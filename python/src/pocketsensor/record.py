"""受信した CDR バイト列を MCAP へ書く。復号しない。"""

from __future__ import annotations

import json
import logging
import queue
import threading
from pathlib import Path
from typing import TYPE_CHECKING, Any

from mcap.writer import CompressionType, Writer

from pocketsensor.protocol import ChannelInfo

if TYPE_CHECKING:
    from pocketsensor.device import Device

log = logging.getLogger("pocketsensor.record")

_STOP = object()
_DEFAULT_QUEUE = 64


def _compression() -> CompressionType:
    try:
        import zstandard  # noqa: F401
    except ImportError:
        return CompressionType.NONE
    return CompressionType.ZSTD


class Recorder:
    """Device の raw tap を専用スレッドで MCAP に書く。受信スレッドはディスク待ちしない。"""

    def __init__(self, device: Device, path: str | Path, *, queue_size: int = _DEFAULT_QUEUE) -> None:
        self._device = device
        self._path = Path(path)
        self._queue: queue.Queue[Any] = queue.Queue(maxsize=max(1, int(queue_size)))
        self._overflow_logged = False
        self._started = False
        self._stopped = False
        self._writer: Writer | None = None
        self._handle = None
        self._thread: threading.Thread | None = None
        self._schema_ids: dict[str, int] = {}
        self._channel_ids: dict[str, int] = {}
        self._seq: dict[str, int] = {}
        self._pending_latched: list[tuple[ChannelInfo, int, bytes]] = []

    def __enter__(self) -> Recorder:
        self.start()
        return self

    def __exit__(self, *args: object) -> None:
        self.stop()

    def start(self) -> None:
        if self._started:
            return
        self._path.parent.mkdir(parents=True, exist_ok=True)
        self._handle = self._path.open("wb")
        self._writer = Writer(self._handle, compression=_compression(), use_chunking=True)
        version = _sdk_version()
        self._writer.start(profile="ros2", library=f"pocketsensor {version}")
        self._thread = threading.Thread(target=self._run, name="ps-record", daemon=True)
        self._thread.start()
        self._started = True
        with self._device._lock:
            latched = list(self._device._latched_raw.values())
        for channel, t_ns, payload in latched:
            self._enqueue(channel, t_ns, payload, kind="latched")
        self._device.add_raw_tap(self._on_raw)

    def stop(self) -> None:
        if self._stopped:
            return
        self._stopped = True
        if self._started:
            self._device.remove_raw_tap(self._on_raw)
            try:
                self._queue.put(_STOP, timeout=2.0)
            except queue.Full:
                log.warning("record queue full while stopping; metadata may be incomplete")
            if self._thread is not None:
                self._thread.join(timeout=5.0)
        self._write_metadata()
        if self._writer is not None:
            try:
                self._writer.finish()
            except Exception:
                log.exception("failed to finish MCAP")
            self._writer = None
        if self._handle is not None:
            try:
                self._handle.close()
            except OSError:
                pass
            self._handle = None
        if getattr(self._device, "_recorder", None) is self:
            self._device._recorder = None

    def _on_raw(self, channel: ChannelInfo, t_ns: int, payload: bytes) -> None:
        self._enqueue(channel, t_ns, payload)

    def _enqueue(self, channel: ChannelInfo, t_ns: int, payload: bytes, kind: str = "msg") -> None:
        try:
            self._queue.put_nowait((kind, channel, int(t_ns), bytes(payload)))
        except queue.Full:
            self._device._note_record_drop()
            if not self._overflow_logged:
                self._overflow_logged = True
                log.warning("record queue overflow; dropping messages")

    def _run(self) -> None:
        while True:
            try:
                item = self._queue.get(timeout=0.2)
            except queue.Empty:
                if self._stopped:
                    self._flush_latched(log_time_ns=None)
                    return
                continue
            if item is _STOP:
                self._drain()
                return
            self._write_item(item)

    def _drain(self) -> None:
        while True:
            try:
                item = self._queue.get_nowait()
            except queue.Empty:
                break
            if item is _STOP:
                continue
            self._write_item(item)
        # 記録のあいだに 1 件も届かなかった。合わせる時刻が無いので、元の時刻で書く。
        self._flush_latched(log_time_ns=None)

    def _write_item(self, item: object) -> None:
        kind, channel, t_ns, payload = item  # type: ignore[misc]
        if self._writer is None:
            return
        if kind == "latched":
            self._pending_latched.append((channel, t_ns, payload))
            return
        if kind != "msg":
            return
        self._flush_latched(log_time_ns=t_ns)
        try:
            self._write_message(channel, t_ns, payload, publish_time_ns=t_ns)
        except Exception:
            log.exception("failed to write MCAP message on %s", channel.topic)

    def _flush_latched(self, log_time_ns: int | None) -> None:
        """記録の開始時に持っていた /tf_static と device_info を、最初に届いたメッセージの時刻で書く。

        これらの時刻はセッションの開始時のもので、そのまま log_time にすると記録の先頭に長い無音ができる。
        rosbag2 や Lichtblick は log_time の順に再生するので、そのあいだ待たされる。
        元の時刻は publish_time に残す。
        """
        pending, self._pending_latched = self._pending_latched, []
        for channel, t_ns, payload in pending:
            try:
                self._write_message(
                    channel,
                    t_ns if log_time_ns is None else max(t_ns, log_time_ns),
                    payload,
                    publish_time_ns=t_ns,
                )
            except Exception:
                log.exception("failed to write MCAP message on %s", channel.topic)

    def _write_message(self, channel: ChannelInfo, t_ns: int, payload: bytes, publish_time_ns: int) -> None:
        writer = self._writer
        assert writer is not None
        schema_id = self._schema_ids.get(channel.schema_name)
        if schema_id is None:
            schema_id = writer.register_schema(
                channel.schema_name,
                "ros2msg",
                channel.schema.encode("utf-8"),
            )
            self._schema_ids[channel.schema_name] = schema_id
        channel_id = self._channel_ids.get(channel.topic)
        if channel_id is None:
            channel_id = writer.register_channel(channel.topic, "cdr", schema_id, {})
            self._channel_ids[channel.topic] = channel_id
        seq = self._seq.get(channel.topic, 0)
        self._seq[channel.topic] = seq + 1
        writer.add_message(channel_id, t_ns, payload, publish_time_ns, sequence=seq)

    def _write_metadata(self) -> None:
        writer = self._writer
        if writer is None:
            return
        info_json = self._device._device_info_json
        if info_json is None and self._device._info is not None:
            info_json = json.dumps(self._device._info.raw, ensure_ascii=False, separators=(",", ":"))
        if info_json is not None:
            writer.add_metadata("pocketsensor.device_info", {"json": info_json})
        with self._device._lock:
            mono = list(self._device._clock_samples_mono)
            wall = list(self._device._clock_samples_wall)
        writer.add_metadata(
            "pocketsensor.clock_samples",
            {
                "monotonic": json.dumps(mono, separators=(",", ":")),
                "wall": json.dumps(wall, separators=(",", ":")),
            },
        )
        writer.add_metadata(
            "pocketsensor.recorder",
            {"sdk_version": _sdk_version(), "source": str(self._device._source)},
        )


def _sdk_version() -> str:
    from pocketsensor import __version__

    return str(__version__)

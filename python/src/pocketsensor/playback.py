"""MCAP 記録をライブと同じ Device API で再生する。"""

from __future__ import annotations

import json
import logging
import threading
import time
from collections.abc import Iterator, Sequence
from pathlib import Path
from typing import Any

from mcap.reader import make_reader
from mcap.records import Channel, Message, Schema

from pocketsensor.clock import ClockSample
from pocketsensor.config import Config, FramePolicy
from pocketsensor.decode import decode_device_info
from pocketsensor.device import Device
from pocketsensor.errors import ConnectionFailed, ProtocolError, Unsupported
from pocketsensor.frameset import FrameSetAssembler
from pocketsensor.protocol import ChannelInfo
from pocketsensor.streams import channel_topic, resolve_channel_keys, topic_to_key

log = logging.getLogger("pocketsensor.playback")

_STARTUP_KEYS = frozenset({"device_info", "tf_static", "color_camera_info", "depth_camera_info"})


def is_recording_source(source: str) -> bool:
    """既存ファイルまたは .mcap で終わるパスなら再生対象。"""
    if source.startswith(("ws://", "wss://", "usb:")):
        return False
    if source.endswith(".mcap"):
        return True
    try:
        return Path(source).expanduser().is_file()
    except OSError:
        return False


def open_playback(source: str, config: Config, *, realtime: bool) -> PlaybackDevice:
    path = Path(source).expanduser()
    if not path.is_file():
        raise ConnectionFailed(f"recording not found: {source}")
    return PlaybackDevice(str(path), config, realtime=realtime)


class PlaybackDevice(Device):
    """記録ファイル。公開 API は Device と同じ。パイプラインは ingest を共有する。"""

    def __init__(self, path: str, config: Config, *, realtime: bool) -> None:
        super().__init__(None, config, source=path, playback=True, realtime=realtime)
        self._path = path
        self._pull = not realtime
        self._fp = None
        self._msg_iter: Iterator[tuple[Schema | None, Channel, Message]] | None = None
        self._peek: tuple[Schema | None, Channel, Message] | None = None
        self._feed_thread: threading.Thread | None = None
        try:
            self._prepare()
        except BaseException:
            self.close()
            raise

    def _prepare(self) -> None:
        with Path(self._path).open("rb") as handle:
            reader = make_reader(handle)
            self._apply_metadata(reader)
            topics = self._register_from_summary(reader)
            self._resolve_playback_name(topics)
            self._bind_topics(topics)
            self._require_wanted_topics(topics)
            for schema, channel, message in reader.iter_messages(log_time_order=True):
                self._ingest_mcap(schema, channel, message, startup=True)
                if self._startup_ready():
                    break
        if not self._startup_ready():
            raise ProtocolError("recording is missing latched device_info, tf_static, or camera_info")
        self._assembler = FrameSetAssembler(self._config.required_camera_streams(), self._config.frame_policy)
        with self._lock:
            self._pending_sets.clear()
            self._color_msg_at.clear()
            self._depth_msg_at.clear()
            self._depth_compressed_at.clear()
            self._msg_q.clear()
        self._fp = Path(self._path).open("rb")
        self._msg_iter = make_reader(self._fp).iter_messages(log_time_order=True)
        if not self._pull:
            self._feed_thread = threading.Thread(target=self._feed_loop, name="ps-play", daemon=True)
            self._feed_thread.start()

    def _apply_metadata(self, reader: Any) -> None:
        for item in reader.iter_metadata():
            name = str(item.name)
            meta = dict(item.metadata)
            if name == "pocketsensor.device_info":
                raw = meta.get("json")
                if raw:
                    self._device_info_json = raw
                    self._info = decode_device_info(type("M", (), {"data": raw})())
            elif name == "pocketsensor.clock_samples":
                self._load_clock_samples(meta)

    def _load_clock_samples(self, meta: dict[str, str]) -> None:
        try:
            mono = json.loads(meta.get("monotonic", "[]"))
            wall = json.loads(meta.get("wall", "[]"))
        except json.JSONDecodeError:
            log.warning("clock_samples metadata is not valid JSON")
            return
        with self._clock_lock:
            for row in mono:
                sample = ClockSample(int(row[0]), int(row[1]), int(row[2]), int(row[3]))
                self._host_est.add(sample)
                self._clock_samples_mono.append([sample.t1, sample.t2, sample.t3, sample.t4])
            for row in wall:
                sample = ClockSample(int(row[0]), int(row[1]), int(row[2]), int(row[3]))
                self._wall_est.add(sample)
                self._clock_samples_wall.append([sample.t1, sample.t2, sample.t3, sample.t4])

    def _register_from_summary(self, reader: Any) -> list[str]:
        summary = reader.get_summary()
        topics: list[str] = []
        if summary is None:
            return topics
        for schema in summary.schemas.values():
            if schema.data:
                try:
                    self._codec.register_schema(schema.name, schema.data.decode("utf-8"))
                except Exception:
                    log.debug("schema register skipped for %s", schema.name, exc_info=True)
        for channel in summary.channels.values():
            topics.append(channel.topic)
        return topics

    def _resolve_playback_name(self, topics: list[str]) -> None:
        if self._info is not None and self._info.name:
            self._name = self._info.name
            return
        for topic in topics:
            if topic.endswith("/device_info"):
                body = topic[1:] if topic.startswith("/") else topic
                self._name = body[: -len("/device_info")]
                return
        raise ProtocolError("recording does not include device_info")

    def _bind_topics(self, topics: list[str]) -> None:
        for topic in topics:
            key = topic_to_key(topic, self._name)
            if key is not None:
                self._topic_key[topic] = key

    def _require_wanted_topics(self, topics: list[str]) -> None:
        present = set(topics)
        advertised: set[str] = set()
        for topic in topics:
            key = topic_to_key(topic, self._name)
            if key is not None:
                advertised.add(key)
        wanted: set[str] = {"device_info", "tf_static"}
        for spec in self._config.streams:
            wanted.update(resolve_channel_keys(spec, advertised))
        for key in sorted(wanted):
            topic = channel_topic(key, self._name)
            if topic not in present:
                raise Unsupported(f"channel not advertised: {topic}")

    def _startup_ready(self) -> bool:
        wanted_cam = self._wanted_camera_info()
        with self._lock:
            if self._info is None or not self._tf_loaded:
                return False
            return wanted_cam <= set(self._caminfo)

    def _as_channel(self, schema: Schema | None, channel: Channel) -> ChannelInfo:
        schema_name = schema.name if schema is not None else ""
        schema_text = schema.data.decode("utf-8") if schema is not None and schema.data else ""
        schema_enc = schema.encoding if schema is not None else ""
        return ChannelInfo(
            id=int(channel.id),
            topic=channel.topic,
            encoding=channel.message_encoding,
            schema_name=schema_name,
            schema=schema_text,
            schema_encoding=schema_enc,
        )

    def _ingest_mcap(
        self,
        schema: Schema | None,
        channel: Channel,
        message: Message,
        *,
        startup: bool = False,
    ) -> None:
        info = self._as_channel(schema, channel)
        if startup:
            key = self._topic_key.get(info.topic)
            if key not in _STARTUP_KEYS:
                return
        self._on_message(info, int(message.log_time), bytes(message.data), 0, 0)

    def _next_item(self) -> tuple[Schema | None, Channel, Message] | None:
        if self._peek is not None:
            item = self._peek
            self._peek = None
            return item
        if self._msg_iter is None:
            return None
        try:
            return next(self._msg_iter)
        except StopIteration:
            return None

    def _peek_item(self) -> tuple[Schema | None, Channel, Message] | None:
        if self._peek is None:
            if self._msg_iter is None:
                return None
            try:
                self._peek = next(self._msg_iter)
            except StopIteration:
                return None
        return self._peek

    def _feed_loop(self) -> None:
        origin_mono: int | None = None
        origin_log: int | None = None
        try:
            while not self._clock_stop.is_set():
                item = self._next_item()
                if item is None:
                    return
                schema, channel, message = item
                log_t = int(message.log_time)
                if origin_log is None:
                    origin_log = log_t
                    origin_mono = time.monotonic_ns()
                else:
                    assert origin_mono is not None
                    target = origin_mono + (log_t - origin_log)
                    now = time.monotonic_ns()
                    if target > now:
                        delay = (target - now) / 1e9
                        if self._clock_stop.wait(delay):
                            return
                self._ingest_mcap(schema, channel, message)
        finally:
            self._eof = True
            with self._lock:
                self._frame_cv.notify_all()
                self._msg_cv.notify_all()

    def wait_for_frames(self, timeout: float | None = None) -> Any:
        if not self._pull:
            return super().wait_for_frames(timeout)
        deadline = None if timeout is None else time.monotonic() + timeout
        while True:
            if deadline is not None and time.monotonic() >= deadline:
                raise TimeoutError("wait_for_frames timed out")
            with self._lock:
                ready = bool(self._pending_sets)
                target_t = self._pending_sets[0].t_device_ns if ready else None
            if ready and target_t is not None:
                self._drain_same_time(target_t)
                with self._lock:
                    return self._pending_sets.popleft()
            item = self._next_item()
            if item is None:
                leftover = self._assembler.flush() if self._config.frame_policy is FramePolicy.ANY else []
                for frames in leftover:
                    frames._clock = self._clock_view
                    frames._allow_host_arrival = False
                    with self._lock:
                        self._pending_sets.append(frames)
                with self._lock:
                    if self._pending_sets:
                        return self._pending_sets.popleft()
                self._eof = True
                raise EOFError("end of recording")
            self._ingest_mcap(*item)

    def _drain_same_time(self, target_t: int) -> None:
        while True:
            item = self._peek_item()
            if item is None:
                return
            _schema, _channel, message = item
            if int(message.log_time) > target_t:
                return
            consumed = self._next_item()
            if consumed is None:
                return
            self._ingest_mcap(*consumed)

    def messages(self, topics: Sequence[str] | None = None) -> Iterator[tuple[str, int, Any]]:
        if not self._pull:
            yield from super().messages(topics)
            return
        wanted = set(topics) if topics is not None else None
        with Path(self._path).open("rb") as handle:
            reader = make_reader(handle)
            for schema, channel, message in reader.iter_messages(log_time_order=True):
                if wanted is not None and channel.topic not in wanted:
                    continue
                info = self._as_channel(schema, channel)
                try:
                    msg = self._codec.decode(info.schema_name, bytes(message.data))
                except Exception:
                    log.exception("failed to decode %s", channel.topic)
                    continue
                yield channel.topic, int(message.log_time), msg

    def close(self) -> None:
        self._clock_stop.set()
        if self._feed_thread is not None:
            self._feed_thread.join(timeout=2.0)
            self._feed_thread = None
        if self._fp is not None:
            try:
                self._fp.close()
            except OSError:
                pass
            self._fp = None
        super().close()

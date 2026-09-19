"""端末を開き、FrameSet とセンサー列を同期 API で返す。"""

from __future__ import annotations

import logging
import threading
import time
from collections import deque
from collections.abc import Callable, Iterator, Sequence
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from pocketsensor.buffers import LatestValue, SampleBuffer
from pocketsensor.calibration import Calibration
from pocketsensor.cdr import CdrCodec
from pocketsensor.client import FoxgloveClient
from pocketsensor.clock import ClockEstimator, ClockSample, ClockView
from pocketsensor.config import Config
from pocketsensor.decode import (
    decode_anchors,
    decode_battery,
    decode_camera_info,
    decode_color,
    decode_confidence,
    decode_confidence_compressed,
    decode_depth,
    decode_depth_compressed,
    decode_device_info,
    decode_gnss,
    decode_imu,
    decode_mag,
    decode_pose,
    decode_pressure,
    decode_tracking,
    stamp_to_ns,
)
from pocketsensor.errors import ConnectionFailed, ConnectionLost, ProtocolError, Unsupported
from pocketsensor.frameset import FrameSet, FrameSetAssembler
from pocketsensor.intrinsics import Intrinsics
from pocketsensor.protocol import ChannelInfo
from pocketsensor.streams import (
    RATE_PARAM_BY_STREAM,
    Color,
    Depth,
    Stream,
    channel_topic,
    resolve_channel_keys,
    topic_to_key,
)
from pocketsensor.transport import connect
from pocketsensor.types import (
    AnchorSample,
    BatteryStatus,
    DeviceInfo,
    GnssFix,
    ImuSample,
    MagSample,
    PressureSample,
)

log = logging.getLogger("pocketsensor.device")

_MESSAGES_CAP = 10000
RawTap = Callable[[ChannelInfo, int, bytes], None]


@dataclass
class DeviceStats:
    dropped_framesets: int = 0
    dropped_incomplete: int = 0
    dropped_imu: int = 0
    dropped_record: int = 0
    received_messages: dict[str, int] = field(default_factory=dict)


class _Drain:
    def __init__(self, device: Device, buffer: SampleBuffer) -> None:
        self._device = device
        self._buffer = buffer

    def read_all(self) -> list:
        self._device._raise_if_dead()
        with self._device._lock:
            samples = self._buffer.read_all()
            if self._buffer is self._device._imu or self._buffer is self._device._imu_raw:
                self._device._stats.dropped_imu = self._device._imu.dropped + self._device._imu_raw.dropped
            return samples

    def latest(self) -> Any:
        self._device._raise_if_dead()
        with self._device._lock:
            return self._buffer.last()


class _Latest:
    def __init__(self, device: Device, slot: LatestValue) -> None:
        self._device = device
        self._slot = slot

    def latest(self) -> Any:
        self._device._raise_if_dead()
        return self._slot.get()


class _AnchorsView:
    def __init__(self, device: Device) -> None:
        self._device = device

    def latest(self, max_age_s: float | None = 1.5) -> dict[str, AnchorSample]:
        self._device._raise_if_dead()
        return self._device._anchors_latest(max_age_s)


class Device:
    """開いた端末。受信は裏スレッド、公開 API は同期。"""

    def __init__(
        self,
        client: FoxgloveClient | None,
        config: Config,
        *,
        source: str = "",
        playback: bool = False,
        realtime: bool = True,
    ) -> None:
        self._client = client
        self._config = config
        self._source = source
        self._playback = playback
        self._realtime = realtime
        self._allow_host_arrival = not playback
        self._latest_only = (not playback) or realtime
        self._codec = CdrCodec.from_contract()
        self._lock = threading.RLock()
        self._dead = False
        self._eof = False
        self._name = ""
        self._session_id = ""
        self._info: DeviceInfo | None = None
        self._device_info_json: str | None = None
        self._tf_static: list[dict[str, Any]] = []
        self._tf_loaded = False
        self._caminfo: dict[Stream, Intrinsics] = {}
        self._color_info_at: dict[int, Intrinsics] = {}
        self._depth_info_at: dict[int, Intrinsics] = {}
        self._color_msg_at: dict[int, Any] = {}
        self._depth_msg_at: dict[int, Any] = {}
        self._depth_compressed_at: dict[int, bool] = {}
        self._topic_key: dict[str, str] = {}
        self._decode_color = True
        for spec in config.streams:
            if isinstance(spec, Color):
                self._decode_color = spec.decode
        self._assembler = FrameSetAssembler(config.required_camera_streams(), config.frame_policy)
        self._host_est = ClockEstimator()
        self._wall_est = ClockEstimator()
        self._clock_lock = threading.Lock()
        self._clock_view = ClockView(self._host_est, self._wall_est, self._clock_lock)
        self._clock_stop = threading.Event()
        self._clock_thread: threading.Thread | None = None
        self._clock_samples_mono: list[list[int]] = []
        self._clock_samples_wall: list[list[int]] = []
        self._imu = SampleBuffer[ImuSample](config.imu_buffer_seconds)
        self._imu_raw = SampleBuffer[ImuSample](config.imu_buffer_seconds)
        self._mag = SampleBuffer[MagSample](config.imu_buffer_seconds)
        self._pressure: LatestValue[PressureSample] = LatestValue()
        self._gnss: LatestValue[GnssFix] = LatestValue()
        self._battery: LatestValue[BatteryStatus] = LatestValue()
        self._gnss_time_ref: dict[int, int] = {}
        self._anchors_enabled = any(spec.stream is Stream.ANCHORS for spec in config.streams)
        self._anchor_samples: dict[str, tuple[AnchorSample, int]] = {}
        self._anchor_origin_epoch: int | None = None
        self._playback_now_ns = 0
        self._anchors_view = _AnchorsView(self)
        self._stats = DeviceStats()
        self._pending_sets: deque[FrameSet] = deque()
        self._frame_cv = threading.Condition(self._lock)
        self._msg_q: deque[tuple[str, int, Any]] = deque()
        self._msg_cv = threading.Condition(self._lock)
        self._raw_taps: list[RawTap] = []
        self._latched_raw: dict[str, tuple[ChannelInfo, int, bytes]] = {}
        self._recorder: Any = None
        self.imu = _Drain(self, self._imu)
        self.imu_raw = _Drain(self, self._imu_raw)
        self.mag = _Drain(self, self._mag)
        self.pressure = _Latest(self, self._pressure)
        self.gnss = _Latest(self, self._gnss)
        self.battery = _Latest(self, self._battery)

    @property
    def anchors(self) -> _AnchorsView:
        if not self._anchors_enabled:
            raise Unsupported("Anchors stream is not configured")
        return self._anchors_view

    @classmethod
    def connect(cls, source: str, config: Config) -> Device:
        try:
            transport = connect(source, timeout=config.open_timeout)
        except (ConnectionFailed, Unsupported):
            raise
        except (OSError, TimeoutError) as exc:
            raise ConnectionFailed(f"could not connect to {source}") from exc
        client = FoxgloveClient(transport)
        device = cls(client, config, source=source)
        try:
            device._startup()
        except BaseException:
            device.close()
            raise
        return device

    def _startup(self) -> None:
        assert self._client is not None
        deadline = time.monotonic() + self._config.open_timeout
        self._client.on_message = self._on_message
        self._client.on_disconnect = self._on_disconnect
        remaining = max(0.0, deadline - time.monotonic())
        info = self._client.wait_ready(remaining)
        self._session_id = info.session_id
        for channel in self._client.channels.values():
            if channel.schema:
                self._codec.register_schema(channel.schema_name, channel.schema)
        self._name = self._resolve_name()
        advertised: set[str] = set()
        for topic in self._client.channels:
            key = topic_to_key(topic, self._name)
            if key is not None:
                advertised.add(key)
        wanted: set[str] = {"device_info", "tf_static", "diagnostics"}
        for spec in self._config.streams:
            wanted.update(resolve_channel_keys(spec, advertised))
        for key in sorted(wanted):
            topic = channel_topic(key, self._name)
            if topic not in self._client.channels:
                raise Unsupported(f"channel not advertised: {topic}")
            self._client.subscribe(topic)
            self._topic_key[topic] = key
        params: dict[str, Any] = {}
        for spec in self._config.streams:
            params.update(spec.parameters())
        if params:
            remaining = max(0.0, deadline - time.monotonic())
            self._client.set_parameters(params, timeout=remaining)
        wanted_cam = self._wanted_camera_info()
        while time.monotonic() < deadline:
            if self._dead:
                raise ConnectionLost("connection lost")
            with self._lock:
                if self._info is not None and self._tf_loaded and wanted_cam <= set(self._caminfo):
                    break
            time.sleep(0.01)
        else:
            with self._lock:
                have = set(self._caminfo)
            if self._info is None or not self._tf_loaded:
                raise ProtocolError("timed out waiting for latched device_info and tf_static")
            missing = ", ".join(sorted(stream.name for stream in (wanted_cam - have)))
            raise ProtocolError(f"timed out waiting for camera_info ({missing})")
        if self._config.clock_sync:
            try:
                self._one_clock_sync(timeout=max(0.2, deadline - time.monotonic()))
            except Exception:
                log.debug("initial clock sync failed", exc_info=True)
            self._clock_thread = threading.Thread(target=self._clock_loop, name="ps-clock", daemon=True)
            self._clock_thread.start()

    def _resolve_name(self) -> str:
        for topic in self._client.channels:
            if topic.endswith("/device_info"):
                body = topic[1:] if topic.startswith("/") else topic
                return body[: -len("/device_info")]
        raise ProtocolError("advertised channels do not include device_info")

    def _raise_if_dead(self) -> None:
        if self._dead:
            raise ConnectionLost("connection lost")

    def _on_disconnect(self) -> None:
        self._dead = True
        with self._lock:
            self._frame_cv.notify_all()
            self._msg_cv.notify_all()

    def __enter__(self) -> Device:
        return self

    def __exit__(self, *args: object) -> None:
        self.close()

    def close(self) -> None:
        rec = self._recorder
        if rec is not None:
            rec.stop()
        self._clock_stop.set()
        if self._client is not None:
            self._client.close()
        self._on_disconnect()

    @property
    def info(self) -> DeviceInfo:
        if self._info is None:
            raise ProtocolError("device_info has not arrived")
        return self._info

    @property
    def calibration(self) -> Calibration:
        with self._lock:
            if self._info is None:
                raise ProtocolError("device_info has not arrived")
            return Calibration(self._info, list(self._tf_static), dict(self._caminfo))

    def _wanted_camera_info(self) -> set[Stream]:
        wanted: set[Stream] = set()
        for spec in self._config.streams:
            if isinstance(spec, Color):
                wanted.add(Stream.COLOR)
            elif isinstance(spec, Depth):
                wanted.add(Stream.DEPTH)
        return wanted

    @property
    def clock(self) -> ClockView:
        return self._clock_view

    @property
    def stats(self) -> DeviceStats:
        with self._lock:
            return DeviceStats(
                dropped_framesets=self._stats.dropped_framesets,
                dropped_incomplete=self._assembler.dropped_incomplete,
                dropped_imu=self._imu.dropped + self._imu_raw.dropped,
                dropped_record=self._stats.dropped_record,
                received_messages=dict(self._stats.received_messages),
            )

    def wait_for_frames(self, timeout: float | None = None) -> FrameSet:
        self._raise_if_dead()
        deadline = None if timeout is None else time.monotonic() + timeout
        with self._lock:
            while not self._pending_sets:
                if self._eof:
                    raise EOFError("end of recording")
                self._raise_if_dead()
                remaining = None if deadline is None else deadline - time.monotonic()
                if remaining is not None and remaining <= 0:
                    raise TimeoutError("wait_for_frames timed out")
                self._frame_cv.wait(timeout=remaining)
            return self._pending_sets.popleft()

    def messages(self, topics: Sequence[str] | None = None) -> Iterator[tuple[str, int, Any]]:
        wanted = set(topics) if topics is not None else None
        while True:
            with self._lock:
                while not self._msg_q:
                    if self._dead:
                        return
                    self._msg_cv.wait(timeout=0.2)
                item = self._msg_q.popleft()
            if wanted is None or item[0] in wanted:
                yield item

    def _require_live(self) -> None:
        if self._playback or self._client is None:
            raise Unsupported("operation is not available during playback")

    def set_rate(self, stream: Stream, hz: float) -> dict[str, Any]:
        self._require_live()
        assert self._client is not None
        param = RATE_PARAM_BY_STREAM.get(stream)
        if param is None:
            raise Unsupported(f"stream {stream.name} has no rate parameter")
        return self._client.set_parameters({param: float(hz)})

    def set_color_width(self, px: int) -> dict[str, Any]:
        self._require_live()
        assert self._client is not None
        return self._client.set_parameters({"color.width": int(px)})

    def set_jpeg_quality(self, quality: float) -> dict[str, Any]:
        self._require_live()
        assert self._client is not None
        return self._client.set_parameters({"color.jpeg_quality": float(quality)})

    def reset_origin(self) -> tuple[bool, str]:
        self._require_live()
        assert self._client is not None
        req = self._codec.make("std_srvs/srv/Trigger_Request")
        payload = self._codec.encode("std_srvs/srv/Trigger_Request", req)
        raw = self._client.call_service(
            f"/{self._name}/reset_origin", payload, timeout=self._config.open_timeout
        )
        resp = self._codec.decode("std_srvs/srv/Trigger_Response", raw)
        success = bool(resp.success)
        if success and self._anchors_enabled:
            with self._lock:
                self._anchor_samples.clear()
        return success, str(resp.message)

    def record(self, path: str | Path) -> Any:
        self._require_live()
        if self._recorder is not None:
            raise RuntimeError("already recording")
        from pocketsensor.record import Recorder

        rec = Recorder(self, path)
        rec.start()
        self._recorder = rec
        return rec

    def _note_record_drop(self) -> None:
        with self._lock:
            self._stats.dropped_record += 1

    def add_raw_tap(self, callback: RawTap) -> None:
        with self._lock:
            self._raw_taps.append(callback)

    def remove_raw_tap(self, callback: RawTap) -> None:
        with self._lock:
            self._raw_taps = [cb for cb in self._raw_taps if cb is not callback]

    def _one_clock_sync(self, timeout: float = 1.0) -> None:
        assert self._client is not None
        t1_mono = time.monotonic_ns()
        t1_wall = time.time_ns()
        req = self._codec.make("pocketsensor_msgs/srv/ClockSync_Request", t1=t1_mono)
        payload = self._codec.encode("pocketsensor_msgs/srv/ClockSync_Request", req)
        raw = self._client.call_service(f"/{self._name}/clock_sync", payload, timeout=timeout)
        arrival = self._client.last_call_arrival
        t4_mono = arrival[0] if arrival is not None else time.monotonic_ns()
        t4_wall = arrival[1] if arrival is not None else time.time_ns()
        resp = self._codec.decode("pocketsensor_msgs/srv/ClockSync_Response", raw)
        with self._clock_lock:
            self._host_est.add(ClockSample(t1_mono, int(resp.t2), int(resp.t3), t4_mono))
            self._wall_est.add(ClockSample(t1_wall, int(resp.t2), int(resp.t3), t4_wall))
            self._clock_samples_mono.append([t1_mono, int(resp.t2), int(resp.t3), t4_mono])
            self._clock_samples_wall.append([t1_wall, int(resp.t2), int(resp.t3), t4_wall])

    def _clock_loop(self) -> None:
        count = self._host_est.sample_count
        while not self._clock_stop.is_set():
            interval = 1.0 if count < 8 else 5.0
            if self._clock_stop.wait(interval):
                return
            try:
                self._one_clock_sync(timeout=1.0)
                count = self._host_est.sample_count
            except ConnectionLost:
                return
            except Exception:
                log.debug("clock sync failed", exc_info=True)

    def _on_message(
        self,
        channel: ChannelInfo,
        log_time_ns: int,
        payload: bytes,
        arrival_mono: int,
        arrival_wall: int,
    ) -> None:
        with self._lock:
            received = self._stats.received_messages.get(channel.topic, 0) + 1
            self._stats.received_messages[channel.topic] = received
            if self._playback:
                self._playback_now_ns = int(log_time_ns)
            taps = list(self._raw_taps)
            if channel.topic == "/tf_static" or channel.topic.endswith("/device_info"):
                self._latched_raw[channel.topic] = (channel, log_time_ns, payload)
        for tap in taps:
            try:
                tap(channel, log_time_ns, payload)
            except Exception:
                log.exception("raw tap raised")
        try:
            msg = self._codec.decode(channel.schema_name, payload)
        except Exception:
            log.exception("failed to decode %s", channel.topic)
            return
        with self._lock:
            if len(self._msg_q) >= _MESSAGES_CAP:
                self._msg_q.popleft()
            self._msg_q.append((channel.topic, log_time_ns, msg))
            self._msg_cv.notify()
        key = self._topic_key.get(channel.topic)
        if key is None:
            return
        try:
            self._route(key, log_time_ns, msg, arrival_mono)
        except Exception:
            log.exception("failed to route %s", key)

    def _route(self, key: str, t_ns: int, msg: Any, arrival: int) -> None:
        if key == "device_info":
            info = decode_device_info(msg)
            with self._lock:
                self._info = info
                self._device_info_json = str(msg.data)
            return
        if key == "tf_static":
            rows = []
            for tf in msg.transforms:
                child = str(tf.child_frame_id)
                rows.append(
                    {
                        "parent": str(tf.header.frame_id),
                        "child": child,
                        "translation": (
                            float(tf.transform.translation.x),
                            float(tf.transform.translation.y),
                            float(tf.transform.translation.z),
                        ),
                        "rotation_xyzw": (
                            float(tf.transform.rotation.x),
                            float(tf.transform.rotation.y),
                            float(tf.transform.rotation.z),
                            float(tf.transform.rotation.w),
                        ),
                        "translation_known": not child.endswith("_imu_link"),
                    }
                )
            with self._lock:
                self._tf_static = rows
                self._tf_loaded = True
            return
        if key == "color_camera_info":
            intr = decode_camera_info(msg)
            with self._lock:
                self._caminfo[Stream.COLOR] = intr
                self._color_info_at[t_ns] = intr
                self._frame_cv.notify_all()
            self._try_color(t_ns, arrival)
            return
        if key == "depth_camera_info":
            intr = decode_camera_info(msg)
            with self._lock:
                self._caminfo[Stream.DEPTH] = intr
                self._depth_info_at[t_ns] = intr
                self._frame_cv.notify_all()
            self._try_depth(t_ns, arrival)
            return
        if key == "color_image":
            self._color_msg_at[t_ns] = msg
            self._try_color(t_ns, arrival)
            return
        if key == "depth_image":
            self._depth_msg_at[t_ns] = msg
            self._depth_compressed_at[t_ns] = False
            self._try_depth(t_ns, arrival)
            return
        if key == "depth_image_compressed":
            self._depth_msg_at[t_ns] = msg
            self._depth_compressed_at[t_ns] = True
            self._try_depth(t_ns, arrival)
            return
        if key == "depth_confidence":
            self._offer(Stream.CONFIDENCE, t_ns, decode_confidence(msg), arrival)
            return
        if key == "depth_confidence_compressed":
            self._offer(Stream.CONFIDENCE, t_ns, decode_confidence_compressed(msg), arrival)
            return
        if key == "odom":
            self._offer(Stream.POSE, t_ns, decode_pose(msg), arrival)
            return
        if key == "tf":
            if self._anchors_enabled:
                samples = decode_anchors(msg, self._name)
                with self._lock:
                    arrived = int(arrival)
                    for sample in samples:
                        self._anchor_samples[sample.name] = (sample, arrived)
            return
        if key == "tracking":
            status = decode_tracking(msg)
            if self._anchors_enabled:
                with self._lock:
                    epoch = int(status.origin_epoch)
                    if self._anchor_origin_epoch is not None and epoch != self._anchor_origin_epoch:
                        self._anchor_samples.clear()
                    self._anchor_origin_epoch = epoch
            self._offer("tracking", t_ns, status, arrival)
            return
        if key == "imu":
            with self._lock:
                self._imu.append(decode_imu(msg, arrival))
            return
        if key == "imu_raw":
            with self._lock:
                self._imu_raw.append(decode_imu(msg, arrival))
            return
        if key == "mag":
            with self._lock:
                self._mag.append(decode_mag(msg, arrival))
            return
        if key == "pressure":
            self._pressure.set(decode_pressure(msg, arrival))
            return
        if key == "gnss_time_reference":
            self._gnss_time_ref[stamp_to_ns(msg.header.stamp)] = stamp_to_ns(msg.time_ref)
            return
        if key == "gnss_fix":
            time_ref = self._gnss_time_ref.get(stamp_to_ns(msg.header.stamp))
            self._gnss.set(decode_gnss(msg, arrival, time_ref))
            return
        if key == "battery":
            self._battery.set(decode_battery(msg, arrival))

    def _try_color(self, t_ns: int, arrival: int) -> None:
        msg = self._color_msg_at.get(t_ns)
        info = self._color_info_at.get(t_ns) or self._caminfo.get(Stream.COLOR)
        if msg is None or info is None:
            return
        self._color_msg_at.pop(t_ns, None)
        frame = decode_color(msg, info, decode=self._decode_color)
        self._offer(Stream.COLOR, t_ns, frame, arrival)

    def _try_depth(self, t_ns: int, arrival: int) -> None:
        msg = self._depth_msg_at.get(t_ns)
        info = self._depth_info_at.get(t_ns) or self._caminfo.get(Stream.DEPTH)
        if msg is None or info is None:
            return
        self._depth_msg_at.pop(t_ns, None)
        compressed = self._depth_compressed_at.pop(t_ns, False)
        if compressed:
            frame = decode_depth_compressed(msg, info)
        else:
            frame = decode_depth(msg, info)
        self._offer(Stream.DEPTH, t_ns, frame, arrival)

    def _offer(self, stream: Stream | str, t_ns: int, value: Any, arrival: int) -> None:
        sets = self._assembler.feed(stream, t_ns, value, arrival)
        for frames in sets:
            frames._clock = self._clock_view
            frames._allow_host_arrival = self._allow_host_arrival
            with self._lock:
                if self._latest_only:
                    if self._pending_sets:
                        self._stats.dropped_framesets += 1
                        self._pending_sets.clear()
                    self._pending_sets.append(frames)
                else:
                    self._pending_sets.append(frames)
                self._frame_cv.notify()

    def _anchors_latest(self, max_age_s: float | None) -> dict[str, AnchorSample]:
        with self._lock:
            items = dict(self._anchor_samples)
            playback = self._playback
            now = self._playback_now_ns if playback else time.monotonic_ns()
        out: dict[str, AnchorSample] = {}
        max_age_ns = None if max_age_s is None else int(max_age_s * 1_000_000_000)
        for name, (sample, arrival_ns) in items.items():
            if max_age_ns is not None:
                # 再生の ingest は到着時刻を 0 にするので、端末時刻で古さを見る。
                age = now - sample.t_device_ns if playback else now - arrival_ns
                if age > max_age_ns:
                    continue
            out[name] = sample
        return out


def open(source: str, config: Config | None = None, *, realtime: bool = True) -> Device:
    if config is None:
        config = Config(streams=(Color(),))
    from pocketsensor.playback import is_recording_source, open_playback

    if is_recording_source(source):
        return open_playback(source, config, realtime=realtime)
    return Device.connect(source, config)

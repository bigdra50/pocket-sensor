from __future__ import annotations

import json
import logging
import queue
import threading
import time
from pathlib import Path

import pytest
from mcap.reader import make_reader

import pocketsensor as ps
from pocketsensor.device import DeviceStats
from pocketsensor.protocol import ChannelInfo
from pocketsensor.record import Recorder
from pocketsensor.testing.fake_device import FakeDevice


def _cfg(**kwargs) -> ps.Config:
    streams = kwargs.pop(
        "streams",
        (
            ps.Color(rate=15, width=32, jpeg_quality=0.4),
            ps.Depth(rate=15),
            ps.Pose(rate=30),
            ps.Imu(rate=100),
        ),
    )
    return ps.Config(streams=streams, open_timeout=5.0, **kwargs)


def _read_mcap(path: Path) -> tuple[dict[str, dict[str, str]], list]:
    with path.open("rb") as handle:
        reader = make_reader(handle)
        metadata = {item.name: dict(item.metadata) for item in reader.iter_metadata()}
        messages = list(reader.iter_messages())
    return metadata, messages


def _record_run(path: Path, duration: float = 0.35) -> None:
    with FakeDevice(port=0, seed=0) as fake:
        with ps.open(fake.url, _cfg()) as dev:
            with dev.record(path):
                deadline = time.monotonic() + duration
                while time.monotonic() < deadline:
                    try:
                        dev.wait_for_frames(timeout=0.15)
                    except TimeoutError:
                        pass


def test_record_writes_cdr_ros2msg_and_metadata(tmp_path: Path) -> None:
    path = tmp_path / "run.mcap"
    _record_run(path)
    assert path.is_file()
    metadata, items = _read_mcap(path)
    assert "pocketsensor.device_info" in metadata
    info_json = metadata["pocketsensor.device_info"]["json"]
    parsed = json.loads(info_json)
    assert parsed["model"] == "FakeDevice"
    clock = metadata["pocketsensor.clock_samples"]
    mono = json.loads(clock["monotonic"])
    wall = json.loads(clock["wall"])
    assert isinstance(mono, list)
    assert isinstance(wall, list)
    assert mono
    assert len(mono[0]) == 4
    recorder = metadata["pocketsensor.recorder"]
    assert recorder["sdk_version"] == ps.__version__
    assert recorder["source"].startswith("ws://")

    assert items
    topics = {channel.topic for _schema, channel, _msg in items}
    assert "/tf_static" in topics
    assert any(topic.endswith("/device_info") for topic in topics)

    schemas_by_name = {}
    for schema, channel, message in items:
        assert schema is not None
        schemas_by_name[schema.name] = schema
        assert schema.encoding == "ros2msg"
        assert schema.data
        assert channel.message_encoding == "cdr"
        assert channel.metadata == {}
        assert message.log_time == message.publish_time
        assert message.log_time > 0

    assert "std_msgs/msg/String" in schemas_by_name
    assert "tf2_msgs/msg/TFMessage" in schemas_by_name


def test_record_includes_latched_payloads_when_started_late(tmp_path: Path) -> None:
    path = tmp_path / "late.mcap"
    with FakeDevice(port=0, seed=1) as fake:
        with ps.open(fake.url, _cfg()) as dev:
            for _ in range(2):
                dev.wait_for_frames(timeout=2.0)
            rec = dev.record(path)
            rec.stop()
    _metadata, items = _read_mcap(path)
    topics = [channel.topic for _schema, channel, _msg in items]
    assert "/tf_static" in topics
    assert any(topic.endswith("/device_info") for topic in topics)


def test_record_queue_overflow_counts_and_logs_once(tmp_path: Path, caplog: pytest.LogCaptureFixture) -> None:
    caplog.set_level(logging.WARNING, logger="pocketsensor.record")

    class Stub:
        def __init__(self) -> None:
            self._lock = threading.Lock()
            self._stats = DeviceStats()
            self._latched_raw: dict = {}
            self._source = "ws://127.0.0.1:1"
            self._device_info_json = '{"model":"stub"}'
            self._clock_samples_mono: list = []
            self._clock_samples_wall: list = []
            self._raw_taps: list = []

        def add_raw_tap(self, callback) -> None:
            self._raw_taps.append(callback)

        def remove_raw_tap(self, callback) -> None:
            self._raw_taps = [item for item in self._raw_taps if item is not callback]

        def _note_record_drop(self) -> None:
            self._stats.dropped_record += 1

    stub = Stub()
    rec = Recorder(stub, tmp_path / "overflow.mcap", queue_size=1)  # type: ignore[arg-type]
    rec._queue.put_nowait(("hold", None, 0, b""))
    channel = ChannelInfo(
        id=1,
        topic="/x",
        encoding="cdr",
        schema_name="std_msgs/msg/String",
        schema="string data\n",
        schema_encoding="ros2msg",
    )
    rec._enqueue(channel, 1, b"abc")
    rec._enqueue(channel, 2, b"def")
    assert stub._stats.dropped_record >= 1
    warnings = [row.message for row in caplog.records if row.levelno >= logging.WARNING]
    assert any("record queue overflow" in msg for msg in warnings)
    assert len(warnings) == 1
    try:
        rec._queue.get_nowait()
    except queue.Empty:
        pass


def test_record_decodes_with_mcap_ros2_support_when_installed(tmp_path: Path) -> None:
    pytest.importorskip("mcap_ros2")
    path = tmp_path / "ros2.mcap"
    _record_run(path, duration=0.25)
    from mcap_ros2.reader import read_ros2_messages

    decoded = list(read_ros2_messages(str(path)))
    assert decoded
    for item in decoded:
        assert item.ros_msg is not None

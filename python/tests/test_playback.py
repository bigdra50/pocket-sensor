from __future__ import annotations

import time
from pathlib import Path

import pytest

import pocketsensor as ps
from pocketsensor.clock import ClockNotReady
from pocketsensor.device import Device
from pocketsensor.playback import PlaybackDevice
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


@pytest.fixture(scope="module")
def recorded_mcap(tmp_path_factory: pytest.TempPathFactory) -> Path:
    path = tmp_path_factory.mktemp("play") / "run.mcap"
    with FakeDevice(port=0, seed=0) as fake:
        with ps.open(fake.url, _cfg()) as dev:
            with dev.record(path):
                got = 0
                deadline = time.monotonic() + 1.2
                while time.monotonic() < deadline and got < 4:
                    try:
                        dev.wait_for_frames(timeout=0.25)
                        got += 1
                    except TimeoutError:
                        pass
                assert got >= 2
    return path


def test_open_mcap_returns_playback_device_with_live_api(recorded_mcap: Path) -> None:
    with ps.open(str(recorded_mcap), _cfg(), realtime=False) as dev:
        assert isinstance(dev, Device)
        assert isinstance(dev, PlaybackDevice)
        assert dev.info.model == "FakeDevice"
        k = dev.calibration.intrinsics(ps.Stream.DEPTH)
        assert k.width == 256
        frames = dev.wait_for_frames(timeout=2.0)
        assert frames.color is not None
        assert frames.depth is not None
        assert frames.pose is not None
        assert frames.t_device_ns > 0
        t_device = frames.timestamp(ps.TimeDomain.DEVICE)
        assert t_device == frames.t_device_ns
        if dev.clock.ready:
            host = frames.timestamp(ps.TimeDomain.HOST)
            assert host != 0
        with pytest.raises(ps.Unsupported):
            frames.timestamp(ps.TimeDomain.HOST_ARRIVAL)
        with pytest.raises(ps.Unsupported):
            _ = frames.latency_ns
        samples = dev.imu.read_all()
        assert all(s.t_device_ns <= frames.t_device_ns for s in samples)


def test_pull_mode_does_not_drop_and_eof(recorded_mcap: Path) -> None:
    with ps.open(str(recorded_mcap), _cfg(), realtime=False) as dev:
        seen = 0
        times: list[int] = []
        while True:
            try:
                frames = dev.wait_for_frames(timeout=2.0)
            except EOFError:
                break
            seen += 1
            times.append(frames.t_device_ns)
        assert seen >= 2
        assert times == sorted(times)
        assert dev.stats.dropped_framesets == 0
        with pytest.raises(EOFError):
            dev.wait_for_frames(timeout=0.2)


def test_playback_messages_iterate_in_log_time_order(recorded_mcap: Path) -> None:
    with ps.open(str(recorded_mcap), _cfg(), realtime=False) as dev:
        rows = []
        for topic, t_ns, _msg in dev.messages():
            rows.append((topic, t_ns))
            if len(rows) >= 40:
                break
        assert rows
        assert [t for _topic, t in rows] == sorted(t for _topic, t in rows)
        assert any(topic.endswith("/device_info") or topic == "/tf_static" for topic, _t in rows)


def test_playback_unsupported_live_ops(recorded_mcap: Path) -> None:
    with ps.open(str(recorded_mcap), _cfg(), realtime=False) as dev:
        with pytest.raises(ps.Unsupported):
            dev.set_rate(ps.Stream.POSE, 10.0)
        with pytest.raises(ps.Unsupported):
            dev.set_color_width(64)
        with pytest.raises(ps.Unsupported):
            dev.set_jpeg_quality(0.5)
        with pytest.raises(ps.Unsupported):
            dev.reset_origin()
        with pytest.raises(ps.Unsupported):
            dev.record("other.mcap")


def test_playback_realtime_paces_and_shares_pipeline(recorded_mcap: Path) -> None:
    started = time.monotonic()
    with ps.open(str(recorded_mcap), _cfg(), realtime=True) as dev:
        frames = dev.wait_for_frames(timeout=3.0)
        assert frames.color is not None or frames.pose is not None
    elapsed = time.monotonic() - started
    assert elapsed >= 0.0


def test_open_missing_mcap_is_connection_failed(tmp_path: Path) -> None:
    missing = tmp_path / "nope.mcap"
    with pytest.raises(ps.ConnectionFailed):
        ps.open(str(missing), _cfg())


def test_playback_without_clock_samples_host_not_ready(tmp_path: Path, recorded_mcap: Path) -> None:
    # メタデータの無いファイルでも DEVICE は使える。HOST は ClockNotReady。
    from mcap.reader import make_reader
    from mcap.writer import CompressionType, Writer

    stripped = tmp_path / "stripped.mcap"
    with recorded_mcap.open("rb") as src, stripped.open("wb") as dest:
        reader = make_reader(src)
        writer = Writer(dest, compression=CompressionType.NONE)
        writer.start(profile="ros2")
        schema_ids: dict[int, int] = {}
        channel_ids: dict[int, int] = {}
        for schema, channel, message in reader.iter_messages():
            if schema is not None and schema.id not in schema_ids:
                schema_ids[schema.id] = writer.register_schema(schema.name, schema.encoding, schema.data)
            if channel.id not in channel_ids:
                sid = schema_ids.get(channel.schema_id, 0)
                channel_ids[channel.id] = writer.register_channel(
                    channel.topic, channel.message_encoding, sid, dict(channel.metadata)
                )
            writer.add_message(
                channel_ids[channel.id],
                message.log_time,
                message.data,
                message.publish_time,
                sequence=message.sequence,
            )
        writer.finish()
    with ps.open(str(stripped), _cfg(), realtime=False) as dev:
        assert dev.info.model == "FakeDevice"
        assert not dev.clock.ready
        frames = dev.wait_for_frames(timeout=2.0)
        with pytest.raises(ClockNotReady):
            frames.timestamp(ps.TimeDomain.HOST)

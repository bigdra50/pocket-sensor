from __future__ import annotations

import math
import time
from collections import Counter
from pathlib import Path

import numpy as np
import pytest
from mcap.reader import make_reader

import pocketsensor as ps
from pocketsensor.cli import main as cli_main
from pocketsensor.frames import LINK_TO_COLOR_OPTICAL_RPY, quat_to_matrix, rpy_to_quaternion
from pocketsensor.intrinsics import scale_intrinsics
from pocketsensor.streams import Stream, channel_topic
from pocketsensor.types import TrackingState

pytestmark = pytest.mark.e2e

_G = 9.80665


def _cfg(*extra: object, **kwargs) -> ps.Config:
    streams = (
        ps.Color(rate=15),
        ps.Depth(rate=15),
        ps.Pose(rate=30),
        ps.Imu(rate=100, raw=True),
        *extra,
    )
    open_timeout = kwargs.pop("open_timeout", 10.0)
    return ps.Config(streams=streams, open_timeout=open_timeout, **kwargs)


def _wait_until(pred, timeout: float, interval: float = 0.02) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if pred():
            return
        time.sleep(min(interval, max(0.0, deadline - time.monotonic())))
    raise AssertionError("deadline exceeded")


def _count_topic(dev: ps.Device, topic: str, seconds: float) -> int:
    start = time.monotonic()
    n0 = dev.stats.received_messages.get(topic, 0)
    while time.monotonic() - start < seconds:
        time.sleep(0.02)
    return dev.stats.received_messages.get(topic, 0) - n0


def test_framesets_share_device_time_and_decode(sim_device: str) -> None:
    with ps.open(sim_device, _cfg()) as dev:
        sets: list[ps.FrameSet] = []
        for _ in range(20):
            sets.append(dev.wait_for_frames(timeout=3.0))
        assert len(sets) == 20
        for frames in sets:
            assert frames.color is not None
            assert frames.depth is not None
            assert frames.pose is not None
            assert frames.t_device_ns > 0
            assert frames.timestamp(ps.TimeDomain.DEVICE) == frames.t_device_ns
            assert frames.color.image is not None
            assert frames.color.image.shape[1] == frames.color.intrinsics.width
            assert frames.color.image.shape[0] == frames.color.intrinsics.height
            assert frames.depth.raw.dtype == np.uint16
            assert frames.depth.raw.shape == (192, 256)
            assert np.any(frames.depth.raw > 0)
            assert np.any(frames.depth.raw == 0)
            meters = frames.depth.meters
            assert np.all(np.isnan(meters[frames.depth.raw == 0]))
            assert np.all(np.isfinite(meters[frames.depth.raw != 0]))
            scaled = scale_intrinsics(
                frames.color.intrinsics,
                frames.depth.intrinsics.width,
                frames.depth.intrinsics.height,
            )
            assert scaled.fx == pytest.approx(frames.depth.intrinsics.fx, rel=1e-6, abs=1e-4)
            assert scaled.fy == pytest.approx(frames.depth.intrinsics.fy, rel=1e-6, abs=1e-4)
            assert scaled.cx == pytest.approx(frames.depth.intrinsics.cx, rel=1e-6, abs=1e-4)
            assert scaled.cy == pytest.approx(frames.depth.intrinsics.cy, rel=1e-6, abs=1e-4)


def test_pose_rep103_and_origin_epoch(sim_device: str) -> None:
    with ps.open(sim_device, _cfg()) as dev:
        name = dev.info.name
        zs: list[float] = []
        epoch0: int | None = None
        for _ in range(5):
            frames = dev.wait_for_frames(timeout=3.0)
            assert frames.pose is not None
            assert frames.pose.frame_id == f"{name}_odom"
            assert frames.pose.child_frame_id == f"{name}_link"
            xy = math.hypot(float(frames.pose.position[0]), float(frames.pose.position[1]))
            assert xy == pytest.approx(1.0, abs=0.08)
            zs.append(float(frames.pose.position[2]))
            q = frames.pose.orientation_xyzw
            assert float(np.linalg.norm(q)) == pytest.approx(1.0, abs=1e-6)
            assert float(q[3]) >= 0.0
            if frames.tracking is not None:
                assert frames.tracking.state == int(TrackingState.NORMAL)
                epoch0 = frames.tracking.origin_epoch
        assert max(zs) - min(zs) < 1e-6
        assert epoch0 is not None
        ok, _message = dev.reset_origin()
        assert ok
        bumped = False
        deadline = time.monotonic() + 4.0
        while time.monotonic() < deadline:
            frames = dev.wait_for_frames(timeout=1.0)
            if frames.tracking is not None and frames.tracking.origin_epoch > epoch0:
                bumped = True
                break
        assert bumped


def test_imu_rate_monotone_and_raw_orientation(sim_device: str) -> None:
    with ps.open(sim_device, _cfg()) as dev:
        dev.imu.read_all()
        dev.imu_raw.read_all()
        t0 = time.monotonic()
        time.sleep(1.0)
        elapsed = time.monotonic() - t0
        fused = dev.imu.read_all()
        raw = dev.imu_raw.read_all()
        assert len(fused) / elapsed >= 80.0
        times = [s.t_device_ns for s in fused]
        assert times == sorted(times)
        assert len(set(times)) == len(times)
        for sample in fused:
            mag = float(np.linalg.norm(sample.linear_acceleration))
            assert mag == pytest.approx(_G, abs=0.4)
        assert raw
        for sample in raw:
            assert sample.orientation_xyzw is None


def test_low_rate_latest_within_3s(sim_device: str) -> None:
    cfg = _cfg(ps.Mag(), ps.Pressure(), ps.Gnss(), ps.Battery())
    with ps.open(sim_device, cfg) as dev:

        def got() -> bool:
            return (
                dev.mag.latest() is not None
                and dev.pressure.latest() is not None
                and dev.gnss.latest() is not None
                and dev.battery.latest() is not None
            )

        _wait_until(got, timeout=3.0)


def test_parameters_rate_clamp_and_readonly_name(sim_device: str) -> None:
    with ps.open(sim_device, _cfg()) as dev:
        topic = channel_topic("color_image", dev.info.name)
        time.sleep(0.3)
        fast = _count_topic(dev, topic, 1.0)
        assert fast >= 8
        dev.set_rate(Stream.COLOR, 5.0)
        time.sleep(0.4)
        slow = _count_topic(dev, topic, 1.2)
        assert 3 <= slow <= 9
        high = dev.set_rate(Stream.COLOR, 999.0)
        assert high["color.rate"] == pytest.approx(60.0)
        low = dev.set_rate(Stream.COLOR, 0.0)
        assert low["color.rate"] == pytest.approx(1.0)
        assert dev._client is not None
        replied = dev._client.set_parameters({"device.name": "hacked"})
        assert replied["device.name"] == "pocketsensor"
        got = dev._client.get_parameters(["device.name"])
        assert got["device.name"] == "pocketsensor"


def test_calibration_latched_after_sim_started(sim_device: str) -> None:
    with ps.open(sim_device, _cfg()) as dev:
        assert dev.info.model
        name = dev.info.name
        link = f"{name}_link"
        optical = f"{name}_color_optical_frame"
        actual = dev.calibration.extrinsics(optical, link)
        expected_r = quat_to_matrix(rpy_to_quaternion(*LINK_TO_COLOR_OPTICAL_RPY))
        np.testing.assert_allclose(actual[:3, :3], expected_r, atol=1e-6)
        np.testing.assert_allclose(actual[:3, 3], 0.0, atol=1e-9)
        # ストリームでの指定は device_info の frames を引く。IMU の並進は未測定なので NaN で返る。
        by_stream = dev.calibration.extrinsics(ps.Stream.COLOR, ps.Stream.POSE)
        np.testing.assert_allclose(by_stream, actual, atol=1e-9)
        to_imu = dev.calibration.extrinsics(ps.Stream.POSE, ps.Stream.IMU)
        assert np.isnan(to_imu[:3, 3]).all()
        assert set(dev.info.streams) >= {"odom", "imu_raw", "depth_confidence", "depth_image_compressed"}


def test_clock_ready_offset_host_latency(sim_device: str) -> None:
    with ps.open(sim_device, _cfg()) as dev:
        _wait_until(lambda: dev.clock.ready, timeout=3.0)
        assert abs(dev._wall_est.offset_ns) < 2_000_000
        hosts: list[int] = []
        for _ in range(5):
            frames = dev.wait_for_frames(timeout=3.0)
            hosts.append(frames.timestamp(ps.TimeDomain.HOST))
            assert 0 < frames.latency_ns < 100_000_000
        assert hosts == sorted(hosts)
        assert hosts[0] < hosts[-1]


def test_record_playback_and_info_cli(sim_device: str, tmp_path: Path) -> None:
    path = tmp_path / "run.mcap"
    with ps.open(sim_device, _cfg()) as dev:
        name = dev.info.name
        with dev.record(path):
            time.sleep(3.0)
    with path.open("rb") as handle:
        reader = make_reader(handle)
        metadata = {item.name: dict(item.metadata) for item in reader.iter_metadata()}
        counts: Counter[str] = Counter()
        for _schema, channel, _msg in reader.iter_messages():
            counts[channel.topic] += 1
    assert "pocketsensor.device_info" in metadata
    assert "pocketsensor.clock_samples" in metadata
    camera_topics = [
        channel_topic("color_image", name),
        channel_topic("depth_image_compressed", name),
        channel_topic("depth_confidence_compressed", name),
        channel_topic("odom", name),
    ]
    slowest = min(counts[topic] for topic in camera_topics)

    def _first_and_count() -> tuple[ps.FrameSet, int]:
        n_sets = 0
        first: ps.FrameSet | None = None
        with ps.open(str(path), _cfg(), realtime=False) as play:
            while True:
                try:
                    frames = play.wait_for_frames(timeout=2.0)
                except EOFError:
                    break
                n_sets += 1
                if first is None:
                    first = frames
        assert first is not None
        return first, n_sets

    first, n_sets = _first_and_count()
    again, n_again = _first_and_count()
    assert n_sets == slowest
    assert n_again == n_sets
    assert first.pose is not None
    assert again.pose is not None
    np.testing.assert_allclose(first.pose.position, again.pose.position)
    np.testing.assert_allclose(first.pose.orientation_xyzw, again.pose.orientation_xyzw)
    assert first.pose.frame_id == again.pose.frame_id
    assert cli_main(["info", str(path)]) == 0


def test_custom_name_changes_topics_and_frames(named_sim_device: str) -> None:
    with ps.open(named_sim_device, _cfg()) as dev:
        assert dev.info.name == "robot1"
        frames = dev.wait_for_frames(timeout=5.0)
        assert frames.pose is not None
        assert frames.pose.frame_id == "robot1_odom"
        assert frames.pose.child_frame_id == "robot1_link"
        assert frames.color is not None
        assert frames.color.frame_id == "robot1_color_optical_frame"
        assert "/robot1/color/image/compressed" in dev.stats.received_messages


def test_two_clients_different_streams(sim_device: str) -> None:
    cfg_cam = ps.Config(
        streams=(ps.Color(rate=15), ps.Depth(rate=15), ps.Pose()),
        open_timeout=10.0,
    )
    cfg_imu = ps.Config(streams=(ps.Imu(rate=100, raw=True), ps.Mag()), open_timeout=10.0)
    with ps.open(sim_device, cfg_cam) as cam, ps.open(sim_device, cfg_imu) as imu:
        frames = cam.wait_for_frames(timeout=5.0)
        assert frames.color is not None
        assert frames.depth is not None
        assert frames.pose is not None
        imu.imu.read_all()
        time.sleep(0.5)
        samples = imu.imu.read_all()
        assert len(samples) >= 30
        mag = imu.mag.read_all()
        assert mag

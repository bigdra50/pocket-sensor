from __future__ import annotations

import math
import time

import numpy as np
import pytest

import pocketsensor as ps
from pocketsensor.streams import Stream
from pocketsensor.testing.fake_device import FakeDevice


def _live_config(**kwargs) -> ps.Config:
    streams = kwargs.pop(
        "streams",
        (
            ps.Color(rate=15, width=32, jpeg_quality=0.4),
            ps.Depth(rate=15),
            ps.Pose(rate=30),
            ps.Imu(rate=100),
        ),
    )
    open_timeout = kwargs.pop("open_timeout", 5.0)
    return ps.Config(streams=streams, open_timeout=open_timeout, **kwargs)


def _wait_until(pred, timeout: float, interval: float = 0.02) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if pred():
            return
        time.sleep(min(interval, deadline - time.monotonic()))
    raise AssertionError("deadline exceeded")


def test_open_close_and_shared_timestamps() -> None:
    with FakeDevice(port=0, seed=0) as fake:
        with ps.open(fake.url, _live_config()) as dev:
            assert dev.info.name == "pocketsensor"
            assert dev.info.model == "FakeDevice"
            frames = dev.wait_for_frames(timeout=2.0)
            assert frames.color is not None
            assert frames.depth is not None
            assert frames.pose is not None
            assert frames.tracking is not None
            assert frames.t_device_ns > 0
            radius = math.hypot(float(frames.pose.position[0]), float(frames.pose.position[1]))
            assert radius == pytest.approx(1.0, abs=0.05)
            k = dev.calibration.intrinsics(Stream.DEPTH)
            assert k.width == 256
            assert k.height == 192


def test_require_all_vs_any_with_dropped_members() -> None:
    with FakeDevice(port=0, seed=0) as fake:
        fake.drop_members({"depth_image", "depth_confidence"})
        cfg_all = _live_config(frame_policy=ps.FramePolicy.REQUIRE_ALL)
        with ps.open(fake.url, cfg_all) as dev:
            with pytest.raises(TimeoutError):
                dev.wait_for_frames(timeout=0.4)
        cfg_any = _live_config(frame_policy=ps.FramePolicy.ANY)
        with ps.open(fake.url, cfg_any) as dev:
            frames = dev.wait_for_frames(timeout=2.0)
            assert frames.depth is None
            assert frames.color is not None or frames.pose is not None


def test_imu_read_all_preserves_order_without_loss() -> None:
    with FakeDevice(port=0, seed=0) as fake:
        with ps.open(fake.url, _live_config()) as dev:
            dev.imu.read_all()
            deadline = time.monotonic() + 1.0
            while time.monotonic() < deadline:
                time.sleep(min(0.05, max(0.0, deadline - time.monotonic())))
            samples = dev.imu.read_all()
            assert len(samples) >= 90
            times = [s.t_device_ns for s in samples]
            assert times == sorted(times)
            assert len(set(times)) == len(times)


def test_set_rate_changes_observed_rate() -> None:
    with FakeDevice(port=0, seed=0) as fake:
        with ps.open(fake.url, _live_config()) as dev:
            topic = "/pocketsensor/odom"

            def count_for(seconds: float) -> int:
                start = time.monotonic()
                n0 = dev.stats.received_messages.get(topic, 0)
                while time.monotonic() - start < seconds:
                    time.sleep(0.02)
                return dev.stats.received_messages.get(topic, 0) - n0

            fast = count_for(0.45)
            dev.set_rate(Stream.POSE, 10.0)
            time.sleep(0.05)
            slow = count_for(0.45)
            assert fast > 0
            assert slow < fast
            assert slow <= 8


def test_unsupported_missing_channel() -> None:
    with FakeDevice(port=0, streams={Stream.POSE}, seed=0) as fake:
        cfg = ps.Config(streams=(ps.Color(),), open_timeout=3.0)
        with pytest.raises(ps.Unsupported):
            ps.open(fake.url, cfg)


def test_timeout_and_connection_lost() -> None:
    with FakeDevice(port=0, seed=0) as fake:
        with ps.open(fake.url, _live_config()) as dev:
            try:
                dev.wait_for_frames(timeout=0.5)
            except TimeoutError:
                pass
            fake.stall(5.0)
            # stall の前に送り出された分は遅れて届く。届き終わるまで読み捨ててから、止まったことを確かめる。
            quiet_by = time.monotonic() + 2.0
            while True:
                try:
                    dev.wait_for_frames(timeout=0.2)
                except TimeoutError:
                    break
                assert time.monotonic() < quiet_by, "frames kept arriving while the device was stalled"
            with pytest.raises(TimeoutError):
                dev.wait_for_frames(timeout=0.3)
            fake.stall(0.0)
            fake.close_abruptly()
            deadline = time.monotonic() + 2.0
            with pytest.raises(ps.ConnectionLost):
                while time.monotonic() < deadline:
                    try:
                        dev.wait_for_frames(timeout=0.1)
                    except TimeoutError:
                        continue
                raise AssertionError("connection still up")


def test_clock_estimate_and_host_timestamps() -> None:
    offset = 2_000_000
    fake = FakeDevice(port=0, seed=0)
    fake.clock_offset_ns = offset
    with fake:
        with ps.open(fake.url, _live_config()) as dev:

            def converged() -> bool:
                if not dev.clock.ready:
                    return False
                if dev.clock.rtt_ns < 2_000_000:
                    return True
                return dev.clock.sample_count >= 8

            _wait_until(converged, timeout=10.0)
            assert abs(dev.clock.offset_ns - fake.expected_offset_ns) < 1_000_000
            hosts: list[int] = []
            for _ in range(4):
                frames = dev.wait_for_frames(timeout=2.0)
                hosts.append(frames.timestamp(ps.TimeDomain.HOST))
                latency = frames.latency_ns
                assert latency > 0
                assert latency < 200_000_000
            assert hosts == sorted(hosts)
            assert hosts[0] < hosts[-1]


def test_intrinsics_available_immediately_after_open() -> None:
    fake = FakeDevice(port=0, seed=0)
    fake.distortion_model = "rational_polynomial"
    fake.distortion = (0.1, -0.2, 0.01, -0.02, 0.3)
    with fake:
        with ps.open(fake.url, _live_config()) as dev:
            color_k = dev.calibration.intrinsics(ps.Stream.COLOR)
            depth_k = dev.calibration.intrinsics(ps.Stream.DEPTH)
            assert color_k.width > 0
            assert depth_k.width == 256
            assert depth_k.height == 192
            assert color_k.distortion_model == "rational_polynomial"
            assert color_k.distortion == (0.1, -0.2, 0.01, -0.02, 0.3)
            assert depth_k.distortion_model == "rational_polynomial"
            assert depth_k.distortion == (0.1, -0.2, 0.01, -0.02, 0.3)
            frames = dev.wait_for_frames(timeout=2.0)
            assert frames.color is not None
            assert frames.color.intrinsics.distortion_model == "rational_polynomial"
            assert frames.color.intrinsics.distortion == (0.1, -0.2, 0.01, -0.02, 0.3)


def test_intrinsics_unsupported_when_device_has_no_camera() -> None:
    with FakeDevice(port=0, streams={Stream.POSE}, seed=0) as fake:
        cfg = ps.Config(streams=(ps.Pose(),), open_timeout=3.0)
        started = time.monotonic()
        with ps.open(fake.url, cfg) as dev:
            assert time.monotonic() - started < 1.0
            with pytest.raises(ps.Unsupported):
                dev.calibration.intrinsics(ps.Stream.DEPTH)


def test_open_raises_when_camera_info_never_arrives() -> None:
    with FakeDevice(port=0, seed=0) as fake:
        fake.drop_members({"depth_camera_info"})
        cfg = _live_config(open_timeout=0.4)
        started = time.monotonic()
        with pytest.raises(ps.ProtocolError, match="camera_info"):
            ps.open(fake.url, cfg)
        assert time.monotonic() - started < 1.5


def test_connection_failed_nothing_listening() -> None:
    cfg = ps.Config(streams=(ps.Pose(),), open_timeout=1.0)
    with pytest.raises(ps.ConnectionFailed):
        ps.open("ws://127.0.0.1:9", cfg)


def test_stats_count_drops_when_consumer_is_slow() -> None:
    with FakeDevice(port=0, seed=0) as fake:
        with ps.open(fake.url, _live_config()) as dev:
            _wait_until(lambda: dev.stats.dropped_framesets > 0, timeout=2.0)
            assert dev.stats.dropped_framesets > 0
            frames = dev.wait_for_frames(timeout=2.0)
            assert frames.t_device_ns > 0
            assert np.isnan(dev.calibration.raw["imu"]["noise_density"])

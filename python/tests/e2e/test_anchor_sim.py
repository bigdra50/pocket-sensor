from __future__ import annotations

import time

import numpy as np
import pytest

import pocketsensor as ps

pytestmark = pytest.mark.e2e

_IDENTITY = np.array([0.0, 0.0, 0.0, 1.0], dtype=np.float64)


def _wait_until(pred, timeout: float, interval: float = 0.02) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if pred():
            return
        time.sleep(min(interval, max(0.0, deadline - time.monotonic())))
    raise AssertionError("deadline exceeded")


def test_anchors_report_frames_and_rep103_positions(anchor_sim_device: str) -> None:
    cfg = ps.Config(streams=(ps.Pose(), ps.Anchors()), open_timeout=10.0)
    with ps.open(anchor_sim_device, cfg) as dev:

        def both() -> bool:
            latest = dev.anchors.latest()
            return "dock" in latest and "door" in latest

        _wait_until(both, timeout=2.0)
        latest = dev.anchors.latest()
        dock = latest["dock"]
        door = latest["door"]
        assert dock.frame_id == "pocketsensor_odom"
        assert door.frame_id == "pocketsensor_odom"
        assert dock.child_frame_id == "pocketsensor_anchor_dock"
        assert door.child_frame_id == "pocketsensor_anchor_door"
        np.testing.assert_allclose(dock.position, [2.0, 0.0, 1.0], atol=1e-6)
        np.testing.assert_allclose(door.position, [2.0, -0.5, 1.0], atol=1e-6)
        np.testing.assert_allclose(dock.orientation_xyzw, _IDENTITY, atol=1e-6)
        np.testing.assert_allclose(door.orientation_xyzw, _IDENTITY, atol=1e-6)


def test_anchors_without_pose_stream(anchor_sim_device: str) -> None:
    cfg = ps.Config(streams=(ps.Anchors(),), open_timeout=10.0)
    with ps.open(anchor_sim_device, cfg) as dev:
        _wait_until(lambda: set(dev.anchors.latest()) >= {"dock", "door"}, timeout=2.0)


def test_default_sim_has_no_anchors(sim_device: str) -> None:
    cfg = ps.Config(streams=(ps.Anchors(),), open_timeout=10.0)
    with ps.open(sim_device, cfg) as dev:
        time.sleep(1.0)
        assert dev.anchors.latest() == {}


def test_anchor_stamps_are_pose_stamps_and_the_pose_rides_first(anchor_sim_device: str) -> None:
    cfg = ps.Config(streams=(ps.Pose(rate=30), ps.Anchors()), open_timeout=10.0)
    with ps.open(anchor_sim_device, cfg) as dev:
        odom_stamps: set[int] = set()
        anchor_stamps: set[int] = set()
        deadline = time.monotonic() + 2.0
        for topic, t_ns, msg in dev.messages(["/tf", "/pocketsensor/odom"]):
            if topic == "/pocketsensor/odom":
                odom_stamps.add(t_ns)
            else:
                children = [str(tf.child_frame_id) for tf in msg.transforms]
                # 姿勢の変換が先頭にあり、anchor はその後ろへ載る。
                assert children[0] == "pocketsensor_link"
                if len(children) > 1:
                    anchor_stamps.add(t_ns)
            if time.monotonic() >= deadline:
                break
        assert len(anchor_stamps) >= 3
        # 最後の anchor と同じ回の odom が、締め切りの後に届くことがある。
        assert len(anchor_stamps - odom_stamps) <= 1

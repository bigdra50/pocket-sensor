from __future__ import annotations

import time
from pathlib import Path

import numpy as np
import pytest

import pocketsensor as ps
from pocketsensor.decode import decode_anchors
from pocketsensor.streams import CAMERA_STREAMS, Anchors, Stream
from pocketsensor.testing.fake_device import FakeDevice


def _wait_until(pred, timeout: float, interval: float = 0.02) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if pred():
            return
        time.sleep(min(interval, max(0.0, deadline - time.monotonic())))
    raise AssertionError("deadline exceeded")


def _stamp(t_ns: int) -> dict[str, int]:
    return {"sec": int(t_ns // 1_000_000_000), "nanosec": int(t_ns % 1_000_000_000)}


def _transform(
    frame_id: str,
    child: str,
    t_ns: int,
    pos: tuple[float, float, float],
    quat: tuple[float, float, float, float],
) -> dict:
    return {
        "header": {"stamp": _stamp(t_ns), "frame_id": frame_id},
        "child_frame_id": child,
        "transform": {
            "translation": {"x": pos[0], "y": pos[1], "z": pos[2]},
            "rotation": {"x": quat[0], "y": quat[1], "z": quat[2], "w": quat[3]},
        },
    }


def _cfg(*extra: object, **kwargs) -> ps.Config:
    streams = (ps.Pose(), *extra)
    return ps.Config(streams=streams, open_timeout=kwargs.pop("open_timeout", 5.0), **kwargs)


_YAW_90 = (0.0, 0.0, 0.7071067811865476, 0.7071067811865476)


def test_anchors_stream_is_not_a_camera_stream() -> None:
    spec = Anchors()
    assert spec.stream is Stream.ANCHORS
    assert spec.channel_keys() == ("tf",)
    assert spec.parameters() == {}
    assert Stream.ANCHORS not in CAMERA_STREAMS
    assert Stream.ANCHORS not in ps.Config(streams=(Anchors(),)).required_camera_streams()


def test_decode_anchors_selection_rules(codec) -> None:
    t_ns = 1_000_000_007
    msg = codec.make(
        "tf2_msgs/msg/TFMessage",
        transforms=[
            _transform("pocketsensor_odom", "pocketsensor_link", t_ns, (0.1, 0.2, 0.3), (0.0, 0.0, 0.0, 1.0)),
            _transform(
                "pocketsensor_odom",
                "pocketsensor_anchor_dock",
                t_ns,
                (2.0, 0.0, 1.0),
                (0.0, 0.0, 0.0, 1.0),
            ),
            _transform("other_odom", "other_anchor_dock", t_ns, (9.0, 9.0, 9.0), (0.0, 0.0, 0.0, 1.0)),
            _transform(
                "pocketsensor_odom",
                "pocketsensor_anchor_",
                t_ns,
                (0.0, 0.0, 0.0),
                (0.0, 0.0, 0.0, 1.0),
            ),
            _transform(
                "pocketsensor_odom",
                "pocketsensor_anchor_door",
                t_ns + 1,
                (2.0, -0.5, 1.0),
                _YAW_90,
            ),
        ],
    )
    samples = decode_anchors(msg, "pocketsensor")
    assert [s.name for s in samples] == ["dock", "door"]
    assert samples[0].t_device_ns == t_ns
    assert samples[0].frame_id == "pocketsensor_odom"
    assert samples[0].child_frame_id == "pocketsensor_anchor_dock"
    np.testing.assert_allclose(samples[0].position, [2.0, 0.0, 1.0])
    np.testing.assert_allclose(samples[0].orientation_xyzw, [0.0, 0.0, 0.0, 1.0])
    assert samples[1].t_device_ns == t_ns + 1
    assert samples[1].child_frame_id == "pocketsensor_anchor_door"
    np.testing.assert_allclose(samples[1].position, [2.0, -0.5, 1.0])
    # 四元数の符号は端末が揃えて送る。クライアントは姿勢と同じく、届いた値をそのまま返す。
    np.testing.assert_allclose(samples[1].orientation_xyzw, _YAW_90)


def test_device_anchors_appear_update_age_and_reset() -> None:
    with FakeDevice(port=0, streams={Stream.POSE, Stream.ANCHORS}, seed=0) as fake:
        fake.anchors = {"dock": ([1.0, 2.0, 3.0], [0.0, 0.0, 0.0, 1.0])}
        with ps.open(fake.url, _cfg(ps.Anchors())) as dev:
            _wait_until(lambda: "dock" in dev.anchors.latest(), timeout=1.5)
            sample = dev.anchors.latest()["dock"]
            assert sample.name == "dock"
            assert sample.frame_id == "pocketsensor_odom"
            assert sample.child_frame_id == "pocketsensor_anchor_dock"
            np.testing.assert_allclose(sample.position, [1.0, 2.0, 3.0])
            np.testing.assert_allclose(sample.orientation_xyzw, [0.0, 0.0, 0.0, 1.0])
            copied = dev.anchors.latest()
            copied.clear()
            assert "dock" in dev.anchors.latest()

            stamps: set[int] = set()
            deadline = time.monotonic() + 1.6
            while time.monotonic() < deadline:
                latest = dev.anchors.latest(max_age_s=None)
                if "dock" in latest:
                    stamps.add(latest["dock"].t_device_ns)
                time.sleep(0.05)
            assert 2 <= len(stamps) <= 5

            fake.anchors = {}
            time.sleep(0.85)
            assert dev.anchors.latest(max_age_s=0.6) == {}
            assert "dock" in dev.anchors.latest(max_age_s=None)

            fake.stall(5.0)
            time.sleep(0.3)
            ok, _message = dev.reset_origin()
            assert ok
            assert dev.anchors.latest(max_age_s=None) == {}
            fake.stall(0.0)


def test_anchors_accessor_requires_stream() -> None:
    with FakeDevice(port=0, streams={Stream.POSE}, seed=0) as fake:
        with ps.open(fake.url, _cfg()) as dev:
            with pytest.raises(ps.Unsupported):
                _ = dev.anchors


def test_pose_and_anchors_subscribe_tf_once() -> None:
    with FakeDevice(port=0, streams={Stream.POSE, Stream.ANCHORS}, seed=0) as fake:
        with ps.open(fake.url, _cfg(ps.Anchors())) as dev:
            _wait_until(lambda: fake._clients, timeout=1.0)
            tf_id = fake._by_key["tf"].id
            with fake._clients_lock:
                clients = list(fake._clients)
            assert len(clients) == 1
            tf_subs = [sub_id for sub_id, channel_id in clients[0].subs.items() if channel_id == tf_id]
            assert len(tf_subs) == 1
            assert dev._client is not None
            assert list(dev._client._topic_sub).count("/tf") == 1


def test_anchors_without_pose_stream() -> None:
    with FakeDevice(port=0, streams={Stream.ANCHORS}, seed=0) as fake:
        fake.anchors = {"dock": ([0.5, 0.0, 0.0], [0.0, 0.0, 0.0, 1.0])}
        cfg = ps.Config(streams=(ps.Anchors(),), open_timeout=5.0)
        started = time.monotonic()
        with ps.open(fake.url, cfg) as dev:
            assert time.monotonic() - started < 1.5
            _wait_until(lambda: "dock" in dev.anchors.latest(), timeout=1.5)
            ok, _message = dev.reset_origin()
            assert ok
            assert dev.anchors.latest(max_age_s=None) == {}


def test_record_playback_roundtrip_anchors(tmp_path: Path) -> None:
    path = tmp_path / "anchors.mcap"
    with FakeDevice(port=0, streams={Stream.POSE, Stream.ANCHORS}, seed=0) as fake:
        fake.anchors = {"dock": ([2.0, 0.0, 1.0], [0.0, 0.0, 0.0, 1.0])}
        with ps.open(fake.url, _cfg(ps.Anchors())) as dev:
            _wait_until(lambda: "dock" in dev.anchors.latest(max_age_s=None), timeout=1.5)
            with dev.record(path):
                deadline = time.monotonic() + 0.8
                while time.monotonic() < deadline:
                    try:
                        dev.wait_for_frames(timeout=0.2)
                    except TimeoutError:
                        pass
    with ps.open(str(path), _cfg(ps.Anchors()), realtime=False) as play:
        while True:
            try:
                play.wait_for_frames(timeout=2.0)
            except EOFError:
                break
        latest = play.anchors.latest(max_age_s=None)
        assert "dock" in latest
        np.testing.assert_allclose(latest["dock"].position, [2.0, 0.0, 1.0])
        assert latest["dock"].child_frame_id == "pocketsensor_anchor_dock"

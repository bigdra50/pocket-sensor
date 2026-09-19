from __future__ import annotations

import io
from types import SimpleNamespace

import numpy as np
import pytest
from PIL import Image

from pocketsensor.cdr import CdrCodec
from pocketsensor.decode import (
    decode_battery,
    decode_camera_info,
    decode_color,
    decode_confidence,
    decode_depth,
    decode_imu,
    decode_jpeg,
    decode_pose,
    stamp_to_ns,
)
from pocketsensor.errors import Unsupported
from pocketsensor.intrinsics import Intrinsics


def _stamp(sec: int, nanosec: int) -> SimpleNamespace:
    return SimpleNamespace(sec=sec, nanosec=nanosec)


def test_stamp_to_ns() -> None:
    assert stamp_to_ns(_stamp(1, 2)) == 1_000_000_002


def test_decode_16uc1_honours_step_and_little_endian(codec: CdrCodec) -> None:
    # 2x2 だが step は 8 バイト（行末に 4 バイトの詰め）。値は 1, 256 / 2, 3
    row0 = bytes([1, 0, 0, 1, 9, 9, 9, 9])
    row1 = bytes([2, 0, 3, 0, 8, 8, 8, 8])
    msg = codec.make(
        "sensor_msgs/msg/Image",
        header={"stamp": {"sec": 1, "nanosec": 0}, "frame_id": "optical"},
        height=2,
        width=2,
        encoding="16UC1",
        is_bigendian=0,
        step=8,
        data=row0 + row1,
    )
    k = Intrinsics(2, 2, 1.0, 1.0, 0.5, 0.5)
    frame = decode_depth(msg, k)
    assert frame.raw.dtype == np.uint16
    assert frame.raw.shape == (2, 2)
    assert frame.raw[0, 0] == 1
    assert frame.raw[0, 1] == 256
    assert frame.raw[1, 0] == 2
    assert frame.raw[1, 1] == 3
    assert frame.frame_id == "optical"


def test_decode_16uc1_bigendian(codec: CdrCodec) -> None:
    data = bytes([0x01, 0x02, 0x03, 0x04])
    msg = codec.make(
        "sensor_msgs/msg/Image",
        header={"stamp": {"sec": 0, "nanosec": 0}, "frame_id": "f"},
        height=1,
        width=2,
        encoding="16UC1",
        is_bigendian=1,
        step=4,
        data=data,
    )
    frame = decode_depth(msg, Intrinsics(2, 1, 1.0, 1.0, 0.0, 0.0))
    assert frame.raw[0, 0] == 0x0102
    assert frame.raw[0, 1] == 0x0304


def test_depth_meters_maps_zero_to_nan_and_caches() -> None:
    raw = np.array([[0, 1000], [2000, 0]], dtype=np.uint16)
    from pocketsensor.types import DepthFrame

    frame = DepthFrame(raw=raw, intrinsics=Intrinsics(2, 2, 1.0, 1.0, 0.5, 0.5), frame_id="f")
    metres = frame.meters
    assert metres.dtype == np.float32
    assert np.isnan(metres[0, 0])
    assert metres[0, 1] == pytest.approx(1.0)
    assert metres[1, 0] == pytest.approx(2.0)
    assert np.isnan(metres[1, 1])
    assert frame.meters is metres


def test_decode_mono8_honours_step(codec: CdrCodec) -> None:
    data = bytes([2, 1, 9, 0, 1, 8])
    msg = codec.make(
        "sensor_msgs/msg/Image",
        header={"stamp": {"sec": 0, "nanosec": 0}, "frame_id": "f"},
        height=2,
        width=2,
        encoding="mono8",
        is_bigendian=0,
        step=3,
        data=data,
    )
    conf = decode_confidence(msg)
    assert conf.levels.shape == (2, 2)
    assert conf.levels[0, 0] == 2
    assert conf.levels[0, 1] == 1
    assert conf.levels[1, 0] == 0
    assert conf.levels[1, 1] == 1


def test_jpeg_plugin_prefers_simplejpeg(monkeypatch: pytest.MonkeyPatch) -> None:
    class FakeSimple:
        @staticmethod
        def decode_jpeg(data: bytes, colorspace: str = "RGB") -> np.ndarray:
            assert colorspace == "RGB"
            return np.full((1, 1, 3), 7, dtype=np.uint8)

    def fake_import(name: str):
        if name == "simplejpeg":
            return FakeSimple
        raise AssertionError(name)

    monkeypatch.setattr("pocketsensor.decode._import_optional", fake_import)
    out = decode_jpeg(b"unused")
    assert out[0, 0, 0] == 7


def test_jpeg_plugin_falls_back_to_cv2(monkeypatch: pytest.MonkeyPatch) -> None:
    class FakeCv2:
        IMREAD_COLOR = 1
        COLOR_BGR2RGB = 4

        @staticmethod
        def imdecode(buf: np.ndarray, flags: int) -> np.ndarray:
            return np.array([[[0, 1, 2]]], dtype=np.uint8)

        @staticmethod
        def cvtColor(img: np.ndarray, code: int) -> np.ndarray:
            return img[:, :, ::-1].copy()

    def fake_import(name: str):
        if name == "simplejpeg":
            return None
        if name == "cv2":
            return FakeCv2
        raise AssertionError(name)

    monkeypatch.setattr("pocketsensor.decode._import_optional", fake_import)
    out = decode_jpeg(b"unused")
    assert list(out[0, 0]) == [2, 1, 0]


def test_jpeg_plugin_falls_back_to_pil(monkeypatch: pytest.MonkeyPatch) -> None:
    calls: list[str] = []

    def fake_import(name: str):
        calls.append(name)
        if name in {"simplejpeg", "cv2"}:
            return None
        if name == "PIL.Image":
            return Image
        return None

    monkeypatch.setattr("pocketsensor.decode._import_optional", fake_import)
    buf = io.BytesIO()
    Image.fromarray(np.zeros((2, 3, 3), dtype=np.uint8), mode="RGB").save(buf, format="JPEG")
    out = decode_jpeg(buf.getvalue())
    assert out.shape == (2, 3, 3)
    assert calls[:3] == ["simplejpeg", "cv2", "PIL.Image"]


def test_jpeg_missing_decoder_raises_unsupported(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr("pocketsensor.decode._import_optional", lambda name: None)
    with pytest.raises(Unsupported, match=r"pocketsensor\[jpeg\]"):
        decode_jpeg(b"x")


def test_decode_camera_info_copies_distortion(codec: CdrCodec) -> None:
    msg = codec.make(
        "sensor_msgs/msg/CameraInfo",
        header={"stamp": {"sec": 0, "nanosec": 0}, "frame_id": "optical"},
        height=3,
        width=4,
        distortion_model="rational_polynomial",
        d=[1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0],
        k=[10.0, 0.0, 2.0, 0.0, 11.0, 1.5, 0.0, 0.0, 1.0],
        r=[1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
        p=[10.0, 0.0, 2.0, 0.0, 0.0, 11.0, 1.5, 0.0, 0.0, 0.0, 1.0, 0.0],
    )
    k = decode_camera_info(msg)
    assert k.width == 4
    assert k.height == 3
    assert k.fx == pytest.approx(10.0)
    assert k.fy == pytest.approx(11.0)
    assert k.cx == pytest.approx(2.0)
    assert k.cy == pytest.approx(1.5)
    assert k.distortion_model == "rational_polynomial"
    assert k.distortion == (1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0)


def test_decode_color_can_skip_pixels(codec: CdrCodec, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr("pocketsensor.decode._import_optional", lambda name: None)
    jpeg = b"not-a-jpeg"
    msg = codec.make(
        "sensor_msgs/msg/CompressedImage",
        header={"stamp": {"sec": 0, "nanosec": 1}, "frame_id": "optical"},
        format="jpeg",
        data=jpeg,
    )
    k = Intrinsics(1, 1, 1.0, 1.0, 0.0, 0.0)
    frame = decode_color(msg, k, decode=False)
    assert frame.image is None
    assert frame.jpeg == jpeg
    with pytest.raises(Unsupported):
        decode_color(msg, k, decode=True)


def test_decode_imu_hides_orientation_when_covariance_unset(codec: CdrCodec) -> None:
    cov = [-1.0] + [0.0] * 8
    msg = codec.make(
        "sensor_msgs/msg/Imu",
        header={"stamp": {"sec": 2, "nanosec": 5}, "frame_id": "imu"},
        orientation={"x": 0.0, "y": 0.0, "z": 0.0, "w": 1.0},
        orientation_covariance=cov,
        angular_velocity={"x": 0.1, "y": 0.2, "z": 0.3},
        linear_acceleration={"x": 1.0, "y": 2.0, "z": 3.0},
    )
    sample = decode_imu(msg, arrival_ns=9)
    assert sample.t_device_ns == stamp_to_ns(msg.header.stamp)
    assert sample.arrival_ns == 9
    assert sample.orientation_xyzw is None
    assert sample.angular_velocity.tolist() == pytest.approx([0.1, 0.2, 0.3])


def test_decode_pose_and_battery(codec: CdrCodec) -> None:
    odom = codec.make(
        "nav_msgs/msg/Odometry",
        header={"stamp": {"sec": 0, "nanosec": 0}, "frame_id": "odom"},
        child_frame_id="link",
        pose={
            "pose": {
                "position": {"x": 1.0, "y": 2.0, "z": 3.0},
                "orientation": {"x": 0.0, "y": 0.0, "z": 0.0, "w": 1.0},
            }
        },
    )
    pose = decode_pose(odom)
    assert pose.position.tolist() == pytest.approx([1.0, 2.0, 3.0])
    assert pose.frame_id == "odom"
    bat = codec.make(
        "sensor_msgs/msg/BatteryState",
        percentage=0.55,
        power_supply_status=2,
    )
    status = decode_battery(bat)
    assert status.percentage == pytest.approx(0.55)
    assert status.power_supply_status == 2

"""rosbags のメッセージから SDK の値型へ落とす。JPEG の実装は差し替えられる。"""

from __future__ import annotations

import importlib
import io
from typing import Any

import numpy as np
from numpy.typing import NDArray

from pocketsensor.errors import ProtocolError, Unsupported
from pocketsensor.intrinsics import Intrinsics
from pocketsensor.types import (
    AnchorSample,
    BatteryStatus,
    ColorFrame,
    ConfidenceFrame,
    DepthFrame,
    DeviceInfo,
    GnssFix,
    ImuSample,
    MagSample,
    PoseSample,
    PressureSample,
    TrackingStatus,
)


def _import_optional(name: str) -> Any:
    try:
        return importlib.import_module(name)
    except ImportError:
        return None


def stamp_to_ns(stamp: Any) -> int:
    return int(stamp.sec) * 1_000_000_000 + int(stamp.nanosec)


def _as_bytes(data: Any) -> bytes:
    if isinstance(data, (bytes, bytearray, memoryview)):
        return bytes(data)
    if isinstance(data, np.ndarray):
        return bytes(data.tobytes())
    return bytes(data)


def _vec3(msg: Any) -> NDArray[np.float64]:
    return np.array([msg.x, msg.y, msg.z], dtype=np.float64)


def _quat(msg: Any) -> NDArray[np.float64]:
    return np.array([msg.x, msg.y, msg.z, msg.w], dtype=np.float64)


def decode_jpeg(data: bytes) -> NDArray[np.uint8]:
    simplejpeg = _import_optional("simplejpeg")
    if simplejpeg is not None:
        return np.asarray(simplejpeg.decode_jpeg(data, colorspace="RGB"))
    cv2 = _import_optional("cv2")
    if cv2 is not None:
        buf = np.frombuffer(data, dtype=np.uint8)
        bgr = cv2.imdecode(buf, cv2.IMREAD_COLOR)
        if bgr is None:
            raise ProtocolError("cv2 failed to decode JPEG")
        return np.asarray(cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB))
    pil_image = _import_optional("PIL.Image")
    if pil_image is not None:
        image = pil_image.open(io.BytesIO(data))
        return np.asarray(image.convert("RGB"))
    raise Unsupported("JPEG decoding requires simplejpeg, OpenCV, or Pillow. pip install pocketsensor[jpeg]")


def decode_image_u16(msg: Any) -> NDArray[np.uint16]:
    height = int(msg.height)
    width = int(msg.width)
    step = int(msg.step)
    raw = _as_bytes(msg.data)
    expected = height * step
    if len(raw) < expected:
        raise ProtocolError(f"image data shorter than height*step: {len(raw)} < {expected}")
    dt = ">u2" if int(msg.is_bigendian) else "<u2"
    out = np.empty((height, width), dtype=np.uint16)
    for row in range(height):
        offset = row * step
        out[row] = np.frombuffer(raw, dtype=dt, count=width, offset=offset)
    return out


def decode_image_u8(msg: Any) -> NDArray[np.uint8]:
    height = int(msg.height)
    width = int(msg.width)
    step = int(msg.step)
    raw = _as_bytes(msg.data)
    expected = height * step
    if len(raw) < expected:
        raise ProtocolError(f"image data shorter than height*step: {len(raw)} < {expected}")
    out = np.empty((height, width), dtype=np.uint8)
    for row in range(height):
        offset = row * step
        out[row] = np.frombuffer(raw, dtype=np.uint8, count=width, offset=offset)
    return out


def decode_camera_info(msg: Any) -> Intrinsics:
    k = np.asarray(msg.k, dtype=np.float64).reshape(9)
    distortion = tuple(float(v) for v in np.asarray(msg.d, dtype=np.float64).reshape(-1))
    return Intrinsics(
        width=int(msg.width),
        height=int(msg.height),
        fx=float(k[0]),
        fy=float(k[4]),
        cx=float(k[2]),
        cy=float(k[5]),
        distortion_model=str(msg.distortion_model),
        distortion=distortion,
    )


def decode_color(msg: Any, intrinsics: Intrinsics, decode: bool = True) -> ColorFrame:
    jpeg = _as_bytes(msg.data)
    image = decode_jpeg(jpeg) if decode else None
    return ColorFrame(image=image, jpeg=jpeg, intrinsics=intrinsics, frame_id=str(msg.header.frame_id))


def decode_depth(msg: Any, intrinsics: Intrinsics) -> DepthFrame:
    return DepthFrame(raw=decode_image_u16(msg), intrinsics=intrinsics, frame_id=str(msg.header.frame_id))


def decode_confidence(msg: Any) -> ConfidenceFrame:
    return ConfidenceFrame(levels=decode_image_u8(msg))


def decode_pose(msg: Any) -> PoseSample:
    pose = msg.pose.pose
    return PoseSample(
        position=_vec3(pose.position),
        orientation_xyzw=_quat(pose.orientation),
        frame_id=str(msg.header.frame_id),
        child_frame_id=str(msg.child_frame_id),
        covariance=np.asarray(msg.pose.covariance, dtype=np.float64).reshape(36).copy(),
    )


def decode_anchors(tf_msg: Any, device_name: str) -> list[AnchorSample]:
    """TFMessage から、この端末の参照画像 anchor だけを拾う。順序はメッセージのとおり。"""
    prefix = f"{device_name}_anchor_"
    parent = f"{device_name}_odom"
    out: list[AnchorSample] = []
    for tf in tf_msg.transforms:
        if str(tf.header.frame_id) != parent:
            continue
        child = str(tf.child_frame_id)
        if not child.startswith(prefix):
            continue
        name = child[len(prefix) :]
        if not name:
            continue
        out.append(
            AnchorSample(
                name=name,
                t_device_ns=stamp_to_ns(tf.header.stamp),
                position=_vec3(tf.transform.translation),
                # 符号は端末が揃えて送る（w >= 0）。姿勢と同じく、受け手では作り変えない。
                orientation_xyzw=_quat(tf.transform.rotation),
                frame_id=parent,
                child_frame_id=child,
            )
        )
    return out


def decode_tracking(msg: Any) -> TrackingStatus:
    return TrackingStatus(state=int(msg.state), reason=int(msg.reason), origin_epoch=int(msg.origin_epoch))


def decode_imu(msg: Any, arrival_ns: int) -> ImuSample:
    cov0 = float(np.asarray(msg.orientation_covariance).reshape(9)[0])
    orientation = None if cov0 == -1.0 else _quat(msg.orientation)
    return ImuSample(
        t_device_ns=stamp_to_ns(msg.header.stamp),
        arrival_ns=int(arrival_ns),
        angular_velocity=_vec3(msg.angular_velocity),
        linear_acceleration=_vec3(msg.linear_acceleration),
        orientation_xyzw=orientation,
    )


def decode_mag(msg: Any, arrival_ns: int) -> MagSample:
    return MagSample(
        t_device_ns=stamp_to_ns(msg.header.stamp),
        arrival_ns=int(arrival_ns),
        field=_vec3(msg.magnetic_field),
        covariance=np.asarray(msg.magnetic_field_covariance, dtype=np.float64).reshape(9).copy(),
    )


def decode_pressure(msg: Any, arrival_ns: int) -> PressureSample:
    return PressureSample(
        t_device_ns=stamp_to_ns(msg.header.stamp),
        arrival_ns=int(arrival_ns),
        pascal=float(msg.fluid_pressure),
        variance=float(msg.variance),
    )


def decode_gnss(msg: Any, arrival_ns: int, time_ref_ns: int | None = None) -> GnssFix:
    return GnssFix(
        lat=float(msg.latitude),
        lon=float(msg.longitude),
        alt=float(msg.altitude),
        covariance9=np.asarray(msg.position_covariance, dtype=np.float64).reshape(9).copy(),
        status=int(msg.status.status),
        service=int(msg.status.service),
        time_ref_ns=time_ref_ns,
        t_device_ns=stamp_to_ns(msg.header.stamp),
        arrival_ns=int(arrival_ns),
    )


def decode_battery(msg: Any, arrival_ns: int = 0) -> BatteryStatus:
    stamp = getattr(getattr(msg, "header", None), "stamp", None)
    t_ns = stamp_to_ns(stamp) if stamp is not None else 0
    return BatteryStatus(
        percentage=float(msg.percentage),
        power_supply_status=int(msg.power_supply_status),
        t_device_ns=t_ns,
        arrival_ns=int(arrival_ns),
    )


def decode_device_info(msg: Any) -> DeviceInfo:
    import json

    raw = json.loads(str(msg.data))
    if not isinstance(raw, dict):
        raise ProtocolError("device_info JSON must be an object")
    return DeviceInfo(
        schema_version=int(raw.get("schema_version", 0)),
        session_id=str(raw.get("session_id", "")),
        name=str(raw.get("name", "")),
        model=str(raw.get("model", "")),
        os_version=str(raw.get("os_version", "")),
        app_version=str(raw.get("app_version", "")),
        mode=str(raw.get("mode", "")),
        streams=dict(raw.get("streams") or {}),
        clock=dict(raw.get("clock") or {}),
        frames=dict(raw.get("frames") or {}),
        raw=raw,
    )

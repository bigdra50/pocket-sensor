"""Golden test vectors for CDR, frames, units, and intrinsics."""

from __future__ import annotations

import argparse
import base64
import io
import json
import math
import sys
from pathlib import Path
from typing import Any

import numpy as np
from rosbags.interfaces import Nodetype

from pocketsensor.cdr import CdrCodec
from pocketsensor.frames import (
    ARKIT_TO_REP103,
    LINK_TO_COLOR_OPTICAL_RPY,
    LINK_TO_IMU_RPY,
    arkit_pose_to_rep103,
    rpy_to_quaternion,
)
from pocketsensor.intrinsics import Intrinsics, camera_info_matrices, deproject, scale_intrinsics
from pocketsensor.units import (
    accel_g_to_mps2,
    accuracy_to_variance,
    course_deg_to_enu_yaw,
    depth_m_to_mm_u16,
    mag_ut_to_tesla,
    navsat_covariance,
    pressure_kpa_to_pa,
)

REPO_ROOT = Path(__file__).resolve().parent.parent
VECTORS = REPO_ROOT / "contract" / "vectors"


def jsonable(value: Any) -> Any:
    if isinstance(value, str):
        return value
    if isinstance(value, (bool, int)):
        return value
    if isinstance(value, float):
        if math.isnan(value):
            return "NaN"
        if math.isinf(value):
            return "Infinity" if value > 0 else "-Infinity"
        if value == 0.0:
            return 0.0
        return value
    if isinstance(value, np.generic):
        return jsonable(value.item())
    if isinstance(value, np.ndarray):
        return [jsonable(item) for item in value.tolist()]
    if isinstance(value, (list, tuple)):
        return [jsonable(item) for item in value]
    if isinstance(value, dict):
        return {str(k): jsonable(v) for k, v in value.items()}
    raise TypeError(f"cannot encode {type(value)!r}")


def field_to_json(value: Any, desc: Any, codec: CdrCodec) -> Any:
    kind = desc[0]
    if kind == Nodetype.BASE:
        basename = desc[1][0]
        if basename in {"float32", "float64"}:
            return jsonable(float(value))
        if basename == "bool":
            return bool(value)
        if basename == "string":
            return str(value)
        return int(value)
    if kind == Nodetype.NAME:
        return msg_to_value(codec, value)
    inner, _count = desc[1]
    if kind in (Nodetype.ARRAY, Nodetype.SEQUENCE) and inner[0] == Nodetype.BASE:
        basename = inner[1][0]
        if basename in {"uint8", "byte", "char"}:
            arr = np.asarray(value, dtype=np.uint8)
            return arr.tobytes().hex()
        return jsonable(np.asarray(value).tolist())
    if kind in (Nodetype.ARRAY, Nodetype.SEQUENCE) and inner[0] == Nodetype.NAME:
        return [msg_to_value(codec, item) for item in value]
    return jsonable(value)


def msg_to_value(codec: CdrCodec, msg: Any) -> dict[str, Any]:
    schema = type(msg).__msgtype__
    out: dict[str, Any] = {}
    for name, desc in codec.store.fielddefs[schema][1]:
        if name == "structure_needs_at_least_one_member":
            continue
        out[name] = field_to_json(getattr(msg, name), desc, codec)
    return out


def cdr_case(codec: CdrCodec, name: str, schema: str, msg: Any) -> dict[str, Any]:
    encoded = codec.encode(schema, msg)
    return {
        "name": name,
        "schema": schema,
        "value": msg_to_value(codec, msg),
        "cdr_hex": encoded.hex(),
    }


def rotation_about(axis: tuple[float, float, float], deg: float) -> np.ndarray:
    angle = math.radians(deg)
    n = np.asarray(axis, dtype=np.float64)
    n = n / np.linalg.norm(n)
    x, y, z = n
    c = math.cos(angle)
    s = math.sin(angle)
    c1 = 1.0 - c
    return np.array(
        [
            [c + x * x * c1, x * y * c1 - z * s, x * z * c1 + y * s],
            [y * x * c1 + z * s, c + y * y * c1, y * z * c1 - x * s],
            [z * x * c1 - y * s, z * y * c1 + x * s, c + z * z * c1],
        ],
        dtype=np.float64,
    )


def homog(r: np.ndarray, p: tuple[float, float, float]) -> list[float]:
    t = np.eye(4, dtype=np.float64)
    t[:3, :3] = r
    t[:3, 3] = np.asarray(p, dtype=np.float64)
    return t.reshape(-1).tolist()


def pose_case(name: str, transform: list[float]) -> dict[str, Any]:
    position, quat = arkit_pose_to_rep103(transform)
    return {
        "name": name,
        "transform": jsonable(transform),
        "position": jsonable(position),
        "quaternion_xyzw": jsonable(quat),
    }


def build_cdr_cases(codec: CdrCodec) -> list[dict[str, Any]]:
    header = {"stamp": {"sec": 1, "nanosec": 2}, "frame_id": "imu_link"}
    ident_q = {"x": 0.0, "y": 0.0, "z": 0.0, "w": 1.0}
    z9 = [0.0] * 9
    z36 = [0.0] * 36

    imu = codec.make(
        "sensor_msgs/msg/Imu",
        header=header,
        orientation=ident_q,
        orientation_covariance=[-1.0, *z9[1:]],
        angular_velocity={"x": 0.5, "y": -0.25, "z": 0.125},
        linear_acceleration={"x": 0.0, "y": 0.0, "z": 9.5},
    )
    k, r, p, d = camera_info_matrices(Intrinsics(1920, 1440, 1500.5, 1500.5, 959.5, 719.5))
    camera_info = codec.make(
        "sensor_msgs/msg/CameraInfo",
        header={"stamp": {"sec": 10, "nanosec": 20}, "frame_id": "color_optical_frame"},
        height=1440,
        width=1920,
        distortion_model="plumb_bob",
        d=d,
        k=k,
        r=r,
        p=p,
        binning_x=0,
        binning_y=0,
        roi={"x_offset": 0, "y_offset": 0, "height": 0, "width": 0, "do_rectify": False},
    )
    # 4x2 16UC1、step は 1 行 8 バイト
    pixels = np.array([1, 2, 3, 4, 5, 6, 7, 8], dtype=np.uint16)
    image = codec.make(
        "sensor_msgs/msg/Image",
        header={"stamp": {"sec": 3, "nanosec": 4}, "frame_id": "color_optical_frame"},
        height=2,
        width=4,
        encoding="16UC1",
        is_bigendian=0,
        step=8,
        data=pixels.tobytes(),
    )
    kv = [
        {"key": "thermal", "value": "nominal"},
        {"key": "battery", "value": "0.75"},
        {"key": "tracking", "value": "normal"},
    ]
    diagnostics = codec.make(
        "diagnostic_msgs/msg/DiagnosticArray",
        header={"stamp": {"sec": 5, "nanosec": 6}, "frame_id": ""},
        status=[
            {
                "level": 0,
                "name": "cpu",
                "message": "ok",
                "hardware_id": "a",
                "values": [],
            },
            {
                "level": 1,
                "name": "imu",
                "message": "warm",
                "hardware_id": "b",
                "values": kv,
            },
        ],
    )

    def stamped_tf(child: str, tx: float, ty: float, tz: float) -> dict[str, Any]:
        return {
            "header": {"stamp": {"sec": 7, "nanosec": 8}, "frame_id": "odom"},
            "child_frame_id": child,
            "transform": {
                "translation": {"x": tx, "y": ty, "z": tz},
                "rotation": ident_q,
            },
        }

    tf = codec.make(
        "tf2_msgs/msg/TFMessage",
        transforms=[stamped_tf("link", 0.5, -0.25, 0.125), stamped_tf("imu_link", 0.0, 0.0, 0.0)],
    )
    cov = list(z36)
    cov[0] = 0.25
    cov[7] = 0.5
    cov[14] = 0.75
    cov[21] = 1.25
    odom = codec.make(
        "nav_msgs/msg/Odometry",
        header={"stamp": {"sec": 9, "nanosec": 10}, "frame_id": "odom"},
        child_frame_id="link",
        pose={
            "pose": {
                "position": {"x": 1.5, "y": -2.5, "z": 0.5},
                "orientation": ident_q,
            },
            "covariance": cov,
        },
        twist={
            "twist": {
                "linear": {"x": 0.25, "y": 0.0, "z": 0.0},
                "angular": {"x": 0.0, "y": 0.0, "z": 0.125},
            },
            "covariance": z36,
        },
    )
    tracking = codec.make(
        "pocketsensor_msgs/msg/TrackingStatus",
        header={"stamp": {"sec": 11, "nanosec": 12}, "frame_id": "link"},
        state=2,
        reason=0,
        origin_epoch=3,
    )
    clock_resp = codec.make(
        "pocketsensor_msgs/srv/ClockSync_Response",
        t1=2**63 + 1,
        t2=2**63 + 100,
        t3=2**63 + 200,
    )
    battery = codec.make(
        "sensor_msgs/msg/BatteryState",
        header={"stamp": {"sec": 13, "nanosec": 14}, "frame_id": ""},
        voltage=3.5,
        temperature=float("nan"),
        current=float("nan"),
        charge=float("nan"),
        capacity=float("nan"),
        design_capacity=float("nan"),
        percentage=0.75,
        power_supply_status=2,
        power_supply_health=1,
        power_supply_technology=2,
        present=True,
        cell_voltage=[],
        cell_temperature=[],
        location="",
        serial_number="",
    )
    navsat = codec.make(
        "sensor_msgs/msg/NavSatFix",
        header={"stamp": {"sec": 15, "nanosec": 16}, "frame_id": "link"},
        status={"status": -1, "service": 0},
        latitude=0.0,
        longitude=0.0,
        altitude=float("nan"),
        position_covariance=z9,
        position_covariance_type=0,
    )

    cases = [
        cdr_case(codec, "imu_basic", "sensor_msgs/msg/Imu", imu),
        cdr_case(codec, "camera_info_plumb_bob", "sensor_msgs/msg/CameraInfo", camera_info),
        cdr_case(codec, "image_depth_16uc1", "sensor_msgs/msg/Image", image),
        cdr_case(codec, "diagnostics_two_statuses", "diagnostic_msgs/msg/DiagnosticArray", diagnostics),
        cdr_case(codec, "tf_two_transforms", "tf2_msgs/msg/TFMessage", tf),
        cdr_case(codec, "odometry_covariance", "nav_msgs/msg/Odometry", odom),
        cdr_case(codec, "tracking_status_normal", "pocketsensor_msgs/msg/TrackingStatus", tracking),
        cdr_case(codec, "clock_sync_response", "pocketsensor_msgs/srv/ClockSync_Response", clock_resp),
        cdr_case(codec, "battery_nan", "sensor_msgs/msg/BatteryState", battery),
        cdr_case(codec, "navsatfix_no_fix", "sensor_msgs/msg/NavSatFix", navsat),
        cdr_case(
            codec,
            "clock_sync_request",
            "pocketsensor_msgs/srv/ClockSync_Request",
            codec.make("pocketsensor_msgs/srv/ClockSync_Request", t1=2**63 + 7),
        ),
        cdr_case(
            codec,
            "trigger_request",
            "std_srvs/srv/Trigger_Request",
            codec.make("std_srvs/srv/Trigger_Request"),
        ),
        cdr_case(
            codec,
            "trigger_response",
            "std_srvs/srv/Trigger_Response",
            codec.make("std_srvs/srv/Trigger_Response", success=True, message="ok"),
        ),
        cdr_case(
            codec,
            "string_empty",
            "std_msgs/msg/String",
            codec.make("std_msgs/msg/String", data=""),
        ),
        cdr_case(
            codec,
            "string_len1",
            "std_msgs/msg/String",
            codec.make("std_msgs/msg/String", data="a"),
        ),
        cdr_case(
            codec,
            "string_len3",
            "std_msgs/msg/String",
            codec.make("std_msgs/msg/String", data="abc"),
        ),
        cdr_case(
            codec,
            "string_len4",
            "std_msgs/msg/String",
            codec.make("std_msgs/msg/String", data="abcd"),
        ),
        cdr_case(
            codec,
            "string_len5",
            "std_msgs/msg/String",
            codec.make("std_msgs/msg/String", data="abcde"),
        ),
        cdr_case(
            codec,
            "compressed_image_empty",
            "sensor_msgs/msg/CompressedImage",
            codec.make(
                "sensor_msgs/msg/CompressedImage",
                header={"stamp": {"sec": 0, "nanosec": 0}, "frame_id": "color_optical_frame"},
                format="jpeg",
                data=b"",
            ),
        ),
        cdr_case(
            codec,
            "uint8_len0",
            "sensor_msgs/msg/CompressedImage",
            codec.make(
                "sensor_msgs/msg/CompressedImage",
                header={"stamp": {"sec": 1, "nanosec": 0}, "frame_id": "c"},
                format="",
                data=b"",
            ),
        ),
        cdr_case(
            codec,
            "uint8_len1",
            "sensor_msgs/msg/CompressedImage",
            codec.make(
                "sensor_msgs/msg/CompressedImage",
                header={"stamp": {"sec": 1, "nanosec": 0}, "frame_id": "c"},
                format="x",
                data=b"\xab",
            ),
        ),
        cdr_case(
            codec,
            "uint8_len5",
            "sensor_msgs/msg/CompressedImage",
            codec.make(
                "sensor_msgs/msg/CompressedImage",
                header={"stamp": {"sec": 1, "nanosec": 0}, "frame_id": "c"},
                format="raw",
                data=bytes([0, 1, 2, 3, 4]),
            ),
        ),
        cdr_case(
            codec,
            "time_negative",
            "builtin_interfaces/msg/Time",
            codec.make("builtin_interfaces/msg/Time", sec=-2, nanosec=300000000),
        ),
        cdr_case(
            codec,
            "magnetic_field",
            "sensor_msgs/msg/MagneticField",
            codec.make(
                "sensor_msgs/msg/MagneticField",
                header=header,
                magnetic_field={"x": 1.5e-5, "y": -2.5e-5, "z": 3.5e-5},
                magnetic_field_covariance=z9,
            ),
        ),
        cdr_case(
            codec,
            "fluid_pressure",
            "sensor_msgs/msg/FluidPressure",
            codec.make(
                "sensor_msgs/msg/FluidPressure",
                header={"stamp": {"sec": 1, "nanosec": 0}, "frame_id": "link"},
                fluid_pressure=101325.0,
                variance=0.25,
            ),
        ),
        cdr_case(
            codec,
            "time_reference",
            "sensor_msgs/msg/TimeReference",
            codec.make(
                "sensor_msgs/msg/TimeReference",
                header={"stamp": {"sec": 1, "nanosec": 2}, "frame_id": ""},
                time_ref={"sec": 1700000000, "nanosec": 123},
                source="gnss",
            ),
        ),
        cdr_case(
            codec,
            "twist_stamped",
            "geometry_msgs/msg/TwistStamped",
            codec.make(
                "geometry_msgs/msg/TwistStamped",
                header={"stamp": {"sec": 1, "nanosec": 0}, "frame_id": "link"},
                twist={
                    "linear": {"x": 0.5, "y": 0.0, "z": 0.0},
                    "angular": {"x": 0.0, "y": 0.0, "z": -0.25},
                },
            ),
        ),
        cdr_case(
            codec,
            "empty_sequence_tf",
            "tf2_msgs/msg/TFMessage",
            codec.make("tf2_msgs/msg/TFMessage", transforms=[]),
        ),
    ]
    return cases


def build_frames() -> dict[str, Any]:
    identity = homog(np.eye(3), (0.0, 0.0, 0.0))
    cases = [
        pose_case("identity", identity),
        pose_case("translate_arkit_x", homog(np.eye(3), (1.0, 0.0, 0.0))),
        pose_case("translate_arkit_y", homog(np.eye(3), (0.0, 1.0, 0.0))),
        pose_case("translate_arkit_z", homog(np.eye(3), (0.0, 0.0, 1.0))),
        pose_case("translate_arkit_neg_x", homog(np.eye(3), (-1.0, 0.0, 0.0))),
        pose_case("translate_arkit_neg_y", homog(np.eye(3), (0.0, -1.0, 0.0))),
        pose_case("translate_arkit_neg_z", homog(np.eye(3), (0.0, 0.0, -1.0))),
        pose_case("rot90_arkit_x", homog(rotation_about((1, 0, 0), 90), (0.0, 0.0, 0.0))),
        pose_case("rot90_arkit_y", homog(rotation_about((0, 1, 0), 90), (0.0, 0.0, 0.0))),
        pose_case("rot90_arkit_z", homog(rotation_about((0, 0, 1), 90), (0.0, 0.0, 0.0))),
        pose_case(
            "general",
            homog(rotation_about((1, 2, 3), 37), (0.3, -1.2, 2.5)),
        ),
    ]
    r = ARKIT_TO_REP103
    r_out = np.array([[-1.0, 0.0, 0.0], [0.0, -1.0, 0.0], [0.0, 0.0, 1.0]], dtype=np.float64)
    r_cam = r.T @ r_out @ r
    cases.append(pose_case("w_zero_180_z", homog(r_cam, (0.0, 0.0, 0.0))))

    def static_q(rpy: tuple[float, float, float]) -> dict[str, Any]:
        q = rpy_to_quaternion(*rpy)
        return {"rpy": list(rpy), "quaternion_xyzw": jsonable(q)}

    return {
        "cases": cases,
        "static_transforms": {
            "link_to_color_optical": static_q(LINK_TO_COLOR_OPTICAL_RPY),
            "link_to_imu": static_q(LINK_TO_IMU_RPY),
        },
    }


def build_units() -> dict[str, Any]:
    depth_inputs: list[Any] = [
        "NaN",
        0.0,
        -1.0,
        0.0004,
        0.0005,
        1.2345,
        65.5344,
        65.535,
        100.0,
        "Infinity",
    ]
    depth_arr = np.array(
        [float("nan"), 0.0, -1.0, 0.0004, 0.0005, 1.2345, 65.5344, 65.535, 100.0, float("inf")],
        dtype=np.float32,
    )
    depth_out = depth_m_to_mm_u16(depth_arr)
    return {
        "accel_g_to_mps2": [
            {"input": [0.0, 0.0, -1.0], "output": jsonable(accel_g_to_mps2([0.0, 0.0, -1.0]))},
            {"input": [1.0, -0.5, 0.25], "output": jsonable(accel_g_to_mps2([1.0, -0.5, 0.25]))},
        ],
        "mag_ut_to_tesla": [
            {"input": [30.0, -15.0, 45.0], "output": jsonable(mag_ut_to_tesla([30.0, -15.0, 45.0]))},
        ],
        "pressure_kpa_to_pa": [
            {"input": 101.325, "output": pressure_kpa_to_pa(101.325)},
        ],
        "course_deg_to_enu_yaw": [
            {"input": 0.0, "output": course_deg_to_enu_yaw(0.0)},
            {"input": 90.0, "output": course_deg_to_enu_yaw(90.0)},
            {"input": 180.0, "output": course_deg_to_enu_yaw(180.0)},
            {"input": 270.0, "output": course_deg_to_enu_yaw(270.0)},
            {"input": 360.0, "output": course_deg_to_enu_yaw(360.0)},
        ],
        "accuracy_to_variance": [
            {"input": 1.5, "output": accuracy_to_variance(1.5)},
            {"input": 0.0, "output": accuracy_to_variance(0.0)},
        ],
        "navsat_covariance": [
            {
                "horizontal_accuracy_m": -1.0,
                "vertical_accuracy_m": 2.0,
                "output": {
                    "cov9": [0.0] * 9,
                    "cov_type": 0,
                    "status": -1,
                },
            },
            {
                "horizontal_accuracy_m": 2.0,
                "vertical_accuracy_m": 4.0,
                "output": {
                    "cov9": navsat_covariance(2.0, 4.0)[0],
                    "cov_type": navsat_covariance(2.0, 4.0)[1],
                    "status": navsat_covariance(2.0, 4.0)[2],
                },
            },
            {
                "horizontal_accuracy_m": 3.0,
                "vertical_accuracy_m": -1.0,
                "output": {
                    "cov9": navsat_covariance(3.0, -1.0)[0],
                    "cov_type": navsat_covariance(3.0, -1.0)[1],
                    "status": navsat_covariance(3.0, -1.0)[2],
                },
            },
        ],
        "depth_m_to_mm_u16": [
            {"input": depth_inputs, "output": [int(v) for v in depth_out.tolist()]},
        ],
    }


def build_intrinsics() -> dict[str, Any]:
    src = Intrinsics(width=1920, height=1440, fx=1592.5, fy=1592.5, cx=959.5, cy=719.5)
    scaled_depth = scale_intrinsics(src, 256, 192)
    scaled_half = scale_intrinsics(src, 960, 720)
    tiny = Intrinsics(width=2, height=2, fx=1.0, fy=1.0, cx=0.5, cy=0.5)
    depth = np.array([[1.0, 2.0], [float("nan"), 4.0]], dtype=np.float32)
    points = deproject(depth, tiny)
    k, r, p, d = camera_info_matrices(scaled_depth)

    def dump_i(i: Intrinsics) -> dict[str, Any]:
        return {"width": i.width, "height": i.height, "fx": i.fx, "fy": i.fy, "cx": i.cx, "cy": i.cy}

    return {
        "source": dump_i(src),
        "scale_256x192": dump_i(scaled_depth),
        "scale_960x720": dump_i(scaled_half),
        "camera_info_256x192": {"k": k, "r": r, "p": p, "d": d},
        "deproject": {
            "intrinsics": dump_i(tiny),
            "depth": jsonable(depth),
            "points": jsonable(points),
        },
    }


def render(obj: Any) -> str:
    return json.dumps(jsonable(obj), indent=2, sort_keys=True, ensure_ascii=False) + "\n"


def generate_all() -> dict[Path, str]:
    codec = CdrCodec.from_contract()
    return {
        VECTORS / "cdr.json": render({"cases": build_cdr_cases(codec)}),
        VECTORS / "frames.json": render(build_frames()),
        VECTORS / "units.json": render(build_units()),
        VECTORS / "intrinsics.json": render(build_intrinsics()),
    }


def png_cases_spec() -> list[dict[str, Any]]:
    """小さな gray16 / gray8。0, 1, 255, 256, 65535 を必ず含める。"""
    gray16 = [0, 1, 255, 256, 1000, 32767, 32768, 65535] * 4
    gray8 = [0, 1, 2, 127, 128, 254, 255, 3] * 4
    return [
        {
            "name": "gray16_8x4",
            "kind": "gray16",
            "width": 8,
            "height": 4,
            "pixels": gray16,
        },
        {
            "name": "gray8_8x4",
            "kind": "gray8",
            "width": 8,
            "height": 4,
            "pixels": gray8,
        },
    ]


def encode_png_case(kind: str, width: int, height: int, pixels: list[int]) -> bytes:
    from PIL import Image

    dtype = np.uint16 if kind == "gray16" else np.uint8
    arr = np.asarray(pixels, dtype=dtype).reshape((height, width))
    buf = io.BytesIO()
    Image.fromarray(arr).save(buf, format="PNG")
    return buf.getvalue()


def decode_png_pixels(png: bytes, kind: str) -> list[int]:
    from PIL import Image

    image = Image.open(io.BytesIO(png))
    arr = np.asarray(image)
    dtype = np.uint16 if kind == "gray16" else np.uint8
    return [int(v) for v in np.asarray(arr, dtype=dtype).reshape(-1).tolist()]


def png_json_is_valid(path: Path) -> bool:
    """PNG バイトは zlib の版で変わりうるので、復号結果だけを見る。"""
    spec = {row["name"]: row for row in png_cases_spec()}
    if not path.exists():
        return False
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return False
    cases = payload.get("cases")
    if not isinstance(cases, list):
        return False
    names = [case.get("name") for case in cases]
    if names != [row["name"] for row in png_cases_spec()]:
        return False
    for case in cases:
        expected = spec[str(case["name"])]
        if case.get("kind") != expected["kind"]:
            return False
        if case.get("width") != expected["width"] or case.get("height") != expected["height"]:
            return False
        if case.get("pixels") != expected["pixels"]:
            return False
        try:
            png = base64.b64decode(case["png_b64"])
        except (KeyError, TypeError, ValueError):
            return False
        try:
            decoded = decode_png_pixels(png, expected["kind"])
        except Exception:
            return False
        if decoded != expected["pixels"]:
            return False
    return True


def write_png_json() -> None:
    path = VECTORS / "png.json"
    if png_json_is_valid(path):
        return
    cases = []
    for row in png_cases_spec():
        png = encode_png_case(row["kind"], row["width"], row["height"], row["pixels"])
        cases.append({**row, "png_b64": base64.b64encode(png).decode("ascii")})
    path.write_text(render({"cases": cases}), encoding="utf-8")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Write golden vectors under contract/vectors/")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args(argv)
    files = generate_all()
    png_path = VECTORS / "png.json"
    if args.check:
        differed = []
        for path, content in files.items():
            existing = path.read_text(encoding="utf-8") if path.exists() else None
            if existing != content:
                differed.append(path)
        if not png_json_is_valid(png_path):
            differed.append(png_path)
        for path in differed:
            print(path.relative_to(REPO_ROOT))
        return 1 if differed else 0
    VECTORS.mkdir(parents=True, exist_ok=True)
    for path, content in files.items():
        path.write_text(content, encoding="utf-8")
    write_png_json()
    return 0


if __name__ == "__main__":
    sys.exit(main())

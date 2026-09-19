from __future__ import annotations

import json
from pathlib import Path

import numpy as np
import pytest

from pocketsensor.calibration import Calibration
from pocketsensor.errors import Unsupported
from pocketsensor.frames import LINK_TO_COLOR_OPTICAL_RPY, LINK_TO_IMU_RPY, quat_to_matrix, rpy_to_quaternion
from pocketsensor.intrinsics import Intrinsics
from pocketsensor.streams import Stream
from pocketsensor.types import DeviceInfo

REPO = Path(__file__).resolve().parents[2]


def _T(rpy: tuple[float, float, float], translation: tuple[float, float, float]) -> np.ndarray:
    t = np.eye(4, dtype=np.float64)
    t[:3, :3] = quat_to_matrix(rpy_to_quaternion(*rpy))
    t[:3, 3] = translation
    return t


def _info() -> DeviceInfo:
    raw = {
        "schema_version": 1,
        "session_id": "s",
        "name": "pocketsensor",
        "model": "fake",
        "os_version": "0",
        "app_version": "0.1.0",
        "mode": "arkit",
        "streams": {},
        "clock": {},
        "frames": {
            "link": "pocketsensor_link",
            "color_optical": "pocketsensor_color_optical_frame",
            "imu": "pocketsensor_imu_link",
            "odom": "pocketsensor_odom",
        },
        "imu": {"noise_density": float("nan")},
        "camera_imu_translation_m": [float("nan"), float("nan"), float("nan")],
    }
    return DeviceInfo(
        schema_version=1,
        session_id="s",
        name="pocketsensor",
        model="fake",
        os_version="0",
        app_version="0.1.0",
        mode="arkit",
        streams={},
        clock={},
        frames=raw["frames"],
        raw=raw,
    )


def _static_tf() -> list[dict[str, object]]:
    q_color = rpy_to_quaternion(*LINK_TO_COLOR_OPTICAL_RPY)
    q_imu = rpy_to_quaternion(*LINK_TO_IMU_RPY)
    return [
        {
            "parent": "pocketsensor_link",
            "child": "pocketsensor_color_optical_frame",
            "translation": (0.0, 0.0, 0.0),
            "rotation_xyzw": tuple(float(v) for v in q_color),
            "translation_known": True,
        },
        {
            "parent": "pocketsensor_link",
            "child": "pocketsensor_imu_link",
            "translation": (0.0, 0.0, 0.0),
            "rotation_xyzw": tuple(float(v) for v in q_imu),
            "translation_known": False,
        },
    ]


def test_intrinsics_latest_and_missing() -> None:
    cal = Calibration(
        _info(),
        _static_tf(),
        {Stream.COLOR: Intrinsics(4, 3, 2.0, 2.0, 1.0, 1.5)},
    )
    k = cal.intrinsics(Stream.COLOR)
    assert k.width == 4
    assert k.fx == pytest.approx(2.0)
    with pytest.raises(Unsupported):
        cal.intrinsics(Stream.DEPTH)


def test_extrinsics_matches_contract_and_inverts() -> None:
    payload = json.loads((REPO / "contract" / "vectors" / "frames.json").read_text())
    cal = Calibration(_info(), _static_tf(), {})
    optical = "pocketsensor_color_optical_frame"
    link = "pocketsensor_link"
    imu = "pocketsensor_imu_link"
    t_opt_to_link = cal.extrinsics(optical, link)
    expected = _T(LINK_TO_COLOR_OPTICAL_RPY, (0.0, 0.0, 0.0))
    np.testing.assert_allclose(t_opt_to_link, expected, atol=1e-12)
    t_link_to_opt = cal.extrinsics(link, optical)
    np.testing.assert_allclose(t_link_to_opt @ t_opt_to_link, np.eye(4), atol=1e-12)
    q = payload["static_transforms"]["link_to_color_optical"]["quaternion_xyzw"]
    np.testing.assert_allclose(t_opt_to_link[:3, :3], quat_to_matrix(q), atol=1e-12)

    t_imu_to_link = cal.extrinsics(imu, link)
    np.testing.assert_allclose(
        t_imu_to_link[:3, :3],
        quat_to_matrix(rpy_to_quaternion(*LINK_TO_IMU_RPY)),
        atol=1e-12,
    )
    assert np.isnan(t_imu_to_link[0, 3])
    t_link_to_imu = cal.extrinsics(link, imu)
    np.testing.assert_allclose(t_link_to_imu[:3, :3], t_imu_to_link[:3, :3].T, atol=1e-12)

    composed = cal.extrinsics(optical, imu)
    r_via = cal.extrinsics(link, imu)[:3, :3] @ cal.extrinsics(optical, link)[:3, :3]
    np.testing.assert_allclose(composed[:3, :3], r_via, atol=1e-12)


def test_stream_members_map_to_frame_names() -> None:
    cal = Calibration(_info(), _static_tf(), {})
    t_named = cal.extrinsics("pocketsensor_color_optical_frame", "pocketsensor_link")
    t_stream = cal.extrinsics(Stream.COLOR, Stream.POSE)
    np.testing.assert_allclose(t_named, t_stream, equal_nan=True)


def test_unknown_frame_raises_unsupported() -> None:
    cal = Calibration(_info(), _static_tf(), {})
    with pytest.raises(Unsupported):
        cal.extrinsics("nope", "pocketsensor_link")


def test_raw_exposes_device_info_and_nans() -> None:
    cal = Calibration(_info(), _static_tf(), {})
    assert cal.raw["name"] == "pocketsensor"
    assert np.isnan(cal.raw["imu"]["noise_density"])
    assert all(np.isnan(v) for v in cal.raw["camera_imu_translation_m"])

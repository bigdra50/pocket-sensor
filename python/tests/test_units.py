from __future__ import annotations

import json
import math
from pathlib import Path

import numpy as np
import pytest

from pocketsensor.units import (
    STANDARD_GRAVITY,
    accel_g_to_mps2,
    accuracy_to_variance,
    course_deg_to_enu_yaw,
    depth_m_to_mm_u16,
    mag_ut_to_tesla,
    navsat_covariance,
    pressure_kpa_to_pa,
)

REPO = Path(__file__).resolve().parents[2]


def _restore_float(value: object) -> object:
    if value == "NaN":
        return float("nan")
    if value == "Infinity":
        return float("inf")
    if value == "-Infinity":
        return float("-inf")
    return value


def test_accel_sign_flip() -> None:
    out = accel_g_to_mps2([0.0, 0.0, -1.0])
    assert out == pytest.approx([0.0, 0.0, STANDARD_GRAVITY])


def test_course_wraps_west_to_pi() -> None:
    assert course_deg_to_enu_yaw(270.0) == pytest.approx(math.pi)


def test_navsat_no_fix() -> None:
    cov, cov_type, status = navsat_covariance(-1.0, 3.0)
    assert status == -1
    assert cov_type == 0
    assert cov == [0.0] * 9


def test_navsat_vertical_unknown() -> None:
    cov, cov_type, status = navsat_covariance(2.0, -0.5)
    assert status == 0
    assert cov_type == 1
    assert cov[0] == pytest.approx(4.0)
    assert cov[4] == pytest.approx(4.0)
    assert cov[8] == 0.0


def test_units_vectors() -> None:
    payload = json.loads((REPO / "contract" / "vectors" / "units.json").read_text())
    for case in payload["accel_g_to_mps2"]:
        assert accel_g_to_mps2(case["input"]) == pytest.approx(case["output"])
    for case in payload["mag_ut_to_tesla"]:
        assert mag_ut_to_tesla(case["input"]) == pytest.approx(case["output"])
    for case in payload["pressure_kpa_to_pa"]:
        assert pressure_kpa_to_pa(case["input"]) == pytest.approx(case["output"])
    for case in payload["course_deg_to_enu_yaw"]:
        assert course_deg_to_enu_yaw(case["input"]) == pytest.approx(case["output"])
    for case in payload["accuracy_to_variance"]:
        assert accuracy_to_variance(case["input"]) == pytest.approx(case["output"])
    for case in payload["navsat_covariance"]:
        cov, cov_type, status = navsat_covariance(case["horizontal_accuracy_m"], case["vertical_accuracy_m"])
        assert cov == pytest.approx(case["output"]["cov9"])
        assert cov_type == case["output"]["cov_type"]
        assert status == case["output"]["status"]
    for case in payload["depth_m_to_mm_u16"]:
        raw = np.array([_restore_float(v) for v in case["input"]], dtype=np.float32)
        out = depth_m_to_mm_u16(raw)
        assert out.tolist() == case["output"]
        assert out.dtype == np.uint16

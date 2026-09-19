from __future__ import annotations

import json
from pathlib import Path

import numpy as np
import pytest

from pocketsensor.intrinsics import Intrinsics, camera_info_matrices, deproject, scale_intrinsics

REPO = Path(__file__).resolve().parents[2]


def test_scale_keeps_pixel_center_origin() -> None:
    src = Intrinsics(width=1920, height=1440, fx=1500.0, fy=1500.0, cx=960.0, cy=720.0)
    got = scale_intrinsics(src, 256, 192)
    sx = 256 / 1920
    assert got.fx == pytest.approx(1500.0 * sx)
    assert got.cx == pytest.approx((960.0 + 0.5) * sx - 0.5)
    assert got.cy == pytest.approx((720.0 + 0.5) * (192 / 1440) - 0.5)


def test_camera_info_plumb_bob_zeros() -> None:
    k, r, p, d = camera_info_matrices(Intrinsics(4, 3, 2.0, 3.0, 1.5, 1.0))
    assert k == [2.0, 0.0, 1.5, 0.0, 3.0, 1.0, 0.0, 0.0, 1.0]
    assert r == [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]
    assert p == [2.0, 0.0, 1.5, 0.0, 0.0, 3.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0]
    assert d == [0.0, 0.0, 0.0, 0.0, 0.0]


def test_deproject_keeps_nan() -> None:
    intrinsics = Intrinsics(width=2, height=2, fx=1.0, fy=1.0, cx=0.5, cy=0.5)
    depth = np.array([[1.0, 2.0], [np.nan, 4.0]], dtype=np.float32)
    points = deproject(depth, intrinsics)
    assert points.shape == (2, 2, 3)
    assert np.isnan(points[1, 0]).all()
    assert points[0, 0, 2] == pytest.approx(1.0)


def test_intrinsics_vectors() -> None:
    payload = json.loads((REPO / "contract" / "vectors" / "intrinsics.json").read_text())
    src = payload["source"]
    source = Intrinsics(**src)
    scaled = scale_intrinsics(source, 256, 192)
    expect = payload["scale_256x192"]
    assert scaled.width == expect["width"]
    assert scaled.height == expect["height"]
    assert scaled.fx == pytest.approx(expect["fx"])
    assert scaled.fy == pytest.approx(expect["fy"])
    assert scaled.cx == pytest.approx(expect["cx"])
    assert scaled.cy == pytest.approx(expect["cy"])
    half = scale_intrinsics(source, 960, 720)
    expect_half = payload["scale_960x720"]
    assert half.fx == pytest.approx(expect_half["fx"])
    assert half.cx == pytest.approx(expect_half["cx"])
    k, r, p, d = camera_info_matrices(scaled)
    info = payload["camera_info_256x192"]
    assert k == pytest.approx(info["k"])
    assert r == pytest.approx(info["r"])
    assert p == pytest.approx(info["p"])
    assert d == pytest.approx(info["d"])
    dep = payload["deproject"]
    points = deproject(np.array(dep["depth"], dtype=np.float32), Intrinsics(**dep["intrinsics"]))
    expected = np.array(dep["points"], dtype=np.float64)
    assert points.shape == expected.shape
    np.testing.assert_allclose(points, expected, equal_nan=True)

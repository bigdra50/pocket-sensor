from __future__ import annotations

import json
import math
from pathlib import Path

import numpy as np
import pytest

from pocketsensor.frames import (
    ARKIT_TO_REP103,
    LINK_TO_COLOR_OPTICAL_RPY,
    LINK_TO_IMU_RPY,
    arkit_pose_to_rep103,
    matrix_to_quat,
    quat_to_matrix,
    quaternion_to_yaw,
    relative_pose,
    rotate_vector,
    rpy_to_quaternion,
)

REPO = Path(__file__).resolve().parents[2]
IDENTITY = np.eye(4, dtype=np.float64)


def _quat_about(axis: tuple[float, float, float], angle_deg: float) -> np.ndarray:
    half = math.radians(angle_deg) / 2.0
    n = np.asarray(axis, dtype=np.float64)
    n = n / np.linalg.norm(n)
    xyz = n * math.sin(half)
    return np.array([xyz[0], xyz[1], xyz[2], math.cos(half)], dtype=np.float64)


def test_axis_relabel_is_a_proper_rotation() -> None:
    r = ARKIT_TO_REP103
    assert np.allclose(r @ r.T, np.eye(3))
    assert np.linalg.det(r) == pytest.approx(1.0)


def test_identity_pose() -> None:
    position, quat = arkit_pose_to_rep103(IDENTITY)
    assert position == pytest.approx((0.0, 0.0, 0.0))
    assert quat == pytest.approx((0.0, 0.0, 0.0, 1.0))


@pytest.mark.parametrize(
    ("arkit", "rep103"),
    [
        ((0.0, 0.0, -1.0), (1.0, 0.0, 0.0)),
        ((1.0, 0.0, 0.0), (0.0, -1.0, 0.0)),
        ((0.0, 1.0, 0.0), (0.0, 0.0, 1.0)),
    ],
)
def test_position_relabel(arkit: tuple[float, float, float], rep103: tuple[float, float, float]) -> None:
    t = np.eye(4)
    t[:3, 3] = arkit
    position, quat = arkit_pose_to_rep103(t)
    assert position == pytest.approx(rep103)
    assert quat == pytest.approx((0.0, 0.0, 0.0, 1.0))


def test_vectors_on_disk() -> None:
    payload = json.loads((REPO / "contract" / "vectors" / "frames.json").read_text())
    for case in payload["cases"]:
        position, quat = arkit_pose_to_rep103(case["transform"])
        assert position == pytest.approx(case["position"])
        assert quat == pytest.approx(case["quaternion_xyzw"])
        if case["name"] == "w_zero_180_z":
            assert quat[3] == pytest.approx(0.0, abs=1e-12)
            first = next(v for v in quat[:3] if v != 0.0)
            assert first > 0.0
    static = payload["static_transforms"]
    color = rpy_to_quaternion(*LINK_TO_COLOR_OPTICAL_RPY)
    imu = rpy_to_quaternion(*LINK_TO_IMU_RPY)
    assert color == pytest.approx(static["link_to_color_optical"]["quaternion_xyzw"])
    assert imu == pytest.approx(static["link_to_imu"]["quaternion_xyzw"])


def test_output_quaternion_is_unit() -> None:
    t = np.eye(4)
    t[:3, :3] = quat_to_matrix(_quat_about((0.2, -0.5, 0.8), 123))
    _, quat = arkit_pose_to_rep103(t)
    assert math.sqrt(float(np.sum(quat * quat))) == pytest.approx(1.0)


def test_matrix_to_quat_handles_180_degree_rotation() -> None:
    q = _quat_about((0, 0, 1), 180)
    m = quat_to_matrix(q)
    back = matrix_to_quat(m)
    assert np.allclose(quat_to_matrix(back), m)
    assert back[3] == pytest.approx(0.0, abs=1e-12)


def test_relative_pose_expresses_the_child_in_the_parent_frame() -> None:
    # 親は (1, 0, 0) にいて左へ 90° 向く。子は world の (1, 2, 0)、向きは world と同じ。
    parent_q = rpy_to_quaternion(0.0, 0.0, math.pi / 2)
    position, orientation = relative_pose(
        np.array([1.0, 0.0, 0.0]), parent_q, np.array([1.0, 2.0, 0.0]), np.array([0.0, 0.0, 0.0, 1.0])
    )
    # 親から見ると、子は真正面の 2 m 先にあり、右へ 90° 向いている。
    np.testing.assert_allclose(position, [2.0, 0.0, 0.0], atol=1e-12)
    np.testing.assert_allclose(orientation, rpy_to_quaternion(0.0, 0.0, -math.pi / 2), atol=1e-12)


def test_relative_pose_of_a_frame_to_itself_is_identity() -> None:
    q = rpy_to_quaternion(0.3, -0.2, 1.1)
    p = np.array([0.4, -1.2, 0.9])
    position, orientation = relative_pose(p, q, p, q)
    np.testing.assert_allclose(position, [0.0, 0.0, 0.0], atol=1e-12)
    np.testing.assert_allclose(orientation, [0.0, 0.0, 0.0, 1.0], atol=1e-12)


def test_relative_pose_is_part_of_the_public_api() -> None:
    import pocketsensor as ps

    assert ps.relative_pose is relative_pose


def test_quaternion_to_yaw_matches_rpy() -> None:
    for deg in (-170.0, -90.0, -45.0, 0.0, 30.0, 90.0, 179.0):
        yaw = math.radians(deg)
        q = rpy_to_quaternion(0.1, -0.2, yaw)
        assert quaternion_to_yaw(q) == pytest.approx(yaw, abs=1e-9)


def test_rotate_vector_follows_the_rotation_matrix() -> None:
    q = rpy_to_quaternion(0.0, 0.0, math.pi / 2)
    rotated = rotate_vector(q, np.array([1.0, 0.0, 0.0]))
    np.testing.assert_allclose(rotated, [0.0, 1.0, 0.0], atol=1e-12)
    batch = rotate_vector(q, np.array([[1.0, 0.0, 0.0], [0.0, 1.0, 0.0]]))
    np.testing.assert_allclose(batch, [[0.0, 1.0, 0.0], [-1.0, 0.0, 0.0]], atol=1e-12)

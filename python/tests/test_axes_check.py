from __future__ import annotations

import math

import numpy as np
import pytest

from pocketsensor.axes_check import (
    G,
    judge_push,
    judge_still,
    judge_translation,
    judge_yaw,
    specific_force_imu_to_link,
)
from pocketsensor.frames import LINK_TO_IMU_RPY, matrix_to_quat, quat_to_matrix, rpy_to_quaternion
from pocketsensor.types import TrackingState

_NS = 10_000_000
_NORMAL = int(TrackingState.NORMAL)
_LIMITED = int(TrackingState.LIMITED)


def _quat(*rpy: float) -> np.ndarray:
    return rpy_to_quaternion(*rpy)


def _yaw_quat(deg: float) -> np.ndarray:
    return rpy_to_quaternion(0.0, 0.0, math.radians(deg))


def _link_from_imu() -> np.ndarray:
    return quat_to_matrix(rpy_to_quaternion(*LINK_TO_IMU_RPY))


def _sf_imu_from_link(f_link: np.ndarray) -> np.ndarray:
    return _link_from_imu().T @ np.asarray(f_link, dtype=np.float64).reshape(3)


def _times(n: int, dt_ns: int = _NS) -> np.ndarray:
    return np.arange(n, dtype=np.int64) * dt_ns


def _constant_poses(
    n: int,
    position: tuple[float, float, float] = (0.0, 0.0, 0.0),
    rpy: tuple[float, float, float] = (0.0, 0.0, 0.0),
) -> tuple[np.ndarray, np.ndarray]:
    positions = np.tile(np.asarray(position, dtype=np.float64), (n, 1))
    quats = np.tile(_quat(*rpy), (n, 1))
    return positions, quats


def _move_poses(
    start: tuple[float, float, float],
    end: tuple[float, float, float],
    n: int,
    rpy: tuple[float, float, float] = (0.0, 0.0, 0.0),
) -> tuple[np.ndarray, np.ndarray]:
    positions = np.linspace(start, end, n, dtype=np.float64)
    quats = np.tile(_quat(*rpy), (n, 1))
    return positions, quats


def test_specific_force_imu_to_link_uses_documented_rpy() -> None:
    # link の +z は imu_link の +x。静止して上向きの比力は imu の +x に出る。
    f_link = specific_force_imu_to_link(np.array([G, 0.0, 0.0]))
    np.testing.assert_allclose(f_link, [0.0, 0.0, G], atol=1e-12)


def test_still_correct_gravity_and_no_drift_passes() -> None:
    n = 25
    positions, quats = _constant_poses(n)
    f_imu = np.tile(_sf_imu_from_link(np.array([0.0, 0.0, G])), (n, 1))
    verdict, gravity = judge_still(positions, quats, np.full(n, _NORMAL), _times(n), f_imu)
    assert verdict.status == "PASS"
    assert verdict.name == "still"
    np.testing.assert_allclose(gravity, [0.0, 0.0, G], atol=1e-9)


def test_still_agrees_with_odom_up_when_the_phone_is_tilted() -> None:
    n = 20
    rpy = (0.0, math.radians(25.0), math.radians(40.0))
    positions, quats = _constant_poses(n, rpy=rpy)
    r = quat_to_matrix(_quat(*rpy))
    up_link = r.T @ np.array([0.0, 0.0, 1.0])
    f_imu = np.tile(_sf_imu_from_link(up_link * G), (n, 1))
    verdict, gravity = judge_still(positions, quats, np.full(n, _NORMAL), _times(n), f_imu)
    assert verdict.status == "PASS"
    np.testing.assert_allclose(gravity, up_link * G, atol=1e-9)


def test_still_fails_when_imu_axes_are_swapped() -> None:
    n = 20
    positions, quats = _constant_poses(n)
    # 変換を掛けず、imu の +z に比力を置いた誤った約束。
    f_imu = np.tile(np.array([0.0, 0.0, G]), (n, 1))
    verdict, _gravity = judge_still(positions, quats, np.full(n, _NORMAL), _times(n), f_imu)
    assert verdict.status == "FAIL"
    assert verdict.measured["up_angle_deg"] > 10.0


def test_still_fails_when_position_drifts() -> None:
    n = 20
    positions, quats = _move_poses((0.0, 0.0, 0.0), (0.05, 0.0, 0.0), n)
    f_imu = np.tile(_sf_imu_from_link(np.array([0.0, 0.0, G])), (n, 1))
    verdict, _gravity = judge_still(positions, quats, np.full(n, _NORMAL), _times(n), f_imu)
    assert verdict.status == "FAIL"
    assert verdict.measured["drift_m"] >= 0.03


def test_still_skipped_when_tracking_is_not_normal() -> None:
    n = 20
    positions, quats = _constant_poses(n)
    tracking = np.full(n, _NORMAL)
    tracking[3] = _LIMITED
    f_imu = np.tile(_sf_imu_from_link(np.array([0.0, 0.0, G])), (n, 1))
    verdict, _gravity = judge_still(positions, quats, tracking, _times(n), f_imu)
    assert verdict.status == "SKIPPED"
    assert "tracking" in verdict.reason


def test_forward_in_start_link_frame_is_independent_of_room_yaw() -> None:
    # 端末は部屋の +y を向いている。カメラ方向へ 30 cm 動かすと odom の y が増える。
    n = 15
    yaw = math.pi / 2
    positions, quats = _move_poses((0.0, 0.0, 0.0), (0.0, 0.30, 0.0), n, rpy=(0.0, 0.0, yaw))
    verdict = judge_translation(positions, quats, np.full(n, _NORMAL), axis=0, min_move=0.15, name="forward")
    assert verdict.status == "PASS"
    assert verdict.measured["dx"] == pytest.approx(0.30, abs=1e-9)


def test_translation_wrong_axis_swap_fails() -> None:
    n = 15
    positions, quats = _move_poses((0.0, 0.0, 0.0), (0.0, 0.30, 0.0), n)
    verdict = judge_translation(positions, quats, np.full(n, _NORMAL), axis=0, min_move=0.15, name="forward")
    assert verdict.status == "FAIL"


def test_translation_negated_axis_fails() -> None:
    n = 15
    positions, quats = _move_poses((0.0, 0.0, 0.0), (-0.30, 0.0, 0.0), n)
    verdict = judge_translation(positions, quats, np.full(n, _NORMAL), axis=0, min_move=0.15, name="forward")
    assert verdict.status == "FAIL"


def test_translation_too_small_is_skipped() -> None:
    n = 15
    positions, quats = _move_poses((0.0, 0.0, 0.0), (0.04, 0.0, 0.0), n)
    verdict = judge_translation(positions, quats, np.full(n, _NORMAL), axis=0, min_move=0.15, name="forward")
    assert verdict.status == "SKIPPED"
    assert "movement" in verdict.reason


@pytest.mark.parametrize(
    ("axis", "delta", "name"),
    [
        (0, (0.30, 0.0, 0.0), "forward"),
        (1, (0.0, 0.30, 0.0), "left"),
        (2, (0.0, 0.0, 0.30), "up"),
    ],
)
def test_translation_correct_axis_passes(axis: int, delta: tuple[float, float, float], name: str) -> None:
    n = 12
    positions, quats = _move_poses((0.0, 0.0, 0.0), delta, n)
    verdict = judge_translation(positions, quats, np.full(n, _NORMAL), axis=axis, min_move=0.15, name=name)
    assert verdict.status == "PASS"


def test_yaw_correct_sign_passes() -> None:
    degs = np.linspace(0.0, 45.0, 20)
    odom = np.stack([_yaw_quat(d) for d in degs])
    imu = np.stack([_yaw_quat(d) for d in degs])
    verdict = judge_yaw(odom, imu, np.full(len(degs), _NORMAL))
    assert verdict.status == "PASS"
    assert verdict.measured["odom_yaw_delta_deg"] == pytest.approx(45.0, abs=1e-6)
    assert verdict.measured["imu_yaw_delta_deg"] == pytest.approx(45.0, abs=1e-6)


def _imu_quats_for_link_yaw(degs: np.ndarray, link_base: np.ndarray) -> np.ndarray:
    """link を鉛直まわりに回したときの、imu_link の向き（imu/data の orientation に当たる）。"""
    link_to_imu = quat_to_matrix(rpy_to_quaternion(*LINK_TO_IMU_RPY))
    return np.stack([matrix_to_quat(quat_to_matrix(_yaw_quat(d)) @ link_base @ link_to_imu) for d in degs])


def test_yaw_of_imu_link_is_measured_about_the_vertical_in_landscape() -> None:
    # カメラ群を上にした横置きでは imu_link の x が真上を向き、オイラー角の yaw は特異点になる
    degs = np.linspace(0.0, 45.0, 20)
    odom = np.stack([_yaw_quat(d) for d in degs])
    imu = _imu_quats_for_link_yaw(degs, np.eye(3))
    verdict = judge_yaw(odom, imu, np.full(len(degs), _NORMAL))
    assert verdict.status == "PASS"
    assert verdict.measured["imu_yaw_delta_deg"] == pytest.approx(45.0, abs=1e-6)


def test_yaw_of_imu_link_is_measured_about_the_vertical_in_portrait() -> None:
    # 縦置きは、link が前方の軸まわりに 90 度回った姿勢
    degs = np.linspace(0.0, 45.0, 20)
    portrait = quat_to_matrix(rpy_to_quaternion(math.pi / 2, 0.0, 0.0))
    odom = np.stack([matrix_to_quat(quat_to_matrix(_yaw_quat(d)) @ portrait) for d in degs])
    imu = _imu_quats_for_link_yaw(degs, portrait)
    verdict = judge_yaw(odom, imu, np.full(len(degs), _NORMAL))
    assert verdict.status == "PASS"
    assert verdict.measured["odom_yaw_delta_deg"] == pytest.approx(45.0, abs=1e-6)
    assert verdict.measured["imu_yaw_delta_deg"] == pytest.approx(45.0, abs=1e-6)


def test_yaw_wraps_across_180() -> None:
    degs = np.linspace(170.0, 200.0, 16)
    odom = np.stack([_yaw_quat(d) for d in degs])
    imu = np.stack([_yaw_quat(d) for d in degs])
    verdict = judge_yaw(odom, imu, np.full(len(degs), _NORMAL))
    assert verdict.status == "PASS"
    assert verdict.measured["odom_yaw_delta_deg"] == pytest.approx(30.0, abs=1e-5)


def test_yaw_flipped_sign_fails() -> None:
    degs = np.linspace(0.0, -45.0, 16)
    odom = np.stack([_yaw_quat(d) for d in degs])
    imu = np.stack([_yaw_quat(d) for d in degs])
    verdict = judge_yaw(odom, imu, np.full(len(degs), _NORMAL))
    assert verdict.status == "FAIL"


def test_yaw_too_small_is_skipped() -> None:
    degs = np.linspace(0.0, 8.0, 10)
    odom = np.stack([_yaw_quat(d) for d in degs])
    imu = np.stack([_yaw_quat(d) for d in degs])
    verdict = judge_yaw(odom, imu, np.full(len(degs), _NORMAL))
    assert verdict.status == "SKIPPED"
    assert "movement" in verdict.reason


def test_push_positive_x_at_peak_passes() -> None:
    t = _times(40, 10_000_000)
    gravity = np.array([0.0, 0.0, G])
    a_dyn = np.zeros((40, 3))
    a_dyn[8:16, 0] = 5.0
    f_imu = np.stack([_sf_imu_from_link(gravity + a) for a in a_dyn])
    verdict = judge_push(t, f_imu, gravity, np.full(40, _NORMAL))
    assert verdict.status == "PASS"
    assert verdict.measured["peak_ax"] > 0.0


def test_push_flipped_accel_sign_fails() -> None:
    t = _times(40, 10_000_000)
    gravity = np.array([0.0, 0.0, G])
    a_dyn = np.zeros((40, 3))
    a_dyn[8:16, 0] = -5.0
    f_imu = np.stack([_sf_imu_from_link(gravity + a) for a in a_dyn])
    verdict = judge_push(t, f_imu, gravity, np.full(40, _NORMAL))
    assert verdict.status == "FAIL"
    assert verdict.measured["peak_ax"] < 0.0


def test_push_without_onset_is_skipped() -> None:
    t = _times(20, 10_000_000)
    gravity = np.array([0.0, 0.0, G])
    f_imu = np.tile(_sf_imu_from_link(gravity), (20, 1))
    verdict = judge_push(t, f_imu, gravity, np.full(20, _NORMAL))
    assert verdict.status == "SKIPPED"
    assert "movement" in verdict.reason

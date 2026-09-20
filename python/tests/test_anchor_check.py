from __future__ import annotations

import math

import numpy as np

from pocketsensor.anchor_check import judge_anchor
from pocketsensor.axes_check import STATUS_FAIL, STATUS_PASS
from pocketsensor.frames import matrix_to_quat

_IDENTITY = np.array([0.0, 0.0, 0.0, 1.0])


def _quat(x_axis: tuple[float, float, float], z_axis: tuple[float, float, float]) -> np.ndarray:
    """anchor の x（画像の上）と z（画像の表の法線）を odom で与えて、四元数を作る。"""
    x = np.asarray(x_axis, dtype=np.float64)
    z = np.asarray(z_axis, dtype=np.float64)
    x, z = x / np.linalg.norm(x), z / np.linalg.norm(z)
    return matrix_to_quat(np.column_stack([x, np.cross(z, x), z]))


def test_image_on_a_wall_seen_from_the_front_passes() -> None:
    # 壁は x = 2 m。画像の表は -x（部屋の中）を向き、画像の上は世界の上。端末は原点から壁を見ている。
    anchor_q = _quat(x_axis=(0, 0, 1), z_axis=(-1, 0, 0))
    verdict = judge_anchor((2.0, 0.0, 1.0), anchor_q, (0.0, 0.0, 1.0), image_pose="vertical")
    assert verdict.status == STATUS_PASS
    assert verdict.measured["camera_in_anchor_m"][2] == 2.0
    assert verdict.measured["distance_m"] == 2.0
    assert verdict.measured["up_angle_deg"] < 1e-6


def test_tilted_laptop_screen_still_passes() -> None:
    tilt = math.radians(20)
    # ノート PC の画面は、20 度ほど後ろへ倒れている。
    up = (-math.sin(tilt), 0.0, math.cos(tilt))
    normal = (-math.cos(tilt), 0.0, -math.sin(tilt))
    verdict = judge_anchor((0.5, 0.0, 0.2), _quat(up, normal), (0.0, 0.0, 0.3), image_pose="vertical")
    assert verdict.status == STATUS_PASS
    assert abs(verdict.measured["up_angle_deg"] - 20.0) < 1e-6


def test_normal_pointing_into_the_wall_fails() -> None:
    # 法線が壁の奥を向くと、端末は画像の裏側にいることになる。z の符号を取り違えた実装がこうなる。
    anchor_q = _quat(x_axis=(0, 0, 1), z_axis=(1, 0, 0))
    verdict = judge_anchor((2.0, 0.0, 1.0), anchor_q, (0.0, 0.0, 1.0), image_pose="vertical")
    assert verdict.status == STATUS_FAIL
    assert "behind" in verdict.reason


def test_image_up_not_matching_gravity_fails() -> None:
    # 画像の上が水平を向いている。x と y を取り違えた実装がこうなる。
    anchor_q = _quat(x_axis=(0, 1, 0), z_axis=(-1, 0, 0))
    verdict = judge_anchor((2.0, 0.0, 1.0), anchor_q, (0.0, 0.0, 1.0), image_pose="vertical")
    assert verdict.status == STATUS_FAIL
    assert "up" in verdict.reason


def test_image_on_a_table_checks_the_normal_against_gravity() -> None:
    origin, camera = (0.0, 0.0, 0.0), (0.0, 0.0, 0.5)
    flat = _quat(x_axis=(1, 0, 0), z_axis=(0, 0, 1))
    assert judge_anchor(origin, flat, camera, image_pose="horizontal").status == STATUS_PASS
    upside_down = _quat(x_axis=(1, 0, 0), z_axis=(0, 0, -1))
    assert judge_anchor(origin, upside_down, camera, image_pose="horizontal").status == STATUS_FAIL


def test_identity_orientation_is_not_silently_accepted_for_a_wall() -> None:
    verdict = judge_anchor((2.0, 0.0, 1.0), _IDENTITY, (0.0, 0.0, 1.0), image_pose="vertical")
    assert verdict.status == STATUS_FAIL

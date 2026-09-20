"""ARKit の姿勢を REP-103 へ付け替える基準実装。"""

from __future__ import annotations

import math
from typing import Final

import numpy as np
from numpy.typing import ArrayLike, NDArray

ARKIT_TO_REP103: Final[NDArray[np.float64]] = np.array(
    [
        [0.0, 0.0, -1.0],
        [-1.0, 0.0, 0.0],
        [0.0, 1.0, 0.0],
    ],
    dtype=np.float64,
)

LINK_TO_COLOR_OPTICAL_RPY: Final[tuple[float, float, float]] = (-math.pi / 2, 0.0, -math.pi / 2)
LINK_TO_IMU_RPY: Final[tuple[float, float, float]] = (0.0, -math.pi / 2, 0.0)


def _canonicalize_quat(x: float, y: float, z: float, w: float) -> NDArray[np.float64]:
    """単位四元数の符号を揃える。w >= 0。w が 0 なら (x, y, z) の最初の非零が正。"""
    n = math.sqrt(x * x + y * y + z * z + w * w)
    x, y, z, w = x / n, y / n, z / n, w / n
    if w < 0.0:
        x, y, z, w = -x, -y, -z, -w
    elif w == 0.0:
        if x < 0.0 or (x == 0.0 and y < 0.0) or (x == 0.0 and y == 0.0 and z < 0.0):
            x, y, z, w = -x, -y, -z, -w
    return np.array([x, y, z, w], dtype=np.float64)


def matrix_to_quat(m: ArrayLike) -> NDArray[np.float64]:
    """3x3 回転行列を (x, y, z, w) にする。Shepperd 法。"""
    m = np.asarray(m, dtype=np.float64)
    trace = float(m[0, 0] + m[1, 1] + m[2, 2])
    if trace > 0:
        s = math.sqrt(trace + 1.0) * 2.0
        w = 0.25 * s
        x = (m[2, 1] - m[1, 2]) / s
        y = (m[0, 2] - m[2, 0]) / s
        z = (m[1, 0] - m[0, 1]) / s
    elif m[0, 0] > m[1, 1] and m[0, 0] > m[2, 2]:
        s = math.sqrt(1.0 + m[0, 0] - m[1, 1] - m[2, 2]) * 2.0
        w = (m[2, 1] - m[1, 2]) / s
        x = 0.25 * s
        y = (m[0, 1] + m[1, 0]) / s
        z = (m[0, 2] + m[2, 0]) / s
    elif m[1, 1] > m[2, 2]:
        s = math.sqrt(1.0 + m[1, 1] - m[0, 0] - m[2, 2]) * 2.0
        w = (m[0, 2] - m[2, 0]) / s
        x = (m[0, 1] + m[1, 0]) / s
        y = 0.25 * s
        z = (m[1, 2] + m[2, 1]) / s
    else:
        s = math.sqrt(1.0 + m[2, 2] - m[0, 0] - m[1, 1]) * 2.0
        w = (m[1, 0] - m[0, 1]) / s
        x = (m[0, 2] + m[2, 0]) / s
        y = (m[1, 2] + m[2, 1]) / s
        z = 0.25 * s
    return _canonicalize_quat(float(x), float(y), float(z), float(w))


def quat_to_matrix(q: ArrayLike) -> NDArray[np.float64]:
    x, y, z, w = (float(v) for v in np.asarray(q, dtype=np.float64).reshape(4))
    n = math.sqrt(x * x + y * y + z * z + w * w)
    x, y, z, w = x / n, y / n, z / n, w / n
    return np.array(
        [
            [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
            [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
            [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)],
        ],
        dtype=np.float64,
    )


def quaternion_to_yaw(orientation_xyzw: ArrayLike) -> float:
    """ROS の yaw（rad）。R = Rz(yaw) Ry(pitch) Rx(roll) なので、行列の xy から取る。"""
    r = quat_to_matrix(orientation_xyzw)
    return math.atan2(float(r[1, 0]), float(r[0, 0]))


def rotate_vector(orientation_xyzw: ArrayLike, vector: ArrayLike) -> NDArray[np.float64]:
    """四元数が表す回転をベクトルへ掛ける。vector は (3,) か (N, 3)。"""
    r = quat_to_matrix(orientation_xyzw)
    v = np.asarray(vector, dtype=np.float64)
    if v.ndim == 1:
        return r @ v.reshape(3)
    return (r @ v.reshape(-1, 3).T).T


def rpy_to_quaternion(roll: float, pitch: float, yaw: float) -> NDArray[np.float64]:
    """ROS の固定軸 RPY。R = Rz(yaw) Ry(pitch) Rx(roll)。返り値は (x, y, z, w)。"""
    cr = math.cos(roll)
    sr = math.sin(roll)
    cp = math.cos(pitch)
    sp = math.sin(pitch)
    cy = math.cos(yaw)
    sy = math.sin(yaw)
    rx = np.array([[1.0, 0.0, 0.0], [0.0, cr, -sr], [0.0, sr, cr]], dtype=np.float64)
    ry = np.array([[cp, 0.0, sp], [0.0, 1.0, 0.0], [-sp, 0.0, cp]], dtype=np.float64)
    rz = np.array([[cy, -sy, 0.0], [sy, cy, 0.0], [0.0, 0.0, 1.0]], dtype=np.float64)
    return matrix_to_quat(rz @ ry @ rx)


def relative_pose(
    parent_position: ArrayLike,
    parent_orientation_xyzw: ArrayLike,
    child_position: ArrayLike,
    child_orientation_xyzw: ArrayLike,
) -> tuple[NDArray[np.float64], NDArray[np.float64]]:
    """同じ frame で表した親と子の姿勢から、親の frame で見た子の位置と四元数を求める。

    端末の姿勢（odom から link）と anchor（odom から anchor）を渡すと、端末から見た anchor になる。
    2 つは同じ時刻のものを渡す。時刻がずれると、そのあいだの端末の動きが誤差として入る。
    """
    r_parent = quat_to_matrix(parent_orientation_xyzw)
    r_child = quat_to_matrix(child_orientation_xyzw)
    delta = np.asarray(child_position, dtype=np.float64).reshape(3) - np.asarray(
        parent_position, dtype=np.float64
    ).reshape(3)
    return r_parent.T @ delta, matrix_to_quat(r_parent.T @ r_child)


def arkit_pose_to_rep103(transform: ArrayLike) -> tuple[NDArray[np.float64], NDArray[np.float64]]:
    """ARKit の camera-to-world（行優先 4x4）を REP-103 の位置と四元数にする。"""
    t = np.asarray(transform, dtype=np.float64).reshape(4, 4)
    r_cam = t[:3, :3]
    p_arkit = t[:3, 3]
    r = ARKIT_TO_REP103
    position = r @ p_arkit
    r_out = r @ r_cam @ r.T
    return position.astype(np.float64, copy=False), matrix_to_quat(r_out)

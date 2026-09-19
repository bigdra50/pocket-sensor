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


def arkit_pose_to_rep103(transform: ArrayLike) -> tuple[NDArray[np.float64], NDArray[np.float64]]:
    """ARKit の camera-to-world（行優先 4x4）を REP-103 の位置と四元数にする。"""
    t = np.asarray(transform, dtype=np.float64).reshape(4, 4)
    r_cam = t[:3, :3]
    p_arkit = t[:3, 3]
    r = ARKIT_TO_REP103
    position = r @ p_arkit
    r_out = r @ r_cam @ r.T
    return position.astype(np.float64, copy=False), matrix_to_quat(r_out)

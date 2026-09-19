"""Apple の単位から wire の SI 単位への変換。計算は float64。"""

from __future__ import annotations

import math
from typing import Final

import numpy as np
from numpy.typing import ArrayLike, NDArray

STANDARD_GRAVITY: Final[float] = 9.80665

# sensor_msgs/NavSatStatus と NavSatFix の定数
STATUS_NO_FIX: Final[int] = -1
STATUS_FIX: Final[int] = 0
COVARIANCE_TYPE_UNKNOWN: Final[int] = 0
COVARIANCE_TYPE_APPROXIMATED: Final[int] = 1

# 深度の無効判定。65.535 m 以上は uint16 の mm に収まらない
_DEPTH_MAX_M: Final[float] = 65.535


def accel_g_to_mps2(v3: ArrayLike) -> NDArray[np.float64]:
    """比力へ直す。Core Motion の符号を反転し、標準重力を掛ける。"""
    return np.asarray(v3, dtype=np.float64) * -STANDARD_GRAVITY


def mag_ut_to_tesla(v3: ArrayLike) -> NDArray[np.float64]:
    return np.asarray(v3, dtype=np.float64) * 1e-6


def pressure_kpa_to_pa(x: float) -> float:
    return float(np.float64(x) * 1000.0)


def wrap_to_pi(angle: float) -> float:
    """(-pi, pi] へ畳む。-pi は pi にする。"""
    two_pi = 2.0 * math.pi
    x = math.fmod(float(angle), two_pi)
    if x > math.pi:
        x -= two_pi
    elif x <= -math.pi:
        x += two_pi
    return x


def course_deg_to_enu_yaw(course_deg: float) -> float:
    """真北 0° 時計回りを、東 0 rad 反時計回りへ。"""
    return wrap_to_pi(math.pi / 2.0 - math.radians(float(course_deg)))


def accuracy_to_variance(a: float) -> float:
    v = np.float64(a)
    return float(v * v)


def navsat_covariance(
    horizontal_accuracy_m: float,
    vertical_accuracy_m: float,
) -> tuple[list[float], int, int]:
    """水平精度が負なら NO_FIX。垂直が負なら Up の分散だけ 0。"""
    h = float(horizontal_accuracy_m)
    v = float(vertical_accuracy_m)
    if h < 0.0:
        return [0.0] * 9, COVARIANCE_TYPE_UNKNOWN, STATUS_NO_FIX
    hh = accuracy_to_variance(h)
    vv = 0.0 if v < 0.0 else accuracy_to_variance(v)
    cov = [0.0] * 9
    cov[0] = hh
    cov[4] = hh
    cov[8] = vv
    return cov, COVARIANCE_TYPE_APPROXIMATED, STATUS_FIX


def depth_m_to_mm_u16(depth: ArrayLike) -> NDArray[np.uint16]:
    """画素ごとに m を mm の uint16 へ。NaN、0 以下、65.535 以上は 0。半上げは float64 で行う。"""
    d = np.asarray(depth, dtype=np.float64)
    out = np.zeros(d.shape, dtype=np.uint16)
    valid = ~(np.isnan(d) | (d <= 0.0) | (d >= _DEPTH_MAX_M))
    if np.any(valid):
        out[valid] = np.floor(d[valid] * 1000.0 + 0.5).astype(np.uint16)
    return out

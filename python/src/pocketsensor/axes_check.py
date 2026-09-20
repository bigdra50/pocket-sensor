"""記録した軌跡から、座標軸と符号が規約どおりかを判定する。"""

from __future__ import annotations

import math
from dataclasses import dataclass
from itertools import pairwise
from typing import Any, Final

import numpy as np
from numpy.typing import ArrayLike, NDArray

from pocketsensor.frames import LINK_TO_IMU_RPY, quat_to_matrix, rpy_to_quaternion
from pocketsensor.types import TrackingState
from pocketsensor.units import STANDARD_GRAVITY

G: Final[float] = STANDARD_GRAVITY
STATUS_PASS: Final[str] = "PASS"
STATUS_FAIL: Final[str] = "FAIL"
STATUS_SKIPPED: Final[str] = "SKIPPED"

MAX_DRIFT_M: Final[float] = 0.03
SF_MIN: Final[float] = 9.5
SF_MAX: Final[float] = 10.1
MAX_UP_ANGLE_DEG: Final[float] = 10.0
DOMINANCE_RATIO: Final[float] = 2.0
MIN_YAW_DELTA_DEG: Final[float] = 20.0
PUSH_ONSET_MPS2: Final[float] = 1.0
PUSH_WINDOW_S: Final[float] = 0.150

# 文書の link -> imu_link。imu のベクトルに左から掛けると link での成分になる。
_LINK_FROM_IMU: Final[NDArray[np.float64]] = quat_to_matrix(rpy_to_quaternion(*LINK_TO_IMU_RPY))


@dataclass(frozen=True)
class StepVerdict:
    name: str
    status: str
    measured: dict[str, Any]
    thresholds: dict[str, Any]
    reason: str = ""

    def to_json(self) -> dict[str, Any]:
        payload: dict[str, Any] = {
            "name": self.name,
            "status": self.status,
            "measured": _jsonify(self.measured),
            "thresholds": _jsonify(self.thresholds),
        }
        if self.reason:
            payload["reason"] = self.reason
        return payload


def specific_force_imu_to_link(specific_force_imu: ArrayLike) -> NDArray[np.float64]:
    """imu_link の比力を <name>_link へ回す。R = Rz(0) Ry(-pi/2) Rx(0)。"""
    f = np.asarray(specific_force_imu, dtype=np.float64)
    if f.ndim == 1:
        return _LINK_FROM_IMU @ f.reshape(3)
    return (f.reshape(-1, 3) @ _LINK_FROM_IMU.T).astype(np.float64, copy=False)


def _jsonify(value: Any) -> Any:
    if isinstance(value, dict):
        return {str(k): _jsonify(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [_jsonify(v) for v in value]
    if isinstance(value, np.ndarray):
        return _jsonify(value.tolist())
    if isinstance(value, (np.floating, float)):
        return float(value)
    if isinstance(value, (np.integer, int)):
        return int(value)
    if isinstance(value, (np.bool_, bool)):
        return bool(value)
    return value


def _as_nx3(values: ArrayLike) -> NDArray[np.float64]:
    array = np.asarray(values, dtype=np.float64)
    if array.size == 0:
        return np.zeros((0, 3), dtype=np.float64)
    return array.reshape(-1, 3)


def _as_nx4(values: ArrayLike) -> NDArray[np.float64]:
    array = np.asarray(values, dtype=np.float64)
    if array.size == 0:
        return np.zeros((0, 4), dtype=np.float64)
    return array.reshape(-1, 4)


def _tracking_reason(tracking: ArrayLike | None, n: int) -> str:
    if tracking is None or n <= 0:
        return ""
    states = np.asarray(tracking, dtype=np.int64).reshape(-1)
    if states.size == 0:
        return ""
    if np.any(states != int(TrackingState.NORMAL)):
        return "tracking not normal"
    return ""


def _verdict(
    name: str,
    status: str,
    measured: dict[str, Any],
    thresholds: dict[str, Any],
    reason: str = "",
) -> StepVerdict:
    return StepVerdict(name=name, status=status, measured=measured, thresholds=thresholds, reason=reason)


def _angle_deg(a: NDArray[np.float64], b: NDArray[np.float64]) -> float:
    na = float(np.linalg.norm(a))
    nb = float(np.linalg.norm(b))
    if na < 1e-12 or nb < 1e-12:
        return 180.0
    cosine = float(np.clip(np.dot(a, b) / (na * nb), -1.0, 1.0))
    return math.degrees(math.acos(cosine))


def _odom_up_in_link(quats: NDArray[np.float64]) -> NDArray[np.float64]:
    z = np.array([0.0, 0.0, 1.0], dtype=np.float64)
    ups = np.stack([quat_to_matrix(q).T @ z for q in quats])
    mean = np.mean(ups, axis=0)
    n = float(np.linalg.norm(mean))
    if n < 1e-12:
        return mean
    return mean / n


def judge_still(
    positions: ArrayLike,
    quats_xyzw: ArrayLike,
    tracking: ArrayLike | None,
    imu_t_ns: ArrayLike,
    specific_force_imu: ArrayLike,
) -> tuple[StepVerdict, NDArray[np.float64] | None]:
    """静止。位置のドリフト、比力の大きさ、odom の上との向きを見る。"""
    thresholds = {
        "max_drift_m": MAX_DRIFT_M,
        "sf_min": SF_MIN,
        "sf_max": SF_MAX,
        "max_up_angle_deg": MAX_UP_ANGLE_DEG,
    }
    pos = _as_nx3(positions)
    quats = _as_nx4(quats_xyzw)
    force_imu = _as_nx3(specific_force_imu)
    measured: dict[str, Any] = {
        "pose_samples": int(pos.shape[0]),
        "imu_samples": int(force_imu.shape[0]),
    }
    skip = _tracking_reason(tracking, pos.shape[0])
    if skip:
        return _verdict("still", STATUS_SKIPPED, measured, thresholds, skip), None
    if pos.shape[0] < 1 or force_imu.shape[0] < 1 or quats.shape[0] < 1:
        return _verdict("still", STATUS_SKIPPED, measured, thresholds, "too few samples"), None

    drift = float(np.max(np.linalg.norm(pos - pos[0], axis=1)))
    force_link = specific_force_imu_to_link(force_imu)
    gravity = np.mean(force_link, axis=0)
    sf_norm = float(np.linalg.norm(gravity))
    up_link = _odom_up_in_link(quats)
    angle = _angle_deg(gravity, up_link)
    measured.update(
        {
            "drift_m": drift,
            "specific_force_link": [float(v) for v in gravity],
            "specific_force_norm": sf_norm,
            "up_angle_deg": angle,
        }
    )
    if drift >= MAX_DRIFT_M:
        return _verdict("still", STATUS_FAIL, measured, thresholds, "position drift"), gravity
    if not (SF_MIN <= sf_norm <= SF_MAX):
        return _verdict("still", STATUS_FAIL, measured, thresholds, "specific force magnitude"), gravity
    if angle > MAX_UP_ANGLE_DEG:
        return _verdict("still", STATUS_FAIL, measured, thresholds, "specific force vs odom up"), gravity
    return _verdict("still", STATUS_PASS, measured, thresholds), gravity


def _displacement_in_start_link(
    positions: NDArray[np.float64], quats: NDArray[np.float64]
) -> NDArray[np.float64]:
    # ステップ開始時の link で見るので、部屋での端末の向きに依らない。
    r0 = quat_to_matrix(quats[0])
    return r0.T @ (positions[-1] - positions[0])


def judge_translation(
    positions: ArrayLike,
    quats_xyzw: ArrayLike,
    tracking: ArrayLike | None,
    *,
    axis: int,
    min_move: float,
    name: str,
) -> StepVerdict:
    """開始時の link で見た変位の、指定軸がdominantかつ正かを見る。"""
    thresholds = {
        "min_move_m": float(min_move),
        "dominance_ratio": DOMINANCE_RATIO,
        "expected_axis": int(axis),
        "expected_sign": 1,
    }
    pos = _as_nx3(positions)
    quats = _as_nx4(quats_xyzw)
    measured: dict[str, Any] = {"pose_samples": int(pos.shape[0])}
    skip = _tracking_reason(tracking, pos.shape[0])
    if skip:
        return _verdict(name, STATUS_SKIPPED, measured, thresholds, skip)
    if pos.shape[0] < 2 or quats.shape[0] < 2:
        return _verdict(name, STATUS_SKIPPED, measured, thresholds, "too few samples")

    d_link = _displacement_in_start_link(pos, quats)
    dx, dy, dz = (float(d_link[0]), float(d_link[1]), float(d_link[2]))
    measured.update({"dx": dx, "dy": dy, "dz": dz, "d_link_m": [dx, dy, dz]})
    distance = float(np.linalg.norm(d_link))
    measured["distance_m"] = distance
    if distance < float(min_move):
        return _verdict(name, STATUS_SKIPPED, measured, thresholds, "too little movement")

    primary = float(d_link[int(axis)])
    others = [abs(float(d_link[i])) for i in range(3) if i != int(axis)]
    lateral = max(others) if others else 0.0
    dominant = abs(primary) >= DOMINANCE_RATIO * lateral and abs(primary) >= float(min_move)
    measured["primary"] = primary
    measured["dominant"] = bool(dominant)
    if not dominant or primary <= 0.0:
        return _verdict(name, STATUS_FAIL, measured, thresholds, "wrong axis or sign")
    return _verdict(name, STATUS_PASS, measured, thresholds)


def _yaw_about_vertical_deg(quats: NDArray[np.float64]) -> float:
    """最初のサンプルから最後のサンプルまでに、基準の座標系の z（鉛直）まわりへ回った角度。

    姿勢そのもののオイラー角は使わない。カメラ群を上にした横置きでは imu_link の x が真上を向き、
    オイラー角の yaw が特異点になって、実機で +23 度の回転が -13 度と出た。
    隣り合うサンプルの差の回転は端末の姿勢に依らないので、その z まわりの成分を足し合わせる。
    差が小さいので、+-180 度の巻き戻りも起きない。
    """
    mats = [quat_to_matrix(q) for q in quats]
    total = 0.0
    for prev, cur in pairwise(mats):
        step = cur @ prev.T
        total += math.atan2(float(step[1, 0]), float(step[0, 0]))
    return math.degrees(total)


def judge_yaw(
    odom_quats_xyzw: ArrayLike,
    imu_quats_xyzw: ArrayLike,
    tracking: ArrayLike | None,
) -> StepVerdict:
    """上から見て反時計回りに回すと、姿勢と IMU の両方で鉛直まわりの角度が増えること。"""
    thresholds = {"min_delta_deg": MIN_YAW_DELTA_DEG}
    odom = _as_nx4(odom_quats_xyzw)
    imu = _as_nx4(imu_quats_xyzw)
    measured: dict[str, Any] = {"odom_samples": int(odom.shape[0]), "imu_samples": int(imu.shape[0])}
    skip = _tracking_reason(tracking, odom.shape[0])
    if skip:
        return _verdict("yaw", STATUS_SKIPPED, measured, thresholds, skip)
    if odom.shape[0] < 2 or imu.shape[0] < 2:
        return _verdict("yaw", STATUS_SKIPPED, measured, thresholds, "too few samples")

    odom_delta = _yaw_about_vertical_deg(odom)
    imu_delta = _yaw_about_vertical_deg(imu)
    measured["odom_yaw_delta_deg"] = odom_delta
    measured["imu_yaw_delta_deg"] = imu_delta
    if max(abs(odom_delta), abs(imu_delta)) < MIN_YAW_DELTA_DEG:
        return _verdict("yaw", STATUS_SKIPPED, measured, thresholds, "too little movement")
    if odom_delta < MIN_YAW_DELTA_DEG or imu_delta < MIN_YAW_DELTA_DEG:
        return _verdict("yaw", STATUS_FAIL, measured, thresholds, "yaw did not increase")
    return _verdict("yaw", STATUS_PASS, measured, thresholds)


def judge_push(
    imu_t_ns: ArrayLike,
    specific_force_imu: ArrayLike,
    gravity_link: ArrayLike | None,
    tracking: ArrayLike | None = None,
) -> StepVerdict:
    """動き出し直後 150 ms で、link の動加速度の x のピークが正であること。"""
    thresholds = {"onset_mps2": PUSH_ONSET_MPS2, "window_s": PUSH_WINDOW_S}
    t_ns = np.asarray(imu_t_ns, dtype=np.int64).reshape(-1)
    force_imu = _as_nx3(specific_force_imu)
    n = min(t_ns.size, force_imu.shape[0])
    measured: dict[str, Any] = {"imu_samples": int(n)}
    skip = _tracking_reason(tracking, 1 if tracking is not None else 0)
    if skip:
        return _verdict("push", STATUS_SKIPPED, measured, thresholds, skip)
    if gravity_link is None:
        return _verdict("push", STATUS_SKIPPED, measured, thresholds, "no gravity estimate")
    if n < 3:
        return _verdict("push", STATUS_SKIPPED, measured, thresholds, "too few samples")

    t_ns = t_ns[:n]
    force_link = specific_force_imu_to_link(force_imu[:n])
    gravity = np.asarray(gravity_link, dtype=np.float64).reshape(3)
    a_dyn = force_link - gravity
    norms = np.linalg.norm(a_dyn, axis=1)
    onset_candidates = np.flatnonzero(norms > PUSH_ONSET_MPS2)
    if onset_candidates.size == 0:
        measured["peak_ax"] = 0.0
        measured["peak_norm"] = float(np.max(norms)) if norms.size else 0.0
        return _verdict("push", STATUS_SKIPPED, measured, thresholds, "too little movement")

    onset = int(onset_candidates[0])
    t0 = int(t_ns[onset])
    window_ns = int(PUSH_WINDOW_S * 1_000_000_000)
    in_window = (t_ns >= t0) & (t_ns <= t0 + window_ns)
    if not np.any(in_window):
        return _verdict("push", STATUS_SKIPPED, measured, thresholds, "too little movement")

    window_idx = np.flatnonzero(in_window)
    peak_local = int(window_idx[int(np.argmax(norms[window_idx]))])
    peak_ax = float(a_dyn[peak_local, 0])
    peak_norm = float(norms[peak_local])
    measured.update(
        {
            "onset_ns": t0,
            "peak_ax": peak_ax,
            "peak_norm": peak_norm,
            "peak_t_ns": int(t_ns[peak_local]),
        }
    )
    if peak_ax <= 0.0:
        return _verdict("push", STATUS_FAIL, measured, thresholds, "accel x peak is not positive")
    return _verdict("push", STATUS_PASS, measured, thresholds)

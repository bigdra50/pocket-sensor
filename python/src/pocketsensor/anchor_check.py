"""参照画像の anchor の向きが、規約どおりかを判定する。

anchor の frame は、z が画像の表から手前へ出る法線、x が画像の上、y が画像の左である
（docs/frames-and-units.md）。
端末は画像を表から見ているので、端末の位置を anchor の座標で表すと z が正になる。
画像の上が世界のどちらを向くかは貼り方で決まるので、壁に貼ったか、机に置いたかを引数で受け取る。
"""

from __future__ import annotations

from typing import Any, Final

import numpy as np
from numpy.typing import ArrayLike

from pocketsensor.axes_check import STATUS_FAIL, STATUS_PASS, StepVerdict
from pocketsensor.frames import quat_to_matrix, relative_pose

MIN_FRONT_M: Final[float] = 0.05
# ノート PC の画面は 20 度ほど後ろへ倒れている。壁に貼った紙の傾きも含めて、この範囲は上向きとみなす。
MAX_UP_ANGLE_VERTICAL_DEG: Final[float] = 35.0
MAX_NORMAL_ANGLE_HORIZONTAL_DEG: Final[float] = 15.0
IMAGE_POSES: Final[tuple[str, ...]] = ("vertical", "horizontal")
_IDENTITY: Final[tuple[float, float, float, float]] = (0.0, 0.0, 0.0, 1.0)
_UP: Final = np.array([0.0, 0.0, 1.0], dtype=np.float64)


def _angle_deg(a: np.ndarray, b: np.ndarray) -> float:
    cosine = float(np.clip(np.dot(a, b) / (np.linalg.norm(a) * np.linalg.norm(b)), -1.0, 1.0))
    return float(np.degrees(np.arccos(cosine)))


def judge_anchor(
    anchor_position: ArrayLike,
    anchor_orientation_xyzw: ArrayLike,
    camera_position: ArrayLike,
    image_pose: str = "vertical",
) -> StepVerdict:
    """odom で表した anchor と端末の位置から、anchor の軸の向きを判定する。

    image_pose は、画像を壁や画面に立てて見せたなら vertical、机や床に置いたなら horizontal。
    """
    if image_pose not in IMAGE_POSES:
        raise ValueError(f"image_pose must be one of {IMAGE_POSES}: {image_pose!r}")
    camera_in_anchor, _ = relative_pose(anchor_position, anchor_orientation_xyzw, camera_position, _IDENTITY)
    rotation = quat_to_matrix(anchor_orientation_xyzw)
    image_up, normal = rotation[:, 0], rotation[:, 2]
    measured: dict[str, Any] = {
        "camera_in_anchor_m": [float(v) for v in camera_in_anchor],
        "distance_m": float(np.linalg.norm(camera_in_anchor)),
        "up_angle_deg": _angle_deg(image_up, _UP),
        "normal_angle_deg": _angle_deg(normal, _UP),
    }
    thresholds: dict[str, Any] = {
        "min_front_m": MIN_FRONT_M,
        "max_up_angle_vertical_deg": MAX_UP_ANGLE_VERTICAL_DEG,
        "max_normal_angle_horizontal_deg": MAX_NORMAL_ANGLE_HORIZONTAL_DEG,
        "image_pose": image_pose,
    }

    def verdict(status: str, reason: str = "") -> StepVerdict:
        return StepVerdict("anchor", status, measured, thresholds, reason)

    if camera_in_anchor[2] < MIN_FRONT_M:
        return verdict(STATUS_FAIL, "the camera is behind the image: z does not point out of the front")
    if image_pose == "vertical" and measured["up_angle_deg"] > MAX_UP_ANGLE_VERTICAL_DEG:
        return verdict(STATUS_FAIL, "the x axis of the anchor does not point up along the image")
    if image_pose == "horizontal" and measured["normal_angle_deg"] > MAX_NORMAL_ANGLE_HORIZONTAL_DEG:
        return verdict(STATUS_FAIL, "the z axis of the anchor does not point up out of the image")
    return verdict(STATUS_PASS)

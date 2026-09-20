"""カメラ内部パラメータの縮尺と、深度の逆投影。"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np
from numpy.typing import ArrayLike, NDArray


@dataclass(frozen=True)
class Intrinsics:
    width: int
    height: int
    fx: float
    fy: float
    cx: float
    cy: float
    distortion_model: str = "plumb_bob"
    distortion: tuple[float, ...] = (0.0, 0.0, 0.0, 0.0, 0.0)


def scale_intrinsics(intrinsics: Intrinsics, new_width: int, new_height: int) -> Intrinsics:
    """画素中心を原点とする規約で、主点へ 0.5 の補正を入れて縮尺する。"""
    sx = new_width / intrinsics.width
    sy = new_height / intrinsics.height
    return Intrinsics(
        width=new_width,
        height=new_height,
        fx=intrinsics.fx * sx,
        fy=intrinsics.fy * sy,
        cx=(intrinsics.cx + 0.5) * sx - 0.5,
        cy=(intrinsics.cy + 0.5) * sy - 0.5,
        distortion_model=intrinsics.distortion_model,
        distortion=intrinsics.distortion,
    )


def camera_info_matrices(
    intrinsics: Intrinsics,
) -> tuple[list[float], list[float], list[float], list[float]]:
    """K は行優先 9、R は単位、P は [K | 0]、D は distortion。"""
    fx, fy, cx, cy = intrinsics.fx, intrinsics.fy, intrinsics.cx, intrinsics.cy
    k = [fx, 0.0, cx, 0.0, fy, cy, 0.0, 0.0, 1.0]
    r = [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]
    p = [fx, 0.0, cx, 0.0, 0.0, fy, cy, 0.0, 0.0, 0.0, 1.0, 0.0]
    d = [float(v) for v in intrinsics.distortion]
    return k, r, p, d


def deproject(depth_m: ArrayLike, intrinsics: Intrinsics) -> NDArray[np.float64]:
    """光学 frame（x 右、y 下、z 前方）へ逆投影する。NaN は NaN のまま。"""
    z = np.asarray(depth_m, dtype=np.float64)
    if z.ndim != 2:
        raise ValueError("depth_m must be a 2-D array")
    height, width = z.shape
    u = np.arange(width, dtype=np.float64)
    v = np.arange(height, dtype=np.float64)
    uu, vv = np.meshgrid(u, v)
    x = (uu - intrinsics.cx) * z / intrinsics.fx
    y = (vv - intrinsics.cy) * z / intrinsics.fy
    return np.stack([x, y, z], axis=-1)

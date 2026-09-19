"""受け手が扱う値の型。配列は numpy。"""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import IntEnum

import numpy as np
from numpy.typing import NDArray

from pocketsensor.intrinsics import Intrinsics


class TrackingState(IntEnum):
    NOT_AVAILABLE = 0
    LIMITED = 1
    NORMAL = 2


class TrackingReason(IntEnum):
    NONE = 0
    INITIALIZING = 1
    EXCESSIVE_MOTION = 2
    INSUFFICIENT_FEATURES = 3
    RELOCALIZING = 4


@dataclass(frozen=True)
class PoseSample:
    position: NDArray[np.float64]
    orientation_xyzw: NDArray[np.float64]
    frame_id: str
    child_frame_id: str
    covariance: NDArray[np.float64]


@dataclass(frozen=True)
class TrackingStatus:
    state: int
    reason: int
    origin_epoch: int


@dataclass(frozen=True)
class ColorFrame:
    image: NDArray[np.uint8] | None
    jpeg: bytes
    intrinsics: Intrinsics
    frame_id: str


@dataclass(frozen=True)
class DepthFrame:
    raw: NDArray[np.uint16]
    intrinsics: Intrinsics
    frame_id: str
    _cache: dict[str, NDArray[np.float32]] = field(default_factory=dict, repr=False, compare=False)

    @property
    def meters(self) -> NDArray[np.float32]:
        cached = self._cache.get("meters")
        if cached is not None:
            return cached
        metres = self.raw.astype(np.float32) * np.float32(0.001)
        metres[self.raw == 0] = np.float32("nan")
        self._cache["meters"] = metres
        return metres


@dataclass(frozen=True)
class ConfidenceFrame:
    levels: NDArray[np.uint8]


@dataclass(frozen=True)
class ImuSample:
    t_device_ns: int
    arrival_ns: int
    angular_velocity: NDArray[np.float64]
    linear_acceleration: NDArray[np.float64]
    orientation_xyzw: NDArray[np.float64] | None


@dataclass(frozen=True)
class MagSample:
    t_device_ns: int
    arrival_ns: int
    field: NDArray[np.float64]
    covariance: NDArray[np.float64]


@dataclass(frozen=True)
class PressureSample:
    t_device_ns: int
    arrival_ns: int
    pascal: float
    variance: float = 0.0


@dataclass(frozen=True)
class GnssFix:
    lat: float
    lon: float
    alt: float
    covariance9: NDArray[np.float64]
    status: int
    service: int
    time_ref_ns: int | None
    t_device_ns: int = 0
    arrival_ns: int = 0


@dataclass(frozen=True)
class BatteryStatus:
    percentage: float
    power_supply_status: int
    t_device_ns: int = 0
    arrival_ns: int = 0


@dataclass(frozen=True)
class DeviceInfo:
    schema_version: int
    session_id: str
    name: str
    model: str
    os_version: str
    app_version: str
    mode: str
    streams: dict
    clock: dict
    frames: dict
    raw: dict

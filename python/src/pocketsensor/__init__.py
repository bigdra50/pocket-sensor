from __future__ import annotations

from pocketsensor.calibration import Calibration
from pocketsensor.clock import ClockNotReady, ClockView
from pocketsensor.config import Config, FramePolicy, TimeDomain
from pocketsensor.device import Device, DeviceStats, open
from pocketsensor.errors import (
    ConnectionFailed,
    ConnectionLost,
    PocketSensorError,
    ProtocolError,
    Unsupported,
)
from pocketsensor.frameset import FrameSet
from pocketsensor.intrinsics import Intrinsics, deproject
from pocketsensor.streams import Battery, Color, Depth, Gnss, Imu, Mag, Pose, Pressure, Stream
from pocketsensor.types import (
    BatteryStatus,
    ColorFrame,
    ConfidenceFrame,
    DepthFrame,
    DeviceInfo,
    GnssFix,
    ImuSample,
    MagSample,
    PoseSample,
    PressureSample,
    TrackingReason,
    TrackingState,
    TrackingStatus,
)

__version__ = "0.1.0"

__all__ = [
    "Battery",
    "BatteryStatus",
    "Calibration",
    "ClockNotReady",
    "ClockView",
    "Color",
    "ColorFrame",
    "Config",
    "ConfidenceFrame",
    "ConnectionFailed",
    "ConnectionLost",
    "Depth",
    "DepthFrame",
    "Device",
    "DeviceInfo",
    "DeviceStats",
    "FramePolicy",
    "FrameSet",
    "Gnss",
    "GnssFix",
    "Imu",
    "ImuSample",
    "Intrinsics",
    "Mag",
    "MagSample",
    "PocketSensorError",
    "Pose",
    "PoseSample",
    "Pressure",
    "PressureSample",
    "ProtocolError",
    "Stream",
    "TimeDomain",
    "TrackingReason",
    "TrackingState",
    "TrackingStatus",
    "Unsupported",
    "__version__",
    "deproject",
    "open",
]

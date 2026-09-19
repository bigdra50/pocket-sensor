"""購読するストリームと、それが触るチャンネル・parameters。"""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum

from pocketsensor._generated.contract_data import CHANNELS


class Stream(Enum):
    COLOR = "color"
    DEPTH = "depth"
    CONFIDENCE = "confidence"
    POSE = "pose"
    IMU = "imu"
    IMU_RAW = "imu_raw"
    MAG = "mag"
    PRESSURE = "pressure"
    GNSS = "gnss"
    BATTERY = "battery"


CAMERA_STREAMS: frozenset[Stream] = frozenset({Stream.COLOR, Stream.DEPTH, Stream.CONFIDENCE, Stream.POSE})

_TOPIC_BY_KEY: dict[str, str] = {str(row["key"]): str(row["topic"]) for row in CHANNELS}


def channel_topic(key: str, name: str) -> str:
    """契約の topic テンプレートへ端末名を入れる。"""
    template = _TOPIC_BY_KEY[key]
    return template.replace("<name>", name)


def channel_row(key: str) -> dict[str, object]:
    for row in CHANNELS:
        if row["key"] == key:
            return row
    raise KeyError(key)


@dataclass(frozen=True)
class Color:
    rate: float | None = None
    width: int | None = None
    jpeg_quality: float | None = None
    decode: bool = True

    @property
    def stream(self) -> Stream:
        return Stream.COLOR

    def channel_keys(self) -> tuple[str, ...]:
        return ("color_image", "color_camera_info")

    def parameters(self) -> dict[str, float | int]:
        out: dict[str, float | int] = {}
        if self.rate is not None:
            out["color.rate"] = self.rate
        if self.width is not None:
            out["color.width"] = self.width
        if self.jpeg_quality is not None:
            out["color.jpeg_quality"] = self.jpeg_quality
        return out


@dataclass(frozen=True)
class Depth:
    rate: float | None = None
    confidence: bool = True

    @property
    def stream(self) -> Stream:
        return Stream.DEPTH

    def channel_keys(self) -> tuple[str, ...]:
        keys = ("depth_image", "depth_camera_info")
        if self.confidence:
            return (*keys, "depth_confidence")
        return keys

    def parameters(self) -> dict[str, float | int]:
        if self.rate is None:
            return {}
        return {"depth.rate": self.rate}


@dataclass(frozen=True)
class Pose:
    rate: float | None = None

    @property
    def stream(self) -> Stream:
        return Stream.POSE

    def channel_keys(self) -> tuple[str, ...]:
        return ("odom", "tf", "tracking")

    def parameters(self) -> dict[str, float | int]:
        if self.rate is None:
            return {}
        return {"pose.rate": self.rate}


@dataclass(frozen=True)
class Imu:
    rate: float | None = None
    raw: bool = False

    @property
    def stream(self) -> Stream:
        return Stream.IMU

    def channel_keys(self) -> tuple[str, ...]:
        if self.raw:
            return ("imu", "imu_raw")
        return ("imu",)

    def parameters(self) -> dict[str, float | int]:
        if self.rate is None:
            return {}
        return {"imu.rate": self.rate}


@dataclass(frozen=True)
class Mag:
    @property
    def stream(self) -> Stream:
        return Stream.MAG

    def channel_keys(self) -> tuple[str, ...]:
        return ("mag",)

    def parameters(self) -> dict[str, float | int]:
        return {}


@dataclass(frozen=True)
class Pressure:
    @property
    def stream(self) -> Stream:
        return Stream.PRESSURE

    def channel_keys(self) -> tuple[str, ...]:
        return ("pressure",)

    def parameters(self) -> dict[str, float | int]:
        return {}


@dataclass(frozen=True)
class Gnss:
    @property
    def stream(self) -> Stream:
        return Stream.GNSS

    def channel_keys(self) -> tuple[str, ...]:
        return ("gnss_fix", "gnss_time_reference")

    def parameters(self) -> dict[str, float | int]:
        return {}


@dataclass(frozen=True)
class Battery:
    @property
    def stream(self) -> Stream:
        return Stream.BATTERY

    def channel_keys(self) -> tuple[str, ...]:
        return ("battery",)

    def parameters(self) -> dict[str, float | int]:
        return {}


StreamSpec = Color | Depth | Pose | Imu | Mag | Pressure | Gnss | Battery

RATE_PARAM_BY_STREAM: dict[Stream, str] = {
    Stream.POSE: "pose.rate",
    Stream.COLOR: "color.rate",
    Stream.DEPTH: "depth.rate",
    Stream.CONFIDENCE: "depth.rate",
    Stream.IMU: "imu.rate",
    Stream.IMU_RAW: "imu.rate",
}

"""開くときに決める設定。"""

from __future__ import annotations

from collections.abc import Sequence
from dataclasses import dataclass
from enum import Enum

from pocketsensor.streams import CAMERA_STREAMS, Depth, Stream, StreamSpec


class FramePolicy(Enum):
    REQUIRE_ALL = "require_all"
    ANY = "any"


class TimeDomain(Enum):
    DEVICE = "device"
    HOST_ARRIVAL = "host_arrival"
    HOST = "host"


@dataclass(frozen=True)
class Config:
    streams: Sequence[StreamSpec]
    frame_policy: FramePolicy = FramePolicy.REQUIRE_ALL
    imu_buffer_seconds: float = 2.0
    open_timeout: float = 5.0
    clock_sync: bool = True

    def required_camera_streams(self) -> set[Stream]:
        required: set[Stream] = set()
        for spec in self.streams:
            stream = spec.stream
            if stream in CAMERA_STREAMS:
                required.add(stream)
            if isinstance(spec, Depth) and spec.confidence:
                required.add(Stream.CONFIDENCE)
        return required

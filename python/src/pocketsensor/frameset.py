"""同じ計測時刻のカメラ系データを組にする。"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from pocketsensor.clock import ClockView
from pocketsensor.config import FramePolicy, TimeDomain
from pocketsensor.errors import ClockNotReady, Unsupported
from pocketsensor.streams import Stream
from pocketsensor.types import (
    ColorFrame,
    ConfidenceFrame,
    DepthFrame,
    PoseSample,
    TrackingStatus,
)

_MAX_PENDING = 8


@dataclass
class _Pending:
    t_device_ns: int
    arrival_ns: int = 0
    members: dict[Stream, Any] = field(default_factory=dict)
    tracking: TrackingStatus | None = None

    def complete(self, required: set[Stream]) -> bool:
        return required <= set(self.members)


@dataclass
class FrameSet:
    color: ColorFrame | None
    depth: DepthFrame | None
    confidence: ConfidenceFrame | None
    pose: PoseSample | None
    tracking: TrackingStatus | None
    t_device_ns: int
    arrival_ns: int
    _clock: ClockView | None = field(default=None, repr=False, compare=False)
    _allow_host_arrival: bool = field(default=True, repr=False, compare=False)

    def timestamp(self, domain: TimeDomain) -> int:
        if domain is TimeDomain.DEVICE:
            return self.t_device_ns
        if domain is TimeDomain.HOST_ARRIVAL:
            if not self._allow_host_arrival:
                raise Unsupported("HOST_ARRIVAL is not available in playback")
            return self.arrival_ns
        if domain is TimeDomain.HOST:
            if self._clock is None or not self._clock.ready:
                raise ClockNotReady("no clock samples")
            return int(self._clock.device_to_host(self.t_device_ns))
        raise ValueError(f"unknown time domain: {domain!r}")

    @property
    def latency_ns(self) -> int:
        """HOST_ARRIVAL から HOST を引いた値。計測から到着までの遅延。"""
        if not self._allow_host_arrival:
            raise Unsupported("HOST_ARRIVAL is not available in playback")
        host = self.timestamp(TimeDomain.HOST)
        return int(self.arrival_ns - host)


def _finalize(pending: _Pending, clock: ClockView | None = None) -> FrameSet:
    members = pending.members
    return FrameSet(
        color=members.get(Stream.COLOR),
        depth=members.get(Stream.DEPTH),
        confidence=members.get(Stream.CONFIDENCE),
        pose=members.get(Stream.POSE),
        tracking=pending.tracking,
        t_device_ns=pending.t_device_ns,
        arrival_ns=pending.arrival_ns,
        _clock=clock,
    )


class FrameSetAssembler:
    """t_device_ns の一致で FrameSet を組む。tracking は揃いの条件に入れない。"""

    def __init__(self, required: set[Stream], policy: FramePolicy) -> None:
        self._required = set(required)
        self._policy = policy
        self._pending: dict[int, _Pending] = {}
        self.dropped_incomplete = 0

    @property
    def pending_count(self) -> int:
        return len(self._pending)

    def feed(self, stream: Stream | str, t_device_ns: int, value: Any, arrival_ns: int) -> list[FrameSet]:
        emitted: list[FrameSet] = []
        is_tracking = stream == "tracking"
        if not is_tracking and self._policy is FramePolicy.ANY:
            older = sorted(t for t in self._pending if t < t_device_ns)
            for old_t in older:
                emitted.append(_finalize(self._pending.pop(old_t)))
        slot = self._pending.get(t_device_ns)
        if slot is None:
            slot = _Pending(t_device_ns=t_device_ns)
            self._pending[t_device_ns] = slot
        slot.arrival_ns = max(slot.arrival_ns, int(arrival_ns))
        if is_tracking:
            slot.tracking = value
        else:
            slot.members[stream] = value  # type: ignore[index]
            if self._policy is FramePolicy.REQUIRE_ALL and slot.complete(self._required):
                emitted.append(_finalize(self._pending.pop(t_device_ns)))
                for old_t in [t for t in self._pending if t < t_device_ns]:
                    del self._pending[old_t]
                    self.dropped_incomplete += 1
        self._trim()
        return emitted

    def flush(self) -> list[FrameSet]:
        if self._policy is not FramePolicy.ANY:
            return []
        out = [_finalize(self._pending.pop(t)) for t in sorted(self._pending)]
        return out

    def _trim(self) -> None:
        while len(self._pending) > _MAX_PENDING:
            oldest = min(self._pending)
            del self._pending[oldest]
            self.dropped_incomplete += 1

"""短い時間窓のサンプル列と、最新 1 件。"""

from __future__ import annotations

from collections import deque
from typing import Generic, Protocol, TypeVar


class Timed(Protocol):
    t_device_ns: int


T = TypeVar("T", bound=Timed)
U = TypeVar("U")


class SampleBuffer(Generic[T]):
    """新しいサンプルの時刻を基準に、max_age_s より古い未読を捨てる。"""

    def __init__(self, max_age_s: float) -> None:
        self._max_age_ns = int(max_age_s * 1_000_000_000)
        self._samples: deque[T] = deque()
        self.dropped = 0

    def append(self, sample: T) -> None:
        t_ns = int(sample.t_device_ns)
        self._samples.append(sample)
        cutoff = t_ns - self._max_age_ns
        while self._samples:
            oldest = self._samples[0]
            oldest_t = int(oldest.t_device_ns)
            if oldest_t >= cutoff:
                break
            self._samples.popleft()
            self.dropped += 1

    def last(self) -> T | None:
        if not self._samples:
            return None
        return self._samples[-1]

    def read_all(self) -> list[T]:
        out = list(self._samples)
        self._samples.clear()
        return out


class LatestValue(Generic[U]):
    def __init__(self) -> None:
        self._value: U | None = None

    def set(self, value: U) -> None:
        self._value = value

    def get(self) -> U | None:
        return self._value

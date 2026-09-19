"""往復 4 時刻から端末時計と受け手時計のずれを推定する。"""

from __future__ import annotations

from dataclasses import dataclass

from pocketsensor.errors import ClockNotReady

__all__ = ["ClockEstimator", "ClockNotReady", "ClockSample", "ClockView"]


@dataclass(frozen=True)
class ClockSample:
    t1: int
    t2: int
    t3: int
    t4: int

    @property
    def rtt(self) -> int:
        return (self.t4 - self.t1) - (self.t3 - self.t2)

    @property
    def offset(self) -> float:
        # 端末時計から受け手時計を引いた値
        return ((self.t2 - self.t1) + (self.t3 - self.t4)) / 2.0


def _theil_sen(points: list[tuple[float, float]]) -> float:
    slopes: list[float] = []
    for i, (xi, yi) in enumerate(points):
        for xj, yj in points[i + 1 :]:
            dx = xj - xi
            if dx == 0.0:
                continue
            slopes.append((yj - yi) / dx)
    if not slopes:
        return 0.0
    slopes.sort()
    n = len(slopes)
    mid = n // 2
    if n % 2 == 1:
        return slopes[mid]
    return 0.5 * (slopes[mid - 1] + slopes[mid])


class ClockEstimator:
    def __init__(self, window: int = 8, max_adopted: int = 64) -> None:
        self._window = window
        self._max_adopted = max_adopted
        self._samples: list[ClockSample] = []
        self._adopted: list[tuple[float, float]] = []
        self._adopted_key: tuple[int, int, int, int] | None = None
        self._sample_count = 0

    def add(self, sample: ClockSample) -> None:
        if sample.t4 < sample.t1:
            raise ValueError(f"t4 precedes t1: t1={sample.t1} t4={sample.t4}")
        if sample.rtt < 0:
            raise ValueError(f"negative rtt: t1={sample.t1} t2={sample.t2} t3={sample.t3} t4={sample.t4}")
        self._samples.append(sample)
        self._sample_count += 1
        if self._window > 0 and len(self._samples) > self._window:
            self._samples = self._samples[-self._window :]
        best = self._best()
        assert best is not None
        key = (best.t1, best.t2, best.t3, best.t4)
        if key != self._adopted_key:
            self._adopted_key = key
            t_mid = (best.t1 + best.t4) / 2.0
            self._adopted.append((t_mid, best.offset))
            if len(self._adopted) > self._max_adopted:
                self._adopted = self._adopted[-self._max_adopted :]

    def _best(self) -> ClockSample | None:
        recent = self._samples[-self._window :] if self._window > 0 else []
        if not recent:
            return None
        # rtt が同じなら、並びの後ろ＝新しいほうを採る
        best = recent[0]
        for sample in recent[1:]:
            if sample.rtt <= best.rtt:
                best = sample
        return best

    @property
    def ready(self) -> bool:
        return bool(self._samples)

    @property
    def sample_count(self) -> int:
        return self._sample_count

    @property
    def offset_ns(self) -> float:
        best = self._best()
        if best is None:
            raise ClockNotReady("no clock samples")
        return best.offset

    @property
    def rtt_ns(self) -> int:
        best = self._best()
        if best is None:
            raise ClockNotReady("no clock samples")
        return best.rtt

    @property
    def drift(self) -> float:
        if len(self._adopted) < 3:
            return 0.0
        return _theil_sen(self._adopted)

    @property
    def drift_ppm(self) -> float:
        return self.drift * 1e6

    def device_to_host(self, t_device_ns: int | float) -> float:
        if not self.ready or not self._adopted:
            raise ClockNotReady("no clock samples")
        t_ref, offset_ref = self._adopted[-1]
        t_device = float(t_device_ns)
        return t_device - (offset_ref + self.drift * ((t_device - offset_ref) - t_ref))


class ClockView:
    """単調時計向けと壁時計向けの 2 つの推定を読む。"""

    def __init__(self, host: ClockEstimator, wall: ClockEstimator, lock: object | None = None) -> None:
        self._host = host
        self._wall = wall
        self._lock = lock

    def _guard(self):
        return self._lock if self._lock is not None else _NullCM()

    @property
    def ready(self) -> bool:
        with self._guard():
            return self._host.ready

    @property
    def offset_ns(self) -> float:
        with self._guard():
            return self._host.offset_ns

    @property
    def rtt_ns(self) -> int:
        with self._guard():
            return self._host.rtt_ns

    @property
    def drift_ppm(self) -> float:
        with self._guard():
            return self._host.drift_ppm

    @property
    def sample_count(self) -> int:
        with self._guard():
            return self._host.sample_count

    def device_to_host(self, t_device_ns: int | float) -> float:
        with self._guard():
            return self._host.device_to_host(t_device_ns)

    def device_to_wall(self, t_device_ns: int | float) -> float:
        with self._guard():
            return self._wall.device_to_host(t_device_ns)


class _NullCM:
    def __enter__(self) -> None:
        return None

    def __exit__(self, *args: object) -> None:
        return None

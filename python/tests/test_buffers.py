from __future__ import annotations

from dataclasses import dataclass

from pocketsensor.buffers import LatestValue, SampleBuffer


@dataclass(frozen=True)
class _S:
    t_device_ns: int
    value: int


def test_sample_buffer_read_all_drains_in_order() -> None:
    buf = SampleBuffer(max_age_s=2.0)
    buf.append(_S(1, 1))
    buf.append(_S(2, 2))
    assert [s.value for s in buf.read_all()] == [1, 2]
    assert buf.read_all() == []


def test_sample_buffer_drops_unread_older_than_max_age() -> None:
    buf = SampleBuffer(max_age_s=1.0)
    buf.append(_S(0, 0))
    buf.append(_S(500_000_000, 1))
    buf.append(_S(1_500_000_000, 2))
    samples = buf.read_all()
    assert [s.value for s in samples] == [1, 2]
    assert buf.dropped == 1


def test_sample_buffer_last_does_not_drain() -> None:
    buf = SampleBuffer(max_age_s=2.0)
    assert buf.last() is None
    buf.append(_S(1, 1))
    buf.append(_S(2, 2))
    assert buf.last() is not None
    assert buf.last().value == 2
    assert [s.value for s in buf.read_all()] == [1, 2]
    assert buf.last() is None


def test_latest_value_set_get() -> None:
    slot: LatestValue[int] = LatestValue()
    assert slot.get() is None
    slot.set(4)
    assert slot.get() == 4
    slot.set(5)
    assert slot.get() == 5

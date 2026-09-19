from __future__ import annotations

import numpy as np
import pytest

from pocketsensor.config import FramePolicy
from pocketsensor.frameset import FrameSetAssembler
from pocketsensor.streams import Stream
from pocketsensor.types import PoseSample, TrackingStatus


def _pose(x: float = 0.0) -> PoseSample:
    return PoseSample(
        position=np.array([x, 0.0, 0.0], dtype=np.float64),
        orientation_xyzw=np.array([0.0, 0.0, 0.0, 1.0], dtype=np.float64),
        frame_id="odom",
        child_frame_id="link",
        covariance=np.zeros(36, dtype=np.float64),
    )


def _tracking(state: int = 2) -> TrackingStatus:
    return TrackingStatus(state=state, reason=0, origin_epoch=0)


def test_require_all_emits_when_every_required_member_arrives() -> None:
    asm = FrameSetAssembler(required={Stream.COLOR, Stream.DEPTH}, policy=FramePolicy.REQUIRE_ALL)
    assert asm.feed(Stream.COLOR, 100, "c", 1) == []
    sets = asm.feed(Stream.DEPTH, 100, "d", 7)
    assert len(sets) == 1
    fs = sets[0]
    assert fs.t_device_ns == 100
    assert fs.color == "c"
    assert fs.depth == "d"
    assert fs.arrival_ns == 7


def test_require_all_groups_by_exact_timestamp() -> None:
    asm = FrameSetAssembler(required={Stream.POSE}, policy=FramePolicy.REQUIRE_ALL)
    asm.feed(Stream.POSE, 1, _pose(1.0), 10)
    later = asm.feed(Stream.POSE, 2, _pose(2.0), 11)
    assert later[0].t_device_ns == 2
    assert later[0].pose is not None
    assert later[0].pose.position[0] == pytest.approx(2.0)


def test_tracking_is_attached_but_never_required() -> None:
    asm = FrameSetAssembler(required={Stream.POSE}, policy=FramePolicy.REQUIRE_ALL)
    assert asm.feed("tracking", 5, _tracking(2), 1) == []
    sets = asm.feed(Stream.POSE, 5, _pose(), 2)
    assert len(sets) == 1
    assert sets[0].tracking is not None
    assert sets[0].tracking.state == 2


def test_any_emits_older_set_when_newer_timestamp_arrives() -> None:
    asm = FrameSetAssembler(required={Stream.COLOR, Stream.DEPTH}, policy=FramePolicy.ANY)
    assert asm.feed(Stream.COLOR, 100, "c0", 1) == []
    sets = asm.feed(Stream.COLOR, 200, "c1", 2)
    assert len(sets) == 1
    assert sets[0].t_device_ns == 100
    assert sets[0].color == "c0"
    assert sets[0].depth is None


def test_any_flush_emits_pending() -> None:
    asm = FrameSetAssembler(required={Stream.COLOR, Stream.DEPTH}, policy=FramePolicy.ANY)
    asm.feed(Stream.DEPTH, 9, "d", 3)
    sets = asm.flush()
    assert len(sets) == 1
    assert sets[0].depth == "d"
    assert asm.flush() == []


def test_require_all_drops_incomplete_older_than_complete() -> None:
    asm = FrameSetAssembler(required={Stream.COLOR, Stream.DEPTH}, policy=FramePolicy.REQUIRE_ALL)
    asm.feed(Stream.COLOR, 100, "old", 1)
    asm.feed(Stream.COLOR, 200, "c", 2)
    sets = asm.feed(Stream.DEPTH, 200, "d", 3)
    assert len(sets) == 1
    assert sets[0].t_device_ns == 200
    assert asm.dropped_incomplete == 1


def test_pending_bound_drops_oldest() -> None:
    asm = FrameSetAssembler(required={Stream.COLOR, Stream.DEPTH}, policy=FramePolicy.REQUIRE_ALL)
    for i in range(9):
        asm.feed(Stream.COLOR, i, f"c{i}", i)
    assert asm.dropped_incomplete >= 1
    assert asm.pending_count <= 8


def test_require_all_flush_does_not_emit_incomplete() -> None:
    asm = FrameSetAssembler(required={Stream.COLOR, Stream.POSE}, policy=FramePolicy.REQUIRE_ALL)
    asm.feed(Stream.COLOR, 1, "c", 1)
    assert asm.flush() == []

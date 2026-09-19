from __future__ import annotations

import pytest

from pocketsensor._generated.contract_data import CHANNELS
from pocketsensor.errors import ProtocolError
from pocketsensor.stamp import rewrite_header_stamp

_HEADER_SCHEMAS = sorted({str(row["schema"]) for row in CHANNELS})


def _ns(sec: int, nanosec: int) -> int:
    return int(sec) * 1_000_000_000 + int(nanosec)


def _stamp_of(msg) -> int:
    return _ns(int(msg.header.stamp.sec), int(msg.header.stamp.nanosec))


def _add_one_second(t_ns: int) -> int:
    return t_ns + 1_000_000_000


def _raise_map(_t_ns: int) -> int:
    raise AssertionError("map_ns must not be called")


def _make_stamped(codec, schema: str, *, sec: int, nanosec: int, frame_id: str = "frame"):
    header = {"stamp": {"sec": sec, "nanosec": nanosec}, "frame_id": frame_id}
    if schema == "std_msgs/msg/String":
        return codec.make(schema, data='{"name":"pocketsensor"}')
    if schema == "tf2_msgs/msg/TFMessage":
        return codec.make(
            schema,
            transforms=[
                {
                    "header": header,
                    "child_frame_id": "child",
                    "transform": {
                        "translation": {"x": 1.0, "y": 2.0, "z": 3.0},
                        "rotation": {"x": 0.0, "y": 0.0, "z": 0.0, "w": 1.0},
                    },
                }
            ],
        )
    kwargs: dict = {"header": header}
    if schema == "sensor_msgs/msg/TimeReference":
        kwargs["time_ref"] = {"sec": 9, "nanosec": 8}
        kwargs["source"] = "gnss"
    if schema == "sensor_msgs/msg/Image":
        kwargs.update(height=1, width=1, encoding="16UC1", step=2, data=b"\x01\x02")
    if schema == "sensor_msgs/msg/CompressedImage":
        kwargs.update(format="jpeg", data=b"\xff\xd8\xff")
    return codec.make(schema, **kwargs)


@pytest.mark.parametrize("schema", _HEADER_SCHEMAS)
def test_rewrite_roundtrip_every_channel_schema(codec, schema: str) -> None:
    msg = _make_stamped(codec, schema, sec=11, nanosec=22)
    encoded = codec.encode(schema, msg)
    if schema == "std_msgs/msg/String":
        patched = rewrite_header_stamp(schema, encoded, _raise_map)
        assert patched == encoded
        back = codec.decode(schema, patched)
        assert back.data == msg.data
        return
    patched = rewrite_header_stamp(schema, encoded, _add_one_second)
    assert patched != encoded
    back = codec.decode(schema, patched)
    if schema == "tf2_msgs/msg/TFMessage":
        assert len(back.transforms) == 1
        assert _stamp_of(back.transforms[0]) == _ns(12, 22)
        assert back.transforms[0].header.frame_id == "frame"
        assert back.transforms[0].child_frame_id == "child"
        assert back.transforms[0].transform.translation.x == pytest.approx(1.0)
        return
    assert _stamp_of(back) == _ns(12, 22)
    assert back.header.frame_id == "frame"
    if schema == "sensor_msgs/msg/TimeReference":
        assert int(back.time_ref.sec) == 9
        assert int(back.time_ref.nanosec) == 8


def _tf(codec, rows: list[tuple[str, str, int, int]]):
    transforms = []
    for frame_id, child, sec, nanosec in rows:
        transforms.append(
            {
                "header": {"stamp": {"sec": sec, "nanosec": nanosec}, "frame_id": frame_id},
                "child_frame_id": child,
                "transform": {
                    "translation": {"x": 0.5, "y": -0.25, "z": 0.125},
                    "rotation": {"x": 0.0, "y": 0.0, "z": 0.0, "w": 1.0},
                },
            }
        )
    return codec.make("tf2_msgs/msg/TFMessage", transforms=transforms)


def test_tf_message_zero_transforms_leaves_bytes_and_skips_map(codec) -> None:
    msg = codec.make("tf2_msgs/msg/TFMessage", transforms=[])
    encoded = codec.encode("tf2_msgs/msg/TFMessage", msg)
    patched = rewrite_header_stamp("tf2_msgs/msg/TFMessage", encoded, _raise_map)
    assert patched == encoded
    back = codec.decode("tf2_msgs/msg/TFMessage", patched)
    assert list(back.transforms) == []


@pytest.mark.parametrize(
    "rows",
    [
        [("a", "b", 1, 2)],
        [("ab", "cd", 3, 4)],
        [("abc", "def", 5, 6)],
        [("abcd", "efgh", 7, 8)],
        [("abcde", "fghij", 9, 10)],
        [("", "p", 10, 100), ("x", "qq", 11, 101), ("yyyy", "rrr", 12, 102)],
    ],
)
def test_tf_message_alignment_with_varied_frame_ids(codec, rows) -> None:
    msg = _tf(codec, rows)
    encoded = codec.encode("tf2_msgs/msg/TFMessage", msg)
    patched = rewrite_header_stamp("tf2_msgs/msg/TFMessage", encoded, _add_one_second)
    back = codec.decode("tf2_msgs/msg/TFMessage", patched)
    assert len(back.transforms) == len(rows)
    for tf, (frame_id, child, sec, nanosec) in zip(back.transforms, rows, strict=True):
        assert tf.header.frame_id == frame_id
        assert tf.child_frame_id == child
        assert _stamp_of(tf) == _ns(sec + 1, nanosec)
        assert tf.transform.translation.x == pytest.approx(0.5)


def test_header_first_patch_is_copy_and_only_touches_stamp(codec) -> None:
    msg = codec.make(
        "sensor_msgs/msg/Imu",
        header={"stamp": {"sec": 4, "nanosec": 5}, "frame_id": "imu_link"},
        linear_acceleration={"z": 9.5},
    )
    encoded = codec.encode("sensor_msgs/msg/Imu", msg)
    patched = rewrite_header_stamp("sensor_msgs/msg/Imu", encoded, _add_one_second)
    assert patched is not encoded
    restored = bytearray(patched)
    restored[4:12] = encoded[4:12]
    assert bytes(restored) == encoded


def test_malformed_input_raises_protocol_error(codec) -> None:
    with pytest.raises(ProtocolError):
        rewrite_header_stamp("sensor_msgs/msg/Imu", b"", _add_one_second)
    with pytest.raises(ProtocolError):
        rewrite_header_stamp("sensor_msgs/msg/Imu", b"\x00\x01\x00\x00", _add_one_second)
    empty_tf = codec.encode("tf2_msgs/msg/TFMessage", codec.make("tf2_msgs/msg/TFMessage"))
    truncated = empty_tf[:4] + (1).to_bytes(4, "little")
    with pytest.raises(ProtocolError):
        rewrite_header_stamp("tf2_msgs/msg/TFMessage", truncated, _add_one_second)
    overlong = bytearray(
        b"\x00\x01\x00\x00" + (1).to_bytes(4, "little") + bytes(8) + (50).to_bytes(4, "little")
    )
    with pytest.raises(ProtocolError):
        rewrite_header_stamp("tf2_msgs/msg/TFMessage", bytes(overlong), _add_one_second)


def test_big_endian_payload_is_rejected_instead_of_being_corrupted(codec) -> None:
    msg = _make_stamped(codec, "sensor_msgs/msg/Imu", sec=11, nanosec=22)
    encoded = codec.encode("sensor_msgs/msg/Imu", msg)
    big_endian = b"\x00\x00" + encoded[2:]
    with pytest.raises(ProtocolError):
        rewrite_header_stamp("sensor_msgs/msg/Imu", big_endian, _add_one_second)

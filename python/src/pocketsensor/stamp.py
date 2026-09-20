"""CDR の header.stamp だけを、デコードせずに書き換える。"""

from __future__ import annotations

import struct
from collections.abc import Callable

from pocketsensor.errors import ProtocolError

# ROS 2 CDR のカプセル化ヘッダ。stamp は直後の 8 バイト（sec int32 LE、nanosec uint32 LE）。
_ENCAP = 4
_CDR_LE = b"\x00\x01"
_STAMP = 8
_NS_PER_SEC = 1_000_000_000
_SEC_MIN = -2_147_483_648
_SEC_MAX = 2_147_483_647
_STRING = "std_msgs/msg/String"
_TF = "tf2_msgs/msg/TFMessage"
# Transform は float64 が 7 個。Vector3 の先頭が 8 バイト整列を要求する。
_TRANSFORM_BYTES = 7 * 8

__all__ = ["rewrite_header_stamp"]


def rewrite_header_stamp(schema_name: str, cdr: bytes, map_ns: Callable[[int], int]) -> bytes:
    """device の wire 時刻を map_ns でシステム時刻へ換算し、Header.stamp だけを差し替える。

    先頭が std_msgs/Header の型は、バイト 4..12 をコピー上で書き換える。
    TFMessage は配列の各 TransformStamped の Header を辿る。
    String はそのまま返す。壊れた入力は ProtocolError。
    """
    if schema_name == _STRING:
        return cdr
    if len(cdr) < _ENCAP:
        raise ProtocolError("CDR payload is shorter than the encapsulation header")
    if cdr[:2] != _CDR_LE:
        # 契約は little endian だけを流す。別の並びを同じ offset で書き換えると、壊れた時刻を黙って出す。
        raise ProtocolError(f"unsupported CDR encapsulation: {cdr[:2].hex()}")
    out = bytearray(cdr)
    if schema_name == _TF:
        _rewrite_tf(out, map_ns)
        return bytes(out)
    if len(out) < _ENCAP + _STAMP:
        raise ProtocolError("CDR payload is truncated before header.stamp")
    _patch_stamp(out, _ENCAP, map_ns)
    return bytes(out)


def _align(offset: int, alignment: int) -> int:
    rem = offset % alignment
    if rem == 0:
        return offset
    return offset + (alignment - rem)


def _need(buf: bytearray, offset: int, size: int, what: str) -> None:
    if offset < 0 or offset + size > len(buf):
        raise ProtocolError(f"truncated CDR while reading {what}")


def _read_u32(buf: bytearray, offset: int) -> int:
    _need(buf, offset, 4, "uint32")
    return int(struct.unpack_from("<I", buf, offset)[0])


def _read_stamp_ns(buf: bytearray, offset: int) -> int:
    _need(buf, offset, _STAMP, "header.stamp")
    sec, nanosec = struct.unpack_from("<iI", buf, offset)
    return int(sec) * _NS_PER_SEC + int(nanosec)


def _patch_stamp(buf: bytearray, offset: int, map_ns: Callable[[int], int]) -> None:
    mapped = int(map_ns(_read_stamp_ns(buf, offset)))
    sec, nanosec = divmod(mapped, _NS_PER_SEC)
    if not _SEC_MIN <= sec <= _SEC_MAX:
        raise ProtocolError(f"mapped timestamp sec exceeds int32: {sec}")
    if not 0 <= nanosec < _NS_PER_SEC:
        raise ProtocolError(f"mapped timestamp nanosec out of range: {nanosec}")
    struct.pack_into("<iI", buf, offset, sec, nanosec)


def _skip_string(buf: bytearray, payload_off: int) -> int:
    """ペイロード先頭を原点にした offset から CDR 文字列を読み飛ばす。返り値も同じ原点。"""
    file_off = _ENCAP + _align(payload_off, 4)
    length = _read_u32(buf, file_off)
    data_off = file_off + 4
    _need(buf, data_off, length, "string")
    return (data_off + length) - _ENCAP


def _rewrite_tf(buf: bytearray, map_ns: Callable[[int], int]) -> None:
    seq_off = _align(0, 4)
    count = _read_u32(buf, _ENCAP + seq_off)
    payload_off = seq_off + 4
    for _ in range(count):
        payload_off = _align(payload_off, 4)
        _patch_stamp(buf, _ENCAP + payload_off, map_ns)
        payload_off += _STAMP
        payload_off = _skip_string(buf, payload_off)
        payload_off = _skip_string(buf, payload_off)
        payload_off = _align(payload_off, 8)
        end = payload_off + _TRANSFORM_BYTES
        _need(buf, _ENCAP + payload_off, _TRANSFORM_BYTES, "Transform")
        payload_off = end

"""ROS 2 CDR のエンコードとデコード。契約の .msg だけを型の正本にする。"""

from __future__ import annotations

from dataclasses import fields
from typing import Any

import numpy as np
from rosbags.interfaces import Nodetype
from rosbags.typesys import Stores, get_types_from_msg, get_typestore
from rosbags.typesys.store import Typestore

from pocketsensor._generated.contract_data import MSG_TEXTS

_SEP = "\n" + ("=" * 80) + "\n"

_DTYPE = {
    "bool": np.bool_,
    "byte": np.uint8,
    "char": np.uint8,
    "int8": np.int8,
    "uint8": np.uint8,
    "int16": np.int16,
    "uint16": np.uint16,
    "int32": np.int32,
    "uint32": np.uint32,
    "int64": np.int64,
    "uint64": np.uint64,
    "float32": np.float32,
    "float64": np.float64,
}


def _ensure_nl(text: str) -> str:
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    if text.endswith("\n"):
        return text.rstrip("\n") + "\n"
    return text + "\n"


def _looks_like_srv(name: str) -> bool:
    return name.endswith("_Request") or name.endswith("_Response")


def canonical_type_name(label: str) -> str:
    """MSG: 行の型名を契約の型名（pkg/msg/Name または pkg/srv/Name）にする。"""
    parts = label.split("/")
    if len(parts) == 3:
        return label
    if len(parts) != 2:
        raise ValueError(f"malformed type label: {label!r}")
    pkg, name = parts
    if _looks_like_srv(name):
        return f"{pkg}/srv/{name}"
    return f"{pkg}/msg/{name}"


def parse_concatenated_schema(schema_name: str, schema_text: str) -> dict[str, str]:
    """連結した ros2msg 本文を型名ごとの定義に分ける。"""
    text = schema_text.replace("\r\n", "\n").replace("\r", "\n")
    if not text.endswith("\n"):
        text += "\n"
    parts = text.split(_SEP)
    texts: dict[str, str] = {}
    first = parts[0]
    if first.startswith("MSG:"):
        header, _, body = first.partition("\n")
        texts[canonical_type_name(header[4:].strip())] = _ensure_nl(body)
    else:
        texts[schema_name] = _ensure_nl(first)
    for part in parts[1:]:
        header, _, body = part.partition("\n")
        if not header.startswith("MSG:"):
            raise ValueError(f"schema block missing MSG: header: {header!r}")
        texts[canonical_type_name(header[4:].strip())] = _ensure_nl(body)
    return texts


def _parse_name_for_rosbags(canonical: str) -> str:
    return canonical.replace("/srv/", "/msg/")


def _parse_msg(raw: str, canonical: str) -> dict:
    parse_name = _parse_name_for_rosbags(canonical)
    parsed = get_types_from_msg(raw, parse_name)
    out = {}
    for key, value in parsed.items():
        out[canonical if key == parse_name else key] = value
    return out


def _as_float(value: Any) -> float:
    if isinstance(value, str):
        if value == "NaN":
            return float("nan")
        if value == "Infinity":
            return float("inf")
        if value == "-Infinity":
            return float("-inf")
    return float(value)


class CdrCodec:
    """契約の型定義を rosbags の空の typestore へ載せ、CDR を往復する。"""

    def __init__(self, store: Typestore) -> None:
        self._store = store

    @classmethod
    def from_contract(cls) -> CdrCodec:
        store = get_typestore(Stores.EMPTY)
        types: dict = {}
        for name, raw in MSG_TEXTS.items():
            for key, value in _parse_msg(raw, name).items():
                if key not in types:
                    types[key] = value
        store.register(types)
        return cls(store)

    @property
    def store(self) -> Typestore:
        return self._store

    def register_schema(self, schema_name: str, schema_text: str) -> None:
        texts = parse_concatenated_schema(schema_name, schema_text)
        to_register: dict = {}
        for name, raw in texts.items():
            if name in self._store.fielddefs:
                continue
            for key, value in _parse_msg(raw, name).items():
                if key not in self._store.fielddefs and key not in to_register:
                    to_register[key] = value
        if to_register:
            self._store.register(to_register)

    def _is_empty(self, schema_name: str) -> bool:
        field_list = self._store.fielddefs[schema_name][1]
        return field_list == [] or (
            len(field_list) == 1 and field_list[0][0] == "structure_needs_at_least_one_member"
        )

    def decode(self, schema_name: str, data: bytes) -> Any:
        payload = data
        # 空メッセージはヘッダだけの形も受け付ける
        if self._is_empty(schema_name) and len(data) == 4:
            payload = data + b"\x00"
        return self._store.deserialize_cdr(payload, schema_name)

    def encode(self, schema_name: str, message: Any) -> bytes:
        return bytes(self._store.serialize_cdr(message, schema_name))

    def make(self, schema_name: str, **overrides: Any) -> Any:
        msg = self._zero(schema_name)
        if not overrides:
            return msg
        return self._apply(msg, overrides)

    def _zero(self, schema_name: str) -> Any:
        cls = self._store.types[schema_name]
        kwargs = {}
        for fname, desc in self._store.fielddefs[schema_name][1]:
            kwargs[fname] = self._zero_desc(desc)
        return cls(**kwargs)

    def _zero_desc(self, desc: Any) -> Any:
        kind = desc[0]
        if kind == Nodetype.BASE:
            basename, _limit = desc[1]
            if basename == "string":
                return ""
            if basename == "bool":
                return False
            if basename in {"float32", "float64"}:
                return 0.0
            return 0
        if kind == Nodetype.NAME:
            return self._zero(desc[1])
        inner, count = desc[1]
        if kind == Nodetype.ARRAY:
            if inner[0] == Nodetype.BASE:
                basename = inner[1][0]
                return np.zeros(count, dtype=_DTYPE[basename])
            return [self._zero_desc(inner) for _ in range(count)]
        if inner[0] == Nodetype.BASE:
            basename = inner[1][0]
            if basename == "string":
                return []
            return np.zeros(0, dtype=_DTYPE[basename])
        return []

    def _apply(self, msg: Any, overrides: dict[str, Any]) -> Any:
        schema_name = type(msg).__msgtype__
        fieldmap = {name: desc for name, desc in self._store.fielddefs[schema_name][1]}
        kwargs = {}
        for field in fields(msg):
            if field.name == "__msgtype__":
                continue
            kwargs[field.name] = getattr(msg, field.name)
        for key, value in overrides.items():
            kwargs[key] = self._coerce(fieldmap[key], value)
        return self._store.types[schema_name](**kwargs)

    def _coerce(self, desc: Any, value: Any) -> Any:
        kind = desc[0]
        if isinstance(value, dict) and kind == Nodetype.NAME:
            return self._apply(self._zero(desc[1]), value)
        if kind == Nodetype.NAME:
            return value
        if kind == Nodetype.BASE:
            basename = desc[1][0]
            if basename == "string":
                return str(value)
            if basename == "bool":
                return bool(value)
            if basename in {"float32", "float64"}:
                return _as_float(value)
            return int(value)
        inner, count = desc[1]
        if kind in (Nodetype.ARRAY, Nodetype.SEQUENCE) and inner[0] == Nodetype.BASE:
            basename = inner[1][0]
            if basename in {"uint8", "byte", "char"}:
                if isinstance(value, str):
                    raw = bytes.fromhex(value)
                    return np.frombuffer(raw, dtype=np.uint8).copy()
                if isinstance(value, (bytes, bytearray, memoryview)):
                    return np.frombuffer(bytes(value), dtype=np.uint8).copy()
            coerced = [_as_float(v) if basename.startswith("float") else v for v in value]
            arr = np.asarray(coerced, dtype=_DTYPE[basename])
            if kind == Nodetype.ARRAY and arr.shape != (count,):
                raise ValueError(f"expected shape ({count},), got {arr.shape}")
            return arr
        if kind in (Nodetype.ARRAY, Nodetype.SEQUENCE) and inner[0] == Nodetype.NAME:
            return [self._coerce(inner, item) if isinstance(item, dict) else item for item in value]
        return value

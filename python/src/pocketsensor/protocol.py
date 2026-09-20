"""Foxglove WebSocket プロトコル v1 のエンコード。ソケットを持たない。"""

from __future__ import annotations

import json
import struct
from collections.abc import Sequence
from dataclasses import dataclass
from typing import Any

from pocketsensor.errors import ProtocolError

SUBPROTOCOLS: tuple[str, str] = ("foxglove.sdk.v1", "foxglove.websocket.v1")

_OP_MESSAGE_DATA = 0x01
_OP_TIME = 0x02
_OP_SERVICE_CALL_RESPONSE = 0x03
_OP_SERVICE_CALL_REQUEST = 0x02


def _dumps(obj: dict[str, Any]) -> str:
    return json.dumps(obj, ensure_ascii=False, separators=(",", ":"))


def _require(obj: dict[str, Any], key: str) -> Any:
    if key not in obj:
        raise ProtocolError(f"missing field {key!r}")
    return obj[key]


@dataclass(frozen=True)
class ServerInfo:
    name: str
    capabilities: tuple[str, ...]
    supported_encodings: tuple[str, ...]
    metadata: dict[str, str]
    session_id: str


@dataclass(frozen=True)
class ChannelInfo:
    id: int
    topic: str
    encoding: str
    schema_name: str
    schema: str
    schema_encoding: str


@dataclass(frozen=True)
class Advertise:
    channels: tuple[ChannelInfo, ...]


@dataclass(frozen=True)
class Unadvertise:
    channel_ids: tuple[int, ...]


@dataclass(frozen=True)
class SchemaInfo:
    encoding: str
    schema_name: str
    schema_encoding: str
    schema: str


@dataclass(frozen=True)
class ServiceInfo:
    id: int
    name: str
    type: str
    request: SchemaInfo
    response: SchemaInfo


@dataclass(frozen=True)
class AdvertiseServices:
    services: tuple[ServiceInfo, ...]


@dataclass(frozen=True)
class UnadvertiseServices:
    service_ids: tuple[int, ...]


@dataclass(frozen=True)
class ParameterValue:
    name: str
    value: Any
    type: str | None = None


@dataclass(frozen=True)
class ParameterValues:
    parameters: tuple[ParameterValue, ...]
    id: str | None = None


@dataclass(frozen=True)
class StatusMessage:
    level: int
    message: str
    id: str | None = None


@dataclass(frozen=True)
class RemoveStatus:
    status_ids: tuple[str, ...]


@dataclass(frozen=True)
class MessageData:
    subscription_id: int
    log_time_ns: int
    payload: memoryview | bytes


@dataclass(frozen=True)
class TimeMessage:
    timestamp_ns: int


@dataclass(frozen=True)
class ServiceCallResponse:
    service_id: int
    call_id: int
    encoding: str
    payload: memoryview | bytes


@dataclass(frozen=True)
class ServiceCallFailure:
    service_id: int
    call_id: int
    message: str


@dataclass(frozen=True)
class UnknownOp:
    op: str
    raw: dict[str, Any]


@dataclass(frozen=True)
class UnknownBinary:
    opcode: int
    data: bytes


def _parse_channel(raw: dict[str, Any]) -> ChannelInfo:
    return ChannelInfo(
        id=int(_require(raw, "id")),
        topic=str(_require(raw, "topic")),
        encoding=str(_require(raw, "encoding")),
        schema_name=str(_require(raw, "schemaName")),
        schema=str(raw.get("schema", "")),
        schema_encoding=str(raw.get("schemaEncoding", "")),
    )


def _parse_schema_info(raw: dict[str, Any]) -> SchemaInfo:
    return SchemaInfo(
        encoding=str(raw.get("encoding", "")),
        schema_name=str(raw.get("schemaName", "")),
        schema_encoding=str(raw.get("schemaEncoding", "")),
        schema=str(raw.get("schema", "")),
    )


def _parse_service(raw: dict[str, Any]) -> ServiceInfo:
    request = raw.get("request")
    response = raw.get("response")
    if not isinstance(request, dict) or not isinstance(response, dict):
        raise ProtocolError("service is missing request/response schema info")
    return ServiceInfo(
        id=int(_require(raw, "id")),
        name=str(_require(raw, "name")),
        type=str(_require(raw, "type")),
        request=_parse_schema_info(request),
        response=_parse_schema_info(response),
    )


def _parse_parameter(raw: dict[str, Any]) -> ParameterValue:
    return ParameterValue(
        name=str(_require(raw, "name")),
        value=raw.get("value"),
        type=str(raw["type"]) if "type" in raw and raw["type"] is not None else None,
    )


def parse_server_text(text: str) -> object:
    """サーバーの JSON 制御メッセージを型へ落とす。未知の op は例外にしない。"""
    try:
        obj = json.loads(text)
    except json.JSONDecodeError as exc:
        raise ProtocolError(f"invalid JSON: {exc}") from exc
    if not isinstance(obj, dict):
        raise ProtocolError("JSON control message must be an object")
    op = obj.get("op")
    if not isinstance(op, str) or not op:
        raise ProtocolError("control message is missing op")
    if op == "serverInfo":
        return ServerInfo(
            name=str(_require(obj, "name")),
            capabilities=tuple(str(v) for v in obj.get("capabilities", [])),
            supported_encodings=tuple(str(v) for v in obj.get("supportedEncodings", [])),
            metadata={str(k): str(v) for k, v in dict(obj.get("metadata") or {}).items()},
            session_id=str(obj.get("sessionId", "")),
        )
    if op == "advertise":
        channels = _require(obj, "channels")
        if not isinstance(channels, list):
            raise ProtocolError("advertise.channels must be a list")
        return Advertise(channels=tuple(_parse_channel(ch) for ch in channels))
    if op == "unadvertise":
        ids = _require(obj, "channelIds")
        return Unadvertise(channel_ids=tuple(int(v) for v in ids))
    if op == "status":
        return StatusMessage(
            level=int(_require(obj, "level")),
            message=str(_require(obj, "message")),
            id=str(obj["id"]) if obj.get("id") is not None else None,
        )
    if op == "removeStatus":
        return RemoveStatus(status_ids=tuple(str(v) for v in _require(obj, "statusIds")))
    if op == "parameterValues":
        params = _require(obj, "parameters")
        if not isinstance(params, list):
            raise ProtocolError("parameterValues.parameters must be a list")
        ident = obj.get("id")
        return ParameterValues(
            parameters=tuple(_parse_parameter(p) for p in params),
            id=str(ident) if ident is not None else None,
        )
    if op == "advertiseServices":
        services = _require(obj, "services")
        if not isinstance(services, list):
            raise ProtocolError("advertiseServices.services must be a list")
        return AdvertiseServices(services=tuple(_parse_service(s) for s in services))
    if op == "unadvertiseServices":
        return UnadvertiseServices(service_ids=tuple(int(v) for v in _require(obj, "serviceIds")))
    if op == "serviceCallFailure":
        return ServiceCallFailure(
            service_id=int(_require(obj, "serviceId")),
            call_id=int(_require(obj, "callId")),
            message=str(obj.get("message", "")),
        )
    return UnknownOp(op=op, raw=obj)


def parse_server_binary(data: bytes | bytearray | memoryview) -> object:
    """サーバーの binary フレームを型へ落とす。未知の opcode は例外にしない。"""
    buf = bytes(data)
    if not buf:
        raise ProtocolError("empty binary frame")
    opcode = buf[0]
    if opcode == _OP_MESSAGE_DATA:
        if len(buf) < 13:
            raise ProtocolError("truncated Message Data")
        sub_id = struct.unpack_from("<I", buf, 1)[0]
        log_time = struct.unpack_from("<Q", buf, 5)[0]
        return MessageData(subscription_id=sub_id, log_time_ns=log_time, payload=memoryview(buf)[13:])
    if opcode == _OP_TIME:
        if len(buf) != 9:
            raise ProtocolError("truncated Time message")
        return TimeMessage(timestamp_ns=struct.unpack_from("<Q", buf, 1)[0])
    if opcode == _OP_SERVICE_CALL_RESPONSE:
        if len(buf) < 13:
            raise ProtocolError("truncated Service Call Response")
        service_id, call_id, enc_len = struct.unpack_from("<III", buf, 1)
        end = 13 + enc_len
        if len(buf) < end:
            raise ProtocolError("truncated Service Call Response encoding")
        encoding = buf[13:end].decode("utf-8")
        return ServiceCallResponse(
            service_id=service_id,
            call_id=call_id,
            encoding=encoding,
            payload=memoryview(buf)[end:],
        )
    return UnknownBinary(opcode=opcode, data=buf)


def build_subscribe(subscriptions: Sequence[tuple[int, int]]) -> str:
    return _dumps(
        {
            "op": "subscribe",
            "subscriptions": [
                {"id": int(sub_id), "channelId": int(ch_id)} for sub_id, ch_id in subscriptions
            ],
        }
    )


def build_unsubscribe(subscription_ids: Sequence[int]) -> str:
    return _dumps({"op": "unsubscribe", "subscriptionIds": [int(v) for v in subscription_ids]})


def build_get_parameters(names: Sequence[str], request_id: str | None = None) -> str:
    obj: dict[str, Any] = {"op": "getParameters", "parameterNames": list(names)}
    if request_id is not None:
        obj["id"] = request_id
    return _dumps(obj)


def build_set_parameters(parameters: Sequence[ParameterValue], request_id: str | None = None) -> str:
    params = []
    for item in parameters:
        entry: dict[str, Any] = {"name": item.name, "value": item.value}
        if item.type is not None:
            entry["type"] = item.type
        params.append(entry)
    obj: dict[str, Any] = {"op": "setParameters", "parameters": params}
    if request_id is not None:
        obj["id"] = request_id
    return _dumps(obj)


def build_subscribe_parameter_updates(names: Sequence[str]) -> str:
    return _dumps({"op": "subscribeParameterUpdates", "parameterNames": list(names)})


def build_unsubscribe_parameter_updates(names: Sequence[str]) -> str:
    return _dumps({"op": "unsubscribeParameterUpdates", "parameterNames": list(names)})


def build_service_call_request(
    service_id: int,
    call_id: int,
    encoding: str,
    payload: bytes | bytearray | memoryview,
) -> bytes:
    enc = encoding.encode("utf-8")
    return (
        bytes([_OP_SERVICE_CALL_REQUEST])
        + struct.pack("<III", int(service_id), int(call_id), len(enc))
        + enc
        + bytes(payload)
    )


def build_message_data(
    subscription_id: int,
    log_time_ns: int,
    payload: bytes | bytearray | memoryview,
) -> bytes:
    header = struct.pack("<IQ", int(subscription_id), int(log_time_ns))
    return bytes([_OP_MESSAGE_DATA]) + header + bytes(payload)


def build_service_call_response(
    service_id: int,
    call_id: int,
    encoding: str,
    payload: bytes | bytearray | memoryview,
) -> bytes:
    enc = encoding.encode("utf-8")
    return (
        bytes([_OP_SERVICE_CALL_RESPONSE])
        + struct.pack("<III", int(service_id), int(call_id), len(enc))
        + enc
        + bytes(payload)
    )


def build_server_info(
    name: str,
    capabilities: Sequence[str],
    supported_encodings: Sequence[str],
    session_id: str,
    metadata: dict[str, str] | None = None,
) -> str:
    return _dumps(
        {
            "op": "serverInfo",
            "name": name,
            "capabilities": list(capabilities),
            "supportedEncodings": list(supported_encodings),
            "metadata": dict(metadata or {}),
            "sessionId": session_id,
        }
    )


def build_advertise(channels: Sequence[ChannelInfo]) -> str:
    return _dumps(
        {
            "op": "advertise",
            "channels": [
                {
                    "id": ch.id,
                    "topic": ch.topic,
                    "encoding": ch.encoding,
                    "schemaName": ch.schema_name,
                    "schema": ch.schema,
                    "schemaEncoding": ch.schema_encoding,
                }
                for ch in channels
            ],
        }
    )


def build_advertise_services(services: Sequence[ServiceInfo]) -> str:
    return _dumps(
        {
            "op": "advertiseServices",
            "services": [
                {
                    "id": svc.id,
                    "name": svc.name,
                    "type": svc.type,
                    "request": {
                        "encoding": svc.request.encoding,
                        "schemaName": svc.request.schema_name,
                        "schemaEncoding": svc.request.schema_encoding,
                        "schema": svc.request.schema,
                    },
                    "response": {
                        "encoding": svc.response.encoding,
                        "schemaName": svc.response.schema_name,
                        "schemaEncoding": svc.response.schema_encoding,
                        "schema": svc.response.schema,
                    },
                }
                for svc in services
            ],
        }
    )


def build_parameter_values(parameters: Sequence[ParameterValue], request_id: str | None = None) -> str:
    params = []
    for item in parameters:
        entry: dict[str, Any] = {"name": item.name, "value": item.value}
        if item.type is not None:
            entry["type"] = item.type
        params.append(entry)
    obj: dict[str, Any] = {"op": "parameterValues", "parameters": params}
    if request_id is not None:
        obj["id"] = request_id
    return _dumps(obj)


def build_service_call_failure(service_id: int, call_id: int, message: str) -> str:
    return _dumps(
        {
            "op": "serviceCallFailure",
            "serviceId": int(service_id),
            "callId": int(call_id),
            "message": message,
        }
    )

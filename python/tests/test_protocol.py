from __future__ import annotations

import json
import struct

import pytest

from pocketsensor.errors import ProtocolError
from pocketsensor.protocol import (
    SUBPROTOCOLS,
    Advertise,
    AdvertiseServices,
    ChannelInfo,
    MessageData,
    ParameterValue,
    ParameterValues,
    RemoveStatus,
    SchemaInfo,
    ServerInfo,
    ServiceCallFailure,
    ServiceCallResponse,
    ServiceInfo,
    StatusMessage,
    TimeMessage,
    Unadvertise,
    UnadvertiseServices,
    UnknownBinary,
    UnknownOp,
    build_get_parameters,
    build_service_call_request,
    build_set_parameters,
    build_subscribe,
    build_subscribe_parameter_updates,
    build_unsubscribe,
    build_unsubscribe_parameter_updates,
    parse_server_binary,
    parse_server_text,
)


def test_subprotocol_order_prefers_sdk() -> None:
    assert SUBPROTOCOLS[0] == "foxglove.sdk.v1"
    assert SUBPROTOCOLS[1] == "foxglove.websocket.v1"


def test_server_info_round_trip() -> None:
    text = json.dumps(
        {
            "op": "serverInfo",
            "name": "pocketsensor",
            "capabilities": ["parameters", "parametersSubscribe", "services"],
            "supportedEncodings": ["cdr"],
            "metadata": {"k": "v"},
            "sessionId": "abc",
        }
    )
    parsed = parse_server_text(text)
    assert isinstance(parsed, ServerInfo)
    assert parsed.name == "pocketsensor"
    assert parsed.capabilities == ("parameters", "parametersSubscribe", "services")
    assert parsed.supported_encodings == ("cdr",)
    assert parsed.session_id == "abc"
    assert parsed.metadata == {"k": "v"}


def test_advertise_and_unadvertise() -> None:
    text = json.dumps(
        {
            "op": "advertise",
            "channels": [
                {
                    "id": 3,
                    "topic": "/pocketsensor/odom",
                    "encoding": "cdr",
                    "schemaName": "nav_msgs/msg/Odometry",
                    "schema": "x",
                    "schemaEncoding": "ros2msg",
                }
            ],
        }
    )
    adv = parse_server_text(text)
    assert isinstance(adv, Advertise)
    assert adv.channels[0] == ChannelInfo(
        id=3,
        topic="/pocketsensor/odom",
        encoding="cdr",
        schema_name="nav_msgs/msg/Odometry",
        schema="x",
        schema_encoding="ros2msg",
    )
    un = parse_server_text(json.dumps({"op": "unadvertise", "channelIds": [3, 4]}))
    assert isinstance(un, Unadvertise)
    assert un.channel_ids == (3, 4)


def test_status_and_remove_status() -> None:
    st = parse_server_text(json.dumps({"op": "status", "level": 2, "message": "boom", "id": "s1"}))
    assert st == StatusMessage(level=2, message="boom", id="s1")
    st2 = parse_server_text(json.dumps({"op": "status", "level": 0, "message": "ok"}))
    assert st2 == StatusMessage(level=0, message="ok", id=None)
    rm = parse_server_text(json.dumps({"op": "removeStatus", "statusIds": ["s1"]}))
    assert isinstance(rm, RemoveStatus)
    assert rm.status_ids == ("s1",)


def test_parameter_values() -> None:
    msg = parse_server_text(
        json.dumps(
            {
                "op": "parameterValues",
                "id": "req-1",
                "parameters": [
                    {"name": "pose.rate", "value": 15.0, "type": "float64"},
                    {"name": "device.name", "value": "pocketsensor"},
                ],
            }
        )
    )
    assert isinstance(msg, ParameterValues)
    assert msg.id == "req-1"
    assert msg.parameters[0] == ParameterValue(name="pose.rate", value=15.0, type="float64")
    assert msg.parameters[1] == ParameterValue(name="device.name", value="pocketsensor", type=None)


def test_advertise_services_and_unadvertise() -> None:
    req = {
        "encoding": "cdr",
        "schemaName": "pocketsensor_msgs/srv/ClockSync_Request",
        "schemaEncoding": "ros2msg",
        "schema": "uint64 t1\n",
    }
    res = {
        "encoding": "cdr",
        "schemaName": "pocketsensor_msgs/srv/ClockSync_Response",
        "schemaEncoding": "ros2msg",
        "schema": "uint64 t1\n",
    }
    msg = parse_server_text(
        json.dumps(
            {
                "op": "advertiseServices",
                "services": [
                    {
                        "id": 1,
                        "name": "/pocketsensor/clock_sync",
                        "type": "pocketsensor_msgs/srv/ClockSync",
                        "request": req,
                        "response": res,
                    }
                ],
            }
        )
    )
    assert isinstance(msg, AdvertiseServices)
    assert msg.services[0] == ServiceInfo(
        id=1,
        name="/pocketsensor/clock_sync",
        type="pocketsensor_msgs/srv/ClockSync",
        request=SchemaInfo(
            encoding="cdr",
            schema_name="pocketsensor_msgs/srv/ClockSync_Request",
            schema_encoding="ros2msg",
            schema="uint64 t1\n",
        ),
        response=SchemaInfo(
            encoding="cdr",
            schema_name="pocketsensor_msgs/srv/ClockSync_Response",
            schema_encoding="ros2msg",
            schema="uint64 t1\n",
        ),
    )
    un = parse_server_text(json.dumps({"op": "unadvertiseServices", "serviceIds": [1]}))
    assert isinstance(un, UnadvertiseServices)
    assert un.service_ids == (1,)


def test_service_call_failure() -> None:
    msg = parse_server_text(
        json.dumps({"op": "serviceCallFailure", "serviceId": 9, "callId": 4, "message": "nope"})
    )
    assert msg == ServiceCallFailure(service_id=9, call_id=4, message="nope")


def test_unknown_op_is_not_an_error() -> None:
    raw = {"op": "fetchAsset", "uri": "package://x", "requestId": 1}
    parsed = parse_server_text(json.dumps(raw))
    assert isinstance(parsed, UnknownOp)
    assert parsed.op == "fetchAsset"
    assert parsed.raw["uri"] == "package://x"


def test_malformed_text_raises() -> None:
    with pytest.raises(ProtocolError):
        parse_server_text("{")
    with pytest.raises(ProtocolError):
        parse_server_text("[]")
    with pytest.raises(ProtocolError):
        parse_server_text("{}")
    with pytest.raises(ProtocolError):
        parse_server_text(json.dumps({"op": "advertise"}))
    with pytest.raises(ProtocolError):
        parse_server_text(json.dumps({"op": "serverInfo"}))


def test_message_data_layout_little_endian() -> None:
    payload = b"cdr-bytes"
    data = b"\x01" + struct.pack("<I", 100) + struct.pack("<Q", 0x18D6AEB0864F3998) + payload
    parsed = parse_server_binary(data)
    assert isinstance(parsed, MessageData)
    assert parsed.subscription_id == 100
    assert parsed.log_time_ns == 0x18D6AEB0864F3998
    assert bytes(parsed.payload) == payload


def test_time_message_layout() -> None:
    data = b"\x02" + struct.pack("<Q", 123456789)
    parsed = parse_server_binary(data)
    assert parsed == TimeMessage(timestamp_ns=123456789)


def test_service_call_response_layout() -> None:
    encoding = b"cdr"
    payload = b"\x00\x01"
    data = (
        b"\x03"
        + struct.pack("<I", 7)
        + struct.pack("<I", 11)
        + struct.pack("<I", len(encoding))
        + encoding
        + payload
    )
    parsed = parse_server_binary(data)
    assert isinstance(parsed, ServiceCallResponse)
    assert parsed.service_id == 7
    assert parsed.call_id == 11
    assert parsed.encoding == "cdr"
    assert bytes(parsed.payload) == payload


def test_unknown_binary_opcode() -> None:
    data = b"\x04\x00\x00"
    parsed = parse_server_binary(data)
    assert isinstance(parsed, UnknownBinary)
    assert parsed.opcode == 4
    assert parsed.data == data


def test_malformed_binary_raises() -> None:
    with pytest.raises(ProtocolError):
        parse_server_binary(b"")
    with pytest.raises(ProtocolError):
        parse_server_binary(b"\x01\x00")
    with pytest.raises(ProtocolError):
        parse_server_binary(b"\x02\x00\x00")
    with pytest.raises(ProtocolError):
        parse_server_binary(b"\x03" + struct.pack("<I", 1) + struct.pack("<I", 2) + struct.pack("<I", 10))


def test_client_json_builders_round_trip() -> None:
    sub = json.loads(build_subscribe([(1, 2), (3, 4)]))
    assert sub == {"op": "subscribe", "subscriptions": [{"id": 1, "channelId": 2}, {"id": 3, "channelId": 4}]}
    unsub = json.loads(build_unsubscribe([1, 3]))
    assert unsub == {"op": "unsubscribe", "subscriptionIds": [1, 3]}
    getp = json.loads(build_get_parameters(["pose.rate"], request_id="r1"))
    assert getp == {"op": "getParameters", "parameterNames": ["pose.rate"], "id": "r1"}
    setp = json.loads(build_set_parameters([ParameterValue("pose.rate", 12.0, "float64")], request_id="r2"))
    assert setp["op"] == "setParameters"
    assert setp["id"] == "r2"
    assert setp["parameters"] == [{"name": "pose.rate", "value": 12.0, "type": "float64"}]
    subp = json.loads(build_subscribe_parameter_updates(["color.rate"]))
    assert subp == {"op": "subscribeParameterUpdates", "parameterNames": ["color.rate"]}
    unp = json.loads(build_unsubscribe_parameter_updates(["color.rate"]))
    assert unp == {"op": "unsubscribeParameterUpdates", "parameterNames": ["color.rate"]}


def test_service_call_request_layout_little_endian() -> None:
    encoding = b"cdr"
    payload = b"\xaa\xbb"
    built = build_service_call_request(service_id=5, call_id=9, encoding="cdr", payload=payload)
    assert built[0] == 0x02
    assert struct.unpack_from("<I", built, 1)[0] == 5
    assert struct.unpack_from("<I", built, 5)[0] == 9
    assert struct.unpack_from("<I", built, 9)[0] == 3
    assert built[13:16] == encoding
    assert built[16:] == payload
    assert built == b"\x02" + struct.pack("<III", 5, 9, 3) + encoding + payload

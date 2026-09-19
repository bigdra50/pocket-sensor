from __future__ import annotations

import time

import foxglove
from foxglove import Channel, Context, Schema

from pocketsensor._generated.contract_data import SCHEMA_TEXTS
from pocketsensor.cdr import CdrCodec
from pocketsensor.client import FoxgloveClient
from pocketsensor.protocol import ChannelInfo
from pocketsensor.transport import WebSocketTransport, connect


def _wait_until(pred, timeout: float, interval: float = 0.02) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if pred():
            return
        time.sleep(min(interval, max(0.0, deadline - time.monotonic())))
    raise AssertionError("deadline exceeded")


def test_conformance_official_sdk_server() -> None:
    codec = CdrCodec.from_contract()
    schema_name = "std_msgs/msg/String"
    schema_text = SCHEMA_TEXTS[schema_name]
    payload = codec.encode(schema_name, codec.make(schema_name, data="hello"))
    context = Context()
    server = foxglove.start_server(
        name="foxglove-sdk",
        host="127.0.0.1",
        port=0,
        supported_encodings=["cdr"],
        context=context,
    )
    channel = Channel(
        "/conformance",
        message_encoding="cdr",
        schema=Schema(name=schema_name, encoding="ros2msg", data=schema_text.encode("utf-8")),
        context=context,
    )
    transport = connect(f"ws://127.0.0.1:{server.port}", timeout=5.0)
    client = FoxgloveClient(transport)
    received: list[tuple[ChannelInfo, int, bytes]] = []

    def on_message(
        info: ChannelInfo,
        log_time_ns: int,
        data: bytes,
        arrival_mono: int,
        arrival_wall: int,
    ) -> None:
        received.append((info, log_time_ns, data))

    client.on_message = on_message
    try:
        assert isinstance(transport, WebSocketTransport)
        assert transport.subprotocol == "foxglove.sdk.v1"
        server_info = client.wait_ready(timeout=5.0)
        assert server_info.name == "foxglove-sdk"
        advertised = client.channels.get("/conformance")
        assert advertised is not None
        assert advertised.encoding == "cdr"
        assert advertised.schema_encoding == "ros2msg"
        assert advertised.schema_name == schema_name
        assert isinstance(advertised, ChannelInfo)
        client.subscribe("/conformance")
        _wait_until(lambda: channel.has_sinks(), timeout=2.0)
        deadline = time.monotonic() + 2.0
        while time.monotonic() < deadline and not received:
            channel.log(payload, log_time=42)
            time.sleep(0.05)
        assert received, "did not receive a message from the official SDK server"
        info, log_time, data = received[0]
        assert info.topic == "/conformance"
        assert log_time == 42
        assert data == payload
        assert codec.decode(schema_name, data).data == "hello"
    finally:
        client.close()
        server.stop()

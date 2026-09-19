from __future__ import annotations

import json
import threading
import time

import pytest
from websockets.sync.client import connect as ws_connect

from pocketsensor.cdr import CdrCodec
from pocketsensor.protocol import (
    SUBPROTOCOLS,
    Advertise,
    AdvertiseServices,
    MessageData,
    ParameterValue,
    ParameterValues,
    ServerInfo,
    ServiceCallResponse,
    build_get_parameters,
    build_service_call_request,
    build_set_parameters,
    build_subscribe,
    parse_server_binary,
    parse_server_text,
)
from pocketsensor.testing.fake_device import FakeDevice


def _recv_until(ws, predicate, timeout: float = 2.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        remaining = deadline - time.monotonic()
        raw = ws.recv(timeout=max(0.01, remaining))
        parsed = parse_server_binary(raw) if isinstance(raw, (bytes, bytearray)) else parse_server_text(raw)
        if predicate(parsed):
            return parsed
    raise AssertionError("timed out waiting for protocol message")


def test_fake_device_handshake_and_latched_parameters_services() -> None:
    codec = CdrCodec.from_contract()
    with FakeDevice(port=0, seed=1) as fake:
        with ws_connect(fake.url, subprotocols=list(SUBPROTOCOLS), compression=None, max_size=None) as ws:
            assert ws.subprotocol == "foxglove.sdk.v1"
            info = parse_server_text(ws.recv(timeout=1.0))
            assert isinstance(info, ServerInfo)
            assert info.name == "pocketsensor"
            assert "parameters" in info.capabilities
            adv = parse_server_text(ws.recv(timeout=1.0))
            assert isinstance(adv, Advertise)
            device_info_ch = next(ch for ch in adv.channels if ch.topic.endswith("/device_info"))
            tf_ch = next(ch for ch in adv.channels if ch.topic == "/tf_static")
            svcs = parse_server_text(ws.recv(timeout=1.0))
            assert isinstance(svcs, AdvertiseServices)
            clock_svc = next(s for s in svcs.services if s.name.endswith("/clock_sync"))
            reset_svc = next(s for s in svcs.services if s.name.endswith("/reset_origin"))

            ws.send(build_subscribe([(1, device_info_ch.id), (2, tf_ch.id)]))
            latched = _recv_until(ws, lambda m: isinstance(m, MessageData) and m.subscription_id == 1)
            msg = codec.decode("std_msgs/msg/String", bytes(latched.payload))
            payload = json.loads(msg.data)
            assert payload["name"] == "pocketsensor"
            assert payload["session_id"] == info.session_id

            tf_msg = _recv_until(ws, lambda m: isinstance(m, MessageData) and m.subscription_id == 2)
            tf = codec.decode("tf2_msgs/msg/TFMessage", bytes(tf_msg.payload))
            assert len(tf.transforms) == 2

            ws.send(build_set_parameters([ParameterValue("pose.rate", 100.0, "float64")], request_id="clamp"))
            clamped = _recv_until(ws, lambda m: isinstance(m, ParameterValues) and m.id == "clamp")
            by_name = {p.name: p.value for p in clamped.parameters}
            assert by_name["pose.rate"] == pytest.approx(60.0)

            ws.send(build_set_parameters([ParameterValue("device.name", "hack")], request_id="ro"))
            readonly = _recv_until(ws, lambda m: isinstance(m, ParameterValues) and m.id == "ro")
            assert readonly.parameters[0].value == "pocketsensor"

            ws.send(build_get_parameters(["device.name"], request_id="get"))
            got = _recv_until(ws, lambda m: isinstance(m, ParameterValues) and m.id == "get")
            assert got.parameters[0].value == "pocketsensor"

            req = codec.encode(
                "pocketsensor_msgs/srv/ClockSync_Request",
                codec.make("pocketsensor_msgs/srv/ClockSync_Request", t1=123),
            )
            ws.send(build_service_call_request(clock_svc.id, 7, "cdr", req))
            reply = _recv_until(ws, lambda m: isinstance(m, ServiceCallResponse) and m.call_id == 7)
            resp = codec.decode("pocketsensor_msgs/srv/ClockSync_Response", bytes(reply.payload))
            assert resp.t1 == 123
            assert resp.t3 >= resp.t2

            trig = codec.encode("std_srvs/srv/Trigger_Request", codec.make("std_srvs/srv/Trigger_Request"))
            ws.send(build_service_call_request(reset_svc.id, 8, "cdr", trig))
            trig_reply = _recv_until(ws, lambda m: isinstance(m, ServiceCallResponse) and m.call_id == 8)
            trig_resp = codec.decode("std_srvs/srv/Trigger_Response", bytes(trig_reply.payload))
            assert trig_resp.success is True


def test_wire_time_applies_anchor() -> None:
    fake = FakeDevice(port=0, seed=0)
    fake.clock_offset_ns = 2_000_000
    with fake:
        wall = time.time_ns()
        t_wire = fake.device_now_ns()
        assert abs(t_wire - (wall + fake.clock_offset_ns)) < 50_000_000
        assert fake.expected_offset_ns == fake.anchor_ns + fake.clock_offset_ns
        assert abs(fake.device_now_ns() - (time.monotonic_ns() + fake.expected_offset_ns)) < 20_000_000


def test_fake_device_can_stop_right_after_start_without_thread_errors(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    errors: list[str] = []
    monkeypatch.setattr(
        threading, "excepthook", lambda args: errors.append(f"{args.thread.name}: {args.exc_value!r}")
    )
    # 待ち受けスレッドの起動と終了が競合するのは 1 回あたり 1 割ほど。60 回で取りこぼす確率は 0.2 % になる。
    for _ in range(60):
        with FakeDevice(port=0, seed=0):
            pass
    time.sleep(0.1)
    assert errors == []

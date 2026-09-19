"""Foxglove WebSocket v1 のクライアント。受信は裏スレッド。"""

from __future__ import annotations

import logging
import queue
import threading
import time
import uuid
from collections.abc import Callable, Sequence
from typing import Any

from pocketsensor.errors import ConnectionLost, ProtocolError, Unsupported
from pocketsensor.protocol import (
    Advertise,
    AdvertiseServices,
    ChannelInfo,
    MessageData,
    ParameterValue,
    ParameterValues,
    ServerInfo,
    ServiceCallFailure,
    ServiceCallResponse,
    ServiceInfo,
    Unadvertise,
    UnadvertiseServices,
    UnknownOp,
    build_get_parameters,
    build_service_call_request,
    build_set_parameters,
    build_subscribe,
    build_subscribe_parameter_updates,
    build_unsubscribe,
    parse_server_binary,
    parse_server_text,
)
from pocketsensor.transport import Transport

log = logging.getLogger("pocketsensor.client")

OnMessage = Callable[[ChannelInfo, int, bytes, int, int], None]


class FoxgloveClient:
    """1 本の接続を表す。公開メソッドはスレッドセーフ。"""

    def __init__(self, transport: Transport) -> None:
        self._transport = transport
        self._lock = threading.RLock()
        self._ready = threading.Event()
        self._dead = False
        self._disconnect_exc: BaseException | None = None
        self._server_info: ServerInfo | None = None
        self._got_advertise = False
        self._channels: dict[str, ChannelInfo] = {}
        self._channels_by_id: dict[int, ChannelInfo] = {}
        self._services: dict[str, ServiceInfo] = {}
        self._sub_id = 1
        self._call_id = 1
        self._req_id = 1
        self._subs: dict[int, ChannelInfo] = {}
        self._topic_sub: dict[str, int] = {}
        self._param_wait: dict[str, tuple[threading.Event, list[Any]]] = {}
        self._svc_wait: dict[int, tuple[threading.Event, list[Any]]] = {}
        self._param_callbacks: list[tuple[frozenset[str], Callable[[dict[str, Any]], None]]] = []
        self.last_call_arrival: tuple[int, int] | None = None
        self.on_message: OnMessage | None = None
        self.on_disconnect: Callable[[], None] | None = None
        self._events: queue.Queue[tuple] = queue.Queue()
        self._stop = threading.Event()
        self._recv_thread = threading.Thread(target=self._recv_loop, name="ps-recv", daemon=True)
        self._disp_thread = threading.Thread(target=self._dispatch_loop, name="ps-dispatch", daemon=True)
        self._recv_thread.start()
        self._disp_thread.start()

    @property
    def channels(self) -> dict[str, ChannelInfo]:
        with self._lock:
            return dict(self._channels)

    @property
    def services(self) -> dict[str, ServiceInfo]:
        with self._lock:
            return dict(self._services)

    @property
    def server_info(self) -> ServerInfo | None:
        with self._lock:
            return self._server_info

    def wait_ready(self, timeout: float | None = None) -> ServerInfo:
        if not self._ready.wait(timeout):
            self._raise_if_dead()
            raise TimeoutError("timed out waiting for serverInfo and advertise")
        self._raise_if_dead()
        info = self._server_info
        if info is None:
            raise ProtocolError("ready without serverInfo")
        return info

    def subscribe(self, topic: str) -> int:
        self._raise_if_dead()
        with self._lock:
            existing = self._topic_sub.get(topic)
            if existing is not None:
                return existing
            channel = self._channels.get(topic)
            if channel is None:
                raise Unsupported(f"channel not advertised: {topic}")
            sub_id = self._sub_id
            self._sub_id += 1
            self._subs[sub_id] = channel
            self._topic_sub[topic] = sub_id
        self._send_text(build_subscribe([(sub_id, channel.id)]))
        return sub_id

    def unsubscribe(self, topic: str) -> None:
        self._raise_if_dead()
        with self._lock:
            sub_id = self._topic_sub.pop(topic, None)
            if sub_id is None:
                return
            self._subs.pop(sub_id, None)
        self._send_text(build_unsubscribe([sub_id]))

    def get_parameters(self, names: Sequence[str], timeout: float | None = 5.0) -> dict[str, Any]:
        values = self._roundtrip_parameters(build_get_parameters(list(names), request_id="{id}"), timeout)
        return {item.name: item.value for item in values}

    def set_parameters(self, values: dict[str, Any], timeout: float | None = 5.0) -> dict[str, Any]:
        params = []
        for name, value in values.items():
            ptype = "float64" if isinstance(value, (int, float)) and not isinstance(value, bool) else None
            params.append(ParameterValue(name=name, value=value, type=ptype))
        result = self._roundtrip_parameters(build_set_parameters(params, request_id="{id}"), timeout)
        return {item.name: item.value for item in result}

    def subscribe_parameter_updates(
        self,
        names: Sequence[str],
        callback: Callable[[dict[str, Any]], None],
    ) -> None:
        self._raise_if_dead()
        frozen = frozenset(names)
        with self._lock:
            self._param_callbacks.append((frozen, callback))
        self._send_text(build_subscribe_parameter_updates(list(names)))

    def call_service(self, name: str, request_payload: bytes, timeout: float | None = 5.0) -> bytes:
        self._raise_if_dead()
        with self._lock:
            service = self._services.get(name)
            if service is None:
                raise Unsupported(f"service not advertised: {name}")
            call_id = self._call_id
            self._call_id += 1
            event = threading.Event()
            box: list[Any] = []
            self._svc_wait[call_id] = (event, box)
        self._send_binary(build_service_call_request(service.id, call_id, "cdr", request_payload))
        if not event.wait(timeout):
            with self._lock:
                self._svc_wait.pop(call_id, None)
            self._raise_if_dead()
            raise TimeoutError(f"service call timed out: {name}")
        self._raise_if_dead()
        result, arr_mono, arr_wall = box[0]
        self.last_call_arrival = (int(arr_mono), int(arr_wall))
        if isinstance(result, ServiceCallFailure):
            raise ProtocolError(result.message)
        assert isinstance(result, ServiceCallResponse)
        return bytes(result.payload)

    def close(self) -> None:
        self._stop.set()
        try:
            self._transport.close()
        except Exception:
            log.debug("transport close failed", exc_info=True)
        self._fail_all(ConnectionLost("client closed"))

    def _roundtrip_parameters(self, template: str, timeout: float | None) -> tuple[ParameterValue, ...]:
        self._raise_if_dead()
        with self._lock:
            req_id = f"p{self._req_id}-{uuid.uuid4().hex[:8]}"
            self._req_id += 1
            event = threading.Event()
            box: list[Any] = []
            self._param_wait[req_id] = (event, box)
        self._send_text(template.replace("{id}", req_id, 1) if "{id}" in template else template)
        if not event.wait(timeout):
            with self._lock:
                self._param_wait.pop(req_id, None)
            self._raise_if_dead()
            raise TimeoutError("parameter request timed out")
        self._raise_if_dead()
        return tuple(box[0])

    def _send_text(self, text: str) -> None:
        try:
            self._transport.send_text(text)
        except Exception as exc:
            self._fail_all(ConnectionLost(str(exc)))
            raise ConnectionLost(str(exc)) from exc

    def _send_binary(self, data: bytes) -> None:
        try:
            self._transport.send_binary(data)
        except Exception as exc:
            self._fail_all(ConnectionLost(str(exc)))
            raise ConnectionLost(str(exc)) from exc

    def _raise_if_dead(self) -> None:
        if self._dead:
            raise ConnectionLost(str(self._disconnect_exc or "connection lost"))

    def _fail_all(self, exc: BaseException) -> None:
        callbacks: list[Callable[[], None]] = []
        with self._lock:
            if self._dead:
                return
            self._dead = True
            self._disconnect_exc = exc
            for event, _box in self._param_wait.values():
                event.set()
            for event, _box in self._svc_wait.values():
                event.set()
            self._ready.set()
            if self.on_disconnect is not None:
                callbacks.append(self.on_disconnect)
        for cb in callbacks:
            try:
                cb()
            except Exception:
                log.exception("on_disconnect raised")

    def _recv_loop(self) -> None:
        while not self._stop.is_set():
            try:
                raw = self._transport.recv(timeout=0.2)
            except TimeoutError:
                continue
            except Exception as exc:
                self._fail_all(ConnectionLost(str(exc)))
                return
            arrival_mono = time.monotonic_ns()
            arrival_wall = time.time_ns()
            try:
                if isinstance(raw, (bytes, bytearray, memoryview)):
                    parsed = parse_server_binary(raw)
                else:
                    parsed = parse_server_text(raw)
            except ProtocolError:
                log.warning("dropping malformed frame", exc_info=True)
                continue
            if isinstance(parsed, MessageData):
                self._events.put(("msg", parsed, arrival_mono, arrival_wall))
            else:
                try:
                    self._handle(parsed, arrival_mono, arrival_wall)
                except Exception:
                    log.exception("control-plane dispatch failed")

    def _dispatch_loop(self) -> None:
        while not self._stop.is_set():
            try:
                event = self._events.get(timeout=0.2)
            except queue.Empty:
                continue
            kind = event[0]
            if kind == "disconnect":
                self._fail_all(ConnectionLost(str(event[1])))
                return
            _, parsed, arrival_mono, arrival_wall = event
            try:
                self._handle(parsed, arrival_mono, arrival_wall)
            except Exception:
                log.exception("dispatch failed")

    def _handle(self, parsed: object, arrival_mono: int, arrival_wall: int) -> None:
        if isinstance(parsed, ServerInfo):
            with self._lock:
                if self._server_info is not None and parsed.session_id != self._server_info.session_id:
                    self._fail_all(ConnectionLost("session id changed"))
                    return
                self._server_info = parsed
                self._maybe_ready()
            return
        if isinstance(parsed, Advertise):
            with self._lock:
                for channel in parsed.channels:
                    self._channels[channel.topic] = channel
                    self._channels_by_id[channel.id] = channel
                self._got_advertise = True
                self._maybe_ready()
            return
        if isinstance(parsed, Unadvertise):
            with self._lock:
                for cid in parsed.channel_ids:
                    ch = self._channels_by_id.pop(cid, None)
                    if ch is not None:
                        self._channels.pop(ch.topic, None)
            return
        if isinstance(parsed, AdvertiseServices):
            with self._lock:
                for service in parsed.services:
                    self._services[service.name] = service
            return
        if isinstance(parsed, UnadvertiseServices):
            with self._lock:
                drop = {svc.name for svc in self._services.values() if svc.id in parsed.service_ids}
                for name in drop:
                    self._services.pop(name, None)
            return
        if isinstance(parsed, ParameterValues):
            self._handle_parameters(parsed)
            return
        if isinstance(parsed, ServiceCallResponse) or isinstance(parsed, ServiceCallFailure):
            with self._lock:
                waiter = self._svc_wait.pop(parsed.call_id, None)
            if waiter is not None:
                event, box = waiter
                box.append((parsed, arrival_mono, arrival_wall))
                event.set()
            return
        if isinstance(parsed, MessageData):
            with self._lock:
                channel = self._subs.get(parsed.subscription_id)
                cb = self.on_message
            if channel is None or cb is None:
                return
            cb(channel, int(parsed.log_time_ns), bytes(parsed.payload), arrival_mono, arrival_wall)
            return
        if isinstance(parsed, UnknownOp):
            log.debug("ignoring unknown op %s", parsed.op)

    def _handle_parameters(self, parsed: ParameterValues) -> None:
        callbacks: list[tuple[Callable[[dict[str, Any]], None], dict[str, Any]]] = []
        with self._lock:
            if parsed.id is not None and parsed.id in self._param_wait:
                event, box = self._param_wait.pop(parsed.id)
                box.append(parsed.parameters)
                event.set()
                return
            values = {item.name: item.value for item in parsed.parameters}
            for names, cb in self._param_callbacks:
                if not names or not names.isdisjoint(values):
                    filtered = values if not names else {k: v for k, v in values.items() if k in names}
                    if filtered:
                        callbacks.append((cb, filtered))
        for cb, filtered in callbacks:
            try:
                cb(filtered)
            except Exception:
                log.exception("parameter callback raised")

    def _maybe_ready(self) -> None:
        if self._server_info is not None and self._got_advertise:
            self._ready.set()

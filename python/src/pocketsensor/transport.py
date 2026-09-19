"""接続先の文字列から Transport を開く。"""

from __future__ import annotations

import socket
from collections.abc import Callable
from typing import Protocol

from websockets.exceptions import WebSocketException
from websockets.sync.client import ClientConnection
from websockets.sync.client import connect as ws_connect

import pocketsensor.usbmux as usbmux
from pocketsensor.errors import ConnectionFailed, Unsupported
from pocketsensor.protocol import SUBPROTOCOLS
from pocketsensor.usbmux import UsbmuxError, find_device, parse_usb_source

Factory = Callable[[str, float | None], "Transport"]


class Transport(Protocol):
    def send_text(self, text: str) -> None: ...

    def send_binary(self, data: bytes) -> None: ...

    def recv(self, timeout: float | None = None) -> str | bytes: ...

    def close(self) -> None: ...


class WebSocketTransport:
    """websockets.sync のクライアントを Transport に合わせる。"""

    def __init__(self, connection: ClientConnection) -> None:
        self._conn = connection
        sock = getattr(connection, "socket", None)
        if sock is not None:
            try:
                sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            except OSError:
                pass

    def send_text(self, text: str) -> None:
        self._conn.send(text)

    def send_binary(self, data: bytes) -> None:
        self._conn.send(bytes(data))

    def recv(self, timeout: float | None = None) -> str | bytes:
        return self._conn.recv(timeout=timeout)

    def close(self) -> None:
        self._conn.close()

    @property
    def subprotocol(self) -> str | None:
        value = self._conn.subprotocol
        return str(value) if value is not None else None


_REGISTRY: list[tuple[Callable[[str], bool], Factory]] = []


def register_source(prefix_or_predicate: str | Callable[[str], bool], factory: Factory) -> None:
    """TASK 03b が usb: やファイル再生を足すための登録口。"""
    if isinstance(prefix_or_predicate, str):
        prefix = prefix_or_predicate

        def pred(source: str, p: str = prefix) -> bool:
            return source.startswith(p)

    else:
        pred = prefix_or_predicate
    _REGISTRY.append((pred, factory))


def connect(source: str, timeout: float | None = None) -> Transport:
    if source.startswith("ws://") or source.startswith("wss://"):
        try:
            conn = ws_connect(
                source,
                subprotocols=list(SUBPROTOCOLS),
                compression=None,
                max_size=None,
                max_queue=None,
                open_timeout=timeout,
                legacy=True,
            )
        except (OSError, TimeoutError, WebSocketException) as exc:
            raise ConnectionFailed(f"could not connect to {source}") from exc
        return WebSocketTransport(conn)
    for pred, factory in _REGISTRY:
        if pred(source):
            try:
                return factory(source, timeout)
            except (ConnectionFailed, Unsupported):
                raise
            except (OSError, TimeoutError) as exc:
                raise ConnectionFailed(f"could not connect to {source}") from exc
    raise Unsupported(f"unsupported source: {source}")


_USB_HINT = (
    "could not connect over USB; check the cable, tap Trust this computer, "
    "and keep the pocketsensor app in the foreground"
)


def _connect_usb(source: str, timeout: float | None) -> Transport:
    try:
        udid, port = parse_usb_source(source)
    except ValueError as exc:
        raise Unsupported(str(exc)) from exc
    wait = 5.0 if timeout is None else timeout
    try:
        device = find_device(udid, socket_path=usbmux.DEFAULT_SOCKET_PATH, timeout=wait)
        sock = usbmux.connect(device.device_id, port, socket_path=usbmux.DEFAULT_SOCKET_PATH, timeout=wait)
    except UsbmuxError as exc:
        raise ConnectionFailed(_USB_HINT) from exc
    try:
        conn = ws_connect(
            f"ws://localhost:{port}",
            sock=sock,
            subprotocols=list(SUBPROTOCOLS),
            compression=None,
            max_size=None,
            max_queue=None,
            open_timeout=timeout,
            legacy=True,
            ping_interval=None,
            ping_timeout=None,
            proxy=None,
        )
    except (OSError, TimeoutError, WebSocketException) as exc:
        try:
            sock.close()
        except OSError:
            pass
        raise ConnectionFailed(_USB_HINT) from exc
    return WebSocketTransport(conn)


register_source("usb:", _connect_usb)

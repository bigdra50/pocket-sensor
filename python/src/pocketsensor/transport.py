"""接続先の文字列から Transport を開く。"""

from __future__ import annotations

import socket
from collections.abc import Callable
from typing import Protocol

from websockets.exceptions import WebSocketException
from websockets.sync.client import ClientConnection
from websockets.sync.client import connect as ws_connect

from pocketsensor.errors import ConnectionFailed, Unsupported
from pocketsensor.protocol import SUBPROTOCOLS

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
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)

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

"""usbmuxd の最小クライアント。

pymobiledevice3 は GPL-3.0 なので、ListDevices と Connect だけを標準ライブラリで実装する。
Unix ドメインソケットへ XML plist を送り、Connect が成功したあと同じソケットが端末の TCP へ通る。
"""

from __future__ import annotations

import logging
import plistlib
import socket
import struct
from dataclasses import dataclass
from typing import Any

# アプリの WebSocket 待ち受け。docs/protocol.md の既定ポート
_DEFAULT_DEVICE_PORT = 8765
_HEADER_SIZE = 16
_VERSION = 1
_MESSAGE_PLIST = 8
# これより長い plist はプロトコル破壊とみなす。通常の DeviceList は数十 KB に収まる
_MAX_PACKET_LENGTH = 1 << 20
_HEADER = struct.Struct("<IIII")
_LOG = logging.getLogger("pocketsensor.usbmux")

DEFAULT_SOCKET_PATH = "/var/run/usbmuxd"

__all__ = [
    "DEFAULT_SOCKET_PATH",
    "UsbDevice",
    "UsbmuxConnectRefused",
    "UsbmuxError",
    "UsbmuxUnavailable",
    "connect",
    "decode_header",
    "encode_packet",
    "find_device",
    "list_devices",
    "parse_usb_source",
    "swap_port",
]


class UsbmuxError(Exception):
    """usbmux プロトコルまたは探索の失敗。

    ``code`` はデーモンが返した Result 番号。接続そのものが張れないときは None。
    """

    def __init__(self, message: str, code: int | None = None) -> None:
        super().__init__(message)
        self.code = code


class UsbmuxUnavailable(UsbmuxError):
    """usbmuxd のソケットが無い、または接続できない。"""


class UsbmuxConnectRefused(UsbmuxError):
    """Connect の Result が 0 以外。``code`` にその番号を残す。"""


@dataclass(frozen=True)
class UsbDevice:
    """usbmuxd が見つけた 1 台。"""

    device_id: int
    udid: str
    connection_type: str
    product_id: int | None


def encode_packet(payload: dict, tag: int) -> bytes:
    """plist 辞書をヘッダ付きの 1 パケットにする。"""
    body = plistlib.dumps(payload, fmt=plistlib.FMT_XML)
    length = _HEADER_SIZE + len(body)
    return _HEADER.pack(length, _VERSION, _MESSAGE_PLIST, tag) + body


def decode_header(data: bytes) -> tuple[int, int, int, int]:
    """先頭 16 バイトを (length, version, message_type, tag) にする。"""
    if len(data) < _HEADER_SIZE:
        raise UsbmuxError("usbmux header is truncated")
    length, version, message_type, tag = _HEADER.unpack_from(data, 0)
    return length, version, message_type, tag


def swap_port(port: int) -> int:
    """TCP ポートを usbmux の PortNumber にする。

    ネットワークバイト順の 16 bit を little-endian の欄へ載せるため、下位 2 バイトを入れ替える。
    """
    return ((port & 0xFF) << 8) | (port >> 8)


def _normalize_udid(udid: str) -> str:
    """usbmuxd のハイフン付きと、他ツールの連結表記を同じ鍵にする。"""
    return udid.replace("-", "").lower()


def parse_usb_source(source: str) -> tuple[str | None, int]:
    """``usb:`` 形式を (UDID または None, TCP ポート) に分解する。

    UDID を省くと最初の USB 端末を指す。ポートを省くと 8765。
    """
    if not source.startswith("usb:"):
        raise ValueError(f"not a usb source: {source!r}")
    rest = source[4:]
    if rest == "":
        return None, _DEFAULT_DEVICE_PORT
    if rest.startswith(":"):
        return None, _parse_port(rest[1:], source)
    colon = rest.find(":")
    if colon == -1:
        return rest, _DEFAULT_DEVICE_PORT
    udid = rest[:colon]
    port_text = rest[colon + 1 :]
    if udid == "" or port_text == "":
        raise ValueError(f"invalid usb source: {source!r}")
    if ":" in port_text:
        raise ValueError(f"invalid usb source: {source!r}")
    return udid, _parse_port(port_text, source)


def _parse_port(text: str, source: str) -> int:
    if text == "":
        raise ValueError(f"invalid usb source: {source!r}")
    try:
        port = int(text, 10)
    except ValueError as exc:
        raise ValueError(f"invalid usb port in {source!r}") from exc
    if port < 0 or port > 65535:
        raise ValueError(f"usb port out of range in {source!r}")
    return port


def _base_request(message_type: str, extra: dict[str, Any] | None = None) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "MessageType": message_type,
        "ClientVersionString": "pocketsensor",
        "ProgName": "pocketsensor",
        "kLibUSBMuxVersion": 3,
    }
    if extra:
        payload.update(extra)
    return payload


def _recv_exactly(sock: socket.socket, nbytes: int) -> bytes:
    chunks: list[bytes] = []
    remaining = nbytes
    while remaining > 0:
        chunk = sock.recv(remaining)
        if not chunk:
            raise UsbmuxError("usbmuxd closed the connection before the packet finished")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def _read_packet(sock: socket.socket) -> tuple[int, dict[str, Any]]:
    header = _recv_exactly(sock, _HEADER_SIZE)
    length, version, message_type, tag = decode_header(header)
    if length > _MAX_PACKET_LENGTH:
        raise UsbmuxError(f"packet length {length} exceeds 1 MiB")
    if length < _HEADER_SIZE:
        raise UsbmuxError(f"packet length {length} is shorter than the header")
    if version != _VERSION:
        raise UsbmuxError(f"unsupported usbmux version {version}")
    if message_type != _MESSAGE_PLIST:
        raise UsbmuxError(f"unsupported usbmux message type {message_type}")
    body = b""
    extra = length - _HEADER_SIZE
    if extra:
        body = _recv_exactly(sock, extra)
    try:
        payload = plistlib.loads(body) if body else {}
    except Exception as exc:
        raise UsbmuxError("malformed plist payload") from exc
    if not isinstance(payload, dict):
        raise UsbmuxError("plist payload is not a dictionary")
    return tag, payload


def _open_usbmux(socket_path: str, timeout: float) -> socket.socket:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    try:
        sock.connect(socket_path)
    except OSError as exc:
        sock.close()
        raise UsbmuxUnavailable(f"cannot connect to usbmuxd at {socket_path}: {exc}") from exc
    return sock


def _devices_from_payload(payload: dict[str, Any], *, include_network: bool) -> list[UsbDevice]:
    raw_list = payload.get("DeviceList", [])
    if not isinstance(raw_list, list):
        raise UsbmuxError("DeviceList is not an array")
    devices: list[UsbDevice] = []
    for entry in raw_list:
        device = _device_from_entry(entry)
        if device is None:
            continue
        if device.connection_type == "USB" or (include_network and device.connection_type == "Network"):
            devices.append(device)
    return devices


def _device_from_entry(entry: Any) -> UsbDevice | None:
    if not isinstance(entry, dict):
        return None
    properties = entry.get("Properties", {})
    if not isinstance(properties, dict):
        properties = {}
    connection_type = properties.get("ConnectionType")
    if not isinstance(connection_type, str):
        return None
    device_id = entry.get("DeviceID", properties.get("DeviceID"))
    if not isinstance(device_id, int):
        return None
    serial = properties.get("SerialNumber", "")
    udid = serial if isinstance(serial, str) else str(serial)
    product = properties.get("ProductID")
    product_id = product if isinstance(product, int) else None
    return UsbDevice(
        device_id=device_id,
        udid=udid,
        connection_type=connection_type,
        product_id=product_id,
    )


def list_devices(
    socket_path: str = DEFAULT_SOCKET_PATH,
    timeout: float = 2.0,
    include_network: bool = False,
) -> list[UsbDevice]:
    """接続中の端末を列挙する。既定では USB だけを返す。"""
    sock = _open_usbmux(socket_path, timeout)
    try:
        sock.sendall(encode_packet(_base_request("ListDevices"), tag=1))
        _tag, payload = _read_packet(sock)
        devices = _devices_from_payload(payload, include_network=include_network)
    except UsbmuxError:
        raise
    except OSError as exc:
        raise UsbmuxError(f"usbmux ListDevices failed: {exc}") from exc
    finally:
        sock.close()
    _LOG.info("listed %d usbmux device(s)", len(devices))
    for device in devices:
        # UDID は個人の端末を特定するので INFO 以上には出さない
        _LOG.debug(
            "usbmux device id=%s type=%s product_id=%s udid=%s",
            device.device_id,
            device.connection_type,
            device.product_id,
            device.udid,
        )
    return devices


def connect(
    device_id: int,
    port: int,
    socket_path: str = DEFAULT_SOCKET_PATH,
    timeout: float = 5.0,
) -> socket.socket:
    """端末の TCP ポートへトンネルするソケットを返す。失敗した接続は必ず閉じる。"""
    sock = _open_usbmux(socket_path, timeout)
    close_on_exit = True
    try:
        request = _base_request(
            "Connect",
            {"DeviceID": device_id, "PortNumber": swap_port(port)},
        )
        sock.sendall(encode_packet(request, tag=1))
        _tag, reply = _read_packet(sock)
        number = reply.get("Number")
        if not isinstance(number, int) or number != 0:
            code = number if isinstance(number, int) else None
            raise UsbmuxConnectRefused(f"usbmux Connect failed with result {number}", code=code)
        sock.settimeout(None)
        sock.setblocking(True)
        close_on_exit = False
        _LOG.info("usbmux tunnel opened for device id=%s port=%s", device_id, port)
        return sock
    except UsbmuxError:
        raise
    except OSError as exc:
        raise UsbmuxError(f"usbmux Connect failed: {exc}") from exc
    finally:
        if close_on_exit:
            sock.close()


def find_device(
    udid: str | None,
    socket_path: str = DEFAULT_SOCKET_PATH,
    timeout: float = 2.0,
) -> UsbDevice:
    """UDID が一致する USB 端末を返す。None なら先頭の 1 台。

    比較は大文字小文字とハイフンを無視する。
    """
    devices = list_devices(socket_path=socket_path, timeout=timeout, include_network=False)
    if udid is None:
        if not devices:
            raise UsbmuxError("no USB device is connected")
        return devices[0]
    wanted = _normalize_udid(udid)
    for device in devices:
        if _normalize_udid(device.udid) == wanted:
            return device
    raise UsbmuxError("no USB device matches the requested UDID")

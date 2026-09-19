"""usbmuxd の plist クライアント。

ヘッダとポート入れ替えはソケット無しで確かめ、ListDevices と Connect は仮のデーモンで通す。
成功した Connect のあと同じソケットが生のトンネルになることまで含める。
"""

from __future__ import annotations

import logging
import os
import plistlib
import select
import socket
import struct
import tempfile
import threading
import uuid
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path

import pytest

from pocketsensor import usbmux

_HEADER = struct.Struct("<IIII")
_USB_UDID = "00008140-001234567890ABCD"
_NET_UDID = "00008110-00DEADBEEF000001"


def _usb_entry(
    device_id: int = 3,
    udid: str = _USB_UDID,
    product_id: int | None = 0x12A8,
) -> dict:
    properties: dict = {
        "ConnectionType": "USB",
        "SerialNumber": udid,
        "DeviceID": device_id,
        "LocationID": 0x01100000,
    }
    if product_id is not None:
        properties["ProductID"] = product_id
    return {
        "DeviceID": device_id,
        "MessageType": "Attached",
        "Properties": properties,
    }


def _net_entry(device_id: int = 7, udid: str = _NET_UDID) -> dict:
    return {
        "DeviceID": device_id,
        "MessageType": "Attached",
        "Properties": {
            "ConnectionType": "Network",
            "SerialNumber": udid,
            "DeviceID": device_id,
            "ProductID": 0x12A8,
            "LocationID": 0,
        },
    }


def _pack(payload: dict, tag: int) -> bytes:
    body = plistlib.dumps(payload, fmt=plistlib.FMT_XML)
    return _HEADER.pack(16 + len(body), 1, 8, tag) + body


def _recv_exactly(sock: socket.socket, nbytes: int) -> bytes:
    chunks: list[bytes] = []
    remaining = nbytes
    while remaining > 0:
        chunk = sock.recv(remaining)
        if not chunk:
            raise RuntimeError("fake usbmuxd: client closed early")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


class _ScriptedSocket:
    """recv が短い断片だけ返すソケットもどき。読み取りの再試行を直接叩く。"""

    def __init__(self, data: bytes, chunk_size: int) -> None:
        self._data = data
        self._offset = 0
        self._chunk_size = chunk_size

    def recv(self, n: int) -> bytes:
        if self._offset >= len(self._data):
            return b""
        take = min(n, self._chunk_size, len(self._data) - self._offset)
        out = self._data[self._offset : self._offset + take]
        self._offset += take
        return out


class EchoServer:
    """Connect 成功後のトンネル先。受け取ったバイトをそのまま返す。"""

    def __init__(self) -> None:
        self._sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._sock.bind(("127.0.0.1", 0))
        self._sock.listen(8)
        host, port = self._sock.getsockname()[:2]
        self.addr = (host, port)
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, name="usbmux-echo", daemon=True)

    def start(self) -> None:
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        try:
            socket.create_connection(self.addr, timeout=0.2).close()
        except OSError:
            pass
        try:
            self._sock.close()
        except OSError:
            pass
        self._thread.join(timeout=2.0)

    def _run(self) -> None:
        self._sock.settimeout(0.2)
        while not self._stop.is_set():
            try:
                conn, _unused = self._sock.accept()
            except OSError:
                continue
            threading.Thread(target=self._echo, args=(conn,), daemon=True).start()

    def _echo(self, conn: socket.socket) -> None:
        conn.settimeout(0.2)
        with conn:
            while not self._stop.is_set():
                try:
                    data = conn.recv(4096)
                except OSError:
                    return
                if not data:
                    return
                try:
                    conn.sendall(data)
                except OSError:
                    return


def _short_unix_path(tmp_path: Path) -> str:
    """Unix ソケットのパスを sockaddr に収まる長さにする。

    macOS の sun_path は 104 バイト。pytest の tmp_path は超えることが多いので /tmp へ置く。
    """
    candidate = str(tmp_path / "s")
    if len(candidate.encode("utf-8")) < 100:
        return candidate
    return os.path.join(tempfile.gettempdir(), f"ps-mux-{os.getpid()}-{uuid.uuid4().hex[:10]}.sock")


class FakeUsbmuxd:
    """ListDevices と Connect だけを返す仮の usbmuxd。"""

    def __init__(
        self,
        path: str,
        *,
        devices: list[dict] | None = None,
        connect_number: int = 0,
        reply_mode: str = "ok",
        echo_addr: tuple[str, int] | None = None,
    ) -> None:
        self.path = path
        self.devices = list(devices) if devices is not None else []
        self.connect_number = connect_number
        self.reply_mode = reply_mode
        self.echo_addr = echo_addr
        self.last_request: dict | None = None
        self.error: BaseException | None = None
        self._halt = threading.Event()
        self._ready = threading.Event()
        self._server: socket.socket | None = None
        self._thread = threading.Thread(target=self._run, name="fake-usbmuxd", daemon=True)

    def start(self) -> None:
        self._thread.start()

    def wait_ready(self, timeout: float = 2.0) -> None:
        if not self._ready.wait(timeout):
            raise RuntimeError("fake usbmuxd did not start")
        if self.error is not None:
            raise self.error

    def stop(self) -> None:
        self._halt.set()
        if self._server is not None:
            try:
                self._server.close()
            except OSError:
                pass
        self._thread.join(timeout=2.0)
        try:
            os.unlink(self.path)
        except FileNotFoundError:
            pass

    def _run(self) -> None:
        try:
            srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            self._server = srv
            try:
                os.unlink(self.path)
            except FileNotFoundError:
                pass
            srv.bind(self.path)
            srv.listen(8)
            srv.settimeout(0.2)
            self._ready.set()
            while not self._halt.is_set():
                try:
                    conn, _unused = srv.accept()
                except OSError:
                    continue
                threading.Thread(target=self._handle, args=(conn,), daemon=True).start()
        except OSError as exc:
            self.error = exc
            self._ready.set()
        finally:
            if self._server is not None:
                try:
                    self._server.close()
                except OSError:
                    pass

    def _handle(self, conn: socket.socket) -> None:
        peer: socket.socket | None = None
        try:
            header = _recv_exactly(conn, 16)
            length, _version, _message_type, tag = _HEADER.unpack(header)
            body = _recv_exactly(conn, length - 16) if length > 16 else b""
            request = plistlib.loads(body)
            if not isinstance(request, dict):
                return
            self.last_request = request
            if not self._send_mode_reply(conn, tag):
                return
            message = request.get("MessageType")
            if message == "ListDevices":
                conn.sendall(_pack({"DeviceList": self.devices}, tag))
                return
            if message != "Connect":
                return
            number = self.connect_number
            if number == 0 and self.echo_addr is not None:
                peer = socket.create_connection(self.echo_addr, timeout=2.0)
            conn.sendall(_pack({"MessageType": "Result", "Number": number}, tag))
            if number == 0 and peer is not None:
                _bridge(conn, peer, self._halt)
        except (OSError, RuntimeError, plistlib.InvalidFileException):
            return
        finally:
            if peer is not None:
                try:
                    peer.close()
                except OSError:
                    pass
            try:
                conn.close()
            except OSError:
                pass

    def _send_mode_reply(self, conn: socket.socket, tag: int) -> bool:
        """通常の ListDevices / Connect 処理へ進むなら True。"""
        mode = self.reply_mode
        if mode == "ok":
            return True
        if mode == "split":
            packet = _pack({"DeviceList": self.devices}, tag)
            for index in range(0, len(packet), 5):
                conn.sendall(packet[index : index + 5])
            return False
        if mode == "truncate_header":
            conn.sendall(b"\x10\x00")
            return False
        if mode == "truncate_body":
            packet = _pack({"DeviceList": self.devices}, tag)
            conn.sendall(packet[:20])
            return False
        if mode == "oversized":
            # ヘッダだけ送って接続を残す。すぐ閉じると長さ上限の欠落が EOF と同じ UsbmuxError になる
            conn.sendall(_HEADER.pack((1 << 20) + 1, 1, 8, tag))
            self._hold_open(conn)
            return False
        if mode == "short_length":
            conn.sendall(_HEADER.pack(8, 1, 8, tag))
            return False
        if mode == "malformed":
            body = b"not-a-plist"
            conn.sendall(_HEADER.pack(16 + len(body), 1, 8, tag) + body)
            return False
        if mode == "bad_version":
            body = plistlib.dumps({"DeviceList": []}, fmt=plistlib.FMT_XML)
            conn.sendall(_HEADER.pack(16 + len(body), 0, 8, tag) + body)
            return False
        if mode == "bad_type":
            body = plistlib.dumps({"DeviceList": []}, fmt=plistlib.FMT_XML)
            conn.sendall(_HEADER.pack(16 + len(body), 1, 7, tag) + body)
            return False
        return True

    def _hold_open(self, conn: socket.socket) -> None:
        while not self._halt.is_set():
            try:
                select.select([conn], [], [], 0.2)
            except OSError:
                return


def _bridge(left: socket.socket, right: socket.socket, stop: threading.Event) -> None:
    sockets = [left, right]
    while not stop.is_set():
        readable, _w, _x = select.select(sockets, [], [], 0.2)
        for ready in readable:
            other = right if ready is left else left
            try:
                data = ready.recv(65536)
            except OSError:
                return
            if not data:
                return
            try:
                other.sendall(data)
            except OSError:
                return


@contextmanager
def fake_usbmuxd(tmp_path: Path, **kwargs: object) -> Iterator[FakeUsbmuxd]:
    path = _short_unix_path(tmp_path)
    server = FakeUsbmuxd(path, **kwargs)  # type: ignore[arg-type]
    server.start()
    try:
        server.wait_ready()
        yield server
    finally:
        server.stop()


@contextmanager
def _tracking_open(monkeypatch: pytest.MonkeyPatch) -> Iterator[list[socket.socket]]:
    opened: list[socket.socket] = []
    real_open = usbmux._open_usbmux

    def tracking_open(socket_path: str, timeout: float) -> socket.socket:
        sock = real_open(socket_path, timeout)
        opened.append(sock)
        return sock

    monkeypatch.setattr(usbmux, "_open_usbmux", tracking_open)
    yield opened


@contextmanager
def echo_server() -> Iterator[EchoServer]:
    server = EchoServer()
    server.start()
    try:
        yield server
    finally:
        server.stop()


def test_header_round_trip() -> None:
    payload = {"MessageType": "ListDevices", "ProgName": "pocketsensor"}
    packet = usbmux.encode_packet(payload, tag=7)
    length, version, message_type, tag = usbmux.decode_header(packet)
    assert version == 1
    assert message_type == 8
    assert tag == 7
    assert length == len(packet)
    body = plistlib.loads(packet[16:])
    assert body == payload


def test_decode_header_rejects_truncated_bytes() -> None:
    with pytest.raises(usbmux.UsbmuxError):
        usbmux.decode_header(b"\x00" * 15)


def test_swap_port_8765() -> None:
    assert usbmux.swap_port(8765) == 0x3D22


def test_parse_usb_source_cases() -> None:
    assert usbmux.parse_usb_source("usb:") == (None, 8765)
    assert usbmux.parse_usb_source("usb:00008140-0012") == ("00008140-0012", 8765)
    assert usbmux.parse_usb_source("usb:00008140-0012:9000") == ("00008140-0012", 9000)
    assert usbmux.parse_usb_source("usb::9000") == (None, 9000)
    assert usbmux.parse_usb_source("usb::65535") == (None, 65535)
    assert usbmux.parse_usb_source("usb::0") == (None, 0)


@pytest.mark.parametrize(
    "source",
    ["ws://localhost:8765", "usb", "usb:foo:notaport", "USB:", "usb:abc:", "file.mcap", ""],
)
def test_parse_usb_source_rejects_other_forms(source: str) -> None:
    with pytest.raises(ValueError):
        usbmux.parse_usb_source(source)


@pytest.mark.parametrize("source", ["usb::70000", "usb::-1", "usb:UDID:65536"])
def test_parse_usb_source_rejects_out_of_range_port(source: str) -> None:
    with pytest.raises(ValueError, match="out of range"):
        usbmux.parse_usb_source(source)


def test_udid_matching_ignores_case_and_dashes() -> None:
    dashed = "00008140-001234567890ABCD"
    compact = "00008140001234567890abcd"
    assert usbmux._normalize_udid(dashed) == usbmux._normalize_udid(compact)


def test_read_packet_assembles_partial_recv() -> None:
    payload = {"MessageType": "Result", "Number": 0}
    packet = usbmux.encode_packet(payload, tag=4)
    sock = _ScriptedSocket(packet, chunk_size=3)
    tag, body = usbmux._read_packet(sock)
    assert tag == 4
    assert body["Number"] == 0


def test_list_devices_empty(tmp_path: Path) -> None:
    with fake_usbmuxd(tmp_path, devices=[]) as server:
        assert usbmux.list_devices(socket_path=server.path) == []


def test_list_devices_filters_network_unless_requested(tmp_path: Path) -> None:
    devices = [_usb_entry(), _net_entry(), _usb_entry(device_id=9, udid="AAAA", product_id=None)]
    with fake_usbmuxd(tmp_path, devices=devices) as server:
        usb_only = usbmux.list_devices(socket_path=server.path)
        assert [d.device_id for d in usb_only] == [3, 9]
        assert usb_only[0].udid == _USB_UDID
        assert usb_only[0].connection_type == "USB"
        assert usb_only[0].product_id == 0x12A8
        assert usb_only[1].product_id is None
        both = usbmux.list_devices(socket_path=server.path, include_network=True)
        assert [d.device_id for d in both] == [3, 7, 9]
        assert both[1].connection_type == "Network"


def test_list_devices_does_not_log_udid_at_info(tmp_path: Path, caplog: pytest.LogCaptureFixture) -> None:
    caplog.set_level(logging.DEBUG, logger="pocketsensor.usbmux")
    with fake_usbmuxd(tmp_path, devices=[_usb_entry()]) as server:
        usbmux.list_devices(socket_path=server.path)
    compact = _USB_UDID.replace("-", "")
    info_text = " ".join(record.getMessage() for record in caplog.records if record.levelno >= logging.INFO)
    assert _USB_UDID not in info_text
    assert compact not in info_text
    for part in compact, _USB_UDID.split("-")[-1]:
        assert part not in info_text
    debug_text = " ".join(record.getMessage() for record in caplog.records if record.levelno == logging.DEBUG)
    assert _USB_UDID in debug_text


def test_list_devices_sends_required_fields(tmp_path: Path) -> None:
    with fake_usbmuxd(tmp_path, devices=[]) as server:
        usbmux.list_devices(socket_path=server.path)
    assert server.last_request is not None
    assert server.last_request["MessageType"] == "ListDevices"
    assert server.last_request["ClientVersionString"] == "pocketsensor"
    assert server.last_request["ProgName"] == "pocketsensor"
    assert server.last_request["kLibUSBMuxVersion"] == 3


def test_find_device_first_usb_and_udid_forms(tmp_path: Path) -> None:
    with fake_usbmuxd(tmp_path, devices=[_net_entry(), _usb_entry()]) as server:
        first = usbmux.find_device(None, socket_path=server.path)
        assert first.device_id == 3
        dashed = usbmux.find_device(_USB_UDID, socket_path=server.path)
        compact = usbmux.find_device("00008140001234567890abcd", socket_path=server.path)
        assert dashed == compact == first


def test_find_device_no_match(tmp_path: Path) -> None:
    with fake_usbmuxd(tmp_path, devices=[_usb_entry()]) as server, pytest.raises(usbmux.UsbmuxError):
        usbmux.find_device("does-not-exist", socket_path=server.path)
    with fake_usbmuxd(tmp_path, devices=[_net_entry()]) as server, pytest.raises(usbmux.UsbmuxError):
        usbmux.find_device(None, socket_path=server.path)


def test_connect_tunnels_bytes_both_ways(tmp_path: Path) -> None:
    with echo_server() as echo, fake_usbmuxd(tmp_path, devices=[_usb_entry()], echo_addr=echo.addr) as server:
        sock = usbmux.connect(3, 8765, socket_path=server.path)
        try:
            # トンネルはブロッキングで、接続時のタイムアウトは解除されている
            assert sock.gettimeout() is None
            assert sock.getblocking() is True
            sock.settimeout(2.0)
            sock.sendall(b"hello")
            assert sock.recv(5) == b"hello"
            sock.sendall(b"abc123")
            assert sock.recv(6) == b"abc123"
        finally:
            sock.close()
    assert server.last_request is not None
    assert server.last_request["MessageType"] == "Connect"
    assert server.last_request["DeviceID"] == 3
    assert server.last_request["PortNumber"] == 0x3D22


def test_connect_result_3_is_refused(tmp_path: Path) -> None:
    with (
        fake_usbmuxd(tmp_path, devices=[_usb_entry()], connect_number=3) as server,
        pytest.raises(usbmux.UsbmuxConnectRefused) as caught,
    ):
        usbmux.connect(3, 8765, socket_path=server.path)
    assert caught.value.code == 3


def test_connect_closes_socket_when_refused(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    with (
        _tracking_open(monkeypatch) as opened,
        fake_usbmuxd(tmp_path, devices=[_usb_entry()], connect_number=2) as server,
        pytest.raises(usbmux.UsbmuxConnectRefused) as caught,
    ):
        usbmux.connect(3, 1, socket_path=server.path)
    assert caught.value.code == 2
    assert opened
    assert opened[0].fileno() == -1


def test_connect_closes_socket_on_malformed_reply(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    with (
        _tracking_open(monkeypatch) as opened,
        fake_usbmuxd(tmp_path, reply_mode="malformed") as server,
        pytest.raises(usbmux.UsbmuxError, match="malformed plist"),
    ):
        usbmux.connect(3, 8765, socket_path=server.path)
    assert opened
    assert opened[0].fileno() == -1


def test_truncated_reply(tmp_path: Path) -> None:
    with fake_usbmuxd(tmp_path, reply_mode="truncate_header") as server, pytest.raises(usbmux.UsbmuxError):
        usbmux.list_devices(socket_path=server.path)
    with fake_usbmuxd(tmp_path, reply_mode="truncate_body") as server, pytest.raises(usbmux.UsbmuxError):
        usbmux.list_devices(socket_path=server.path)


def test_oversized_length(tmp_path: Path) -> None:
    with (
        fake_usbmuxd(tmp_path, reply_mode="oversized") as server,
        pytest.raises(usbmux.UsbmuxError, match=r"packet length \d+ exceeds 1 MiB"),
    ):
        usbmux.list_devices(socket_path=server.path, timeout=1.0)


def test_short_declared_length(tmp_path: Path) -> None:
    with (
        fake_usbmuxd(tmp_path, reply_mode="short_length") as server,
        pytest.raises(usbmux.UsbmuxError, match="shorter than the header"),
    ):
        usbmux.list_devices(socket_path=server.path)


def test_reply_split_across_send_calls(tmp_path: Path) -> None:
    with fake_usbmuxd(tmp_path, devices=[_usb_entry()], reply_mode="split") as server:
        devices = usbmux.list_devices(socket_path=server.path)
    assert len(devices) == 1
    assert devices[0].device_id == 3


def test_wrong_version_and_type(tmp_path: Path) -> None:
    with fake_usbmuxd(tmp_path, reply_mode="bad_version") as server, pytest.raises(usbmux.UsbmuxError):
        usbmux.list_devices(socket_path=server.path)
    with fake_usbmuxd(tmp_path, reply_mode="bad_type") as server, pytest.raises(usbmux.UsbmuxError):
        usbmux.list_devices(socket_path=server.path)


def test_missing_socket_path_is_unavailable(tmp_path: Path) -> None:
    missing = _short_unix_path(tmp_path) + ".missing"
    with pytest.raises(usbmux.UsbmuxUnavailable):
        usbmux.list_devices(socket_path=missing)
    with pytest.raises(usbmux.UsbmuxUnavailable):
        usbmux.connect(1, 8765, socket_path=missing)


@pytest.mark.skipif(
    os.environ.get("POCKETSENSOR_USBMUX_LIVE") != "1" or not Path("/var/run/usbmuxd").exists(),
    reason="live usbmuxd smoke test is opt-in via POCKETSENSOR_USBMUX_LIVE=1",
)
def test_live_usbmuxd_smoke() -> None:
    devices = usbmux.list_devices()
    assert isinstance(devices, list)
    usb = [item for item in devices if item.connection_type == "USB"]
    if not usb:
        pytest.skip("no USB device attached")
    with pytest.raises(usbmux.UsbmuxConnectRefused) as caught:
        usbmux.connect(usb[0].device_id, 1)
    assert caught.value.code == 3

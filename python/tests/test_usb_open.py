from __future__ import annotations

import pytest
from test_usbmux import _usb_entry, fake_usbmuxd

import pocketsensor as ps
from pocketsensor import usbmux
from pocketsensor.testing.fake_device import FakeDevice


def _pose_cfg() -> ps.Config:
    return ps.Config(streams=(ps.Pose(),), open_timeout=5.0)


def test_open_usb_reaches_fake_device_over_tunnel(tmp_path, monkeypatch: pytest.MonkeyPatch) -> None:
    with FakeDevice(port=0, seed=0) as fake:
        echo = ("127.0.0.1", fake._port)
        with fake_usbmuxd(tmp_path, devices=[_usb_entry()], echo_addr=echo) as mux:
            monkeypatch.setattr(usbmux, "DEFAULT_SOCKET_PATH", mux.path)
            with ps.open("usb:", _pose_cfg()) as dev:
                assert dev.info.model == "FakeDevice"
                frames = dev.wait_for_frames(timeout=2.0)
                assert frames.pose is not None


def test_open_usb_udid_and_port_form(tmp_path, monkeypatch: pytest.MonkeyPatch) -> None:
    with FakeDevice(port=0, seed=0) as fake:
        echo = ("127.0.0.1", fake._port)
        with fake_usbmuxd(tmp_path, devices=[_usb_entry()], echo_addr=echo) as mux:
            monkeypatch.setattr(usbmux, "DEFAULT_SOCKET_PATH", mux.path)
            source = "usb:00008140-001234567890ABCD:8765"
            with ps.open(source, _pose_cfg()) as dev:
                assert dev.info.name == "pocketsensor"


def test_usb_connect_refused_is_connection_failed(tmp_path, monkeypatch: pytest.MonkeyPatch) -> None:
    with fake_usbmuxd(tmp_path, devices=[_usb_entry()], connect_number=3) as mux:
        monkeypatch.setattr(usbmux, "DEFAULT_SOCKET_PATH", mux.path)
        with pytest.raises(ps.ConnectionFailed) as caught:
            ps.open("usb:", _pose_cfg())
        assert isinstance(caught.value.__cause__, usbmux.UsbmuxConnectRefused)
        text = str(caught.value).lower()
        assert "cable" in text or "trust" in text or "foreground" in text


def test_usb_no_device_is_connection_failed(tmp_path, monkeypatch: pytest.MonkeyPatch) -> None:
    with fake_usbmuxd(tmp_path, devices=[]) as mux:
        monkeypatch.setattr(usbmux, "DEFAULT_SOCKET_PATH", mux.path)
        with pytest.raises(ps.ConnectionFailed) as caught:
            ps.open("usb:", _pose_cfg())
        assert caught.value.__cause__ is not None
        text = str(caught.value).lower()
        assert "cable" in text or "trust" in text or "usb" in text

from __future__ import annotations

import logging

import pytest

import pocketsensor as ps
from pocketsensor.discovery import (
    DiscoveredDevice,
    bonjour_available,
    device_from_bonjour,
    device_from_usb,
    merge_devices,
)
from pocketsensor.usbmux import UsbDevice, UsbmuxUnavailable


def test_device_from_bonjour_formats_ws_source() -> None:
    hit = device_from_bonjour("pocketsensor", "192.168.1.8", 8765)
    assert hit.name == "pocketsensor"
    assert hit.source == "ws://192.168.1.8:8765"
    assert hit.transport == "wifi"
    assert hit.address == "192.168.1.8"
    assert hit.udid is None
    assert hit.port == 8765


def test_device_from_usb_formats_usb_source() -> None:
    usb = UsbDevice(device_id=3, udid="00008140-0012", connection_type="USB", product_id=0x12A8)
    hit = device_from_usb(usb)
    assert hit.name == "00008140-0012"
    assert hit.source == "usb:00008140-0012"
    assert hit.transport == "usb"
    assert hit.udid == "00008140-0012"
    assert hit.address is None
    assert hit.port == 8765


def test_merge_wifi_then_usb() -> None:
    wifi = [device_from_bonjour("phone", "10.0.0.2", 8765)]
    usb = [device_from_usb(UsbDevice(1, "UDID", "USB", None))]
    merged = merge_devices(wifi, usb)
    assert [item.transport for item in merged] == ["wifi", "usb"]


def test_discover_uses_stub_bonjour_browser() -> None:
    stub = [
        DiscoveredDevice(
            name="stub",
            source="ws://127.0.0.1:8765",
            transport="wifi",
            address="127.0.0.1",
            udid=None,
            port=8765,
        )
    ]

    def browser(timeout: float) -> list[DiscoveredDevice]:
        assert timeout == 0.05
        return list(stub)

    found = ps.discover(timeout=0.05, bonjour_browser=browser, usb_lister=list)
    assert found == stub


def test_discover_missing_usbmuxd_is_not_an_error(caplog: pytest.LogCaptureFixture) -> None:
    caplog.set_level(logging.INFO)

    def boom() -> list:
        raise UsbmuxUnavailable("missing socket")

    found = ps.discover(timeout=0.01, bonjour_browser=lambda _t: [], usb_lister=boom)
    assert found == []


@pytest.mark.parametrize(("spec", "expected"), [(None, False), (object(), True)])
def test_bonjour_available_follows_the_zeroconf_import(
    monkeypatch: pytest.MonkeyPatch, spec: object, expected: bool
) -> None:
    monkeypatch.setattr("pocketsensor.discovery.find_spec", lambda name: spec)
    assert bonjour_available() is expected

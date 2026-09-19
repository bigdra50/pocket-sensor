"""Bonjour と usbmux で端末を探す。"""

from __future__ import annotations

import logging
import threading
from collections.abc import Callable, Sequence
from dataclasses import dataclass

from pocketsensor.usbmux import UsbDevice, UsbmuxError, UsbmuxUnavailable, list_devices

_DEFAULT_PORT = 8765

log = logging.getLogger("pocketsensor.discovery")

BonjourBrowser = Callable[[float], Sequence["DiscoveredDevice"]]
UsbLister = Callable[[], Sequence[UsbDevice]]


@dataclass(frozen=True)
class DiscoveredDevice:
    name: str
    source: str
    transport: str
    address: str | None
    udid: str | None
    port: int


def device_from_bonjour(name: str, address: str, port: int) -> DiscoveredDevice:
    return DiscoveredDevice(
        name=name,
        source=f"ws://{address}:{port}",
        transport="wifi",
        address=address,
        udid=None,
        port=int(port),
    )


def device_from_usb(device: UsbDevice, port: int = _DEFAULT_PORT) -> DiscoveredDevice:
    return DiscoveredDevice(
        name=device.udid,
        source=f"usb:{device.udid}",
        transport="usb",
        address=None,
        udid=device.udid,
        port=int(port),
    )


def merge_devices(
    wifi: Sequence[DiscoveredDevice],
    usb: Sequence[DiscoveredDevice],
) -> list[DiscoveredDevice]:
    return [*wifi, *usb]


def discover(
    timeout: float = 2.0,
    *,
    bonjour_browser: BonjourBrowser | None = None,
    usb_lister: UsbLister | None = None,
) -> list[DiscoveredDevice]:
    wifi = _browse_bonjour(timeout, bonjour_browser)
    usb = _list_usb(usb_lister)
    return merge_devices(wifi, usb)


def _list_usb(lister: UsbLister | None) -> list[DiscoveredDevice]:
    try:
        from pocketsensor import usbmux

        devices = (
            list(lister()) if lister is not None else list_devices(socket_path=usbmux.DEFAULT_SOCKET_PATH)
        )
    except UsbmuxUnavailable:
        return []
    except UsbmuxError as exc:
        log.debug("usbmux list failed: %s", exc)
        return []
    return [device_from_usb(item) for item in devices]


def _browse_bonjour(timeout: float, browser: BonjourBrowser | None) -> list[DiscoveredDevice]:
    if browser is not None:
        return list(browser(timeout))
    try:
        from zeroconf import ServiceBrowser, ServiceListener, Zeroconf
    except ImportError:
        log.info("zeroconf is not installed; skipping Bonjour discovery")
        return []
    hits: list[DiscoveredDevice] = []
    lock = threading.Lock()

    class Listener(ServiceListener):
        def add_service(self, zc: Zeroconf, type_: str, name: str) -> None:
            info = zc.get_service_info(type_, name)
            if info is None or not info.port:
                return
            addresses = info.parsed_addresses()
            if not addresses:
                return
            display = name.split(".", 1)[0]
            hit = device_from_bonjour(display, addresses[0], int(info.port))
            with lock:
                hits.append(hit)

        def remove_service(self, zc: Zeroconf, type_: str, name: str) -> None:
            return None

        def update_service(self, zc: Zeroconf, type_: str, name: str) -> None:
            return None

    zc = Zeroconf()
    try:
        ServiceBrowser(zc, "_pocketsensor._tcp.local.", Listener())
        threading.Event().wait(timeout)
    finally:
        zc.close()
    with lock:
        return list(hits)

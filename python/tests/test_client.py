from __future__ import annotations

import time

from pocketsensor.client import FoxgloveClient
from pocketsensor.testing import FakeDevice
from pocketsensor.transport import connect


def test_client_reports_closed_after_the_server_goes_away() -> None:
    with FakeDevice(port=0, seed=0) as fake:
        client = FoxgloveClient(connect(fake.url, timeout=2.0))
        client.wait_ready(timeout=2.0)
        assert not client.closed
    try:
        deadline = time.monotonic() + 3.0
        while not client.closed and time.monotonic() < deadline:
            time.sleep(0.02)
        assert client.closed
    finally:
        client.close()


def test_client_reports_closed_after_close() -> None:
    with FakeDevice(port=0, seed=0) as fake:
        client = FoxgloveClient(connect(fake.url, timeout=2.0))
        client.wait_ready(timeout=2.0)
        client.close()
        assert client.closed

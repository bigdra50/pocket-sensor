from __future__ import annotations

import subprocess
import sys
import time
from pathlib import Path

import pytest

import pocketsensor as ps
from pocketsensor.cli import main
from pocketsensor.discovery import DiscoveredDevice
from pocketsensor.testing.fake_device import FakeDevice

REPO = Path(__file__).resolve().parents[2]


def _cfg() -> ps.Config:
    return ps.Config(
        streams=(
            ps.Color(rate=15, width=32, jpeg_quality=0.4),
            ps.Depth(rate=15),
            ps.Pose(rate=30),
            ps.Imu(rate=100),
        ),
        open_timeout=5.0,
    )


@pytest.fixture(scope="module")
def recorded_mcap(tmp_path_factory: pytest.TempPathFactory) -> Path:
    path = tmp_path_factory.mktemp("cli") / "run.mcap"
    with FakeDevice(port=0, seed=2) as fake:
        with ps.open(fake.url, _cfg()) as dev:
            with dev.record(path):
                deadline = time.monotonic() + 0.6
                while time.monotonic() < deadline:
                    try:
                        dev.wait_for_frames(timeout=0.2)
                    except TimeoutError:
                        pass
    return path


def test_cli_no_args_is_usage() -> None:
    assert main([]) == 2


def test_cli_unknown_command_is_usage() -> None:
    assert main(["nope"]) == 2


def test_discover_prints_stub_devices(capsys, monkeypatch: pytest.MonkeyPatch) -> None:
    devices = [
        DiscoveredDevice("wifi-phone", "ws://10.0.0.1:8765", "wifi", "10.0.0.1", None, 8765),
        DiscoveredDevice("UDID", "usb:UDID", "usb", None, "UDID", 8765),
    ]
    monkeypatch.setattr("pocketsensor.cli.discover", lambda timeout=2.0: devices)
    assert main(["discover", "--timeout", "0.1"]) == 0
    out = capsys.readouterr().out
    assert "ws://10.0.0.1:8765" in out
    assert "usb:UDID" in out


def test_info_against_recorded_file(recorded_mcap: Path, capsys) -> None:
    assert main(["info", str(recorded_mcap)]) == 0
    out = capsys.readouterr().out
    assert "FakeDevice" in out
    assert "clock_ready=True" in out
    fields = dict(line.split("=", 1) for line in out.splitlines() if "=" in line)
    # FakeDevice の時計はこのマシンの壁時計そのものなので、壁時計どうしのずれは 0 に近い。
    assert abs(float(fields["clock_wall_offset_ms"])) < 50.0
    assert 0.0 <= float(fields["clock_rtt_ms"]) < 1000.0
    assert "e+" not in out


def test_echo_against_recorded_file(recorded_mcap: Path, capsys) -> None:
    assert main(["echo", str(recorded_mcap), "/tf_static", "-n", "1"]) == 0
    out = capsys.readouterr().out.strip()
    assert "/tf_static" in out


def test_record_cli_against_fake_device(tmp_path: Path) -> None:
    out = tmp_path / "cli.mcap"
    with FakeDevice(port=0, seed=3) as fake:
        code = main(
            [
                "record",
                fake.url,
                "-o",
                str(out),
                "--duration",
                "0.4",
                "--streams",
                "color,depth,pose,imu",
            ]
        )
    assert code == 0
    assert out.is_file()
    assert out.stat().st_size > 64


def test_runtime_failure_is_exit_1(capsys) -> None:
    code = main(["info", "ws://127.0.0.1:9"])
    assert code == 1
    err = capsys.readouterr().err
    assert err


def test_gen_vectors_check() -> None:
    result = subprocess.run(
        [sys.executable, str(REPO / "tools" / "gen_vectors.py"), "--check"],
        cwd=REPO,
        check=False,
    )
    assert result.returncode == 0

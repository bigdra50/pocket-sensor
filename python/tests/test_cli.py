from __future__ import annotations

import json
import math
import subprocess
import sys
import time
from pathlib import Path

import pytest

import pocketsensor as ps
from pocketsensor.cli import main
from pocketsensor.discovery import DiscoveredDevice
from pocketsensor.streams import Stream
from pocketsensor.testing.fake_device import FakeDevice
from pocketsensor.units import STANDARD_GRAVITY

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
    # FakeDevice のクロックはこのマシンのシステム時刻そのものなので、オフセットは 0 に近い。
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


def test_check_axes_missing_source_is_usage() -> None:
    assert main(["check-axes"]) == 2


def test_check_axes_negative_step_seconds_is_usage() -> None:
    assert main(["check-axes", "ws://127.0.0.1:9", "--step-seconds", "-1"]) == 2


def test_check_axes_negative_min_move_is_usage() -> None:
    assert main(["check-axes", "ws://127.0.0.1:9", "--min-move", "-0.1"]) == 2


class _CheckAxesDirector:
    """countdown の sleep を境に FakeDevice の動きを切り替える。"""

    def __init__(self, fake: FakeDevice) -> None:
        self._ticks = 0
        g = STANDARD_GRAVITY
        self._plans = [
            lambda: fake.script_motion(position=(0.0, 0.0, 0.0), imu_accel=(g, 0.0, 0.0)),
            lambda: fake.script_motion(
                position=(0.0, 0.0, 0.0),
                position_end=(0.30, 0.0, 0.0),
                duration=0.20,
                imu_accel=(g, 0.0, 0.0),
            ),
            lambda: fake.script_motion(
                position=(0.30, 0.0, 0.0),
                position_end=(0.30, 0.30, 0.0),
                duration=0.20,
                imu_accel=(g, 0.0, 0.0),
            ),
            lambda: fake.script_motion(
                position=(0.30, 0.30, 0.0),
                position_end=(0.30, 0.30, 0.30),
                duration=0.20,
                imu_accel=(g, 0.0, 0.0),
            ),
            lambda: fake.script_motion(
                position=(0.30, 0.30, 0.30),
                yaw=0.0,
                yaw_end=math.radians(50.0),
                imu_yaw=0.0,
                imu_yaw_end=math.radians(50.0),
                duration=0.20,
                imu_accel=(g, 0.0, 0.0),
            ),
            lambda: fake.script_motion(
                position=(0.30, 0.30, 0.30),
                yaw=math.radians(50.0),
                imu_yaw=math.radians(50.0),
                imu_accel=(g, 0.0, 0.0),
                imu_accel_pulse=(0.0, 0.0, -5.0),
                pulse_at=0.12,
                pulse_duration=0.08,
            ),
        ]

    def __call__(self, seconds: float) -> None:
        if seconds >= 1.0:
            self._ticks += 1
            if self._ticks % 3 == 0:
                step = self._ticks // 3 - 1
                if 0 <= step < len(self._plans):
                    self._plans[step]()


def test_check_axes_writes_json_against_default_fake_device(tmp_path: Path, capsys) -> None:
    out = tmp_path / "axes.json"
    with FakeDevice(port=0, seed=0, streams={Stream.POSE, Stream.IMU}) as fake:
        code = main(
            ["check-axes", fake.url, "--json", str(out), "--step-seconds", "0.2"],
            sleep=lambda _s: None,
        )
    assert code == 1
    printed = capsys.readouterr().out
    assert "still" in printed
    payload = json.loads(out.read_text())
    assert payload["device"]
    assert payload["app_version"]
    assert payload["session_id"]
    assert payload["started_at"]
    assert [step["name"] for step in payload["steps"]] == [
        "still",
        "forward",
        "left",
        "up",
        "yaw",
        "push",
    ]
    for step in payload["steps"]:
        assert step["status"] in {"PASS", "FAIL", "SKIPPED"}
        assert "measured" in step
        assert "thresholds" in step


def test_check_axes_happy_path_against_scripted_fake_device(tmp_path: Path, capsys) -> None:
    out = tmp_path / "axes.json"
    g = STANDARD_GRAVITY
    with FakeDevice(port=0, seed=0, streams={Stream.POSE, Stream.IMU}) as fake:
        fake.script_motion(position=(0.0, 0.0, 0.0), imu_accel=(g, 0.0, 0.0))
        director = _CheckAxesDirector(fake)
        code = main(
            # 動きは 0.2 秒で終わる。測る窓を 1 秒にして、負荷で配送が遅れても窓の中に収まるようにする。
            ["check-axes", fake.url, "--json", str(out), "--step-seconds", "1.0", "--min-move", "0.15"],
            sleep=director,
        )
    assert code == 0
    printed = capsys.readouterr().out
    assert "PASS" in printed
    payload = json.loads(out.read_text())
    assert [step["status"] for step in payload["steps"]] == ["PASS"] * 6


def _wall_anchor() -> tuple[list[float], list[float]]:
    # 擬似デバイスは原点のまわりの半径 1 m の円の上にいる。x = 3 m の壁に、表を原点の側へ向けて貼った画像。
    # anchor の x（画像の上）は世界の上、z（法線）は -x。
    from pocketsensor.frames import matrix_to_quat

    # 列が anchor の x、y、z。y は z × x で、世界の +y（画像の左）になる。
    rotation = [[0.0, 0.0, -1.0], [0.0, 1.0, 0.0], [1.0, 0.0, 0.0]]
    return [3.0, 0.0, 0.0], [float(v) for v in matrix_to_quat(rotation)]


def test_check_anchor_passes_for_an_image_on_a_wall(tmp_path: Path) -> None:
    out = tmp_path / "anchor.json"
    lines: list[str] = []
    with FakeDevice(port=0, seed=0) as fake:
        fake.anchors = {"marker_a": _wall_anchor()}
        code = main(["check-anchor", fake.url, "--timeout", "5", "--json", str(out)], printer=lines.append)
    assert code == 0, lines
    assert any(line.startswith("PASS  anchor  marker_a") for line in lines)
    report = json.loads(out.read_text())
    assert report["anchors"][0]["image"] == "marker_a"
    assert report["anchors"][0]["status"] == "PASS"
    assert 1.9 <= report["anchors"][0]["measured"]["distance_m"] <= 4.1


def test_check_anchor_fails_when_the_normal_points_into_the_wall(tmp_path: Path) -> None:
    position, _ = _wall_anchor()
    lines: list[str] = []
    with FakeDevice(port=0, seed=0) as fake:
        # 単位四元数だと、法線（z）が世界の上を向く。壁に貼った画像としては誤り。
        fake.anchors = {"marker_a": (position, [0.0, 0.0, 0.0, 1.0])}
        code = main(["check-anchor", fake.url, "--timeout", "5"], printer=lines.append)
    assert code == 1
    assert any(line.startswith("FAIL  anchor  marker_a") for line in lines)


def test_check_anchor_times_out_without_an_image() -> None:
    lines: list[str] = []
    with FakeDevice(port=0, seed=0) as fake:
        code = main(["check-anchor", fake.url, "--timeout", "1"], printer=lines.append)
    assert code == 1
    assert any("no reference image" in line for line in lines)


def test_check_anchor_rejects_an_unknown_pose() -> None:
    assert main(["check-anchor", "ws://127.0.0.1:9", "--pose", "diagonal"]) == 2

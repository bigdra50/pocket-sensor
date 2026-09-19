from __future__ import annotations

import shutil
import signal
import subprocess
import threading
import time
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[3]
KIT = REPO / "ios" / "PocketSensorKit"
SIM_BIN = KIT / ".build" / "debug" / "pocketsensor-sim"


def _locate_or_build_sim() -> Path:
    swift = shutil.which("swift")
    if swift is None:
        if SIM_BIN.is_file():
            return SIM_BIN
        pytest.skip("swift is not available and pocketsensor-sim is not built")
    # 既にあるバイナリをそのまま使うと、Swift 側を変えたあとに古い実装を確かめてしまう。
    # 差分が無ければ swift build は 1 秒かからずに終わるので、毎回ビルドする。
    result = subprocess.run(
        [swift, "build", "--product", "pocketsensor-sim"],
        cwd=KIT,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0 or not SIM_BIN.is_file():
        # ビルドできないのは Swift 側の不具合なので、skip にして隠さない。
        pytest.fail(f"swift build --product pocketsensor-sim failed: {result.stderr[-800:]}")
    return SIM_BIN


def _read_ready(proc: subprocess.Popen[str], timeout: float) -> int:
    port_box: list[int] = []
    err: list[str] = []

    def _stdout() -> None:
        assert proc.stdout is not None
        for line in proc.stdout:
            if line.startswith("READY port="):
                port_box.append(int(line.strip().split("=", 1)[1]))
                return

    def _stderr() -> None:
        assert proc.stderr is not None
        err.append(proc.stderr.read())

    t_out = threading.Thread(target=_stdout, daemon=True)
    t_err = threading.Thread(target=_stderr, daemon=True)
    t_out.start()
    t_err.start()
    t_out.join(timeout)
    if not port_box:
        proc.send_signal(signal.SIGTERM)
        raise RuntimeError(f"sim did not print READY within {timeout}s: {''.join(err)[-500:]}")
    return port_box[0]


def _stop_sim(proc: subprocess.Popen[str]) -> None:
    if proc.poll() is None:
        proc.send_signal(signal.SIGTERM)
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=2)
    if proc.stdout is not None:
        proc.stdout.close()
    if proc.stderr is not None:
        proc.stderr.close()


@contextmanager
def run_sim(
    *,
    name: str = "pocketsensor",
    duration: float = 600.0,
    extra_args: list[str] | None = None,
) -> Iterator[str]:
    binary = _locate_or_build_sim()
    cmd = [
        str(binary),
        "--port",
        "0",
        "--no-bonjour",
        "--duration",
        str(int(duration)),
        "--quiet",
        "--name",
        name,
    ]
    if extra_args:
        cmd.extend(extra_args)
    proc = subprocess.Popen(
        cmd,
        cwd=str(KIT),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )
    try:
        port = _read_ready(proc, timeout=10.0)
        # READY を出した直後に latched を載せるので、接続の前に一瞬待つ
        time.sleep(0.05)
        yield f"ws://127.0.0.1:{port}"
    finally:
        _stop_sim(proc)


@pytest.fixture(scope="session")
def sim_device() -> Iterator[str]:
    # duration は取り残されたプロセスを片付けるための上限。テストの終わりには fixture が止める。
    with run_sim(name="pocketsensor") as url:
        yield url


@pytest.fixture
def named_sim_device() -> Iterator[str]:
    with run_sim(name="robot1") as url:
        yield url


@pytest.fixture
def anchor_sim_device() -> Iterator[str]:
    with run_sim(name="pocketsensor", extra_args=["--anchor", "dock", "--anchor", "door"]) as url:
        yield url

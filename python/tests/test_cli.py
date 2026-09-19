from __future__ import annotations

import subprocess
import sys
from pathlib import Path

from pocketsensor.cli import main

REPO = Path(__file__).resolve().parents[2]


def test_cli_stub_prints_usage(capsys) -> None:
    assert main() == 2
    captured = capsys.readouterr()
    assert "Usage:" in captured.out


def test_gen_vectors_check() -> None:
    result = subprocess.run(
        [sys.executable, str(REPO / "tools" / "gen_vectors.py"), "--check"],
        cwd=REPO,
        check=False,
    )
    assert result.returncode == 0

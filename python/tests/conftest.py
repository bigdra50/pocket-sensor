from __future__ import annotations

from pathlib import Path

import pytest

from pocketsensor.cdr import CdrCodec

REPO = Path(__file__).resolve().parents[2]


@pytest.fixture(scope="session")
def codec() -> CdrCodec:
    return CdrCodec.from_contract()


@pytest.fixture(scope="session")
def repo_root() -> Path:
    return REPO

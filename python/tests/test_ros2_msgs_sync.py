from __future__ import annotations

from pathlib import Path


def _iface_files(root: Path) -> dict[str, str]:
    files: dict[str, str] = {}
    for path in sorted(root.rglob("*")):
        if path.suffix in {".msg", ".srv"} and path.is_file():
            files[str(path.relative_to(root))] = path.read_text()
    return files


def test_pocketsensor_msgs_copy_matches_contract(repo_root: Path) -> None:
    src = repo_root / "contract" / "msg" / "pocketsensor_msgs"
    dst = repo_root / "ros2" / "pocketsensor_msgs"
    assert src.is_dir()
    assert dst.is_dir()
    assert _iface_files(src) == _iface_files(dst)
    assert _iface_files(src), "contract pocketsensor_msgs has no .msg/.srv files"

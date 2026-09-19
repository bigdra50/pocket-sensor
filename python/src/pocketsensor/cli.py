"""コマンドライン入口。main(argv) は subprocess 無しで試せる。"""

from __future__ import annotations

import argparse
import sys
import time
from collections.abc import Sequence
from typing import Any

from pocketsensor.config import Config
from pocketsensor.device import open
from pocketsensor.discovery import discover
from pocketsensor.errors import PocketSensorError
from pocketsensor.playback import is_recording_source
from pocketsensor.streams import Battery, Color, Depth, Gnss, Imu, Mag, Pose, Pressure, Stream

_STREAM_FACTORIES = {
    "color": Color,
    "depth": Depth,
    "pose": Pose,
    "imu": Imu,
    "mag": Mag,
    "pressure": Pressure,
    "gnss": Gnss,
    "battery": Battery,
}


def main(argv: Sequence[str] | None = None) -> int:
    parser = _build_parser()
    try:
        args = parser.parse_args(list(argv) if argv is not None else None)
    except SystemExit as exc:
        code = exc.code
        if code is None:
            return 0
        try:
            return int(code)
        except (TypeError, ValueError):
            return 2
    try:
        return int(args.func(args))
    except (PocketSensorError, OSError, TimeoutError, EOFError, ValueError) as exc:
        print(str(exc), file=sys.stderr)
        return 1


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="pocketsensor")
    sub = parser.add_subparsers(dest="cmd", required=True)

    discover_p = sub.add_parser("discover", help="find devices over Bonjour and USB")
    discover_p.add_argument("--timeout", type=float, default=2.0, metavar="S")
    discover_p.set_defaults(func=_cmd_discover)

    info_p = sub.add_parser("info", help="print device info, streams, calibration, clock")
    info_p.add_argument("source")
    info_p.set_defaults(func=_cmd_info)

    record_p = sub.add_parser("record", help="record an MCAP file")
    record_p.add_argument("source")
    record_p.add_argument("-o", "--output", required=True)
    record_p.add_argument("--duration", type=float, metavar="S")
    record_p.add_argument("--streams", default="color,depth,pose,imu")
    record_p.set_defaults(func=_cmd_record)

    echo_p = sub.add_parser("echo", help="print decoded messages for one topic")
    echo_p.add_argument("source")
    echo_p.add_argument("topic")
    echo_p.add_argument("-n", "--count", type=int, default=None)
    echo_p.set_defaults(func=_cmd_echo)
    return parser


def _parse_streams(text: str) -> tuple[Any, ...]:
    specs: list[Any] = []
    for part in text.split(","):
        key = part.strip().lower()
        if not key:
            continue
        if key == "imu_raw":
            specs.append(Imu(raw=True))
            continue
        factory = _STREAM_FACTORIES.get(key)
        if factory is None:
            raise ValueError(f"unknown stream: {key}")
        specs.append(factory())
    if not specs:
        raise ValueError("no streams specified")
    return tuple(specs)


def _open(source: str, config: Config):
    if is_recording_source(source):
        return open(source, config, realtime=False)
    return open(source, config)


def _cmd_discover(args: argparse.Namespace) -> int:
    devices = discover(timeout=args.timeout)
    for item in devices:
        print(f"{item.transport}\t{item.name}\t{item.source}")
    return 0


def _wait_clock(dev: Any, budget: float = 3.0) -> None:
    deadline = time.monotonic() + budget
    while time.monotonic() < deadline:
        if dev.clock.ready:
            return
        time.sleep(0.05)


def _cmd_info(args: argparse.Namespace) -> int:
    config = Config(streams=_parse_streams("color,depth,pose,imu"), open_timeout=5.0)
    with _open(args.source, config) as dev:
        _wait_clock(dev)
        info = dev.info
        print(f"name={info.name}")
        print(f"model={info.model}")
        print(f"os_version={info.os_version}")
        print(f"app_version={info.app_version}")
        print(f"mode={info.mode}")
        print(f"streams={sorted(info.streams)}")
        try:
            depth_k = dev.calibration.intrinsics(Stream.DEPTH)
            print(f"depth_intrinsics={depth_k.width}x{depth_k.height}")
        except Exception as exc:
            print(f"depth_intrinsics=unavailable ({exc})")
        try:
            color_k = dev.calibration.intrinsics(Stream.COLOR)
            print(f"color_intrinsics={color_k.width}x{color_k.height}")
        except Exception as exc:
            print(f"color_intrinsics=unavailable ({exc})")
        clock = dev.clock
        print(f"clock_ready={clock.ready}")
        if clock.ready:
            print(f"clock_offset_ns={clock.offset_ns}")
            print(f"clock_rtt_ns={clock.rtt_ns}")
            print(f"clock_samples={clock.sample_count}")
        else:
            print("clock_offset_ns=unavailable")
    return 0


def _cmd_record(args: argparse.Namespace) -> int:
    config = Config(streams=_parse_streams(args.streams), open_timeout=5.0)
    with _open(args.source, config) as dev:
        with dev.record(args.output):
            if args.duration is not None:
                time.sleep(max(0.0, float(args.duration)))
            else:
                while True:
                    time.sleep(0.5)
    return 0


def _compact(msg: Any) -> str:
    fields = getattr(msg, "__dataclass_fields__", None)
    if fields is None:
        return repr(msg)
    parts: list[str] = []
    for name in fields:
        if name == "__msgtype__":
            continue
        value = getattr(msg, name)
        if isinstance(value, (bytes, bytearray, memoryview)):
            parts.append(f"{name}=<{len(value)} bytes>")
            continue
        shape = getattr(value, "shape", None)
        if shape is not None and not isinstance(value, (str, dict, list, tuple)):
            parts.append(f"{name}=array{tuple(shape)}")
            continue
        text = repr(value)
        if len(text) > 120:
            text = text[:117] + "..."
        parts.append(f"{name}={text}")
    return f"{type(msg).__name__}({', '.join(parts)})"


def _cmd_echo(args: argparse.Namespace) -> int:
    config = Config(streams=_parse_streams("color,depth,pose,imu"), open_timeout=5.0)
    n = args.count
    printed = 0
    with _open(args.source, config) as dev:
        for topic, t_ns, msg in dev.messages(topics=[args.topic]):
            print(f"{topic} {t_ns} {_compact(msg)}")
            printed += 1
            if n is not None and printed >= n:
                break
    return 0

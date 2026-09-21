"""コマンドライン入口。main(argv) は subprocess 無しで試せる。"""

from __future__ import annotations

import argparse
import json
import sys
import time
from collections.abc import Callable, Sequence
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import numpy as np
from numpy.typing import NDArray

from pocketsensor.anchor_check import IMAGE_POSES, judge_anchor
from pocketsensor.axes_check import (
    STATUS_PASS,
    StepVerdict,
    judge_push,
    judge_still,
    judge_translation,
    judge_yaw,
)
from pocketsensor.config import Config
from pocketsensor.device import open
from pocketsensor.discovery import bonjour_available, discover
from pocketsensor.errors import PocketSensorError
from pocketsensor.playback import is_recording_source
from pocketsensor.streams import Anchors, Battery, Color, Depth, Gnss, Imu, Mag, Pose, Pressure, Stream
from pocketsensor.types import TrackingState

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


def main(
    argv: Sequence[str] | None = None,
    *,
    clock: Callable[[], float] | None = None,
    sleep: Callable[[float], None] | None = None,
    printer: Callable[[str], None] | None = None,
) -> int:
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
    args._clock = clock or time.monotonic
    args._sleep = sleep or time.sleep
    args._printer = printer or (lambda msg: print(msg))
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

    check_p = sub.add_parser(
        "check-axes",
        help="guided check of odom axes, yaw sign, and IMU specific-force sign",
    )
    check_p.add_argument("source")
    check_p.add_argument("--json", dest="json_out", metavar="PATH")
    check_p.add_argument("--step-seconds", type=float, default=4.0)
    check_p.add_argument("--min-move", type=float, default=0.15)
    check_p.set_defaults(func=_cmd_check_axes)

    anchor_p = sub.add_parser(
        "check-anchor",
        help="show a reference image to the camera and check the axes of its anchor frame",
    )
    anchor_p.add_argument("source")
    anchor_p.add_argument("--pose", choices=IMAGE_POSES, default="vertical", help="how the image is placed")
    anchor_p.add_argument("--timeout", type=float, default=30.0, metavar="S")
    anchor_p.add_argument("--json", dest="json_out", metavar="PATH")
    anchor_p.set_defaults(func=_cmd_check_anchor)
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
    if not bonjour_available():
        # 黙って飛ばすと、端末が同じ LAN にいても「見つからない」としか分からない
        print(
            "Bonjour discovery is skipped because zeroconf is not installed. "
            "Install the extra: pocketsensor[discovery]. Only USB devices are listed.",
            file=sys.stderr,
        )
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
            print(f"clock_wall_offset_ms={clock.wall_offset_ns / 1e6:+.3f}")
            print(f"clock_rtt_ms={clock.rtt_ns / 1e6:.3f}")
            print(f"clock_drift_ppm={clock.drift_ppm:.3f}")
            print(f"clock_samples={clock.sample_count}")
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


_CHECK_STEPS: tuple[tuple[str, str], ...] = (
    ("still", "Hold the phone still."),
    ("forward", "Move the phone about 30 cm in the direction the rear camera looks."),
    (
        "left",
        "Move the phone about 30 cm to its left. Left is defined for landscape with the camera bump UP.",
    ),
    ("up", "Move the phone about 30 cm upward (landscape, camera bump UP)."),
    (
        "yaw",
        "Rotate the phone counter-clockwise seen from above by about 45 deg, keeping it level.",
    ),
    ("push", "Push the phone quickly forward (camera direction) and stop."),
)


def _cmd_check_anchor(args: argparse.Namespace) -> int:
    """参照画像を映してもらい、届いた anchor ごとに軸の向きを判定する。"""
    timeout = float(args.timeout)
    if timeout <= 0.0:
        print("timeout must be positive", file=sys.stderr)
        return 2
    clock: Callable[[], float] = args._clock
    sleep: Callable[[float], None] = args._sleep
    printer: Callable[[str], None] = args._printer
    config = Config(streams=(Pose(), Anchors()), open_timeout=5.0)
    started_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    # 端末は anchor を、姿勢を送る回にだけ載せる。同じ時刻の姿勢が必ずあるので、時刻で組にする。
    poses: dict[int, Any] = {}
    results: dict[str, StepVerdict] = {}
    with _open(args.source, config) as dev:
        info = dev.info
        printer(f"Point the rear camera at a reference image ({args.pose}). Waiting up to {timeout:g} s.")
        deadline = clock() + timeout
        while clock() < deadline:
            try:
                frames = dev.wait_for_frames(timeout=0.2)
            except TimeoutError:
                frames = None
            if frames is not None and frames.pose is not None:
                poses[frames.t_device_ns] = frames.pose
                for stamp in sorted(poses)[:-120]:
                    del poses[stamp]
            for name, anchor in dev.anchors.latest().items():
                pose = poses.get(anchor.t_device_ns)
                if pose is None or name in results:
                    continue
                results[name] = judge_anchor(
                    anchor.position, anchor.orientation_xyzw, pose.position, image_pose=args.pose
                )
            if results:
                # 1 枚見つかったあとも少しだけ待ち、同時に映っているほかの画像も拾う。
                deadline = min(deadline, clock() + 1.0)
            sleep(0.02)
    for name, verdict in sorted(results.items()):
        measured = verdict.measured
        position = ", ".join(f"{v:+.2f}" for v in measured["camera_in_anchor_m"])
        line = (
            f"{verdict.status}  anchor  {name}  distance_m={measured['distance_m']:.2f}  "
            f"camera_in_anchor_m=({position})  up_angle_deg={measured['up_angle_deg']:.1f}"
        )
        printer(f"{line}  {verdict.reason}".rstrip())
    if not results:
        printer("FAIL  no reference image was tracked. Is it registered in the app, flat, and well lit?")
    if args.json_out:
        report = {
            "device": info.model,
            "app_version": info.app_version,
            "session_id": info.session_id,
            "started_at": started_at,
            "anchors": [{"image": name, **verdict.to_json()} for name, verdict in sorted(results.items())],
        }
        Path(args.json_out).write_text(json.dumps(report, indent=1) + "\n")
    return 0 if results and all(v.status == STATUS_PASS for v in results.values()) else 1


def _cmd_check_axes(args: argparse.Namespace) -> int:
    step_seconds = float(args.step_seconds)
    min_move = float(args.min_move)
    if step_seconds <= 0.0 or min_move <= 0.0:
        print("step-seconds and min-move must be positive", file=sys.stderr)
        return 2
    clock: Callable[[], float] = args._clock
    sleep: Callable[[float], None] = args._sleep
    printer: Callable[[str], None] = args._printer
    config = Config(streams=(Pose(), Imu(rate=100)), open_timeout=5.0)
    started_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    verdicts: list[StepVerdict] = []
    with _open(args.source, config) as dev:
        info = dev.info
        gravity: NDArray[np.float64] | None = None
        for name, instruction in _CHECK_STEPS:
            printer(f"== {name} ==")
            printer(instruction)
            for n in (3, 2, 1):
                printer(str(n))
                sleep(1.0)
            collected = _collect_step(dev, step_seconds, clock, sleep)
            verdict, gravity = _judge_collected(name, collected, min_move, gravity)
            verdicts.append(verdict)
            printer(_format_verdict(verdict))
        report = {
            "device": info.name,
            "app_version": info.app_version,
            "session_id": info.session_id,
            "started_at": started_at,
            "steps": [item.to_json() for item in verdicts],
        }
    if args.json_out:
        Path(args.json_out).write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    passed = sum(1 for item in verdicts if item.status == "PASS")
    if passed == len(verdicts):
        printer("ALL PASS")
        return 0
    printer(f"FAIL ({passed}/{len(verdicts)} steps passed)")
    return 1


def _collect_step(
    dev: Any,
    duration: float,
    clock: Callable[[], float],
    sleep: Callable[[float], None],
) -> dict[str, Any]:
    # 直前のステップや script_motion 切り替え前の組を捨ててから測る。
    for _ in range(2):
        try:
            dev.wait_for_frames(timeout=0.2)
        except TimeoutError:
            break
    dev.imu.read_all()
    t0 = clock()
    positions: list[NDArray[np.float64]] = []
    quats: list[NDArray[np.float64]] = []
    tracking: list[int] = []
    imu_t: list[int] = []
    imu_f: list[NDArray[np.float64]] = []
    imu_q: list[NDArray[np.float64]] = []

    def _take_imu() -> None:
        for sample in dev.imu.read_all():
            imu_t.append(int(sample.t_device_ns))
            imu_f.append(np.asarray(sample.linear_acceleration, dtype=np.float64))
            if sample.orientation_xyzw is not None:
                imu_q.append(np.asarray(sample.orientation_xyzw, dtype=np.float64))

    while clock() - t0 < duration:
        remaining = duration - (clock() - t0)
        try:
            frames = dev.wait_for_frames(timeout=max(0.0, min(0.05, remaining)))
        except TimeoutError:
            frames = None
        if frames is not None and frames.pose is not None:
            positions.append(np.asarray(frames.pose.position, dtype=np.float64))
            quats.append(np.asarray(frames.pose.orientation_xyzw, dtype=np.float64))
            if frames.tracking is None:
                tracking.append(int(TrackingState.NOT_AVAILABLE))
            else:
                tracking.append(int(frames.tracking.state))
        _take_imu()
        sleep(0.0)
    _take_imu()
    return {
        "positions": _stack(positions, 3),
        "quats": _stack(quats, 4),
        "tracking": np.asarray(tracking, dtype=np.int64),
        "imu_t": np.asarray(imu_t, dtype=np.int64),
        "imu_f": _stack(imu_f, 3),
        "imu_q": _stack(imu_q, 4),
    }


def _stack(rows: list[NDArray[np.float64]], width: int) -> NDArray[np.float64]:
    if not rows:
        return np.zeros((0, width), dtype=np.float64)
    return np.stack(rows)


def _judge_collected(
    name: str,
    collected: dict[str, Any],
    min_move: float,
    gravity: NDArray[np.float64] | None,
) -> tuple[StepVerdict, NDArray[np.float64] | None]:
    tracking = collected["tracking"]
    if name == "still":
        return judge_still(
            collected["positions"],
            collected["quats"],
            tracking,
            collected["imu_t"],
            collected["imu_f"],
        )
    if name == "forward":
        return (
            judge_translation(
                collected["positions"],
                collected["quats"],
                tracking,
                axis=0,
                min_move=min_move,
                name="forward",
            ),
            gravity,
        )
    if name == "left":
        return (
            judge_translation(
                collected["positions"],
                collected["quats"],
                tracking,
                axis=1,
                min_move=min_move,
                name="left",
            ),
            gravity,
        )
    if name == "up":
        return (
            judge_translation(
                collected["positions"],
                collected["quats"],
                tracking,
                axis=2,
                min_move=min_move,
                name="up",
            ),
            gravity,
        )
    if name == "yaw":
        return judge_yaw(collected["quats"], collected["imu_q"], tracking), gravity
    return judge_push(collected["imu_t"], collected["imu_f"], gravity, tracking), gravity


def _format_verdict(verdict: StepVerdict) -> str:
    parts = [verdict.status, verdict.name]
    measured = verdict.measured
    if verdict.name == "still":
        if "drift_m" in measured:
            parts.append(f"drift_cm={float(measured['drift_m']) * 100.0:.2f}")
        if "specific_force_norm" in measured:
            parts.append(f"|sf|={float(measured['specific_force_norm']):.3f}")
        if "up_angle_deg" in measured:
            parts.append(f"up_angle_deg={float(measured['up_angle_deg']):.1f}")
    elif verdict.name in {"forward", "left", "up"} and "d_link_m" in measured:
        dx, dy, dz = (float(v) for v in measured["d_link_m"])
        parts.append(f"d_link_m=({dx:.3f}, {dy:.3f}, {dz:.3f})")
    elif verdict.name == "yaw":
        if "odom_yaw_delta_deg" in measured:
            parts.append(f"odom_yaw_deg={float(measured['odom_yaw_delta_deg']):+.1f}")
        if "imu_yaw_delta_deg" in measured:
            parts.append(f"imu_yaw_deg={float(measured['imu_yaw_delta_deg']):+.1f}")
    elif verdict.name == "push" and "peak_ax" in measured:
        parts.append(f"peak_ax={float(measured['peak_ax']):.2f}")
    if verdict.reason:
        parts.append(verdict.reason)
    return "  ".join(parts)

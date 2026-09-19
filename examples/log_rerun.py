"""Rerun に pose、画像、deproject した点を流す。"""

from __future__ import annotations

import argparse
import sys

import numpy as np

import pocketsensor as ps


def main() -> int:
    parser = argparse.ArgumentParser(description="Log pocketsensor streams to Rerun")
    parser.add_argument("source", nargs="?", default="usb:")
    args = parser.parse_args()
    try:
        import rerun as rr
    except ImportError:
        print("Rerun is missing.", file=sys.stderr)
        print("uv run --with rerun-sdk python examples/log_rerun.py", file=sys.stderr)
        return 1
    rr.init("pocketsensor", spawn=True)
    config = ps.Config(streams=(ps.Color(), ps.Depth(), ps.Pose()))
    realtime = not str(args.source).endswith(".mcap")
    with ps.open(args.source, config, realtime=realtime) as dev:
        while True:
            try:
                frames = dev.wait_for_frames(timeout=1.0)
            except TimeoutError:
                continue
            except EOFError:
                break
            if frames.pose is not None:
                xyz = frames.pose.position
                quat = frames.pose.orientation_xyzw
                rr.log("pose", rr.Transform3D(translation=xyz, rotation=rr.Quaternion(xyzw=quat)))
            if frames.color is not None and frames.color.image is not None:
                rr.log("color", rr.Image(frames.color.image))
            if frames.depth is not None:
                pts = ps.deproject(frames.depth.meters, frames.depth.intrinsics).reshape(-1, 3)
                valid = np.isfinite(pts).all(axis=1)
                rr.log("points", rr.Points3D(pts[valid]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

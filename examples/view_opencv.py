"""OpenCV で color と colorized depth を表示する。"""

from __future__ import annotations

import argparse
import sys

import numpy as np

import pocketsensor as ps


def main() -> int:
    parser = argparse.ArgumentParser(description="Show color and depth from a pocketsensor source")
    parser.add_argument("source", nargs="?", default="usb:")
    args = parser.parse_args()
    try:
        import cv2
    except ImportError:
        print("OpenCV is missing.", file=sys.stderr)
        print("uv run --with opencv-python python examples/view_opencv.py", file=sys.stderr)
        return 1
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
            if frames.color is not None and frames.color.image is not None:
                cv2.imshow("color", cv2.cvtColor(frames.color.image, cv2.COLOR_RGB2BGR))
            if frames.depth is not None:
                depth = np.nan_to_num(frames.depth.meters, nan=0.0)
                scaled = cv2.normalize(depth, None, 0, 255, cv2.NORM_MINMAX)
                cv2.imshow("depth", cv2.applyColorMap(scaled.astype(np.uint8), cv2.COLORMAP_JET))
            if cv2.waitKey(1) & 0xFF == ord("q"):
                break
    cv2.destroyAllWindows()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

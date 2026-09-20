#!/usr/bin/env python3
"""ARKit の参照画像に使う目印の画像を作る。

ARKit は、特徴点が多く、繰り返しが無く、明暗の幅が広い画像を安定して検出する。
大きさと濃さの違う四角、円、線を乱数で重ねて、その条件を満たす画像にする。
乱数の種を固定してあるので、同じ画像が再現される。

    uv run --project python python tools/gen_marker.py
"""

from __future__ import annotations

import random
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
GROUP = ROOT / "ios" / "PocketSensor" / "Assets.xcassets" / "Anchors.arresourcegroup"
SIZE = 1024
MARKERS = {"marker_a": 20260920, "marker_b": 20260921}


def draw_marker(seed: int) -> Image.Image:
    rng = random.Random(seed)
    image = Image.new("RGB", (SIZE, SIZE), (255, 255, 255))
    draw = ImageDraw.Draw(image)
    # 大きい形から小さい形の順に重ねる。どの縮尺でも特徴が残る。
    for count, low, high in ((14, 180, 420), (60, 70, 180), (260, 18, 70)):
        for _ in range(count):
            w, h = rng.randint(low, high), rng.randint(low, high)
            x, y = rng.randint(-w // 3, SIZE - w // 2), rng.randint(-h // 3, SIZE - h // 2)
            tone = rng.choice((0, 30, 60, 110, 160, 200, 235, 255))
            color = (tone, tone, tone) if rng.random() < 0.7 else tuple(rng.randint(0, 255) for _ in range(3))
            if rng.random() < 0.65:
                draw.rectangle((x, y, x + w, y + h), fill=color)
            else:
                draw.ellipse((x, y, x + w, y + h), fill=color)
    for _ in range(40):
        points = [(rng.randint(0, SIZE), rng.randint(0, SIZE)) for _ in range(2)]
        draw.line(points, fill=rng.choice(((0, 0, 0), (255, 255, 255))), width=rng.randint(3, 10))
    # 向きを取り違えないように、左上の角にだけ大きい黒い三角を置く。
    draw.polygon(((0, 0), (SIZE // 4, 0), (0, SIZE // 4)), fill=(0, 0, 0))
    draw.rectangle((0, 0, SIZE - 1, SIZE - 1), outline=(0, 0, 0), width=12)
    return image


def main() -> None:
    for name in MARKERS:
        folder = GROUP / f"{name}.arreferenceimage"
        folder.mkdir(parents=True, exist_ok=True)
        draw_marker(MARKERS[name]).save(folder / f"{name}.png", optimize=True)
        print(f"wrote {folder.relative_to(ROOT)}/{name}.png")


if __name__ == "__main__":
    main()

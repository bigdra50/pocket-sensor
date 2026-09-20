# 例

`examples/` のスクリプトは受け手 SDK の使い方を短く示す。
リポジトリのルートで実行する。
`--project python` で SDK の環境を使い、例ごとの依存は `--with` で足す。

## view_opencv.py

color 画像と、色を付けた深度を OpenCV の窓に出す。

```
uv run --project python --with opencv-python python examples/view_opencv.py ws://iphone.local:8765
```

記録ファイルならパスを渡す。

```
uv run --project python --with opencv-python python examples/view_opencv.py run.mcap
```

## log_rerun.py

姿勢、RGB、深度から起こした点を Rerun へ流す。

```
uv run --project python --with rerun-sdk python examples/log_rerun.py usb:
```

記録の再生も同じ形である。

```
uv run --project python --with rerun-sdk python examples/log_rerun.py run.mcap
```

## lichtblick-layout.json

Lichtblick 用のレイアウトである。
3D、RGB、深度の 3 つのパネルを並べ、深度には色（turbo）と値の範囲（0 mm から 4000 mm）を設定してある。
深度のパネルは、設定しないままだとほぼ真っ黒に見える。
Lichtblick は、値の範囲を指定していない `16UC1` の画像を 0 mm から 10000 mm の範囲で描き、室内の距離はその下のほうに集まるためである。

`mise run view:lichtblick` は、Lichtblick の Web 版を Docker で立て、このレイアウトで開く URL を出す。
接続先は `SOURCE` で変える。

```
SOURCE=ws://iphone.local:8765 mise run view:lichtblick
```

デスクトップ版では、レイアウトのメニューの「Import from file」でこのファイルを読み込む。

トピックと frame の名前は、端末の名前が既定の `pocketsensor` のときのものである。
端末の名前を変えたときは、ファイルの中の `pocketsensor` を置き換える。
端末を縦置きで使うときは、RGB と深度のパネルの設定で Rotation を変える（[frames-and-units.md](../docs/frames-and-units.md) の「画像の向き」）。

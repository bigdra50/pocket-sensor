[English](README.en.md) | **日本語**

# 例

リポジトリのルートで実行する。
接続先には、`ws://` の URL、`usb:`、記録ファイルのパスのどれでも渡せる。

## view_opencv.py

RGB と、色を付けた深度を OpenCV の窓に出す。

```
uv run --project python --with opencv-python python examples/view_opencv.py ws://iphone.local:8765
```

## log_rerun.py

姿勢、RGB、深度から求めた点群を Rerun へ流す。

```
uv run --project python --with rerun-sdk python examples/log_rerun.py usb:
```

## lichtblick-layout.json

3D、RGB、深度の 3 つのパネルを並べた、Lichtblick 用のレイアウトである。
深度には色（turbo）と値の範囲（0 mm から 4000 mm）を設定してある。
値の範囲を設定しないと、Lichtblick は `16UC1` を 0 mm から 10000 mm で描くので、室内の深度はほぼ真っ黒に見える。

`mise run view:lichtblick` は、Lichtblick の Web 版を Docker で立て、このレイアウトで開く URL を出す。

```
SOURCE=ws://iphone.local:8765 mise run view:lichtblick
```

デスクトップ版では、レイアウトのメニューの「Import from file」でこのファイルを読み込む。

トピックと frame の名前は、端末の名前が既定の `pocketsensor` のときのものである。
端末の名前を変えたときは、ファイルの中の `pocketsensor` を置き換える。
端末を縦置きで使うときは、RGB と深度のパネルの設定で Rotation を変える。

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

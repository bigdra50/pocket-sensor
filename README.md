# pocketsensor

iPhone を、ロボットへ貼り付けて使えるセンサーにする iOS アプリと、その Python SDK。
LiDAR の深度、カメラ、自己位置、IMU、GNSS を、WiFi か USB で配信する。
データは ROS 2 標準のメッセージ型で流れるので、Lichtblick、rosbag2、ROS 2 のノードがそのまま使える。

## Quick Start

### 1. アプリを入れる

LiDAR 付きの iPhone（iOS 17 以降）、Xcode、[XcodeGen](https://github.com/yonaskolb/XcodeGen) が要る。

```
cd ios/PocketSensor
echo 'DEVELOPMENT_TEAM = <自分の Team ID>' > Local.xcconfig
xcodegen generate && open PocketSensor.xcodeproj
```

Xcode で実機を選んで Run する。
アプリが前面にいるあいだ、`ws://<iPhone の名前>.local:8765` で待ち受ける。

### 2. 見る

```
mise run view:lichtblick
```

出てきた URL を開くと、3D、RGB、深度が並ぶ（Docker が要る）。
手元の Lichtblick や Foxglove では、接続の種類に Foxglove WebSocket を選んで同じアドレスを開く。

### 3. Python で受け取る

```
uv add --editable <このリポジトリ>/python --extra discovery
```

```python
import pocketsensor as ps

config = ps.Config(streams=[ps.Color(), ps.Depth(), ps.Pose(), ps.Imu()])
with ps.open("ws://iphone.local:8765", config) as dev:   # "usb:" も "run.mcap" も同じ
    frames = dev.wait_for_frames()
    depth_m = frames.depth.meters      # float32、無効は NaN
    pose = frames.pose                 # REP-103、odom から link
    imu = dev.imu.read_all()           # 前回からの全サンプル
```

## 配信するデータ

| データ | トピック | 形式 | 既定のレート |
| --- | --- | --- | --- |
| 自己位置（ARKit） | `/<name>/odom`、`/tf` | `nav_msgs/Odometry` | 30 Hz |
| RGB | `/<name>/color/image/compressed` | JPEG、960×720 | 15 Hz |
| LiDAR の深度 | `/<name>/depth/image`、`.../compressedDepth` | `16UC1` の mm、256×192。無圧縮と PNG | 15 Hz |
| 深度の confidence | `/<name>/depth/confidence`、`.../compressed` | `mono8`。無圧縮と PNG | 15 Hz |
| IMU | `/<name>/imu/data`、`/<name>/imu/data_raw` | `sensor_msgs/Imu` | 100 Hz |
| 地磁気 | `/<name>/imu/mag` | `sensor_msgs/MagneticField` | 50 Hz |
| 気圧 | `/<name>/pressure` | `sensor_msgs/FluidPressure` | 約 1 Hz |
| GNSS | `/<name>/gnss/fix` | `sensor_msgs/NavSatFix` | 約 1 Hz |
| 電池と診断 | `/<name>/battery`、`/diagnostics` | `BatteryState`、`DiagnosticArray` | 1 Hz |
| 参照画像の anchor | `/tf` | 印刷した目印の位置と向き | 30 Hz |

- 座標は REP-103、単位は SI、時刻は端末が計測した時刻
- センサーは、購読されているあいだだけ動く
- `<name>` は端末の名前で、既定は `pocketsensor`

## コマンド

```
pocketsensor discover                          # 端末を探す
pocketsensor info   ws://iphone.local:8765     # 端末の情報、較正、時計合わせ
pocketsensor record ws://iphone.local:8765 -o run.mcap
pocketsensor echo   run.mcap /pocketsensor/odom
pocketsensor check-axes   usb:                 # 取り付けたあとに、軸の向きを確かめる
pocketsensor check-anchor usb:                 # 参照画像の anchor を確かめる
```

記録した MCAP は、`ros2 bag play` と Lichtblick でも開ける。
OpenCV と Rerun で表示する例は [examples/](examples/README.md) にある。

## ROS 2

```
ros2 launch pocketsensor_ros relay.launch.py source:=ws://iphone.local:8765
```

ビルドとパラメータは [ros2/pocketsensor_ros/](ros2/pocketsensor_ros/README.md) にある。

## 開発

```
mise run test        # Python、Swift、E2E
mise run test:ios    # アプリの単体テスト（シミュレーター）
mise run test:ros2   # ROS 2 のコンテナでの確認（Docker）
mise run sim         # iPhone 無しで試すための擬似デバイス
```

メッセージの型とチャンネルの正本は `contract/` にある。
Swift と Python のコードは、そこから生成する。

## 文書

| 読みたいこと | 文書 |
| --- | --- |
| 何を作るか、なぜその形か | [docs/architecture.md](docs/architecture.md) |
| 接続、チャンネル、設定、サービス | [docs/protocol.md](docs/protocol.md) |
| 座標系と単位 | [docs/frames-and-units.md](docs/frames-and-units.md) |
| 時刻と時計合わせ | [docs/time.md](docs/time.md) |
| SDK の API | [docs/sdk-api.md](docs/sdk-api.md) |
| iPhone 16 Pro での測定の記録 | [docs/research/on-device-measurements.md](docs/research/on-device-measurements.md) |

## License

[Apache-2.0](LICENSE) © bigdra50

# pocketsensor

> iPhone を、ロボットなど他のシステムへ組み込めるセンサーデバイスにする iOS アプリと受け手 SDK。

iPhone の RGB、LiDAR 深度、ARKit の自己位置、IMU、GNSS、地磁気、気圧を、計測時刻付きで配信する。
受け手は、ZED や RealSense の SDK と同じ作法で iPhone を開く。

- iPhone のアプリは、Foxglove WebSocket プロトコル v1 と互換のサーバーになる。Lichtblick や Foxglove から直接つないで表示できる
- データは ROS 2 の標準メッセージを CDR で流す。記録した MCAP は rosbag2 でも再生できる
- WiFi、USB、USB-C の Ethernet アダプタを、同じ接続の手順で使える
- 受け手の SDK は ROS 2 に依存しない。実機と記録ファイルを同じ API で開ける

## 現在の段階

最初の段階のセンサー（姿勢、RGB、深度、IMU、地磁気、気圧、GNSS、電池）の配信と、Python の受け手 SDK が動く。
深度と confidence は、無圧縮と PNG の可逆圧縮の 2 通りで配信する。

| 項目 | 状態 |
| --- | --- |
| iOS アプリ | iPhone 16 Pro で動作を確認した |
| Python SDK（接続、フレームの組、IMU、較正、時計合わせ、記録と再生、コマンド） | 実機（WiFi と USB）と擬似デバイスで確認した |
| Lichtblick からの接続 | 実機へ直接つなぎ、TF、RGB、深度、IMU の表示を確認した。`compressedDepth` だけは Lichtblick が復号できないので、表示には無圧縮の深度を使う |
| USB での接続 | 実機で確認した。破棄は 0 で、遅延の中央値は約 60 ms |
| ROS 2 の中継 | ROS 2 Jazzy のコンテナで、ビルド、実行、`image_transport` での深度の復号、rosbag2 での再生を確認した |
| 参照画像の anchor | 擬似デバイスでは確認した。実機では、参照画像を登録して映す確認をしていない |
| H.264、マイク、iPhone への出力 | 次の段階で足す |

実機での測定の記録は [docs/research/on-device-measurements.md](docs/research/on-device-measurements.md) にある。

## Install

### iOS アプリ

LiDAR の付いた iPhone（iOS 17 以降）、Xcode、[XcodeGen](https://github.com/yonaskolb/XcodeGen) が要る。
署名に使う Team ID は、リポジトリへ入れない `Local.xcconfig` に書く。

```
cd ios/PocketSensor
echo 'DEVELOPMENT_TEAM = <自分の Team ID>' > Local.xcconfig
xcodegen generate
open PocketSensor.xcodeproj
```

Xcode で実機を選び、Run する。

### Python SDK

Python 3.10 以降が要る。
PyPI には出していないので、リポジトリから入れる。

```
uv add --editable <リポジトリの場所>/python --extra discovery
```

`discovery` は、Bonjour での発見に使う zeroconf を足す。

## Usage

アプリを起動し、画面を表示したままにする。
アプリが待ち受けるのは、前面で動いているあいだだけである。
接続先のアドレスは、画面の Link の欄で確かめられる。

```
pocketsensor discover                                  # 端末を探す
pocketsensor info ws://iphone.local:8765               # 端末の情報、較正、時計合わせの状態
pocketsensor record ws://iphone.local:8765 -o run.mcap # MCAP へ記録する
pocketsensor echo run.mcap /pocketsensor/odom          # 記録も同じ形で開ける
```

```python
import pocketsensor as ps

config = ps.Config(streams=[ps.Color(rate=15), ps.Depth(rate=15), ps.Pose(), ps.Imu(rate=100)])

with ps.open("ws://iphone.local:8765", config) as dev:    # "usb:" も "run.mcap" も同じ
    while True:
        frames = dev.wait_for_frames(timeout=1.0)
        depth_m = frames.depth.meters                     # float32、無効は NaN
        pose = frames.pose                                # REP-103、odom から link
        for sample in dev.imu.read_all():                 # 前回の呼び出し以降の全サンプル
            ...
```

| やりたいこと | 見るもの |
| --- | --- |
| Lichtblick や Foxglove で表示する | 接続の種類に Foxglove WebSocket を選び、`ws://iphone.local:8765` を開く。`mise run view:lichtblick` は、3D、RGB、深度を並べたレイアウトで開く URL を出す（[examples/](examples/README.md)） |
| OpenCV や Rerun で表示する | [examples/](examples/README.md) |
| ROS 2 のトピックへ流す | [ros2/pocketsensor_ros/](ros2/pocketsensor_ros/README.md) |
| 取り付けたあとに軸の向きを確かめる | `pocketsensor check-axes usb:` の指示に従って端末を動かす |
| 参照画像で原点を固定する | `tools/show_marker.html` の目印を印刷するか画面へ出し、`pocketsensor check-anchor usb:` で確かめる |
| iPhone 無しで試す | `mise run sim` で擬似デバイスを起動し、`ws://127.0.0.1:8765` を開く |

## Development

タスクは [mise](https://mise.jdx.dev/) で走らせる。
uv、Swift、XcodeGen は、PATH にあるものを使う。

| タスク | 内容 |
| --- | --- |
| `mise run test` | 生成物が `contract/` と一致するかの検査と、Python、Swift、E2E のテストをまとめて走らせる |
| `mise run test:python` | Python SDK のテスト（E2E を除く） |
| `mise run test:swift` | Swift パッケージのテスト（macOS の上で走る） |
| `mise run test:ios` | iOS アプリの単体テストをシミュレーターで走らせる（署名は要らない） |
| `mise run test:e2e` | Swift の擬似デバイスと Python SDK を通しで確かめる |
| `mise run test:foxglove-client` | Lichtblick と同じクライアントと復号器でサーバーを確かめる（node が要る） |
| `mise run test:ros2` | ROS 2 のコンテナの中で、中継、`image_transport`、TF、rosbag2 を確かめる（Docker が要る） |
| `mise run view:lichtblick` | Lichtblick の Web 版を Docker で立て、用意したレイアウトで開く URL を出す |
| `mise run lint:python` | ruff の検査 |
| `mise run gen` | `contract/` から Swift と Python の生成物を作り直す |

メッセージの型、チャンネル、parameters、services の正本は `contract/` にある。
Swift の型と Python の表は、そこから生成する。

## Documentation

| 読みたいこと | 文書 |
| --- | --- |
| 何を作るか、なぜその形か | [docs/architecture.md](docs/architecture.md) |
| 接続、チャンネル、設定、サービス | [docs/protocol.md](docs/protocol.md) |
| 座標系と単位 | [docs/frames-and-units.md](docs/frames-and-units.md) |
| 時刻と時計合わせ | [docs/time.md](docs/time.md) |
| 受け手 SDK の API | [docs/sdk-api.md](docs/sdk-api.md) |
| 設計の根拠にした調査と、実機での測定 | [docs/research/](docs/research/) |

## License

[Apache-2.0](LICENSE) © bigdra50

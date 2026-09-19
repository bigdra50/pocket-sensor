# pocketsensor

> iPhone を、ロボットなど他のシステムへ組み込めるセンサーデバイスにする iOS アプリと受け手 SDK。

iPhone の RGB、LiDAR 深度、ARKit の自己位置、IMU、GNSS、地磁気、気圧を、計測時刻付きで配信する。
受け手は、ZED や RealSense の SDK と同じ作法で iPhone を開く。

- iPhone のアプリは、Foxglove WebSocket プロトコル v1 と互換のサーバーになる。Lichtblick や Foxglove から直接つないで表示できる
- データは ROS 2 の標準メッセージを CDR で流す。記録した MCAP は rosbag2 でも再生できる
- WiFi、USB、USB-C の Ethernet アダプタを、同じ接続の手順で使える
- 受け手の SDK は ROS 2 に依存しない。実機と記録ファイルを同じ API で開ける

## 現在の段階

設計を終えた段階で、実装はこれから入る。
Install と Usage は、最初の実装と一緒に足す。

## Documentation

| 読みたいこと | 文書 |
| --- | --- |
| 何を作るか、なぜその形か | [docs/architecture.md](docs/architecture.md) |
| 接続、チャンネル、設定、サービス | [docs/protocol.md](docs/protocol.md) |
| 座標系と単位 | [docs/frames-and-units.md](docs/frames-and-units.md) |
| 時刻と時計合わせ | [docs/time.md](docs/time.md) |
| 受け手 SDK の API | [docs/sdk-api.md](docs/sdk-api.md) |
| 設計の根拠にした調査 | [docs/research/](docs/research/) |

## License

[Apache-2.0](LICENSE) © bigdra50

[English](README.en.md) | **日本語**

# contract

pocketsensor が配信するメッセージの定義を、機械可読な形で置く。
意図の説明は [docs/protocol.md](../docs/protocol.md) にある。
説明と定義が食い違ったときは、このディレクトリの定義を正とする。

| パス | 内容 |
| --- | --- |
| `msg/` | メッセージとサービスの定義（`.msg`、`.srv`） |
| `channels.toml` | チャンネルの表 |
| `parameters.toml` | parameters の表 |
| `services.toml` | services の表 |
| `vectors/` | Swift と Python が共有するテストベクトル |

## 生成物

Swift の型とスキーマの本文、Python が読む表は、ここから生成する。
生成物はリポジトリへ入れてあり、定義を変えたら作り直す。

```bash
mise run gen          # 生成物を作り直す
mise run gen:check    # 生成物が定義と一致しているかを確かめる
mise run vectors      # テストベクトルを作り直す
```

テストベクトルは Python の基準実装が作り、Swift のテストが同じファイルを読む。
CDR のバイト列は `rosbags` の出力を基準にする。

## 取り込んだ定義の出どころ

`msg/` のうち `pocketsensor_msgs` 以外は、ROS 2 の jazzy ブランチから内容を変えずに取り込んだ。

| パッケージ | 取り込み元 | コミット | ライセンス |
| --- | --- | --- | --- |
| `std_msgs`、`geometry_msgs`、`nav_msgs`、`sensor_msgs`、`diagnostic_msgs`、`std_srvs` | [ros2/common_interfaces](https://github.com/ros2/common_interfaces) | `a941f14` | Apache-2.0 |
| `builtin_interfaces` | [ros2/rcl_interfaces](https://github.com/ros2/rcl_interfaces) | `7aa3caf` | Apache-2.0 |
| `tf2_msgs` | [ros2/geometry2](https://github.com/ros2/geometry2) | `f702874` | BSD-3-Clause（`msg/tf2_msgs/LICENSE`） |

取り込むのは、チャンネルと services が使う型と、その依存に限る。

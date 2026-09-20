# pocketsensor_ros

iPhone の配信を ROS 2 のトピックへ流す中継ノードである。
Python SDK が受け取った CDR のバイト列を、復号せずにそのまま publish する。
ROS 2 Jazzy で確かめてある。

## ビルド

ROS 2 のワークスペースで、2 つのパッケージを `--paths` で指定する。
Python SDK（`python/`）は、ROS 2 が使う Python へ先に入れておく。

```
pip install ./python
colcon build --paths ros2/pocketsensor_msgs ros2/pocketsensor_ros
source install/setup.bash
```

`pocketsensor_msgs` の `.msg` と `.srv` は、`contract/msg/pocketsensor_msgs` のコピーである。

## 実行

```
ros2 launch pocketsensor_ros relay.launch.py source:=ws://iphone.local:8765
```

USB でつなぐときは `source:=usb:` を渡す。

| パラメータ | 型 | 既定 | 意味 |
| --- | --- | --- | --- |
| `source` | 文字列 | `ws://iphone.local:8765` | 接続先。`ws://<host>:<port>` か `usb:` |
| `rewrite_stamp` | 真偽値 | true | `header.stamp` を、このマシンの壁時計へ書き換える |
| `streams` | 文字列の配列 | 空 | 流すストリーム。空なら、端末が広告したチャンネルをすべて流す |
| `publish_tf` | 真偽値 | true | false なら、端末の姿勢の `/tf` と `/tf_static` を出さない。参照画像の anchor は出す（下の URDF の節を参照） |
| `reconnect_period` | 実数（秒） | 2.0 | つながらないときと切れたときに、接続し直す間隔 |
| `depth_transport` | 文字列 | `compressed` | 深度と confidence をどの形で受け取るか。`compressed`（PNG）、`raw`（無圧縮）、`both` |

`streams` には `color`、`depth`、`pose`、`imu`、`imu_raw`、`mag`、`pressure`、`gnss`、`battery` を書ける。
絞り込んだときも、`/tf_static`、`device_info`、`/diagnostics` は流す。

### 深度の受け取り方

`depth_transport` を指定しなければ、中継は PNG のほうだけを購読して `<トピック>/compressedDepth` と `<トピック>/compressed` へ流す。
`sensor_msgs/Image` が要るノードには、ロボットの側で `image_transport` の `republish` を挟む。

```
ros2 run image_transport republish compressedDepth raw --ros-args \
  -r in/compressedDepth:=/pocketsensor/depth/image/compressedDepth -r out:=/pocketsensor/depth/image
```

### 時刻

端末が付ける `header.stamp` は、端末の時計の値である。
`rewrite_stamp` が true のとき、中継は時計合わせ（`clock_sync`）の結果で、この値をマシンの壁時計へ写してから publish する。
時計合わせが済むまでに届いたメッセージは捨てる。
端末の時計の値のままでは、tf2 と `message_filters` が、ほかのノードのメッセージと組にできない。

### 接続し直し

端末のアプリは、前面にいるあいだだけ待ち受ける。
中継は `reconnect_period` ごとに接続し直し、セッションごとに時計合わせをやり直す。
端末より先に中継を起動してもよい。

### QoS

| トピック | QoS |
| --- | --- |
| 画像、深度、IMU | sensor data（best effort、深さ 5） |
| `/tf_static`、`device_info` | reliable、transient local、深さ 1 |
| `/tf` | reliable、深さ 100 |
| そのほか | reliable、深さ 10 |

## URDF

`urdf/pocketsensor.urdf.xacro` のマクロ `pocketsensor_device` は、取り付け先の link の下へ端末の frame を足す。
`name` と `parent` を渡し、取り付けの位置と向きは `xyz` と `rpy` で渡す（既定は 0）。

```
<xacro:include filename="$(find pocketsensor_ros)/urdf/pocketsensor.urdf.xacro"/>
<xacro:pocketsensor_device name="pocketsensor" parent="base_link" xyz="0 0 0.3"/>
```

マクロは `<name>_link`、`<name>_color_optical_frame`、`<name>_imu_link` の 3 つの link を作る。

このマクロを使うときは、中継を `publish_tf:=false` で起動する。
中継の `/tf` は `<name>_odom` から `<name>_link` への変換を出すので、URDF が `<name>_link` の親を決めていると、親が 2 つになる。
端末の姿勢は `/<name>/odom`（`nav_msgs/Odometry`）から受け取る。

参照画像の anchor は、`publish_tf` の値で出し方が変わる。

| `publish_tf` | `/tf` に出る anchor の変換 |
| --- | --- |
| true | `<name>_odom` から `<name>_anchor_<画像の名前>`。端末が送った値のまま |
| false | `<name>_link` から `<name>_anchor_<画像の名前>`。同じ時刻の端末の姿勢を使って、端末から見た変換へ直す |

false のときの形は、`apriltag_ros` がカメラの frame からタグへの変換を出すのと同じである。

## テスト

```
mise run test:ros2                               # 擬似デバイスを相手に、ROS 2 のコンテナの中で確かめる
SOURCE=ws://192.168.1.20:8765 mise run test:ros2 # 実機を相手にする
```

Docker が要る。
イメージは環境変数 `POCKETSENSOR_ROS_IMAGE` で選べ、指定しなければ `ros:jazzy-ros-base` を使う。

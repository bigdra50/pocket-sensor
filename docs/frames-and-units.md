# 座標系と単位

wire に載せる値は、ROS 2 の約束（REP-103、REP-105、REP-145）と SI 単位に揃える。
Apple の API が返す値との変換は、iPhone のアプリが受け持つ。

## 共通の約束

- 座標系はすべて右手系
- 端末に固定した frame は、x が前、y が左、z が上
- カメラの光学 frame は、z が視線の向き、x が画像の右、y が画像の下
- 回転は単位四元数（x, y, z, w）で表す
- 長さは m、角度は rad、時間は s

## frame の一覧

frame 名の前には、端末の名前 `<name>` を付ける。

| frame | 定義 |
| --- | --- |
| `<name>_odom` | ARKit の world を REP-103 へ付け替えたもの。z は重力の逆向きで、原点と水平の向きはセッションの開始時に決まる |
| `<name>_link` | 端末に固定した基準の frame。原点は背面の広角カメラの光学中心。x はカメラの視線の向きで、背面から外へ出る |
| `<name>_color_optical_frame` | 原点は `<name>_link` と同じ。z が視線の向き、x が画像の右、y が画像の下 |
| `<name>_imu_link` | Core Motion の端末座標系そのもの。縦持ちで画面を見て、x が右、y が上、z が手前 |
| `<name>_anchor_<画像の名前>` | 参照画像に固定した frame。原点は画像の中心。z は画像の面の法線で、表から手前へ出る。x は画像の上、y は画像の左 |

`<name>_link` の y（左）と z（上）は、カメラ群を上にした横置きの姿勢を基準にしている。
端末を縦置きで取り付けると、`<name>_link` は前方の軸まわりに 90° 回った姿勢で出る。
この回転は、ロボット側の URDF が持つ取り付けの変換へ含める。

### 画像の向き

RGB、深度、confidence の画素は、端末の持ち方にも画面の向きにも依らず、センサーの並びのまま送る。
この並びは、カメラ群を上にした横置きで正立する。
縦置きで使うと、表示ツールの画像は 90° 回って見える。
`camera_info` と `<name>_color_optical_frame` は、この画素の並びに対して決まっている。
JPEG へ EXIF の向きは入れない。

人が見るために正立させる処理は、表示の側へ置く。
Lichtblick と Foxglove では Image パネルの設定の Rotation、ROS 2 では `image_rotate` が使える。

### 固定の変換

`/tf_static` で流す変換は次の 2 つである。

| 親 | 子 | 回転（roll, pitch, yaw） | 並進 |
| --- | --- | --- | --- |
| `<name>_link` | `<name>_color_optical_frame` | (-π/2, 0, -π/2) | 0 |
| `<name>_link` | `<name>_imu_link` | (0, -π/2, 0) | 0（未較正） |

光学 frame への回転は、RealSense と Orbbec の ROS 2 ラッパーが使う値と同じである。
カメラと IMU のあいだの並進は測っていないので 0 とし、`device_info` に未較正と記す。

## ARKit の姿勢の変換

ARKit の world は、右手系、y が上、重力に整列している。
カメラは -z を向き、+x が右、+y が上である。
REP-103 との違いは軸の付け替えだけなので、変換は回転行列 1 つで表せる。

```
        |  0   0  -1 |      x_odom（前） = -z_arkit
    R = | -1   0   0 |      y_odom（左） = -x_arkit
        |  0   1   0 |      z_odom（上） = +y_arkit

    p_odom       = R * p_arkit
    R_odom_link  = R * R_arkit_camera * R^T
```

参照画像の anchor にも同じ変換を使う。
ARKit の anchor の座標系は、x が画像の右、y が画像の面の法線、z が画像の下である。
変換後の frame は、x が画像の上、y が画像の左、z が法線になる。
壁に貼った画像なら、z が壁から部屋の中へ向く。

world の向きは `.gravity` で決めるので、yaw は北を基準にしない。

## 画像と内部パラメータ

- 画素の座標は、左上の画素の中心を原点とする。ARKit の内部パラメータと OpenCV が、同じ約束を使っている
- `camera_info` の `k` と `p` は、送る画像の解像度に合わせた値を入れ、`width` と `height` も書き換える。`binning` と `roi` は使わない
- ARKit はレンズの歪みの係数を出さない。`distortion_model` は `plumb_bob`、`d` は 0 を 5 つ入れる
- `camera_info` は、画像と同じ時刻で毎フレーム送る

### 解像度を変えるときの換算

横の倍率を sx、縦の倍率を sy とする。
深度の内部パラメータは、RGB の解像度の値からこの式で求める。

```
    fx' = fx * sx                   cx' = (cx + 0.5) * sx - 0.5
    fy' = fy * sy                   cy' = (cy + 0.5) * sy - 0.5
```

主点へ 0.5 を加えてから倍率を掛けるのは、画素の中心を原点とする約束のためである。

## 単位の変換

| 量 | Apple の値 | wire の値 | 変換 |
| --- | --- | --- | --- |
| 加速度 | G。静止して画面が上なら z は -1 | m/s² の比力。静止して z が上なら +g | -9.80665 を掛ける |
| 角速度 | rad/s | rad/s | しない |
| 地磁気 | µT | T | 1e-6 を掛ける |
| 気圧 | kPa | Pa | 1000 を掛ける |
| 緯度と経度 | 度（WGS 84） | 度 | しない |
| 高度 | `ellipsoidalAltitude`（WGS 84 の楕円体からの m） | m | しない |
| 水平と垂直の精度 | 半径と 1σ（m） | 分散（m²） | 二乗して対角へ入れる |
| 進行の方位 | 真北が 0°、時計回り | 東が 0 rad、反時計回り | π/2 から、rad へ直した値を引く |
| 深度 | `Float32` の m | `uint16` の mm | 1000 を掛けて丸める |
| 電池の残量 | 0 から 1 | 0 から 1 | しない |

### 加速度

`imu/data_raw` の加速度は、`CMAccelerometerData` の値に -9.80665 を掛けたものである。
`imu/data` の加速度は、`CMDeviceMotion` の `userAcceleration` と `gravity` を足してから、同じ係数を掛ける。
どちらも、REP-145 が求めるとおり重力を含む。

`imu/data_raw` は向きを持たないので、`orientation_covariance` の先頭へ -1 を入れる。

### 地磁気

`imu/mag` には、`CMDeviceMotion` の較正済みの値を入れる。
較正の度合い（未較正、低、中、高）は `/diagnostics` で知らせ、未較正のあいだは `imu/mag` を流さない。

### GNSS

- 高度は `ellipsoidalAltitude` を使う。`altitude` は海抜で、`NavSatFix` が求める楕円体からの高さと基準が違う
- `position_covariance` は East、North、Up の順の対角へ、精度の二乗を入れる。`position_covariance_type` は `APPROXIMATED` とする
- `horizontalAccuracy` が負なら測位は無効で、`status` を `STATUS_NO_FIX` にし、緯度、経度、高度を NaN にする
- `verticalAccuracy` だけが負なら、高度だけを NaN にする
- 衛星系の別は API から分からないので、`service` は 0 とする
- 測位の時刻（壁時計）は `gnss/time_reference` の `time_ref` に入れる。`header.stamp` の扱いは [time.md](time.md) にある

### 深度

無効な画素は 0 にする。
ARKit の深度が NaN、0 以下、65.535 m 以上の画素を、無効として扱う。
confidence による足切りはアプリではせず、クライアントが `depth/confidence` を見て決める。

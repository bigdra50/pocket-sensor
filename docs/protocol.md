# プロトコル

iPhone のアプリは、Foxglove WebSocket プロトコル v1 と互換のサーバーとして動く。
データは ROS 2 の標準メッセージを CDR でエンコードして流し、設定は parameters、時刻同期と指示は services で受ける。
チャンネルと型の正本は `contract/` にある。

## 接続

| 項目 | 内容 |
| --- | --- |
| トランスポート | TCP 上の WebSocket。ポートの初期値は 8765（foxglove_bridge と同じ） |
| 接続の向き | iPhone が待ち受け、クライアントが接続する。同時に複数の接続を受ける |
| サブプロトコル | `foxglove.sdk.v1` と `foxglove.websocket.v1` の両方を受ける。両方の提示なら前者を選ぶ |
| WiFi と Ethernet | Bonjour のサービス型 `_pocketsensor._tcp` でアドバタイズする。IP アドレスを直接指定しても接続できる |
| USB | ホスト側の usbmux が、同じポートへの接続を端末へ転送する |

Bonjour のアドバタイズには、ローカルネットワークの許可が要る。
許可が無くても、IP アドレスの直接指定と USB では接続できる。

### 接続の直後に送るもの

1. `serverInfo`。`name` は `pocketsensor`、`capabilities` は `parameters`、`parametersSubscribe`、`services` の 3 つ
2. `advertise`。その時点で配信できるチャンネルをすべて載せる
3. `advertiseServices`

`serverInfo` の `sessionId` は、セッションごとに作る UUID である。
クライアントは、再接続のときに同じセッションが続いているかをこの値で見分ける。
`supportedEncodings` は `cdr` とする。

### セッション

セッションは、アプリがフォアグラウンドで配信を続けているひと続きの期間である。
アプリは、バックグラウンドへ移る時点で待ち受けを閉じ、接続を切る。
フォアグラウンドへ戻ったら待ち受けを開き直し、新しいセッションを始める。

セッションが変わると、`sessionId` と時刻の基準（[time.md](time.md) の `anchor`）が新しくなり、ARKit の world 原点もリセットされる。
クライアントは、前のセッションのデータと連続していないものとして扱う。

## チャンネル

チャンネルの `encoding` は `cdr`、`schemaEncoding` は `ros2msg` である。
`schema` には、依存する型の定義までを連結した `.msg` の本文を入れる。
クライアントは、ROS 2 を入れていなくても型を復元できる。

トピック名と frame 名は、端末の名前 `<name>` を前に付ける。
初期値は `pocketsensor` で、アプリの画面で変えられる。
frame の定義は [frames-and-units.md](frames-and-units.md) にある。

| トピック | 型 | frame_id | レートの初期値 |
| --- | --- | --- | --- |
| `/<name>/odom` | `nav_msgs/msg/Odometry` | `<name>_odom`、child は `<name>_link` | 30 Hz |
| `/<name>/tracking` | `pocketsensor_msgs/msg/TrackingStatus` | `<name>_link` | 姿勢と同じ |
| `/tf` | `tf2_msgs/msg/TFMessage` | `<name>_odom` から `<name>_link`。参照画像の anchor もここへ載る | 姿勢と同じ |
| `/tf_static` | `tf2_msgs/msg/TFMessage` | `<name>_link` から各センサー | 購読の直後と変更時 |
| `/<name>/color/image/compressed` | `sensor_msgs/msg/CompressedImage` | `<name>_color_optical_frame` | 15 Hz |
| `/<name>/color/camera_info` | `sensor_msgs/msg/CameraInfo` | `<name>_color_optical_frame` | 画像と同じ |
| `/<name>/depth/image` | `sensor_msgs/msg/Image`（`16UC1`） | `<name>_color_optical_frame` | 15 Hz |
| `/<name>/depth/confidence` | `sensor_msgs/msg/Image`（`mono8`） | `<name>_color_optical_frame` | 深度と同じ |
| `/<name>/depth/camera_info` | `sensor_msgs/msg/CameraInfo` | `<name>_color_optical_frame` | 深度と同じ |
| `/<name>/depth/image/compressedDepth` | `sensor_msgs/msg/CompressedImage`（PNG） | `<name>_color_optical_frame` | 深度と同じ |
| `/<name>/depth/confidence/compressed` | `sensor_msgs/msg/CompressedImage`（PNG） | `<name>_color_optical_frame` | 深度と同じ |
| `/<name>/imu/data_raw` | `sensor_msgs/msg/Imu` | `<name>_imu_link` | 100 Hz |
| `/<name>/imu/data` | `sensor_msgs/msg/Imu` | `<name>_imu_link` | 100 Hz |
| `/<name>/imu/mag` | `sensor_msgs/msg/MagneticField` | `<name>_imu_link` | 50 Hz |
| `/<name>/pressure` | `sensor_msgs/msg/FluidPressure` | `<name>_link` | 端末が出す間隔 |
| `/<name>/gnss/fix` | `sensor_msgs/msg/NavSatFix` | `<name>_link` | 端末が出す間隔 |
| `/<name>/gnss/time_reference` | `sensor_msgs/msg/TimeReference` | 使わない | 測位と同じ |
| `/<name>/battery` | `sensor_msgs/msg/BatteryState` | 使わない | 1 Hz |
| `/<name>/device_info` | `std_msgs/msg/String`（JSON） | 使わない | 購読の直後と変更時 |
| `/diagnostics` | `diagnostic_msgs/msg/DiagnosticArray` | 使わない | 1 Hz |

同じ ARFrame から作る姿勢、RGB、深度、confidence、`camera_info` には、同じ時刻を付ける。
クライアントは、時刻の一致でフレームセットを作る。

深度は RGB のカメラへ位置合わせ済みなので、frame_id は RGB と同じにしてある。
単位はミリメートルで、無効な画素には 0 が入る。
`depth/camera_info` には、深度の解像度に合わせた内部パラメータを入れる。
`confidence` の画素値は、ARKit の `ARConfidenceLevel` のとおり 0（低）、1（中）、2（高）である。

### 深度の可逆圧縮

深度と confidence は、無圧縮のチャンネルと、PNG で可逆圧縮したチャンネルの 2 通りで出す。
中身は同じで、クライアントが購読で選ぶ。
端末は、購読されたほうだけをエンコードする。

| チャンネル | `format` | `data` |
| --- | --- | --- |
| `depth/image/compressedDepth` | `16UC1; compressedDepth png` | 12 バイトのヘッダに続けて、16 bit のグレースケールの PNG |
| `depth/confidence/compressed` | `mono8; png compressed `（末尾に空白が 1 つ） | 8 bit のグレースケールの PNG |

トピック名、`format` の文字列、12 バイトのヘッダは、ROS の `image_transport` の `compressedDepth` と `compressed` に合わせた。
ROS 2 の側は、`image_transport` の `republish` で `sensor_msgs/Image` へ戻せる。
ヘッダは `int32` の 0（`INV_DEPTH`）と `float32` の 0 が 2 つで、どれも little endian である。
`16UC1` の深度では、デコードする側はこのヘッダを読み飛ばすだけでよい。

無圧縮の深度と confidence は、15 Hz で毎秒 2.2 MB になる。
Python SDK は、端末がアドバタイズしていれば圧縮のほうを購読する。
可視化ツールで深度を色付きで見たいときは、無圧縮の `depth/image` を購読する。

### トラッキングの状態

ARKit のトラッキングの状態は、姿勢と同じ時刻の `TrackingStatus` で流す。

| フィールド | 型 | 内容 |
| --- | --- | --- |
| `header` | `std_msgs/Header` | 姿勢と同じ時刻 |
| `state` | `uint8` | 0 は利用不可、1 は制限あり、2 は正常 |
| `reason` | `uint8` | 0 は無し、1 は初期化中、2 は動きが速すぎる、3 は特徴が足りない、4 は再ローカライズ中 |
| `origin_epoch` | `uint32` | ARKit の world 原点をリセットするたびに増える数 |

`origin_epoch` が変わったら、クライアントは前の姿勢と連続していないものとして扱う。
原点をリセットするのは、`reset_origin` が呼ばれたときと、止まっていた ARKit が再開するときである。
`state` が 0 のあいだは、`odom` と `/tf` を流さない。

`odom` の `pose.covariance` は 0（不明）である。
ARKit は速度を出さないので、`twist` は 0 とし、`twist.covariance` の先頭へ -1 を入れる。

### 参照画像の anchor

ARKit の world 原点は、セッションごとに変わる。
部屋へ貼った画像を基準にすると、クライアントはセッションをまたいで同じ原点を作れる。

アプリへ組み込んだ参照画像を ARKit がトラッキングしているあいだ、`<name>_odom` から `<name>_anchor_<画像の名前>` への変換を `/tf` へ載せる。
参照画像は、Xcode の AR Resource Group `Anchors` へ、印刷したときの実寸と一緒に登録する。
画像の名前は frame 名の一部になるので、英小文字、数字、下線だけで付ける。

アプリには、目印の画像を 2 枚（`marker_a` と `marker_b`）登録してある。
どちらも、横 15 cm で印刷して使う。
左上の黒い三角が、画像の上と左を示す。
画像は `tools/gen_marker.py` が作り、`tools/show_marker.html` を開くと、画面の上へ実寸で表示できる。

| 項目 | 内容 |
| --- | --- |
| レート | 画像ごとに 0.5 秒に 1 回を上限にする |
| トラッキングが外れたとき | 流すのをやめる |
| 時刻 | 検出した ARFrame の時刻。同じフレームの姿勢と同じ値になる |
| まとめ方 | 姿勢を送る回にだけ、その姿勢の変換と同じ `TFMessage` へ載せる |

anchor の時刻は、`odom` のどれかの時刻と必ず一致する。
クライアントは、同じ時刻の姿勢と組にして、端末から見た anchor の位置（`<name>_link` から anchor への変換）を求められる。
`pose.rate` を 2 Hz より下げると、anchor の間隔も姿勢の間隔まで延びる。
anchor の frame の軸は [frames-and-units.md](frames-and-units.md) にある。

### 購読の直後に送るチャンネル

`/tf_static` と `/<name>/device_info` は、購読を受けた直後に最新の 1 件を送る。
ROS 2 の transient local に当たる。

`device_info` は、ストリームを解釈するためのメタデータを 1 つの JSON にまとめたものである。

| キー | 内容 |
| --- | --- |
| `schema_version` | この JSON の版 |
| `session_id` | セッションごとの UUID。`serverInfo` の `sessionId` と同じ値 |
| `name` | 端末の名前。トピック名と frame 名の前に付く |
| `model`、`os_version`、`app_version` | 機種の識別子、iOS の版、アプリの版 |
| `mode` | カメラのモード。`arkit` だけ |
| `streams` | アドバタイズしている全チャンネル。キーはチャンネルの表（`contract/channels.toml`）の key |
| `clock` | クロックの種類と、システム時刻との差。[time.md](time.md) を参照 |
| `frames` | frame 名の一覧と、固定の変換 |

入れ子の中身は次のとおりである。

| キー | 中身 |
| --- | --- |
| `streams.<key>` | `topic` と `schema`。画像のチャンネルには `width`、`height`、`encoding`、レートの決まっているチャンネルには `rate`（Hz）が加わる |
| `clock` | `kind`（クロックの種類）、`anchor_ns`、`anchored_at_wall_ns`、`self_check` |
| `frames` | `odom`、`link`、`color_optical`、`imu_link` の frame 名と、固定の変換の配列 `static_transforms` |
| `frames.static_transforms[]` | `parent`、`child`、`translation`、`rotation_xyzw`、`calibrated` |

`calibrated` が false の変換は、回転は正しいが、並進を測っていない（0 を入れてある）。
IMU への変換がこれに当たる。

### diagnostics の中身

`/diagnostics` は、1 Hz で次の status を 1 つの `DiagnosticArray` にまとめて流す。
データが届かない理由は、ここで判別できる。
`hardware_id` には端末の名前を入れる。

| `name` | `level` | `values` |
| --- | --- | --- |
| `pocketsensor/tracking` | 正常は OK、制限ありは WARN、利用不可は ERROR。ARKit を止めているあいだは OK とし、`message` を `stopped` にする | `state`、`reason`（`TrackingStatus` と同じ数値） |
| `pocketsensor/thermal` | nominal と fair は OK、serious は WARN、critical は ERROR | `level` |
| `pocketsensor/streams` | 破棄が 1 件でもあれば WARN | `clients`、`rate.<key>`（送った実績の Hz）、`drops.<key>`（バックプレッシャーで破棄した数）、`encode_skips.<key>`（エンコードが間に合わず飛ばした数） |
| `pocketsensor/clock` | セルフチェックが suspicious なら ERROR | `self_check`（[time.md](time.md) を参照） |
| `pocketsensor/mag` | high と medium は OK、low と unknown は WARN、uncalibrated は ERROR | `calibration` |
| `pocketsensor/gnss` | authorized は OK、not_determined は WARN、denied と restricted は ERROR | `authorization` |
| `pocketsensor/sensors` | 常に OK | `arkit`、`depth`、`motion`、`altimeter`、`battery`、`gnss`。値は、そのセンサー群が動いていれば `on`、止まっていれば `off` |

`<key>` は、チャンネルの表（`contract/channels.toml`）の key である。
`message` には、その status の要約（`values` の主な値と同じ文字列）を入れる。

位置情報の許可は、測位が初めて必要になった時点で、端末の画面で求める。
許可されるまで `gnss/fix` は届かないので、クライアントは `pocketsensor/gnss` の `authorization` で理由を知る。

## 購読とセンサーの起動

端末は、購読されたチャンネルに要るセンサーだけを動かす。
クライアントは、使うチャンネルだけを購読する。
深度を購読しなければ LiDAR は動かず、姿勢、RGB、深度のどれも購読しなければ ARKit も動かない。
アプリの画面が表示のためにセンサーを動かしていることもあるが、クライアントの購読には影響しない。

止まっているセンサーのチャンネルを購読すると、最初のメッセージまでに時間がかかる。
ARKit は、最初のフレームまでに 1 秒ほど、トラッキングが正常になるまでに 4 秒ほどかかる。
購読が無くなっても、センサーは 10 秒のあいだ動かし続ける。

ARKit が再開すると、world の原点はリセットされ、`origin_epoch` が増える。
姿勢の連続性が要るクライアントは、`odom` か `/tf` を購読したままにする。

## parameters

設定は Foxglove の parameters で読み書きする。
設定は端末に 1 つで、どの接続から変えても全体へ反映される。
変更は、`subscribeParameterUpdates` をした接続へ通知する。

| 名前 | 型 | 初期値 | 内容 |
| --- | --- | --- | --- |
| `pose.rate` | 数値 | 30 | 姿勢、`tracking`、`/tf` のレートの上限（Hz） |
| `color.rate` | 数値 | 15 | RGB のレートの上限（Hz） |
| `color.width` | 数値 | 960 | 送る画像の幅（画素）。高さは縦横比から決まる |
| `color.jpeg_quality` | 数値 | 0.8 | JPEG の品質（0 から 1） |
| `depth.rate` | 数値 | 15 | 深度と confidence のレートの上限（Hz） |
| `imu.rate` | 数値 | 100 | IMU のレート（Hz）。端末の上限を超える値は上限へ丸める |
| `imu.reference_frame` | 文字列 | `arbitrary` | `imu/data` の向きの基準。`arbitrary` か `true_north` |
| `device.name` | 文字列 | `pocketsensor` | 読み取り専用。変更はアプリの画面でする |

レートは上限である。
ARKit は 60 fps のまま動かし、配信するときに間引く。

1. 姿勢、RGB、深度の上限のうち最も高いものを、基準のレートとする。ARFrame の時刻を見て、前に選んだフレームから基準の間隔がたったフレームを選び、通し番号を振る
2. レートの上限が r のストリームは、N を基準のレート / r の切り上げとして、その通し番号が N で割り切れるフレームだけを送る

レートが違っても、遅い側のフレームは速い側のフレームに含まれるので、同じフレームのデータが揃う。
端末の thermal state が serious なら基準のレートを半分、critical なら 6 分の 1 へ下げ、実際のレートを `/diagnostics` で知らせる。

## services

| 名前 | 型 | 内容 |
| --- | --- | --- |
| `/<name>/clock_sync` | `pocketsensor_msgs/srv/ClockSync` | 時刻同期の 1 往復。[time.md](time.md) を参照 |
| `/<name>/reset_origin` | `std_srvs/srv/Trigger` | ARKit の world 原点をリセットし、`origin_epoch` を 1 増やす |

`ClockSync` の要求は `uint64 t1`（クライアントのクロック、ナノ秒）の 1 項目である。
応答は `uint64 t1`（要求の値をそのまま返す）、`uint64 t2`（受信の時刻）、`uint64 t3`（返信の時刻）の 3 項目である。
`t2` と `t3` は、チャンネルの時刻と同じクロックで測る。

`std_srvs/srv/Trigger` の要求のようにフィールドの無いメッセージは、ROS 2 のエンコードに合わせて、値が 0 の 1 バイトを本体とする。
iPhone のアプリは、この 1 バイトが無い要求も受け付ける。

## バックプレッシャー

送信が追いつかないときの扱いは、チャンネルの種類ごとに決めてあり、接続ごとに適用する。

| チャンネル | キューの扱い |
| --- | --- |
| 姿勢、`tracking`、`/tf`、RGB、深度、confidence、`camera_info` | 最新の 1 件だけを持つ。送信中に次が来たら置き換える |
| IMU、地磁気 | 1 秒分までのキュー。あふれたら古いものから破棄する |
| そのほか | 破棄しない |

同じ ARFrame から作ったメッセージは、まとめて置き換える。
RGB の JPEG 化のように時間のかかるメッセージは、同じ時刻を付けたまま、あとから同じまとまりへ加わる。
エンコードが次のフレームに間に合わなければ、その回の RGB だけを飛ばす。
破棄した件数と飛ばした回数は、チャンネルごとに `/diagnostics` で知らせる。

## MCAP への記録

クライアントは、受信したメッセージをそのまま MCAP へ書ける。

| MCAP の要素 | 入れるもの |
| --- | --- |
| Schema と Channel | `advertise` で受けた `schemaName`、`schema`、`topic`、`encoding` |
| Message の `log_time` と `publish_time` | Message Data の時刻（計測時刻） |
| Metadata | `device_info` の JSON と、時刻同期のサンプル |

この形の MCAP は `cdr` と `ros2msg` の組み合わせなので、Lichtblick でも rosbag2 でも開ける。

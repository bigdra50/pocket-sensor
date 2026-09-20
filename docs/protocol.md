# 通信の約束

iPhone のアプリは、Foxglove WebSocket プロトコル v1 と互換のサーバーとして動く。
データは ROS 2 の標準メッセージを CDR で符号化して流し、設定は parameters、時計合わせと指示は services で受ける。
この文書は、接続の手順、チャンネル、parameters、services、背圧の約束を定める。

実装が始まったら、チャンネルと型の正本は `contract/` の機械可読な定義へ移る。
この文書は、その定義の意図を説明する役割を持つ。

## 接続

| 項目 | 約束 |
| --- | --- |
| 転送 | TCP の上の WebSocket。ポートの初期値は 8765（foxglove_bridge と同じ） |
| 向き | iPhone が待ち受け、クライアントが接続する。同時に複数の接続を受ける |
| サブプロトコル | `foxglove.sdk.v1` と `foxglove.websocket.v1` の両方を受ける。両方の提示なら前者を選ぶ |
| 名前の比較 | 提示された名前は、前後の空白を除いてから比べる |
| 遅延 | TCP の `noDelay` を有効にする |
| WiFi と Ethernet | Bonjour のサービス型 `_pocketsensor._tcp` で広告する。IP アドレスを直接指定しても接続できる |
| USB | ホスト側の usbmux が、同じポートへの接続を端末へ転送する。アプリ側に専用の実装は要らない |

サブプロトコル名を 2 つとも受けるのは、可視化ツールごとに提示する名前が違うためである。
Lichtblick は両方を提示し、PlotJuggler は `foxglove.sdk.v1` だけを提示する。
空白を除くのは、Network.framework がカンマ区切りの 2 つ目以降を空白付きで渡してくるためである。

Bonjour の広告にはローカルネットワークの許可が要り、TCP の待ち受けと受理には要らない。
利用者が許可を与えなくても、IP アドレスの直接指定と USB では接続できる。

### 接続の直後に送るもの

1. `serverInfo`。`name` は `pocketsensor`、`capabilities` は `parameters`、`parametersSubscribe`、`services` の 3 つ
2. `advertise`。その時点で配信できるチャンネルをすべて載せる
3. `advertiseServices`

`serverInfo` の `sessionId` には、セッションごとに作る UUID を入れる。
クライアントは、再接続のときに同じセッションが続いているかをこの値で見分ける。
`supportedEncodings` は `cdr` とする。
これは、services の要求と応答に使う符号化をクライアントへ知らせる項目である。

### セッション

セッションは、アプリが前面で配信を続けているひと続きの期間である。
アプリの起動か、背景からの復帰で始まり、背景へ回った時点で終わる。

iOS は、背景へ回ったアプリをまもなく停止する。
アプリは背景へ回る時点で待ち受けを閉じ、接続を切る。
前面へ戻ったら待ち受けを開き直し、新しいセッションを始める。

セッションが変わると、`sessionId` と時刻の基準（[time.md](time.md) の `anchor`）が新しくなり、ARKit の world 原点も作り直される。
クライアントは、前のセッションのデータと連続していないものとして扱う。

## チャンネル

チャンネルの `encoding` は `cdr`、`schemaEncoding` は `ros2msg` である。
`schema` には、依存する型の定義までを連結した `.msg` の本文を入れる。
これにより、クライアントは ROS 2 を入れていなくても型を復元できる。

トピック名と frame 名は、端末の名前 `<name>` を前に付ける。
初期値は `pocketsensor` で、複数台を同じロボットに載せるときはアプリの画面で変える。
frame の定義は [frames-and-units.md](frames-and-units.md) にある。

### 最初の段階

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
クライアントは、時刻の一致でフレームの組を作る。

深度は ARKit が RGB のカメラへ位置合わせ済みの値なので、frame_id は RGB と同じにする。
単位はミリメートル、無効な画素は 0 である。
`depth/camera_info` の内部パラメータは、深度の解像度に合わせた値を入れる。
換算の式は [frames-and-units.md](frames-and-units.md) にある。

`confidence` の画素値は、ARKit の `ARConfidenceLevel` のとおり 0（低）、1（中）、2（高）である。

### 深度の可逆圧縮

深度と confidence は、無圧縮のチャンネルと、PNG で可逆圧縮したチャンネルの 2 通りで出す。
中身は同じで、クライアントが購読で選ぶ。
端末は、購読されたほうだけを符号化する。

| チャンネル | `format` | `data` |
| --- | --- | --- |
| `depth/image/compressedDepth` | `16UC1; compressedDepth png` | 12 バイトのヘッダに続けて、16 bit のグレースケールの PNG |
| `depth/confidence/compressed` | `mono8; png compressed `（末尾に空白が 1 つ） | 8 bit のグレースケールの PNG |

トピック名、`format` の文字列、12 バイトのヘッダは、ROS の `image_transport` の `compressedDepth` と `compressed` に合わせた。
ROS 2 の側は、`image_transport` の `republish` で `sensor_msgs/Image` へ戻せる。
ヘッダは `int32` の 0（`INV_DEPTH`）と `float32` の 0 が 2 つで、どれも little endian である。
`16UC1` の深度では、復号する側はこのヘッダの値を使わず、読み飛ばすだけである。

無圧縮の深度と confidence は、15 Hz で毎秒 2.2 MB になる。
WiFi では最新 1 件を保持する背圧のチャンネルが 1 割ほど捨てられており、この 2 つが帯域の大半を占めていた。
測定は [measurements.md](measurements.md) にある。
Python SDK は、端末が広告していれば圧縮のほうを購読する。
表示ツールで深度を色付きで見たいときは、無圧縮の `depth/image` を購読する。

### 追跡の状態

`nav_msgs/msg/Odometry` には、ARKit の追跡の状態を載せる場所が無い。
そこで、姿勢と同じ時刻の `TrackingStatus` を別のチャンネルで流す。

| フィールド | 型 | 内容 |
| --- | --- | --- |
| `header` | `std_msgs/Header` | 姿勢と同じ時刻 |
| `state` | `uint8` | 0 は利用不可、1 は制限あり、2 は正常 |
| `reason` | `uint8` | 0 は無し、1 は初期化中、2 は動きが速すぎる、3 は特徴が足りない、4 は再ローカライズ中 |
| `origin_epoch` | `uint32` | ARKit の world 原点を作り直すたびに増える数 |

`origin_epoch` が変わったら、クライアントは前の姿勢と連続していないものとして扱う。
原点を作り直すのは、`reset_origin` が呼ばれたときと、止まっていた ARKit が動き直すときである。
`state` が 0 のあいだは、`odom` と `/tf` を流さない。
`odom` の `pose.covariance` には、`state` に応じた対角の値を入れる。
値は台車の上での測定を経て決めるので、それまでは 0（不明）にしておく。
ARKit は速度を出さないので、`twist` は求めない。
値は 0 とし、`twist.covariance` の先頭へ -1 を入れて、値が無いことを示す。
`sensor_msgs/Imu` が、持たない量の共分散の先頭へ -1 を入れる約束に倣った。

独自のメッセージはこの 1 つと、時計合わせのサービスに限る。
標準の型で表せるものに、独自の型を作らない。

### 参照画像の anchor

ARKit の world 原点は、セッションごとに変わる。
部屋へ貼った画像を基準にすると、クライアントはセッションをまたいで同じ原点を作れる。
AprilTag に当たる役割を、ARKit の参照画像の検出が受け持つ。

アプリへ組み込んだ参照画像を ARKit が追跡しているあいだ、`<name>_odom` から `<name>_anchor_<画像の名前>` への変換を `/tf` へ載せる。
参照画像は、Xcode の AR Resource Group `Anchors` へ、印刷したときの実寸と一緒に登録する。
画像の名前は frame 名の一部になるので、英小文字、数字、下線だけで付ける。

アプリには、目印の画像を 2 枚（`marker_a` と `marker_b`）登録してある。
どちらも、横 15 cm で印刷して使う。
左上の黒い三角が、画像の上と左を示す。
画像は `tools/gen_marker.py` が作り、`tools/show_marker.html` を開くと、画面の上へ実寸で表示できる。
別の画像を使うときは、同じ AR Resource Group へ足してアプリをビルドし直す。

| 項目 | 内容 |
| --- | --- |
| レート | 画像ごとに 0.5 秒に 1 回を上限にする |
| 追跡が外れたとき | 流すのをやめる。ARKit は外れたあとも最後の変換を持ち続けるが、古い値なので出さない |
| 時刻 | 検出した ARFrame の時刻。同じフレームの姿勢と同じ値になる |
| まとめ方 | 姿勢を送る回にだけ、その姿勢の変換と同じ `TFMessage` へ載せる |

anchor を姿勢と同じ回にだけ載せるので、anchor の時刻は `odom` のどれかの時刻と必ず一致する。
クライアントは、同じ時刻の姿勢と組にして、端末から見た anchor の位置（`<name>_link` から anchor への変換）を求められる。
`pose.rate` を 2 Hz より下げると、anchor の間隔も姿勢の間隔まで延びる。

同じメッセージへ載せるのは、`/tf` の背圧が最新 1 件の保持だからである。
別のメッセージにすると、姿勢か anchor のどちらかが捨てられる。
anchor の frame の軸は [frames-and-units.md](frames-and-units.md) にある。

### 購読の直後に送るチャンネル

Foxglove WebSocket プロトコルには、ROS 2 の transient local に当たる仕組みが無い。
`/tf_static`、`/<name>/device_info` は、購読を受けた直後に最新の 1 件を送る。

`device_info` は、ストリームを解釈するためのメタデータを 1 つの JSON にまとめたものである。
Ouster の `SensorInfo` と同じ役割を持つ。

| キー | 内容 |
| --- | --- |
| `schema_version` | この JSON の版 |
| `session_id` | セッションごとの UUID。`serverInfo` の `sessionId` と同じ値 |
| `name` | 端末の名前。トピック名と frame 名の前に付く |
| `model`、`os_version`、`app_version` | 機種の識別子、iOS の版、アプリの版 |
| `mode` | カメラのモード。最初は `arkit` だけ |
| `streams` | 広告している全チャンネル。キーはチャンネルの表（`contract/channels.toml`）の key |
| `clock` | 時計の種類と、壁時計へ固定したときの差。[time.md](time.md) を参照 |
| `frames` | frame 名の一覧と、固定の変換 |

`streams` の値は、`topic` と `schema` を必ず持つ。
画像のチャンネルは `width`、`height`、`encoding` を持ち、レートの決まっているチャンネルは `rate`（Hz）を持つ。
クライアントは、端末が何を出せるかを、開く前にこの一覧で知る。

`clock` は `kind`（時計の種類）、`anchor_ns`、`anchored_at_wall_ns`、`self_check` を持つ。

`frames` は、frame 名を `odom`、`link`、`color_optical`、`imu_link` のキーで持つ。
固定の変換は `static_transforms` の配列で、1 つが `parent`、`child`、`translation`、`rotation_xyzw`、`calibrated` を持つ。
中身は `/tf_static` と同じで、`calibrated` だけがここにしか無い。
`calibrated` が false の変換は、回転は正しいが、並進を測っていない（0 を入れてある）。
IMU への変換がこれに当たる。

### diagnostics の中身

`/diagnostics` は、クライアントが端末の画面を見ずに状態を知るためのチャンネルである。
データが届かない理由（追跡の喪失、熱によるレートの低下、背圧による破棄、位置情報の許可の不足、センサーの停止）を、ここで判別できるようにする。
1 Hz で、次の status を 1 つの `DiagnosticArray` にまとめて流す。
`hardware_id` には端末の名前を入れる。

| `name` | `level` | `values` |
| --- | --- | --- |
| `pocketsensor/tracking` | 正常は OK、制限ありは WARN、利用不可は ERROR。ARKit を止めているあいだは OK とし、`message` を `stopped` にする | `state`、`reason`（`TrackingStatus` と同じ数値） |
| `pocketsensor/thermal` | nominal と fair は OK、serious は WARN、critical は ERROR | `level` |
| `pocketsensor/streams` | 破棄が 1 件でもあれば WARN | `clients`、`rate.<key>`（送った実績の Hz）、`drops.<key>`（背圧で捨てた数）、`encode_skips.<key>`（符号化が間に合わず飛ばした数） |
| `pocketsensor/clock` | 自己点検が suspicious なら ERROR | `self_check`（[time.md](time.md) を参照） |
| `pocketsensor/mag` | high と medium は OK、low と unknown は WARN、未較正は ERROR | `calibration` |
| `pocketsensor/gnss` | authorized は OK、not_determined は WARN、denied と restricted は ERROR | `authorization` |
| `pocketsensor/sensors` | 常に OK | `arkit`、`depth`、`motion`、`altimeter`、`battery`、`gnss`。値は、そのセンサー群が動いていれば `on`、止まっていれば `off` |

`<key>` は、チャンネルの表（`contract/channels.toml`）の key である。
`message` には、その status の要約（`values` の主な値と同じ文字列）を入れる。

位置情報の許可は、測位が初めて必要になった時点で、端末の画面で求める。
GNSS のチャンネルの最初の購読か、アプリの設定での GNSS の表示の ON が、そのきっかけになる。
許可されるまで `gnss/fix` は届かないので、クライアントは `pocketsensor/gnss` の `authorization` で理由を知る。

### 次の段階で足すチャンネル

| トピック | 型 | 内容 |
| --- | --- | --- |
| `/<name>/color/video` | `foxglove_msgs/msg/CompressedVideo` | H.264。Annex B、1 メッセージ 1 フレーム、B フレームなし、キーフレームに SPS と PPS を同梱 |
| `/<name>/imu/mag_raw` | `sensor_msgs/msg/MagneticField` | 端末自身の磁気の偏りを含む生値 |
| `/<name>/gnss/vel` | `geometry_msgs/msg/TwistStamped` | 対地速度。ENU で表す |
| `/<name>/audio` | 未定 | マイク |

## 購読とセンサーの起動

端末は、購読されたチャンネルに要るセンサーだけを動かす。
クライアントは、使うチャンネルだけを購読する。
深度を購読しなければ LiDAR は動かず、姿勢、RGB、深度のどれも購読しなければ ARKit も動かない。
アプリの画面が表示のためにセンサーを動かしていることもあるが、クライアントの購読には影響しない。

止まっているセンサーのチャンネルを購読すると、最初のメッセージまでに時間がかかる。
ARKit は、最初のフレームまでに 1 秒ほど、追跡が正常になるまでに 4 秒ほどかかる。
購読が無くなっても、センサーは 10 秒のあいだ動かし続ける。

ARKit が動き直すと、world の原点は作り直され、`origin_epoch` が増える。
姿勢の連続性が要るクライアントは、`odom` か `/tf` を購読したままにする。

## parameters

設定は Foxglove の parameters で読み書きする。
名前は平らにし、値は数値、真偽値、文字列に限る。
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

チャンネルを有効にするための parameter は持たない。
購読している接続が無いチャンネルでは、センサーの取得と符号化を止める。
GNSS のように許可が要るセンサーは、最初の購読を受けたときに起動する。

レートは上限である。
ARKit は 60 fps のまま動かし、wire に載せる分だけを間引く。
間引きは 2 段で決める。

1. 姿勢、RGB、深度の上限のうち最も高いものを、基準のレートとする。ARFrame の時刻を見て、前に選んだフレームから基準の間隔がたったフレームを選び、通し番号を振る
2. レートの上限が r のストリームは、N を基準のレート / r の切り上げとして、その通し番号が N で割り切れるフレームだけを送る

1 段目を時刻で決めるのは、ARKit が届けるフレームの数に左右されないためである。
端末が熱を持つと、ARKit のフレームは毎秒 60 枚より減る。
フレームの枚数だけで間引くと、送るレートがその割合で上限を下回る。

2 段目を通し番号で決めるのは、同じフレームの組を揃えるためである。
姿勢が 30 Hz で RGB と深度が 15 Hz のようにレートが違っても、遅い側のフレームは速い側のフレームに含まれる。
ストリームごとに別々の時刻で間引くと、同じフレームの組が揃わなくなる。

端末の熱の状態が serious なら基準のレートを半分、critical なら 6 分の 1 へ下げ、実際のレートを `/diagnostics` で知らせる。

## services

| 名前 | 型 | 内容 |
| --- | --- | --- |
| `/<name>/clock_sync` | `pocketsensor_msgs/srv/ClockSync` | 時計合わせの 1 往復。[time.md](time.md) を参照 |
| `/<name>/reset_origin` | `std_srvs/srv/Trigger` | ARKit の world 原点を作り直し、`origin_epoch` を 1 増やす |

`ClockSync` の要求は `uint64 t1`（クライアントの時計、ナノ秒）の 1 項目である。
応答は `uint64 t1`（要求の値をそのまま返す）、`uint64 t2`（受信の時刻）、`uint64 t3`（返信の時刻）の 3 項目である。
`t2` と `t3` は、チャンネルの時刻と同じ時計で測る。

`std_srvs/srv/Trigger` の要求のようにフィールドの無いメッセージは、ROS 2 の符号化に合わせて、値が 0 の 1 バイトを本体とする。
iPhone のアプリは、この 1 バイトが無い要求も受け付ける。

iPhone を出力装置として使う指示（音声、トーチ、触覚、画面の表示）は、次の段階で services として足す。

## 背圧

接続ごとに、チャンネルの種類に応じた送信待ちの持ち方をする。

| チャンネル | 送信待ちの持ち方 | 理由 |
| --- | --- | --- |
| 姿勢、`tracking`、`/tf`、RGB、深度、confidence、`camera_info` | 最新の 1 件だけを持つ。送信中に次が来たら置き換える | 遅いクライアントへ古いフレームが届き続けるのを防ぐ |
| IMU、地磁気 | 1 秒分までのキュー。あふれたら古いものから捨てる | 積分に使うので、短い詰まりでは欠落させない |
| そのほか | 捨てない | 低いレートで、量も小さい |

同じ ARFrame から作ったメッセージは、まとめて置き換える。
RGB の JPEG 化のように時間のかかるメッセージは、同じ時刻を付けたまま、あとから同じまとまりへ加わる。
姿勢や深度を、RGB の符号化が終わるまで待たせないためである。
符号化が次のフレームに間に合わなければ、その回の RGB だけを飛ばし、飛ばした回数を `/diagnostics` で知らせる。
RGB だけが新しく、深度が古い、という組をクライアントへ渡さないためである。
捨てた件数はチャンネルごとに数え、`/diagnostics` で知らせる。

公式の Foxglove SDK は、接続ごとに 1024 件のキューを持ち、あふれると古いものから捨てる。
大きなメッセージを 1024 件ためると秒単位の遅れになるので、この方式は採らない。

## 記録との対応

クライアントは、受信したメッセージをそのまま MCAP へ書ける。

| MCAP の要素 | 入れるもの |
| --- | --- |
| Schema と Channel | `advertise` で受けた `schemaName`、`schema`、`topic`、`encoding` |
| Message の `log_time` と `publish_time` | Message Data の時刻（計測時刻） |
| Metadata | `device_info` の JSON と、時計合わせのサンプル |

この形の MCAP は `cdr` と `ros2msg` の組なので、Lichtblick でも rosbag2 でも開ける。

## 後で足すもの

- foxglove_bridge への publish。iPhone がクライアントとして接続し、同じ CDR のバイト列を送る。USB では張れず、時計合わせも使えない
- 認証と暗号化。自己署名の証明書をピン留めした TLS にする

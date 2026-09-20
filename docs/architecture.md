# pocketsensor の設計

pocketsensor は、iPhone をロボットなど他のシステムへ組み込めるセンサーデバイスにする。
iOS アプリが iPhone のセンサーを配信し、Python SDK がそれを ZED や RealSense と同じ作法で開く。
この文書は、立ち位置、全体の構成、決定事項とその理由をまとめる。
個別の約束は次の文書に分けてある。

| 文書 | 内容 |
| --- | --- |
| [protocol.md](protocol.md) | 接続、チャンネル、設定、サービス、背圧 |
| [frames-and-units.md](frames-and-units.md) | 座標系と単位の約束、Apple の値からの変換 |
| [time.md](time.md) | 端末の時計、時刻の付け方、時計合わせ |
| [sdk-api.md](sdk-api.md) | Python SDK の API |
| [measurements.md](measurements.md) | iPhone の実機で測った記録 |

## 立ち位置

iPhone のセンサーを外へ出すアプリは既にある。
Conduit は iPhone を ROS 2 のノードにし、Record3D は RGB-D と姿勢を USB で流す。
pocketsensor は、iPhone を SDK 付きのセンサーデバイスとして扱える形にする。
ROS 2 は必須にせず、クライアント側のアダプタとして足す。

軸にするのは、既存のものが満たしていない次の 5 点である。

| 軸にする点 | 既存の状況 |
| --- | --- |
| 姿勢、RGB-D、IMU、GNSS を 1 本で出す | Conduit の公開文書に姿勢の配信が無い。Record3D は IMU と GNSS を出さない |
| 計測時刻を付け、クライアントの時計とのずれを推定する | 時計合わせを持つ製品が見つからない。研究では外部センサーとの同期を後処理で済ませている |
| 有線（USB、Ethernet）を正式な経路にする | Conduit の DDS は WiFi に固定されている。研究での配信は有線に寄っている |
| 実機、記録、再生を同じ API で扱う | Record3D はライブ配信を保存できない |
| 商用に使えるライセンスで公開する | Record3D 系は LGPL-2.1、Record3DStream は個人の非商用に限られる |

## 全体の構成

```
 iPhone (pocketsensor app)                      クライアント
+----------------------------------+   WiFi   +----------------------------------------+
| capture                          |   USB    | Python SDK                             |
|   ARKit: pose / RGB / depth      |   LAN    |   discover / open(url)                 |
|   CoreMotion: IMU / mag / baro   |<-------->|   FrameSet / calibration / clock       |
|   CoreLocation: GNSS / heading   |          |   record -> MCAP / open(file) で再生   |
| encode                           |          |     +--> ROS 2 中継 (CDR のまま publish)|
|   CDR (sensor_msgs ほか) / JPEG  |          |     +--> Rerun / LeRobot の例          |
| server                           |          +----------------------------------------+
|   Foxglove WS v1 (NWListener)    |<--------> Lichtblick / Foxglove / PlotJuggler (直結)
|   parameters: 設定               |
|   services: 時計合わせ、指示     |
+----------------------------------+
```

| 構成要素 | 置き場所 | 責務 |
| --- | --- | --- |
| iOS アプリ | `ios/` | センサーの取得、REP-103 と SI への変換、符号化、配信。画面は状態の表示と最小の操作に留める |
| 契約 | `contract/` | `.msg`、チャンネルの表、parameters と services のスキーマ |
| Python SDK | `python/` | 発見、接続、復号、時計の対応付け、較正、フレームの組、記録と再生 |
| ROS 2 中継 | `ros2/` | 受け取った CDR のバイト列を ROS 2 のトピックへ流す。URDF の xacro も持つ |
| 例 | `examples/` | Rerun での表示、OpenCV での表示、LeRobot のデータセットへの記録 |

アプリは、生データとメタデータ（時刻、内部パラメータ、座標系）を流すことに徹する。
取り付け位置からロボットの基準座標への変換や、Nav2 向けの疑似 LaserScan のような加工は、クライアント側に置く。

## 決定事項

| 論点 | 決定 | 理由 |
| --- | --- | --- |
| 接続の向き | iPhone が WebSocket のサーバーになり、クライアントが接続する | USB の転送（usbmux）は、ホストから端末への向きにしか張れない。サーバー 1 本なら WiFi、USB、Ethernet が同じコードになる |
| 通信形式 | Foxglove WebSocket プロトコル v1 と互換にする | Lichtblick、Foxglove、PlotJuggler が iPhone へ直接つながる。購読したチャンネルだけを送る仕組みも仕様に含まれる |
| 中身の型と符号化 | ROS 2 の標準メッセージを CDR で送る | IMU、地磁気、気圧、GNSS の型が揃っている。記録した MCAP を rosbag2 で再生でき、foxglove_bridge への publish にも同じバイト列を使える |
| 座標と単位 | REP-103 と SI に揃え、変換はアプリが受け持つ | 可視化ツールや ROS 2 の中継は iPhone のデータを直接受ける。クライアント側で変換する前提が成り立たない |
| 契約の正本 | `.msg` とチャンネルの表を正本にする。Swift の型はそこから生成し、Python は `.msg` を実行時に読む | 標準メッセージの定義は ROS 2 が保守している。2 つの言語の型を手で揃える作業が消える |
| 設定 | Foxglove の parameters に載せる | 平らな名前と値の組で足りる。Foxglove のパネルからも変更できる |
| 時計合わせと指示 | Foxglove の services に載せる | プロトコルに時計合わせの仕組みが無い。往復 4 時刻の方式は、要求と応答の 1 往復で表せる |
| 時刻 | センサーが計測した時刻を付け、クライアントが時計のずれを推定する | 処理時点の時刻では、同じフレームの深度と姿勢に別々の時刻が付く。クライアントが遅延を補償するにも計測時刻が要る |
| 転送路 | TCP の待ち受け 1 本を WiFi、USB、Ethernet で共用する | 研究での配信は有線に寄っている。WiFi 上の UDP は大きなメッセージが欠けやすい |
| 背圧 | 画像、深度、姿勢は接続ごとに最新 1 件を保持する。IMU は上限付きのキューにする | 遅いクライアントへ古いフレームが届き続けるのを防ぐ。IMU は積分に使うので、欠落をできるだけ避ける |
| 圧縮 | RGB は JPEG で送る。深度は `16UC1` の無圧縮と、PNG の可逆圧縮の 2 本を出し、クライアントが購読で選ぶ | JPEG と PNG はフレーム単位で復号でき、クライアントに FFmpeg が要らない。深度の PNG は、WiFi で無圧縮の深度が帯域の大半を占めたので足した。H.264 は、それでも帯域が足りなくなった段階で足す |
| センサーの起動 | センサー群ごとに、購読している接続があるか、アプリの設定でその区画の表示が ON のときだけ動かす。ARKit と LiDAR もこの対象にする | ARKit と LiDAR は消費電力が大きく、誰も使っていないのに動かし続けると端末が熱を持つ。実機では 1 時間あまりの使用で熱の状態が serious になり、レートが落ちた |
| SDK の言語 | Python を先行させ、実機、記録、ネットワークを同じ API で開く | ロボット学習と ROS の利用者は Python が中心である。ZED、Orbbec、Ouster が同じ形を採っている |
| 記録 | MCAP へ、受信したバイト列をそのまま書く | 復号と再符号化が要らない。スキーマと較正がファイルに入り、Lichtblick と rosbag2 の両方で開ける |
| カメラのモード | ARKit から始める | 姿勢を取れるのは ARKit だけである。AVFoundation の LiDAR 深度カメラは、姿勢が要らない用途のために後で足す |
| 派生データ | アプリは生データとメタデータだけを流す | 疑似 LaserScan のような加工は、ロボットごとに条件が違う。クライアント側の `pointcloud_to_laserscan` や Nav2 の costmap が、高さの帯で切れる |
| 認証と暗号化 | 最初は持たない | 信頼できる LAN と有線での利用から始める。足すときは、自己署名の証明書をピン留めする |
| ライセンス | Apache-2.0 | 商用のロボットへ組み込める。特許条項があり、`.msg` を取り込む `common_interfaces` と同じである |

認証に TLS の事前共有鍵を使わないのは、Apple の実装では TLS 1.2 でしか使えないためである。

### Swift 側の CDR と型の生成

iOS アプリは、CDR（XCDR v1、リトルエンディアン）の符号化を自前の小さな実装で持つ。
メッセージの型、スキーマの本文、チャンネルの表は、`contract/` から生成する。
生成したコードはリポジトリへ入れ、再生成しても差分が出ないことをテストで確かめる。

符号化の正しさは、Python の `rosbags` が作ったバイト列との一致で確かめる。
`rosbags` は rosbag2 の読み書きに広く使われている実装で、これを基準にする。
必要な符号化は、基本型、文字列、固定長と可変長の配列、入れ子の型に限られ、実装は数百行に収まる。

### 採らなかった案

| 案 | 採らなかった理由 |
| --- | --- |
| protobuf と Foxglove の標準スキーマ | IMU、地磁気、気圧、電池の型が無い。protobuf の MCAP は rosbag2 で再生できず、foxglove_bridge が受ける符号化にも含まれない |
| 独自の JSON | 可視化ツールが直接つながらず、クライアントの常駐が要る。画像と深度には別のフレーム形式を定義することになる |
| iPhone を ROS 2 のノードにする | クライアントに ROS 2 が必須になる。この形は Conduit が既に提供している |
| foxglove-sdk の C ライブラリを組み込む | Swift の binding が無い。サーバーの最小実装は小さく、Network.framework だけで書いた公式の前例（`foxglove-ios-bridge`）がある |
| WebRTC | 深度を損失のある映像へ載せることになる。Record3D の WiFi 配信がこの形で、USB より品質が下がると公式に書いている |
| swift-ros2 の CDR コーデック | パッケージが Apple 向けに Zenoh、CycloneDDS、rcl のビルド済みバイナリを宣言し、構成を環境変数で切り替える。コーデックだけが要るアプリには、依存の解決とビルドの構成が重い |

### Foxglove の仕様書にある注意書きの扱い

Foxglove WebSocket プロトコルの仕様書は、冒頭で自前サーバーの実装を勧めていない。
プロトコルが今後も変わるから、というのが理由である。
それでも互換にするのは、次の 3 点による。

- 主なクライアントは pocketsensor 自身の Python SDK である。Foxglove 側が変わっても、失うのは可視化ツールとの互換に限られる
- 公式 SDK の現行の実装は、v1 の binary のレイアウトをそのまま使っている。新しい `protocol/v2` はリモートアクセス専用で、LAN 内の直接接続とは別物である
- Lichtblick はオープンソースで、v1 のサブプロトコル名を提示し続けている

## 対象にするセンサー

| 段階 | 対象 |
| --- | --- |
| 最初 | ARKit の姿勢、RGB、深度、confidence、フレームごとの内部パラメータ、追跡の状態 |
| 最初 | IMU の生値と融合値、地磁気（生値と較正済み）、気圧と相対高度 |
| 最初 | GNSS の測位解、方位、電池、熱の状態 |
| 次 | 参照画像の anchor（TF として出す）、マイク |
| 次 | iPhone への出力（音声、トーチ、触覚、画面の表示）。services で受ける |
| 後 | AVFoundation の LiDAR 深度カメラ（姿勢は出ない）、前面の TrueDepth、UWB、端末内での MCAP 記録 |
| 対象外 | GNSS の生の観測量と、環境光の lux。どちらも公開 API に無い |

カメラのモードは排他である。
ARKit の動作中は、AVFoundation のカメラのセッションを同時に動かせない。
公式のドキュメントに明記は無く、Apple の技術サポートがフォーラムでそう答えている。
トピック名は、モードが変わっても同じものを使う。
AVFoundation のモードでは、姿勢のチャンネルを広告しない。

## アプリの画面

画面は、配信している値を人が確かめるための計器盤である。
操作は、端末の名前の変更、原点の作り直し、プレビューの切り替え、設定の変更に留める。

表示する値は、クライアントへ送っている値と同じものにする。
姿勢は REP-103 へ変換したあとの位置と向き、IMU は比力（m/s²）と角速度（rad/s）で出す。
ARKit や Core Motion の生の値を出すと、画面で見た軸の向きとクライアントが受け取る軸の向きが食い違い、取り付けの確認に使えない。

IMU の区画の角度は、`imu/data` の向き（`<name>_imu_link` の向き）を `<name>_link` の向きへ直してから度にする。
`<name>_imu_link` の x は、カメラ群を上にした横置きで真上を向く。
この姿勢は roll、pitch、yaw の特異点に当たり、`<name>_imu_link` のままでは角度が定まらない。
`<name>_link` へ直すと、Pose の区画の角度とそのまま見比べられる。
roll と pitch は 2 つの区画で一致し、yaw は基準の向きの分だけ違う。

| 区画 | 表示する内容 |
| --- | --- |
| Link | 待ち受けの状態とポート、接続数、アドレス、端末の名前 |
| Pose | 追跡の状態、`<name>_odom` から見た位置（m）、向き（roll、pitch、yaw の度と四元数）、`origin_epoch` |
| Streams | チャンネルごとの送った実績（Hz）と、背圧で捨てた数 |
| IMU | 比力、角速度、IMU の向きから求めた `<name>_link` の roll、pitch、yaw（度）、地磁気（µT）と較正の状態 |
| Environment | 気圧（hPa）、GNSS の測位と精度か許可の状態、電池、熱の状態、時計の自己点検 |
| RGB-D | タップで切り替えるプレビュー。RGB と深度のヒートマップを同じ大きさで横に並べ、中心の距離を添える |

数値の更新は毎秒 5 回にする。
センサーの周期（100 Hz）で描き直すと、描画の負荷が配信を邪魔する。

プレビューの RGB と深度は、同じフレームから作った 1 組を表示する。
画素は、画面の向きに合わせて回して正立させる。
回すのは画面の表示だけで、配信する画素の並びは変えない（[frames-and-units.md](frames-and-units.md) の「画像の向き」）。
プレビューの画像は、ARKit の queue とは別の queue で作る。
前の 1 組を作り終えていなければ、そのフレームは飛ばす。
更新は毎秒 30 回までにする。
こうして、プレビューの処理がフレームの取得と配信を待たせないようにする。

### センサーを動かす条件

センサーは、必要とされているあいだだけ動かす。
必要とするのは、そのセンサー群のチャンネルを購読している接続と、アプリの画面の 2 つである。
どちらかが必要としていれば動かし、どちらも必要としなくなったら止める。

| センサー群 | 購読による条件 | 画面による条件 |
| --- | --- | --- |
| ARKit（姿勢、RGB） | `odom`、`/tf`、`tracking`、RGB、深度のどれかが購読されている | 設定で Pose の表示が ON、または RGB-D のプレビューを表示している |
| LiDAR の深度（ARKit の sceneDepth） | 深度、confidence、`depth/camera_info` のどれかが購読されている | RGB-D のプレビューを表示している |
| IMU と地磁気 | `imu/data`、`imu/data_raw`、`imu/mag` のどれかが購読されている | 設定で IMU の表示が ON |
| 気圧と電池 | `pressure` か `battery` が購読されている | 設定で Environment の表示が ON |
| GNSS | `gnss/fix` か `gnss/time_reference` が購読されている | 設定で GNSS の表示が ON |

止めるのは、必要とされなくなってから 10 秒たった時点にする。
クライアントの接続し直しや、表示ツールのパネルの切り替えのたびに、センサーが止まって動き直すのを避けるためである。

ARKit を止めているあいだは、自己位置を追えない。
ARKit を動かし直すときは world の原点を作り直し、`origin_epoch` を 1 増やす。
台車へ載せる使い方では、クライアントが姿勢を購読し続けるので、ARKit は止まらない。
深度の要否だけが変わったときは、原点を保ったまま ARKit の設定を入れ替える。

画面の区画は、表示が OFF でも、データが流れていればその値を出す。
購読によってセンサーが動いているなら、値を出しても負荷は増えないためである。
どのセンサー群が動いているかは、`/diagnostics` の `pocketsensor/sensors` でも知らせる。

### 設定の画面

設定は、見出しの歯車のボタンから開く。
内容は端末へ保存し、次の起動へ引き継ぐ。

| 設定 | 既定 | 内容 |
| --- | --- | --- |
| Pose の表示 | ON | 購読が無くても ARKit を動かし、Pose の区画へ値を出す |
| IMU の表示 | ON | 購読が無くても IMU と地磁気を取得し、IMU の区画へ値を出す |
| Environment の表示 | ON | 購読が無くても気圧と電池を取得し、Environment の区画へ値を出す |
| GNSS の表示 | OFF | 購読が無くても測位する。最初に ON にしたとき、位置情報の許可を求める |

台車へ載せて画面を見ない使い方では、すべてを OFF にする。
そうすると、クライアントが購読したセンサーだけが動く。
GNSS の既定が OFF なのは、消費電力が大きく、位置情報の許可のダイアログが出るためである。
RGB-D のプレビューは設定へ入れず、これまでどおり画面のタップで切り替える。
起動した時点では、プレビューを表示しない。

## 実装の順序

1. 契約（`.msg`、チャンネルの表）と、CDR のゴールデンバイト列の単体テスト
2. 姿勢、diagnostics、時計合わせだけを Foxglove WebSocket で流す最小の一式。Lichtblick と Python SDK の両方で受ける
3. 参照画像の anchor を TF として足す。ここで xlerobot-book の実験が pocketsensor へ切り替えられる
4. 深度、`camera_info`、RGB（JPEG）、フレームの組
5. IMU、地磁気、気圧、GNSS、電池
6. MCAP への記録と、記録ファイルの再生
7. USB（usbmux）と Bonjour での発見
8. ROS 2 の中継、H.264、深度の可逆圧縮

## xlerobot-book との分担

pocketsensor の前身は、書籍「XLeRobot をつくる」の実験用リポジトリ xlerobot-book にある PhoneSense である。
xlerobot-book は、pocketsensor を利用する側として次のものを持ち続ける。

- 台車への取り付けの向きと、マウントの設計
- ARKit の姿勢が台車の上で使えるかを測るゲートの手順と結果、走行の要約
- URDF の `phone_link` と、Nav2 への橋渡し（深度から costmap への入力）

### 前身から引き継ぐもの

| 前身（xlerobot-book の `navigate/`） | pocketsensor での扱い |
| --- | --- |
| `ios/` のアプリ（ARKit のセッション、WebSocket のサーバー、熱に応じたレート、背圧、画面） | 引き継ぐ。wire の型は新しい契約で置き換える |
| `phonesense/` の `clock.py` | 引き継ぎ、ドリフトの推定を足す |
| `phonesense/` の `frames.py` | 引き継ぎ、座標変換の基準実装にする |
| `phonesense/` の `contract.py` と `stream.py` | 置き換える。JSON の wire と、その受信部は無くなる |
| 疑似 LaserScan と、その設定（行の範囲、取り付けの下向き角） | 引き継がない |
| 走行の要約と、Record3D 経由の記録 | xlerobot-book に残す |

xlerobot-book の実験は、iPhone の側に pocketsensor を使う。
前身のアプリと wire の契約は xlerobot-book から除いてあり、ゲートの記録と解析（`navigate/gate`）は pocketsensor の SDK の上で動く。

## 実機で確かめること

時計、座標軸と符号、参照画像の anchor、usbmux 経由での到達は、実機の測定で確かめた。
記録は [measurements.md](measurements.md) にあり、座標と単位に関わる結果は [frames-and-units.md](frames-and-units.md) の表にもまとめてある。
残っているのは次の項目である。

| 項目 | 見込み | 確かめ方 |
| --- | --- | --- |
| Lichtblick での H.264 の表示 | `foxglove_msgs/CompressedVideo` の要件（Annex B、B フレームなし）を満たせば映ると見ている | VideoToolbox の出力を Annex B へ変換して送る |
| foxglove_bridge への publish | clientPublish が CDR を受ける。実機での確認例は見つかっていない | Docker の ROS 2 で foxglove_bridge を立て、iPhone から接続する |

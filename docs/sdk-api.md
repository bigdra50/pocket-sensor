# 受け手 SDK の API

受け手の SDK は、iPhone を ZED や RealSense と同じ作法で開けるようにする。
最初の実装は Python で、ROS 2 には依存しない。
この文書は、API の形と、その形にした理由を定める。
倣った SDK の事実は [research/sdk-conventions-depth-cameras.md](research/sdk-conventions-depth-cameras.md) と [research/sdk-conventions-lidars.md](research/sdk-conventions-lidars.md) にある。

実装が始まったら、API の正本は型と docstring へ移る。
この文書は、設計の意図を説明する役割を持つ。

## 全体の形

```python
import pocketsensor as ps

devices = ps.discover(timeout=2.0)                  # Bonjour と usbmux で探す

config = ps.Config(
    streams=[ps.Color(rate=15), ps.Depth(rate=15), ps.Pose(), ps.Imu(rate=100)],
    frame_policy=ps.FramePolicy.REQUIRE_ALL,
)

with ps.open("ws://iphone.local:8765", config) as dev:   # "usb:" も "run.mcap" も同じ
    print(dev.info.model, dev.info.app_version)
    k = dev.calibration.intrinsics(ps.Stream.DEPTH)

    with dev.record("run.mcap"):
        while True:
            frames = dev.wait_for_frames(timeout=1.0)
            depth_m = frames.depth.meters               # float32、無効は NaN
            pose = frames.pose                          # REP-103、odom から link
            t = frames.timestamp(ps.TimeDomain.HOST)
            for sample in dev.imu.read_all():           # 前回の呼び出し以降の全サンプル
                ...
```

## 開き方

| 関数 | 内容 |
| --- | --- |
| `ps.discover(timeout)` | 見つかった端末の一覧を返す。Bonjour の広告と、USB でつながった端末の両方を探す |
| `ps.open(source, config)` | 端末か記録ファイルを開き、`Device` を返す |

`source` には次の 3 つの形を渡せる。

| 形 | 例 | 内容 |
| --- | --- | --- |
| WebSocket の URL | `ws://iphone.local:8765` | WiFi と Ethernet。IP アドレスの直接指定も同じ形 |
| USB | `usb:`、`usb:<UDID>`、`usb:<UDID>:<port>` | usbmux で転送する。UDID を省くと最初の 1 台を開く。ポートを省くと 8765 を使う |
| ファイルのパス | `run.mcap` | 記録を再生する |

実機、USB、記録ファイルのどれを開いても、返る `Device` の API は同じである。
ZED の `InitParameters.input`、Ouster の `open_source`、Orbbec の `PlaybackDevice` が同じ形を採っている。
Azure Kinect は再生を別系統の API にしており、ライブ用と再生用でコードが二重になる。

記録ファイルで意味を持たない操作（レートの変更、原点の作り直し）は、例外を返す。
ZED が、SVO の再生でカメラの設定を変える操作を受け付けないのと同じ扱いである。

## 設定

開くときに決める設定と、開いたあとで変えられる設定を分ける。
ZED が `InitParameters` と `RuntimeParameters` を分けているのと同じ考え方である。

| 種類 | 渡し方 | 項目 |
| --- | --- | --- |
| 開くときに決める | `ps.Config` | 使うストリーム、フレームの組の扱い、受信バッファの長さ |
| 開いたあとで変えられる | `dev.set_rate(stream, hz)` など | 各ストリームのレート、JPEG の品質、画像の幅 |

`Config.streams` に挙げたストリームだけを購読する。
端末は、購読されていないセンサーを取得しないので、使わないストリームを挙げないことが発熱を抑える手段になる。

開いたあとの変更は、端末の parameters を書き換える。
設定は端末に 1 つなので、ほかの接続にも反映される。

## フレームの組

`dev.wait_for_frames(timeout)` は、同じ ARFrame から作られたデータの組（`FrameSet`）を返す。
端末は同じフレームのデータへ同じ時刻を付けるので、組は時刻の一致で作る。
RealSense の `frameset` や Azure Kinect の `k4a_capture_t` に当たる。

| `FrameSet` の項目 | 内容 |
| --- | --- |
| `color` | 画像（`numpy` の配列）と、そのフレームの内部パラメータ |
| `depth` | `raw`（`uint16`、mm、無効は 0）と `meters`（`float32`、無効は NaN） |
| `confidence` | 画素ごとの 0、1、2 |
| `pose` | `<name>_odom` から見た `<name>_link` の位置と姿勢 |
| `tracking` | 追跡の状態、理由、`origin_epoch` |
| `timestamp(domain)` | 計測時刻。種類は下の「時刻」を参照 |
| `latency` | 計測から到着までの遅延の推定値 |

組が欠けたときの扱いは `FramePolicy` で選ぶ。
Orbbec の `OBFrameAggregateOutputMode` に倣った。

| 値 | 内容 |
| --- | --- |
| `REQUIRE_ALL` | `Config.streams` に挙げたカメラ系のストリームが揃った組だけを返す |
| `ANY` | 欠けていても返す。欠けた項目は `None` になる |

`wait_for_frames` を呼んでいないあいだに届いた組は、最新の 1 つを残して捨てる。
遅延を小さく保つための扱いで、ZED と RealSense も同じである。
捨てた数は `dev.stats` で読める。

## 高いレートのセンサー

IMU のように画像より速いセンサーは、フレームの組へ入れない。
`dev.imu.read_all()` が、前回の呼び出し以降に届いた全サンプルを返す。
画像のループを 1 本回すだけで、IMU を取りこぼさずに読める。

ZED は当初、全サンプルを得るために 800 Hz でポーリングする別スレッドを利用者へ求めていた。
5.1 で `getSensorsDataBatch` を足し、直前の `grab()` 以降のサンプルをまとめて返す形に直している。
pocketsensor は最初からこの形にする。

バッファは 2 秒分を上限とし、あふれたら古いものから捨てて `dev.stats` に数える。
GNSS、気圧、電池のような低いレートのデータは、`dev.gnss.latest()` のように最新の 1 件を読む。

すべてのメッセージを順に受け取りたい利用者には、`dev.messages(topics)` を用意する。
トピック名、計測時刻、復号済みのメッセージを順に返す、低い層の API である。

## 時刻

1 つのデータは 3 種類の時刻を持つ。
定義は [time.md](time.md) にある。

| `TimeDomain` | 内容 |
| --- | --- |
| `DEVICE` | 端末が付けた計測時刻 |
| `HOST_ARRIVAL` | 受け手が受信した時点の、受け手の単調時計 |
| `HOST` | 計測時刻を、推定したずれで受け手の単調時計へ写した値 |

時計合わせの状態は `dev.clock` で読める。
ずれの推定値、往復の遅延、ドリフト、使ったサンプルの数を返す。
時計合わせが済むまで、`HOST` を求める呼び出しは例外を返す。

## 較正

| API | 内容 |
| --- | --- |
| `dev.calibration.intrinsics(stream)` | 解像度、fx、fy、cx、cy、歪みのモデル名、係数 |
| `dev.calibration.extrinsics(source, target)` | `source` から `target` への 4×4 の変換。並進は m |
| `dev.calibration.raw` | 端末が送った `device_info` の JSON そのまま |

外部パラメータを `extrinsics(source, target)` の形で引くのは、RealSense、Azure Kinect、Orbbec に共通する作法である。
歪みは、モデル名と固定長の係数で表す。
値が分からない項目（IMU のノイズ密度、カメラと IMU のあいだの並進）は、0 ではなく NaN を返す。
ZED の `SensorParameters` が同じ扱いをしている。

内部パラメータはフレームごとに変わりうるので、`frames.color.intrinsics` がそのフレームの値を持つ。
`dev.calibration.intrinsics` は、最後に受け取った値を返す。

深度から 3 次元の点を求める関数 `ps.deproject(depth, intrinsics)` を、純粋関数として用意する。
内部パラメータの縮尺、画素の原点、軸の向きは取り違えやすいので、利用者ごとの再実装を避けるためである。

## 記録と再生

`dev.record(path)` は、受信したバイト列をそのまま MCAP へ書く。
復号と再符号化をしないので、記録の負荷は小さい。
`device_info` と時計合わせのサンプルも、同じファイルへ入る。

記録ファイルは `ps.open(path)` で開く。
再生の速さは 2 通りから選ぶ。

| 指定 | 内容 |
| --- | --- |
| `realtime=True` | 記録したときと同じ時間の進み方で返す。処理が遅いと、ライブと同じように組が捨てられる |
| `realtime=False` | 呼び出しのたびに次の組を返す。1 つも捨てない |

RealSense の `playback.set_real_time` と同じ区別で、前者は動作の再現に、後者は解析に使う。

## エラー

| 例外 | 起きる場面 |
| --- | --- |
| `TimeoutError` | `wait_for_frames` が時間内に組を得られなかった |
| `ps.ConnectionFailed` | `open` で端末へつなげなかった。待ち受けが無い、USB に端末が無い、ハンドシェイクの失敗を含む |
| `ps.ConnectionLost` | つながっていた端末との接続が切れた。`session_id` が変わった再接続も含む |
| `ps.ProtocolError` | 端末が約束と違うメッセージを送ってきた |
| `ps.Unsupported` | 端末や記録ファイルが、求められた操作やストリームに対応していない |

対応していないストリームは、開く前に `dev.info.streams` で確かめられる。
LiDAR の無い機種では、深度と confidence が一覧に現れない。

## 並行性

受信は、SDK が持つ裏のスレッドで動かす。
公開する API は同期の呼び出しで、どのスレッドから呼んでもよい。
`asyncio` 向けの API は、同期の API が固まってから足す。

## コマンド

| コマンド | 内容 |
| --- | --- |
| `pocketsensor discover` | 端末を探して一覧を出す |
| `pocketsensor info <source>` | 端末の情報、ストリーム、較正、時計合わせの状態を出す |
| `pocketsensor record <source> -o run.mcap` | MCAP へ記録する |
| `pocketsensor echo <source> <topic>` | 1 つのトピックを復号して表示する |

## 依存

| 用途 | パッケージ | 扱い |
| --- | --- | --- |
| WebSocket | `websockets` | 必須 |
| 配列 | `numpy` | 必須 |
| CDR の復号 | `rosbags`（Apache-2.0、純 Python） | 必須。ROS 2 のインストールは要らない |
| MCAP | `mcap` | 必須 |
| JPEG の復号 | `simplejpeg`、`opencv-python`、`Pillow` のうち、入っているもの | 追加の依存（`pocketsensor[jpeg]` は `Pillow` を入れる） |
| Bonjour | `zeroconf`（LGPL-2.1-or-later） | 追加の依存（`pocketsensor[discovery]`） |
| H.264 の復号 | `av` | 追加の依存（`pocketsensor[video]`） |

usbmux のクライアントは、SDK の中に最小の実装を持つ。
広く使われている `pymobiledevice3` は GPL-3.0 なので、依存にしない。

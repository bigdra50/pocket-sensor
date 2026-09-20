# Python SDK の API

Python SDK は、iPhone を RGB-D カメラの SDK と同じ作法で開く。
ROS 2 には依存しない。

## 使用例

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
| `ps.discover(timeout)` | 見つかった端末の一覧を返す。Bonjour と、USB でつながった端末の両方を探す |
| `ps.open(source, config)` | 端末か記録ファイルを開き、`Device` を返す |

`source` には次の 3 つの形を渡せる。

| 形 | 例 | 内容 |
| --- | --- | --- |
| WebSocket の URL | `ws://iphone.local:8765` | WiFi と Ethernet。IP アドレスの直接指定も同じ形 |
| USB | `usb:`、`usb:<UDID>`、`usb:<UDID>:<port>` | usbmux で転送する。UDID を省くと最初の 1 台を開く。ポートを省くと 8765 を使う |
| ファイルのパス | `run.mcap` | 記録を再生する |

実機、USB、記録ファイルのどれを開いても、返る `Device` の API は同じである。
記録ファイルで意味を持たない操作（レートの変更、原点のリセット）は、例外を返す。

## 設定

| 種類 | 渡し方 | 項目 |
| --- | --- | --- |
| 開くときに決める | `ps.Config` | 使うストリーム、フレームセットの扱い、受信バッファの長さ |
| 開いたあとで変えられる | `dev.set_rate(stream, hz)` など | 各ストリームのレート、JPEG の品質、画像の幅 |

`Config.streams` に挙げたストリームだけを購読する。
端末は購読されていないセンサーを止めるので、使わないストリームを挙げなければ発熱が減る。

開いたあとの変更は、端末の parameters を書き換える。
設定は端末に 1 つなので、ほかの接続にも反映される。

## フレームセット

`dev.wait_for_frames(timeout)` は、同じ ARFrame から作られたデータをまとめたフレームセット（`FrameSet`）を返す。

| `FrameSet` の項目 | 内容 |
| --- | --- |
| `color` | 画像（`numpy` の配列）と、そのフレームの内部パラメータ |
| `depth` | `raw`（`uint16`、mm、無効は 0）と `meters`（`float32`、無効は NaN） |
| `confidence` | 画素ごとの 0、1、2 |
| `pose` | `<name>_odom` から見た `<name>_link` の位置と姿勢 |
| `tracking` | トラッキングの状態、理由、`origin_epoch` |
| `timestamp(domain)` | 計測時刻。種類は下の「時刻」を参照 |
| `latency` | 計測から到着までの遅延の推定値 |

深度と confidence は、端末が対応していれば、PNG で可逆圧縮したチャンネルから受け取る。
`ps.Depth(compressed=False)` を渡すと、無圧縮のチャンネルを使う。

フレームセットが欠けたときの扱いは `FramePolicy` で選ぶ。

| 値 | 内容 |
| --- | --- |
| `REQUIRE_ALL` | `Config.streams` に挙げたカメラ系のストリームが揃ったフレームセットだけを返す |
| `ANY` | 欠けていても返す。欠けた項目は `None` になる |

`wait_for_frames` を呼んでいないあいだに届いたフレームセットは、最新の 1 つを残して破棄する。
破棄した数は `dev.stats` で読める。

## 高いレートのセンサー

IMU のように画像より速いセンサーは、フレームセットへ入れない。
`dev.imu.read_all()` が、前回の呼び出し以降に届いた全サンプルを返す。
バッファは 2 秒分を上限とし、あふれたら古いものから破棄して `dev.stats` に数える。

GNSS、気圧、電池のような低いレートのデータは、`dev.gnss.latest()` のように最新の 1 件を読む。
`dev.messages(topics)` は、トピック名、計測時刻、デコード済みのメッセージを、届いた順にすべて返す。

## 参照画像の anchor

`Config.streams` へ `ps.Anchors()` を足すと、端末がトラッキングしている参照画像の位置と姿勢を読める。
`dev.anchors.latest()` は、画像の名前から `AnchorSample` への辞書を返す。

| `AnchorSample` の項目 | 内容 |
| --- | --- |
| `name` | 参照画像の名前 |
| `t_device_ns` | 検出したフレームの計測時刻 |
| `position`、`orientation_xyzw` | `<name>_odom` から見た anchor の位置（m）と姿勢 |
| `frame_id`、`child_frame_id` | `<name>_odom` と `<name>_anchor_<画像の名前>` |

端末は、トラッキングしているあいだだけ 0.5 秒おきに anchor を送る。
`latest()` は、1.5 秒より前に届いたものを返さない。
この長さは `latest(max_age_s=...)` で変えられ、`None` を渡すと古いものも返す。

`t_device_ns` は、どれかの `FrameSet` の計測時刻と必ず一致する。
同じ時刻の `frames.pose` と anchor を `ps.relative_pose` へ渡すと、端末から見た anchor の位置と姿勢が求まる。

## 時刻

1 つのデータは 3 種類の時刻を持つ。
定義は [time.md](time.md) にある。

| `TimeDomain` | 内容 |
| --- | --- |
| `DEVICE` | 端末が付けた計測時刻 |
| `HOST_ARRIVAL` | クライアントが受信した時点の、クライアントのモノトニッククロック |
| `HOST` | 計測時刻を、推定したオフセットでクライアントのモノトニッククロックへ換算した値 |

時刻同期の状態は `dev.clock` で読める。
オフセットの推定値、RTT、ドリフト、使ったサンプルの数を返す。
時刻同期が済むまで、`HOST` を求める呼び出しは例外を返す。

オフセットの推定値は 2 つある。
`offset_ns` はクライアントのモノトニッククロックに対する値で、`HOST` への変換に使う。
`wall_offset_ns` は、端末のシステム時刻からクライアントのシステム時刻を引いた値である。

## キャリブレーション

| API | 内容 |
| --- | --- |
| `dev.calibration.intrinsics(stream)` | 解像度、fx、fy、cx、cy、歪みのモデル名、係数 |
| `dev.calibration.extrinsics(source, target)` | `source` から `target` への 4×4 の変換。並進は m |
| `dev.calibration.raw` | 端末が送った `device_info` の JSON そのまま |
| `ps.deproject(depth, intrinsics)` | 深度から 3 次元の点を求める |

端末が測っていない並進（カメラと IMU のあいだ）は、0 ではなく NaN で返す。

内部パラメータはフレームごとに変わりうるので、`frames.color.intrinsics` がそのフレームの値を持つ。
`dev.calibration.intrinsics` は、最後に受け取った値を返す。

## 記録と再生

`dev.record(path)` は、受信したバイト列をそのまま MCAP へ書く。
`device_info` と時刻同期のサンプルも、同じファイルへ入る。

記録ファイルは `ps.open(path)` で開く。
再生の速さは 2 通りから選ぶ。

| 指定 | 内容 |
| --- | --- |
| `realtime=True` | 記録したときと同じ時間の進み方で返す。処理が遅いと、ライブと同じようにフレームセットが破棄される |
| `realtime=False` | 呼び出しのたびに次のフレームセットを返す。1 つも破棄しない |

## エラー

| 例外 | 起きる場面 |
| --- | --- |
| `TimeoutError` | `wait_for_frames` が時間内にフレームセットを得られなかった |
| `ps.ConnectionFailed` | `open` で端末へつなげなかった。待ち受けが無い、USB に端末が無い、ハンドシェイクの失敗を含む |
| `ps.ConnectionLost` | つながっていた端末との接続が切れた。`session_id` が変わった再接続も含む |
| `ps.ProtocolError` | 端末がプロトコルに反するメッセージを送ってきた |
| `ps.Unsupported` | 端末や記録ファイルが、求められた操作やストリームに対応していない |

対応していないストリームは、開く前に `dev.info.streams` で確かめられる。
LiDAR の無い機種では、深度と confidence が一覧に現れない。

## スレッド

受信は、SDK が持つ裏のスレッドで動かす。
公開する API は同期の呼び出しで、どのスレッドから呼んでもよい。

## コマンド

| コマンド | 内容 |
| --- | --- |
| `pocketsensor discover` | 端末を探して一覧を出す |
| `pocketsensor info <source>` | 端末の情報、ストリーム、キャリブレーション、時刻同期の状態を出す |
| `pocketsensor record <source> -o run.mcap` | MCAP へ記録する |
| `pocketsensor echo <source> <topic>` | 1 つのトピックをデコードして表示する |
| `pocketsensor check-axes <source>` | 端末を決まった向きへ動かしてもらい、座標軸と符号が規約どおりかを判定する |
| `pocketsensor check-anchor <source>` | 参照画像を映してもらい、anchor の frame の軸の向きと、端末からの距離を判定する |

`check-anchor` は、参照画像の置き方を `--pose` で受け取る。
`vertical` は壁や画面、`horizontal` は机や床である。

## 依存パッケージ

| 用途 | パッケージ | 扱い |
| --- | --- | --- |
| WebSocket | `websockets` | 必須 |
| 配列 | `numpy` | 必須 |
| CDR のデコード | `rosbags`（Apache-2.0、純 Python） | 必須。ROS 2 のインストールは要らない |
| MCAP | `mcap` | 必須 |
| JPEG と PNG のデコード | `Pillow` | 必須。`simplejpeg` か `opencv-python` が入っていれば、JPEG のデコードにはそちらを先に使う |
| Bonjour | `zeroconf`（LGPL-2.1-or-later） | 追加の依存（`pocketsensor[discovery]`） |
| H.264 のデコード | `av` | 追加の依存（`pocketsensor[video]`） |

usbmux のクライアントは、SDK の中に最小の実装を持つ。

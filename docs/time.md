# 時刻と時計合わせ

pocketsensor は、センサーが計測した時点の時刻をメッセージに付ける。
クライアントは、iPhone の時計と自分の時計のずれを推定し、計測時刻を自分の時計へ写す。

## iPhone 側の時計

iPhone のアプリは、`mach_absolute_time` の系統の時計を基準にする。
端末の起動からの単調時計で、ARKit と Core Motion のサンプルの時刻もこの時計で届く。

アプリは、セッションの開始時に時計を自己点検する。
サンプルが届いた時点の `CACurrentMediaTime()` と、そのサンプルの時刻との差を測る。
差が 0 秒から 0.5 秒の範囲に収まらなければ、`/diagnostics` の `pocketsensor/clock` で警告する。

## wire に載せる時刻

wire に載せる時刻は、単調時計の値に、セッションの開始時に 1 回だけ求めた差を足したものである。

```
    anchor = 壁時計(開始時) - 単調時計(開始時)      セッションの開始時に 1 回だけ求める
    t_wire = t_sensor + anchor                     ナノ秒、UNIX 時刻の形
```

`anchor` は、セッションのあいだ変えない。
途中で NTP が iPhone の壁時計を動かしても、`t_wire` は跳ばずに単調時計の速さで進む。

`t_wire` は、Foxglove の Message Data の時刻と、メッセージの `header.stamp` の両方へ同じ値を入れる。
`anchor` の値と求めた時点は、`device_info` の `clock` に入れる。

### センサーごとの時刻

| データ | 元にする時刻 | 補足 |
| --- | --- | --- |
| 姿勢、RGB、深度、confidence、`camera_info`、`tracking` | `ARFrame.timestamp` | 同じフレームから作るものは同じ値になる |
| 参照画像の anchor | anchor の更新を含む `ARFrame` の `timestamp` | |
| IMU、地磁気、気圧 | `CMLogItem.timestamp` | |
| GNSS | `CLLocation.timestamp` を単調時計へ換算した値 | 換算の式は下にある |
| 電池、`/diagnostics` | 値を読んだ時点の `CACurrentMediaTime()` | 計測時刻を持たないデータである |

`CLLocation.timestamp` は壁時計なので、次の式で単調時計へ換算する。

```
    t_sensor = 単調時計(今) - (壁時計(今) - CLLocation.timestamp)
```

測位の壁時計の時刻そのものは、`gnss/time_reference` の `time_ref` で別に流す。

## 時計合わせ

NTP と同じ往復 4 時刻の方式を、services の 1 往復で表す。

```
    クライアント                        iPhone
      | -- ClockSync(t1) ---------> |   t2: 要求を受け取った時刻
      | <-------- (t1, t2, t3) ---- |   t3: 応答を送る直前の時刻
      t4: 応答を受け取った時刻

    rtt    = (t4 - t1) - (t3 - t2)
    offset = ((t2 - t1) + (t3 - t4)) / 2        iPhone の時計 - クライアントの時計
```

`t1` と `t4` はクライアントの時計、`t2` と `t3` は `t_wire` と同じ時計で測る。
往路と復路の遅延が等しければ `offset` は正確で、等しくなければ差の半分が誤差になる。
`rtt` が小さいサンプルほど、誤差の上限が小さい。

### クライアントの推定

1. 接続の直後は 1 秒ごと、安定したら 5 秒ごとに `ClockSync` を呼ぶ
2. 直近 8 サンプルのうち、`rtt` が最短のものの `offset` を現在の推定値にする。`rtt` が同じなら新しいほうを採る
3. 採用したサンプルの系列へ直線を当てはめ、時計の進み方の差（ドリフト）を求める。当てはめには、外れ値に強い Theil-Sen 推定を使う

計測時刻をクライアントの時計へ写すときは、最後に採用したサンプルを基準に、ドリフトの分だけずれを進める。

```
    (t_ref, offset_ref) = 最後に採用したサンプルの (t1 と t4 の中点, offset)
    t_host = t_wire - (offset_ref + drift * ((t_wire - offset_ref) - t_ref))
```

採用したサンプルが 3 つに満たないあいだは、`drift` を 0 とする。

ずれの推定値は、クライアントの単調時計向けと壁時計向けの 2 つを持つ。
SDK の利用者は単調時計を使い、ROS 2 の中継は壁時計（ROS の時刻）を使う。

## クライアントが扱う時刻の種類

Python SDK は、1 つのデータに対して 3 種類の時刻を返す。

| 種類 | 内容 | 使いどころ |
| --- | --- | --- |
| `DEVICE` | `t_wire` そのまま | 同じ端末のデータどうしを合わせる。記録ファイルの時刻 |
| `HOST_ARRIVAL` | クライアントがメッセージを受け取った時点の、クライアントの時計 | 転送の遅延と揺れの診断 |
| `HOST` | `t_wire` から推定した `offset` を引き、クライアントの時計へ写した値 | ロボットのほかのセンサーと合わせる。遅延の補償 |

時計合わせのサンプルがまだ無いあいだ、`HOST` は値を返さない。
`HOST_ARRIVAL` から `HOST` を引いた値が、計測から到着までの遅延になる。
SDK はこの値をフレームごとに返す。

ROS 2 の中継は、`header.stamp` を `HOST`（壁時計）へ書き換えてから publish する。

## 記録と再生

MCAP の `log_time` には `t_wire` を入れる。
時計合わせのサンプル（`t1` から `t4`）も MCAP の Metadata へ残すので、再生のときに `HOST` を求め直せる。

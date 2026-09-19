# 時刻と時計合わせ

pocketsensor は、センサーが計測した時点の時刻をメッセージに付ける。
受け手は、iPhone の時計と自分の時計のずれを推定し、計測時刻を自分の時計へ写す。
この文書は、iPhone 側の時計、wire に載せる時刻、時計合わせの手順、受け手が扱う時刻の種類を定める。
根拠にした事実は [research/apple-apis.md](research/apple-apis.md) と [research/sdk-conventions-depth-cameras.md](research/sdk-conventions-depth-cameras.md) にある。

## 計測時刻を使う理由

アプリがデータを受け取った時点の時刻を付けると、次の問題が起きる。

- 同じ ARFrame から作った深度と姿勢に、別々の時刻が付く
- 処理の待ち時間がそのまま時刻の揺れになり、IMU と画像を後から合わせられなくなる
- 受け手が、計測から到着までの遅延を見積もれなくなる

ARKit の姿勢は、計測から受け手へ届くまでに 100 ms を超える遅延を持つことがある。
制御へ使う受け手は、この遅延を補償するために計測時刻を必要とする。

## iPhone 側の時計

iPhone のアプリは、`mach_absolute_time` の系統の時計を基準にする。
端末の起動からの単調時計で、スリープのあいだは止まる。

| API | 時計 | 根拠 |
| --- | --- | --- |
| `CACurrentMediaTime()` | `mach_absolute_time` を秒へ直した値 | Apple のドキュメントに明記がある |
| AVCapture の `CMSampleBuffer` の時刻 | ホスト時計。iOS では `mach_absolute_time` に基づく | Apple の QA1643 |
| `ProcessInfo.systemUptime` | 再起動から、起きていた時間 | Apple のドキュメント |
| `ARFrame.timestamp` | 文書化されていない | Apple の技術サポートが、フォーラムで `mach_absolute_time` に基づくと答えている |
| `CMLogItem.timestamp` | 端末の起動からの秒。スリープを含むかは書かれていない | 同上 |
| `CLLocation.timestamp` | 壁時計（`Date`） | Apple のドキュメント |

`ARFrame.timestamp` と `CMLogItem.timestamp` の時計は、Apple が文書化していない。
そこでアプリは、セッションの開始時に自己診断をする。
フレームや IMU のサンプルが届いた時点の `CACurrentMediaTime()` と、そのサンプルの時刻との差を測る。
差が 0 秒から 0.5 秒の範囲に収まらなければ、時計が違うものとして `/diagnostics` で警告する。

スリープのあいだ時計が止まることは、運用では問題にならない。
アプリは前面で動き、画面のロックを抑止しているので、配信中に端末はスリープしない。
アプリが背景へ回るとセッションは終わり、前面へ戻ると新しいセッションが始まる（[protocol.md](protocol.md) の「セッション」）。
端末がスリープした場合も、復帰後は新しいセッションになる。

スリープ中も進む `mach_continuous_time` を基準にする案は採らなかった。
上の表のとおり、センサーの時刻は `mach_absolute_time` の系統で届くと見ている。
別の時計へ写すと、サンプルごとに換算の誤差が入る。

## wire に載せる時刻

wire に載せる時刻は、単調時計の値に、セッションの開始時に 1 回だけ求めた差を足したものである。

```
    anchor = 壁時計(開始時) - 単調時計(開始時)      セッションの開始時に 1 回だけ求める
    t_wire = t_sensor + anchor                     ナノ秒、UNIX 時刻の形
```

`anchor` は、セッションのあいだ変えない。
途中で NTP が iPhone の壁時計を動かしても、`t_wire` は跳ばずに単調時計の速さで進む。

壁時計へ固定するのは、可視化ツールと記録のためである。
Lichtblick は時刻を日時として表示し、MCAP は複数のファイルを時刻で並べる。
起動からの秒のままでは、どちらも 1970 年の時刻として扱われる。

`t_wire` は、Foxglove の Message Data の時刻と、メッセージの `header.stamp` の両方へ同じ値を入れる。
`anchor` の値と求めた時点は、`device_info` の `clock` に入れる。

### センサーごとの時刻

| データ | 元にする時刻 | 補足 |
| --- | --- | --- |
| 姿勢、RGB、深度、confidence、`camera_info`、`tracking` | `ARFrame.timestamp` | 同じフレームから作るものは同じ値になる |
| 参照画像の anchor | anchor の更新を含む `ARFrame` の `timestamp` | anchor の更新を受けた時点の時刻は使わない |
| IMU、地磁気 | `CMLogItem.timestamp` | |
| 気圧 | `CMLogItem.timestamp` | |
| GNSS | `CLLocation.timestamp` を単調時計へ換算した値 | 換算の式は下にある |
| 電池、`/diagnostics` | 値を読んだ時点の `CACurrentMediaTime()` | 計測時刻を持たないデータである |

`CLLocation.timestamp` は壁時計なので、次の式で単調時計へ換算する。

```
    t_sensor = 単調時計(今) - (壁時計(今) - CLLocation.timestamp)
```

測位の壁時計の時刻そのものは、`gnss/time_reference` の `time_ref` で別に流す。

## 時計合わせ

Foxglove WebSocket プロトコルに、時計合わせの仕組みは無い。
pocketsensor は、NTP と同じ往復 4 時刻の方式を services の 1 往復で表す。

```
    受け手                        iPhone
      | -- ClockSync(t1) ---------> |   t2: 要求を受け取った時刻
      | <-------- (t1, t2, t3) ---- |   t3: 応答を送る直前の時刻
      t4: 応答を受け取った時刻

    rtt    = (t4 - t1) - (t3 - t2)
    offset = ((t2 - t1) + (t3 - t4)) / 2        iPhone の時計 - 受け手の時計
```

`t1` と `t4` は受け手の時計、`t2` と `t3` は `t_wire` と同じ時計で測る。
往路と復路の遅延が等しければ `offset` は正確で、等しくなければ差の半分が誤差になる。
`rtt` が小さいサンプルほど、誤差の上限が小さい。

### 受け手の推定

1. 接続の直後は 1 秒ごと、安定したら 5 秒ごとに `ClockSync` を呼ぶ
2. 直近 8 サンプルのうち、`rtt` が最短のものの `offset` を現在の推定値にする
3. 採用したサンプルの系列へ直線を当てはめ、時計の進み方の差（ドリフト）を求める。当てはめには Theil-Sen 推定を使う

Theil-Sen 推定は、全サンプルの組の傾きの中央値を取る方法で、外れ値に強い。
RealSense SDK が、デバイスの時計をホストの時計へ写すために同じ方法を使っている。
RealSense は USB 接続のデバイスを 100 ms の周期で測っている。
WiFi は遅延の揺れが大きい。
そこで pocketsensor は、当てはめの前に `rtt` が最短のサンプルだけを残す。

`rtt` が同じサンプルが並んだら、新しいほうを採る。

計測時刻を受け手の時計へ写すときは、最後に採用したサンプルを基準に、ドリフトの分だけずれを進める。

```
    (t_ref, offset_ref) = 最後に採用したサンプルの (t1 と t4 の中点, offset)
    t_host = t_wire - (offset_ref + drift * ((t_wire - offset_ref) - t_ref))
```

採用したサンプルが 3 つに満たないあいだは、`drift` を 0 とする。

ずれの推定値は、受け手の単調時計向けと壁時計向けの 2 つを持つ。
SDK の利用者は単調時計を使い、ROS 2 の中継は壁時計（ROS の時刻）を使うためである。

## 受け手が扱う時刻の種類

受け手の SDK は、1 つのデータに対して 3 種類の時刻を返す。
RealSense SDK と Orbbec SDK が同じ区別を持つ。

| 種類 | 内容 | 使いどころ |
| --- | --- | --- |
| `DEVICE` | `t_wire` そのまま | 同じ端末のデータどうしを合わせる。記録ファイルの時刻 |
| `HOST_ARRIVAL` | 受け手がメッセージを受け取った時点の、受け手の時計 | 転送の遅延と揺れの診断 |
| `HOST` | `t_wire` から推定した `offset` を引き、受け手の時計へ写した値 | ロボットのほかのセンサーと合わせる。遅延の補償 |

時計合わせのサンプルがまだ無いあいだ、`HOST` は値を返さない。
推定値が無いのに `HOST_ARRIVAL` で代用すると、利用者が精度の違いに気付けないためである。

`HOST_ARRIVAL` から `HOST` を引いた値が、計測から到着までの遅延になる。
SDK はこの値をフレームごとに返す。

ROS 2 の中継は、`header.stamp` を `HOST`（壁時計）へ書き換えてから publish する。
CDR では `header.stamp` がメッセージの先頭にあるので、全体を復号せずに書き換えられる。

## 記録と再生

MCAP の `log_time` には `t_wire` を入れる。
時計合わせのサンプル（`t1` から `t4`）も MCAP の Metadata へ残す。
再生のときに `HOST` を求め直せるようにするためである。

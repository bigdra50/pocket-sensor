# foxglove-client-check

pocketsensor のサーバーを、表示ツールの側の実装で確かめる検査である。
接続から復号までを、Lichtblick が内部で使っているパッケージだけで行う。
Foxglove も同じパッケージを使っている。
Python SDK のテストは SDK 自身のクライアントを使うので、表示ツールから見て正しいかどうかは分からない。

| 役割 | パッケージ |
| --- | --- |
| WebSocket のクライアント | `@foxglove/ws-protocol` |
| `ros2msg` のスキーマの解析 | `@foxglove/rosmsg` |
| CDR の復号と符号化 | `@foxglove/rosmsg2-serialization` |

## 確かめること

- `serverInfo` が `cdr` と、`parameters`、`parametersSubscribe`、`services` を広告する
- 広告された全チャンネルのスキーマが解析でき、届いたメッセージが復号できる
- `header.stamp` が、メッセージに付いた時刻と一致する
- `clock_sync` が `t1` をそのまま返し、`t2` が `t3` より後にならない
- `getParameters` と `setParameters` が動く。変えた `color.rate` は、終わる前に元の値へ戻す

## 実行

```
mise run test:foxglove-client                # 擬似デバイスを起動して確かめる
node check.mjs ws://iphone.local:8765 8      # 動いている端末を 8 秒ぶん確かめる
```

実機の GNSS は、屋内では届かないことがある。
GNSS の 2 つのチャンネルは、届かなくても問題として数えず、注記として表示する。

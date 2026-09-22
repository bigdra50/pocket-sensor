**English** | [日本語](README.md)

# foxglove-client-check

A check that exercises the pocketsensor server through the same packages a visualizer uses.
Connection through decoding uses only the packages that Lichtblick and Foxglove use internally.

| Role | Package |
| --- | --- |
| WebSocket client | `@foxglove/ws-protocol` |
| `ros2msg` schema parsing | `@foxglove/rosmsg` |
| CDR decode and encode | `@foxglove/rosmsg2-serialization` |

## What it checks

- `serverInfo` advertises `cdr`, plus `parameters`, `parametersSubscribe`, and `services`
- The schema of every advertised channel parses, and every message that arrives decodes
- `header.stamp` matches the time attached to the message
- `clock_sync` echoes `t1`, and `t2` is not later than `t3`
- `getParameters` and `setParameters` work. `color.rate` is restored to its previous value before the check finishes

## Running it

```
mise run test:foxglove-client                # start a fake device and check it
node check.mjs ws://iphone.local:8765 8      # check a running device for 8 seconds
```

GNSS from a physical device may not arrive indoors.
The two GNSS channels are not counted as failures when they do not arrive. They are reported as a note.

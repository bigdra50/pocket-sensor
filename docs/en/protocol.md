**English** | [日本語](../protocol.md)

# Protocol

The iPhone app runs as a server compatible with Foxglove WebSocket protocol v1.
It streams standard ROS 2 messages encoded as CDR. Settings are parameters. Clock synchronization and commands are services.
The source of truth for channels and types is `contract/`.

## Connection

| Item | Contents |
| --- | --- |
| Transport | WebSocket over TCP. The default port is 8765 (the same as foxglove_bridge) |
| Direction | The iPhone listens, and the client connects. Several connections are accepted at once |
| Subprotocol | Both `foxglove.sdk.v1` and `foxglove.websocket.v1` are accepted. If both are offered, the former is chosen |
| Wi-Fi and Ethernet | Advertised as the Bonjour service type `_pocketsensor._tcp`. Connecting to an IP address directly also works |
| USB | usbmux on the host forwards a connection to the same port onto the device |

The Bonjour advertisement needs local-network permission.
Without that permission, a direct IP address and USB still connect.

### Sent immediately after connect

1. `serverInfo`. `name` is `pocketsensor`. `capabilities` are the three values `parameters`, `parametersSubscribe`, and `services`
2. `advertise`. Every channel that can be streamed at that moment
3. `advertiseServices`

`sessionId` in `serverInfo` is a UUID created for each session.
On reconnect, the client uses this value to tell whether the same session is still running.
`supportedEncodings` is `cdr`.

### Session

A session is one continuous stretch during which the app is in the foreground and keeps streaming.
The app closes the listener and drops connections when it moves to the background.
When it returns to the foreground, it opens the listener again and starts a new session.

When the session changes, `sessionId` and the time base (`anchor` in [time.md](time.md)) are new, and the ARKit world origin is reset.
The client treats the new data as discontinuous with the previous session.

## Channels

A channel's `encoding` is `cdr`, and its `schemaEncoding` is `ros2msg`.
`schema` holds the `.msg` text, including the definitions of the types it depends on, concatenated.

Topic names and frame names are prefixed with the device name, `<name>`.
The initial value is `pocketsensor`, and it can be changed on the app screen.
Frame definitions are in [frames-and-units.md](frames-and-units.md).

| Topic | Type | frame_id | Default rate |
| --- | --- | --- | --- |
| `/<name>/odom` | `nav_msgs/msg/Odometry` | `<name>_odom`, child is `<name>_link` | 30 Hz |
| `/<name>/tracking` | `pocketsensor_msgs/msg/TrackingStatus` | `<name>_link` | Same as pose |
| `/tf` | `tf2_msgs/msg/TFMessage` | From `<name>_odom` to `<name>_link`. Reference-image anchors are carried here too | Same as pose |
| `/tf_static` | `tf2_msgs/msg/TFMessage` | From `<name>_link` to each sensor | Just after subscribe, and on change |
| `/<name>/color/image/compressed` | `sensor_msgs/msg/CompressedImage` | `<name>_color_optical_frame` | 15 Hz |
| `/<name>/color/camera_info` | `sensor_msgs/msg/CameraInfo` | `<name>_color_optical_frame` | Same as the image |
| `/<name>/depth/image` | `sensor_msgs/msg/Image` (`16UC1`) | `<name>_color_optical_frame` | 15 Hz |
| `/<name>/depth/confidence` | `sensor_msgs/msg/Image` (`mono8`) | `<name>_color_optical_frame` | Same as depth |
| `/<name>/depth/camera_info` | `sensor_msgs/msg/CameraInfo` | `<name>_color_optical_frame` | Same as depth |
| `/<name>/depth/image/compressedDepth` | `sensor_msgs/msg/CompressedImage` (PNG) | `<name>_color_optical_frame` | Same as depth |
| `/<name>/depth/confidence/compressed` | `sensor_msgs/msg/CompressedImage` (PNG) | `<name>_color_optical_frame` | Same as depth |
| `/<name>/imu/data_raw` | `sensor_msgs/msg/Imu` | `<name>_imu_link` | 100 Hz |
| `/<name>/imu/data` | `sensor_msgs/msg/Imu` | `<name>_imu_link` | 100 Hz |
| `/<name>/imu/mag` | `sensor_msgs/msg/MagneticField` | `<name>_imu_link` | 50 Hz |
| `/<name>/pressure` | `sensor_msgs/msg/FluidPressure` | `<name>_link` | Whatever interval the device produces |
| `/<name>/gnss/fix` | `sensor_msgs/msg/NavSatFix` | `<name>_link` | Whatever interval the device produces |
| `/<name>/gnss/time_reference` | `sensor_msgs/msg/TimeReference` | unused | Same as the fix |
| `/<name>/battery` | `sensor_msgs/msg/BatteryState` | unused | 1 Hz |
| `/<name>/device_info` | `std_msgs/msg/String` (JSON) | unused | Just after subscribe, and on change |
| `/diagnostics` | `diagnostic_msgs/msg/DiagnosticArray` | unused | 1 Hz |

Pose, RGB, depth, confidence, and `camera_info` built from the same ARFrame carry the same time.
The client builds a frame set by matching those times.

Depth is aligned to the RGB camera, so its frame_id is the same as RGB.
The unit is millimeters, and an invalid pixel is 0.
`depth/camera_info` carries intrinsics matched to the depth resolution.
A `confidence` pixel follows ARKit's `ARConfidenceLevel`: 0 (low), 1 (medium), 2 (high).

### Lossless depth compression

Depth and confidence are published two ways: an uncompressed channel, and a channel losslessly compressed as PNG.
The contents are the same. The client chooses by subscribing.
The device encodes only the one that is subscribed.

| Channel | `format` | `data` |
| --- | --- | --- |
| `depth/image/compressedDepth` | `16UC1; compressedDepth png` | A 12-byte header followed by a 16-bit grayscale PNG |
| `depth/confidence/compressed` | `mono8; png compressed ` (one trailing space) | An 8-bit grayscale PNG |

The topic name, the `format` string, and the 12-byte header match `compressedDepth` and `compressed` from ROS `image_transport`.
On the ROS 2 side, `image_transport` `republish` turns them back into `sensor_msgs/Image`.
The header is an `int32` 0 (`INV_DEPTH`) and two `float32` 0 values, all little endian.
For `16UC1` depth, a decoder only has to skip this header.

Uncompressed depth and confidence are 2.2 MB per second at 15 Hz.
The Python SDK subscribes to the compressed form when the device advertises it.
To see depth in color in a visualizer, subscribe to the uncompressed `depth/image`.

### Tracking state

ARKit's tracking state is streamed as `TrackingStatus`, at the same time as the pose.

| Field | Type | Contents |
| --- | --- | --- |
| `header` | `std_msgs/Header` | The same time as the pose |
| `state` | `uint8` | 0 is not available, 1 is limited, 2 is normal |
| `reason` | `uint8` | 0 is none, 1 is initializing, 2 is excessive motion, 3 is insufficient features, 4 is relocalizing |
| `origin_epoch` | `uint32` | A count that increases every time the ARKit world origin is reset |

When `origin_epoch` changes, the client treats the pose as discontinuous with the previous one.
The origin is reset when `reset_origin` is called, and when ARKit that had stopped starts again.
While `state` is 0, `odom` and `/tf` are not streamed.

`pose.covariance` of `odom` is 0 (unknown).
ARKit does not report velocity, so `twist` is 0, and the first element of `twist.covariance` is -1.

### Reference-image anchors

The ARKit world origin changes with every session.
A client that uses an image placed in the room as a reference can rebuild the same origin across sessions.

While ARKit is tracking a reference image built into the app, the transform from `<name>_odom` to `<name>_anchor_<image name>` is carried on `/tf`.
Register the reference image in the Xcode AR Resource Group `Anchors`, together with its physical size when printed.
The image name becomes part of the frame name, so use only lowercase letters, digits, and underscores.

The app ships with two marker images (`marker_a` and `marker_b`).
Print both at 15 cm wide.
The black triangle at the top left marks the top and the left of the image.
`tools/gen_marker.py` creates the images. Open `tools/show_marker.html` to display one at physical size on a screen.

| Item | Contents |
| --- | --- |
| Rate | At most once every 0.5 seconds, per image |
| When tracking is lost | Publishing stops |
| Time | The time of the ARFrame that detected it. The same value as the pose from that frame |
| Batching | Only on a cycle that sends a pose, and in the same `TFMessage` as that pose's transform |

An anchor time always matches some `odom` time.
The client pairs it with the pose at that same time to get the anchor's position as seen from the device (the transform from `<name>_link` to the anchor).
The axes of the anchor frame are in [frames-and-units.md](frames-and-units.md).

### Channels sent just after subscribe

`/tf_static` and `/<name>/device_info` send their latest sample immediately after a subscription is accepted.
This corresponds to transient local in ROS 2.

`device_info` is one JSON document of the metadata needed to interpret the streams.

| Key | Contents |
| --- | --- |
| `schema_version` | The version of this JSON |
| `session_id` | The per-session UUID. The same value as `sessionId` in `serverInfo` |
| `name` | The device name. Prefixed onto topic names and frame names |
| `model`, `os_version`, `app_version` | The model identifier, the iOS version, and the app version |
| `mode` | The camera mode. Only `arkit` |
| `streams` | Every channel being advertised. The key is the key in the channel table (`contract/channels.toml`) |
| `clock` | The kind of clock, and its offset from system time. See [time.md](time.md) |
| `frames` | The list of frame names, and the fixed transforms |

The nested contents are as follows.

| Key | Contents |
| --- | --- |
| `streams.<key>` | `topic` and `schema`. An image channel also has `width`, `height`, and `encoding`. A channel with a fixed rate also has `rate` (Hz) |
| `clock` | `kind` (the kind of clock), `anchor_ns`, `anchored_at_wall_ns`, and `self_check` |
| `frames` | The frame names `odom`, `link`, `color_optical`, and `imu_link`, and the array of fixed transforms `static_transforms` |
| `frames.static_transforms[]` | `parent`, `child`, `translation`, `rotation_xyzw`, and `calibrated` |

A transform whose `calibrated` is false has a correct rotation, but its translation was not measured (0 is filled in).
The transform to the IMU is one of these.

### Contents of diagnostics

`/diagnostics` streams the following statuses, once a second, gathered into one `DiagnosticArray`.
This is where a client can tell why data is not arriving.
`hardware_id` is the device name.

| `name` | `level` | `values` |
| --- | --- | --- |
| `pocketsensor/tracking` | Normal is OK, limited is WARN, and not available is ERROR. While ARKit is stopped the level is OK and `message` is `stopped` | `state` and `reason` (the same numbers as `TrackingStatus`) |
| `pocketsensor/thermal` | nominal and fair are OK, serious is WARN, critical is ERROR | `level` |
| `pocketsensor/streams` | WARN if even one sample was dropped | `clients`, `rate.<key>` (the Hz actually sent), `drops.<key>` (the count dropped by backpressure), `encode_skips.<key>` (the count skipped because encoding did not finish in time) |
| `pocketsensor/clock` | ERROR if the self-check is suspicious | `self_check` (see [time.md](time.md)) |
| `pocketsensor/mag` | high and medium are OK, low and unknown are WARN, uncalibrated is ERROR | `calibration` |
| `pocketsensor/gnss` | authorized is OK, not_determined is WARN, denied and restricted are ERROR | `authorization` |
| `pocketsensor/sensors` | Always OK | `arkit`, `depth`, `motion`, `altimeter`, `battery`, and `gnss`. The value is `on` when that sensor group is running, and `off` when it is stopped |

`<key>` is the key in the channel table (`contract/channels.toml`).
`message` holds a summary of that status (the same string as the main value in `values`).

Location permission is requested on the device screen the first time a fix is needed.
Until it is granted, `gnss/fix` does not arrive, so the client learns the reason from `authorization` of `pocketsensor/gnss`.

## Subscription and starting sensors

The device runs only the sensors required by the channels that are subscribed.
The client subscribes only to the channels it uses.
If depth is not subscribed, LiDAR does not run. If none of pose, RGB, and depth is subscribed, ARKit does not run either.

Subscribing to a channel whose sensor is stopped takes time before the first message.
ARKit takes about 1 second to the first frame, and about 4 seconds until tracking is normal.
After the last subscription goes away, the sensor keeps running for 10 seconds.

When ARKit starts again, the world origin is reset and `origin_epoch` increases.
A client that needs pose continuity leaves `odom` or `/tf` subscribed.

## parameters

Settings are read and written as Foxglove parameters.
There is one set of settings on the device. A change from any connection applies to the whole device.
A change is announced to connections that called `subscribeParameterUpdates`.

| Name | Type | Initial value | Contents |
| --- | --- | --- | --- |
| `pose.rate` | number | 30 | Upper bound on the rate of pose, `tracking`, and `/tf` (Hz) |
| `color.rate` | number | 15 | Upper bound on the RGB rate (Hz) |
| `color.width` | number | 960 | Width of the image that is sent, in pixels. Height follows the aspect ratio |
| `color.jpeg_quality` | number | 0.8 | JPEG quality (0 to 1) |
| `depth.rate` | number | 15 | Upper bound on the rate of depth and confidence (Hz) |
| `imu.rate` | number | 100 | IMU rate (Hz). A value above the device limit is clamped to the limit |
| `imu.reference_frame` | string | `arbitrary` | The orientation reference of `imu/data`. `arbitrary` or `true_north` |
| `device.name` | string | `pocketsensor` | Read only. Change it on the app screen |

A rate is an upper bound.
ARKit keeps running at 60 fps, and frames are thinned out at publish time.

1. Take the highest upper bound among pose, RGB, and depth as the base rate. Looking at the ARFrame time, pick a frame once the base interval has elapsed since the previously chosen frame, and assign it a sequence number
2. A stream whose upper bound is r sends only the frames whose sequence number is divisible by N, where N is the base rate divided by r, rounded up

Even when the rates differ, a frame on the slower stream is also a frame on the faster stream, so data from the same frame still lines up.
If the device thermal state is serious, the base rate is halved. If it is critical, the base rate is divided by 6. The rate that actually results is reported in `/diagnostics`.

## services

| Name | Type | Contents |
| --- | --- | --- |
| `/<name>/clock_sync` | `pocketsensor_msgs/srv/ClockSync` | One clock-sync round trip. See [time.md](time.md) |
| `/<name>/reset_origin` | `std_srvs/srv/Trigger` | Reset the ARKit world origin and add 1 to `origin_epoch` |

The `ClockSync` request is the single field `uint64 t1` (the client clock, in nanoseconds).
The response is three fields: `uint64 t1` (the request value, echoed), `uint64 t2` (the time it was received), and `uint64 t3` (the time of the reply).
`t2` and `t3` are measured on the same clock as the channel timestamps.

A message with no fields, such as the request of `std_srvs/srv/Trigger`, has a body of one byte whose value is 0, matching the ROS 2 encoding.
The iPhone app also accepts a request that omits this one byte.

## Backpressure

What happens when sending falls behind is fixed per kind of channel, and applied per connection.

| Channel | Queue |
| --- | --- |
| Pose, `tracking`, `/tf`, RGB, depth, confidence, `camera_info` | Holds only the latest sample. If the next one arrives while one is being sent, it replaces it |
| IMU, magnetometer | A queue of up to 1 second. On overflow, the oldest samples are dropped |
| Everything else | Nothing is dropped |

Messages built from the same ARFrame are replaced together.
A message that takes time, such as JPEG encoding of RGB, joins that same group later, still carrying the same time.
If encoding does not finish before the next frame, only the RGB for that cycle is skipped.
The number dropped and the number skipped are reported per channel in `/diagnostics`.

## Recording to MCAP

A client can write the messages it receives straight into MCAP.

| MCAP element | What goes in it |
| --- | --- |
| Schema and Channel | `schemaName`, `schema`, `topic`, and `encoding` received in `advertise` |
| Message `log_time` and `publish_time` | The time in the Message Data (the measurement time) |
| Metadata | The `device_info` JSON, and the clock-sync samples |

An MCAP in this shape is the `cdr` and `ros2msg` combination, so both Lichtblick and rosbag2 can open it.

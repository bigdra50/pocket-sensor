**English** | [日本語](../sdk-api.md)

# Python SDK API

## Example

```python
import pocketsensor as ps

devices = ps.discover(timeout=2.0)                  # search with Bonjour and usbmux

config = ps.Config(
    streams=[ps.Color(rate=15), ps.Depth(rate=15), ps.Pose(), ps.Imu(rate=100)],
    frame_policy=ps.FramePolicy.REQUIRE_ALL,
)

with ps.open("ws://iphone.local:8765", config) as dev:   # "usb:" and "run.mcap" work the same way
    print(dev.info.model, dev.info.app_version)
    k = dev.calibration.intrinsics(ps.Stream.DEPTH)

    with dev.record("run.mcap"):
        while True:
            frames = dev.wait_for_frames(timeout=1.0)
            depth_m = frames.depth.meters               # float32; invalid values are NaN
            pose = frames.pose                          # REP-103, from odom to link
            t = frames.timestamp(ps.TimeDomain.HOST)
            for sample in dev.imu.read_all():           # every sample since the previous call
                ...
```

## Opening a source

| Function | Behavior |
| --- | --- |
| `ps.discover(timeout)` | Returns the devices it found. Searches both Bonjour and devices connected over USB |
| `ps.open(source, config)` | Opens a device or a recording and returns a `Device` |

Bonjour discovery needs the `discovery` extra (zeroconf).
Without it, only devices connected over USB are returned.

`source` takes one of three forms.

| Form | Example | Meaning |
| --- | --- | --- |
| WebSocket URL | `ws://iphone.local:8765` | Wi-Fi and Ethernet. An IP address uses the same form |
| USB | `usb:`, `usb:<UDID>`, `usb:<UDID>:<port>` | Forwarded through usbmux. Omit the UDID to open the first device. Omit the port to use 8765 |
| File path | `run.mcap` | Play back a recording |

A live device, USB, and a recording all return a `Device` with the same API.
An operation that has no meaning on a recording (changing a rate, resetting the origin) raises an exception.

## Configuration

| Kind | How to pass it | What it sets |
| --- | --- | --- |
| Chosen when opening | `ps.Config` | Which streams to use, how to treat a frame set, and the receive-buffer length |
| Changeable after opening | `dev.set_rate(stream, hz)` and similar | The rate of each stream, JPEG quality, and image width |

Only the streams listed in `Config.streams` are subscribed.
The device stops a sensor that nobody is subscribed to, so leaving out an unused stream reduces heat.

A change made after opening writes the device parameters.
There is one set of settings on the device, so the change is visible to other connections too.

A value passed on a stream, such as `ps.Depth(rate=5)`, also writes the device parameters.
That value is restored to what it was before opening when the `Device` closes.
If another connection changed the same setting while this one was open, it is not restored.
A value changed with `dev.set_rate` or similar stays on the device after close.

## Frame sets

`dev.wait_for_frames(timeout)` returns a frame set (`FrameSet`): the data built from one ARFrame, grouped together.

| `FrameSet` field | Contents |
| --- | --- |
| `color` | The image (a `numpy` array) and the intrinsics for that frame |
| `depth` | `raw` (`uint16`, millimeters, invalid is 0) and `meters` (`float32`, invalid is NaN) |
| `confidence` | 0, 1, or 2 per pixel |
| `pose` | Position and orientation of `<name>_link` as seen from `<name>_odom` |
| `tracking` | Tracking state, reason, and `origin_epoch` |
| `timestamp(domain)` | Measurement time. The kinds are under "Time" below |
| `latency_ns` | Estimated latency from measurement to arrival, in nanoseconds. Raises until clock sync has completed |

When the device supports it, depth and confidence are received from the channels that losslessly compress them as PNG.
Pass `ps.Depth(compressed=False)` to use the uncompressed channels.

What to do when a frame set is incomplete is chosen with `FramePolicy`.

| Value | Behavior |
| --- | --- |
| `REQUIRE_ALL` | Return only a frame set in which every camera stream listed in `Config.streams` is present |
| `ANY` | Return the frame set even when something is missing. A missing field is `None` |

Frame sets that arrive while `wait_for_frames` is not being called are dropped, keeping only the latest one.
The number dropped is available from `dev.stats`.

## High-rate sensors

A sensor faster than the images, such as the IMU, is not placed in the frame set.
`dev.imu.read_all()` returns every sample that arrived since the previous call.
The buffer holds at most 2 seconds. When it overflows, the oldest samples are dropped and counted in `dev.stats`.

Low-rate data such as GNSS, pressure, and battery is read as the single latest sample, for example `dev.gnss.latest()`.
`dev.messages(topics)` returns every message, in arrival order, as the topic name, the measurement time, and the decoded message.

## Reference-image anchors

Add `ps.Anchors()` to `Config.streams` to read the position and orientation of the reference images the device is tracking.
`dev.anchors.latest()` returns a dictionary from image name to `AnchorSample`.

| `AnchorSample` field | Contents |
| --- | --- |
| `name` | Name of the reference image |
| `t_device_ns` | Measurement time of the frame that detected it |
| `position`, `orientation_xyzw` | Position (meters) and orientation of the anchor as seen from `<name>_odom` |
| `frame_id`, `child_frame_id` | `<name>_odom` and `<name>_anchor_<image name>` |

The device sends an anchor at most once every 0.5 seconds, and only while it is tracking.
`latest()` does not return a sample that arrived more than 1.5 seconds ago.
Change that age with `latest(max_age_s=...)`. Pass `None` to return older samples too.

`t_device_ns` always matches the measurement time of some `FrameSet`.
Pass `frames.pose` and the anchor from that same time to `ps.relative_pose` to get the anchor's position and orientation as seen from the device.

## Time

One piece of data has three kinds of time.
The definitions are in [time.md](time.md).

| `TimeDomain` | Meaning |
| --- | --- |
| `DEVICE` | The measurement time the device attached |
| `HOST_ARRIVAL` | The client's monotonic clock at the moment the client received it |
| `HOST` | The measurement time converted onto the client's monotonic clock by the estimated offset |

The state of clock synchronization is available from `dev.clock`.
It returns the estimated offset, the RTT, the drift, and the number of samples used.
Until clock synchronization has completed, a call that asks for `HOST` raises.

There are two offset estimates.
`offset_ns` is relative to the client's monotonic clock, and is what the conversion to `HOST` uses.
`wall_offset_ns` is the device system time minus the client system time.

## Calibration

| API | Behavior |
| --- | --- |
| `dev.calibration.intrinsics(stream)` | Resolution, fx, fy, cx, cy, the distortion model name, and the coefficients |
| `dev.calibration.extrinsics(source, target)` | The 4×4 transform from `source` to `target`. Translation is in meters |
| `dev.calibration.raw` | The `device_info` JSON the device sent, unchanged |
| `ps.deproject(depth, intrinsics)` | 3D points from a depth image |

A translation the device did not measure (between the camera and the IMU) is returned as NaN, not 0.

Intrinsics can change from frame to frame, so `frames.color.intrinsics` holds the value for that frame.
`dev.calibration.intrinsics` returns the last value received.

## Recording and playback

`dev.record(path)` writes the received bytes to MCAP as they are.
`device_info` and the clock-sync samples go into the same file.

Open a recording with `ps.open(path)`.
Playback speed is one of two choices.

| Setting | Behavior |
| --- | --- |
| `realtime=True` | Return data on the same timeline as the recording. If processing falls behind, frame sets are dropped, as they are live |
| `realtime=False` | Return the next frame set on every call. Nothing is dropped |

## Errors

| Exception | When it is raised |
| --- | --- |
| `TimeoutError` | `wait_for_frames` did not get a frame set in time |
| `ps.ConnectionFailed` | `open` could not connect to the device. Includes no listener, no device on USB, and a failed handshake |
| `ps.ConnectionLost` | The connection to a device that was connected has dropped. Includes a reconnect whose `session_id` changed |
| `ps.ProtocolError` | The device sent a message that violates the protocol |
| `ps.Unsupported` | The device or the recording does not support the requested operation or stream |

Streams that are not supported can be checked in `dev.info.streams` before you open them.
On a model without LiDAR, depth and confidence do not appear in the list.

## Threads

Receiving runs on a background thread owned by the SDK.
The public API is synchronous, and may be called from any thread.

## Commands

| Command | Behavior |
| --- | --- |
| `pocketsensor discover` | Find devices and list them |
| `pocketsensor info <source>` | Print device info, streams, calibration, and clock-sync state |
| `pocketsensor record <source> -o run.mcap` | Record to MCAP |
| `pocketsensor echo <source> <topic>` | Decode one topic and print it |
| `pocketsensor check-axes <source>` | Ask you to move the device through known orientations, then judge whether the axes and signs match the convention |
| `pocketsensor check-anchor <source>` | Ask you to show a reference image, then judge the axis directions of the anchor frame and the distance from the device |

`check-anchor` takes the placement of the reference image in `--pose`.
`vertical` is a wall or a screen. `horizontal` is a desk or the floor.

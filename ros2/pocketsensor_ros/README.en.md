**English** | [日本語](README.md)

# pocketsensor_ros

A relay node that publishes an iPhone stream onto ROS 2 topics.
It has been checked on ROS 2 Jazzy.

## Build

In a ROS 2 workspace, pass the two packages with `--paths`.
Install the Python SDK (`python/`) into the Python that ROS 2 uses before building.

```
pip install ./python
colcon build --paths ros2/pocketsensor_msgs ros2/pocketsensor_ros
source install/setup.bash
```

## Run

```
ros2 launch pocketsensor_ros relay.launch.py source:=ws://iphone.local:8765
```

To connect over USB, pass `source:=usb:`.

| Parameter | Type | Default | Meaning |
| --- | --- | --- | --- |
| `source` | string | `ws://iphone.local:8765` | Where to connect. `ws://<host>:<port>` or `usb:` |
| `rewrite_stamp` | bool | true | Rewrite `header.stamp` to this machine's system time |
| `streams` | string array | empty | Streams to publish. Empty publishes every channel the device advertises |
| `publish_tf` | bool | true | When false, the device pose is not published on `/tf`, and `/tf_static` is not published either. Reference-image anchors are still published (see the URDF section below) |
| `reconnect_period` | float (seconds) | 2.0 | How often to reconnect when the connection fails or drops |
| `depth_transport` | string | `compressed` | Which form to receive depth and confidence in. `compressed` (PNG), `raw` (uncompressed), or `both` |

`streams` accepts `color`, `depth`, `pose`, `imu`, `imu_raw`, `mag`, `pressure`, `gnss`, and `battery`.
Even when the list is narrowed, `/tf_static`, `device_info`, and `/diagnostics` are still published.

### Receiving depth

If `depth_transport` is left unset, the relay subscribes only to the PNG form and publishes it on `<topic>/compressedDepth` and `<topic>/compressed`.
A node that needs `sensor_msgs/Image` inserts `image_transport` `republish` on the robot side.

```
ros2 run image_transport republish compressedDepth raw --ros-args \
  -r in/compressedDepth:=/pocketsensor/depth/image/compressedDepth -r out:=/pocketsensor/depth/image
```

### Time

The `header.stamp` the device attaches is a value on the device clock.
When `rewrite_stamp` is true, the relay converts that value to this machine's system time using the result of clock sync (`clock_sync`), then publishes.
Messages that arrive before clock sync has completed are dropped.
Left on the device clock, tf2 and `message_filters` cannot pair them with messages from other nodes.

### Reconnecting

The app on the device listens only while it is in the foreground.
The relay reconnects every `reconnect_period`, and repeats clock sync for each session.
The relay may be started before the device.

### QoS

| Topic | QoS |
| --- | --- |
| Images, depth, IMU | sensor data (best effort, depth 5) |
| `/tf_static`, `device_info` | reliable, transient local, depth 1 |
| `/tf` | reliable, depth 100 |
| Everything else | reliable, depth 10 |

## URDF

The `pocketsensor_device` macro in `urdf/pocketsensor.urdf.xacro` adds the device frames under the link it is mounted on.
Pass `name` and `parent`. Pass the mount position and orientation as `xyz` and `rpy` (the default is 0).

```
<xacro:include filename="$(find pocketsensor_ros)/urdf/pocketsensor.urdf.xacro"/>
<xacro:pocketsensor_device name="pocketsensor" parent="base_link" xyz="0 0 0.3"/>
```

The macro creates three links: `<name>_link`, `<name>_color_optical_frame`, and `<name>_imu_link`.

When you use this macro, launch the relay with `publish_tf:=false`.
The relay's `/tf` publishes the transform from `<name>_odom` to `<name>_link`, so if the URDF also parents `<name>_link`, that frame has two parents.
Take the device pose from `/<name>/odom` (`nav_msgs/Odometry`).

How a reference-image anchor is published depends on `publish_tf`.

| `publish_tf` | Anchor transform published on `/tf` |
| --- | --- |
| true | From `<name>_odom` to `<name>_anchor_<image name>`. The value the device sent, unchanged |
| false | From `<name>_link` to `<name>_anchor_<image name>`. Rewritten, using the device pose at the same time, into the transform as seen from the device |

## Tests

```
mise run test:ros2                               # check against a fake device, inside a ROS 2 container
SOURCE=ws://192.168.1.20:8765 mise run test:ros2 # check against a physical device
```

Docker is required.
The image is selected with the environment variable `POCKETSENSOR_ROS_IMAGE`. If it is unset, `ros:jazzy-ros-base` is used.

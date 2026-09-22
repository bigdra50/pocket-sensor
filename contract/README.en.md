**English** | [日本語](README.md)

# contract

Machine-readable definitions of the messages pocketsensor publishes.
The intent is explained in [docs/en/protocol.md](../docs/en/protocol.md).
When the explanation and the definitions disagree, the definitions in this directory win.

| Path | Contents |
| --- | --- |
| `msg/` | Message and service definitions (`.msg`, `.srv`) |
| `channels.toml` | The channel table |
| `parameters.toml` | The parameters table |
| `services.toml` | The services table |
| `vectors/` | Test vectors shared by Swift and Python |

## Generated code

Swift types and schema text, and the tables Python reads, are generated from here.
The generated files are committed. Regenerate them when a definition changes.

```bash
mise run gen          # regenerate the outputs
mise run gen:check    # check that the outputs match the definitions
mise run vectors      # regenerate the test vectors
```

The test vectors are produced by the Python reference implementation, and the Swift tests read the same files.
CDR bytes are compared against the output of `rosbags`.

## Where the vendored definitions come from

Everything in `msg/` other than `pocketsensor_msgs` is copied, unchanged, from the ROS 2 Jazzy branch.

| Package | Source | Commit | License |
| --- | --- | --- | --- |
| `std_msgs`, `geometry_msgs`, `nav_msgs`, `sensor_msgs`, `diagnostic_msgs`, `std_srvs` | [ros2/common_interfaces](https://github.com/ros2/common_interfaces) | `a941f14` | Apache-2.0 |
| `builtin_interfaces` | [ros2/rcl_interfaces](https://github.com/ros2/rcl_interfaces) | `7aa3caf` | Apache-2.0 |
| `tf2_msgs` | [ros2/geometry2](https://github.com/ros2/geometry2) | `f702874` | BSD-3-Clause (`msg/tf2_msgs/LICENSE`) |

Only the types used by the channels and services, and their dependencies, are vendored.

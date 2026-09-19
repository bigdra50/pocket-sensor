from __future__ import annotations

import sys
import xml.etree.ElementTree as ET
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
ROS2 = REPO / "ros2"


def test_xacro_and_package_xml_are_well_formed() -> None:
    paths = [
        ROS2 / "pocketsensor_ros" / "urdf" / "pocketsensor.urdf.xacro",
        ROS2 / "pocketsensor_msgs" / "package.xml",
        ROS2 / "pocketsensor_ros" / "package.xml",
    ]
    for path in paths:
        tree = ET.parse(path)
        assert tree.getroot() is not None
    xacro = (ROS2 / "pocketsensor_ros" / "urdf" / "pocketsensor.urdf.xacro").read_text()
    assert "pocketsensor_device" in xacro
    assert "${name}_link" in xacro
    assert "${name}_color_optical_frame" in xacro
    assert "${name}_imu_link" in xacro
    assert "${-pi/2} 0 ${-pi/2}" in xacro
    assert "0 ${-pi/2} 0" in xacro


def test_ros2_python_compiles() -> None:
    py_files = list(ROS2.rglob("*.py"))
    assert py_files
    for path in py_files:
        source = path.read_text(encoding="utf-8")
        compile(source, str(path), "exec")


def test_relay_channel_key_and_stream_tokens() -> None:
    src = ROS2 / "pocketsensor_ros"
    if str(src) not in sys.path:
        sys.path.insert(0, str(src))
    from pocketsensor_ros.relay import _channel_key, _expand_stream_tokens

    assert _channel_key("/tf") == "tf"
    assert _channel_key("/tf_static") == "tf_static"
    assert _channel_key("/pocketsensor/odom") == "odom"
    assert _channel_key("/robot1/color/image/compressed") == "color_image"
    assert _channel_key("/nope") is None
    assert _expand_stream_tokens([]) is None
    assert _expand_stream_tokens([""]) is None
    keys = _expand_stream_tokens(["color", "imu"])
    assert keys is not None
    assert "color_image" in keys
    assert "imu" in keys
    assert "odom" not in keys
    assert {"tf_static", "device_info", "diagnostics"} <= keys

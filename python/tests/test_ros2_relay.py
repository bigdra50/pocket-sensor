"""ROS 2 の無い環境で、中継ノードを擬似の rclpy と擬似デバイスで動かす。"""

from __future__ import annotations

import enum
import sys
import time
import types
from collections.abc import Callable, Iterator
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import pytest

from pocketsensor.cdr import CdrCodec
from pocketsensor.testing import FakeDevice

REPO = Path(__file__).resolve().parents[2]

# 端末の時計を壁時計から 3 秒ずらす。書き換えの有無が stamp から判別できる大きさにする。
_OFFSET_NS = 3_000_000_000
_NEAR_NS = 500_000_000


class _Reliability(enum.Enum):
    RELIABLE = 1
    BEST_EFFORT = 2


class _Durability(enum.Enum):
    VOLATILE = 1
    TRANSIENT_LOCAL = 2


class _History(enum.Enum):
    KEEP_LAST = 1


@dataclass(frozen=True)
class _QoSProfile:
    reliability: _Reliability
    durability: _Durability
    history: _History
    depth: int


_SENSOR_DATA = _QoSProfile(_Reliability.BEST_EFFORT, _Durability.VOLATILE, _History.KEEP_LAST, 5)


class _Logger:
    def __init__(self) -> None:
        self.records: list[tuple[str, str]] = []

    def info(self, message: str) -> None:
        self.records.append(("info", message))

    def warning(self, message: str) -> None:
        self.records.append(("warning", message))

    def error(self, message: str) -> None:
        self.records.append(("error", message))


@dataclass
class _Param:
    value: Any


class _Publisher:
    def __init__(self, cls: Any, topic: str, qos: Any) -> None:
        self.cls = cls
        self.topic = topic
        self.qos = qos
        self.messages: list[tuple[int, bytes]] = []

    def publish(self, data: bytes) -> None:
        self.messages.append((time.time_ns(), data))


class _Node:
    def __init__(self, **params: Any) -> None:
        self._params = params
        self.publishers: dict[str, _Publisher] = {}
        self.logger = _Logger()

    def declare_parameter(self, name: str, default: Any) -> _Param:
        return _Param(self._params.get(name, default))

    def get_logger(self) -> _Logger:
        return self.logger

    def create_publisher(self, cls: Any, topic: str, qos: Any) -> _Publisher:
        pub = _Publisher(cls, topic, qos)
        self.publishers[topic] = pub
        return pub


@pytest.fixture
def relay_module(monkeypatch: pytest.MonkeyPatch) -> Iterator[Any]:
    qos = types.ModuleType("rclpy.qos")
    qos.ReliabilityPolicy = _Reliability  # type: ignore[attr-defined]
    qos.DurabilityPolicy = _Durability  # type: ignore[attr-defined]
    qos.HistoryPolicy = _History  # type: ignore[attr-defined]
    qos.QoSProfile = _QoSProfile  # type: ignore[attr-defined]
    qos.qos_profile_sensor_data = _SENSOR_DATA  # type: ignore[attr-defined]
    rclpy = types.ModuleType("rclpy")
    rclpy.qos = qos  # type: ignore[attr-defined]
    monkeypatch.setitem(sys.modules, "rclpy", rclpy)
    monkeypatch.setitem(sys.modules, "rclpy.qos", qos)
    monkeypatch.syspath_prepend(str(REPO / "ros2" / "pocketsensor_ros"))
    from pocketsensor_ros import relay

    # メッセージの型は ROS 2 のパッケージに入っている。ここでは schema 名をそのまま型の代わりにする。
    monkeypatch.setattr(relay, "_load_msg_class", lambda schema_name: schema_name)
    yield relay


def _wait_until(pred: Callable[[], bool], timeout: float) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if pred():
            return
        time.sleep(0.02)
    raise AssertionError("deadline exceeded")


def _stamp_ns(stamp: Any) -> int:
    return int(stamp.sec) * 1_000_000_000 + int(stamp.nanosec)


def _has(node: _Node, *topics: str) -> bool:
    return all(topic in node.publishers and node.publishers[topic].messages for topic in topics)


def test_relay_rewrites_stamps_to_the_host_wall_clock(relay_module: Any, codec: CdrCodec) -> None:
    with FakeDevice(port=0, seed=0) as fake:
        fake.clock_offset_ns = _OFFSET_NS
        node = _Node(source=fake.url)
        relay = relay_module.RelayNode(node)
        try:
            _wait_until(
                lambda: _has(node, "/pocketsensor/odom", "/pocketsensor/imu/data", "/tf", "/tf_static"),
                timeout=5.0,
            )
        finally:
            relay.destroy()
    wall_ns, payload = node.publishers["/pocketsensor/odom"].messages[-1]
    odom = codec.decode("nav_msgs/msg/Odometry", payload)
    assert abs(_stamp_ns(odom.header.stamp) - wall_ns) < _NEAR_NS
    wall_ns, payload = node.publishers["/tf"].messages[-1]
    tf = codec.decode("tf2_msgs/msg/TFMessage", payload)
    assert tf.transforms
    for transform in tf.transforms:
        assert abs(_stamp_ns(transform.header.stamp) - wall_ns) < _NEAR_NS


def test_relay_passes_bytes_through_when_rewrite_is_off(relay_module: Any, codec: CdrCodec) -> None:
    with FakeDevice(port=0, seed=0) as fake:
        fake.clock_offset_ns = _OFFSET_NS
        node = _Node(source=fake.url, rewrite_stamp=False)
        relay = relay_module.RelayNode(node)
        try:
            _wait_until(lambda: _has(node, "/pocketsensor/odom"), timeout=5.0)
        finally:
            relay.destroy()
    wall_ns, payload = node.publishers["/pocketsensor/odom"].messages[-1]
    odom = codec.decode("nav_msgs/msg/Odometry", payload)
    assert _stamp_ns(odom.header.stamp) - wall_ns > _OFFSET_NS - _NEAR_NS


def test_relay_qos_follows_the_kind_of_topic(relay_module: Any) -> None:
    with FakeDevice(port=0, seed=0) as fake:
        node = _Node(source=fake.url, depth_transport="both")
        relay = relay_module.RelayNode(node)
        try:
            _wait_until(lambda: _has(node, "/tf_static", "/pocketsensor/device_info"), timeout=5.0)
        finally:
            relay.destroy()
    pubs = node.publishers
    for topic in ("/tf_static", "/pocketsensor/device_info"):
        assert pubs[topic].qos.durability is _Durability.TRANSIENT_LOCAL
        assert pubs[topic].qos.reliability is _Reliability.RELIABLE
    assert pubs["/pocketsensor/imu/data"].qos is _SENSOR_DATA
    assert pubs["/pocketsensor/color/image/compressed"].qos is _SENSOR_DATA
    assert pubs["/pocketsensor/depth/image"].qos is _SENSOR_DATA
    assert pubs["/pocketsensor/depth/image/compressedDepth"].qos is _SENSOR_DATA
    assert pubs["/pocketsensor/depth/confidence/compressed"].qos is _SENSOR_DATA
    assert pubs["/pocketsensor/odom"].qos.reliability is _Reliability.RELIABLE
    assert pubs["/pocketsensor/odom"].qos.durability is _Durability.VOLATILE
    assert pubs["/pocketsensor/imu/data"].cls == "sensor_msgs/msg/Imu"
    assert pubs["/tf"].cls == "tf2_msgs/msg/TFMessage"


_DEPTH_RAW = {"/pocketsensor/depth/image", "/pocketsensor/depth/confidence"}
_DEPTH_PNG = {"/pocketsensor/depth/image/compressedDepth", "/pocketsensor/depth/confidence/compressed"}


def _depth_topics(relay_module: Any, fake: FakeDevice, **params: Any) -> set[str]:
    node = _Node(source=fake.url, **params)
    relay = relay_module.RelayNode(node)
    try:
        _wait_until(lambda: _has(node, "/pocketsensor/depth/camera_info"), timeout=5.0)
    finally:
        relay.destroy()
    return set(node.publishers) & (_DEPTH_RAW | _DEPTH_PNG)


def test_relay_asks_the_device_for_one_depth_variant_only(relay_module: Any) -> None:
    # 両方を購読すると、端末は同じ深度を 2 通りに符号化して送る。帯域を減らすための圧縮が逆に働く。
    with FakeDevice(port=0, seed=0) as fake:
        assert _depth_topics(relay_module, fake) == _DEPTH_PNG
        assert _depth_topics(relay_module, fake, depth_transport="raw") == _DEPTH_RAW
        assert _depth_topics(relay_module, fake, depth_transport="both") == _DEPTH_RAW | _DEPTH_PNG


def test_relay_falls_back_to_raw_depth_on_a_device_without_png(relay_module: Any) -> None:
    with FakeDevice(port=0, seed=0, compressed_depth=False) as fake:
        assert _depth_topics(relay_module, fake) == _DEPTH_RAW


def test_relay_stream_filter_keeps_calibration_and_device_info(relay_module: Any) -> None:
    with FakeDevice(port=0, seed=0) as fake:
        node = _Node(source=fake.url, streams=["imu"])
        relay = relay_module.RelayNode(node)
        try:
            _wait_until(
                lambda: _has(node, "/pocketsensor/imu/data", "/tf_static", "/pocketsensor/device_info"),
                timeout=5.0,
            )
        finally:
            relay.destroy()
    assert set(node.publishers) == {
        "/pocketsensor/imu/data",
        "/tf_static",
        "/pocketsensor/device_info",
        "/diagnostics",
    }


def test_relay_without_tf_publishes_no_device_transforms(relay_module: Any) -> None:
    with FakeDevice(port=0, seed=0) as fake:
        node = _Node(source=fake.url, publish_tf=False)
        relay = relay_module.RelayNode(node)
        try:
            odom = "/pocketsensor/odom"
            _wait_until(lambda: _has(node, odom) and len(node.publishers[odom].messages) >= 10, timeout=5.0)
        finally:
            relay.destroy()
    assert "/tf_static" not in node.publishers
    # anchor が映っていなければ、/tf へは何も出さない。
    assert node.publishers["/tf"].messages == []


def test_relay_without_tf_reports_anchors_seen_from_the_device(relay_module: Any, codec: CdrCodec) -> None:
    with FakeDevice(port=0, seed=0) as fake:
        fake.anchors = {"dock": ([3.0, 0.0, 1.0], [0.0, 0.0, 0.0, 1.0])}
        node = _Node(source=fake.url, publish_tf=False)
        relay = relay_module.RelayNode(node)
        try:
            _wait_until(lambda: _has(node, "/tf"), timeout=5.0)
        finally:
            relay.destroy()
    assert "/tf_static" not in node.publishers
    for _wall_ns, payload in node.publishers["/tf"].messages:
        message = codec.decode("tf2_msgs/msg/TFMessage", payload)
        # URDF が <name>_link の親を決めているので、odom からの変換は出さない。
        assert [(t.header.frame_id, t.child_frame_id) for t in message.transforms] == [
            ("pocketsensor_link", "pocketsensor_anchor_dock")
        ]
    wall_ns, payload = node.publishers["/tf"].messages[-1]
    transform = codec.decode("tf2_msgs/msg/TFMessage", payload).transforms[0]
    assert abs(_stamp_ns(transform.header.stamp) - wall_ns) < _NEAR_NS
    # 擬似デバイスは半径 1 m の円の上にいる。anchor は中心から水平に 3 m、高さ 1 m にある。
    # 端末から見た距離は、水平に 2 m から 4 m、高さを入れて 2.2 m から 4.2 m に収まる。
    translation = transform.transform.translation
    distance = (translation.x**2 + translation.y**2 + translation.z**2) ** 0.5
    assert 2.2 <= distance <= 4.2


def test_relay_reconnects_with_a_fresh_clock_for_a_new_session(relay_module: Any, codec: CdrCodec) -> None:
    topic = "/pocketsensor/odom"
    with FakeDevice(port=0, seed=0) as first:
        first.clock_offset_ns = _OFFSET_NS
        port = int(first.url.rsplit(":", 1)[1])
        node = _Node(source=first.url, reconnect_period=0.1)
        relay = relay_module.RelayNode(node)
        _wait_until(lambda: _has(node, topic), timeout=5.0)
    try:
        before = len(node.publishers[topic].messages)
        # 新しいセッションは anchor が変わる。前の推定を持ち越すと stamp が 5 秒ずれる。
        with FakeDevice(port=port, seed=1) as second:
            second.clock_offset_ns = -2_000_000_000
            _wait_until(lambda: len(node.publishers[topic].messages) > before + 5, timeout=8.0)
    finally:
        relay.destroy()
    wall_ns, payload = node.publishers[topic].messages[-1]
    odom = codec.decode("nav_msgs/msg/Odometry", payload)
    assert abs(_stamp_ns(odom.header.stamp) - wall_ns) < _NEAR_NS


def test_relay_keeps_retrying_when_the_device_is_not_up_yet(relay_module: Any) -> None:
    with FakeDevice(port=0, seed=0) as probe:
        port = int(probe.url.rsplit(":", 1)[1])
    node = _Node(source=f"ws://127.0.0.1:{port}", reconnect_period=0.1)
    relay = relay_module.RelayNode(node)
    try:
        time.sleep(0.3)
        with FakeDevice(port=port, seed=0):
            _wait_until(lambda: _has(node, "/pocketsensor/odom"), timeout=8.0)
    finally:
        relay.destroy()
    assert any(level == "warning" for level, _message in node.logger.records)


def test_load_msg_class_resolves_the_ros_python_module(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.syspath_prepend(str(REPO / "ros2" / "pocketsensor_ros"))
    from pocketsensor_ros import relay

    class Imu:
        pass

    package = types.ModuleType("sensor_msgs")
    module = types.ModuleType("sensor_msgs.msg")
    module.Imu = Imu  # type: ignore[attr-defined]
    monkeypatch.setitem(sys.modules, "sensor_msgs", package)
    monkeypatch.setitem(sys.modules, "sensor_msgs.msg", module)
    assert relay._load_msg_class("sensor_msgs/msg/Imu") is Imu
    with pytest.raises(ValueError):
        relay._load_msg_class("pocketsensor_msgs/srv/ClockSync")

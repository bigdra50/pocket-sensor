"""pocketsensor の Foxglove ストリームを ROS 2 へ中継するノード。"""

from __future__ import annotations

import importlib
import logging
import threading
import time
from typing import Any

from pocketsensor._generated.contract_data import CHANNELS
from pocketsensor.cdr import CdrCodec
from pocketsensor.client import FoxgloveClient
from pocketsensor.clock import ClockEstimator, ClockSample
from pocketsensor.errors import ClockNotReady, ConnectionLost, PocketSensorError, ProtocolError
from pocketsensor.frames import relative_pose
from pocketsensor.protocol import ChannelInfo
from pocketsensor.stamp import rewrite_header_stamp
from pocketsensor.streams import (
    Battery,
    Color,
    Depth,
    Gnss,
    Imu,
    Mag,
    Pose,
    Pressure,
)
from pocketsensor.transport import connect

log = logging.getLogger("pocketsensor.ros.relay")

_SENSOR_SCHEMAS = frozenset(
    {
        "sensor_msgs/msg/Image",
        "sensor_msgs/msg/CompressedImage",
        "sensor_msgs/msg/Imu",
    }
)
_DEPTH_PNG_KEYS = ("depth_image_compressed", "depth_confidence_compressed")
_STREAM_KEYS: dict[str, tuple[str, ...]] = {
    "color": Color().channel_keys(),
    "depth": (*Depth().channel_keys(), *_DEPTH_PNG_KEYS),
    "pose": Pose().channel_keys(),
    "imu": Imu().channel_keys(),
    "imu_raw": Imu(raw=True).channel_keys(),
    "mag": Mag().channel_keys(),
    "pressure": Pressure().channel_keys(),
    "gnss": Gnss().channel_keys(),
    "battery": Battery().channel_keys(),
}
# キャリブレーション（tf_static）と端末の情報が無いと、絞り込んだストリームを ROS 側で使えない。
# 診断は 1 Hz で軽い。
_ALWAYS_KEYS = frozenset({"tf_static", "device_info", "diagnostics"})
# 深度と confidence は、無圧縮と PNG の 2 通りでアドバタイズされる。無圧縮の key から PNG の key への対応。
_DEPTH_PNG_KEY = dict(zip(("depth_image", "depth_confidence"), _DEPTH_PNG_KEYS, strict=True))
_DEPTH_TRANSPORTS = ("compressed", "raw", "both")
_CONNECT_TIMEOUT_S = 5.0
# 最初の 8 回は 1 秒おきに測って推定を早く落ち着かせ、以後は 5 秒おきにする。SDK の Device と同じ刻み。
_CLOCK_WARMUP_SAMPLES = 8
_CLOCK_WARMUP_PERIOD_S = 1.0
_CLOCK_PERIOD_S = 5.0


def _load_msg_class(schema_name: str) -> Any:
    parts = schema_name.split("/")
    if len(parts) != 3 or parts[1] != "msg":
        raise ValueError(f"not a ROS 2 message schema: {schema_name}")
    module = importlib.import_module(f"{parts[0]}.msg")
    return getattr(module, parts[2])


def _qos_for(topic: str, schema_name: str) -> Any:
    from rclpy.qos import (
        DurabilityPolicy,
        HistoryPolicy,
        QoSProfile,
        ReliabilityPolicy,
        qos_profile_sensor_data,
    )

    if topic == "/tf_static" or topic.endswith("/device_info"):
        return QoSProfile(
            reliability=ReliabilityPolicy.RELIABLE,
            durability=DurabilityPolicy.TRANSIENT_LOCAL,
            history=HistoryPolicy.KEEP_LAST,
            depth=1,
        )
    if schema_name in _SENSOR_SCHEMAS:
        return qos_profile_sensor_data
    depth = 100 if topic == "/tf" else 10
    return QoSProfile(
        reliability=ReliabilityPolicy.RELIABLE,
        durability=DurabilityPolicy.VOLATILE,
        history=HistoryPolicy.KEEP_LAST,
        depth=depth,
    )


def _expand_stream_tokens(tokens: list[str]) -> set[str] | None:
    """空なら全チャンネル。それ以外は契約の key の集合で、常に流す key を含む。"""
    wanted: set[str] = set()
    for raw in tokens:
        token = str(raw).strip()
        if not token:
            continue
        if token in _STREAM_KEYS:
            wanted.update(_STREAM_KEYS[token])
        else:
            wanted.add(token)
    if not wanted:
        return None
    return wanted | _ALWAYS_KEYS


def _skipped_depth_keys(transport: str, advertised: set[str]) -> set[str]:
    """深度を 1 通りだけ購読するために、購読しない key を返す。

    両方を購読すると、端末は同じ深度を 2 通りにエンコードして送る。
    compressed でも、PNG をアドバタイズしない端末では無圧縮を使う。
    """
    if transport == "both":
        return set()
    if transport == "raw":
        return set(_DEPTH_PNG_KEY.values())
    return {raw for raw, png in _DEPTH_PNG_KEY.items() if png in advertised}


def _channel_key(topic: str) -> str | None:
    for row in CHANNELS:
        key = str(row["key"])
        template = str(row["topic"])
        if "<name>" not in template:
            if topic == template:
                return key
            continue
        prefix, suffix = template.split("<name>", 1)
        if not topic.startswith(prefix) or not topic.endswith(suffix):
            continue
        end = len(topic) - len(suffix) if suffix else len(topic)
        middle = topic[len(prefix) : end]
        if middle and "/" not in middle:
            return key
    return None


def _anchors_seen_from_link(codec: CdrCodec, payload: bytes) -> bytes | None:
    """/tf の 1 メッセージから、<name>_link を親にした anchor だけの TFMessage を作る。

    anchor が載っていなければ None を返す。

    端末は、anchor を必ず同じ時刻の姿勢（先頭の変換）と同じメッセージへ載せる。
    """
    message = codec.decode("tf2_msgs/msg/TFMessage", payload)
    if len(message.transforms) < 2:
        return None
    pose = message.transforms[0]
    link = str(pose.child_frame_id)
    if not link.endswith("_link"):
        return None
    anchor_prefix = f"{link[: -len('_link')]}_anchor_"
    out: list[dict[str, Any]] = []
    for tf in message.transforms[1:]:
        if not str(tf.child_frame_id).startswith(anchor_prefix) or tf.header.frame_id != pose.header.frame_id:
            continue
        position, orientation = relative_pose(
            _xyz(pose.transform.translation),
            _xyzw(pose.transform.rotation),
            _xyz(tf.transform.translation),
            _xyzw(tf.transform.rotation),
        )
        out.append(
            {
                "header": {
                    "stamp": {"sec": int(tf.header.stamp.sec), "nanosec": int(tf.header.stamp.nanosec)},
                    "frame_id": link,
                },
                "child_frame_id": str(tf.child_frame_id),
                "transform": {
                    "translation": dict(zip("xyz", map(float, position), strict=True)),
                    "rotation": dict(zip("xyzw", map(float, orientation), strict=True)),
                },
            }
        )
    if not out:
        return None
    return codec.encode("tf2_msgs/msg/TFMessage", codec.make("tf2_msgs/msg/TFMessage", transforms=out))


def _xyz(v: Any) -> tuple[float, float, float]:
    return float(v.x), float(v.y), float(v.z)


def _xyzw(q: Any) -> tuple[float, float, float, float]:
    return float(q.x), float(q.y), float(q.z), float(q.w)


class RelayNode:
    """FoxgloveClient で受けた CDR を、そのまま ROS 2 の Publisher へ渡す。

    端末のアプリがフォアグラウンドにあるあいだだけ接続できるので、つながらないときと切れたときは
    reconnect_period ごとに再接続する。
    """

    def __init__(self, ros_node: Any) -> None:
        self._node = ros_node
        self._codec = CdrCodec.from_contract()
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._wall = ClockEstimator()
        self._pubs: dict[str, Any] = {}
        self._source = str(ros_node.declare_parameter("source", "ws://iphone.local:8765").value)
        self._rewrite = bool(ros_node.declare_parameter("rewrite_stamp", True).value)
        self._publish_tf = bool(ros_node.declare_parameter("publish_tf", True).value)
        self._reconnect_period = float(ros_node.declare_parameter("reconnect_period", 2.0).value)
        self._depth_transport = str(ros_node.declare_parameter("depth_transport", "compressed").value)
        if self._depth_transport not in _DEPTH_TRANSPORTS:
            raise ValueError(f"depth_transport must be one of {_DEPTH_TRANSPORTS}: {self._depth_transport!r}")
        # 空の配列は型が決まらず宣言できないので、空文字 1 個を「指定なし」とする。
        streams_param = ros_node.declare_parameter("streams", [""]).value
        tokens = [str(v) for v in streams_param] if streams_param is not None else []
        self._wanted_keys = _expand_stream_tokens(tokens)
        self._thread = threading.Thread(target=self._run, name="ps-ros-relay", daemon=True)
        self._thread.start()

    def destroy(self) -> None:
        self._stop.set()
        self._thread.join(timeout=_CONNECT_TIMEOUT_S + 2.0)

    def _run(self) -> None:
        announced = False
        while not self._stop.is_set():
            try:
                self._serve_one_session()
                announced = False
            except (PocketSensorError, TimeoutError, OSError) as exc:
                # 端末がフォアグラウンドに来るまで同じ失敗が続くので、続けて出さない。
                if not announced:
                    self._node.get_logger().warning(
                        f"cannot reach {self._source} ({exc}); retrying every {self._reconnect_period:g} s"
                    )
                    announced = True
            self._stop.wait(self._reconnect_period)

    def _serve_one_session(self) -> None:
        client = FoxgloveClient(connect(self._source, timeout=_CONNECT_TIMEOUT_S))
        try:
            info = client.wait_ready(timeout=_CONNECT_TIMEOUT_S)
            lost = threading.Event()
            client.on_disconnect = lost.set
            if client.closed:
                lost.set()
            for channel in client.channels.values():
                if channel.schema:
                    self._codec.register_schema(channel.schema_name, channel.schema)
            # セッションごとに端末の anchor が変わる。前の推定を持ち越すと stamp がずれる。
            with self._lock:
                self._wall = ClockEstimator()
            self._node.get_logger().info(f"connected to {self._source} session={info.session_id}")
            if self._rewrite:
                # 購読より先に 1 回合わせる。latched の /tf_static は購読の直後に 1 回しか届かないので、
                # 時計が未確定のまま受けると捨てるしかなく、そのセッションでは二度と出せない。
                self._one_clock_sync(client, self._wait_clock_service(client))
            client.on_message = self._on_message
            self._subscribe(client)
            self._keep_clock(client, lost)
            if not self._stop.is_set():
                self._node.get_logger().warning(f"connection to {self._source} was lost")
        finally:
            client.close()

    def _subscribe(self, client: FoxgloveClient) -> None:
        advertised = {key for key in map(_channel_key, client.channels) if key is not None}
        skipped = _skipped_depth_keys(self._depth_transport, advertised)
        for channel in client.channels.values():
            key = _channel_key(channel.topic)
            if key in skipped:
                continue
            if self._wanted_keys is not None and key not in self._wanted_keys:
                continue
            # publish_tf が false でも /tf は購読する。anchor を、端末から見た変換へ直して出すため。
            if not self._publish_tf and channel.topic == "/tf_static":
                continue
            if channel.topic not in self._pubs:
                try:
                    cls = _load_msg_class(channel.schema_name)
                except Exception as exc:
                    self._node.get_logger().warning(
                        f"skip {channel.topic}: cannot load {channel.schema_name} ({exc})"
                    )
                    continue
                qos = _qos_for(channel.topic, channel.schema_name)
                self._pubs[channel.topic] = self._node.create_publisher(cls, channel.topic, qos)
                self._node.get_logger().info(f"relaying {channel.topic} ({channel.schema_name})")
            client.subscribe(channel.topic)

    def _keep_clock(self, client: FoxgloveClient, lost: threading.Event) -> None:
        """切れるか止められるまで居座る。stamp を書き換えるときは、その間に時刻同期を続ける。"""
        service = self._wait_clock_service(client) if self._rewrite else None
        samples = 1
        while not self._stop.is_set() and not lost.is_set():
            period = _CLOCK_WARMUP_PERIOD_S if samples < _CLOCK_WARMUP_SAMPLES else _CLOCK_PERIOD_S
            deadline = time.monotonic() + period
            while not self._stop.is_set() and not lost.is_set() and time.monotonic() < deadline:
                lost.wait(0.1)
            if service is None or self._stop.is_set() or lost.is_set():
                continue
            try:
                self._one_clock_sync(client, service)
                samples += 1
            except ConnectionLost:
                return
            except (PocketSensorError, TimeoutError) as exc:
                log.debug("clock sync failed: %s", exc)

    def _wait_clock_service(self, client: FoxgloveClient, timeout: float = 3.0) -> str:
        # services のアドバタイズは channels のアドバタイズとは別のメッセージで届く。
        # wait_ready の直後はまだ無いことがある。
        deadline = time.monotonic() + timeout
        while True:
            for name in client.services:
                if name.endswith("/clock_sync"):
                    return name
            if time.monotonic() >= deadline or self._stop.is_set():
                raise ProtocolError("clock_sync is not advertised")
            time.sleep(0.02)

    def _one_clock_sync(self, client: FoxgloveClient, service: str, timeout: float = 1.0) -> None:
        t1 = time.time_ns()
        req = self._codec.make("pocketsensor_msgs/srv/ClockSync_Request", t1=t1)
        payload = self._codec.encode("pocketsensor_msgs/srv/ClockSync_Request", req)
        raw = client.call_service(service, payload, timeout=timeout)
        arrival = client.last_call_arrival
        t4 = arrival[1] if arrival is not None else time.time_ns()
        resp = self._codec.decode("pocketsensor_msgs/srv/ClockSync_Response", raw)
        with self._lock:
            self._wall.add(ClockSample(t1, int(resp.t2), int(resp.t3), t4))

    def _map_ns(self, t_ns: int) -> int:
        return int(self._wall.device_to_host(t_ns))

    def _on_message(
        self,
        channel: ChannelInfo,
        log_time_ns: int,
        payload: bytes,
        arrival_mono: int,
        arrival_wall: int,
    ) -> None:
        del log_time_ns, arrival_mono, arrival_wall
        pub = self._pubs.get(channel.topic)
        if pub is None:
            return
        data: bytes | None = payload
        if channel.topic == "/tf" and not self._publish_tf:
            try:
                data = _anchors_seen_from_link(self._codec, payload)
            except Exception as exc:
                self._node.get_logger().warning(f"cannot rebuild anchors from /tf: {exc}")
                return
            if data is None:
                return
        if self._rewrite:
            try:
                with self._lock:
                    data = rewrite_header_stamp(channel.schema_name, data, self._map_ns)
            except ClockNotReady:
                # 時刻同期が済むまでは捨てる。端末の時刻のまま出すと、ROS 側の時刻と混ざる。
                return
            except ProtocolError as exc:
                self._node.get_logger().warning(f"stamp rewrite failed on {channel.topic}: {exc}")
                return
        try:
            pub.publish(data)
        except Exception:
            # 終了のシグナルを受けると、rclpy は destroy() より先に context を無効にする。
            # そのあいだに届いたメッセージの publish は必ず失敗するので、不具合として記録しない。
            if not self._stop.is_set() and self._context_ok():
                log.exception("publish failed on %s", channel.topic)

    def _context_ok(self) -> bool:
        context = getattr(self._node, "context", None)
        return context is None or bool(context.ok())


def main(args: list[str] | None = None) -> None:
    import rclpy
    from rclpy.node import Node

    class _Node(Node):
        def __init__(self) -> None:
            super().__init__("pocketsensor_relay")
            self.relay = RelayNode(self)

        def destroy_node(self) -> bool:
            self.relay.destroy()
            return super().destroy_node()

    from rclpy.executors import ExternalShutdownException

    rclpy.init(args=args)
    node = _Node()
    try:
        rclpy.spin(node)
    except (KeyboardInterrupt, ExternalShutdownException):
        pass
    finally:
        node.destroy_node()
        # SIGINT と SIGTERM では、rclpy のシグナルハンドラが先に context を止めている。
        # shutdown() を重ねて呼ぶと RCLError になるので、止まっていなければ止める形にする。
        rclpy.try_shutdown()


if __name__ == "__main__":
    main()

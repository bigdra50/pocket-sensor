"""iPhone アプリの代わりになる Foxglove WS v1 サーバー。"""

from __future__ import annotations

import io
import json
import logging
import math
import socket
import struct
import threading
import time
import uuid
from collections import deque
from collections.abc import Sequence
from dataclasses import dataclass, field
from typing import Any

import numpy as np
from websockets.sync.server import Server, ServerConnection, serve

from pocketsensor._generated.contract_data import CHANNELS, PARAMETERS, SCHEMA_TEXTS, SERVICES
from pocketsensor.cdr import CdrCodec
from pocketsensor.frames import LINK_TO_COLOR_OPTICAL_RPY, LINK_TO_IMU_RPY, rpy_to_quaternion
from pocketsensor.intrinsics import Intrinsics, camera_info_matrices, scale_intrinsics
from pocketsensor.protocol import (
    SUBPROTOCOLS,
    ChannelInfo,
    SchemaInfo,
    ServiceInfo,
    build_advertise,
    build_advertise_services,
    build_message_data,
    build_parameter_values,
    build_server_info,
    build_service_call_failure,
    build_service_call_response,
)
from pocketsensor.streams import Stream, channel_topic

log = logging.getLogger("pocketsensor.testing.fake_device")

try:
    from PIL import Image
except ImportError:  # pragma: no cover
    Image = None

_PARAM_BY_NAME = {str(row["name"]): row for row in PARAMETERS}
_STAGE1_KEYS = tuple(str(row["key"]) for row in CHANNELS if int(row["stage"]) == 1)

_STREAM_KEYS: dict[Stream, tuple[str, ...]] = {
    Stream.COLOR: ("color_image", "color_camera_info"),
    Stream.DEPTH: (
        "depth_image",
        "depth_camera_info",
        "depth_confidence",
        "depth_image_compressed",
        "depth_confidence_compressed",
    ),
    Stream.CONFIDENCE: ("depth_confidence", "depth_confidence_compressed"),
    Stream.POSE: ("odom", "tf", "tracking"),
    Stream.ANCHORS: ("tf",),
    Stream.IMU: ("imu",),
    Stream.IMU_RAW: ("imu_raw",),
    Stream.MAG: ("mag",),
    Stream.PRESSURE: ("pressure",),
    Stream.GNSS: ("gnss_fix", "gnss_time_reference"),
    Stream.BATTERY: ("battery",),
}

_ALWAYS_KEYS = ("device_info", "tf_static", "diagnostics")
_COMPRESSED_DEPTH_KEYS = ("depth_image_compressed", "depth_confidence_compressed")
_COMPRESSED_DEPTH_HEADER = b"\x00" * 12
_COMPRESSED_DEPTH_FORMAT = "16UC1; compressedDepth png"
_COMPRESSED_CONFIDENCE_FORMAT = "mono8; png compressed "


def _select_subprotocol(connection: ServerConnection, proposals: list[str]) -> str | None:
    by_name = {str(p).strip(): p for p in proposals}
    for name in SUBPROTOCOLS:
        if name in by_name:
            return by_name[name]
    return None


def _stamp(t_ns: int) -> dict[str, int]:
    return {"sec": int(t_ns // 1_000_000_000), "nanosec": int(t_ns % 1_000_000_000)}


def _quat_dict(q: np.ndarray) -> dict[str, float]:
    return {"x": float(q[0]), "y": float(q[1]), "z": float(q[2]), "w": float(q[3])}


def _schema_info(schema_name: str) -> SchemaInfo:
    return SchemaInfo(
        encoding="cdr",
        schema_name=schema_name,
        schema_encoding="ros2msg",
        schema=SCHEMA_TEXTS.get(schema_name, ""),
    )


@dataclass
class _Client:
    ws: ServerConnection
    send_lock: threading.Lock = field(default_factory=threading.Lock)
    subs: dict[int, int] = field(default_factory=dict)
    param_sub: set[str] = field(default_factory=set)
    out: deque[bytes] = field(default_factory=deque)
    out_lock: threading.Lock = field(default_factory=threading.Lock)

    def out_pending(self) -> bool:
        with self.out_lock:
            return bool(self.out)


class FakeDevice:
    """契約どおりの Foxglove サーバー。seed を固定すると中身は再現する。"""

    def __init__(
        self,
        name: str = "pocketsensor",
        port: int = 0,
        streams: set[Stream] | None = None,
        seed: int = 0,
        compressed_depth: bool = True,
    ) -> None:
        self.name = name
        self._port = port
        self._streams = streams
        self._rng = np.random.default_rng(seed)
        self.clock_offset_ns = 0
        self.clock_drift_ppm = 0.0
        self.distortion_model = "plumb_bob"
        self.distortion: tuple[float, ...] = (0.0, 0.0, 0.0, 0.0, 0.0)
        self.anchors: dict[str, tuple[Sequence[float], Sequence[float]]] = {}
        self._anchor_last_ns: dict[str, int] = {}
        self._drop_members: set[str] = set()
        self._stall_until = 0.0
        self._params: dict[str, Any] = {str(row["name"]): row["default"] for row in PARAMETERS}
        self._params["device.name"] = name
        self._codec = CdrCodec.from_contract()
        self._session_id = str(uuid.uuid4())
        self._origin_epoch = 0
        self._stop = threading.Event()
        self._clients: list[_Client] = []
        self._clients_lock = threading.Lock()
        self._server: Server | None = None
        self._threads: list[threading.Thread] = []
        self._start_mono = 0
        self._start_wall = 0
        self._compressed_depth = compressed_depth
        self._keys = self._resolve_keys()
        self._channels, self._by_key, self._by_id = self._build_channels()
        self._services, self._svc_by_key = self._build_services()

    def _resolve_keys(self) -> set[str]:
        if self._streams is None:
            keys = set(_STAGE1_KEYS)
        else:
            keys = set(_ALWAYS_KEYS)
            for stream in self._streams:
                keys.update(_STREAM_KEYS.get(stream, ()))
        if not self._compressed_depth:
            keys.difference_update(_COMPRESSED_DEPTH_KEYS)
        return keys

    def _build_channels(self) -> tuple[list[ChannelInfo], dict[str, ChannelInfo], dict[int, ChannelInfo]]:
        channels: list[ChannelInfo] = []
        by_key: dict[str, ChannelInfo] = {}
        by_id: dict[int, ChannelInfo] = {}
        cid = 1
        for row in CHANNELS:
            key = str(row["key"])
            if key not in self._keys:
                continue
            schema = str(row["schema"])
            info = ChannelInfo(
                id=cid,
                topic=channel_topic(key, self.name),
                encoding="cdr",
                schema_name=schema,
                schema=SCHEMA_TEXTS.get(schema, ""),
                schema_encoding="ros2msg",
            )
            channels.append(info)
            by_key[key] = info
            by_id[cid] = info
            cid += 1
        return channels, by_key, by_id

    def _build_services(self) -> tuple[list[ServiceInfo], dict[str, ServiceInfo]]:
        services: list[ServiceInfo] = []
        by_key: dict[str, ServiceInfo] = {}
        sid = 1
        for row in SERVICES:
            if int(row["stage"]) != 1:
                continue
            type_name = str(row["type"])
            info = ServiceInfo(
                id=sid,
                name=str(row["name"]).replace("<name>", self.name),
                type=type_name,
                request=_schema_info(f"{type_name}_Request"),
                response=_schema_info(f"{type_name}_Response"),
            )
            services.append(info)
            by_key[str(row["key"])] = info
            sid += 1
        return services, by_key

    @property
    def url(self) -> str:
        return f"ws://127.0.0.1:{self._port}"

    def drop_members(self, keys: set[str]) -> None:
        self._drop_members = set(keys)

    def stall(self, seconds: float) -> None:
        self._stall_until = time.monotonic() + seconds

    def close_abruptly(self) -> None:
        with self._clients_lock:
            clients = list(self._clients)
        for client in clients:
            sock = getattr(client.ws, "socket", None)
            if sock is not None:
                try:
                    sock.close()
                except OSError:
                    pass

    @property
    def anchor_ns(self) -> int:
        return int(self._start_wall - self._start_mono)

    @property
    def expected_offset_ns(self) -> int:
        return self.anchor_ns + int(self.clock_offset_ns)

    def device_now_ns(self) -> int:
        elapsed = time.monotonic_ns() - self._start_mono
        drift = int(elapsed * self.clock_drift_ppm * 1e-6)
        t_sensor = time.monotonic_ns() + int(self.clock_offset_ns) + drift
        return t_sensor + self.anchor_ns

    def __enter__(self) -> FakeDevice:
        self._stop.clear()
        self._start_mono = time.monotonic_ns()
        self._start_wall = time.time_ns()
        self._server = serve(
            self._handler,
            "127.0.0.1",
            self._port,
            subprotocols=list(SUBPROTOCOLS),
            select_subprotocol=_select_subprotocol,
            compression=None,
            max_size=None,
            max_queue=None,
            ping_interval=None,
            ping_timeout=None,
        )
        self._port = int(self._server.socket.getsockname()[1])
        serve_thread = threading.Thread(target=self._serve, args=(self._server,), name="fake-ws", daemon=True)
        prod_thread = threading.Thread(target=self._produce, name="fake-prod", daemon=True)
        serve_thread.start()
        prod_thread.start()
        self._threads = [serve_thread, prod_thread]
        return self

    def _serve(self, server: Server) -> None:
        try:
            server.serve_forever()
        except OSError:
            # websockets は待ち受けを始めた直後に socket の名前をログへ出す。
            # その手前で __exit__ が socket を閉じると EBADF になるので、終了中に限って握りつぶす。
            if not self._stop.is_set():
                raise

    def __exit__(self, *args: object) -> None:
        self._stop.set()
        with self._clients_lock:
            clients = list(self._clients)
        for client in clients:
            try:
                client.ws.close()
            except Exception:
                pass
        if self._server is not None:
            self._server.shutdown()
        self._server = None

    def _handler(self, websocket: ServerConnection) -> None:
        sock = getattr(websocket, "socket", None)
        if sock is not None:
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        client = _Client(ws=websocket)
        with self._clients_lock:
            self._clients.append(client)
        try:
            self._send_text(
                client,
                build_server_info(
                    name="pocketsensor",
                    capabilities=("parameters", "parametersSubscribe", "services"),
                    supported_encodings=("cdr",),
                    session_id=self._session_id,
                ),
            )
            self._send_text(client, build_advertise(self._channels))
            self._send_text(client, build_advertise_services(self._services))
            while not self._stop.is_set():
                timeout = 0.001 if client.out_pending() else 0.05
                try:
                    raw = websocket.recv(timeout=timeout)
                except TimeoutError:
                    raw = None
                if raw is not None:
                    self._handle_client(client, raw)
                self._flush_out(client)
        except Exception:
            log.debug("fake client handler exited", exc_info=True)
        finally:
            with self._clients_lock:
                if client in self._clients:
                    self._clients.remove(client)

    def _send_text(self, client: _Client, text: str) -> None:
        with client.send_lock:
            client.ws.send(text)

    def _send_bin(self, client: _Client, data: bytes) -> None:
        with client.send_lock:
            client.ws.send(data)

    def _enqueue_bin(self, client: _Client, data: bytes) -> None:
        with client.out_lock:
            client.out.append(data)

    def _flush_out(self, client: _Client, limit: int = 8) -> None:
        for _ in range(limit):
            with client.out_lock:
                if not client.out:
                    return
                data = client.out.popleft()
            try:
                self._send_bin(client, data)
            except Exception:
                log.debug("flush send failed", exc_info=True)
                return

    def _handle_client(self, client: _Client, raw: str | bytes) -> None:
        if isinstance(raw, (bytes, bytearray, memoryview)):
            self._handle_binary(client, bytes(raw))
            return
        obj = json.loads(raw)
        op = obj.get("op")
        if op == "subscribe":
            for sub in obj.get("subscriptions", []):
                sub_id = int(sub["id"])
                channel_id = int(sub["channelId"])
                client.subs[sub_id] = channel_id
                channel = self._by_id.get(channel_id)
                if channel is not None:
                    self._send_latched(client, sub_id, channel)
        elif op == "unsubscribe":
            for sub_id in obj.get("subscriptionIds", []):
                client.subs.pop(int(sub_id), None)
        elif op == "getParameters":
            names = list(obj.get("parameterNames") or [])
            self._send_text(client, self._parameter_values(names, obj.get("id")))
        elif op == "setParameters":
            for item in obj.get("parameters") or []:
                self._apply_param(str(item["name"]), item.get("value"))
            names = [str(item["name"]) for item in obj.get("parameters") or []]
            self._send_text(client, self._parameter_values(names, obj.get("id")))
            self._notify_param_updates(names)
        elif op == "subscribeParameterUpdates":
            client.param_sub.update(str(n) for n in obj.get("parameterNames") or [])
        elif op == "unsubscribeParameterUpdates":
            for name in obj.get("parameterNames") or []:
                client.param_sub.discard(str(name))

    def _handle_binary(self, client: _Client, data: bytes) -> None:
        if not data or data[0] != 0x02 or len(data) < 13:
            return
        service_id, call_id, enc_len = struct.unpack_from("<III", data, 1)
        end = 13 + enc_len
        if len(data) < end:
            return
        payload = data[end:]
        svc = next((s for s in self._services if s.id == service_id), None)
        if svc is None:
            self._send_text(client, build_service_call_failure(service_id, call_id, "unknown service"))
            return
        try:
            reply = self._call_service(svc, payload)
        except Exception as exc:
            self._send_text(client, build_service_call_failure(service_id, call_id, str(exc)))
            return
        self._send_bin(client, build_service_call_response(service_id, call_id, "cdr", reply))

    def _call_service(self, svc: ServiceInfo, payload: bytes) -> bytes:
        if svc.name.endswith("/clock_sync"):
            req = self._codec.decode("pocketsensor_msgs/srv/ClockSync_Request", payload)
            t2 = self.device_now_ns()
            t3 = self.device_now_ns()
            resp = self._codec.make("pocketsensor_msgs/srv/ClockSync_Response", t1=int(req.t1), t2=t2, t3=t3)
            return self._codec.encode("pocketsensor_msgs/srv/ClockSync_Response", resp)
        if svc.name.endswith("/reset_origin"):
            self._origin_epoch += 1
            resp = self._codec.make("std_srvs/srv/Trigger_Response", success=True, message="ok")
            return self._codec.encode("std_srvs/srv/Trigger_Response", resp)
        raise ValueError(f"unhandled service {svc.name}")

    def _apply_param(self, name: str, value: Any) -> None:
        spec = _PARAM_BY_NAME.get(name)
        if spec is None:
            return
        if not spec["writable"]:
            return
        if spec["type"] == "number":
            number = float(value)
            minimum = spec["min"]
            maximum = spec["max"]
            if minimum is not None:
                number = max(float(minimum), number)
            if maximum is not None:
                number = min(float(maximum), number)
            self._params[name] = number
            return
        choices = spec["choices"]
        if choices is not None and value not in choices:
            return
        self._params[name] = value

    def _parameter_values(self, names: list[str], request_id: str | None) -> str:
        keys = names or list(self._params)
        params = []
        from pocketsensor.protocol import ParameterValue

        for name in keys:
            if name not in self._params:
                continue
            value = self._params[name]
            ptype = "float64" if isinstance(value, (int, float)) and not isinstance(value, bool) else None
            params.append(ParameterValue(name=name, value=value, type=ptype))
        return build_parameter_values(params, request_id=str(request_id) if request_id is not None else None)

    def _notify_param_updates(self, names: list[str]) -> None:
        with self._clients_lock:
            clients = list(self._clients)
        for client in clients:
            hit = [n for n in names if n in client.param_sub]
            if hit:
                self._send_text(client, self._parameter_values(hit, None))

    def _send_latched(self, client: _Client, sub_id: int, channel: ChannelInfo) -> None:
        t_wire = self.device_now_ns()
        payload = None
        if channel.topic.endswith("/device_info") or channel.topic.endswith("device_info"):
            payload = self._encode_device_info(t_wire)
        elif channel.topic == "/tf_static":
            payload = self._encode_tf_static(t_wire)
        if payload is not None:
            self._send_bin(client, build_message_data(sub_id, t_wire, payload))

    def _anyone(self, key: str) -> list[tuple[_Client, int]]:
        channel = self._by_key.get(key)
        if channel is None:
            return []
        found: list[tuple[_Client, int]] = []
        with self._clients_lock:
            clients = list(self._clients)
        for client in clients:
            for sub_id, channel_id in client.subs.items():
                if channel_id == channel.id:
                    found.append((client, sub_id))
        return found

    def _broadcast(self, key: str, t_wire: int, payload: bytes) -> None:
        if key in self._drop_members:
            return
        for client, sub_id in self._anyone(key):
            self._enqueue_bin(client, build_message_data(sub_id, t_wire, payload))

    def _should_send(self, rate: float, frame_index: int) -> bool:
        step = max(1, math.ceil(60.0 / max(float(rate), 1e-9)))
        return frame_index % step == 0

    def _produce(self) -> None:
        frame_period = 1_000_000_000 // 60
        next_frame = time.monotonic_ns()
        next_imu = next_frame
        next_mag = next_frame
        next_pressure = next_frame
        next_slow = next_frame
        frame_index = 0
        while not self._stop.is_set():
            if time.monotonic() < self._stall_until:
                time.sleep(0.005)
                continue
            now = time.monotonic_ns()
            t_wire = self.device_now_ns()
            if now >= next_frame:
                self._emit_arframe(frame_index, t_wire)
                frame_index += 1
                next_frame += frame_period
                if next_frame < now - 500_000_000:
                    next_frame = now
            imu_hz = float(self._params["imu.rate"])
            imu_period = int(1_000_000_000 / max(imu_hz, 1.0))
            if now >= next_imu:
                self._emit_imu(t_wire)
                next_imu += imu_period
                if next_imu < now - 500_000_000:
                    next_imu = now
            if now >= next_mag:
                self._emit_mag(t_wire)
                next_mag += 20_000_000
            if now >= next_pressure:
                self._emit_pressure(t_wire)
                next_pressure += 100_000_000
            if now >= next_slow:
                self._emit_slow(t_wire)
                next_slow += 1_000_000_000
            time.sleep(0.001)

    def _emit_arframe(self, frame_index: int, t_wire: int) -> None:
        pose_rate = float(self._params["pose.rate"])
        color_rate = float(self._params["color.rate"])
        depth_rate = float(self._params["depth.rate"])
        if self._should_send(pose_rate, frame_index):
            self._emit_pose(frame_index, t_wire)
        if self._should_send(color_rate, frame_index):
            self._emit_color(frame_index, t_wire)
        if self._should_send(depth_rate, frame_index):
            self._emit_depth(frame_index, t_wire)

    def _emit_pose(self, frame_index: int, t_wire: int) -> None:
        theta = frame_index * (2.0 * math.pi / 180.0)
        x = math.cos(theta)
        y = math.sin(theta)
        q = rpy_to_quaternion(0.0, 0.0, theta)
        header = {"stamp": _stamp(t_wire), "frame_id": f"{self.name}_odom"}
        twist_cov = [0.0] * 36
        twist_cov[0] = -1.0
        tracking = self._codec.make(
            "pocketsensor_msgs/msg/TrackingStatus",
            header={"stamp": _stamp(t_wire), "frame_id": f"{self.name}_link"},
            state=2,
            reason=0,
            origin_epoch=self._origin_epoch,
        )
        self._broadcast(
            "tracking",
            t_wire,
            self._codec.encode("pocketsensor_msgs/msg/TrackingStatus", tracking),
        )
        odom = self._codec.make(
            "nav_msgs/msg/Odometry",
            header=header,
            child_frame_id=f"{self.name}_link",
            pose={
                "pose": {
                    "position": {"x": x, "y": y, "z": 0.0},
                    "orientation": _quat_dict(q),
                },
                "covariance": [0.0] * 36,
            },
            twist={"covariance": twist_cov},
        )
        self._broadcast("odom", t_wire, self._codec.encode("nav_msgs/msg/Odometry", odom))
        pose_transform = {
            "header": header,
            "child_frame_id": f"{self.name}_link",
            "transform": {
                "translation": {"x": x, "y": y, "z": 0.0},
                "rotation": _quat_dict(q),
            },
        }
        # 実機と同じく、anchor は姿勢の変換の後ろへ載せる。/tf が anchor だけになることは無い。
        transforms = [pose_transform, *self._due_anchor_transforms(t_wire, header)]
        tf = self._codec.make("tf2_msgs/msg/TFMessage", transforms=transforms)
        self._broadcast("tf", t_wire, self._codec.encode("tf2_msgs/msg/TFMessage", tf))

    def _due_anchor_transforms(self, t_wire: int, header: dict[str, Any]) -> list[dict[str, Any]]:
        # アプリと同じく、名前ごとに端末時刻 0.5 秒に 1 回を上限にする。
        current = dict(self.anchors)
        if not current:
            return []
        interval_ns = 500_000_000
        out: list[dict[str, Any]] = []
        for name, (pos, quat) in current.items():
            last = self._anchor_last_ns.get(name)
            if last is not None and t_wire - last < interval_ns:
                continue
            self._anchor_last_ns[name] = t_wire
            out.append(
                {
                    "header": header,
                    "child_frame_id": f"{self.name}_anchor_{name}",
                    "transform": {
                        "translation": {"x": float(pos[0]), "y": float(pos[1]), "z": float(pos[2])},
                        "rotation": {
                            "x": float(quat[0]),
                            "y": float(quat[1]),
                            "z": float(quat[2]),
                            "w": float(quat[3]),
                        },
                    },
                }
            )
        return out

    def _color_size(self) -> tuple[int, int]:
        width = int(self._params["color.width"])
        height = max(1, int(round(width * 3 / 4)))
        return width, height

    def _emit_color(self, frame_index: int, t_wire: int) -> None:
        width, height = self._color_size()
        jpeg = self._jpeg(width, height, frame_index)
        header = {"stamp": _stamp(t_wire), "frame_id": f"{self.name}_color_optical_frame"}
        msg = self._codec.make(
            "sensor_msgs/msg/CompressedImage",
            header=header,
            format="jpeg",
            data=jpeg,
        )
        self._broadcast("color_camera_info", t_wire, self._encode_camera_info(header, width, height))
        self._broadcast("color_image", t_wire, self._codec.encode("sensor_msgs/msg/CompressedImage", msg))

    def _emit_depth(self, frame_index: int, t_wire: int) -> None:
        height, width = 192, 256
        depth = np.full((height, width), 1000 + (frame_index % 50), dtype=np.uint16)
        depth[:8, :8] = 0
        conf = np.zeros((height, width), dtype=np.uint8)
        conf[:, : width // 3] = 0
        conf[:, width // 3 : 2 * width // 3] = 1
        conf[:, 2 * width // 3 :] = 2
        header = {"stamp": _stamp(t_wire), "frame_id": f"{self.name}_color_optical_frame"}
        depth_msg = self._codec.make(
            "sensor_msgs/msg/Image",
            header=header,
            height=height,
            width=width,
            encoding="16UC1",
            is_bigendian=0,
            step=width * 2,
            data=depth.tobytes(),
        )
        conf_msg = self._codec.make(
            "sensor_msgs/msg/Image",
            header=header,
            height=height,
            width=width,
            encoding="mono8",
            is_bigendian=0,
            step=width,
            data=conf.tobytes(),
        )
        self._broadcast("depth_camera_info", t_wire, self._encode_camera_info(header, width, height))
        self._broadcast("depth_image", t_wire, self._codec.encode("sensor_msgs/msg/Image", depth_msg))
        self._broadcast("depth_confidence", t_wire, self._codec.encode("sensor_msgs/msg/Image", conf_msg))
        if "depth_image_compressed" in self._by_key:
            png16 = self._png(depth)
            compressed_depth = self._codec.make(
                "sensor_msgs/msg/CompressedImage",
                header=header,
                format=_COMPRESSED_DEPTH_FORMAT,
                data=_COMPRESSED_DEPTH_HEADER + png16,
            )
            self._broadcast(
                "depth_image_compressed",
                t_wire,
                self._codec.encode("sensor_msgs/msg/CompressedImage", compressed_depth),
            )
        if "depth_confidence_compressed" in self._by_key:
            png8 = self._png(conf)
            compressed_conf = self._codec.make(
                "sensor_msgs/msg/CompressedImage",
                header=header,
                format=_COMPRESSED_CONFIDENCE_FORMAT,
                data=png8,
            )
            self._broadcast(
                "depth_confidence_compressed",
                t_wire,
                self._codec.encode("sensor_msgs/msg/CompressedImage", compressed_conf),
            )

    def _encode_camera_info(self, header: dict[str, Any], width: int, height: int) -> bytes:
        base = Intrinsics(
            1920,
            1440,
            1500.0,
            1500.0,
            960.0,
            720.0,
            distortion_model=self.distortion_model,
            distortion=self.distortion,
        )
        k = scale_intrinsics(base, width, height)
        km, rm, pm, dm = camera_info_matrices(k)
        msg = self._codec.make(
            "sensor_msgs/msg/CameraInfo",
            header=header,
            height=height,
            width=width,
            distortion_model=k.distortion_model,
            d=dm,
            k=km,
            r=rm,
            p=pm,
        )
        return self._codec.encode("sensor_msgs/msg/CameraInfo", msg)

    def _jpeg(self, width: int, height: int, frame_index: int) -> bytes:
        image = np.zeros((height, width, 3), dtype=np.uint8)
        if width > 1:
            image[:, :, 0] = np.linspace(0, 255, width, dtype=np.uint8)[None, :]
        if height > 1:
            image[:, :, 2] = np.linspace(0, 255, height, dtype=np.uint8)[:, None]
        image[:, :, 1] = (frame_index * 17) % 256
        if Image is None:
            return b""
        buf = io.BytesIO()
        quality = int(round(float(self._params["color.jpeg_quality"]) * 100))
        quality = min(95, max(10, quality))
        Image.fromarray(image, "RGB").save(buf, format="JPEG", quality=quality)
        return buf.getvalue()

    def _png(self, pixels: np.ndarray) -> bytes:
        if Image is None:
            return b""
        buf = io.BytesIO()
        Image.fromarray(pixels).save(buf, format="PNG")
        return buf.getvalue()

    def _emit_imu(self, t_wire: int) -> None:
        header = {"stamp": _stamp(t_wire), "frame_id": f"{self.name}_imu_link"}
        cov_unset = [-1.0] + [0.0] * 8
        raw = self._codec.make(
            "sensor_msgs/msg/Imu",
            header=header,
            orientation_covariance=cov_unset,
            angular_velocity={"z": 0.01},
            linear_acceleration={"z": 9.80665},
        )
        fused = self._codec.make(
            "sensor_msgs/msg/Imu",
            header=header,
            orientation={"w": 1.0},
            angular_velocity={"z": 0.01},
            linear_acceleration={"z": 9.80665},
        )
        payload_raw = self._codec.encode("sensor_msgs/msg/Imu", raw)
        payload = self._codec.encode("sensor_msgs/msg/Imu", fused)
        self._broadcast("imu_raw", t_wire, payload_raw)
        self._broadcast("imu", t_wire, payload)

    def _emit_mag(self, t_wire: int) -> None:
        header = {"stamp": _stamp(t_wire), "frame_id": f"{self.name}_imu_link"}
        msg = self._codec.make(
            "sensor_msgs/msg/MagneticField",
            header=header,
            magnetic_field={"x": 20e-6, "y": 5e-6, "z": 40e-6},
        )
        self._broadcast("mag", t_wire, self._codec.encode("sensor_msgs/msg/MagneticField", msg))

    def _emit_pressure(self, t_wire: int) -> None:
        header = {"stamp": _stamp(t_wire), "frame_id": f"{self.name}_link"}
        msg = self._codec.make("sensor_msgs/msg/FluidPressure", header=header, fluid_pressure=101325.0)
        self._broadcast("pressure", t_wire, self._codec.encode("sensor_msgs/msg/FluidPressure", msg))

    def _emit_slow(self, t_wire: int) -> None:
        header_link = {"stamp": _stamp(t_wire), "frame_id": f"{self.name}_link"}
        fix = self._codec.make(
            "sensor_msgs/msg/NavSatFix",
            header=header_link,
            status={"status": 0, "service": 0},
            latitude=35.0,
            longitude=139.0,
            altitude=10.0,
            position_covariance=[1.0, 0, 0, 0, 1.0, 0, 0, 0, 4.0],
            position_covariance_type=1,
        )
        self._broadcast("gnss_fix", t_wire, self._codec.encode("sensor_msgs/msg/NavSatFix", fix))
        tref = self._codec.make(
            "sensor_msgs/msg/TimeReference",
            header={"stamp": _stamp(t_wire), "frame_id": ""},
            time_ref=_stamp(self._start_wall),
            source="gnss",
        )
        self._broadcast(
            "gnss_time_reference",
            t_wire,
            self._codec.encode("sensor_msgs/msg/TimeReference", tref),
        )
        bat = self._codec.make(
            "sensor_msgs/msg/BatteryState",
            header={"stamp": _stamp(t_wire), "frame_id": ""},
            percentage=0.8,
            power_supply_status=2,
            present=True,
        )
        self._broadcast("battery", t_wire, self._codec.encode("sensor_msgs/msg/BatteryState", bat))
        diag = self._codec.make(
            "diagnostic_msgs/msg/DiagnosticArray",
            header={"stamp": _stamp(t_wire), "frame_id": ""},
            status=[
                {
                    "level": 0,
                    "name": "pocketsensor",
                    "message": "ok",
                    "hardware_id": self.name,
                    "values": [],
                }
            ],
        )
        self._broadcast(
            "diagnostics", t_wire, self._codec.encode("diagnostic_msgs/msg/DiagnosticArray", diag)
        )

    def _encode_tf_static(self, t_wire: int) -> bytes:
        q_color = rpy_to_quaternion(*LINK_TO_COLOR_OPTICAL_RPY)
        q_imu = rpy_to_quaternion(*LINK_TO_IMU_RPY)
        header = {"stamp": _stamp(t_wire), "frame_id": f"{self.name}_link"}
        msg = self._codec.make(
            "tf2_msgs/msg/TFMessage",
            transforms=[
                {
                    "header": header,
                    "child_frame_id": f"{self.name}_color_optical_frame",
                    "transform": {
                        "translation": {"x": 0.0, "y": 0.0, "z": 0.0},
                        "rotation": _quat_dict(q_color),
                    },
                },
                {
                    "header": header,
                    "child_frame_id": f"{self.name}_imu_link",
                    "transform": {
                        "translation": {"x": 0.0, "y": 0.0, "z": 0.0},
                        "rotation": _quat_dict(q_imu),
                    },
                },
            ],
        )
        return self._codec.encode("tf2_msgs/msg/TFMessage", msg)

    def _device_streams(self, color_width: int, color_height: int) -> dict[str, dict[str, Any]]:
        images = {
            "color_image": (color_width, color_height, "jpeg"),
            "depth_image": (256, 192, "16UC1"),
            "depth_confidence": (256, 192, "mono8"),
            "depth_image_compressed": (256, 192, "16UC1; compressedDepth png"),
            "depth_confidence_compressed": (256, 192, "mono8; png compressed "),
        }
        streams: dict[str, dict[str, Any]] = {}
        for row in CHANNELS:
            key = str(row["key"])
            if key not in self._by_key:
                continue
            entry: dict[str, Any] = {"topic": self._by_key[key].topic, "schema": str(row["schema"])}
            if key in images:
                entry["width"], entry["height"], entry["encoding"] = images[key]
            rate_param = row.get("rate_param")
            rate = self._params.get(str(rate_param)) if rate_param else row.get("rate_hz")
            if rate is not None:
                entry["rate"] = rate
            streams[key] = entry
        return streams

    def _encode_device_info(self, t_wire: int) -> bytes:
        width, height = self._color_size()
        payload = {
            "schema_version": 1,
            "session_id": self._session_id,
            "name": self.name,
            "model": "FakeDevice",
            "os_version": "iOS-fake",
            "app_version": "0.1.0",
            "mode": "arkit",
            "streams": self._device_streams(width, height),
            # キーは、アプリ（PocketSensorCore の DeviceInfo）が送るものと同じにする。
            "clock": {
                "kind": "mach_absolute_time",
                "anchor_ns": int(self._start_wall - self._start_mono),
                "anchored_at_wall_ns": int(self._start_wall),
                "self_check": "ok",
            },
            "frames": {
                "odom": f"{self.name}_odom",
                "link": f"{self.name}_link",
                "color_optical": f"{self.name}_color_optical_frame",
                "imu_link": f"{self.name}_imu_link",
                "static_transforms": [
                    {
                        "parent": f"{self.name}_link",
                        "child": f"{self.name}_color_optical_frame",
                        "translation": [0.0, 0.0, 0.0],
                        "rotation_xyzw": [float(v) for v in rpy_to_quaternion(*LINK_TO_COLOR_OPTICAL_RPY)],
                        "calibrated": True,
                    },
                    {
                        "parent": f"{self.name}_link",
                        "child": f"{self.name}_imu_link",
                        "translation": [0.0, 0.0, 0.0],
                        "rotation_xyzw": [float(v) for v in rpy_to_quaternion(*LINK_TO_IMU_RPY)],
                        "calibrated": False,
                    },
                ],
            },
        }
        msg = self._codec.make(
            "std_msgs/msg/String",
            data=json.dumps(payload),
        )
        return self._codec.encode("std_msgs/msg/String", msg)

#!/usr/bin/env python3
"""中継が出すトピックを、ROS 2 の側から確かめる。コンテナの中で、中継と republish を動かした状態で実行する。

確かめること
  - 標準の型と pocketsensor_msgs の型で、期待する数のメッセージが届く
  - header.stamp が、このマシンのシステム時刻の近くへ書き換わっている
  - transient local の device_info と /tf_static が、後から購読しても届く
  - TF の木から、odom -> link、link -> 光学 frame、anchor が引ける
  - image_transport の republish が、compressedDepth と compressed を sensor_msgs/Image へ戻せる
"""

from __future__ import annotations

import argparse
import json
import sys
import time

import rclpy
from diagnostic_msgs.msg import DiagnosticArray
from nav_msgs.msg import Odometry
from pocketsensor_msgs.msg import TrackingStatus
from rclpy.node import Node
from rclpy.qos import DurabilityPolicy, QoSProfile, ReliabilityPolicy, qos_profile_sensor_data
from rclpy.time import Time
from sensor_msgs.msg import CameraInfo, CompressedImage, Image, Imu
from std_msgs.msg import String
from tf2_ros import Buffer, TransformListener

LATCHED = QoSProfile(
    depth=1, reliability=ReliabilityPolicy.RELIABLE, durability=DurabilityPolicy.TRANSIENT_LOCAL
)


class Checker(Node):
    def __init__(self, name: str) -> None:
        super().__init__("pocketsensor_check")
        self.device = name
        self.counts: dict[str, int] = {}
        self.stamp_error_s: dict[str, float] = {}
        self.samples: dict[str, object] = {}
        self.tf_buffer = Buffer()
        self.tf_listener = TransformListener(self.tf_buffer, self)
        prefix = f"/{name}"
        self._watch(Odometry, f"{prefix}/odom", 10)
        self._watch(TrackingStatus, f"{prefix}/tracking", 10)
        self._watch(Imu, f"{prefix}/imu/data", qos_profile_sensor_data)
        self._watch(CompressedImage, f"{prefix}/color/image/compressed", qos_profile_sensor_data)
        self._watch(CompressedImage, f"{prefix}/depth/image/compressedDepth", qos_profile_sensor_data)
        self._watch(CompressedImage, f"{prefix}/depth/confidence/compressed", qos_profile_sensor_data)
        self._watch(CameraInfo, f"{prefix}/depth/camera_info", 10)
        self._watch(DiagnosticArray, "/diagnostics", 10)
        self._watch(String, f"{prefix}/device_info", LATCHED)
        # republish の出力。上流のデコーダーが、端末の PNG を sensor_msgs/Image へ戻したもの。
        self._watch(Image, "/check/depth_raw", qos_profile_sensor_data)
        self._watch(Image, "/check/confidence_raw", qos_profile_sensor_data)

    def _watch(self, msg_type: type, topic: str, qos: object) -> None:
        self.counts[topic] = 0

        def callback(msg: object, topic: str = topic) -> None:
            self.counts[topic] += 1
            self.samples[topic] = msg
            header = getattr(msg, "header", None)
            if header is not None and (header.stamp.sec or header.stamp.nanosec):
                now = self.get_clock().now().nanoseconds
                stamp = Time.from_msg(header.stamp).nanoseconds
                self.stamp_error_s[topic] = (now - stamp) / 1e9

        self.create_subscription(msg_type, topic, callback, qos)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--name", default="pocketsensor")
    parser.add_argument("--seconds", type=float, default=6.0)
    parser.add_argument("--anchor", default="")
    parser.add_argument("--publish-tf", choices=("true", "false"), default="true")
    parser.add_argument(
        "--rate-scale",
        type=float,
        default=1.0,
        help="scale of the minimum message counts; use 0.4 for a real device over WiFi",
    )
    args = parser.parse_args()

    rclpy.init()
    node = Checker(args.name)
    deadline = time.monotonic() + args.seconds
    while time.monotonic() < deadline:
        rclpy.spin_once(node, timeout_sec=0.05)

    name = args.name
    problems: list[str] = []
    report: dict[str, object] = {
        "rate_hz": {topic: round(count / args.seconds, 1) for topic, count in node.counts.items()},
        "stamp_error_ms": {topic: round(error * 1e3, 1) for topic, error in node.stamp_error_s.items()},
    }

    minimum = {
        f"/{name}/odom": 20 * args.seconds,
        f"/{name}/tracking": 20 * args.seconds,
        f"/{name}/imu/data": 70 * args.seconds,
        f"/{name}/color/image/compressed": 8 * args.seconds,
        f"/{name}/depth/image/compressedDepth": 8 * args.seconds,
        f"/{name}/depth/confidence/compressed": 8 * args.seconds,
        f"/{name}/depth/camera_info": 8 * args.seconds,
        "/diagnostics": 0.5 * args.seconds,
        f"/{name}/device_info": 1,
        "/check/depth_raw": 5 * args.seconds,
        "/check/confidence_raw": 5 * args.seconds,
    }
    for topic, need in minimum.items():
        need = 1 if need == 1 else need * args.rate_scale
        if node.counts.get(topic, 0) < need:
            problems.append(f"{topic}: {node.counts.get(topic, 0)} messages, expected at least {need:.0f}")
    # 中継が二重に動いていると、レートが倍になる。設定の上限（姿勢 30 Hz、IMU 100 Hz）を超えないことも見る。
    limits_hz = {f"/{name}/odom": 36.0, f"/{name}/imu/data": 115.0, "/check/depth_raw": 20.0}
    for topic, limit_hz in limits_hz.items():
        rate = node.counts.get(topic, 0) / args.seconds
        if rate > limit_hz:
            problems.append(f"{topic}: {rate:.1f} Hz exceeds the configured rate")
    if node.counts.get(f"/{name}/device_info", 0) > 1:
        problems.append("device_info was delivered more than once: is another relay running?")

    for topic, error in node.stamp_error_s.items():
        # 中継は stamp をシステム時刻へ書き換える。端末のクロックのままなら、擬似デバイスでも数十秒は離れる。
        if abs(error) > 0.5:
            problems.append(f"{topic}: header.stamp is {error:+.3f} s from the ROS clock")

    depth = node.samples.get("/check/depth_raw")
    if depth is not None:
        layout = (depth.encoding, depth.width, depth.height, depth.step)
        report["depth_raw"] = list(layout)
        if layout != ("16UC1", 256, 192, 512):
            problems.append(f"republished depth has an unexpected layout: {report['depth_raw']}")
        if not any(depth.data):
            problems.append("republished depth is all zero")
    confidence = node.samples.get("/check/confidence_raw")
    if confidence is not None:
        layout = (confidence.encoding, confidence.width, confidence.height)
        report["confidence_raw"] = list(layout)
        if layout != ("mono8", 256, 192):
            problems.append(f"republished confidence has an unexpected layout: {report['confidence_raw']}")

    lookups = []
    if args.publish_tf == "true":
        lookups += [
            (f"{name}_odom", f"{name}_link"),
            (f"{name}_link", f"{name}_color_optical_frame"),
            (f"{name}_link", f"{name}_imu_link"),
        ]
        if args.anchor:
            lookups.append((f"{name}_odom", f"{name}_anchor_{args.anchor}"))
    elif args.anchor:
        lookups.append((f"{name}_link", f"{name}_anchor_{args.anchor}"))
    transforms = {}
    for parent, child in lookups:
        try:
            tf = node.tf_buffer.lookup_transform(parent, child, Time())
            t, q = tf.transform.translation, tf.transform.rotation
            transforms[f"{parent}->{child}"] = [round(v, 4) for v in (t.x, t.y, t.z, q.x, q.y, q.z, q.w)]
        except Exception as exc:  # noqa: BLE001
            problems.append(f"TF {parent} -> {child} is not available: {exc}")
    report["transforms"] = transforms
    optical = transforms.get(f"{name}_link->{name}_color_optical_frame")
    if optical is not None:
        # q と -q は同じ回転。tf2 は符号を揃えずに返すので、内積の絶対値で比べる。
        dot = sum(a * b for a, b in zip(optical[3:], (-0.5, 0.5, -0.5, 0.5), strict=True))
        if abs(abs(dot) - 1.0) > 1e-3:
            problems.append(f"link -> optical rotation is {optical[3:]}, expected (-0.5, 0.5, -0.5, 0.5)")
    if args.publish_tf == "false" and f"{name}_odom" in node.tf_buffer.all_frames_as_string():
        problems.append("publish_tf is false but a transform from the device odom frame was published")

    report["problems"] = problems
    print(json.dumps(report, indent=1, default=str))
    node.destroy_node()
    rclpy.shutdown()
    return 0 if not problems else 1


if __name__ == "__main__":
    sys.exit(main())

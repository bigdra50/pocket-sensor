from __future__ import annotations

from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument
from launch.substitutions import LaunchConfiguration
from launch_ros.actions import Node


def generate_launch_description() -> LaunchDescription:
    source = LaunchConfiguration("source")
    rewrite_stamp = LaunchConfiguration("rewrite_stamp")
    publish_tf = LaunchConfiguration("publish_tf")
    return LaunchDescription(
        [
            DeclareLaunchArgument("source", default_value="ws://iphone.local:8765"),
            DeclareLaunchArgument("rewrite_stamp", default_value="true"),
            DeclareLaunchArgument("publish_tf", default_value="true"),
            Node(
                package="pocketsensor_ros",
                executable="relay",
                name="pocketsensor_relay",
                output="screen",
                parameters=[
                    {
                        "source": source,
                        "rewrite_stamp": rewrite_stamp,
                        "publish_tf": publish_tf,
                    }
                ],
            ),
        ]
    )

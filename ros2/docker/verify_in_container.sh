#!/usr/bin/env bash
# ROS 2 のコンテナの中で、中継をビルドして動かし、ROS 2 の側から確かめる。
#   /repo  このリポジトリ（読み取り専用）
#   SOURCE 端末か擬似デバイスの URL（例 ws://host.docker.internal:8766）
#   BAG    SDK が記録した MCAP（任意）。rosbag2 で読めることを確かめる
set -eo pipefail
SOURCE="${SOURCE:?set SOURCE, e.g. ws://host.docker.internal:8766}"
NAME="${NAME:-pocketsensor}"
ANCHOR="${ANCHOR:-}"
source "/opt/ros/${ROS_DISTRO:-jazzy}/setup.bash"

# 公式の ros-base には、画像の圧縮のプラグイン、xacro、pip が入っていない。足りないものだけを入れる。
missing=()
ros2 pkg prefix compressed_depth_image_transport >/dev/null 2>&1 || missing+=("ros-${ROS_DISTRO}-image-transport-plugins")
ros2 pkg prefix xacro >/dev/null 2>&1 || missing+=("ros-${ROS_DISTRO}-xacro")
ros2 pkg prefix rosbag2_storage_mcap >/dev/null 2>&1 || missing+=("ros-${ROS_DISTRO}-rosbag2-storage-mcap")
command -v pip3 >/dev/null || missing+=(python3-pip)
command -v colcon >/dev/null || missing+=(python3-colcon-common-extensions)
if [ ${#missing[@]} -gt 0 ]; then
  echo "== 足りないパッケージを入れる: ${missing[*]}"
  apt-get update -qq && apt-get install -y -qq "${missing[@]}" >/dev/null
fi

echo "== 受け手 SDK を ROS 2 の Python へ入れる"
cp -r /repo/python /tmp/sdk && pip3 install --quiet --break-system-packages /tmp/sdk

echo "== colcon build"
mkdir -p /ws/src && cp -r /repo/ros2/pocketsensor_msgs /repo/ros2/pocketsensor_ros /ws/src/
cd /ws && colcon build --event-handlers console_cohesion- >/tmp/colcon.log 2>&1 || { tail -40 /tmp/colcon.log; exit 1; }
source /ws/install/setup.bash
# head で切ると、pipefail の下では ros2 の BrokenPipe が失敗として返る。いったんファイルへ出す。
ros2 interface show pocketsensor_msgs/msg/TrackingStatus > /tmp/interface.txt
grep -c . /tmp/interface.txt | sed 's/^/TrackingStatus lines: /'

echo "== xacro のマクロを展開する"
cat > /tmp/robot.urdf.xacro <<'XACRO'
<?xml version="1.0"?>
<robot name="check" xmlns:xacro="http://www.ros.org/wiki/xacro">
  <link name="base_link"/>
  <xacro:include filename="$(find pocketsensor_ros)/urdf/pocketsensor.urdf.xacro"/>
  <xacro:pocketsensor_device name="pocketsensor" parent="base_link" xyz="0 0 0.3"/>
</robot>
XACRO
xacro /tmp/robot.urdf.xacro > /tmp/robot.urdf
echo "joints: $(grep -c '<joint' /tmp/robot.urdf)"
if command -v check_urdf >/dev/null; then check_urdf /tmp/robot.urdf > /tmp/check_urdf.txt; tail -6 /tmp/check_urdf.txt; fi

# `ros2 run` は子プロセスを作るので、その PID を止めてもノードが残る。実行ファイルを直接起動する。
RELAY=/ws/install/pocketsensor_ros/lib/pocketsensor_ros/relay
REPUBLISH="/opt/ros/${ROS_DISTRO:-jazzy}/lib/image_transport/republish"

run_case() {  # publish_tf の値を受け取って、中継と republish を動かして確かめる
  local publish_tf="$1"
  echo "== 中継を起動する（publish_tf=${publish_tf}）"
  "${RELAY}" --ros-args -p source:="${SOURCE}" -p publish_tf:="${publish_tf}" >/tmp/relay.log 2>&1 &
  local relay=$!
  "${REPUBLISH}" --ros-args -p in_transport:=compressedDepth -p out_transport:=raw \
    -r in/compressedDepth:="/${NAME}/depth/image/compressedDepth" -r out:=/check/depth_raw \
    -p "qos_overrides./${NAME}/depth/image/compressedDepth.subscription.reliability:=best_effort" \
    >/tmp/republish_depth.log 2>&1 &
  local rep_depth=$!
  "${REPUBLISH}" --ros-args -p in_transport:=compressed -p out_transport:=raw \
    -r in/compressed:="/${NAME}/depth/confidence/compressed" -r out:=/check/confidence_raw \
    -p "qos_overrides./${NAME}/depth/confidence/compressed.subscription.reliability:=best_effort" \
    >/tmp/republish_conf.log 2>&1 &
  local rep_conf=$!
  sleep 4
  local status=0
  python3 /repo/ros2/docker/check_relay.py --name "${NAME}" --anchor "${ANCHOR}" --publish-tf "${publish_tf}" \
    --rate-scale "${RATE_SCALE:-1.0}" || status=$?
  kill $relay $rep_depth $rep_conf 2>/dev/null || true
  wait $relay $rep_depth $rep_conf 2>/dev/null || true
  if [ $status -ne 0 ]; then
    echo "-- relay log"; tail -5 /tmp/relay.log
    echo "-- republish log"; tail -5 /tmp/republish_depth.log
  fi
  sleep 1
  return $status
}

result=0
run_case true || result=1
run_case false || result=1

if [ -n "${BAG:-}" ]; then
  echo "== rosbag2 で SDK の記録を読む"
  ros2 bag info "${BAG}" > /tmp/baginfo.txt
  cat /tmp/baginfo.txt
  grep -q "pocketsensor_msgs/msg/TrackingStatus" /tmp/baginfo.txt || { echo "TrackingStatus is missing from the bag info"; result=1; }
  echo "== rosbag2 で再生して、ROS 2 のノードで受け取る"
  ros2 bag play "${BAG}" --rate 2.0 >/tmp/bagplay.log 2>&1 &
  play=$!
  # 型を明示する。再生の開始より先に echo が動くと、トピックの型を引けずに終わる。
  timeout 10 ros2 topic echo --once "/${NAME}/odom" nav_msgs/msg/Odometry --field pose.pose.position \
    || { echo "no odom from the bag"; result=1; }
  kill $play 2>/dev/null || true
fi

[ $result -eq 0 ] && echo "ROS2 CHECK: OK" || echo "ROS2 CHECK: FAILED"
exit $result

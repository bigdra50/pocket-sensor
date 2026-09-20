#!/usr/bin/env bash
# ホスト側の入口。擬似デバイスを起動し、SDK で短い MCAP を記録してから、
# ROS 2 のコンテナの中で中継、image_transport、TF、rosbag2 を確かめる。
#
#   POCKETSENSOR_ROS_IMAGE  使う Docker イメージ（既定は ros:jazzy-ros-base）。足りないパッケージは中で入れる
#   SOURCE                  擬似デバイスの代わりに確かめる端末（例 ws://192.168.1.20:8765）。コンテナの中から届く URL
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IMAGE="${POCKETSENSOR_ROS_IMAGE:-ros:jazzy-ros-base}"
WORK="$(mktemp -d)"
SIM_PID=""
cleanup() {
  [ -n "${SIM_PID}" ] && kill "${SIM_PID}" 2>/dev/null || true
  rm -rf "${WORK}"
}
trap cleanup EXIT

ANCHOR=""
if [ -z "${SOURCE:-}" ]; then
  SIM="${ROOT}/ios/PocketSensorKit/.build/debug/pocketsensor-sim"
  [ -x "${SIM}" ] || { echo "pocketsensor-sim is not built. Run: mise run build:sim" >&2; exit 2; }
  "${SIM}" --port 0 --no-bonjour --anchor dock --duration 900 --quiet > "${WORK}/sim.out" &
  SIM_PID=$!
  for _ in $(seq 1 100); do
    grep -q "READY port=" "${WORK}/sim.out" 2>/dev/null && break
    sleep 0.1
  done
  PORT="$(sed -n 's/^READY port=\([0-9]*\).*/\1/p' "${WORK}/sim.out")"
  [ -n "${PORT}" ] || { echo "pocketsensor-sim did not start" >&2; exit 1; }
  HOST_SOURCE="ws://127.0.0.1:${PORT}"
  SOURCE="ws://host.docker.internal:${PORT}"
  ANCHOR="dock"
else
  HOST_SOURCE="${HOST_SOURCE:-${SOURCE}}"
  # 実機の WiFi は、コンテナの NAT を通ると擬似デバイスほどのレートが出ない。下限を緩める。
  RATE_SCALE="${RATE_SCALE:-0.4}"
fi

echo "== SDK で ${HOST_SOURCE} を 3 秒記録する"
uv run --project "${ROOT}/python" pocketsensor record "${HOST_SOURCE}" -o "${WORK}/run.mcap" --duration 3

docker run --rm --add-host=host.docker.internal:host-gateway --entrypoint bash \
  -v "${ROOT}:/repo:ro" -v "${WORK}:/data:ro" \
  -e SOURCE="${SOURCE}" -e ANCHOR="${ANCHOR}" -e BAG=/data/run.mcap -e NAME="${NAME:-pocketsensor}" \
  -e RATE_SCALE="${RATE_SCALE:-1.0}" \
  "${IMAGE}" -lc /repo/ros2/docker/verify_in_container.sh

"""内部パラメータと、静的 TF から組む外部パラメータ。"""

from __future__ import annotations

from collections import deque
from typing import Any

import numpy as np
from numpy.typing import NDArray

from pocketsensor.errors import Unsupported
from pocketsensor.frames import quat_to_matrix
from pocketsensor.intrinsics import Intrinsics
from pocketsensor.streams import Stream
from pocketsensor.types import DeviceInfo

_STREAM_FRAME_KEY: dict[Stream, str] = {
    Stream.COLOR: "color_optical",
    Stream.DEPTH: "color_optical",
    Stream.CONFIDENCE: "color_optical",
    Stream.POSE: "link",
    Stream.IMU: "imu",
    Stream.IMU_RAW: "imu",
    Stream.MAG: "imu",
    Stream.PRESSURE: "link",
    Stream.GNSS: "link",
    Stream.BATTERY: "link",
}


def _make_t(rotation_xyzw: Any, translation: Any) -> NDArray[np.float64]:
    t = np.eye(4, dtype=np.float64)
    t[:3, :3] = quat_to_matrix(rotation_xyzw)
    t[:3, 3] = np.asarray(translation, dtype=np.float64).reshape(3)
    return t


def _invert_t(t: NDArray[np.float64]) -> NDArray[np.float64]:
    r = t[:3, :3]
    p = t[:3, 3]
    inv = np.eye(4, dtype=np.float64)
    inv[:3, :3] = r.T
    inv[:3, 3] = -r.T @ p
    return inv


class Calibration:
    """最新の camera_info と /tf_static から較正を引く。"""

    def __init__(
        self,
        device_info: DeviceInfo,
        tf_static: list[dict[str, Any]],
        camera_infos: dict[Stream, Intrinsics],
    ) -> None:
        self._info = device_info
        self._tf_static = list(tf_static)
        self._camera_infos = dict(camera_infos)
        # parent -> child の辺。p_parent = T @ p_child
        self._edges: dict[tuple[str, str], tuple[NDArray[np.float64], bool]] = {}
        self._frames: set[str] = set()
        for item in self._tf_static:
            parent = str(item["parent"])
            child = str(item["child"])
            known = bool(item.get("translation_known", True))
            t = _make_t(item["rotation_xyzw"], item["translation"])
            self._edges[(parent, child)] = (t, known)
            self._frames.add(parent)
            self._frames.add(child)

    @property
    def raw(self) -> dict:
        return self._info.raw

    def intrinsics(self, stream: Stream) -> Intrinsics:
        try:
            return self._camera_infos[stream]
        except KeyError as exc:
            raise Unsupported(f"no camera_info for stream {stream.name}") from exc

    def _resolve_frame(self, frame: str | Stream) -> str:
        if isinstance(frame, Stream):
            key = _STREAM_FRAME_KEY.get(frame)
            if key is None:
                raise Unsupported(f"stream {frame.name} has no frame")
            name = self._info.frames.get(key)
            if not name:
                raise Unsupported(f"device_info.frames is missing {key}")
            return str(name)
        return frame

    def extrinsics(self, source_frame: str | Stream, target_frame: str | Stream) -> NDArray[np.float64]:
        """source の点を target の座標へ写す 4x4。未較正の並進は NaN。"""
        source = self._resolve_frame(source_frame)
        target = self._resolve_frame(target_frame)
        if source == target:
            return np.eye(4, dtype=np.float64)
        path = self._path(source, target)
        t = np.eye(4, dtype=np.float64)
        known = True
        for parent, child, to_child in path:
            edge, edge_known = self._edges[(parent, child)]
            # parent へ進むときは TF そのもの、child へ進むときは逆
            step = _invert_t(edge) if to_child else edge
            t = step @ t
            known = known and edge_known
        if not known:
            t = t.copy()
            t[0, 3] = np.nan
            t[1, 3] = np.nan
            t[2, 3] = np.nan
        return t

    def _path(self, source: str, target: str) -> list[tuple[str, str, bool]]:
        if source not in self._frames or target not in self._frames:
            raise Unsupported(f"unknown frame {source!r} -> {target!r}")
        adj: dict[str, list[tuple[str, str, str, bool]]] = {}
        for parent, child in self._edges:
            adj.setdefault(parent, []).append((parent, child, child, True))
            adj.setdefault(child, []).append((parent, child, parent, False))
        prev: dict[str, tuple[str, str, str, bool] | None] = {source: None}
        queue: deque[str] = deque([source])
        while queue:
            node = queue.popleft()
            if node == target:
                break
            for parent, child, nxt, forward in adj.get(node, []):
                if nxt in prev:
                    continue
                prev[nxt] = (parent, child, node, forward)
                queue.append(nxt)
        if target not in prev:
            raise Unsupported(f"no static transform path {source!r} -> {target!r}")
        steps: list[tuple[str, str, bool]] = []
        node = target
        while node != source:
            parent, child, prev_node, forward = prev[node]  # type: ignore[misc]
            steps.append((parent, child, forward))
            node = prev_node
        steps.reverse()
        return steps

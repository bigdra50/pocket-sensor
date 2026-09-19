from __future__ import annotations

import time
from collections import defaultdict

import numpy as np
import pytest

import pocketsensor as ps
from pocketsensor.cdr import CdrCodec
from pocketsensor.client import FoxgloveClient
from pocketsensor.decode import (
    decode_compressed_depth,
    decode_compressed_mono8,
    decode_image_u8,
    decode_image_u16,
)
from pocketsensor.streams import channel_topic
from pocketsensor.transport import connect

pytestmark = pytest.mark.e2e


def _cfg() -> ps.Config:
    return ps.Config(
        streams=(
            ps.Color(rate=15),
            ps.Depth(rate=15),
            ps.Pose(rate=30),
            ps.Imu(rate=100, raw=True),
        ),
        open_timeout=10.0,
    )


def _cfg_raw() -> ps.Config:
    return ps.Config(
        streams=(
            ps.Color(rate=15),
            ps.Depth(rate=15, compressed=False),
            ps.Pose(rate=30),
            ps.Imu(rate=100, raw=True),
        ),
        open_timeout=10.0,
    )


def test_default_frames_use_compressed_depth_and_match_raw(sim_device: str) -> None:
    with ps.open(sim_device, _cfg()) as dev:
        name = dev.info.name
        frames = dev.wait_for_frames(timeout=3.0)
        assert frames.depth is not None
        assert frames.depth.raw.dtype == np.uint16
        assert frames.depth.raw.shape == (192, 256)
        assert frames.confidence is not None
        meters = frames.depth.meters
        assert np.all(np.isnan(meters[frames.depth.raw == 0]))
        compressed = channel_topic("depth_image_compressed", name)
        raw = channel_topic("depth_image", name)
        deadline = time.monotonic() + 2.0
        while time.monotonic() < deadline and dev.stats.received_messages.get(compressed, 0) == 0:
            time.sleep(0.05)
        assert dev.stats.received_messages.get(compressed, 0) > 0
        assert dev.stats.received_messages.get(raw, 0) == 0

    with ps.open(sim_device, _cfg_raw()) as dev:
        frames = dev.wait_for_frames(timeout=3.0)
        assert frames.depth is not None
        assert frames.depth.raw.shape == (192, 256)
        raw = channel_topic("depth_image", dev.info.name)
        assert dev.stats.received_messages.get(raw, 0) > 0

    transport = connect(sim_device, timeout=5.0)
    client = FoxgloveClient(transport)
    try:
        client.wait_ready(timeout=5.0)
        codec = CdrCodec.from_contract()
        for channel in client.channels.values():
            if channel.schema:
                codec.register_schema(channel.schema_name, channel.schema)
        name = "pocketsensor"
        topics = {
            "depth_raw": channel_topic("depth_image", name),
            "depth_png": channel_topic("depth_image_compressed", name),
            "conf_raw": channel_topic("depth_confidence", name),
            "conf_png": channel_topic("depth_confidence_compressed", name),
        }
        by_topic: dict[str, dict[int, object]] = {topic: {} for topic in topics.values()}
        sizes: dict[str, list[int]] = defaultdict(list)

        def on_message(channel, log_time_ns, payload, arrival_mono, arrival_wall) -> None:
            del arrival_mono, arrival_wall
            if channel.topic not in by_topic:
                return
            sizes[channel.topic].append(len(payload))
            by_topic[channel.topic][int(log_time_ns)] = codec.decode(channel.schema_name, payload)

        client.on_message = on_message
        for topic in topics.values():
            client.subscribe(topic)

        matched_depth = False
        matched_conf = False
        deadline = time.monotonic() + 5.0
        while time.monotonic() < deadline and not (matched_depth and matched_conf):
            time.sleep(0.05)
            common_depth = set(by_topic[topics["depth_raw"]]) & set(by_topic[topics["depth_png"]])
            common_conf = set(by_topic[topics["conf_raw"]]) & set(by_topic[topics["conf_png"]])
            for stamp in sorted(common_depth):
                raw_msg = by_topic[topics["depth_raw"]][stamp]
                png_msg = by_topic[topics["depth_png"]][stamp]
                np.testing.assert_array_equal(decode_image_u16(raw_msg), decode_compressed_depth(png_msg))
                matched_depth = True
                break
            for stamp in sorted(common_conf):
                raw_msg = by_topic[topics["conf_raw"]][stamp]
                png_msg = by_topic[topics["conf_png"]][stamp]
                np.testing.assert_array_equal(decode_image_u8(raw_msg), decode_compressed_mono8(png_msg))
                matched_conf = True
                break
        assert matched_depth
        assert matched_conf
        for key, topic in topics.items():
            med = sorted(sizes[topic])[len(sizes[topic]) // 2]
            print(f"e2e bytes/frame median {key}={med}")
    finally:
        client.close()

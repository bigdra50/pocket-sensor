from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import numpy as np
from rosbags.typesys import Stores, get_typestore

from pocketsensor._generated.contract_data import CHANNELS, MSG_TEXTS, SCHEMA_TEXTS, SERVICES
from pocketsensor.cdr import CdrCodec

REPO = Path(__file__).resolve().parents[2]


def test_vendored_types_match_jazzy(codec: CdrCodec) -> None:
    jazzy = get_typestore(Stores.ROS2_JAZZY)
    missing = []
    mismatched = []
    for name in MSG_TEXTS:
        if name.startswith("pocketsensor_msgs/") or name.startswith("std_srvs/"):
            continue
        if name not in jazzy.fielddefs:
            missing.append(name)
            continue
        if codec.store.fielddefs[name] != jazzy.fielddefs[name]:
            mismatched.append(name)
    assert missing == []
    assert mismatched == []


def test_empty_trigger_encodes_dummy_byte(codec: CdrCodec) -> None:
    msg = codec.make("std_srvs/srv/Trigger_Request")
    encoded = codec.encode("std_srvs/srv/Trigger_Request", msg)
    assert encoded == bytes.fromhex("0001000000")
    assert codec.decode("std_srvs/srv/Trigger_Request", encoded)
    assert codec.decode("std_srvs/srv/Trigger_Request", bytes.fromhex("00010000"))


def test_register_schema_accepts_concatenated_text(codec: CdrCodec) -> None:
    name = "std_msgs/msg/Header"
    extra = CdrCodec.from_contract()
    extra.register_schema(name, SCHEMA_TEXTS[name])
    msg = extra.make(name, stamp={"sec": 1, "nanosec": 2}, frame_id="map")
    encoded = extra.encode(name, msg)
    back = extra.decode(name, encoded)
    assert back.frame_id == "map"
    assert back.stamp.sec == 1


def test_make_nested_overrides(codec: CdrCodec) -> None:
    imu = codec.make(
        "sensor_msgs/msg/Imu",
        header={"stamp": {"sec": 4, "nanosec": 5}, "frame_id": "imu"},
        linear_acceleration={"z": 9.5},
    )
    assert imu.header.stamp.sec == 4
    assert imu.linear_acceleration.z == 9.5
    assert imu.orientation_covariance.shape == (9,)


def test_cdr_vectors_roundtrip(codec: CdrCodec) -> None:
    payload = json.loads((REPO / "contract" / "vectors" / "cdr.json").read_text())
    for case in payload["cases"]:
        msg = codec.make(case["schema"], **case["value"])
        encoded = codec.encode(case["schema"], msg)
        assert encoded.hex() == case["cdr_hex"], case["name"]
        back = codec.decode(case["schema"], encoded)
        again = codec.encode(case["schema"], back)
        assert again == encoded, case["name"]


def test_every_channel_and_service_has_a_cdr_case() -> None:
    payload = json.loads((REPO / "contract" / "vectors" / "cdr.json").read_text())
    schemas = {case["schema"] for case in payload["cases"]}
    for row in CHANNELS:
        assert row["schema"] in schemas, row["key"]
    for row in SERVICES:
        assert f"{row['type']}_Request" in schemas, row["key"]
        assert f"{row['type']}_Response" in schemas, row["key"]


def test_gen_contract_check() -> None:
    result = subprocess.run(
        [sys.executable, str(REPO / "tools" / "gen_contract.py"), "--check"],
        cwd=REPO,
        check=False,
    )
    assert result.returncode == 0


def test_uint64_above_signed_range(codec: CdrCodec) -> None:
    value = 2**63 + 1
    msg = codec.make("pocketsensor_msgs/srv/ClockSync_Request", t1=value)
    encoded = codec.encode("pocketsensor_msgs/srv/ClockSync_Request", msg)
    back = codec.decode("pocketsensor_msgs/srv/ClockSync_Request", encoded)
    assert int(back.t1) == value
    assert np.uint64(back.t1) == np.uint64(value)

from __future__ import annotations

from pocketsensor.streams import Depth, resolve_channel_keys


def test_depth_channel_keys_ignore_advertisement() -> None:
    assert Depth().channel_keys() == ("depth_image", "depth_camera_info", "depth_confidence")
    assert Depth(compressed=False).channel_keys() == (
        "depth_image",
        "depth_camera_info",
        "depth_confidence",
    )
    assert Depth(compressed=True).channel_keys() == (
        "depth_image_compressed",
        "depth_camera_info",
        "depth_confidence_compressed",
    )
    assert Depth(confidence=False, compressed=True).channel_keys() == (
        "depth_image_compressed",
        "depth_camera_info",
    )


def test_depth_resolve_prefers_compressed_when_advertised() -> None:
    both = {
        "depth_image",
        "depth_image_compressed",
        "depth_confidence",
        "depth_confidence_compressed",
        "depth_camera_info",
    }
    raw_only = {"depth_image", "depth_confidence", "depth_camera_info"}
    assert resolve_channel_keys(Depth(), both) == (
        "depth_image_compressed",
        "depth_camera_info",
        "depth_confidence_compressed",
    )
    assert resolve_channel_keys(Depth(), raw_only) == (
        "depth_image",
        "depth_camera_info",
        "depth_confidence",
    )
    assert resolve_channel_keys(Depth(compressed=False), both) == (
        "depth_image",
        "depth_camera_info",
        "depth_confidence",
    )
    assert resolve_channel_keys(Depth(compressed=True), raw_only) == (
        "depth_image_compressed",
        "depth_camera_info",
        "depth_confidence_compressed",
    )

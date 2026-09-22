**English** | [日本語](README.md)

# Examples

Run these from the repository root.
The source can be a `ws://` URL, `usb:`, or the path of a recording.

## view_opencv.py

Shows RGB and colorized depth in an OpenCV window.

```
uv run --project python --with opencv-python python examples/view_opencv.py ws://iphone.local:8765
```

## log_rerun.py

Streams pose, RGB, and a point cloud built from the depth into Rerun.

```
uv run --project python --with rerun-sdk python examples/log_rerun.py usb:
```

## lichtblick-layout.json

A Lichtblick layout with three panels: 3D, RGB, and depth.
The depth panel sets a color map (turbo) and a value range (0 mm to 4000 mm).
Without a value range, Lichtblick draws `16UC1` from 0 mm to 10000 mm, so indoor depth looks almost black.

`mise run view:lichtblick` starts the Lichtblick web app in Docker and prints a URL that opens this layout.

```
SOURCE=ws://iphone.local:8765 mise run view:lichtblick
```

In the desktop app, load this file with Import from file in the layout menu.

Topic and frame names are the ones used when the device name is the default, `pocketsensor`.
If you rename the device, replace `pocketsensor` inside the file.
When the device is mounted in portrait, change Rotation in the RGB and depth panel settings.

**English** | [日本語](../frames-and-units.md)

# Coordinate frames and units

Published values follow the ROS 2 conventions (REP-103, REP-105, and REP-145) and SI units.

## Shared conventions

- Every coordinate frame is right-handed
- A frame fixed to the device has x forward, y left, and z up
- A camera optical frame has z along the optical axis, x to the right in the image, and y down in the image
- Rotations are unit quaternions (x, y, z, w)
- Lengths are meters, angles are radians, and time is seconds

## Frames

Frame names are prefixed with the device name, `<name>`.

| Frame | Definition |
| --- | --- |
| `<name>_odom` | The ARKit world, with its axes reassigned to REP-103. z is opposite gravity. The origin and the yaw are fixed when the session starts |
| `<name>_link` | The reference frame fixed to the device. The origin is the optical center of the rear wide camera. x is the camera's viewing direction, pointing out from the back of the device |
| `<name>_color_optical_frame` | The origin is the same as `<name>_link`. z is the viewing direction, x is right in the image, and y is down in the image |
| `<name>_imu_link` | The Core Motion device frame itself. Holding the phone in portrait and looking at the screen, x is right, y is up, and z is toward the viewer |
| `<name>_anchor_<image name>` | A frame fixed to a reference image. The origin is the center of the image. z is the normal of the image plane, pointing out of the front face toward the viewer. x is up in the image, and y is left in the image |

y (left) and z (up) of `<name>_link` are defined for landscape orientation, with the camera cluster at the top.
Mount the device in portrait and `<name>_link` is published rotated 90° about the forward axis.
That rotation belongs in the mount transform owned by the robot's URDF.

### Image orientation

Pixels of RGB, depth, and confidence are sent in the sensor's native order, independent of how the device is held and of the screen orientation.
That order is upright in landscape, with the camera cluster at the top.
Used in portrait, the image in a visualizer appears rotated by 90°.
`camera_info` and `<name>_color_optical_frame` are defined against this pixel order.
JPEGs do not carry an EXIF orientation.

Making the image upright for a person is the display's job.
Lichtblick and Foxglove have Rotation in the Image panel settings. On ROS 2, `image_rotate` does the same.

### Static transforms

`/tf_static` carries these two transforms.

| Parent | Child | Rotation (roll, pitch, yaw) | Translation |
| --- | --- | --- | --- |
| `<name>_link` | `<name>_color_optical_frame` | (-π/2, 0, -π/2) | 0 |
| `<name>_link` | `<name>_imu_link` | (0, -π/2, 0) | 0 (not measured) |

The translation between the camera and the IMU is not measured, so it is 0, and `calibrated` in `device_info` is false.

## Converting an ARKit pose

The ARKit world is right-handed, with y up, and aligned to gravity.
The camera looks along -z, with +x right and +y up.
The only difference from REP-103 is which axis is which, so the conversion is a single rotation matrix.

```
        |  0   0  -1 |      x_odom (forward) = -z_arkit
    R = | -1   0   0 |      y_odom (left)    = -x_arkit
        |  0   1   0 |      z_odom (up)      = +y_arkit

    p_odom       = R * p_arkit
    R_odom_link  = R * R_arkit_camera * R^T
```

A reference-image anchor uses the same conversion.
An ARKit anchor frame has x to the right in the image, y along the image normal, and z down in the image.
After the conversion, x is up in the image, y is left in the image, and z is the normal.
On an image stuck to a wall, z points from the wall into the room.

World yaw comes from `.gravity`, so it is not referenced to north.

## Images and intrinsics

- Pixel coordinates take the center of the top-left pixel as the origin. ARKit intrinsics and OpenCV use the same convention
- `k` and `p` in `camera_info` are the values for the resolution of the image that is sent, and `width` and `height` are rewritten to match. `binning` and `roi` are not used
- ARKit does not report lens-distortion coefficients. `distortion_model` is `plumb_bob`, and `d` is five zeros
- `camera_info` is sent on every frame, at the same time as the image

### Rescaling intrinsics

Let sx be the horizontal scale and sy the vertical scale.
Depth intrinsics are computed from the RGB-resolution values with this formula.

```
    fx' = fx * sx                   cx' = (cx + 0.5) * sx - 0.5
    fy' = fy * sy                   cy' = (cy + 0.5) * sy - 0.5
```

The 0.5 added to the principal point before scaling is there because the origin is the center of a pixel.

## Unit conversions

| Quantity | Apple's value | Published value | Conversion |
| --- | --- | --- | --- |
| Acceleration | g. At rest with the screen facing up, z is -1 | Specific force in m/s². At rest with z up, +g | Multiply by -9.80665 |
| Angular velocity | rad/s | rad/s | None |
| Magnetic field | µT | T | Multiply by 1e-6 |
| Pressure | kPa | Pa | Multiply by 1000 |
| Latitude and longitude | degrees (WGS 84) | degrees | None |
| Altitude | `ellipsoidalAltitude` (meters above the WGS 84 ellipsoid) | m | None |
| Horizontal and vertical accuracy | A radius and 1σ, in meters | Variance, in m² | Square it and place it on the diagonal |
| Course | True north is 0°, clockwise | East is 0 rad, counter-clockwise | Subtract the value, converted to radians, from π/2 |
| Depth | meters, as `Float32` | millimeters, as `uint16` | Multiply by 1000 and round |
| Battery level | 0 to 1 | 0 to 1 | None |

### Acceleration

The acceleration in `imu/data_raw` is the `CMAccelerometerData` value multiplied by -9.80665.
The acceleration in `imu/data` is `userAcceleration` plus `gravity` from `CMDeviceMotion`, then multiplied by the same factor.
Both include gravity, as REP-145 requires.

`imu/data_raw` has no orientation, so the first element of `orientation_covariance` is -1.

### Magnetometer

`imu/mag` carries the calibrated value from `CMDeviceMotion`.
Calibration accuracy (uncalibrated, low, medium, high) is reported in `/diagnostics`. While accuracy is uncalibrated, `imu/mag` is not published.

### GNSS

- Altitude uses `ellipsoidalAltitude`. `altitude` is height above sea level, which is a different datum from the height above the ellipsoid that `NavSatFix` asks for
- `position_covariance` places the squared accuracies on the diagonal, in East, North, Up order. `position_covariance_type` is `APPROXIMATED`
- A negative `horizontalAccuracy` means the fix is invalid. `status` is `STATUS_NO_FIX`, and latitude, longitude, and altitude are NaN
- If only `verticalAccuracy` is negative, only the altitude is NaN
- The API does not identify the satellite system, so `service` is 0
- The system time of the fix goes into `time_ref` of `gnss/time_reference`. How `header.stamp` is handled is described in [time.md](time.md)

### Depth

Invalid pixels are 0.
An ARKit depth sample that is NaN, less than or equal to 0, or greater than or equal to 65.535 m is treated as invalid.
The app does not threshold on confidence. The client decides, using `depth/confidence`.

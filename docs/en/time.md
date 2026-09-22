**English** | [日本語](../time.md)

# Timestamps and clock synchronization

pocketsensor stamps each message with the time at which the sensor took the measurement.
A client estimates the offset between the iPhone clock and its own clock, then converts the measurement time onto its own clock.

## The clock on the iPhone

The iPhone app uses a clock in the `mach_absolute_time` family as its time base.
It is a monotonic clock that advances from device boot. Sample times from ARKit and Core Motion arrive on this same clock.

The app self-checks the clock when a session starts.
It measures the difference between `CACurrentMediaTime()` at the moment a sample arrives and the timestamp of that sample.
If the difference is outside the range from 0 seconds to 0.5 seconds, it warns through `pocketsensor/clock` in `/diagnostics`.

## Message timestamps

The time attached to a message (`t_wire`) is the monotonic-clock value plus an offset computed once, when the session starts.

```
    anchor = system time (at start) - monotonic clock (at start)
    t_wire = t_sensor + anchor                     nanoseconds, in the form of a UNIX time
```

`anchor` does not change during the session.
If NTP steps the iPhone system clock while the session is running, `t_wire` does not jump. It keeps advancing at the rate of the monotonic clock.

The same `t_wire` is written both to the time in the Foxglove Message Data and to `header.stamp`.
The value of `anchor`, and the time at which it was computed, go into `clock` in `device_info`.

### Time source for each sensor

| Data | Time it is based on | Notes |
| --- | --- | --- |
| Pose, RGB, depth, confidence, `camera_info`, `tracking` | `ARFrame.timestamp` | Anything built from the same frame gets the same value |
| Reference-image anchor | `timestamp` of the `ARFrame` that contains the anchor update | |
| IMU, magnetometer, barometer | `CMLogItem.timestamp` | |
| GNSS | `CLLocation.timestamp`, converted onto the monotonic clock | The conversion is below |
| Battery, `/diagnostics` | `CACurrentMediaTime()` at the moment the value is read | These values have no measurement time of their own |

`CLLocation.timestamp` is a system time, so it is converted onto the monotonic clock as follows.

```
    t_sensor = monotonic clock (now) - (system time (now) - CLLocation.timestamp)
```

The system time of the fix itself is streamed separately as `time_ref` on `gnss/time_reference`.

## Clock synchronization

The same four-timestamp round trip used by NTP is expressed as one services call.

```
    Client                            iPhone
      | -- ClockSync(t1) ---------> |   t2: time the request was received
      | <-------- (t1, t2, t3) ---- |   t3: time just before the response is sent
      t4: time the response was received

    rtt    = (t4 - t1) - (t3 - t2)
    offset = ((t2 - t1) + (t3 - t4)) / 2        iPhone clock - client clock
```

`t1` and `t4` are on the client clock. `t2` and `t3` are measured on the same clock as `t_wire`.
If the outbound and return delays are equal, `offset` is exact. If they differ, half of that difference is the error.
A sample with a smaller `rtt` has a smaller upper bound on that error.

### The client's estimate

1. Call `ClockSync` once a second just after connecting, then every 5 seconds once the estimate has settled.
2. Among the latest 8 samples, take the `offset` of the one with the shortest `rtt` as the current estimate. If two samples have the same `rtt`, take the newer one.
3. Fit a line to the series of accepted samples and estimate the difference in clock rate (drift). The fit uses the Theil-Sen estimator, which resists outliers.

To convert a measurement time onto the client clock, start from the last accepted sample and advance the offset by the drift.

```
    (t_ref, offset_ref) = (midpoint of t1 and t4, offset) of the last accepted sample
    t_host = t_wire - (offset_ref + drift * ((t_wire - offset_ref) - t_ref))
```

Until three samples have been accepted, `drift` is 0.

There are two offset estimates: one for the client's monotonic clock, and one for system time.
SDK users use the monotonic clock. The ROS 2 relay uses system time (ROS time).

## Time domains the client exposes

The Python SDK returns three kinds of time for one piece of data.

| Kind | Meaning | When to use it |
| --- | --- | --- |
| `DEVICE` | `t_wire` unchanged | Align data from the same device. The time stored in a recording |
| `HOST_ARRIVAL` | The client clock at the moment the client received the message | Diagnose transport latency and jitter |
| `HOST` | `t_wire` minus the estimated `offset`, converted onto the client clock | Align with the robot's other sensors. Compensate for latency |

Until a clock-sync sample exists, `HOST` has no value.
`HOST_ARRIVAL` minus `HOST` is the latency from measurement to arrival.
The SDK returns this value on every frame.

The ROS 2 relay rewrites `header.stamp` to `HOST` (system time) before it publishes.

## Recording and playback

MCAP `log_time` stores `t_wire`.
Clock-sync samples (`t1` through `t4`) are also kept in the MCAP Metadata, so playback can recompute `HOST`.

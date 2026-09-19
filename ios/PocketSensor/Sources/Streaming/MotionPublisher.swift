import Foundation
import PocketSensorCore
import PocketSensorServer
import QuartzCore
import simd

/// 生 IMU、融合 IMU、地磁気、気圧。気圧は自己診断に入れない。
final class MotionPublisher: @unchecked Sendable {
    private let runtime: StreamingRuntime
    private var pairer = RawImuPairer()
    private var lastMagSent: Double?
    private let magMaxHz: Double

    init(runtime: StreamingRuntime) {
        self.runtime = runtime
        magMaxHz = Contract.channels.first { $0.key == "mag" }?.rateHz ?? 50
    }

    func handleAccel(_ sample: AccelSample) {
        guard !runtime.isStopped else { return }
        runtime.noteClock(accel: ClockSelfCheck.evaluate(
            sampleTimestampS: sample.timestamp,
            arrivalMonoS: CACurrentMediaTime()
        ))
        pairer.accel(timestampS: sample.timestamp, g: SIMD3(sample.x, sample.y, sample.z))
    }

    func handleGyro(_ sample: GyroSample) {
        guard !runtime.isStopped else { return }
        runtime.noteClock(gyro: ClockSelfCheck.evaluate(
            sampleTimestampS: sample.timestamp,
            arrivalMonoS: CACurrentMediaTime()
        ))
        guard runtime.server.hasSubscribers("imu_raw") else { return }
        guard let pair = pairer.gyro(timestampS: sample.timestamp, radS: SIMD3(sample.x, sample.y, sample.z)) else {
            return
        }
        let stampNs = runtime.anchor.wireTime(sensorSeconds: pair.timestampS)
        let names = runtime.names()
        runtime.server.publish(
            "imu_raw",
            stampNs: stampNs,
            payload: encodeCDR(MessageBuilders.imuRaw(
                stampNs: stampNs,
                names: names,
                accelG: pair.accelG,
                gyroRadS: pair.gyro
            ))
        )
    }

    func handleDeviceMotion(_ sample: DeviceMotionSample) {
        guard !runtime.isStopped else { return }
        runtime.noteClock(motion: ClockSelfCheck.evaluate(
            sampleTimestampS: sample.timestamp,
            arrivalMonoS: CACurrentMediaTime()
        ))
        let mag = MagCalibration.fromAccuracyRaw(sample.magneticFieldAccuracy)
        runtime.setMagCalibration(mag)
        let rates = runtime.rates()
        let stampNs = runtime.anchor.wireTime(sensorSeconds: sample.timestamp)
        let names = FrameNames(deviceName: rates.name)
        if runtime.server.hasSubscribers("imu") {
            runtime.server.publish(
                "imu",
                stampNs: stampNs,
                payload: encodeCDR(MessageBuilders.imuFused(
                    stampNs: stampNs,
                    names: names,
                    attitudeDeviceToReference: StreamingMap.attitudeDeviceToReference(
                        x: sample.attitudeX,
                        y: sample.attitudeY,
                        z: sample.attitudeZ,
                        w: sample.attitudeW
                    ),
                    reference: rates.reference,
                    userAccelG: SIMD3(sample.userAccelerationX, sample.userAccelerationY, sample.userAccelerationZ),
                    gravityG: SIMD3(sample.gravityX, sample.gravityY, sample.gravityZ),
                    rotationRateRadS: SIMD3(sample.rotationRateX, sample.rotationRateY, sample.rotationRateZ)
                ))
            )
        }
        if mag != .uncalibrated,
           runtime.server.hasSubscribers("mag"),
           StreamingMap.shouldSend(lastSent: lastMagSent, now: sample.timestamp, maxHz: magMaxHz)
        {
            lastMagSent = sample.timestamp
            runtime.server.publish(
                "mag",
                stampNs: stampNs,
                payload: encodeCDR(MessageBuilders.magneticField(
                    stampNs: stampNs,
                    names: names,
                    microTesla: SIMD3(sample.magneticFieldX, sample.magneticFieldY, sample.magneticFieldZ)
                ))
            )
        }
    }

    func handleAltimeter(_ sample: AltimeterSample) {
        guard !runtime.isStopped else { return }
        guard runtime.server.hasSubscribers("pressure") else { return }
        // 気圧は計測から 1.6 s 以上遅れて届くので、到着時刻ではなく標本の timestamp を使う。
        let stampNs = runtime.anchor.wireTime(sensorSeconds: sample.timestamp)
        let names = runtime.names()
        runtime.server.publish(
            "pressure",
            stampNs: stampNs,
            payload: encodeCDR(MessageBuilders.fluidPressure(stampNs: stampNs, names: names, kPa: sample.pressure))
        )
    }
}

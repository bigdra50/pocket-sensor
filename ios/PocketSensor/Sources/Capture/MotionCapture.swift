import CoreMotion
import Foundation

/// 加速度計の 1 サンプル。単位は G。符号は Core Motion のまま。
struct AccelSample {
    var timestamp: TimeInterval
    var x: Double
    var y: Double
    var z: Double
}

/// ジャイロの 1 サンプル。単位は rad/s。
struct GyroSample {
    var timestamp: TimeInterval
    var x: Double
    var y: Double
    var z: Double
}

/// `CMDeviceMotion` の 1 サンプル。四元数の向きは Core Motion が返した x, y, z, w のまま。
struct DeviceMotionSample {
    var timestamp: TimeInterval
    var attitudeX: Double
    var attitudeY: Double
    var attitudeZ: Double
    var attitudeW: Double
    var gravityX: Double
    var gravityY: Double
    var gravityZ: Double
    var userAccelerationX: Double
    var userAccelerationY: Double
    var userAccelerationZ: Double
    var rotationRateX: Double
    var rotationRateY: Double
    var rotationRateZ: Double
    var magneticFieldX: Double
    var magneticFieldY: Double
    var magneticFieldZ: Double
    /// `CMMagneticFieldCalibrationAccuracy` の生値（-1 / 0 / 1 / 2）
    var magneticFieldAccuracy: Int32
}

/// 気圧計の 1 サンプル。気圧は kPa、相対高度は m。
struct AltimeterSample {
    var timestamp: TimeInterval
    var pressure: Double
    var relativeAltitude: Double
}

/// アプリにつき `CMMotionManager` は 1 個。単位変換はしない。
final class MotionCapture {
    private let motion = CMMotionManager()
    private let altimeter = CMAltimeter()
    private let opQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "pocketsensor.motion"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private let accelHandlers = HandlerList<AccelSample>()
    private let gyroHandlers = HandlerList<GyroSample>()
    private let motionHandlers = HandlerList<DeviceMotionSample>()
    private let altimeterHandlers = HandlerList<AltimeterSample>()
    private let lock = NSLock()
    private var running = false

    func onAccel(_ handler: @escaping (AccelSample) -> Void) {
        accelHandlers.add(handler)
    }

    func onGyro(_ handler: @escaping (GyroSample) -> Void) {
        gyroHandlers.add(handler)
    }

    func onDeviceMotion(_ handler: @escaping (DeviceMotionSample) -> Void) {
        motionHandlers.add(handler)
    }

    func onAltimeter(_ handler: @escaping (AltimeterSample) -> Void) {
        altimeterHandlers.add(handler)
    }

    func start(rateHz: Double, referenceFrame: CMAttitudeReferenceFrame) {
        stop()
        let interval = rateHz > 0 ? 1.0 / rateHz : 0.01
        lock.lock()
        running = true
        lock.unlock()

        motion.accelerometerUpdateInterval = interval
        motion.gyroUpdateInterval = interval
        motion.deviceMotionUpdateInterval = interval

        if motion.isAccelerometerAvailable {
            motion.startAccelerometerUpdates(to: opQueue) { [weak self] data, _ in
                guard let self, self.isRunning, let data else { return }
                self.accelHandlers.emit(
                    AccelSample(timestamp: data.timestamp, x: data.acceleration.x, y: data.acceleration.y, z: data.acceleration.z)
                )
            }
        }
        if motion.isGyroAvailable {
            motion.startGyroUpdates(to: opQueue) { [weak self] data, _ in
                guard let self, self.isRunning, let data else { return }
                self.gyroHandlers.emit(
                    GyroSample(timestamp: data.timestamp, x: data.rotationRate.x, y: data.rotationRate.y, z: data.rotationRate.z)
                )
            }
        }
        if motion.isDeviceMotionAvailable {
            motion.startDeviceMotionUpdates(using: referenceFrame, to: opQueue) { [weak self] data, _ in
                guard let self, self.isRunning, let data else { return }
                let q = data.attitude.quaternion
                let g = data.gravity
                let ua = data.userAcceleration
                let rr = data.rotationRate
                let mag = data.magneticField
                self.motionHandlers.emit(
                    DeviceMotionSample(
                        timestamp: data.timestamp,
                        attitudeX: q.x,
                        attitudeY: q.y,
                        attitudeZ: q.z,
                        attitudeW: q.w,
                        gravityX: g.x,
                        gravityY: g.y,
                        gravityZ: g.z,
                        userAccelerationX: ua.x,
                        userAccelerationY: ua.y,
                        userAccelerationZ: ua.z,
                        rotationRateX: rr.x,
                        rotationRateY: rr.y,
                        rotationRateZ: rr.z,
                        magneticFieldX: mag.field.x,
                        magneticFieldY: mag.field.y,
                        magneticFieldZ: mag.field.z,
                        magneticFieldAccuracy: mag.accuracy.rawValue
                    )
                )
            }
        }
        if CMAltimeter.isRelativeAltitudeAvailable() {
            altimeter.startRelativeAltitudeUpdates(to: opQueue) { [weak self] data, _ in
                guard let self, self.isRunning, let data else { return }
                self.altimeterHandlers.emit(
                    AltimeterSample(
                        timestamp: data.timestamp,
                        pressure: data.pressure.doubleValue,
                        relativeAltitude: data.relativeAltitude.doubleValue
                    )
                )
            }
        }
    }

    func stop() {
        lock.lock()
        running = false
        lock.unlock()
        motion.stopAccelerometerUpdates()
        motion.stopGyroUpdates()
        motion.stopDeviceMotionUpdates()
        if CMAltimeter.isRelativeAltitudeAvailable() {
            altimeter.stopRelativeAltitudeUpdates()
        }
    }

    private var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }
}

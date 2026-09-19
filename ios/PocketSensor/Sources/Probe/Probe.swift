import CoreMotion
import CoreVideo
import Darwin
import Foundation
import QuartzCore
import simd
import UIKit

/// 実機で Apple が文書化していない時計とレートを測る。
/// capture の中身は変えず、callback を購読して印刷だけ間引く。12 秒で打ち切り、アプリは終了しない。
final class Probe {
    private let arkit: ARKitCapture
    private let motion: MotionCapture
    private let battery: BatteryCapture
    private let thermal: ThermalMonitor
    private let queue = DispatchQueue(label: "pocketsensor.probe")
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = []
        // NaN / Inf を黙って落とさず、JSON 上で印にする
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )
        return encoder
    }()

    private var printing = true
    private var rateTimer: DispatchSourceTimer?
    private var windowStart: CFTimeInterval = 0
    private var accelCount = 0
    private var gyroCount = 0
    private var motionCount = 0
    private var arframeCount = 0
    private var lastArframePrint: CFTimeInterval?
    private var lastCameraPrint: CFTimeInterval?
    private var lastAccelPrint: CFTimeInterval?
    private var lastGyroPrint: CFTimeInterval?
    private var lastMotionPrint: CFTimeInterval?

    init(arkit: ARKitCapture, motion: MotionCapture, battery: BatteryCapture, thermal: ThermalMonitor) {
        self.arkit = arkit
        self.motion = motion
        self.battery = battery
        self.thermal = thermal
    }

    /// callback を購読し、12 秒の印刷を始める。センサーの start は AppController が一度だけ行う。
    func start() {
        arkit.onFrame { [weak self] sample in
            self?.handleARFrame(sample)
        }
        motion.onAccel { [weak self] sample in
            self?.handleAccel(sample)
        }
        motion.onGyro { [weak self] sample in
            self?.handleGyro(sample)
        }
        motion.onDeviceMotion { [weak self] sample in
            self?.handleMotion(sample)
        }
        motion.onAltimeter { [weak self] sample in
            self?.handleAltimeter(sample)
        }
        battery.onSample { [weak self] sample in
            self?.handleBattery(sample)
        }

        emitDevice()
        emitClocks()
        windowStart = CACurrentMediaTime()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            self?.emitRates()
        }
        timer.resume()
        rateTimer = timer

        queue.asyncAfter(deadline: .now() + 12) { [weak self] in
            self?.finish()
        }
    }

    private func finish() {
        guard printing else { return }
        emitClocks()
        emit(DoneLine(media_time: CACurrentMediaTime()))
        printing = false
        rateTimer?.cancel()
        rateTimer = nil
    }

    private func handleARFrame(_ sample: ARFrameSample) {
        let mediaTime = CACurrentMediaTime()
        let tracking = ARKitCapture.trackingLabel(sample.trackingState)
        let camera = CameraSnapshot(sample)
        queue.async { [weak self] in
            guard let self, self.printing else { return }
            self.arframeCount += 1
            let printAr = sample.index <= 10 || self.allow(&self.lastArframePrint, now: mediaTime, hz: 2)
            if printAr {
                self.emit(
                    ArFrameLine(
                        media_time: mediaTime,
                        index: sample.index,
                        frame_timestamp: sample.timestamp,
                        delta_media: mediaTime - sample.timestamp,
                        tracking: tracking
                    )
                )
            }
            if self.allow(&self.lastCameraPrint, now: mediaTime, hz: 2) {
                self.emit(
                    CameraLine(
                        media_time: mediaTime,
                        index: sample.index,
                        transform_colmajor: camera.transform,
                        intrinsics_colmajor: camera.intrinsics,
                        image_resolution: camera.imageResolution,
                        captured_pixel_format: camera.capturedPixelFormat,
                        depth_size: camera.depthSize,
                        depth_pixel_format: camera.depthPixelFormat,
                        depth_bytes_per_row: camera.depthBytesPerRow,
                        confidence_size: camera.confidenceSize,
                        confidence_pixel_format: camera.confidencePixelFormat,
                        depth_center_m: camera.depthCenterM
                    )
                )
            }
        }
    }

    private func handleAccel(_ sample: AccelSample) {
        let mediaTime = CACurrentMediaTime()
        queue.async { [weak self] in
            guard let self, self.printing else { return }
            self.accelCount += 1
            guard self.allow(&self.lastAccelPrint, now: mediaTime, hz: 5) else { return }
            self.emit(
                AccelLine(
                    media_time: mediaTime,
                    timestamp: sample.timestamp,
                    delta_media: mediaTime - sample.timestamp,
                    g: [sample.x, sample.y, sample.z]
                )
            )
        }
    }

    private func handleGyro(_ sample: GyroSample) {
        let mediaTime = CACurrentMediaTime()
        queue.async { [weak self] in
            guard let self, self.printing else { return }
            self.gyroCount += 1
            guard self.allow(&self.lastGyroPrint, now: mediaTime, hz: 5) else { return }
            self.emit(
                GyroLine(
                    media_time: mediaTime,
                    timestamp: sample.timestamp,
                    delta_media: mediaTime - sample.timestamp,
                    rad_s: [sample.x, sample.y, sample.z]
                )
            )
        }
    }

    private func handleMotion(_ sample: DeviceMotionSample) {
        let mediaTime = CACurrentMediaTime()
        queue.async { [weak self] in
            guard let self, self.printing else { return }
            self.motionCount += 1
            guard self.allow(&self.lastMotionPrint, now: mediaTime, hz: 5) else { return }
            self.emit(
                MotionLine(
                    media_time: mediaTime,
                    timestamp: sample.timestamp,
                    delta_media: mediaTime - sample.timestamp,
                    attitude_xyzw: [sample.attitudeX, sample.attitudeY, sample.attitudeZ, sample.attitudeW],
                    gravity_g: [sample.gravityX, sample.gravityY, sample.gravityZ],
                    user_accel_g: [sample.userAccelerationX, sample.userAccelerationY, sample.userAccelerationZ],
                    rotation_rate: [sample.rotationRateX, sample.rotationRateY, sample.rotationRateZ],
                    mag_ut: [sample.magneticFieldX, sample.magneticFieldY, sample.magneticFieldZ],
                    mag_accuracy: sample.magneticFieldAccuracy,
                    reference_frame: "xArbitraryCorrectedZVertical"
                )
            )
        }
    }

    private func handleAltimeter(_ sample: AltimeterSample) {
        let mediaTime = CACurrentMediaTime()
        queue.async { [weak self] in
            guard let self, self.printing else { return }
            self.emit(
                AltimeterLine(
                    media_time: mediaTime,
                    timestamp: sample.timestamp,
                    delta_media: mediaTime - sample.timestamp,
                    pressure_kpa: sample.pressure,
                    relative_altitude_m: sample.relativeAltitude
                )
            )
        }
    }

    private func handleBattery(_ sample: BatterySample) {
        let mediaTime = CACurrentMediaTime()
        let thermalState = thermal.current.wireName
        queue.async { [weak self] in
            guard let self, self.printing else { return }
            self.emit(
                BatteryLine(media_time: mediaTime, level: Double(sample.level), state: sample.state.wireName)
            )
            self.emit(ThermalLine(media_time: mediaTime, state: thermalState))
        }
    }

    private func emitRates() {
        guard printing else { return }
        let now = CACurrentMediaTime()
        let dt = now - windowStart
        guard dt > 0 else { return }
        emit(
            RatesLine(
                media_time: now,
                accel_hz: Double(accelCount) / dt,
                gyro_hz: Double(gyroCount) / dt,
                motion_hz: Double(motionCount) / dt,
                arframe_hz: Double(arframeCount) / dt
            )
        )
        accelCount = 0
        gyroCount = 0
        motionCount = 0
        arframeCount = 0
        windowStart = now
    }

    private func emitDevice() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        emit(
            DeviceLine(
                media_time: CACurrentMediaTime(),
                model: Self.deviceModel,
                os_version: UIDevice.current.systemVersion,
                app_version: version
            )
        )
    }

    private func emitClocks() {
        emit(
            ClocksLine(
                media_time: CACurrentMediaTime(),
                system_uptime: ProcessInfo.processInfo.systemUptime,
                mach_absolute_s: Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000,
                mach_continuous_s: Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000,
                wall_unix_s: Date().timeIntervalSince1970
            )
        )
    }

    private func allow(_ last: inout CFTimeInterval?, now: CFTimeInterval, hz: Double) -> Bool {
        if let last, now - last < 1.0 / hz { return false }
        last = now
        return true
    }

    private func emit<T: Encodable>(_ row: T) {
        do {
            let data = try encoder.encode(row)
            guard let line = String(data: data, encoding: .utf8) else {
                emitEncodeFailure("utf8 conversion failed")
                return
            }
            print(line)
            fflush(stdout)
        } catch {
            emitEncodeFailure(String(describing: error))
        }
    }

    private func emitEncodeFailure(_ message: String) {
        let payload: [String: Any] = [
            "probe": "encode_error",
            "media_time": CACurrentMediaTime(),
            "error": message,
        ]
        if JSONSerialization.isValidJSONObject(payload),
           let data = try? JSONSerialization.data(withJSONObject: payload),
           let line = String(data: data, encoding: .utf8)
        {
            print(line)
        } else {
            print("{\"probe\":\"encode_error\",\"error\":\"unprintable\"}")
        }
        fflush(stdout)
    }

    /// "iPhone17,1" のような機種識別子
    static var deviceModel: String {
        var system = utsname()
        uname(&system)
        return withUnsafePointer(to: &system.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) { String(cString: $0) }
        }
    }
}

private struct CameraSnapshot {
    var transform: [Double]
    var intrinsics: [Double]
    var imageResolution: [Int]
    var capturedPixelFormat: String
    var depthSize: [Int]?
    var depthPixelFormat: String?
    var depthBytesPerRow: Int?
    var confidenceSize: [Int]?
    var confidencePixelFormat: String?
    var depthCenterM: Double?

    init(_ sample: ARFrameSample) {
        transform = Self.colMajor4(sample.cameraTransform)
        intrinsics = Self.colMajor3(sample.intrinsics)
        imageResolution = [Int(sample.imageResolution.width.rounded()), Int(sample.imageResolution.height.rounded())]
        capturedPixelFormat = Self.fourCC(CVPixelBufferGetPixelFormatType(sample.capturedImage))
        if let depth = sample.depthMap {
            depthSize = [CVPixelBufferGetWidth(depth), CVPixelBufferGetHeight(depth)]
            depthPixelFormat = Self.fourCC(CVPixelBufferGetPixelFormatType(depth))
            depthBytesPerRow = CVPixelBufferGetBytesPerRow(depth)
            depthCenterM = Self.centerPixelMeters(depth)
        }
        if let confidence = sample.confidenceMap {
            confidenceSize = [CVPixelBufferGetWidth(confidence), CVPixelBufferGetHeight(confidence)]
            confidencePixelFormat = Self.fourCC(CVPixelBufferGetPixelFormatType(confidence))
        }
    }

    static func colMajor4(_ m: simd_float4x4) -> [Double] {
        let c = m.columns
        return [c.0, c.1, c.2, c.3].flatMap { col in [Double(col.x), Double(col.y), Double(col.z), Double(col.w)] }
    }

    static func colMajor3(_ m: simd_float3x3) -> [Double] {
        let c = m.columns
        return [c.0, c.1, c.2].flatMap { col in [Double(col.x), Double(col.y), Double(col.z)] }
    }

    static func fourCC(_ type: OSType) -> String {
        let chars: [UInt8] = [
            UInt8((type >> 24) & 0xFF),
            UInt8((type >> 16) & 0xFF),
            UInt8((type >> 8) & 0xFF),
            UInt8(type & 0xFF),
        ]
        if chars.allSatisfy({ isprint(Int32($0)) != 0 }) {
            return String(bytes: chars, encoding: .ascii) ?? String(type)
        }
        return String(format: "0x%08x", type)
    }

    static func centerPixelMeters(_ buffer: CVPixelBuffer) -> Double? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_DepthFloat32 else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard width > 0, height > 0 else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let x = width / 2
        let y = height / 2
        let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: Float.self)
        let value = row[x]
        guard value.isFinite else { return nil }
        return Double(value)
    }
}

private struct DeviceLine: Encodable {
    let probe = "device"
    let media_time: Double
    let model: String
    let os_version: String
    let app_version: String
}

private struct ClocksLine: Encodable {
    let probe = "clocks"
    let media_time: Double
    let system_uptime: Double
    let mach_absolute_s: Double
    let mach_continuous_s: Double
    let wall_unix_s: Double
}

private struct ArFrameLine: Encodable {
    let probe = "arframe"
    let media_time: Double
    let index: UInt64
    let frame_timestamp: Double
    let delta_media: Double
    let tracking: String
}

private struct CameraLine: Encodable {
    let probe = "camera"
    let media_time: Double
    let index: UInt64
    let transform_colmajor: [Double]
    let intrinsics_colmajor: [Double]
    let image_resolution: [Int]
    let captured_pixel_format: String
    let depth_size: [Int]?
    let depth_pixel_format: String?
    let depth_bytes_per_row: Int?
    let confidence_size: [Int]?
    let confidence_pixel_format: String?
    let depth_center_m: Double?
}

private struct AccelLine: Encodable {
    let probe = "accel"
    let media_time: Double
    let timestamp: Double
    let delta_media: Double
    let g: [Double]
}

private struct GyroLine: Encodable {
    let probe = "gyro"
    let media_time: Double
    let timestamp: Double
    let delta_media: Double
    let rad_s: [Double]
}

private struct MotionLine: Encodable {
    let probe = "motion"
    let media_time: Double
    let timestamp: Double
    let delta_media: Double
    let attitude_xyzw: [Double]
    let gravity_g: [Double]
    let user_accel_g: [Double]
    let rotation_rate: [Double]
    let mag_ut: [Double]
    let mag_accuracy: Int32
    let reference_frame: String
}

private struct AltimeterLine: Encodable {
    let probe = "altimeter"
    let media_time: Double
    let timestamp: Double
    let delta_media: Double
    let pressure_kpa: Double
    let relative_altitude_m: Double
}

private struct RatesLine: Encodable {
    let probe = "rates"
    let media_time: Double
    let accel_hz: Double
    let gyro_hz: Double
    let motion_hz: Double
    let arframe_hz: Double
}

private struct BatteryLine: Encodable {
    let probe = "battery"
    let media_time: Double
    let level: Double
    let state: String
}

private struct ThermalLine: Encodable {
    let probe = "thermal"
    let media_time: Double
    let state: String
}

private struct DoneLine: Encodable {
    let probe = "done"
    let media_time: Double
}

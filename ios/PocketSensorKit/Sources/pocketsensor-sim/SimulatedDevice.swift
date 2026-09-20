import CoreVideo
import Darwin
import Foundation
import PocketSensorCore
import PocketSensorMedia
import PocketSensorServer
import simd

struct SimArgs {
    var port: UInt16 = 8765
    var name = "pocketsensor"
    var advertiseBonjour = true
    var duration: Double?
    var quiet = false
    var anchors: [String] = []
}

func usageAndExit(_ message: String) -> Never {
    fputs("\(message)\n", stderr)
    exit(2)
}

/// 画像名は frame 名の一部。英小文字、数字、下線。空は不可。
func isValidAnchorImageName(_ name: String) -> Bool {
    guard !name.isEmpty else { return false }
    return name.utf8.allSatisfy { byte in
        (0x61 ... 0x7A).contains(byte) || (0x30 ... 0x39).contains(byte) || byte == 0x5F
    }
}

func parseSimArgs(_ argv: [String]) -> SimArgs {
    var parsed = SimArgs()
    var index = 1
    while index < argv.count {
        let arg = argv[index]
        switch arg {
        case "--port":
            index += 1
            if index < argv.count, let value = UInt16(argv[index]) {
                parsed.port = value
            }
        case "--name":
            index += 1
            if index < argv.count {
                parsed.name = argv[index]
            }
        case "--no-bonjour":
            parsed.advertiseBonjour = false
        case "--duration":
            index += 1
            if index < argv.count, let value = Double(argv[index]) {
                parsed.duration = value
            }
        case "--quiet":
            parsed.quiet = true
        case "--anchor":
            index += 1
            guard index < argv.count else {
                usageAndExit("--anchor requires an image name")
            }
            let name = argv[index]
            guard isValidAnchorImageName(name) else {
                usageAndExit("invalid --anchor name \(name)")
            }
            parsed.anchors.append(name)
        default:
            fputs("unknown argument \(arg)\n", stderr)
        }
        index += 1
    }
    return parsed
}

func wallClockNs() -> Int64 {
    var ts = timespec()
    clock_gettime(CLOCK_REALTIME, &ts)
    return Int64(ts.tv_sec) * 1_000_000_000 + Int64(ts.tv_nsec)
}

func encodeCDR<T: CDREncodable>(_ value: T) -> Data {
    var encoder = CDREncoder()
    encoder.encode(value)
    return encoder.data
}

private struct SimRates {
    var pose: Double
    var color: Double
    var width: Double
    var quality: Double
    var depth: Double
    var imu: Double
    var reference: ImuReferenceFrame
    var name: String
    var epoch: UInt32
}

/// 実サーバー上でセンサー値を合成する。購読があるチャンネルだけエンコードする。
final class SimulatedDevice: @unchecked Sendable {
    private let server: FoxgloveServer
    private let anchor: ClockAnchor
    private let startMonoNs: Int64
    // arframeQueue: frameIndex, trackingState, depthBuffer, confidenceBuffer
    private let arframeQueue = DispatchQueue(label: "pocketsensor.sim.arframe")
    // imuQueue: IMU と mag のタイマーだけ。標本は毎 tick 出す。
    private let imuQueue = DispatchQueue(label: "pocketsensor.sim.imu", qos: .userInteractive)
    // slowQueue: pressure / GNSS / battery / diagnostics
    private let slowQueue = DispatchQueue(label: "pocketsensor.sim.slow", qos: .utility)
    // encodeQueue: jpeg, colorBuffer, lastBarCol
    private let encodeQueue = DispatchQueue(label: "pocketsensor.sim.encode", qos: .userInitiated)
    private let jpeg = JPEGEncoder()
    // lock: rates, originEpoch, deviceName, stopped, colorEncodeBusy, encodeSkipCount
    private let lock = NSLock()
    private var originEpoch: UInt32 = 0
    private var poseRate = 30.0
    private var colorRate = 15.0
    private var colorWidth = 960.0
    private var jpegQuality = 0.8
    private var depthRate = 15.0
    private var imuRate = 100.0
    private var imuReference = ImuReferenceFrame.arbitrary
    private var deviceName: String
    private var frameIndex: UInt64 = 0
    private var schedule = FrameSchedule()
    /// 擬似の ARFrame を作る周期（枚/秒）
    private static let arframeFps = 60.0
    private var timers: [DispatchSourceTimer] = []
    private var colorBuffer: CVPixelBuffer?
    private var depthBuffer: CVPixelBuffer?
    private var confidenceBuffer: CVPixelBuffer?
    private var trackingState = TrackingState.normal
    private var stopped = false
    private var colorEncodeBusy = false
    private var encodeSkipCount = 0
    private var lastBarCol = -1
    private var currentSessionId = ""
    private var anchorGate = AnchorGate()
    private let anchorNames: [String]

    init(server: FoxgloveServer, anchor: ClockAnchor, startMonoNs: Int64, deviceName: String, anchorNames: [String] = []) {
        self.server = server
        self.anchor = anchor
        self.startMonoNs = startMonoNs
        self.deviceName = deviceName
        self.anchorNames = anchorNames
        colorBuffer = makeBGRABuffer(width: 1920, height: 1440)
        depthBuffer = makeFloatBuffer(width: 256, height: 192, format: kCVPixelFormatType_DepthFloat32)
        confidenceBuffer = makeFloatBuffer(width: 256, height: 192, format: kCVPixelFormatType_OneComponent8)
        if let colorBuffer {
            paintColorGradient(colorBuffer)
        }
        if let depthBuffer {
            paintDepth(depthBuffer, frameIndex: 0)
        }
        if let confidenceBuffer {
            paintConfidence(confidenceBuffer)
        }
    }

    func start() {
        server.registerService("reset_origin") { [weak self] _, _ in
            guard let self else { return .failure(ServiceFailure(message: "stopped")) }
            self.lock.lock()
            self.originEpoch += 1
            self.lock.unlock()
            return .success(encodeCDR(StdSrvs.Trigger.Response(success: true, message: "ok")))
        }
        server.onParametersChange = { [weak self] changed in
            self?.apply(changed)
            self?.publishLatched()
        }
        publishLatched()
        startTimer(1.0 / Self.arframeFps, queue: arframeQueue, strict: false, leeway: .milliseconds(2)) { [weak self] in
            self?.tickARFrame()
        }
        startTimer(0.01, queue: imuQueue, strict: true, leeway: .milliseconds(1)) { [weak self] in
            self?.tickIMU()
        }
        startTimer(0.02, queue: imuQueue, strict: true, leeway: .milliseconds(1)) { [weak self] in
            self?.tickMag()
        }
        startTimer(1.0, queue: slowQueue, strict: false, leeway: .milliseconds(50)) { [weak self] in
            self?.tickSlow()
        }
    }

    func stop() {
        lock.lock()
        stopped = true
        let toCancel = timers
        timers.removeAll()
        lock.unlock()
        toCancel.forEach { $0.cancel() }
        server.stop()
    }

    private func startTimer(
        _ interval: Double,
        queue: DispatchQueue,
        strict: Bool,
        leeway: DispatchTimeInterval,
        handler: @escaping () -> Void
    ) {
        let timer: DispatchSourceTimer
        if strict {
            timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        } else {
            timer = DispatchSource.makeTimerSource(queue: queue)
        }
        timer.schedule(deadline: .now(), repeating: interval, leeway: leeway)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let done = self.stopped
            self.lock.unlock()
            guard !done else { return }
            handler()
        }
        timer.resume()
        lock.lock()
        timers.append(timer)
        lock.unlock()
    }

    private func apply(_ changed: [ParameterValue]) {
        lock.lock()
        defer { lock.unlock() }
        for item in changed {
            switch (item.name, item.value) {
            case ("pose.rate", .number(let value)): poseRate = value
            case ("color.rate", .number(let value)): colorRate = value
            case ("color.width", .number(let value)): colorWidth = value
            case ("color.jpeg_quality", .number(let value)): jpegQuality = value
            case ("depth.rate", .number(let value)): depthRate = value
            case ("imu.rate", .number(let value)): imuRate = value
            case ("imu.reference_frame", .string(let value)):
                imuReference = value == "true_north" ? .trueNorth : .arbitrary
            case ("device.name", .string(let value)): deviceName = value
            default: break
            }
        }
    }

    private func snapshotRates() -> SimRates {
        lock.lock()
        defer { lock.unlock() }
        return SimRates(
            pose: poseRate,
            color: colorRate,
            width: colorWidth,
            quality: jpegQuality,
            depth: depthRate,
            imu: imuRate,
            reference: imuReference,
            name: deviceName,
            epoch: originEpoch
        )
    }

    private func nowStamp() -> UInt64 {
        let mono = Int64(bitPattern: DispatchTime.now().uptimeNanoseconds)
        return anchor.wireTime(monoNs: mono)
    }

    private func tickARFrame() {
        let rates = snapshotRates()
        let index = frameIndex
        frameIndex += 1
        let stampNs = nowStamp()
        let names = FrameNames(deviceName: rates.name)
        // タイマーの揺れでレートがぶれないよう、フレームの時刻は通し番号から作る
        let due = schedule.next(
            timestamp: Double(index) / Self.arframeFps,
            poseHz: rates.pose,
            colorHz: rates.color,
            depthHz: rates.depth,
            thermal: .nominal
        )
        var items: [(String, Data)] = []

        let poseDue = due.pose
        let pose = PoseInput(
            cameraTransform: cameraOnCircle(frameIndex: index),
            state: trackingState,
            reason: .none,
            originEpoch: rates.epoch
        )
        if poseDue {
            if server.hasSubscribers("tracking") {
                items.append(("tracking", encodeCDR(MessageBuilders.tracking(stampNs: stampNs, names: names, pose: pose))))
            }
            if trackingState != .notAvailable, server.hasSubscribers("odom") {
                items.append(("odom", encodeCDR(MessageBuilders.odometry(stampNs: stampNs, names: names, pose: pose))))
            }
        }
        // アプリ（ARFramePublisher）と同じ組み立て。anchor は姿勢を送る回にだけ載せる。
        if poseDue, trackingState != .notAvailable, server.hasSubscribers("tf") {
            let atS = Double(stampNs) / 1_000_000_000.0
            let dueAnchors = anchorNames.enumerated()
                .filter { anchorGate.shouldSend(name: $0.element, isTracked: true, atS: atS) }
                .map { (imageName: $0.element, transform: fixedAnchorTransform(index: $0.offset)) }
            let message = MessageBuilders.tfWithAnchors(stampNs: stampNs, names: names, pose: pose, anchors: dueAnchors)
            items.append(("tf", encodeCDR(message)))
        }

        if due.color {
            scheduleColor(stampNs: stampNs, names: names, rates: rates, frameIndex: index)
        }
        if due.depth {
            appendDepth(stampNs: stampNs, names: names, frameIndex: index, items: &items)
        }
        guard !items.isEmpty else { return }
        server.publishBatch(group: "arframe", stampNs: stampNs, items: items)
    }

    private func scheduleColor(stampNs: UInt64, names: FrameNames, rates: SimRates, frameIndex: UInt64) {
        let wantImage = server.hasSubscribers("color_image")
        let wantInfo = server.hasSubscribers("color_camera_info")
        guard wantImage || wantInfo else { return }
        if !wantImage {
            let width = Int(rates.width)
            let height = Int((1440.0 * Double(width) / 1920.0).rounded())
            let colorK = sourceIntrinsics.scaled(toWidth: width, height: height)
            server.publishBatch(
                group: "arframe",
                stampNs: stampNs,
                items: [("color_camera_info", encodeCDR(MessageBuilders.cameraInfo(stampNs: stampNs, names: names, intrinsics: colorK)))]
            )
            return
        }
        lock.lock()
        if colorEncodeBusy {
            encodeSkipCount += 1
            lock.unlock()
            return
        }
        colorEncodeBusy = true
        lock.unlock()
        encodeQueue.async { [weak self] in
            self?.encodeColor(stampNs: stampNs, names: names, rates: rates, frameIndex: frameIndex, wantInfo: wantInfo)
        }
    }

    private func encodeColor(stampNs: UInt64, names: FrameNames, rates: SimRates, frameIndex: UInt64, wantInfo: Bool) {
        defer {
            lock.lock()
            colorEncodeBusy = false
            lock.unlock()
        }
        guard let buffer = colorBuffer else { return }
        paintColorBar(buffer, previousCol: &lastBarCol, frameIndex: frameIndex)
        let encoded = jpeg.encode(pixelBuffer: buffer, targetWidth: Int(rates.width), quality: rates.quality)
        let width = encoded?.width ?? Int(rates.width)
        let height = encoded?.height ?? Int((1440.0 * Double(width) / 1920.0).rounded())
        var items: [(String, Data)] = []
        if wantInfo {
            let colorK = sourceIntrinsics.scaled(toWidth: width, height: height)
            items.append(("color_camera_info", encodeCDR(MessageBuilders.cameraInfo(stampNs: stampNs, names: names, intrinsics: colorK))))
        }
        if let encoded {
            items.append(("color_image", encodeCDR(MessageBuilders.compressedImage(stampNs: stampNs, names: names, jpeg: encoded.data))))
        }
        guard !items.isEmpty else { return }
        server.publishBatch(group: "arframe", stampNs: stampNs, items: items)
    }

    private func appendDepth(
        stampNs: UInt64,
        names: FrameNames,
        frameIndex: UInt64,
        items: inout [(String, Data)]
    ) {
        let wantDepth = server.hasSubscribers("depth_image")
        let wantDepthPNG = server.hasSubscribers("depth_image_compressed")
        let wantConf = server.hasSubscribers("depth_confidence")
        let wantConfPNG = server.hasSubscribers("depth_confidence_compressed")
        let wantInfo = server.hasSubscribers("depth_camera_info")
        guard wantDepth || wantDepthPNG || wantConf || wantConfPNG || wantInfo else { return }
        let depthK = sourceIntrinsics.scaled(toWidth: 256, height: 192)
        if wantInfo {
            items.append(("depth_camera_info", encodeCDR(MessageBuilders.cameraInfo(stampNs: stampNs, names: names, intrinsics: depthK))))
        }
        if (wantDepth || wantDepthPNG), let buffer = depthBuffer {
            paintDepth(buffer, frameIndex: frameIndex)
            if let packed = DepthPacker.depth16(from: buffer) {
                if wantDepth {
                    items.append((
                        "depth_image",
                        encodeCDR(MessageBuilders.depthImage(
                            stampNs: stampNs,
                            names: names,
                            width: packed.width,
                            height: packed.height,
                            data: packed.data
                        ))
                    ))
                }
                if wantDepthPNG, let png = PNGEncoder.gray16(width: packed.width, height: packed.height, pixels: packed.data) {
                    items.append((
                        "depth_image_compressed",
                        encodeCDR(MessageBuilders.compressedDepth(stampNs: stampNs, names: names, png: png))
                    ))
                }
            }
        }
        if (wantConf || wantConfPNG), let buffer = confidenceBuffer {
            if let packed = DepthPacker.confidence8(from: buffer) {
                if wantConf {
                    items.append((
                        "depth_confidence",
                        encodeCDR(MessageBuilders.confidenceImage(
                            stampNs: stampNs,
                            names: names,
                            width: packed.width,
                            height: packed.height,
                            data: packed.data
                        ))
                    ))
                }
                if wantConfPNG, let png = PNGEncoder.gray8(width: packed.width, height: packed.height, pixels: packed.data) {
                    items.append((
                        "depth_confidence_compressed",
                        encodeCDR(MessageBuilders.compressedConfidence(stampNs: stampNs, names: names, png: png))
                    ))
                }
            }
        }
    }

    private func tickIMU() {
        let rates = snapshotRates()
        let wantRaw = server.hasSubscribers("imu_raw")
        let wantFused = server.hasSubscribers("imu")
        guard wantRaw || wantFused else { return }
        let stampNs = nowStamp()
        let names = FrameNames(deviceName: rates.name)
        let accel = SIMD3<Double>(0, 0, -1)
        let gyro = SIMD3<Double>(0, 0, 0.01)
        if wantRaw {
            server.publish(
                "imu_raw",
                stampNs: stampNs,
                payload: encodeCDR(MessageBuilders.imuRaw(stampNs: stampNs, names: names, accelG: accel, gyroRadS: gyro))
            )
        }
        if wantFused {
            server.publish(
                "imu",
                stampNs: stampNs,
                payload: encodeCDR(MessageBuilders.imuFused(
                    stampNs: stampNs,
                    names: names,
                    attitudeDeviceToReference: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1),
                    reference: rates.reference,
                    userAccelG: SIMD3(0, 0, 0),
                    gravityG: accel,
                    rotationRateRadS: gyro
                ))
            )
        }
    }

    private func tickMag() {
        guard server.hasSubscribers("mag") else { return }
        let rates = snapshotRates()
        let stampNs = nowStamp()
        let names = FrameNames(deviceName: rates.name)
        server.publish(
            "mag",
            stampNs: stampNs,
            payload: encodeCDR(MessageBuilders.magneticField(
                stampNs: stampNs,
                names: names,
                microTesla: SIMD3(20, 5, 40)
            ))
        )
    }

    private func tickSlow() {
        let rates = snapshotRates()
        let stampNs = nowStamp()
        let names = FrameNames(deviceName: rates.name)
        if server.hasSubscribers("pressure") {
            server.publish(
                "pressure",
                stampNs: stampNs,
                payload: encodeCDR(MessageBuilders.fluidPressure(stampNs: stampNs, names: names, kPa: 101.325))
            )
        }
        if server.hasSubscribers("gnss_fix") {
            server.publish(
                "gnss_fix",
                stampNs: stampNs,
                payload: encodeCDR(MessageBuilders.navSatFix(
                    stampNs: stampNs,
                    names: names,
                    latitude: 35,
                    longitude: 139,
                    ellipsoidalAltitude: 10,
                    horizontalAccuracy: 1,
                    verticalAccuracy: 2
                ))
            )
        }
        if server.hasSubscribers("gnss_time_reference") {
            server.publish(
                "gnss_time_reference",
                stampNs: stampNs,
                payload: encodeCDR(MessageBuilders.timeReference(
                    stampNs: stampNs,
                    wallTimeNs: UInt64(bitPattern: wallClockNs()),
                    source: "gnss"
                ))
            )
        }
        if server.hasSubscribers("battery") {
            server.publish(
                "battery",
                stampNs: stampNs,
                payload: encodeCDR(MessageBuilders.battery(stampNs: stampNs, level: 0.8, state: .discharging))
            )
        }
        if server.hasSubscribers("diagnostics") {
            let stats = server.stats()
            let nowS = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000.0
            var ratesHz: [String: Double] = [:]
            for (key, var meter) in stats.sentRateByChannelKey {
                ratesHz[key] = meter.hz(now: nowS)
            }
            let diag = Diagnostics.build(
                stampNs: stampNs,
                input: DiagnosticsInput(
                    deviceName: rates.name,
                    trackingState: trackingState,
                    trackingReason: .none,
                    thermal: .nominal,
                    clients: stats.clients,
                    ratesHz: ratesHz,
                    drops: stats.dropsByChannelKey,
                    encodeSkips: ["color": encodeSkipSnapshot()],
                    clock: .ok,
                    magCalibration: .high,
                    locationAuthorization: .authorized,
                    sensors: .allOn
                )
            )
            server.publish("diagnostics", stampNs: stampNs, payload: encodeCDR(diag))
        }
    }

    func publishLatched() {
        let rates = snapshotRates()
        let stampNs = nowStamp()
        let names = FrameNames(deviceName: rates.name)
        let info = DeviceInfo(
            sessionId: currentSessionId,
            name: rates.name,
            model: "pocketsensor-sim",
            osVersion: "macOS",
            appVersion: "0.1.0",
            streams: deviceStreams(names: names, rates: rates),
            clock: DeviceClock(
                anchorNs: anchor.anchorNs,
                anchoredAtWallNs: anchor.wallNs,
                selfCheck: .ok
            ),
            frames: DeviceFrames.standard(names: names)
        )
        server.setLatched("tf_static", stampNs: stampNs, payload: encodeCDR(MessageBuilders.tfStatic(stampNs: stampNs, names: names)))
        server.setLatched(
            "device_info",
            stampNs: stampNs,
            payload: encodeCDR(MessageBuilders.string(info.jsonString()))
        )
    }

    private func encodeSkipSnapshot() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return encodeSkipCount
    }

    func setSessionId(_ sessionId: String) {
        currentSessionId = sessionId
    }

    private func deviceStreams(names: FrameNames, rates: SimRates) -> [String: DeviceStream] {
        let colorW = Int(rates.width)
        let colorH = Int((1440.0 * Double(colorW) / 1920.0).rounded())
        return DeviceStream.all(
            names: names,
            settings: DeviceStreamSettings(
                rates: ["pose.rate": rates.pose, "color.rate": rates.color, "depth.rate": rates.depth, "imu.rate": rates.imu],
                colorWidth: colorW,
                colorHeight: colorH,
                depthWidth: 256,
                depthHeight: 192
            )
        )
    }
}

private let sourceIntrinsics = Intrinsics(width: 1920, height: 1440, fx: 1500, fy: 1500, cx: 960, cy: 720)

/// i 番目の参照画像。ARKit 座標で (0.5*i, 1, -2)、回転は単位。
private func fixedAnchorTransform(index: Int) -> simd_double4x4 {
    var transform = matrix_identity_double4x4
    transform.columns.3 = SIMD4(0.5 * Double(index), 1.0, -2.0, 1.0)
    return transform
}

private func cameraOnCircle(frameIndex: UInt64) -> simd_double4x4 {
    let theta = Double(frameIndex) * (2.0 * Double.pi / 1200.0)
    let c = cos(theta)
    let s = sin(theta)
    return simd_double4x4(columns: (
        SIMD4(-c, 0, -s, 0),
        SIMD4(0, 1, 0, 0),
        SIMD4(s, 0, -c, 0),
        SIMD4(c, 0, s, 1)
    ))
}

private func makeBGRABuffer(width: Int, height: Int) -> CVPixelBuffer? {
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
    guard status == kCVReturnSuccess else { return nil }
    return buffer
}

private func makeFloatBuffer(width: Int, height: Int, format: OSType) -> CVPixelBuffer? {
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, nil, &buffer)
    guard status == kCVReturnSuccess else { return nil }
    return buffer
}

private func paintColorGradient(_ buffer: CVPixelBuffer) {
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let width = CVPixelBufferGetWidth(buffer)
    let height = CVPixelBufferGetHeight(buffer)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
    for row in 0 ..< height {
        let rowPtr = base.advanced(by: row * bytesPerRow).assumingMemoryBound(to: UInt8.self)
        for col in 0 ..< width {
            let i = col * 4
            rowPtr[i] = UInt8(col * 255 / max(width - 1, 1))
            rowPtr[i + 1] = 80
            rowPtr[i + 2] = UInt8(row * 255 / max(height - 1, 1))
            rowPtr[i + 3] = 255
        }
    }
}

private func paintColorBar(_ buffer: CVPixelBuffer, previousCol: inout Int, frameIndex: UInt64) {
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let width = CVPixelBufferGetWidth(buffer)
    let height = CVPixelBufferGetHeight(buffer)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
    let bar = Int(frameIndex * 8) % max(width, 1)
    if previousCol >= 0 {
        fillGreen(base: base, bytesPerRow: bytesPerRow, height: height, width: width, col: previousCol, green: 80)
        fillGreen(base: base, bytesPerRow: bytesPerRow, height: height, width: width, col: previousCol + 1, green: 80)
    }
    fillGreen(base: base, bytesPerRow: bytesPerRow, height: height, width: width, col: bar, green: 255)
    fillGreen(base: base, bytesPerRow: bytesPerRow, height: height, width: width, col: bar + 1, green: 255)
    previousCol = bar
}

private func fillGreen(base: UnsafeMutableRawPointer, bytesPerRow: Int, height: Int, width: Int, col: Int, green: UInt8) {
    guard col >= 0, col < width else { return }
    for row in 0 ..< height {
        let pixel = base.advanced(by: row * bytesPerRow + col * 4).assumingMemoryBound(to: UInt8.self)
        pixel[1] = green
    }
}

private func paintDepth(_ buffer: CVPixelBuffer, frameIndex: UInt64) {
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let width = CVPixelBufferGetWidth(buffer)
    let height = CVPixelBufferGetHeight(buffer)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
    let distance = Float(1.5 + 0.4 * sin(Double(frameIndex) / 60.0))
    for row in 0 ..< height {
        for col in 0 ..< width {
            let value: Float = (row < 8 && col < 8) ? .nan : distance
            base.advanced(by: row * bytesPerRow + col * 4).storeBytes(of: value, as: Float.self)
        }
    }
}

private func paintConfidence(_ buffer: CVPixelBuffer) {
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let width = CVPixelBufferGetWidth(buffer)
    let height = CVPixelBufferGetHeight(buffer)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
    for row in 0 ..< height {
        let rowPtr = base.advanced(by: row * bytesPerRow).assumingMemoryBound(to: UInt8.self)
        for col in 0 ..< width {
            rowPtr[col] = (row < 8 && col < 8) ? 0 : 2
        }
    }
}

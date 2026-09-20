import CoreVideo
import Foundation
import PocketSensorCore
import PocketSensorMedia
import PocketSensorServer

/// 1 枚の ARFrame を同じ stampNs の publishBatch にする。JPEG だけ別キュー。
final class ARFramePublisher: @unchecked Sendable {
    private let runtime: StreamingRuntime
    private var gate = AnchorGate()
    /// ARKit の delegate queue からだけ触る
    private var schedule = FrameSchedule()
    private let gateLock = NSLock()

    init(runtime: StreamingRuntime) {
        self.runtime = runtime
    }

    func resetGates() {
        gateLock.lock()
        gate.reset()
        gateLock.unlock()
    }

    func publish(_ sample: ARFrameSample) {
        guard !runtime.isStopped else { return }
        runtime.noteClock(arframe: ClockSelfCheck.evaluate(
            sampleTimestampS: sample.timestamp,
            arrivalMonoS: sample.arrivalMediaTime
        ))
        let mapped = StreamingMap.tracking(sample.trackingState)
        runtime.setTracking(mapped)

        let srcW = max(1, Int(sample.imageResolution.width.rounded()))
        let srcH = max(1, Int(sample.imageResolution.height.rounded()))
        var depthW: Int?
        var depthH: Int?
        if let depth = sample.depthMap {
            depthW = CVPixelBufferGetWidth(depth)
            depthH = CVPixelBufferGetHeight(depth)
        }
        runtime.setSourceSize(colorWidth: srcW, colorHeight: srcH, depthWidth: depthW, depthHeight: depthH)

        let rates = runtime.rates()
        let stampNs = runtime.anchor.wireTime(sensorSeconds: sample.timestamp)
        let names = FrameNames(deviceName: rates.name)
        let due = schedule.next(
            timestamp: sample.timestamp,
            poseHz: rates.pose,
            colorHz: rates.color,
            depthHz: rates.depth,
            thermal: rates.thermal
        )
        let poseDue = due.pose
        let colorDue = due.color
        let depthDue = due.depth
        let trackingAvailable = mapped.state != .notAvailable
        let pose = PoseInput(
            cameraTransform: StreamingMap.poseMatrix(sample.cameraTransform),
            state: mapped.state,
            reason: mapped.reason,
            originEpoch: rates.epoch
        )

        var items: [(String, Data)] = []
        if poseDue {
            if runtime.server.hasSubscribers("tracking") {
                items.append(("tracking", encodeCDR(MessageBuilders.tracking(stampNs: stampNs, names: names, pose: pose))))
            }
            if trackingAvailable, runtime.server.hasSubscribers("odom") {
                items.append(("odom", encodeCDR(MessageBuilders.odometry(stampNs: stampNs, names: names, pose: pose))))
            }
        }

        // anchor は姿勢を送る回にだけ載せる。anchor の時刻が、odom のどれかの時刻と必ず一致する。
        if poseDue, trackingAvailable, runtime.server.hasSubscribers("tf") {
            gateLock.lock()
            let dueAnchors = sample.imageAnchors
                .filter { gate.shouldSend(name: $0.name, isTracked: $0.isTracked, atS: sample.timestamp) }
                .map { (imageName: $0.name, transform: StreamingMap.poseMatrix($0.transform)) }
            gateLock.unlock()
            let message = MessageBuilders.tfWithAnchors(stampNs: stampNs, names: names, pose: pose, anchors: dueAnchors)
            items.append(("tf", encodeCDR(message)))
        }

        if colorDue {
            scheduleColor(sample: sample, stampNs: stampNs, names: names, rates: rates, sourceWidth: srcW, sourceHeight: srcH)
        }
        if depthDue {
            appendDepth(sample: sample, stampNs: stampNs, names: names, sourceWidth: srcW, sourceHeight: srcH, items: &items)
        }
        guard !items.isEmpty else { return }
        runtime.server.publishBatch(group: "arframe", stampNs: stampNs, items: items)
    }

    private func scheduleColor(
        sample: ARFrameSample,
        stampNs: UInt64,
        names: FrameNames,
        rates: SessionRates,
        sourceWidth: Int,
        sourceHeight: Int
    ) {
        let wantImage = runtime.server.hasSubscribers("color_image")
        let wantInfo = runtime.server.hasSubscribers("color_camera_info")
        guard wantImage || wantInfo else { return }
        let colorK = StreamingMap.colorIntrinsics(matrix: sample.intrinsics, width: sourceWidth, height: sourceHeight)
        if !wantImage {
            let size = JPEGEncoder.targetSize(sourceWidth: sourceWidth, sourceHeight: sourceHeight, targetWidth: Int(rates.width))
            let width = size?.width ?? Int(rates.width)
            let height = size?.height ?? Int((Double(sourceHeight) * Double(width) / Double(max(sourceWidth, 1))).rounded())
            let scaled = colorK.scaled(toWidth: width, height: height)
            runtime.server.publishBatch(
                group: "arframe",
                stampNs: stampNs,
                items: [("color_camera_info", encodeCDR(MessageBuilders.cameraInfo(stampNs: stampNs, names: names, intrinsics: scaled)))]
            )
            return
        }
        guard runtime.beginColorEncode() else { return }
        let buffer = sample.capturedImage
        runtime.encodeQueue.async { [weak self] in
            self?.encodeColor(
                buffer: buffer,
                stampNs: stampNs,
                names: names,
                rates: rates,
                colorK: colorK,
                wantInfo: wantInfo
            )
        }
    }

    private func encodeColor(
        buffer: CVPixelBuffer,
        stampNs: UInt64,
        names: FrameNames,
        rates: SessionRates,
        colorK: Intrinsics,
        wantInfo: Bool
    ) {
        defer { runtime.endColorEncode() }
        guard !runtime.isStopped else { return }
        let encoded = runtime.jpeg.encode(pixelBuffer: buffer, targetWidth: Int(rates.width), quality: rates.quality)
        var items: [(String, Data)] = []
        let width = encoded?.width ?? Int(rates.width)
        let height = encoded?.height ?? Int((Double(colorK.height) * Double(width) / Double(max(colorK.width, 1))).rounded())
        if wantInfo {
            let scaled = colorK.scaled(toWidth: width, height: height)
            items.append(("color_camera_info", encodeCDR(MessageBuilders.cameraInfo(stampNs: stampNs, names: names, intrinsics: scaled))))
        }
        if let encoded {
            items.append(("color_image", encodeCDR(MessageBuilders.compressedImage(stampNs: stampNs, names: names, jpeg: encoded.data))))
        }
        guard !items.isEmpty else { return }
        runtime.server.publishBatch(group: "arframe", stampNs: stampNs, items: items)
    }

    private func appendDepth(
        sample: ARFrameSample,
        stampNs: UInt64,
        names: FrameNames,
        sourceWidth: Int,
        sourceHeight: Int,
        items: inout [(String, Data)]
    ) {
        let wantDepth = runtime.server.hasSubscribers("depth_image")
        let wantDepthPNG = runtime.server.hasSubscribers("depth_image_compressed")
        let wantConf = runtime.server.hasSubscribers("depth_confidence")
        let wantConfPNG = runtime.server.hasSubscribers("depth_confidence_compressed")
        let wantInfo = runtime.server.hasSubscribers("depth_camera_info")
        guard wantDepth || wantDepthPNG || wantConf || wantConfPNG || wantInfo else { return }
        let depthW = sample.depthMap.map { CVPixelBufferGetWidth($0) } ?? 0
        let depthH = sample.depthMap.map { CVPixelBufferGetHeight($0) } ?? 0
        guard depthW > 0, depthH > 0 else { return }
        if wantInfo {
            let colorK = StreamingMap.colorIntrinsics(matrix: sample.intrinsics, width: sourceWidth, height: sourceHeight)
            let depthK = colorK.scaled(toWidth: depthW, height: depthH)
            items.append(("depth_camera_info", encodeCDR(MessageBuilders.cameraInfo(stampNs: stampNs, names: names, intrinsics: depthK))))
        }
        if (wantDepth || wantDepthPNG), let buffer = sample.depthMap, let packed = DepthPacker.depth16(from: buffer) {
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
        if (wantConf || wantConfPNG), let buffer = sample.confidenceMap, let packed = DepthPacker.confidence8(from: buffer) {
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

import Darwin
import Foundation
import PocketSensorCore
import PocketSensorMedia
import PocketSensorServer
import QuartzCore
import UIKit

/// 電池、1 Hz の diagnostics、起動時と変更時の tf_static / device_info。
final class StatusPublisher: @unchecked Sendable {
    private let runtime: StreamingRuntime
    private let locationAuthorization: () -> LocationAuthorization
    private let queue = DispatchQueue(label: "pocketsensor.status", qos: .utility)
    private var timer: DispatchSourceTimer?

    init(runtime: StreamingRuntime, locationAuthorization: @escaping () -> LocationAuthorization) {
        self.runtime = runtime
        self.locationAuthorization = locationAuthorization
    }

    func start() {
        publishLatchedNow()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            self?.tickDiagnostics()
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    func publishBattery(_ sample: BatterySample) {
        guard !runtime.isStopped else { return }
        guard runtime.server.hasSubscribers("battery") else { return }
        let stampNs = runtime.nowStampNs()
        runtime.server.publish(
            "battery",
            stampNs: stampNs,
            payload: encodeCDR(MessageBuilders.battery(
                stampNs: stampNs,
                level: sample.level,
                state: StreamingMap.battery(sample.state)
            ))
        )
    }

    func scheduleLatched() {
        runtime.latchQueue.async { [weak self] in
            self?.publishLatchedNow()
        }
    }

    func publishLatchedNow() {
        guard !runtime.isStopped else { return }
        let rates = runtime.rates()
        let stampNs = runtime.nowStampNs()
        let names = FrameNames(deviceName: rates.name)
        runtime.server.setLatched(
            "tf_static",
            stampNs: stampNs,
            payload: encodeCDR(MessageBuilders.tfStatic(stampNs: stampNs, names: names))
        )
        let info = DeviceInfo(
            sessionId: runtime.sessionId,
            name: rates.name,
            model: DeviceIdentity.modelIdentifier,
            osVersion: UIDevice.current.systemVersion,
            appVersion: DeviceIdentity.appVersion,
            streams: deviceStreams(names: names, rates: rates),
            clock: DeviceClock(
                anchorNs: runtime.anchor.anchorNs,
                anchoredAtWallNs: runtime.anchor.wallNs,
                selfCheck: rates.clock
            ),
            frames: DeviceFrames.standard(names: names)
        )
        runtime.server.setLatched(
            "device_info",
            stampNs: stampNs,
            payload: encodeCDR(MessageBuilders.string(info.jsonString()))
        )
    }

    private func tickDiagnostics() {
        guard !runtime.isStopped else { return }
        guard runtime.server.hasSubscribers("diagnostics") else { return }
        let stats = runtime.server.stats()
        let nowS = CACurrentMediaTime()
        var ratesHz: [String: Double] = [:]
        for (key, var meter) in stats.sentRateByChannelKey {
            ratesHz[key] = meter.hz(now: nowS)
        }
        let rates = runtime.rates()
        let stampNs = runtime.nowStampNs()
        let diag = Diagnostics.build(
            stampNs: stampNs,
            input: DiagnosticsInput(
                deviceName: rates.name,
                trackingState: rates.trackingState,
                trackingReason: rates.trackingReason,
                thermal: rates.thermal,
                clients: stats.clients,
                ratesHz: ratesHz,
                drops: stats.dropsByChannelKey,
                encodeSkips: ["color": rates.encodeSkips],
                clock: rates.clock,
                magCalibration: rates.magCalibration,
                locationAuthorization: locationAuthorization()
            )
        )
        runtime.server.publish("diagnostics", stampNs: stampNs, payload: encodeCDR(diag))
    }

    private func deviceStreams(names: FrameNames, rates: SessionRates) -> [String: DeviceStream] {
        let colorSize = JPEGEncoder.targetSize(
            sourceWidth: rates.colorSourceWidth,
            sourceHeight: rates.colorSourceHeight,
            targetWidth: Int(rates.width)
        )
        let colorW = colorSize?.width ?? Int(rates.width)
        let colorH = colorSize?.height ?? Int(
            (Double(rates.colorSourceHeight) * Double(colorW) / Double(max(rates.colorSourceWidth, 1))).rounded()
        )
        func topic(_ key: String) -> String {
            names.topic(Contract.channels.first { $0.key == key }!)
        }
        return [
            "odom": DeviceStream(topic: topic("odom"), schema: "nav_msgs/msg/Odometry", rate: rates.pose),
            "tracking": DeviceStream(topic: topic("tracking"), schema: "pocketsensor_msgs/msg/TrackingStatus", rate: rates.pose),
            "color_image": DeviceStream(
                topic: topic("color_image"),
                schema: "sensor_msgs/msg/CompressedImage",
                width: colorW,
                height: colorH,
                encoding: "jpeg",
                rate: rates.color
            ),
            "depth_image": DeviceStream(
                topic: topic("depth_image"),
                schema: "sensor_msgs/msg/Image",
                width: rates.depthWidth,
                height: rates.depthHeight,
                encoding: "16UC1",
                rate: rates.depth
            ),
            "depth_image_compressed": DeviceStream(
                topic: topic("depth_image_compressed"),
                schema: "sensor_msgs/msg/CompressedImage",
                width: rates.depthWidth,
                height: rates.depthHeight,
                encoding: MessageBuilders.compressedDepthFormat,
                rate: rates.depth
            ),
            "depth_confidence_compressed": DeviceStream(
                topic: topic("depth_confidence_compressed"),
                schema: "sensor_msgs/msg/CompressedImage",
                width: rates.depthWidth,
                height: rates.depthHeight,
                encoding: MessageBuilders.compressedConfidenceFormat,
                rate: rates.depth
            ),
            "imu": DeviceStream(topic: topic("imu"), schema: "sensor_msgs/msg/Imu", rate: rates.imu),
        ]
    }
}

enum DeviceIdentity {
    /// "iPhone17,1" のような機種識別子
    static var modelIdentifier: String {
        var system = utsname()
        uname(&system)
        return withUnsafePointer(to: &system.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) { String(cString: $0) }
        }
    }

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }
}

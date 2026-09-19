import Foundation
import simd

public enum TrackingState: UInt8, Equatable, Sendable {
    case notAvailable = 0
    case limited = 1
    case normal = 2
}

public enum TrackingReason: UInt8, Equatable, Sendable {
    case none = 0
    case initializing = 1
    case excessiveMotion = 2
    case insufficientFeatures = 3
    case relocalizing = 4
}

public struct PoseInput: Equatable, Sendable {
    public var cameraTransform: simd_double4x4
    public var state: TrackingState
    public var reason: TrackingReason
    public var originEpoch: UInt32

    public init(
        cameraTransform: simd_double4x4,
        state: TrackingState,
        reason: TrackingReason,
        originEpoch: UInt32
    ) {
        self.cameraTransform = cameraTransform
        self.state = state
        self.reason = reason
        self.originEpoch = originEpoch
    }
}

public enum ImuReferenceFrame: Equatable, Sendable {
    case arbitrary
    case trueNorth
}

public enum BatteryChargeState: Equatable, Sendable {
    case unknown
    case charging
    case discharging
    case full
}

/// ROS 2 メッセージをセンサー値から組み立てる。時刻は呼び出し側が stampNs で渡す。
public enum MessageBuilders {
    public static func odometry(stampNs: UInt64, names: FrameNames, pose: PoseInput) -> NavMsgs.Odometry {
        let converted = Frames.arkitPoseToREP103(pose.cameraTransform)
        var twistCov = Array(repeating: 0.0, count: 36)
        twistCov[0] = -1
        return NavMsgs.Odometry(
            header: WireStamp.header(stampNs: stampNs, frameId: names.odom),
            childFrameId: names.link,
            pose: GeometryMsgs.PoseWithCovariance(
                pose: GeometryMsgs.Pose(
                    position: point(converted.position),
                    orientation: quaternion(converted.orientation)
                ),
                covariance: Array(repeating: 0.0, count: 36)
            ),
            twist: GeometryMsgs.TwistWithCovariance(
                twist: GeometryMsgs.Twist(),
                covariance: twistCov
            )
        )
    }

    public static func tracking(stampNs: UInt64, names: FrameNames, pose: PoseInput) -> PocketsensorMsgs.TrackingStatus {
        PocketsensorMsgs.TrackingStatus(
            header: WireStamp.header(stampNs: stampNs, frameId: names.link),
            state: pose.state.rawValue,
            reason: pose.reason.rawValue,
            originEpoch: pose.originEpoch
        )
    }

    public static func tf(stampNs: UInt64, names: FrameNames, pose: PoseInput) -> Tf2Msgs.TFMessage {
        let converted = Frames.arkitPoseToREP103(pose.cameraTransform)
        return Tf2Msgs.TFMessage(transforms: [
            GeometryMsgs.TransformStamped(
                header: WireStamp.header(stampNs: stampNs, frameId: names.odom),
                childFrameId: names.link,
                transform: GeometryMsgs.Transform(
                    translation: vector(converted.position),
                    rotation: quaternion(converted.orientation)
                )
            ),
        ])
    }

    public static func tfStatic(stampNs: UInt64, names: FrameNames) -> Tf2Msgs.TFMessage {
        let stamp = WireStamp.header(stampNs: stampNs, frameId: names.link)
        let zero = GeometryMsgs.Vector3(x: 0, y: 0, z: 0)
        return Tf2Msgs.TFMessage(transforms: [
            GeometryMsgs.TransformStamped(
                header: stamp,
                childFrameId: names.colorOptical,
                transform: GeometryMsgs.Transform(
                    translation: zero,
                    rotation: quaternion(Frames.linkToColorOptical)
                )
            ),
            GeometryMsgs.TransformStamped(
                header: stamp,
                childFrameId: names.imuLink,
                transform: GeometryMsgs.Transform(
                    translation: zero,
                    rotation: quaternion(Frames.linkToImu)
                )
            ),
        ])
    }

    public static func anchorTF(
        stampNs: UInt64,
        names: FrameNames,
        imageName: String,
        anchorTransform: simd_double4x4
    ) -> Tf2Msgs.TFMessage {
        let converted = Frames.arkitPoseToREP103(anchorTransform)
        return Tf2Msgs.TFMessage(transforms: [
            GeometryMsgs.TransformStamped(
                header: WireStamp.header(stampNs: stampNs, frameId: names.odom),
                childFrameId: names.anchorFrame(imageName: imageName),
                transform: GeometryMsgs.Transform(
                    translation: vector(converted.position),
                    rotation: quaternion(converted.orientation)
                )
            ),
        ])
    }

    public static func compressedImage(stampNs: UInt64, names: FrameNames, jpeg: Data) -> SensorMsgs.CompressedImage {
        SensorMsgs.CompressedImage(
            header: WireStamp.header(stampNs: stampNs, frameId: names.colorOptical),
            format: "jpeg",
            data: jpeg
        )
    }

    public static func depthImage(stampNs: UInt64, names: FrameNames, width: Int, height: Int, data: Data) -> SensorMsgs.Image {
        SensorMsgs.Image(
            header: WireStamp.header(stampNs: stampNs, frameId: names.colorOptical),
            height: UInt32(height),
            width: UInt32(width),
            encoding: "16UC1",
            isBigendian: 0,
            step: UInt32(width * 2),
            data: data
        )
    }

    public static func confidenceImage(
        stampNs: UInt64,
        names: FrameNames,
        width: Int,
        height: Int,
        data: Data
    ) -> SensorMsgs.Image {
        SensorMsgs.Image(
            header: WireStamp.header(stampNs: stampNs, frameId: names.colorOptical),
            height: UInt32(height),
            width: UInt32(width),
            encoding: "mono8",
            isBigendian: 0,
            step: UInt32(width),
            data: data
        )
    }

    public static func cameraInfo(stampNs: UInt64, names: FrameNames, intrinsics: Intrinsics) -> SensorMsgs.CameraInfo {
        SensorMsgs.CameraInfo(
            header: WireStamp.header(stampNs: stampNs, frameId: names.colorOptical),
            height: UInt32(intrinsics.height),
            width: UInt32(intrinsics.width),
            distortionModel: "plumb_bob",
            d: intrinsics.d,
            k: intrinsics.k,
            r: intrinsics.r,
            p: intrinsics.p,
            binningX: 0,
            binningY: 0,
            roi: SensorMsgs.RegionOfInterest()
        )
    }

    public static func imuRaw(stampNs: UInt64, names: FrameNames, accelG: SIMD3<Double>, gyroRadS: SIMD3<Double>) -> SensorMsgs.Imu {
        var orientationCov = Array(repeating: 0.0, count: 9)
        orientationCov[0] = -1
        let accel = Units.accelGToMps2(accelG)
        return SensorMsgs.Imu(
            header: WireStamp.header(stampNs: stampNs, frameId: names.imuLink),
            orientation: identityQuaternion,
            orientationCovariance: orientationCov,
            angularVelocity: vector(gyroRadS),
            angularVelocityCovariance: Array(repeating: 0.0, count: 9),
            linearAcceleration: vector(accel),
            linearAccelerationCovariance: Array(repeating: 0.0, count: 9)
        )
    }

    /// Core Motion の xTrueNorthZVertical は North-West-Up。REP-145 の East-North-Up へは Rz(+π/2) を左から掛ける。
    public static func imuFused(
        stampNs: UInt64,
        names: FrameNames,
        attitudeDeviceToReference: simd_quatd,
        reference: ImuReferenceFrame,
        userAccelG: SIMD3<Double>,
        gravityG: SIMD3<Double>,
        rotationRateRadS: SIMD3<Double>
    ) -> SensorMsgs.Imu {
        let orientation: simd_quatd
        switch reference {
        case .arbitrary:
            orientation = Frames.canonical(attitudeDeviceToReference)
        case .trueNorth:
            let rz = Frames.quaternion(roll: 0, pitch: 0, yaw: .pi / 2)
            orientation = Frames.canonical(rz * attitudeDeviceToReference)
        }
        let accel = Units.accelGToMps2(userAccelG + gravityG)
        return SensorMsgs.Imu(
            header: WireStamp.header(stampNs: stampNs, frameId: names.imuLink),
            orientation: quaternion(orientation),
            orientationCovariance: Array(repeating: 0.0, count: 9),
            angularVelocity: vector(rotationRateRadS),
            angularVelocityCovariance: Array(repeating: 0.0, count: 9),
            linearAcceleration: vector(accel),
            linearAccelerationCovariance: Array(repeating: 0.0, count: 9)
        )
    }

    public static func magneticField(stampNs: UInt64, names: FrameNames, microTesla: SIMD3<Double>) -> SensorMsgs.MagneticField {
        SensorMsgs.MagneticField(
            header: WireStamp.header(stampNs: stampNs, frameId: names.imuLink),
            magneticField: vector(Units.magMicroTeslaToTesla(microTesla)),
            magneticFieldCovariance: Array(repeating: 0.0, count: 9)
        )
    }

    public static func fluidPressure(stampNs: UInt64, names: FrameNames, kPa: Double) -> SensorMsgs.FluidPressure {
        SensorMsgs.FluidPressure(
            header: WireStamp.header(stampNs: stampNs, frameId: names.link),
            fluidPressure: Units.pressureKPaToPa(kPa),
            variance: 0
        )
    }

    public static func navSatFix(
        stampNs: UInt64,
        names: FrameNames,
        latitude: Double,
        longitude: Double,
        ellipsoidalAltitude: Double,
        horizontalAccuracy: Double,
        verticalAccuracy: Double
    ) -> SensorMsgs.NavSatFix {
        let cov = Units.navSatCovariance(
            horizontalAccuracy: horizontalAccuracy,
            verticalAccuracy: verticalAccuracy
        )
        // 測位なしの値を残すと、受け手がそのまま使ってしまう。
        if horizontalAccuracy < 0 {
            return SensorMsgs.NavSatFix(
                header: WireStamp.header(stampNs: stampNs, frameId: names.link),
                status: SensorMsgs.NavSatStatus(status: cov.status, service: 0),
                latitude: .nan,
                longitude: .nan,
                altitude: .nan,
                positionCovariance: cov.covariance,
                positionCovarianceType: cov.type
            )
        }
        let altitude = verticalAccuracy < 0 ? Double.nan : ellipsoidalAltitude
        return SensorMsgs.NavSatFix(
            header: WireStamp.header(stampNs: stampNs, frameId: names.link),
            status: SensorMsgs.NavSatStatus(status: cov.status, service: 0),
            latitude: latitude,
            longitude: longitude,
            altitude: altitude,
            positionCovariance: cov.covariance,
            positionCovarianceType: cov.type
        )
    }

    public static func timeReference(stampNs: UInt64, wallTimeNs: UInt64, source: String) -> SensorMsgs.TimeReference {
        SensorMsgs.TimeReference(
            header: WireStamp.header(stampNs: stampNs, frameId: ""),
            timeRef: WireStamp.time(wallTimeNs),
            source: source
        )
    }

    public static func battery(stampNs: UInt64, level: Float, state: BatteryChargeState) -> SensorMsgs.BatteryState {
        let percentage: Float = level < 0 ? .nan : level
        let status: UInt8
        switch state {
        case .unknown: status = SensorMsgs.BatteryState.powerSupplyStatusUnknown
        case .charging: status = SensorMsgs.BatteryState.powerSupplyStatusCharging
        case .discharging: status = SensorMsgs.BatteryState.powerSupplyStatusDischarging
        case .full: status = SensorMsgs.BatteryState.powerSupplyStatusFull
        }
        return SensorMsgs.BatteryState(
            header: WireStamp.header(stampNs: stampNs, frameId: ""),
            voltage: .nan,
            temperature: .nan,
            current: .nan,
            charge: .nan,
            capacity: .nan,
            designCapacity: .nan,
            percentage: percentage,
            powerSupplyStatus: status,
            powerSupplyHealth: SensorMsgs.BatteryState.powerSupplyHealthUnknown,
            powerSupplyTechnology: SensorMsgs.BatteryState.powerSupplyTechnologyLion,
            present: true
        )
    }

    public static func string(_ data: String) -> StdMsgs.String {
        StdMsgs.String(data: data)
    }

    static let identityQuaternion = GeometryMsgs.Quaternion(x: 0, y: 0, z: 0, w: 1)

    static func quaternion(_ q: simd_quatd) -> GeometryMsgs.Quaternion {
        GeometryMsgs.Quaternion(x: q.vector.x, y: q.vector.y, z: q.vector.z, w: q.vector.w)
    }

    static func point(_ p: SIMD3<Double>) -> GeometryMsgs.Point {
        GeometryMsgs.Point(x: p.x, y: p.y, z: p.z)
    }

    static func vector(_ p: SIMD3<Double>) -> GeometryMsgs.Vector3 {
        GeometryMsgs.Vector3(x: p.x, y: p.y, z: p.z)
    }
}

/// 最新の加速度を各ジャイロ標本へゼロ次ホールドで付ける。加速度が 50 ms より古いと組にしない。
public struct RawImuPairer: Sendable {
    private var lastAccelTime: Double?
    private var lastAccelG: SIMD3<Double>?

    public init() {}

    public mutating func accel(timestampS: Double, g: SIMD3<Double>) {
        lastAccelTime = timestampS
        lastAccelG = g
    }

    public mutating func gyro(timestampS: Double, radS: SIMD3<Double>) -> (timestampS: Double, accelG: SIMD3<Double>, gyro: SIMD3<Double>)? {
        guard let accelTime = lastAccelTime, let accelG = lastAccelG else { return nil }
        if timestampS - accelTime > 0.050 {
            return nil
        }
        return (timestampS, accelG, radS)
    }
}

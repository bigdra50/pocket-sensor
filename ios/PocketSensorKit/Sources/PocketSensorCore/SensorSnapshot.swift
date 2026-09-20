import Foundation
import simd

/// 計器盤へ出す 1 枚の値。5 Hz で入れ替える。単位は wire と同じ変換のあと。
public struct SensorSnapshot: Sendable {
    public var tracking: String
    public var originEpoch: UInt32
    public var positionM: SIMD3<Double>?
    public var orientation: simd_quatd?
    public var specificForceMps2: SIMD3<Double>?
    public var angularVelocityRadS: SIMD3<Double>?
    public var imuOrientation: simd_quatd?
    public var magneticFieldUT: SIMD3<Double>?
    public var magCalibration: MagCalibration
    public var pressurePa: Double?
    public var relativeAltitudeM: Double?
    public var gnssLatitude: Double?
    public var gnssLongitude: Double?
    public var gnssHorizontalAccuracyM: Double?
    public var gnssAltitudeM: Double?
    public var locationAuthorization: LocationAuthorization
    public var batteryLevel: Float
    public var batteryState: String
    public var thermal: String
    public var clock: ClockCheckStatus
    public var ratesHz: [String: Double]
    public var drops: [String: Int]
    public var depthCenterM: Float?

    public init(
        tracking: String = "unavailable",
        originEpoch: UInt32 = 0,
        positionM: SIMD3<Double>? = nil,
        orientation: simd_quatd? = nil,
        specificForceMps2: SIMD3<Double>? = nil,
        angularVelocityRadS: SIMD3<Double>? = nil,
        imuOrientation: simd_quatd? = nil,
        magneticFieldUT: SIMD3<Double>? = nil,
        magCalibration: MagCalibration = .unknown,
        pressurePa: Double? = nil,
        relativeAltitudeM: Double? = nil,
        gnssLatitude: Double? = nil,
        gnssLongitude: Double? = nil,
        gnssHorizontalAccuracyM: Double? = nil,
        gnssAltitudeM: Double? = nil,
        locationAuthorization: LocationAuthorization = .unknown,
        batteryLevel: Float = -1,
        batteryState: String = "unknown",
        thermal: String = "nominal",
        clock: ClockCheckStatus = .pending,
        ratesHz: [String: Double] = [:],
        drops: [String: Int] = [:],
        depthCenterM: Float? = nil
    ) {
        self.tracking = tracking
        self.originEpoch = originEpoch
        self.positionM = positionM
        self.orientation = orientation
        self.specificForceMps2 = specificForceMps2
        self.angularVelocityRadS = angularVelocityRadS
        self.imuOrientation = imuOrientation
        self.magneticFieldUT = magneticFieldUT
        self.magCalibration = magCalibration
        self.pressurePa = pressurePa
        self.relativeAltitudeM = relativeAltitudeM
        self.gnssLatitude = gnssLatitude
        self.gnssLongitude = gnssLongitude
        self.gnssHorizontalAccuracyM = gnssHorizontalAccuracyM
        self.gnssAltitudeM = gnssAltitudeM
        self.locationAuthorization = locationAuthorization
        self.batteryLevel = batteryLevel
        self.batteryState = batteryState
        self.thermal = thermal
        self.clock = clock
        self.ratesHz = ratesHz
        self.drops = drops
        self.depthCenterM = depthCenterM
    }

    public var poseRPYDeg: (roll: Double, pitch: Double, yaw: Double)? {
        orientation.map { Frames.rpyDegrees(from: $0) }
    }

    public var imuRPYDeg: (roll: Double, pitch: Double, yaw: Double)? {
        imuOrientation.map { Frames.rpyDegrees(from: $0) }
    }

    /// capture の生値。単位変換は `make` が MessageBuilders と同じ経路で行う。
    public struct Input: Sendable {
        public var tracking: String
        public var originEpoch: UInt32
        public var cameraTransform: simd_double4x4?
        public var accelG: SIMD3<Double>?
        public var userAccelG: SIMD3<Double>?
        public var gravityG: SIMD3<Double>?
        public var rotationRateRadS: SIMD3<Double>?
        public var attitudeDeviceToReference: simd_quatd?
        public var imuReference: ImuReferenceFrame
        public var magneticFieldUT: SIMD3<Double>?
        public var magCalibration: MagCalibration
        public var pressureKPa: Double?
        public var relativeAltitudeM: Double?
        public var gnssLatitude: Double?
        public var gnssLongitude: Double?
        public var gnssHorizontalAccuracyM: Double?
        public var gnssAltitudeM: Double?
        public var locationAuthorization: LocationAuthorization
        public var batteryLevel: Float
        public var batteryState: String
        public var thermal: String
        public var clock: ClockCheckStatus
        public var ratesHz: [String: Double]
        public var drops: [String: Int]
        public var depthCenterM: Float?

        public init(
            tracking: String,
            originEpoch: UInt32,
            cameraTransform: simd_double4x4?,
            accelG: SIMD3<Double>?,
            userAccelG: SIMD3<Double>?,
            gravityG: SIMD3<Double>?,
            rotationRateRadS: SIMD3<Double>?,
            attitudeDeviceToReference: simd_quatd?,
            imuReference: ImuReferenceFrame,
            magneticFieldUT: SIMD3<Double>?,
            magCalibration: MagCalibration,
            pressureKPa: Double?,
            relativeAltitudeM: Double?,
            gnssLatitude: Double?,
            gnssLongitude: Double?,
            gnssHorizontalAccuracyM: Double?,
            gnssAltitudeM: Double?,
            locationAuthorization: LocationAuthorization,
            batteryLevel: Float,
            batteryState: String,
            thermal: String,
            clock: ClockCheckStatus,
            ratesHz: [String: Double],
            drops: [String: Int],
            depthCenterM: Float?
        ) {
            self.tracking = tracking
            self.originEpoch = originEpoch
            self.cameraTransform = cameraTransform
            self.accelG = accelG
            self.userAccelG = userAccelG
            self.gravityG = gravityG
            self.rotationRateRadS = rotationRateRadS
            self.attitudeDeviceToReference = attitudeDeviceToReference
            self.imuReference = imuReference
            self.magneticFieldUT = magneticFieldUT
            self.magCalibration = magCalibration
            self.pressureKPa = pressureKPa
            self.relativeAltitudeM = relativeAltitudeM
            self.gnssLatitude = gnssLatitude
            self.gnssLongitude = gnssLongitude
            self.gnssHorizontalAccuracyM = gnssHorizontalAccuracyM
            self.gnssAltitudeM = gnssAltitudeM
            self.locationAuthorization = locationAuthorization
            self.batteryLevel = batteryLevel
            self.batteryState = batteryState
            self.thermal = thermal
            self.clock = clock
            self.ratesHz = ratesHz
            self.drops = drops
            self.depthCenterM = depthCenterM
        }
    }

    public static func make(_ input: Input) -> SensorSnapshot {
        let pose = input.cameraTransform.map { Frames.arkitPoseToREP103($0) }
        var specificForce: SIMD3<Double>?
        if let user = input.userAccelG, let gravity = input.gravityG {
            specificForce = Units.accelGToMps2(user + gravity)
        } else if let accelG = input.accelG {
            specificForce = Units.accelGToMps2(accelG)
        }
        let imuOrientation = input.attitudeDeviceToReference.map {
            MessageBuilders.fusedOrientation(attitudeDeviceToReference: $0, reference: input.imuReference)
        }
        return SensorSnapshot(
            tracking: input.tracking,
            originEpoch: input.originEpoch,
            positionM: pose?.position,
            orientation: pose?.orientation,
            specificForceMps2: specificForce,
            angularVelocityRadS: input.rotationRateRadS,
            imuOrientation: imuOrientation,
            magneticFieldUT: input.magneticFieldUT,
            magCalibration: input.magCalibration,
            pressurePa: input.pressureKPa.map { Units.pressureKPaToPa($0) },
            relativeAltitudeM: input.relativeAltitudeM,
            gnssLatitude: input.gnssLatitude,
            gnssLongitude: input.gnssLongitude,
            gnssHorizontalAccuracyM: input.gnssHorizontalAccuracyM,
            gnssAltitudeM: input.gnssAltitudeM,
            locationAuthorization: input.locationAuthorization,
            batteryLevel: input.batteryLevel,
            batteryState: input.batteryState,
            thermal: input.thermal,
            clock: input.clock,
            ratesHz: input.ratesHz,
            drops: input.drops,
            depthCenterM: input.depthCenterM
        )
    }

    /// Simulator のレイアウト確認用。3 桁の負値と GNSS 測位を載せ、セル幅の最悪を出す。
    public static let demo = SensorSnapshot(
        tracking: "normal",
        originEpoch: 2,
        positionM: SIMD3(-123.45, -101.03, 145.67),
        orientation: Frames.quaternion(
            roll: -12.5 * .pi / 180,
            pitch: -45.0 * .pi / 180,
            yaw: 179.9 * .pi / 180
        ),
        specificForceMps2: SIMD3(-123.45, -9.81, 145.67),
        angularVelocityRadS: SIMD3(-12.345, -1.002, 10.110),
        imuOrientation: Frames.quaternion(
            roll: -12.5 * .pi / 180,
            pitch: -45.0 * .pi / 180,
            yaw: 179.9 * .pi / 180
        ),
        magneticFieldUT: SIMD3(-123.4, -41.0, 321.5),
        magCalibration: .high,
        pressurePa: 101_325,
        relativeAltitudeM: 1.25,
        gnssLatitude: 35.12345,
        gnssLongitude: 139.12345,
        gnssHorizontalAccuracyM: 5.9,
        gnssAltitudeM: 12.3,
        locationAuthorization: .authorized,
        batteryLevel: 0.87,
        batteryState: "charging",
        thermal: "nominal",
        clock: .ok,
        ratesHz: [
            "odom": 30.0,
            "color_image": 15.0,
            "depth_image_compressed": 15.0,
            "depth_confidence_compressed": 15.0,
            "imu": 100.0,
            "mag": 50.0,
            "pressure": 1.0,
            "gnss_fix": 1.0,
            "battery": 1.0,
        ],
        drops: [
            "color_image": 12,
            "odom": 0,
        ],
        depthCenterM: 1.84
    )
}

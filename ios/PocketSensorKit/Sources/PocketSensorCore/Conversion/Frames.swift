import simd

/// ARKit の姿勢を REP-103 へ付け替える。行列の計算は Python の基準実装と同じ手順。
public enum Frames {
    /// 行は [0, 0, -1], [-1, 0, 0], [0, 1, 0]。simd は列優先なので rows: で与える。
    public static let arkitToREP103 = simd_double3x3(rows: [
        SIMD3(0, 0, -1),
        SIMD3(-1, 0, 0),
        SIMD3(0, 1, 0),
    ])

    /// 光学 frame への固定回転。R = Rz(-π/2) Ry(0) Rx(-π/2)。
    public static let linkToColorOptical = quaternion(roll: -.pi / 2, pitch: 0, yaw: -.pi / 2)

    /// IMU frame への固定回転。R = Rz(0) Ry(-π/2) Rx(0)。並進は未較正のため 0。
    public static let linkToImu = quaternion(roll: 0, pitch: -.pi / 2, yaw: 0)

    public static func arkitPoseToREP103(
        _ cameraTransform: simd_double4x4
    ) -> (position: SIMD3<Double>, orientation: simd_quatd) {
        let r = arkitToREP103
        let pArkit = SIMD3(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)
        let rCam = simd_double3x3(
            SIMD3(cameraTransform.columns.0.x, cameraTransform.columns.0.y, cameraTransform.columns.0.z),
            SIMD3(cameraTransform.columns.1.x, cameraTransform.columns.1.y, cameraTransform.columns.1.z),
            SIMD3(cameraTransform.columns.2.x, cameraTransform.columns.2.y, cameraTransform.columns.2.z)
        )
        let position = r * pArkit
        let rOut = r * rCam * r.transpose
        return (position, canonical(quaternion(from: rOut)))
    }

    /// 単位四元数の符号を揃える。w >= 0。w が 0 なら (x, y, z) の最初の非零が正。
    public static func canonical(_ q: simd_quatd) -> simd_quatd {
        let n = simd_length(q.vector)
        let v = n == 0 ? q.vector : q.vector / n
        if v.w < 0 {
            return simd_quatd(vector: -v)
        }
        if v.w == 0 {
            if v.x < 0 || (v.x == 0 && v.y < 0) || (v.x == 0 && v.y == 0 && v.z < 0) {
                return simd_quatd(vector: -v)
            }
        }
        return simd_quatd(vector: v)
    }

    /// ROS の固定軸 RPY を度で返す。R = Rz(yaw) Ry(pitch) Rx(roll)。
    /// yaw は (-180, 180]。pitch は ±90 で打ち切る。ジンバルロックでも NaN は出さない。
    public static func rpyDegrees(from q: simd_quatd) -> (roll: Double, pitch: Double, yaw: Double) {
        let n = canonical(q)
        let x = n.vector.x
        let y = n.vector.y
        let z = n.vector.z
        let w = n.vector.w
        let sinp = 2.0 * (w * y - z * x)
        let pitchRad: Double
        if sinp >= 1.0 {
            pitchRad = .pi / 2
        } else if sinp <= -1.0 {
            pitchRad = -.pi / 2
        } else {
            pitchRad = asin(sinp)
        }
        let rollRad = atan2(2.0 * (w * x + y * z), 1.0 - 2.0 * (x * x + y * y))
        let yawRad = atan2(2.0 * (w * z + x * y), 1.0 - 2.0 * (y * y + z * z))
        let toDeg = 180.0 / Double.pi
        return (
            roll: Units.wrapToPi(rollRad) * toDeg,
            pitch: pitchRad * toDeg,
            yaw: Units.wrapToPi(yawRad) * toDeg
        )
    }

    /// ROS の固定軸 RPY。R = Rz(yaw) Ry(pitch) Rx(roll)。
    public static func quaternion(roll: Double, pitch: Double, yaw: Double) -> simd_quatd {
        let cr = cos(roll)
        let sr = sin(roll)
        let cp = cos(pitch)
        let sp = sin(pitch)
        let cy = cos(yaw)
        let sy = sin(yaw)
        let rx = simd_double3x3(rows: [
            SIMD3(1, 0, 0),
            SIMD3(0, cr, -sr),
            SIMD3(0, sr, cr),
        ])
        let ry = simd_double3x3(rows: [
            SIMD3(cp, 0, sp),
            SIMD3(0, 1, 0),
            SIMD3(-sp, 0, cp),
        ])
        let rz = simd_double3x3(rows: [
            SIMD3(cy, -sy, 0),
            SIMD3(sy, cy, 0),
            SIMD3(0, 0, 1),
        ])
        return quaternion(from: rz * ry * rx)
    }

    /// 3x3 回転行列を四元数にする。Shepperd 法。Python の matrix_to_quat と同じ分岐。
    public static func quaternion(from m: simd_double3x3) -> simd_quatd {
        func at(_ row: Int, _ col: Int) -> Double {
            m[col][row]
        }

        let trace = at(0, 0) + at(1, 1) + at(2, 2)
        let x: Double
        let y: Double
        let z: Double
        let w: Double
        if trace > 0 {
            let s = sqrt(trace + 1.0) * 2.0
            w = 0.25 * s
            x = (at(2, 1) - at(1, 2)) / s
            y = (at(0, 2) - at(2, 0)) / s
            z = (at(1, 0) - at(0, 1)) / s
        } else if at(0, 0) > at(1, 1), at(0, 0) > at(2, 2) {
            let s = sqrt(1.0 + at(0, 0) - at(1, 1) - at(2, 2)) * 2.0
            w = (at(2, 1) - at(1, 2)) / s
            x = 0.25 * s
            y = (at(0, 1) + at(1, 0)) / s
            z = (at(0, 2) + at(2, 0)) / s
        } else if at(1, 1) > at(2, 2) {
            let s = sqrt(1.0 + at(1, 1) - at(0, 0) - at(2, 2)) * 2.0
            w = (at(0, 2) - at(2, 0)) / s
            x = (at(0, 1) + at(1, 0)) / s
            y = 0.25 * s
            z = (at(1, 2) + at(2, 1)) / s
        } else {
            let s = sqrt(1.0 + at(2, 2) - at(0, 0) - at(1, 1)) * 2.0
            w = (at(1, 0) - at(0, 1)) / s
            x = (at(0, 2) + at(2, 0)) / s
            y = (at(1, 2) + at(2, 1)) / s
            z = 0.25 * s
        }
        return canonical(simd_quatd(ix: x, iy: y, iz: z, r: w))
    }
}

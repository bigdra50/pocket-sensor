import Foundation
import simd

/// 計器盤の固定幅セル。欠けた値は既存 UI と同じ "—"（U+2014）。
/// 符号込み 7 字。はみ出しは overflow にして幅を広げない。
public enum Readout {
    public static let missing = "—"
    public static let cellWidth = 7
    public static let overflow = "#######"
    public static var missingCell: String { String(repeating: " ", count: cellWidth - 1) + missing }

    public static let depthChannelKeys = ["depth_image", "depth_image_compressed"]
    public static let confidenceChannelKeys = ["depth_confidence", "depth_confidence_compressed"]

    /// Streams 区画のセル。depth / confidence は圧縮と無圧縮の大きい方を出す。
    public static let streamPanelRows: [(label: String, keys: [String])] = [
        ("pose", ["odom"]),
        ("color", ["color_image"]),
        ("depth", depthChannelKeys),
        ("conf", confidenceChannelKeys),
        ("imu", ["imu"]),
        ("raw", ["imu_raw"]),
        ("mag", ["mag"]),
        ("press", ["pressure"]),
        ("gnss", ["gnss_fix"]),
        ("batt", ["battery"]),
    ]

    public static func cell(_ value: Double, fractionDigits: Int) -> String {
        guard value.isFinite else { return overflow }
        let formatted = String(format: "%+.\(fractionDigits)f", value)
        if formatted.count > cellWidth {
            return overflow
        }
        if formatted.count == cellWidth {
            return formatted
        }
        return String(repeating: " ", count: cellWidth - formatted.count) + formatted
    }

    public static func vectorCells(_ v: SIMD3<Double>?, fractionDigits: Int) -> [String] {
        guard let v else { return [missingCell, missingCell, missingCell] }
        return [
            cell(v.x, fractionDigits: fractionDigits),
            cell(v.y, fractionDigits: fractionDigits),
            cell(v.z, fractionDigits: fractionDigits),
        ]
    }

    public static func rpyCells(_ value: (roll: Double, pitch: Double, yaw: Double)?) -> [String] {
        guard let value else { return [missingCell, missingCell, missingCell] }
        return [
            cell(value.roll, fractionDigits: 1),
            cell(value.pitch, fractionDigits: 1),
            cell(value.yaw, fractionDigits: 1),
        ]
    }

    public static func quaternionCells(_ q: simd_quatd?) -> [String] {
        guard let q else { return [missingCell, missingCell, missingCell, missingCell] }
        let v = q.vector
        return [
            cell(v.x, fractionDigits: 3),
            cell(v.y, fractionDigits: 3),
            cell(v.z, fractionDigits: 3),
            cell(v.w, fractionDigits: 3),
        ]
    }

    /// wire は Pa。画面は hPa。相対高度は同じ行。
    public static func pressureAltitudeLine(pa: Double?, relativeAltitudeM: Double?) -> String {
        let press = pa.map { String(format: "%.2f hPa", $0 / 100.0) } ?? missing
        let alt = relativeAltitudeM.map { String(format: "alt %+.2f m", $0) } ?? "alt \(missing)"
        return "\(press)   \(alt)"
    }

    public static func gnssLatLon(latitude: Double?, longitude: Double?) -> String? {
        guard let latitude, let longitude else { return nil }
        return String(format: "%+.5f  %+.5f", latitude, longitude)
    }

    public static func gnssAccuracyLine(horizontalM: Double, altitudeM: Double?) -> String {
        let horiz = String(format: "±%.1f m", horizontalM)
        if let altitudeM {
            return "\(horiz)   alt \(String(format: "%+.1f m", altitudeM))"
        }
        return horiz
    }

    /// 水平精度が負、または測位が無いときは許可の状態だけを出す。
    public static func gnss(
        latitude: Double?,
        longitude: Double?,
        horizontalAccuracyM: Double?,
        authorization: LocationAuthorization
    ) -> String {
        if let latitude, let longitude, let horizontalAccuracyM, horizontalAccuracyM >= 0 {
            return gnssLatLon(latitude: latitude, longitude: longitude) ?? authorization.rawValue
        }
        return authorization.rawValue
    }

    public static func rateHz(_ hz: Double) -> String {
        String(format: "%.1f Hz", hz)
    }

    public static func streamRate(label: String, hz: Double) -> String {
        "\(label) \(rateHz(hz))"
    }

    public static func streamDrop(_ count: Int) -> String? {
        count > 0 ? "drop \(count)" : nil
    }

    public static func batteryThermal(level: Float, state: String, thermal: String) -> String {
        let batt: String
        if level >= 0 {
            batt = String(format: "%.0f%% %@", level * 100, state)
        } else {
            batt = missing
        }
        return "\(batt)   \(thermal)"
    }

    public static func clock(_ status: ClockCheckStatus) -> String {
        status.rawValue
    }

    /// 同じ物理量の複数チャンネルは、流れている方（最大 Hz）を出す。
    public static func combinedRateHz(keys: [String], rates: [String: Double]) -> Double {
        keys.map { rates[$0] ?? 0 }.max() ?? 0
    }

    public static func combinedDrops(keys: [String], drops: [String: Int]) -> Int {
        keys.reduce(0) { $0 + (drops[$1] ?? 0) }
    }
}

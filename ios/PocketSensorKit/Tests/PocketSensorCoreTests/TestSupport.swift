import Foundation
import PocketSensorCore
import simd
import XCTest

enum VectorFiles {
    static func url(_ name: String) -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0 ..< 16 {
            let candidate = dir
                .appendingPathComponent("contract")
                .appendingPathComponent("vectors")
                .appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            dir.deleteLastPathComponent()
        }
        return dir
            .appendingPathComponent("contract")
            .appendingPathComponent("vectors")
            .appendingPathComponent(name)
    }

    static func json(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: url(name))
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "VectorFiles", code: 1)
        }
        return root
    }
}

func jsonDouble(_ value: Any) -> Double {
    if let d = value as? Double { return d }
    if let i = value as? Int { return Double(i) }
    if let n = value as? NSNumber { return n.doubleValue }
    return .nan
}

func jsonDoubles(_ value: Any) -> [Double] {
    (value as? [Any])?.map(jsonDouble) ?? []
}

func jsonInt(_ value: Any) -> Int {
    if let i = value as? Int { return i }
    if let n = value as? NSNumber { return n.intValue }
    return 0
}

/// 契約のベクトルは行優先 4x4。simd は列優先。
func matrix4x4(rowMajor values: [Double]) -> simd_double4x4 {
    simd_double4x4(rows: [
        SIMD4(values[0], values[1], values[2], values[3]),
        SIMD4(values[4], values[5], values[6], values[7]),
        SIMD4(values[8], values[9], values[10], values[11]),
        SIMD4(values[12], values[13], values[14], values[15]),
    ])
}

func restoreJSONFloat(_ value: Any) -> Float {
    if let s = value as? String {
        switch s {
        case "NaN": return .nan
        case "Infinity": return .infinity
        case "-Infinity": return -.infinity
        default: break
        }
    }
    return Float(jsonDouble(value))
}

func encodedCDR<T: CDREncodable>(_ value: T) -> Data {
    var encoder = CDREncoder()
    encoder.encode(value)
    return encoder.data
}

func jsonHexData(_ hex: String) -> Data? {
    let chars = Array(hex)
    guard chars.count.isMultiple(of: 2) else { return nil }
    var bytes: [UInt8] = []
    bytes.reserveCapacity(chars.count / 2)
    var index = 0
    while index < chars.count {
        let pair = String(chars[index]) + String(chars[index + 1])
        guard let byte = UInt8(pair, radix: 16) else { return nil }
        bytes.append(byte)
        index += 2
    }
    return Data(bytes)
}

func XCTAssertEqualDoubles(
    _ actual: [Double],
    _ expected: [Double],
    accuracy: Double,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(actual.count, expected.count, file: file, line: line)
    for (a, e) in zip(actual, expected) {
        if e.isNaN {
            XCTAssertTrue(a.isNaN, file: file, line: line)
        } else {
            XCTAssertEqual(a, e, accuracy: accuracy, file: file, line: line)
        }
    }
}

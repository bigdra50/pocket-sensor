import Foundation

enum SortedJSON {
    static func data(_ object: Any) -> Data {
        do {
            return try JSONSerialization.data(
                withJSONObject: jsonReady(object),
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
        } catch {
            preconditionFailure("JSON serialization failed: \(error)")
        }
    }

    static func text(_ object: Any) -> String {
        String(data: data(object), encoding: .utf8) ?? "{}"
    }

    /// JSONSerialization は UInt32 や Int64 をそのまま受けないので NSNumber へ直す。
    private static func jsonReady(_ value: Any) -> Any {
        if value is NSNull || value is String || value is Bool {
            return value
        }
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            for (key, item) in dict {
                out[key] = jsonReady(item)
            }
            return out
        }
        if let array = value as? [Any] {
            return array.map { jsonReady($0) }
        }
        if let v = value as? Int { return v }
        if let v = value as? Double { return v }
        if let v = value as? Float { return Double(v) }
        if let v = value as? UInt8 { return Int(v) }
        if let v = value as? UInt16 { return Int(v) }
        if let v = value as? UInt32 { return Int(v) }
        if let v = value as? UInt64 { return NSNumber(value: v) }
        if let v = value as? Int8 { return Int(v) }
        if let v = value as? Int16 { return Int(v) }
        if let v = value as? Int32 { return Int(v) }
        if let v = value as? Int64 { return NSNumber(value: v) }
        return value
    }
}

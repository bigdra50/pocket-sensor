import Foundation

/// CDR のエンコードで起きる誤り。不正な入力ではトラップせず、これを投げる。
public enum CDRError: Error, Equatable {
    case truncated
    case badHeader
    case oversizedCount
    case invalidUTF8
    case missingNUL
    case unknownSchema(String)
}

public protocol CDREncodable {
    func encode(to encoder: inout CDREncoder)
}

public protocol CDRDecodable {
    init(from decoder: inout CDRDecoder) throws
}

public typealias CDRCodable = CDREncodable & CDRDecodable

extension Bool: CDRCodable {
    public func encode(to encoder: inout CDREncoder) {
        encoder.encode(UInt8(self ? 1 : 0))
    }

    public init(from decoder: inout CDRDecoder) throws {
        self = try decoder.decode(UInt8.self) != 0
    }
}

extension UInt8: CDRCodable {
    public func encode(to encoder: inout CDREncoder) {
        encoder.align(to: 1)
        encoder.appendRaw(Data([self]))
    }

    public init(from decoder: inout CDRDecoder) throws {
        try decoder.align(to: 1)
        let bytes = try decoder.readData(1)
        self = bytes[bytes.startIndex]
    }
}

extension Int8: CDRCodable {
    public func encode(to encoder: inout CDREncoder) {
        encoder.encode(UInt8(bitPattern: self))
    }

    public init(from decoder: inout CDRDecoder) throws {
        self = Int8(bitPattern: try decoder.decode(UInt8.self))
    }
}

extension UInt16: CDRCodable {
    public func encode(to encoder: inout CDREncoder) {
        encoder.align(to: 2)
        encoder.appendLittleEndian(self)
    }

    public init(from decoder: inout CDRDecoder) throws {
        try decoder.align(to: 2)
        self = try decoder.readLittleEndian(UInt16.self)
    }
}

extension Int16: CDRCodable {
    public func encode(to encoder: inout CDREncoder) {
        encoder.encode(UInt16(bitPattern: self))
    }

    public init(from decoder: inout CDRDecoder) throws {
        self = Int16(bitPattern: try decoder.decode(UInt16.self))
    }
}

extension UInt32: CDRCodable {
    public func encode(to encoder: inout CDREncoder) {
        encoder.align(to: 4)
        encoder.appendLittleEndian(self)
    }

    public init(from decoder: inout CDRDecoder) throws {
        try decoder.align(to: 4)
        self = try decoder.readLittleEndian(UInt32.self)
    }
}

extension Int32: CDRCodable {
    public func encode(to encoder: inout CDREncoder) {
        encoder.encode(UInt32(bitPattern: self))
    }

    public init(from decoder: inout CDRDecoder) throws {
        self = Int32(bitPattern: try decoder.decode(UInt32.self))
    }
}

extension UInt64: CDRCodable {
    public func encode(to encoder: inout CDREncoder) {
        encoder.align(to: 8)
        encoder.appendLittleEndian(self)
    }

    public init(from decoder: inout CDRDecoder) throws {
        try decoder.align(to: 8)
        self = try decoder.readLittleEndian(UInt64.self)
    }
}

extension Int64: CDRCodable {
    public func encode(to encoder: inout CDREncoder) {
        encoder.encode(UInt64(bitPattern: self))
    }

    public init(from decoder: inout CDRDecoder) throws {
        self = Int64(bitPattern: try decoder.decode(UInt64.self))
    }
}

extension Float: CDRCodable {
    public func encode(to encoder: inout CDREncoder) {
        // ビットパターンのまま書く。NaN のペイロードを往復で保つ。
        encoder.encode(bitPattern)
    }

    public init(from decoder: inout CDRDecoder) throws {
        self = Float(bitPattern: try decoder.decode(UInt32.self))
    }
}

extension Double: CDRCodable {
    public func encode(to encoder: inout CDREncoder) {
        encoder.encode(bitPattern)
    }

    public init(from decoder: inout CDRDecoder) throws {
        self = Double(bitPattern: try decoder.decode(UInt64.self))
    }
}

extension String: CDRCodable {
    public func encode(to encoder: inout CDREncoder) {
        var utf8 = Data(self.utf8)
        utf8.append(0)
        encoder.encode(UInt32(utf8.count))
        encoder.appendRaw(utf8)
    }

    public init(from decoder: inout CDRDecoder) throws {
        let count = Int(try decoder.decode(UInt32.self))
        if count == 0 {
            self = ""
            return
        }
        guard count <= decoder.remaining else { throw CDRError.oversizedCount }
        let raw = try decoder.readData(count)
        guard raw.last == 0 else { throw CDRError.missingNUL }
        let payload = raw.dropLast()
        guard let value = String(bytes: payload, encoding: .utf8) else {
            throw CDRError.invalidUTF8
        }
        self = value
    }
}

extension Data: CDRCodable {
    public func encode(to encoder: inout CDREncoder) {
        encoder.encode(UInt32(count))
        encoder.appendRaw(self)
    }

    public init(from decoder: inout CDRDecoder) throws {
        let count = Int(try decoder.decode(UInt32.self))
        guard count <= decoder.remaining else { throw CDRError.oversizedCount }
        self = try decoder.readData(count)
    }
}

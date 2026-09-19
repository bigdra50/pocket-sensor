import Foundation

/// XCDR version 1、リトルエンディアン。ヘッダは `00 01 00 00` だけを受け付ける。
public struct CDRDecoder {
    private let data: Data
    private var pos: Int

    public init(data: Data) throws {
        guard data.count >= 4 else { throw CDRError.truncated }
        guard data[data.startIndex] == 0x00,
              data[data.startIndex + 1] == 0x01,
              data[data.startIndex + 2] == 0x00,
              data[data.startIndex + 3] == 0x00
        else {
            throw CDRError.badHeader
        }
        self.data = data
        pos = data.startIndex + 4
    }

    public var remaining: Int { data.count - pos }

    public mutating func decode<T: CDRDecodable>(_: T.Type) throws -> T {
        try T(from: &self)
    }

    public mutating func decodeSequence<T: CDRDecodable>(_: T.Type) throws -> [T] {
        let count = Int(try decode(UInt32.self))
        guard count <= remaining else { throw CDRError.oversizedCount }
        var result: [T] = []
        result.reserveCapacity(count)
        for _ in 0 ..< count {
            result.append(try decode(T.self))
        }
        return result
    }

    public mutating func decodeFixedArray<T: CDRDecodable>(_: T.Type, count: Int) throws -> [T] {
        var result: [T] = []
        result.reserveCapacity(count)
        for _ in 0 ..< count {
            result.append(try decode(T.self))
        }
        return result
    }

    mutating func align(to alignment: Int) throws {
        let a = min(max(alignment, 1), 8)
        let offset = pos - data.startIndex - 4
        let remainder = offset % a
        if remainder != 0 {
            let pad = a - remainder
            guard remaining >= pad else { throw CDRError.truncated }
            pos += pad
        }
    }

    mutating func readData(_ count: Int) throws -> Data {
        guard count >= 0, remaining >= count else { throw CDRError.truncated }
        let start = pos
        pos += count
        return data.subdata(in: start ..< pos)
    }

    mutating func readLittleEndian<T: FixedWidthInteger>(_: T.Type) throws -> T {
        let size = MemoryLayout<T>.size
        guard remaining >= size else { throw CDRError.truncated }
        var value: T = 0
        _ = withUnsafeMutableBytes(of: &value) { dest in
            data.copyBytes(to: dest, from: pos ..< pos + size)
        }
        pos += size
        return T(littleEndian: value)
    }
}

import Foundation

/// XCDR version 1、リトルエンディアン。
/// 整列はカプセル化ヘッダ（4 バイト）の直後を原点とし、最大 8 バイトまで。
public struct CDREncoder {
    private var buffer: Data

    public init() {
        // representation identifier 0x0001 (CDR_LE) と options 0x0000
        buffer = Data([0x00, 0x01, 0x00, 0x00])
    }

    public var data: Data { buffer }

    public mutating func encode<T: CDREncodable>(_ value: T) {
        value.encode(to: &self)
    }

    public mutating func encodeSequence<T: CDREncodable>(_ values: [T]) {
        encode(UInt32(values.count))
        for value in values {
            encode(value)
        }
    }

    /// 固定長配列。個数が合わないときはデバッグでは断言し、リリースでは 0 埋めか切り詰めで後続の整列を壊さない。
    public mutating func encodeFixedArray<T: CDREncodable>(_ values: [T], count: Int, zero: T) {
        var elems = values
        if elems.count != count {
            assert(elems.count == count, "fixed array length \(elems.count) != \(count)")
            if elems.count > count {
                elems = Array(elems.prefix(count))
            } else {
                elems.append(contentsOf: Array(repeating: zero, count: count - elems.count))
            }
        }
        for value in elems {
            encode(value)
        }
    }

    mutating func align(to alignment: Int) {
        let a = min(max(alignment, 1), 8)
        let offset = buffer.count - 4
        let remainder = offset % a
        if remainder != 0 {
            let pad = a - remainder
            buffer.append(contentsOf: repeatElement(UInt8(0), count: pad))
        }
    }

    mutating func appendRaw(_ bytes: Data) {
        buffer.append(bytes)
    }

    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { raw in
            buffer.append(contentsOf: raw)
        }
    }
}

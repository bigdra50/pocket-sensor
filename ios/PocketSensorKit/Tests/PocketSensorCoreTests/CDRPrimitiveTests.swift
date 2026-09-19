import Foundation
import PocketSensorCore
import XCTest

final class CDRPrimitiveTests: XCTestCase {
    func testHeaderIsCdrLe() {
        var encoder = CDREncoder()
        encoder.encode(UInt8(0))
        XCTAssertEqual(Array(encoder.data.prefix(4)), [0x00, 0x01, 0x00, 0x00])
    }

    func testUint8ThenUint64Alignment() throws {
        var encoder = CDREncoder()
        encoder.encode(UInt8(1))
        encoder.encode(UInt64(2))
        // ヘッダ直後を原点に、uint8 のあと 7 バイト埋めて uint64 を 8 整列する
        let expected: [UInt8] = [
            0x00, 0x01, 0x00, 0x00,
            0x01,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        ]
        XCTAssertEqual(Array(encoder.data), expected)

        var decoder = try CDRDecoder(data: encoder.data)
        XCTAssertEqual(try decoder.decode(UInt8.self), 1)
        XCTAssertEqual(try decoder.decode(UInt64.self), 2)
    }

    func testEmptyString() throws {
        var encoder = CDREncoder()
        encoder.encode("")
        let expected: [UInt8] = [0x00, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00]
        XCTAssertEqual(Array(encoder.data), expected)
        var decoder = try CDRDecoder(data: encoder.data)
        XCTAssertEqual(try decoder.decode(String.self), "")
    }

    func testStringLength1() throws {
        var encoder = CDREncoder()
        encoder.encode("a")
        let expected: [UInt8] = [0x00, 0x01, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x61, 0x00]
        XCTAssertEqual(Array(encoder.data), expected)
        var decoder = try CDRDecoder(data: encoder.data)
        XCTAssertEqual(try decoder.decode(String.self), "a")
    }

    func testStringLength3() throws {
        var encoder = CDREncoder()
        encoder.encode("abc")
        let expected: [UInt8] = [
            0x00, 0x01, 0x00, 0x00,
            0x04, 0x00, 0x00, 0x00,
            0x61, 0x62, 0x63, 0x00,
        ]
        XCTAssertEqual(Array(encoder.data), expected)
        var decoder = try CDRDecoder(data: encoder.data)
        XCTAssertEqual(try decoder.decode(String.self), "abc")
    }

    func testStringLength4() throws {
        var encoder = CDREncoder()
        encoder.encode("abcd")
        let expected: [UInt8] = [
            0x00, 0x01, 0x00, 0x00,
            0x05, 0x00, 0x00, 0x00,
            0x61, 0x62, 0x63, 0x64, 0x00,
        ]
        XCTAssertEqual(Array(encoder.data), expected)
        var decoder = try CDRDecoder(data: encoder.data)
        XCTAssertEqual(try decoder.decode(String.self), "abcd")
    }

    func testSequenceAfterOddString() throws {
        var encoder = CDREncoder()
        encoder.encode("x")
        encoder.encodeSequence([UInt32(1), UInt32(2)])
        let expected: [UInt8] = [
            0x00, 0x01, 0x00, 0x00,
            0x02, 0x00, 0x00, 0x00, 0x78, 0x00,
            0x00, 0x00,
            0x02, 0x00, 0x00, 0x00,
            0x01, 0x00, 0x00, 0x00,
            0x02, 0x00, 0x00, 0x00,
        ]
        XCTAssertEqual(Array(encoder.data), expected)
        var decoder = try CDRDecoder(data: encoder.data)
        XCTAssertEqual(try decoder.decode(String.self), "x")
        XCTAssertEqual(try decoder.decodeSequence(UInt32.self), [1, 2])
    }

    func testTruncatedPayloadThrows() {
        XCTAssertThrowsError(try CDRDecoder(data: Data([0x00, 0x01, 0x00]))) { error in
            XCTAssertEqual(error as? CDRError, .truncated)
        }
        let headerOnly = Data([0x00, 0x01, 0x00, 0x00])
        var decoder = try? CDRDecoder(data: headerOnly)
        XCTAssertThrowsError(try decoder?.decode(UInt64.self)) { error in
            XCTAssertEqual(error as? CDRError, .truncated)
        }
    }

    func testBadHeaderThrows() {
        XCTAssertThrowsError(try CDRDecoder(data: Data([0x00, 0x00, 0x00, 0x00]))) { error in
            XCTAssertEqual(error as? CDRError, .badHeader)
        }
        XCTAssertThrowsError(try CDRDecoder(data: Data([0x00, 0x07, 0x00, 0x00]))) { error in
            XCTAssertEqual(error as? CDRError, .badHeader)
        }
    }

    func testOversizedCountThrowsBeforeAllocating() throws {
        // uint32 個数に 1_000_000 を書き、中身は付けない
        let payload = Data([0x00, 0x01, 0x00, 0x00, 0x40, 0x42, 0x0F, 0x00])
        var decoder = try CDRDecoder(data: payload)
        XCTAssertThrowsError(try decoder.decodeSequence(UInt64.self)) { error in
            XCTAssertEqual(error as? CDRError, .oversizedCount)
        }
    }

    func testNegativeIntRoundTrip() throws {
        var encoder = CDREncoder()
        encoder.encode(Int32(-1))
        encoder.encode(Int8(-128))
        var decoder = try CDRDecoder(data: encoder.data)
        XCTAssertEqual(try decoder.decode(Int32.self), -1)
        XCTAssertEqual(try decoder.decode(Int8.self), -128)
    }

    func testFloatNaNPreservesBits() throws {
        let nan = Float(bitPattern: 0x7FC0_0000)
        var encoder = CDREncoder()
        encoder.encode(nan)
        var decoder = try CDRDecoder(data: encoder.data)
        let back = try decoder.decode(Float.self)
        XCTAssertEqual(back.bitPattern, 0x7FC0_0000)
    }

    func testUint8SequenceAppendsWithoutPerByteLoop() throws {
        let blob = Data((0 ..< 64).map { UInt8($0) })
        var encoder = CDREncoder()
        encoder.encode(blob)
        var decoder = try CDRDecoder(data: encoder.data)
        XCTAssertEqual(try decoder.decode(Data.self), blob)
    }
}

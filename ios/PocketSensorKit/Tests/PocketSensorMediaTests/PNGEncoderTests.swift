import CoreGraphics
import Dispatch
import Foundation
import ImageIO
import PocketSensorMedia
import XCTest

final class PNGEncoderTests: XCTestCase {
    func testGray16RoundTripIncludesValuesAbove255AndZero() throws {
        let width = 4
        let height = 2
        let samples: [UInt16] = [0, 1, 255, 256, 1000, 32768, 65535, 2]
        let png = try XCTUnwrap(PNGEncoder.gray16(width: width, height: height, pixels: u16Data(samples)))
        let ihdr = try XCTUnwrap(pngIHDR(png))
        XCTAssertEqual(ihdr.bitDepth, 16)
        XCTAssertEqual(ihdr.colorType, 0)
        XCTAssertEqual(ihdr.interlace, 0)
        let decoded = try decodeGray16PNG(png)
        XCTAssertEqual(decoded.width, width)
        XCTAssertEqual(decoded.height, height)
        XCTAssertEqual(decoded.pixels, samples)
    }

    func testGray8RoundTrip() throws {
        let width = 3
        let height = 2
        let samples: [UInt8] = [0, 1, 2, 255, 128, 3]
        let png = try XCTUnwrap(PNGEncoder.gray8(width: width, height: height, pixels: Data(samples)))
        let ihdr = try XCTUnwrap(pngIHDR(png))
        XCTAssertEqual(ihdr.bitDepth, 8)
        XCTAssertEqual(ihdr.colorType, 0)
        XCTAssertEqual(ihdr.interlace, 0)
        let decoded = try decodeGray8PNG(png)
        XCTAssertEqual(decoded.pixels, samples)
    }

    func testSharedVectorsDecodeWithImageIO() throws {
        let root = try pngVectorJSON()
        let rows = try XCTUnwrap(root["cases"] as? [[String: Any]])
        XCTAssertFalse(rows.isEmpty)
        for row in rows {
            let kind = try XCTUnwrap(row["kind"] as? String)
            let width = jsonInt(row["width"] as Any)
            let height = jsonInt(row["height"] as Any)
            let pixels = try XCTUnwrap(row["pixels"] as? [Any]).map(jsonInt)
            let b64 = try XCTUnwrap(row["png_b64"] as? String)
            let png = try XCTUnwrap(Data(base64Encoded: b64))
            if kind == "gray16" {
                let decoded = try decodeGray16PNG(png)
                XCTAssertEqual(decoded.width, width)
                XCTAssertEqual(decoded.height, height)
                XCTAssertEqual(decoded.pixels, pixels.map { UInt16($0) })
            } else {
                XCTAssertEqual(kind, "gray8")
                let decoded = try decodeGray8PNG(png)
                XCTAssertEqual(decoded.width, width)
                XCTAssertEqual(decoded.height, height)
                XCTAssertEqual(decoded.pixels, pixels.map { UInt8($0) })
            }
        }
    }

    func testRejectsEmptySize() {
        XCTAssertNil(PNGEncoder.gray16(width: 0, height: 2, pixels: Data(count: 4)))
        XCTAssertNil(PNGEncoder.gray8(width: 2, height: 0, pixels: Data(count: 2)))
        XCTAssertNil(PNGEncoder.gray16(width: 2, height: 2, pixels: Data(count: 2)))
    }

    func testMedianEncodeTimeAndSizeForSimSizedBuffers() throws {
        let width = 256
        let height = 192
        var depth = [UInt16](repeating: 1500, count: width * height)
        var conf = [UInt8](repeating: 2, count: width * height)
        for row in 0 ..< 8 {
            for col in 0 ..< 8 {
                depth[row * width + col] = 0
                conf[row * width + col] = 0
            }
        }
        let depthData = u16Data(depth)
        let confData = Data(conf)
        _ = PNGEncoder.gray16(width: width, height: height, pixels: depthData)
        _ = PNGEncoder.gray8(width: width, height: height, pixels: confData)

        var depthNs: [UInt64] = []
        var depthSizes: [Int] = []
        var confNs: [UInt64] = []
        var confSizes: [Int] = []
        for _ in 0 ..< 50 {
            let t0 = DispatchTime.now().uptimeNanoseconds
            let depthPNG = try XCTUnwrap(PNGEncoder.gray16(width: width, height: height, pixels: depthData))
            let t1 = DispatchTime.now().uptimeNanoseconds
            depthNs.append(t1 &- t0)
            depthSizes.append(depthPNG.count)
            let t2 = DispatchTime.now().uptimeNanoseconds
            let confPNG = try XCTUnwrap(PNGEncoder.gray8(width: width, height: height, pixels: confData))
            let t3 = DispatchTime.now().uptimeNanoseconds
            confNs.append(t3 &- t2)
            confSizes.append(confPNG.count)
        }
        let depthTime = median(depthNs)
        let confTime = median(confNs)
        let depthSize = median(depthSizes.map { UInt64($0) })
        let confSize = median(confSizes.map { UInt64($0) })
        print(
            "PNGEncoder median n=50 sim 256x192 depth_ns=\(depthTime) depth_bytes=\(depthSize) conf_ns=\(confTime) conf_bytes=\(confSize)"
        )
        XCTAssertGreaterThan(depthSize, 0)
        XCTAssertGreaterThan(confSize, 0)
    }
}

func decodeGray16PNG(_ data: Data) throws -> (width: Int, height: Int, pixels: [UInt16]) {
    let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
    let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    let width = image.width
    let height = image.height
    var pixels = [UInt16](repeating: 0, count: width * height)
    let colorSpace = CGColorSpaceCreateDeviceGray()
    let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
    let ok = pixels.withUnsafeMutableBytes { raw -> Bool in
        guard let ctx = CGContext(
            data: raw.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 16,
            bytesPerRow: width * 2,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else { return false }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    XCTAssertTrue(ok, "failed to draw 16-bit PNG into a little-endian gray context")
    return (width, height, pixels)
}

func decodeGray8PNG(_ data: Data) throws -> (width: Int, height: Int, pixels: [UInt8]) {
    let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
    let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    let width = image.width
    let height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height)
    let colorSpace = CGColorSpaceCreateDeviceGray()
    let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
    let ok = pixels.withUnsafeMutableBytes { raw -> Bool in
        guard let ctx = CGContext(
            data: raw.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else { return false }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    XCTAssertTrue(ok, "failed to draw 8-bit PNG into a gray context")
    return (width, height, pixels)
}

private func pngIHDR(_ data: Data) -> (bitDepth: Int, colorType: Int, interlace: Int)? {
    guard data.count >= 29 else { return nil }
    return (Int(data[24]), Int(data[25]), Int(data[28]))
}

private func u16Data(_ samples: [UInt16]) -> Data {
    samples.withUnsafeBufferPointer { Data(buffer: $0) }
}

private func median(_ values: [UInt64]) -> UInt64 {
    let sorted = values.sorted()
    return sorted[sorted.count / 2]
}

private func pngVectorJSON() throws -> [String: Any] {
    var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    for _ in 0 ..< 16 {
        let candidate = dir
            .appendingPathComponent("contract")
            .appendingPathComponent("vectors")
            .appendingPathComponent("png.json")
        if FileManager.default.fileExists(atPath: candidate.path) {
            let data = try Data(contentsOf: candidate)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        dir.deleteLastPathComponent()
    }
    throw NSError(domain: "PNGEncoderTests", code: 1)
}

private func jsonInt(_ value: Any) -> Int {
    if let i = value as? Int { return i }
    if let n = value as? NSNumber { return n.intValue }
    return 0
}

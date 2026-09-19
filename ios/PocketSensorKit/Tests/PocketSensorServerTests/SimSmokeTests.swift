import Foundation
import PocketSensorCore
import PocketSensorServer
import XCTest

final class SimSmokeTests: XCTestCase {
    func testSimProducesMatchingOdomAndTrackingTimestamps() throws {
        let exe = try XCTUnwrap(simExecutableURL(), "pocketsensor-sim was not built")
        let process = Process()
        process.executableURL = exe
        process.arguments = ["--port", "0", "--no-bonjour", "--duration", "3"]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        addTeardownBlock {
            if process.isRunning {
                process.terminate()
            }
        }

        let ready = expectation(description: "READY")
        ready.assertForOverFulfill = false
        var port: UInt16 = 0
        var buffer = Data()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            buffer.append(handle.availableData)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = String(data: buffer.subdata(in: buffer.startIndex ..< newline), encoding: .utf8) ?? ""
                buffer.removeSubrange(buffer.startIndex ... newline)
                if line.hasPrefix("READY port="), let value = UInt16(line.dropFirst("READY port=".count)) {
                    port = value
                    ready.fulfill()
                }
            }
        }
        waitCompleted(ready)
        stdout.fileHandleForReading.readabilityHandler = nil
        XCTAssertGreaterThan(port, 0)

        let client = WSTestClient(port: port, protocols: [Subprotocol.sdkV1])
        addTeardownBlock { client.close() }
        XCTAssertNotNil(client.waitOpen())
        let handshake = client.waitHandshake()
        let channels = try XCTUnwrap(handshake.advertise["channels"] as? [[String: Any]])
        let odomId = try XCTUnwrap(jsonUInt32(channels.first { ($0["topic"] as? String)?.hasSuffix("/odom") == true }?["id"]))
        let trackingId = try XCTUnwrap(jsonUInt32(channels.first { ($0["topic"] as? String)?.hasSuffix("/tracking") == true }?["id"]))

        client.sendJSON([
            "op": "subscribe",
            "subscriptions": [
                ["id": 1, "channelId": odomId],
                ["id": 2, "channelId": trackingId],
            ],
        ])

        var odomStamp: UInt64?
        var trackingStamp: UInt64?
        _ = client.waitBinary { data in
            guard case .messageData(let sub, let stamp, _)? = try? FoxgloveBinary.parseServerBinary(data) else {
                return false
            }
            if sub == 1 { odomStamp = stamp }
            if sub == 2 { trackingStamp = stamp }
            return odomStamp != nil && trackingStamp != nil
        }
        XCTAssertEqual(odomStamp, trackingStamp)
        XCTAssertNotNil(odomStamp)
    }

    func testDebugLoopbackRatesStayNearContract() throws {
        let exe = try XCTUnwrap(simExecutableURL(), "pocketsensor-sim was not built")
        let process = Process()
        process.executableURL = exe
        process.arguments = ["--port", "0", "--no-bonjour", "--duration", "8"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        addTeardownBlock {
            if process.isRunning {
                process.terminate()
            }
        }

        let ready = expectation(description: "READY")
        ready.assertForOverFulfill = false
        var port: UInt16 = 0
        var buffer = Data()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            buffer.append(handle.availableData)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = String(data: buffer.subdata(in: buffer.startIndex ..< newline), encoding: .utf8) ?? ""
                buffer.removeSubrange(buffer.startIndex ... newline)
                if line.hasPrefix("READY port="), let value = UInt16(line.dropFirst("READY port=".count)) {
                    port = value
                    ready.fulfill()
                }
            }
        }
        waitCompleted(ready, timeout: 3)
        stdout.fileHandleForReading.readabilityHandler = nil
        XCTAssertGreaterThan(port, 0)

        let client = WSTestClient(port: port, protocols: [Subprotocol.sdkV1])
        addTeardownBlock { client.close() }
        XCTAssertNotNil(client.waitOpen(timeout: 2))
        let handshake = client.waitHandshake()
        let channels = try XCTUnwrap(handshake.advertise["channels"] as? [[String: Any]])
        func id(suffix: String) throws -> UInt32 {
            try XCTUnwrap(jsonUInt32(channels.first { ($0["topic"] as? String)?.hasSuffix(suffix) == true }?["id"]))
        }
        let odomId = try id(suffix: "/odom")
        let trackingId = try id(suffix: "/tracking")
        let colorId = try id(suffix: "/color/image/compressed")
        let colorInfoId = try id(suffix: "/color/camera_info")
        let depthId = try id(suffix: "/depth/image")
        let imuId = try id(suffix: "/imu/data")
        let imuRawId = try id(suffix: "/imu/data_raw")

        client.sendJSON([
            "op": "subscribe",
            "subscriptions": [
                ["id": 1, "channelId": odomId],
                ["id": 2, "channelId": trackingId],
                ["id": 3, "channelId": colorId],
                ["id": 4, "channelId": colorInfoId],
                ["id": 5, "channelId": depthId],
                ["id": 6, "channelId": imuId],
                ["id": 7, "channelId": imuRawId],
            ],
        ])

        pause(0.5)
        _ = client.drainBinaries()
        pause(2.0)
        let frames = client.drainBinaries()

        var stamps: [UInt32: [UInt64]] = [:]
        for data in frames {
            guard case .messageData(let sub, let stamp, _)? = try? FoxgloveBinary.parseServerBinary(data) else {
                continue
            }
            stamps[sub, default: []].append(stamp)
        }
        let imu = stamps[6] ?? []
        let imuRaw = stamps[7] ?? []
        let odom = stamps[1] ?? []
        let color = stamps[3] ?? []
        let depth = stamps[5] ?? []
        let imuHz = Double(imu.count) / 2.0
        let imuRawHz = Double(imuRaw.count) / 2.0
        let odomHz = Double(odom.count) / 2.0
        let colorHz = Double(color.count) / 2.0
        let depthHz = Double(depth.count) / 2.0
        print(
            "SimRate measured imu/data=\(imuHz) imu/data_raw=\(imuRawHz) odom=\(odomHz) color=\(colorHz) depth=\(depthHz)"
        )
        XCTAssertGreaterThanOrEqual(imuHz, 90, "imu/data \(imuHz) Hz")
        XCTAssertGreaterThanOrEqual(imuRawHz, 90, "imu/data_raw \(imuRawHz) Hz")
        XCTAssertGreaterThanOrEqual(odomHz, 27, "odom \(odomHz) Hz")
        XCTAssertGreaterThanOrEqual(colorHz, 13, "color \(colorHz) Hz")
        XCTAssertGreaterThanOrEqual(depthHz, 13, "depth \(depthHz) Hz")

        XCTAssertGreaterThanOrEqual(imu.count, 2)
        var deltas: [UInt64] = []
        for index in 1 ..< imu.count {
            let later = imu[index]
            let earlier = imu[index - 1]
            if later >= earlier {
                deltas.append(later - earlier)
            }
        }
        let medianDt = median(deltas)
        print("SimRate measured imu/data median dt ns=\(medianDt)")
        XCTAssertGreaterThanOrEqual(medianDt, 7_000_000)
        XCTAssertLessThanOrEqual(medianDt, 13_000_000)

        let odomSet = Set(odom)
        let depthSet = Set(depth)
        for stamp in color {
            XCTAssertTrue(odomSet.contains(stamp), "color stamp \(stamp) missing from odom")
            XCTAssertTrue(depthSet.contains(stamp), "color stamp \(stamp) missing from depth")
        }
    }

    private func pause(_ seconds: TimeInterval) {
        let exp = expectation(description: "pause \(seconds)")
        exp.isInverted = true
        _ = XCTWaiter.wait(for: [exp], timeout: seconds)
    }

    private func median(_ values: [UInt64]) -> UInt64 {
        let sorted = values.sorted()
        XCTAssertFalse(sorted.isEmpty)
        return sorted[sorted.count / 2]
    }

    private func waitCompleted(_ expectation: XCTestExpectation, timeout: TimeInterval = 5) {
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(result, .completed)
    }
}

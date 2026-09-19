import Foundation
import PocketSensorCore
import XCTest

final class ClockSyncResponderTests: XCTestCase {
    func testEchoesT1AndWritesWireTimes() throws {
        let request = encodedCDR(PocketsensorMsgs.ClockSync.Request(t1: 42))
        let result = ClockSyncResponder.respond(request: request, t2WireNs: 100, t3WireNs: 101)
        let payload = try result.get()
        var decoder = try CDRDecoder(data: payload)
        let response = try PocketsensorMsgs.ClockSync.Response(from: &decoder)
        XCTAssertEqual(response.t1, 42)
        XCTAssertEqual(response.t2, 100)
        XCTAssertEqual(response.t3, 101)
    }

    func testMalformedRequestFails() {
        let result = ClockSyncResponder.respond(request: Data([0x00]), t2WireNs: 1, t3WireNs: 2)
        switch result {
        case .success:
            XCTFail("expected failure")
        case .failure(let failure):
            XCTAssertEqual(failure.message, "malformed clock_sync request")
        }
    }
}

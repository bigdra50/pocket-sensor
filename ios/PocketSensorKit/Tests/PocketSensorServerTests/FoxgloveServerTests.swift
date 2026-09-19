import Foundation
import PocketSensorCore
import PocketSensorServer
import XCTest

final class FoxgloveServerTests: XCTestCase {
    private var server: FoxgloveServer?
    private var clients: [WSTestClient] = []

    override func tearDown() {
        clients.forEach { $0.close() }
        clients.removeAll()
        server?.stop()
        server = nil
        super.tearDown()
    }

    func testSubprotocolSelection() {
        let port = startServer()
        let both = connect(port: port, protocols: [Subprotocol.websocketV1, Subprotocol.sdkV1])
        XCTAssertEqual(both.waitOpen(), Subprotocol.sdkV1)

        let onlyV1 = connect(port: port, protocols: [Subprotocol.websocketV1])
        XCTAssertEqual(onlyV1.waitOpen(), Subprotocol.websocketV1)

        let rejected = connect(port: port, protocols: ["not-a-protocol"])
        rejected.waitFail()
    }

    func testHandshakeMatchesContract() throws {
        let port = startServer(sessionId: "sess-42", deviceName: "phone")
        let client = connect(port: port)
        XCTAssertNotNil(client.waitOpen())
        let handshake = client.waitHandshake()

        XCTAssertEqual(handshake.info["name"] as? String, "pocketsensor")
        XCTAssertEqual(handshake.info["sessionId"] as? String, "sess-42")
        XCTAssertEqual(handshake.info["supportedEncodings"] as? [String], ["cdr"])
        XCTAssertEqual(
            handshake.info["capabilities"] as? [String],
            ["parameters", "parametersSubscribe", "services"]
        )

        let expectedChannels = FoxgloveAdvertisement.channels(deviceName: "phone", stages: [1])
        let advertised = try XCTUnwrap(handshake.advertise["channels"] as? [[String: Any]])
        XCTAssertEqual(advertised.count, expectedChannels.count)
        for (row, expected) in zip(advertised, expectedChannels) {
            XCTAssertEqual(jsonUInt32(row["id"]), expected.id)
            XCTAssertEqual(row["topic"] as? String, expected.topic)
            XCTAssertEqual(row["encoding"] as? String, "cdr")
            XCTAssertEqual(row["schemaEncoding"] as? String, "ros2msg")
            XCTAssertEqual(row["schemaName"] as? String, expected.schemaName)
            XCTAssertEqual(row["schema"] as? String, expected.schema)
        }

        let expectedServices = FoxgloveAdvertisement.services(deviceName: "phone", stages: [1])
        let services = try XCTUnwrap(handshake.services["services"] as? [[String: Any]])
        XCTAssertEqual(services.count, expectedServices.count)
        for (row, expected) in zip(services, expectedServices) {
            XCTAssertEqual(jsonUInt32(row["id"]), expected.id)
            XCTAssertEqual(row["name"] as? String, expected.name)
            XCTAssertEqual(row["type"] as? String, expected.type)
            let request = try XCTUnwrap(row["request"] as? [String: Any])
            XCTAssertEqual(request["schemaName"] as? String, expected.request.schemaName)
            XCTAssertEqual(request["encoding"] as? String, "cdr")
            XCTAssertEqual(request["schemaEncoding"] as? String, "ros2msg")
            let response = try XCTUnwrap(row["response"] as? [String: Any])
            XCTAssertEqual(response["schemaName"] as? String, expected.response.schemaName)
        }
    }

    func testSubscribePublishIsByteExactThenUnsubscribeStops() throws {
        let port = startServer()
        let client = connect(port: port)
        XCTAssertNotNil(client.waitOpen())
        _ = client.waitHandshake()

        let subscribed = expectation(description: "odom subscribers")
        server?.onSubscribersChange = { key, has in
            if key == "odom", has { subscribed.fulfill() }
        }
        client.sendJSON([
            "op": "subscribe",
            "subscriptions": [["id": 7, "channelId": 1]],
        ])
        waitCompleted(subscribed)

        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF])
        server?.publish("odom", stampNs: 42, payload: payload)
        let frame = client.waitBinary { data in
            guard case .messageData(let sub, let stamp, let body)? = try? FoxgloveBinary.parseServerBinary(data) else {
                return false
            }
            return sub == 7 && stamp == 42 && body == payload
        }
        XCTAssertEqual(
            try FoxgloveBinary.parseServerBinary(frame),
            .messageData(subscriptionId: 7, timestampNs: 42, payload: payload)
        )

        let stopped = expectation(description: "odom stopped")
        server?.onSubscribersChange = { key, has in
            if key == "odom", !has { stopped.fulfill() }
        }
        client.sendJSON(["op": "unsubscribe", "subscriptionIds": [7]])
        waitCompleted(stopped)

        let before = client.pendingBinaryCount
        server?.publish("odom", stampNs: 99, payload: Data([0x00]))
        let extra = expectation(description: "no extra odom")
        extra.isInverted = true
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
            if client.pendingBinaryCount > before {
                extra.fulfill()
            }
        }
        waitCompleted(extra, timeout: 0.5)
        XCTAssertEqual(client.pendingBinaryCount, before)
    }

    func testLatchedDeliveryRightAfterSubscribe() throws {
        let port = startServer()
        let payload = Data([0x11, 0x22])
        server?.setLatched("tf_static", stampNs: 8, payload: payload)
        let client = connect(port: port)
        XCTAssertNotNil(client.waitOpen())
        let handshake = client.waitHandshake()
        let channels = try XCTUnwrap(handshake.advertise["channels"] as? [[String: Any]])
        let tfStatic = try XCTUnwrap(channels.first { ($0["topic"] as? String) == "/tf_static" })
        let channelId = try XCTUnwrap(jsonUInt32(tfStatic["id"]))

        client.sendJSON([
            "op": "subscribe",
            "subscriptions": [["id": 3, "channelId": channelId]],
        ])
        let frame = client.waitBinary { data in
            (try? FoxgloveBinary.parseServerBinary(data)) == .messageData(
                subscriptionId: 3,
                timestampNs: 8,
                payload: payload
            )
        }
        XCTAssertEqual(
            try FoxgloveBinary.parseServerBinary(frame),
            .messageData(subscriptionId: 3, timestampNs: 8, payload: payload)
        )
    }

    func testOnSubscribersChangeAcrossTwoClients() {
        let port = startServer()
        let a = connect(port: port)
        let b = connect(port: port)
        XCTAssertNotNil(a.waitOpen())
        XCTAssertNotNil(b.waitOpen())
        _ = a.waitHandshake()
        _ = b.waitHandshake()

        let started = expectation(description: "0 to 1")
        let stopped = expectation(description: "1 to 0")
        let lock = NSLock()
        var flags: [Bool] = []
        server?.onSubscribersChange = { key, has in
            guard key == "odom" else { return }
            lock.lock()
            flags.append(has)
            lock.unlock()
            if has { started.fulfill() }
            else { stopped.fulfill() }
        }

        a.sendJSON(["op": "subscribe", "subscriptions": [["id": 1, "channelId": 1]]])
        waitCompleted(started)
        b.sendJSON(["op": "subscribe", "subscriptions": [["id": 1, "channelId": 1]]])
        let noSecondStart = expectation(description: "second client stays silent")
        noSecondStart.isInverted = true
        waitCompleted(noSecondStart, timeout: 0.3)
        a.sendJSON(["op": "unsubscribe", "subscriptionIds": [1]])
        let noStopYet = expectation(description: "first unsubscribe stays silent")
        noStopYet.isInverted = true
        waitCompleted(noStopYet, timeout: 0.3)
        lock.lock()
        XCTAssertEqual(flags, [true])
        lock.unlock()
        b.sendJSON(["op": "unsubscribe", "subscriptionIds": [1]])
        waitCompleted(stopped)
        lock.lock()
        XCTAssertEqual(flags, [true, false])
        lock.unlock()
    }

    func testParametersGetSetClampReadOnlyAndNotifySecondClient() throws {
        let port = startServer()
        let a = connect(port: port)
        let b = connect(port: port)
        XCTAssertNotNil(a.waitOpen())
        XCTAssertNotNil(b.waitOpen())
        _ = a.waitHandshake()
        _ = b.waitHandshake()

        b.sendJSON(["op": "subscribeParameterUpdates", "parameterNames": ["pose.rate"]])

        a.sendJSON([
            "op": "setParameters",
            "id": "clamp",
            "parameters": [["name": "pose.rate", "value": 100]],
        ])
        let clamped = a.waitText { ($0["op"] as? String) == "parameterValues" && ($0["id"] as? String) == "clamp" }
        let clampParams = try XCTUnwrap(clamped["parameters"] as? [[String: Any]])
        XCTAssertEqual(clampParams.first?["name"] as? String, "pose.rate")
        XCTAssertEqual((clampParams.first?["value"] as? NSNumber)?.doubleValue, 60)

        let notified = b.waitText { object in
            (object["op"] as? String) == "parameterValues" && object["id"] == nil
        }
        XCTAssertNil(notified["id"])
        let notifyParams = try XCTUnwrap(notified["parameters"] as? [[String: Any]])
        XCTAssertEqual(notifyParams.first?["name"] as? String, "pose.rate")
        XCTAssertEqual((notifyParams.first?["value"] as? NSNumber)?.doubleValue, 60)

        a.sendJSON([
            "op": "setParameters",
            "id": "ro",
            "parameters": [["name": "device.name", "value": "hack"]],
        ])
        let readonly = a.waitText { ($0["op"] as? String) == "parameterValues" && ($0["id"] as? String) == "ro" }
        let roParams = try XCTUnwrap(readonly["parameters"] as? [[String: Any]])
        XCTAssertEqual(roParams.first?["value"] as? String, "pocketsensor")

        a.sendJSON(["op": "getParameters", "parameterNames": ["device.name"], "id": "get"])
        let got = a.waitText { ($0["op"] as? String) == "parameterValues" && ($0["id"] as? String) == "get" }
        let gotParams = try XCTUnwrap(got["parameters"] as? [[String: Any]])
        XCTAssertEqual(gotParams.first?["value"] as? String, "pocketsensor")
    }

    func testClockSyncServiceAndUnknownServiceFailure() throws {
        let port = startServer()
        let client = connect(port: port)
        XCTAssertNotNil(client.waitOpen())
        let handshake = client.waitHandshake()
        let services = try XCTUnwrap(handshake.services["services"] as? [[String: Any]])
        let clock = try XCTUnwrap(services.first { ($0["name"] as? String)?.hasSuffix("/clock_sync") == true })
        let clockId = try XCTUnwrap(jsonUInt32(clock["id"]))

        let request = encodedCDR(PocketsensorMsgs.ClockSync.Request(t1: 123))
        client.sendData(FoxgloveBinary.serviceCallRequest(serviceId: clockId, callId: 7, encoding: "cdr", payload: request))
        let reply = client.waitBinary { data in
            guard case .serviceCallResponse(_, let callId, _, _)? = try? FoxgloveBinary.parseServerBinary(data) else {
                return false
            }
            return callId == 7
        }
        guard case .serviceCallResponse(_, _, let encoding, let payload) = try FoxgloveBinary.parseServerBinary(reply) else {
            return XCTFail("expected service response")
        }
        XCTAssertEqual(encoding, "cdr")
        var decoder = try CDRDecoder(data: payload)
        let response = try PocketsensorMsgs.ClockSync.Response(from: &decoder)
        XCTAssertEqual(response.t1, 123)
        XCTAssertLessThanOrEqual(response.t2, response.t3)
        XCTAssertGreaterThan(response.t2, 1_700_000_000_000_000_000)

        client.sendData(FoxgloveBinary.serviceCallRequest(serviceId: 999, callId: 8, encoding: "cdr", payload: Data()))
        let failure = client.waitOp("serviceCallFailure")
        XCTAssertEqual(jsonUInt32(failure["serviceId"]), 999)
        XCTAssertEqual(jsonUInt32(failure["callId"]), 8)
        XCTAssertEqual(failure["message"] as? String, "unknown service")
    }

    func testPublishBatchFiltersMembersAndSharesTimestamp() throws {
        let port = startServer()
        let client = connect(port: port)
        XCTAssertNotNil(client.waitOpen())
        _ = client.waitHandshake()

        let subscribed = expectation(description: "odom only")
        server?.onSubscribersChange = { key, has in
            if key == "odom", has { subscribed.fulfill() }
        }
        client.sendJSON([
            "op": "subscribe",
            "subscriptions": [["id": 4, "channelId": 1]],
        ])
        waitCompleted(subscribed)

        let odom = Data([0x0A])
        let tracking = Data([0x0B])
        server?.publishBatch(
            group: "arframe",
            stampNs: 77,
            items: [("odom", odom), ("tracking", tracking)]
        )
        let frame = client.waitBinary { data in
            guard case .messageData(let sub, let stamp, let body)? = try? FoxgloveBinary.parseServerBinary(data) else {
                return false
            }
            return sub == 4 && stamp == 77 && body == odom
        }
        XCTAssertEqual(
            try FoxgloveBinary.parseServerBinary(frame),
            .messageData(subscriptionId: 4, timestampNs: 77, payload: odom)
        )
        XCTAssertEqual(client.pendingBinaryCount, 0)
        let extra = expectation(description: "no tracking")
        extra.isInverted = true
        waitCompleted(extra, timeout: 0.3)
        XCTAssertEqual(client.pendingBinaryCount, 0)
    }

    private func startServer(sessionId: String = "test-session", deviceName: String = "pocketsensor") -> UInt16 {
        let mono = Int64(bitPattern: DispatchTime.now().uptimeNanoseconds)
        let wall = Int64((Date().timeIntervalSince1970 * 1_000_000_000).rounded())
        let started = FoxgloveServer(
            config: ServerConfig(
                port: 0,
                deviceName: deviceName,
                sessionId: sessionId,
                advertiseBonjour: false
            ),
            parameters: ParameterStore(specs: Contract.parameters),
            anchor: ClockAnchor(wallNs: wall, monoNs: mono),
            monoClockNs: { Int64(bitPattern: DispatchTime.now().uptimeNanoseconds) }
        )
        let ready = expectation(description: "listener ready")
        started.onStateChange = { state in
            if state == "ready" { ready.fulfill() }
        }
        started.start()
        waitCompleted(ready)
        server = started
        return try! XCTUnwrap(started.actualPort)
    }

    private func connect(port: UInt16, protocols: [String] = [Subprotocol.sdkV1, Subprotocol.websocketV1]) -> WSTestClient {
        let client = WSTestClient(port: port, protocols: protocols)
        clients.append(client)
        return client
    }

    private func waitCompleted(_ expectation: XCTestExpectation, timeout: TimeInterval = 5) {
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(result, .completed)
    }
}

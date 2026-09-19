import Foundation
import PocketSensorCore
import XCTest

final class FoxgloveProtocolTests: XCTestCase {
    func testServerInfoGolden() {
        let json = FoxgloveServerMessages.serverInfo(
            name: "pocketsensor",
            capabilities: ["parameters", "parametersSubscribe", "services"],
            supportedEncodings: ["cdr"],
            metadata: [:],
            sessionId: "abc"
        )
        XCTAssertEqual(
            json,
            "{\"capabilities\":[\"parameters\",\"parametersSubscribe\",\"services\"],\"metadata\":{},\"name\":\"pocketsensor\",\"op\":\"serverInfo\",\"sessionId\":\"abc\",\"supportedEncodings\":[\"cdr\"]}"
        )
    }

    func testAdvertiseAndStatusGolden() {
        let channel = AdvertisedChannel(
            id: 1,
            topic: "/phone/odom",
            encoding: "cdr",
            schemaName: "nav_msgs/msg/Odometry",
            schema: "string child_frame_id",
            schemaEncoding: "ros2msg"
        )
        XCTAssertEqual(
            FoxgloveServerMessages.advertise([channel]),
            "{\"channels\":[{\"encoding\":\"cdr\",\"id\":1,\"schema\":\"string child_frame_id\",\"schemaEncoding\":\"ros2msg\",\"schemaName\":\"nav_msgs/msg/Odometry\",\"topic\":\"/phone/odom\"}],\"op\":\"advertise\"}"
        )
        XCTAssertFalse(FoxgloveServerMessages.advertise([channel]).contains("\\/"))
        XCTAssertEqual(
            FoxgloveServerMessages.unadvertise([1, 2]),
            "{\"channelIds\":[1,2],\"op\":\"unadvertise\"}"
        )
        XCTAssertEqual(
            FoxgloveServerMessages.status(level: 2, message: "nope"),
            "{\"level\":2,\"message\":\"nope\",\"op\":\"status\"}"
        )
        XCTAssertEqual(
            FoxgloveServerMessages.status(level: 1, message: "dup", id: "s1"),
            "{\"id\":\"s1\",\"level\":1,\"message\":\"dup\",\"op\":\"status\"}"
        )
        XCTAssertEqual(
            FoxgloveServerMessages.removeStatus(["s1"]),
            "{\"op\":\"removeStatus\",\"statusIds\":[\"s1\"]}"
        )
        XCTAssertEqual(
            FoxgloveServerMessages.serviceCallFailure(serviceId: 4, callId: 9, message: "busy"),
            "{\"callId\":9,\"message\":\"busy\",\"op\":\"serviceCallFailure\",\"serviceId\":4}"
        )
    }

    func testParameterValuesEmitFloat64Type() {
        let json = FoxgloveServerMessages.parameterValues(
            [
                ParameterValue(name: "pose.rate", value: .number(30)),
                ParameterValue(name: "flag", value: .bool(true)),
                ParameterValue(name: "device.name", value: .string("phone")),
            ],
            id: "r1"
        )
        XCTAssertEqual(
            json,
            "{\"id\":\"r1\",\"op\":\"parameterValues\",\"parameters\":[{\"name\":\"pose.rate\",\"type\":\"float64\",\"value\":30},{\"name\":\"flag\",\"value\":true},{\"name\":\"device.name\",\"value\":\"phone\"}]}"
        )
    }

    func testAdvertiseServicesGolden() {
        let service = AdvertisedService(
            id: 1,
            name: "/phone/clock_sync",
            type: "pocketsensor_msgs/srv/ClockSync",
            request: ServiceSchema(
                encoding: "cdr",
                schemaName: "pocketsensor_msgs/srv/ClockSync_Request",
                schemaEncoding: "ros2msg",
                schema: "uint64 t1"
            ),
            response: ServiceSchema(
                encoding: "cdr",
                schemaName: "pocketsensor_msgs/srv/ClockSync_Response",
                schemaEncoding: "ros2msg",
                schema: "uint64 t1"
            )
        )
        XCTAssertEqual(
            FoxgloveServerMessages.advertiseServices([service]),
            "{\"op\":\"advertiseServices\",\"services\":[{\"id\":1,\"name\":\"/phone/clock_sync\",\"request\":{\"encoding\":\"cdr\",\"schema\":\"uint64 t1\",\"schemaEncoding\":\"ros2msg\",\"schemaName\":\"pocketsensor_msgs/srv/ClockSync_Request\"},\"response\":{\"encoding\":\"cdr\",\"schema\":\"uint64 t1\",\"schemaEncoding\":\"ros2msg\",\"schemaName\":\"pocketsensor_msgs/srv/ClockSync_Response\"},\"type\":\"pocketsensor_msgs/srv/ClockSync\"}]}"
        )
    }

    func testClientParser() throws {
        let sub = try FoxgloveClientMessages.parse(
            text: "{\"op\":\"subscribe\",\"subscriptions\":[{\"id\":7,\"channelId\":3}]}"
        )
        XCTAssertEqual(sub, .subscribe([ClientSubscription(subscriptionId: 7, channelId: 3)]))

        let unsub = try FoxgloveClientMessages.parse(text: "{\"op\":\"unsubscribe\",\"subscriptionIds\":[7,8]}")
        XCTAssertEqual(unsub, .unsubscribe([7, 8]))

        let get = try FoxgloveClientMessages.parse(text: "{\"op\":\"getParameters\",\"parameterNames\":[],\"id\":\"q\"}")
        XCTAssertEqual(get, .getParameters(names: [], id: "q"))

        let set = try FoxgloveClientMessages.parse(
            text: "{\"op\":\"setParameters\",\"parameters\":[{\"name\":\"pose.rate\",\"value\":15},{\"name\":\"on\",\"value\":true},{\"name\":\"imu.reference_frame\",\"value\":\"arbitrary\"}],\"id\":\"s\"}"
        )
        XCTAssertEqual(
            set,
            .setParameters(
                [
                    ParameterValue(name: "pose.rate", value: .number(15)),
                    ParameterValue(name: "on", value: .bool(true)),
                    ParameterValue(name: "imu.reference_frame", value: .string("arbitrary")),
                ],
                id: "s"
            )
        )

        let subP = try FoxgloveClientMessages.parse(
            text: "{\"op\":\"subscribeParameterUpdates\",\"parameterNames\":[\"pose.rate\"]}"
        )
        XCTAssertEqual(subP, .subscribeParameterUpdates(["pose.rate"]))

        let ignored = try FoxgloveClientMessages.parse(text: "{\"op\":\"advertise\",\"channels\":[]}")
        XCTAssertEqual(ignored, .ignored("advertise"))
        XCTAssertEqual(try FoxgloveClientMessages.parse(text: "{\"op\":\"fetchAsset\"}"), .ignored("fetchAsset"))
    }

    func testMalformedJSONThrows() {
        XCTAssertThrowsError(try FoxgloveClientMessages.parse(text: "{"))
        XCTAssertThrowsError(try FoxgloveClientMessages.parse(text: "[]"))
        XCTAssertThrowsError(try FoxgloveClientMessages.parse(text: "{\"op\":\"subscribe\"}"))
    }

    func testBinaryLayouts() throws {
        let payload = Data([0xAB])
        let message = FoxgloveBinary.messageData(subscriptionId: 1, timestampNs: 2, payload: payload)
        XCTAssertEqual(Array(message), [0x01, 1, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0xAB])

        let example = FoxgloveBinary.messageData(
            subscriptionId: 0x64,
            timestampNs: 0x18D6_AEB0_864F_3998,
            payload: Data()
        )
        XCTAssertEqual(Array(example.prefix(13)), [
            0x01,
            0x64, 0x00, 0x00, 0x00,
            0x98, 0x39, 0x4F, 0x86, 0xB0, 0xAE, 0xD6, 0x18,
        ])

        let response = FoxgloveBinary.serviceCallResponse(
            serviceId: 5,
            callId: 9,
            encoding: "cdr",
            payload: Data([0x01])
        )
        XCTAssertEqual(Array(response.prefix(14)), [
            0x03,
            5, 0, 0, 0,
            9, 0, 0, 0,
            3, 0, 0, 0,
            0x63,
        ])
        XCTAssertEqual(String(data: response.subdata(in: 13 ..< 16), encoding: .utf8), "cdr")
        XCTAssertEqual(Array(response.suffix(1)), [0x01])

        var request = Data([0x02])
        request.append(contentsOf: [8, 0, 0, 0])
        request.append(contentsOf: [1, 0, 0, 0])
        request.append(contentsOf: [3, 0, 0, 0])
        request.append(contentsOf: Array("cdr".utf8))
        request.append(0xFF)
        XCTAssertEqual(
            try FoxgloveBinary.parseClientBinary(request),
            .serviceCallRequest(serviceId: 8, callId: 1, encoding: "cdr", payload: Data([0xFF]))
        )
        XCTAssertEqual(
            FoxgloveBinary.serviceCallRequest(serviceId: 8, callId: 1, encoding: "cdr", payload: Data([0xFF])),
            request
        )
        XCTAssertEqual(
            try FoxgloveBinary.parseServerBinary(message),
            .messageData(subscriptionId: 1, timestampNs: 2, payload: payload)
        )
        XCTAssertEqual(
            try FoxgloveBinary.parseServerBinary(response),
            .serviceCallResponse(serviceId: 5, callId: 9, encoding: "cdr", payload: Data([0x01]))
        )
        XCTAssertEqual(try FoxgloveBinary.parseClientBinary(Data([0x01, 0x00])), .unknown(opcode: 0x01))
        XCTAssertEqual(try FoxgloveBinary.parseClientBinary(Data([0x02])), .unknown(opcode: 0x02))
        XCTAssertThrowsError(try FoxgloveBinary.parseClientBinary(Data())) { error in
            XCTAssertEqual(error as? FoxgloveBinaryError, .empty)
        }
    }

    func testSubprotocolNegotiation() {
        XCTAssertEqual(Subprotocol.negotiate(offered: ["foxglove.websocket.v1", " foxglove.sdk.v1"]), Subprotocol.sdkV1)
        XCTAssertEqual(Subprotocol.negotiate(offered: ["foxglove.websocket.v1"]), Subprotocol.websocketV1)
        XCTAssertEqual(Subprotocol.negotiate(offered: [" foxglove.sdk.v1"]), Subprotocol.sdkV1)
        XCTAssertNil(Subprotocol.negotiate(offered: ["nope"]))
        XCTAssertNil(Subprotocol.negotiate(offered: []))
    }
}

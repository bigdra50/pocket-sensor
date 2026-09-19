import Foundation

public enum FoxgloveBinaryError: Error, Equatable {
    /// 空入力には opcode が無いので、未認識 opcode 0 を捏造しない。
    case empty
}

public enum FoxgloveBinary {
    public static func messageData(subscriptionId: UInt32, timestampNs: UInt64, payload: Data) -> Data {
        var data = Data(capacity: 13 + payload.count)
        data.append(0x01)
        appendUInt32(&data, subscriptionId)
        appendUInt64(&data, timestampNs)
        data.append(payload)
        return data
    }

    public static func serviceCallResponse(
        serviceId: UInt32,
        callId: UInt32,
        encoding: String,
        payload: Data
    ) -> Data {
        serviceCall(opcode: 0x03, serviceId: serviceId, callId: callId, encoding: encoding, payload: payload)
    }

    public enum ClientBinary: Equatable, Sendable {
        case serviceCallRequest(serviceId: UInt32, callId: UInt32, encoding: String, payload: Data)
        case unknown(opcode: UInt8)
    }

    public static func parseClientBinary(_ data: Data) throws -> ClientBinary {
        guard let opcode = data.first else { throw FoxgloveBinaryError.empty }
        if opcode == 0x02 {
            if let parsed = parseServiceCall(data) {
                return .serviceCallRequest(
                    serviceId: parsed.serviceId,
                    callId: parsed.callId,
                    encoding: parsed.encoding,
                    payload: parsed.payload
                )
            }
        }
        return .unknown(opcode: opcode)
    }

    private static func serviceCall(
        opcode: UInt8,
        serviceId: UInt32,
        callId: UInt32,
        encoding: String,
        payload: Data
    ) -> Data {
        let encodingBytes = Data(encoding.utf8)
        var data = Data(capacity: 13 + encodingBytes.count + payload.count)
        data.append(opcode)
        appendUInt32(&data, serviceId)
        appendUInt32(&data, callId)
        appendUInt32(&data, UInt32(encodingBytes.count))
        data.append(encodingBytes)
        data.append(payload)
        return data
    }

    private static func parseServiceCall(_ data: Data) -> (
        serviceId: UInt32,
        callId: UInt32,
        encoding: String,
        payload: Data
    )? {
        guard data.count >= 13 else { return nil }
        let serviceId = readUInt32(data, 1)
        let callId = readUInt32(data, 5)
        let encodingLength = Int(readUInt32(data, 9))
        let encodingStart = 13
        let encodingEnd = encodingStart + encodingLength
        guard encodingEnd <= data.count else { return nil }
        let encodingData = data.subdata(in: encodingStart ..< encodingEnd)
        guard let encoding = String(data: encodingData, encoding: .utf8) else { return nil }
        let payload = data.subdata(in: encodingEnd ..< data.count)
        return (serviceId, callId, encoding, payload)
    }
}

public enum Subprotocol {
    public static let sdkV1 = "foxglove.sdk.v1"
    public static let websocketV1 = "foxglove.websocket.v1"

    /// 提示された名前は前後の空白を除いてから比べる。sdk.v1 を優先する。
    public static func negotiate(offered: [String]) -> String? {
        let names = Set(offered.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        if names.contains(sdkV1) { return sdkV1 }
        if names.contains(websocketV1) { return websocketV1 }
        return nil
    }
}

private func appendUInt32(_ data: inout Data, _ value: UInt32) {
    var le = value.littleEndian
    withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
}

private func appendUInt64(_ data: inout Data, _ value: UInt64) {
    var le = value.littleEndian
    withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
}

private func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
    var value: UInt32 = 0
    _ = withUnsafeMutableBytes(of: &value) { dest in
        data.copyBytes(to: dest, from: offset ..< (offset + 4))
    }
    return UInt32(littleEndian: value)
}

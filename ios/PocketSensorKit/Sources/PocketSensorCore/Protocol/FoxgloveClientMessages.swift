import Foundation

public enum FoxgloveParseError: Error, Equatable {
    case malformed
}

public struct ClientSubscription: Equatable, Sendable {
    public var subscriptionId: UInt32
    public var channelId: UInt32

    public init(subscriptionId: UInt32, channelId: UInt32) {
        self.subscriptionId = subscriptionId
        self.channelId = channelId
    }
}

public enum FoxgloveClientMessage: Equatable, Sendable {
    case subscribe([ClientSubscription])
    case unsubscribe([UInt32])
    case getParameters(names: [String], id: String?)
    case setParameters([ParameterValue], id: String?)
    case subscribeParameterUpdates([String])
    case unsubscribeParameterUpdates([String])
    case ignored(String)
}

public enum FoxgloveClientMessages {
    public static func parse(text: String) throws -> FoxgloveClientMessage {
        guard let data = text.data(using: .utf8) else { throw FoxgloveParseError.malformed }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw FoxgloveParseError.malformed
        }
        guard let dict = object as? [String: Any], let op = dict["op"] as? String else {
            throw FoxgloveParseError.malformed
        }
        switch op {
        case "subscribe":
            guard let rows = dict["subscriptions"] as? [[String: Any]] else { throw FoxgloveParseError.malformed }
            var items: [ClientSubscription] = []
            items.reserveCapacity(rows.count)
            for row in rows {
                guard let subscriptionId = jsonUInt32(row["id"]), let channelId = jsonUInt32(row["channelId"]) else {
                    throw FoxgloveParseError.malformed
                }
                items.append(ClientSubscription(subscriptionId: subscriptionId, channelId: channelId))
            }
            return .subscribe(items)
        case "unsubscribe":
            guard let ids = dict["subscriptionIds"] as? [Any] else { throw FoxgloveParseError.malformed }
            return .unsubscribe(try ids.map { value in
                guard let id = jsonUInt32(value) else { throw FoxgloveParseError.malformed }
                return id
            })
        case "getParameters":
            let names = (dict["parameterNames"] as? [String]) ?? []
            return .getParameters(names: names, id: dict["id"] as? String)
        case "setParameters":
            guard let rows = dict["parameters"] as? [[String: Any]] else { throw FoxgloveParseError.malformed }
            return .setParameters(try rows.map(parseParameter), id: dict["id"] as? String)
        case "subscribeParameterUpdates":
            let names = (dict["parameterNames"] as? [String]) ?? []
            return .subscribeParameterUpdates(names)
        case "unsubscribeParameterUpdates":
            let names = (dict["parameterNames"] as? [String]) ?? []
            return .unsubscribeParameterUpdates(names)
        default:
            return .ignored(op)
        }
    }
}

private func parseParameter(_ row: [String: Any]) throws -> ParameterValue {
    guard let name = row["name"] as? String else { throw FoxgloveParseError.malformed }
    guard let raw = row["value"] else { throw FoxgloveParseError.malformed }
    if let flag = jsonBool(raw) {
        return ParameterValue(name: name, value: .bool(flag))
    }
    if let text = raw as? String {
        return ParameterValue(name: name, value: .string(text))
    }
    if let number = jsonNumber(raw) {
        return ParameterValue(name: name, value: .number(number))
    }
    throw FoxgloveParseError.malformed
}

private func jsonUInt32(_ value: Any?) -> UInt32? {
    guard let value else { return nil }
    if let n = value as? UInt32 { return n }
    if let n = value as? Int, n >= 0 { return UInt32(n) }
    if let n = value as? NSNumber {
        if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
        let v = n.int64Value
        if v < 0 || v > Int64(UInt32.max) { return nil }
        return UInt32(v)
    }
    return nil
}

private func jsonNumber(_ value: Any) -> Double? {
    if let n = value as? NSNumber {
        if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
        return n.doubleValue
    }
    if let d = value as? Double { return d }
    if let i = value as? Int { return Double(i) }
    return nil
}

private func jsonBool(_ value: Any) -> Bool? {
    if let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() {
        return n.boolValue
    }
    return nil
}

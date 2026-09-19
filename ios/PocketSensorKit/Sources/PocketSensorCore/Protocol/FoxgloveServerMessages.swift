import Foundation

public struct ParameterValue: Equatable, Sendable {
    public var name: String
    public var value: Value

    public init(name: String, value: Value) {
        self.name = name
        self.value = value
    }

    public enum Value: Equatable, Sendable {
        case number(Double)
        case bool(Bool)
        case string(String)
    }

    func jsonObject() -> [String: Any] {
        switch value {
        case .number(let number):
            return ["name": name, "type": "float64", "value": number]
        case .bool(let flag):
            return ["name": name, "value": flag]
        case .string(let text):
            return ["name": name, "value": text]
        }
    }
}

public struct AdvertisedChannel: Equatable, Sendable {
    public var id: UInt32
    public var topic: String
    public var encoding: String
    public var schemaName: String
    public var schema: String
    public var schemaEncoding: String

    public init(
        id: UInt32,
        topic: String,
        encoding: String,
        schemaName: String,
        schema: String,
        schemaEncoding: String
    ) {
        self.id = id
        self.topic = topic
        self.encoding = encoding
        self.schemaName = schemaName
        self.schema = schema
        self.schemaEncoding = schemaEncoding
    }

    func jsonObject() -> [String: Any] {
        [
            "id": id,
            "topic": topic,
            "encoding": encoding,
            "schemaName": schemaName,
            "schema": schema,
            "schemaEncoding": schemaEncoding,
        ]
    }
}

public struct AdvertisedService: Equatable, Sendable {
    public var id: UInt32
    public var name: String
    public var type: String
    public var request: ServiceSchema
    public var response: ServiceSchema

    public init(id: UInt32, name: String, type: String, request: ServiceSchema, response: ServiceSchema) {
        self.id = id
        self.name = name
        self.type = type
        self.request = request
        self.response = response
    }

    func jsonObject() -> [String: Any] {
        [
            "id": id,
            "name": name,
            "type": type,
            "request": request.jsonObject(),
            "response": response.jsonObject(),
        ]
    }
}

public struct ServiceSchema: Equatable, Sendable {
    public var encoding: String
    public var schemaName: String
    public var schemaEncoding: String
    public var schema: String

    public init(encoding: String, schemaName: String, schemaEncoding: String, schema: String) {
        self.encoding = encoding
        self.schemaName = schemaName
        self.schemaEncoding = schemaEncoding
        self.schema = schema
    }

    func jsonObject() -> [String: Any] {
        [
            "encoding": encoding,
            "schemaName": schemaName,
            "schemaEncoding": schemaEncoding,
            "schema": schema,
        ]
    }
}

public enum FoxgloveServerMessages {
    public static func serverInfo(
        name: String,
        capabilities: [String],
        supportedEncodings: [String],
        metadata: [String: String],
        sessionId: String
    ) -> String {
        SortedJSON.text([
            "op": "serverInfo",
            "name": name,
            "capabilities": capabilities,
            "supportedEncodings": supportedEncodings,
            "metadata": metadata,
            "sessionId": sessionId,
        ])
    }

    public static func advertise(_ channels: [AdvertisedChannel]) -> String {
        SortedJSON.text([
            "op": "advertise",
            "channels": channels.map { $0.jsonObject() },
        ])
    }

    public static func unadvertise(_ channelIds: [UInt32]) -> String {
        SortedJSON.text([
            "op": "unadvertise",
            "channelIds": channelIds,
        ])
    }

    public static func status(level: UInt8, message: String, id: String? = nil) -> String {
        var object: [String: Any] = [
            "op": "status",
            "level": level,
            "message": message,
        ]
        if let id { object["id"] = id }
        return SortedJSON.text(object)
    }

    public static func removeStatus(_ statusIds: [String]) -> String {
        SortedJSON.text([
            "op": "removeStatus",
            "statusIds": statusIds,
        ])
    }

    public static func parameterValues(_ parameters: [ParameterValue], id: String? = nil) -> String {
        var object: [String: Any] = [
            "op": "parameterValues",
            "parameters": parameters.map { $0.jsonObject() },
        ]
        if let id { object["id"] = id }
        return SortedJSON.text(object)
    }

    public static func advertiseServices(_ services: [AdvertisedService]) -> String {
        SortedJSON.text([
            "op": "advertiseServices",
            "services": services.map { $0.jsonObject() },
        ])
    }

    public static func serviceCallFailure(serviceId: UInt32, callId: UInt32, message: String) -> String {
        SortedJSON.text([
            "op": "serviceCallFailure",
            "serviceId": serviceId,
            "callId": callId,
            "message": message,
        ])
    }
}

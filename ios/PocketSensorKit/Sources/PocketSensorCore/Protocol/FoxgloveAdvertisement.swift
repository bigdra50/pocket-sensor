import Foundation

/// 契約の表から、接続直後に advertise するチャンネルとサービスを組み立てる。
public enum FoxgloveAdvertisement {
    public static func channels(deviceName: String, stages: Set<Int>) -> [AdvertisedChannel] {
        let names = FrameNames(deviceName: deviceName)
        return Contract.channels.filter { stages.contains($0.stage) }.enumerated().map { index, spec in
            AdvertisedChannel(
                id: UInt32(index + 1),
                topic: names.topic(spec),
                encoding: "cdr",
                schemaName: spec.schema,
                schema: ContractSchemas.text(for: spec.schema) ?? "",
                schemaEncoding: "ros2msg"
            )
        }
    }

    public static func services(deviceName: String, stages: Set<Int>) -> [AdvertisedService] {
        let names = FrameNames(deviceName: deviceName)
        return Contract.services.filter { stages.contains($0.stage) }.enumerated().map { index, spec in
            let requestName = "\(spec.type)_Request"
            let responseName = "\(spec.type)_Response"
            return AdvertisedService(
                id: UInt32(index + 1),
                name: names.resolve(spec.name),
                type: spec.type,
                request: ServiceSchema(
                    encoding: "cdr",
                    schemaName: requestName,
                    schemaEncoding: "ros2msg",
                    schema: ContractSchemas.text(for: requestName) ?? ""
                ),
                response: ServiceSchema(
                    encoding: "cdr",
                    schemaName: responseName,
                    schemaEncoding: "ros2msg",
                    schema: ContractSchemas.text(for: responseName) ?? ""
                )
            )
        }
    }

    public static func channelSpecs(stages: Set<Int>) -> [ChannelSpec] {
        Contract.channels.filter { stages.contains($0.stage) }
    }

    public static func serviceSpecs(stages: Set<Int>) -> [ServiceSpec] {
        Contract.services.filter { stages.contains($0.stage) }
    }
}

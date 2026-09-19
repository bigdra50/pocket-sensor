/// 端末名を topic と frame のテンプレートへ入れる。
public struct FrameNames: Equatable, Sendable {
    public var deviceName: String

    public init(deviceName: String) {
        self.deviceName = deviceName
    }

    public var odom: String { resolve("<name>_odom") }
    public var link: String { resolve("<name>_link") }
    public var colorOptical: String { resolve("<name>_color_optical_frame") }
    public var imuLink: String { resolve("<name>_imu_link") }

    public func resolve(_ template: String) -> String {
        template.replacingOccurrences(of: "<name>", with: deviceName)
    }

    public func topic(_ spec: ChannelSpec) -> String {
        resolve(spec.topic)
    }

    public func anchorFrame(imageName: String) -> String {
        resolve("<name>_anchor_\(imageName)")
    }
}

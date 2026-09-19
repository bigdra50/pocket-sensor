/// トピックと frame の接頭辞になる端末名。ROS の名前規則に合わせる。
public enum DeviceName {
    public static let defaultValue = "pocketsensor"

    /// 先頭は英小文字、以降は英小文字・数字・下線。空は不可。
    public static func isValid(_ name: String) -> Bool {
        guard let first = name.utf8.first else { return false }
        guard (0x61 ... 0x7A).contains(first) else { return false }
        return name.utf8.allSatisfy { byte in
            (0x61 ... 0x7A).contains(byte) || (0x30 ... 0x39).contains(byte) || byte == 0x5F
        }
    }
}

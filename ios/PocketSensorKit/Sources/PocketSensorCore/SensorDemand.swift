/// 画面の Monitor と購読の論理和。GNSS は許可ダイアログと消費電力のため Monitor では動かさない。
public enum SensorDemand {
    public static func motion(subscribed: Bool, monitorOn: Bool) -> Bool {
        subscribed || monitorOn
    }

    public static func battery(subscribed: Bool, monitorOn: Bool) -> Bool {
        subscribed || monitorOn
    }

    public static func gnss(subscribed: Bool, monitorOn: Bool) -> Bool {
        _ = monitorOn
        return subscribed
    }
}

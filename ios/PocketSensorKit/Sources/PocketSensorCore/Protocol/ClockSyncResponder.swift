import Foundation

/// サービス処理の失敗。呼び出し側は `serviceCallFailure` に載せる。
public struct ServiceFailure: Error, Equatable, Sendable {
    public var message: String

    public init(message: String) {
        self.message = message
    }
}

/// `clock_sync` の応答を作る。t2 と t3 は呼び出し側が wire 時計で測って渡す。
public enum ClockSyncResponder {
    public static func respond(request: Data, t2WireNs: UInt64, t3WireNs: UInt64) -> Result<Data, ServiceFailure> {
        let req: PocketsensorMsgs.ClockSync.Request
        do {
            var decoder = try CDRDecoder(data: request)
            req = try PocketsensorMsgs.ClockSync.Request(from: &decoder)
        } catch {
            return .failure(ServiceFailure(message: "malformed clock_sync request"))
        }
        let response = PocketsensorMsgs.ClockSync.Response(t1: req.t1, t2: t2WireNs, t3: t3WireNs)
        var encoder = CDREncoder()
        encoder.encode(response)
        return .success(encoder.data)
    }
}

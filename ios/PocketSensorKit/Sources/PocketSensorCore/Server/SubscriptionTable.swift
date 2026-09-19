import Foundation

public enum SubscribeError: Error, Equatable {
    case duplicateSubscriptionId(UInt32)
    case unknownChannel(UInt32)

    public var statusMessage: String {
        switch self {
        case .duplicateSubscriptionId(let id):
            return "duplicate subscription id \(id)"
        case .unknownChannel(let id):
            return "unknown channel \(id)"
        }
    }
}

/// 接続ごとの購読。subscription id は接続内で一意。
public struct SubscriptionTable: Equatable, Sendable {
    private var bySubscription: [UInt32: UInt32] = [:]
    private var byChannel: [UInt32: [UInt32]] = [:]

    public init() {}

    public mutating func subscribe(
        subscriptionId: UInt32,
        channelId: UInt32,
        knownChannels: Set<UInt32>
    ) -> Result<Void, SubscribeError> {
        if bySubscription[subscriptionId] != nil {
            return .failure(.duplicateSubscriptionId(subscriptionId))
        }
        if !knownChannels.contains(channelId) {
            return .failure(.unknownChannel(channelId))
        }
        bySubscription[subscriptionId] = channelId
        byChannel[channelId, default: []].append(subscriptionId)
        return .success(())
    }

    public mutating func unsubscribe(subscriptionId: UInt32) {
        guard let channelId = bySubscription.removeValue(forKey: subscriptionId) else { return }
        if var ids = byChannel[channelId] {
            ids.removeAll { $0 == subscriptionId }
            if ids.isEmpty {
                byChannel.removeValue(forKey: channelId)
            } else {
                byChannel[channelId] = ids
            }
        }
    }

    public func subscriptionId(forChannel channelId: UInt32) -> [UInt32] {
        byChannel[channelId] ?? []
    }

    public var channels: Set<UInt32> {
        Set(byChannel.keys)
    }
}

/// 接続をまたいだチャンネルごとの購読数。0→1 と 1→0 を知らせる。
public struct SubscriberCounts: Equatable, Sendable {
    public enum Transition: Equatable, Sendable {
        case started(UInt32)
        case stopped(UInt32)
    }

    private var counts: [UInt32: Int] = [:]

    public init() {}

    public mutating func add(_ channelId: UInt32) -> Transition? {
        let next = (counts[channelId] ?? 0) + 1
        counts[channelId] = next
        return next == 1 ? .started(channelId) : nil
    }

    public mutating func remove(_ channelId: UInt32) -> Transition? {
        guard let current = counts[channelId], current > 0 else { return nil }
        let next = current - 1
        if next == 0 {
            counts.removeValue(forKey: channelId)
            return .stopped(channelId)
        }
        counts[channelId] = next
        return nil
    }

    public func count(for channelId: UInt32) -> Int {
        counts[channelId] ?? 0
    }
}

import Foundation

public struct OutboundItem: Equatable, Sendable {
    public var channelId: UInt32
    public var timestampNs: UInt64
    public var payload: Data

    public init(channelId: UInt32, timestampNs: UInt64, payload: Data) {
        self.channelId = channelId
        self.timestampNs = timestampNs
        self.payload = payload
    }
}

/// 接続ごとの送信待ち。サーバーは 1 接続につき同時に 1 つの WebSocket メッセージだけを送る。
public struct Outbox: Equatable, Sendable {
    public static let keepCap = 256

    private var keep: [OutboundItem] = []
    private var queues: [UInt32: [OutboundItem]] = [:]
    private var latest: [UInt32: OutboundItem] = [:]
    private var currentBatch: [OutboundItem] = []
    private var currentBatchGroup: String?
    private var currentBatchStamp: UInt64?
    private var waitingBatches: [String: [OutboundItem]] = [:]
    private var inFlight = false
    public private(set) var drops: [UInt32: Int] = [:]

    public init() {}

    public var isIdle: Bool {
        !inFlight
            && keep.isEmpty
            && queues.allSatisfy { $0.value.isEmpty }
            && latest.isEmpty
            && currentBatch.isEmpty
            && waitingBatches.isEmpty
    }

    public mutating func offerKeep(_ item: OutboundItem) {
        keep.append(item)
        while keep.count > Self.keepCap {
            countDrop(keep.removeFirst())
        }
    }

    public mutating func offerQueue(_ item: OutboundItem, maxAgeNs: UInt64) {
        var q = queues[item.channelId] ?? []
        q.append(item)
        while q.count >= 2 {
            let oldest = q[0].timestampNs
            let newest = item.timestampNs
            // 新しい標本が古いと減算が周回し、キューが 1 件まで空になる。
            let age = newest >= oldest ? newest - oldest : 0
            if age > maxAgeNs {
                countDrop(q.removeFirst())
            } else {
                break
            }
        }
        queues[item.channelId] = q
    }

    public mutating func offerLatest(_ item: OutboundItem) {
        if let previous = latest[item.channelId] {
            countDrop(previous)
        }
        latest[item.channelId] = item
    }

    public mutating func offerBatch(group: String, items: [OutboundItem]) {
        guard !items.isEmpty else { return }
        let stamp = items[0].timestampNs
        // 同じ stamp の color を後から足す。新しい stamp だけが待ちを置き換える。
        if currentBatchGroup == group, currentBatchStamp == stamp, inFlight || !currentBatch.isEmpty {
            currentBatch.append(contentsOf: items)
            return
        }
        if let previous = waitingBatches[group], let previousStamp = previous.first?.timestampNs {
            if previousStamp == stamp {
                waitingBatches[group] = previous + items
                return
            }
            if stamp > previousStamp {
                for dropped in previous {
                    countDrop(dropped)
                }
                waitingBatches[group] = items
                return
            }
            for dropped in items {
                countDrop(dropped)
            }
            return
        }
        waitingBatches[group] = items
    }

    public mutating func next() -> OutboundItem? {
        guard !inFlight else { return nil }
        if let item = popKeep() { return take(item) }
        if let item = popQueue() { return take(item) }
        if let item = popCurrentBatch() { return take(item) }
        if let item = popLatest() { return take(item) }
        if promoteWaiting(), let item = popCurrentBatch() { return take(item) }
        return nil
    }

    public mutating func completed() {
        inFlight = false
        if currentBatch.isEmpty {
            currentBatchGroup = nil
            currentBatchStamp = nil
        }
    }

    private mutating func take(_ item: OutboundItem) -> OutboundItem {
        inFlight = true
        return item
    }

    private mutating func popKeep() -> OutboundItem? {
        guard !keep.isEmpty else { return nil }
        return keep.removeFirst()
    }

    private mutating func popQueue() -> OutboundItem? {
        var bestChannel: UInt32?
        var bestTime = UInt64.max
        for (channel, items) in queues {
            guard let first = items.first else { continue }
            if first.timestampNs < bestTime || (first.timestampNs == bestTime && channel < (bestChannel ?? .max)) {
                bestTime = first.timestampNs
                bestChannel = channel
            }
        }
        guard let channel = bestChannel, var items = queues[channel], !items.isEmpty else { return nil }
        let item = items.removeFirst()
        if items.isEmpty {
            queues.removeValue(forKey: channel)
        } else {
            queues[channel] = items
        }
        return item
    }

    private mutating func popCurrentBatch() -> OutboundItem? {
        guard !currentBatch.isEmpty else { return nil }
        return currentBatch.removeFirst()
    }

    private mutating func popLatest() -> OutboundItem? {
        var bestKey: UInt32?
        var bestTime = UInt64.max
        for (channel, item) in latest {
            if item.timestampNs < bestTime || (item.timestampNs == bestTime && channel < (bestKey ?? .max)) {
                bestTime = item.timestampNs
                bestKey = channel
            }
        }
        guard let channel = bestKey, let item = latest.removeValue(forKey: channel) else { return nil }
        return item
    }

    private mutating func promoteWaiting() -> Bool {
        var bestGroup: String?
        var bestTime = UInt64.max
        for (group, items) in waitingBatches {
            guard let first = items.first else { continue }
            if first.timestampNs < bestTime || (first.timestampNs == bestTime && group < (bestGroup ?? "")) {
                bestTime = first.timestampNs
                bestGroup = group
            }
        }
        guard let group = bestGroup, let items = waitingBatches.removeValue(forKey: group) else { return false }
        currentBatch = items
        currentBatchGroup = group
        currentBatchStamp = items.first?.timestampNs
        return !currentBatch.isEmpty
    }

    private mutating func countDrop(_ item: OutboundItem) {
        drops[item.channelId, default: 0] += 1
    }
}

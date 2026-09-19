import Foundation
import Network
import PocketSensorCore

public struct ServerConfig: Equatable, Sendable {
    public var port: UInt16
    public var deviceName: String
    public var sessionId: String
    public var advertiseBonjour: Bool
    public var bonjourType: String
    public var stages: Set<Int>

    public init(
        port: UInt16 = 8765,
        deviceName: String = "pocketsensor",
        sessionId: String = UUID().uuidString,
        advertiseBonjour: Bool = true,
        bonjourType: String = "_pocketsensor._tcp",
        stages: Set<Int> = [1]
    ) {
        self.port = port
        self.deviceName = deviceName
        self.sessionId = sessionId
        self.advertiseBonjour = advertiseBonjour
        self.bonjourType = bonjourType
        self.stages = stages
    }
}

public struct ServerStats: Equatable, Sendable {
    public var clients: Int
    public var dropsByChannelKey: [String: Int]
    public var sentRateByChannelKey: [String: RateMeter]

    public init(clients: Int, dropsByChannelKey: [String: Int], sentRateByChannelKey: [String: RateMeter]) {
        self.clients = clients
        self.dropsByChannelKey = dropsByChannelKey
        self.sentRateByChannelKey = sentRateByChannelKey
    }
}

/// Foxglove WS v1 サーバー。状態はすべて `queue` 上で触る。
public final class FoxgloveServer: @unchecked Sendable {
    public var onStateChange: ((String) -> Void)?
    public var onClientCountChange: ((Int) -> Void)?
    public var onSubscribersChange: ((String, Bool) -> Void)?
    public var onParametersChange: (([ParameterValue]) -> Void)?

    private let config: ServerConfig
    private var parameters: ParameterStore
    private let anchor: ClockAnchor
    private let monoClockNs: () -> Int64
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<UInt8>()

    private var listener: NWListener?
    private var _actualPort: UInt16?
    private var connections: [ObjectIdentifier: Client] = [:]
    private var subscriberCounts = SubscriberCounts()
    private var subscriberKeys: Set<String> = []
    private let subscriberSnapshotLock = NSLock()
    private var subscriberKeysSnapshot: Set<String> = []
    private var latched: [String: (stampNs: UInt64, payload: Data)] = [:]
    private var serviceHandlers: [String: (Data, Int64) -> Result<Data, ServiceFailure>] = [:]
    private var sentMeters: [String: RateMeter] = [:]
    private var closedDrops: [String: Int] = [:]

    private let advertisedIds: Set<UInt32>
    private let channelsByKey: [String: (id: UInt32, spec: ChannelSpec)]
    private let keyById: [UInt32: String]
    private let servicesById: [UInt32: ServiceSpec]
    private let serviceIdByKey: [String: UInt32]

    public init(
        config: ServerConfig,
        parameters: ParameterStore,
        anchor: ClockAnchor,
        monoClockNs: @escaping () -> Int64
    ) {
        self.config = config
        self.parameters = parameters
        self.anchor = anchor
        self.monoClockNs = monoClockNs
        queue = DispatchQueue(label: "pocketsensor.server")
        queue.setSpecific(key: queueKey, value: 1)
        _ = self.parameters.setInternal(name: "device.name", value: .string(config.deviceName))

        let specs = FoxgloveAdvertisement.channelSpecs(stages: config.stages)
        var byKey: [String: (id: UInt32, spec: ChannelSpec)] = [:]
        var byId: [UInt32: String] = [:]
        var ids: Set<UInt32> = []
        for (index, spec) in specs.enumerated() {
            let id = UInt32(index + 1)
            byKey[spec.key] = (id, spec)
            byId[id] = spec.key
            ids.insert(id)
        }
        channelsByKey = byKey
        keyById = byId
        advertisedIds = ids

        var servicesById: [UInt32: ServiceSpec] = [:]
        var serviceIdByKey: [String: UInt32] = [:]
        for (index, spec) in FoxgloveAdvertisement.serviceSpecs(stages: config.stages).enumerated() {
            let id = UInt32(index + 1)
            servicesById[id] = spec
            serviceIdByKey[spec.key] = id
        }
        self.servicesById = servicesById
        self.serviceIdByKey = serviceIdByKey

        serviceHandlers["clock_sync"] = { [weak self] request, t2Mono in
            guard let self else { return .failure(ServiceFailure(message: "stopped")) }
            let t3Mono = self.monoClockNs()
            return ClockSyncResponder.respond(
                request: request,
                t2WireNs: self.anchor.wireTime(monoNs: t2Mono),
                t3WireNs: self.anchor.wireTime(monoNs: t3Mono)
            )
        }
    }

    public var actualPort: UInt16? {
        onQueue { _actualPort }
    }

    public func start() {
        asyncOnQueue { self.startOnQueue() }
    }

    public func stop() {
        onQueue { self.stopOnQueue() }
    }

    public func hasSubscribers(_ channelKey: String) -> Bool {
        // 送信完了待ちの queue.sync に IMU / ARFrame を載せない。
        subscriberSnapshotLock.lock()
        let hit = subscriberKeysSnapshot.contains(channelKey)
        subscriberSnapshotLock.unlock()
        return hit
    }

    public func stats() -> ServerStats {
        onQueue { self.statsOnQueue() }
    }

    public func publish(_ channelKey: String, stampNs: UInt64, payload: Data) {
        asyncOnQueue { self.publishOnQueue(channelKey, stampNs: stampNs, payload: payload) }
    }

    public func publishBatch(group: String, stampNs: UInt64, items: [(String, Data)]) {
        asyncOnQueue { self.publishBatchOnQueue(group: group, stampNs: stampNs, items: items) }
    }

    public func setLatched(_ channelKey: String, stampNs: UInt64, payload: Data) {
        onQueue { self.setLatchedOnQueue(channelKey, stampNs: stampNs, payload: payload) }
    }

    public func registerService(
        _ key: String,
        handler: @escaping (Data, Int64) -> Result<Data, ServiceFailure>
    ) {
        onQueue { self.serviceHandlers[key] = handler }
    }

    public func setParameterInternal(name: String, value: ParameterValue.Value) {
        onQueue {
            guard let changed = self.parameters.setInternal(name: name, value: value) else { return }
            self.notifyParameterChanges([changed])
        }
    }

    private func startOnQueue() {
        if listener != nil { return }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        websocket.setClientRequestHandler(queue) { subprotocols, _ in
            if let name = Subprotocol.negotiate(offered: subprotocols) {
                return NWProtocolWebSocket.Response(status: .accept, subprotocol: name)
            }
            return NWProtocolWebSocket.Response(status: .reject, subprotocol: nil)
        }
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)

        let nwPort = NWEndpoint.Port(rawValue: config.port) ?? .any
        do {
            let listener = try NWListener(using: parameters, on: nwPort)
            if config.advertiseBonjour {
                listener.service = NWListener.Service(name: config.deviceName, type: config.bonjourType)
            }
            listener.stateUpdateHandler = { [weak self] state in
                self?.handleListenerState(state)
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            onStateChange?("failed: \(error)")
        }
    }

    private func stopOnQueue() {
        let clients = Array(connections.values)
        for client in clients {
            removeClient(client)
            client.connection.cancel()
        }
        listener?.cancel()
        listener = nil
        _actualPort = nil
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            if let port = listener?.port {
                _actualPort = port.rawValue
            }
            onStateChange?(describe(state))
        default:
            onStateChange?(describe(state))
        }
    }

    private func accept(_ connection: NWConnection) {
        let client = Client(connection: connection)
        connections[ObjectIdentifier(connection)] = client
        connection.stateUpdateHandler = { [weak self, weak client] state in
            guard let self, let client else { return }
            switch state {
            case .ready:
                if !client.ready {
                    client.ready = true
                    self.sendHandshake(to: client)
                    self.onClientCountChange?(self.readyCount)
                }
            case .failed, .cancelled:
                self.removeClient(client)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(client)
    }

    private func removeClient(_ client: Client) {
        let id = ObjectIdentifier(client.connection)
        guard let existing = connections.removeValue(forKey: id) else { return }
        for (channelId, count) in existing.outbox.drops {
            guard let key = keyById[channelId] else { continue }
            closedDrops[key, default: 0] += count
        }
        for channelId in existing.subscriptions.channels {
            if let transition = subscriberCounts.remove(channelId) {
                apply(transition)
            }
        }
        if existing.ready {
            onClientCountChange?(readyCount)
        }
    }

    private var readyCount: Int {
        connections.values.reduce(0) { $0 + ($1.ready ? 1 : 0) }
    }

    private func sendHandshake(to client: Client) {
        let name = parameters.string("device.name")
        let channels = FoxgloveAdvertisement.channels(deviceName: name, stages: config.stages)
        let services = FoxgloveAdvertisement.services(deviceName: name, stages: config.stages)
        send(
            text: FoxgloveServerMessages.serverInfo(
                name: "pocketsensor",
                capabilities: ["parameters", "parametersSubscribe", "services"],
                supportedEncodings: ["cdr"],
                metadata: [:],
                sessionId: config.sessionId
            ),
            to: client
        )
        send(text: FoxgloveServerMessages.advertise(channels), to: client)
        send(text: FoxgloveServerMessages.advertiseServices(services), to: client)
    }

    private func receive(_ client: Client) {
        let clock = monoClockNs
        client.connection.receiveMessage { [weak self, weak client] data, context, _, error in
            let t2 = clock()
            guard let self, let client else { return }
            if let data, let context {
                self.handle(data, context: context, from: client, receivedMonoNs: t2)
            }
            if error == nil, self.connections[ObjectIdentifier(client.connection)] != nil {
                self.receive(client)
            } else if error != nil {
                client.connection.cancel()
            }
        }
    }

    private func handle(_ data: Data, context: NWConnection.ContentContext, from client: Client, receivedMonoNs: Int64) {
        guard let metadata = context.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata else {
            return
        }
        switch metadata.opcode {
        case .text:
            guard let text = String(data: data, encoding: .utf8) else { return }
            handleText(text, from: client)
        case .binary:
            handleBinary(data, from: client, receivedMonoNs: receivedMonoNs)
        case .close:
            client.connection.cancel()
        default:
            break
        }
    }

    private func handleText(_ text: String, from client: Client) {
        let message: FoxgloveClientMessage
        do {
            message = try FoxgloveClientMessages.parse(text: text)
        } catch {
            return
        }
        switch message {
        case .subscribe(let items):
            for item in items {
                let before = client.subscriptions.subscriptionId(forChannel: item.channelId)
                switch client.subscriptions.subscribe(
                    subscriptionId: item.subscriptionId,
                    channelId: item.channelId,
                    knownChannels: advertisedIds
                ) {
                case .success:
                    let after = client.subscriptions.subscriptionId(forChannel: item.channelId)
                    if before.isEmpty, !after.isEmpty, let transition = subscriberCounts.add(item.channelId) {
                        apply(transition)
                    }
                    deliverLatched(channelId: item.channelId, to: client)
                case .failure(let error):
                    send(
                        text: FoxgloveServerMessages.status(level: 1, message: error.statusMessage),
                        to: client
                    )
                }
            }
            pump(client)
        case .unsubscribe(let ids):
            for subscriptionId in ids {
                let channelIds = advertisedIds.filter { client.subscriptions.subscriptionId(forChannel: $0).contains(subscriptionId) }
                client.subscriptions.unsubscribe(subscriptionId: subscriptionId)
                for channelId in channelIds {
                    if client.subscriptions.subscriptionId(forChannel: channelId).isEmpty,
                       let transition = subscriberCounts.remove(channelId)
                    {
                        apply(transition)
                    }
                }
            }
        case .getParameters(let names, let id):
            send(
                text: FoxgloveServerMessages.parameterValues(parameters.get(names: names), id: id),
                to: client
            )
        case .setParameters(let updates, let id):
            let requested = updates.map(\.name)
            let changed = parameters.set(updates)
            if let id {
                send(
                    text: FoxgloveServerMessages.parameterValues(parameters.get(names: requested), id: id),
                    to: client
                )
            }
            if !changed.isEmpty {
                notifyParameterChanges(changed)
            }
        case .subscribeParameterUpdates(let names):
            client.paramSubscriptions.formUnion(names)
        case .unsubscribeParameterUpdates(let names):
            for name in names {
                client.paramSubscriptions.remove(name)
            }
        case .ignored:
            break
        }
    }

    private func handleBinary(_ data: Data, from client: Client, receivedMonoNs: Int64) {
        let parsed: FoxgloveBinary.ClientBinary
        do {
            parsed = try FoxgloveBinary.parseClientBinary(data)
        } catch {
            return
        }
        guard case .serviceCallRequest(let serviceId, let callId, _, let payload) = parsed else { return }
        guard let spec = servicesById[serviceId] else {
            send(
                text: FoxgloveServerMessages.serviceCallFailure(
                    serviceId: serviceId,
                    callId: callId,
                    message: "unknown service"
                ),
                to: client
            )
            return
        }
        guard let handler = serviceHandlers[spec.key] else {
            send(
                text: FoxgloveServerMessages.serviceCallFailure(
                    serviceId: serviceId,
                    callId: callId,
                    message: "unregistered service"
                ),
                to: client
            )
            return
        }
        switch handler(payload, receivedMonoNs) {
        case .success(let response):
            send(
                data: FoxgloveBinary.serviceCallResponse(
                    serviceId: serviceId,
                    callId: callId,
                    encoding: "cdr",
                    payload: response
                ),
                opcode: .binary,
                to: client
            )
        case .failure(let failure):
            send(
                text: FoxgloveServerMessages.serviceCallFailure(
                    serviceId: serviceId,
                    callId: callId,
                    message: failure.message
                ),
                to: client
            )
        }
    }

    private func notifyParameterChanges(_ changed: [ParameterValue]) {
        let names = Set(changed.map(\.name))
        for client in connections.values {
            let hit = changed.filter { names.contains($0.name) && client.paramSubscriptions.contains($0.name) }
            if !hit.isEmpty {
                send(text: FoxgloveServerMessages.parameterValues(hit, id: nil), to: client)
            }
        }
        onParametersChange?(changed)
    }

    private func publishOnQueue(_ channelKey: String, stampNs: UInt64, payload: Data) {
        guard let entry = channelsByKey[channelKey] else {
            preconditionFailure("unknown channel key \(channelKey)")
        }
        let item = OutboundItem(channelId: entry.id, timestampNs: stampNs, payload: payload)
        for client in connections.values {
            guard !client.subscriptions.subscriptionId(forChannel: entry.id).isEmpty else { continue }
            offer(item, spec: entry.spec, to: client)
            pump(client)
        }
    }

    private func publishBatchOnQueue(group: String, stampNs: UInt64, items: [(String, Data)]) {
        var resolved: [(entry: (id: UInt32, spec: ChannelSpec), payload: Data)] = []
        resolved.reserveCapacity(items.count)
        for (key, payload) in items {
            guard let entry = channelsByKey[key] else {
                preconditionFailure("unknown channel key \(key)")
            }
            resolved.append((entry, payload))
        }
        for client in connections.values {
            var outbound: [OutboundItem] = []
            outbound.reserveCapacity(resolved.count)
            for pair in resolved {
                guard !client.subscriptions.subscriptionId(forChannel: pair.entry.id).isEmpty else { continue }
                outbound.append(OutboundItem(channelId: pair.entry.id, timestampNs: stampNs, payload: pair.payload))
            }
            guard !outbound.isEmpty else { continue }
            client.outbox.offerBatch(group: group, items: outbound)
            pump(client)
        }
    }

    private func setLatchedOnQueue(_ channelKey: String, stampNs: UInt64, payload: Data) {
        guard let entry = channelsByKey[channelKey] else {
            preconditionFailure("unknown channel key \(channelKey)")
        }
        latched[channelKey] = (stampNs, payload)
        let item = OutboundItem(channelId: entry.id, timestampNs: stampNs, payload: payload)
        for client in connections.values {
            guard !client.subscriptions.subscriptionId(forChannel: entry.id).isEmpty else { continue }
            client.outbox.offerKeep(item)
            pump(client)
        }
    }

    private func deliverLatched(channelId: UInt32, to client: Client) {
        guard let key = keyById[channelId], let held = latched[key] else { return }
        client.outbox.offerKeep(OutboundItem(channelId: channelId, timestampNs: held.stampNs, payload: held.payload))
    }

    private func offer(_ item: OutboundItem, spec: ChannelSpec, to client: Client) {
        switch spec.backpressure {
        case .keep:
            client.outbox.offerKeep(item)
        case .queue:
            let seconds = spec.queueSeconds ?? 1
            let maxAge = seconds <= 0 ? UInt64(0) : UInt64(seconds * 1_000_000_000.0)
            client.outbox.offerQueue(item, maxAgeNs: maxAge)
        case .latest:
            client.outbox.offerLatest(item)
        }
    }

    private func pump(_ client: Client) {
        guard connections[ObjectIdentifier(client.connection)] != nil else { return }
        while true {
            guard let item = client.outbox.next() else { return }
            let subIds = client.subscriptions.subscriptionId(forChannel: item.channelId)
            guard let subId = subIds.first else {
                client.outbox.completed()
                continue
            }
            if let key = keyById[item.channelId] {
                var meter = sentMeters[key] ?? RateMeter()
                meter.record(at: Double(monoClockNs()) / 1_000_000_000.0)
                sentMeters[key] = meter
            }
            let frame = FoxgloveBinary.messageData(
                subscriptionId: subId,
                timestampNs: item.timestampNs,
                payload: item.payload
            )
            send(data: frame, opcode: .binary, to: client) { [weak self, weak client] in
                guard let self, let client else { return }
                client.outbox.completed()
                self.pump(client)
            }
            return
        }
    }

    private func apply(_ transition: SubscriberCounts.Transition) {
        switch transition {
        case .started(let channelId):
            guard let key = keyById[channelId] else { return }
            subscriberKeys.insert(key)
            snapshotSubscriberKeys()
            onSubscribersChange?(key, true)
        case .stopped(let channelId):
            guard let key = keyById[channelId] else { return }
            subscriberKeys.remove(key)
            snapshotSubscriberKeys()
            onSubscribersChange?(key, false)
        }
    }

    private func snapshotSubscriberKeys() {
        subscriberSnapshotLock.lock()
        subscriberKeysSnapshot = subscriberKeys
        subscriberSnapshotLock.unlock()
    }

    private func statsOnQueue() -> ServerStats {
        var drops = closedDrops
        for client in connections.values {
            for (channelId, count) in client.outbox.drops {
                guard let key = keyById[channelId] else { continue }
                drops[key, default: 0] += count
            }
        }
        return ServerStats(clients: readyCount, dropsByChannelKey: drops, sentRateByChannelKey: sentMeters)
    }

    private func send(text: String, to client: Client, completion: (() -> Void)? = nil) {
        send(data: Data(text.utf8), opcode: .text, to: client, completion: completion)
    }

    private func send(
        data: Data,
        opcode: NWProtocolWebSocket.Opcode,
        to client: Client,
        completion: (() -> Void)? = nil
    ) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: opcode)
        let context = NWConnection.ContentContext(
            identifier: opcode == .binary ? "binary" : "text",
            metadata: [metadata]
        )
        client.connection.send(
            content: data,
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed { [weak self] _ in
                guard let completion else { return }
                self?.queue.async { completion() }
            }
        )
    }

    private func onQueue<T>(_ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return body()
        }
        return queue.sync(execute: body)
    }

    private func asyncOnQueue(_ body: @escaping () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            body()
        } else {
            queue.async(execute: body)
        }
    }
}

private final class Client {
    let connection: NWConnection
    var outbox = Outbox()
    var subscriptions = SubscriptionTable()
    var paramSubscriptions: Set<String> = []
    var ready = false

    init(connection: NWConnection) {
        self.connection = connection
    }
}

private func describe(_ state: NWListener.State) -> String {
    switch state {
    case .setup: return "setup"
    case .waiting(let error): return "waiting: \(error)"
    case .ready: return "ready"
    case .failed(let error): return "failed: \(error)"
    case .cancelled: return "cancelled"
    @unknown default: return "unknown"
    }
}

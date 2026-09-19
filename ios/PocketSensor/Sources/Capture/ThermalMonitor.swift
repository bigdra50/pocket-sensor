import Foundation

extension ProcessInfo.ThermalState {
    var wireName: String {
        switch self {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}

/// 現在の熱状態と、変化したときの通知。
///
/// `thermalStateDidChangeNotification` を受け取るには、登録より前に `thermalState` を一度読む必要がある。
final class ThermalMonitor {
    private let queue = DispatchQueue(label: "pocketsensor.thermal")
    private let handlers = HandlerList<ProcessInfo.ThermalState>()
    private var observer: NSObjectProtocol?
    private let opQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "pocketsensor.thermal"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    var current: ProcessInfo.ThermalState {
        ProcessInfo.processInfo.thermalState
    }

    func onChange(_ handler: @escaping (ProcessInfo.ThermalState) -> Void) {
        handlers.add(handler)
    }

    func start() {
        // 通知を受け取るには、登録より前に thermalState を一度読む必要がある
        let state = ProcessInfo.processInfo.thermalState
        queue.async { self.handlers.emit(state) }
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: opQueue
        ) { [weak self] _ in
            guard let self else { return }
            let state = ProcessInfo.processInfo.thermalState
            self.queue.async { self.handlers.emit(state) }
        }
    }

    func stop() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
    }
}

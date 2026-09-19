import Foundation
import UIKit

struct BatterySample {
    var level: Float
    var state: UIDevice.BatteryState
}

extension UIDevice.BatteryState {
    var wireName: String {
        switch self {
        case .unknown: return "unknown"
        case .unplugged: return "unplugged"
        case .charging: return "charging"
        case .full: return "full"
        @unknown default: return "unknown"
        }
    }
}

/// 開始中は 1 Hz で残量と充電状態を読む。監視の ON は main で行う。
final class BatteryCapture {
    private let queue = DispatchQueue(label: "pocketsensor.battery")
    private let handlers = HandlerList<BatterySample>()
    private var timer: DispatchSourceTimer?
    private let lock = NSLock()
    private var running = false

    func onSample(_ handler: @escaping (BatterySample) -> Void) {
        handlers.add(handler)
    }

    func start() {
        lock.lock()
        let already = running
        running = true
        lock.unlock()
        guard !already else { return }

        DispatchQueue.main.async {
            UIDevice.current.isBatteryMonitoringEnabled = true
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0)
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        lock.lock()
        running = false
        lock.unlock()
        timer?.cancel()
        timer = nil
        DispatchQueue.main.async {
            UIDevice.current.isBatteryMonitoringEnabled = false
        }
    }

    private func tick() {
        lock.lock()
        let run = running
        lock.unlock()
        guard run else { return }
        DispatchQueue.main.async {
            let sample = BatterySample(
                level: UIDevice.current.batteryLevel,
                state: UIDevice.current.batteryState
            )
            self.queue.async { self.handlers.emit(sample) }
        }
    }
}

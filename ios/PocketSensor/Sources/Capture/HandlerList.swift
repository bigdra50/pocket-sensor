import Foundation

/// 複数購読者へ同じサンプルを渡す。capture のキューから `emit` する。
final class HandlerList<Sample> {
    private var handlers: [(Sample) -> Void] = []
    private let lock = NSLock()

    func add(_ handler: @escaping (Sample) -> Void) {
        lock.lock()
        handlers.append(handler)
        lock.unlock()
    }

    func emit(_ sample: Sample) {
        lock.lock()
        let snapshot = handlers
        lock.unlock()
        for handler in snapshot {
            handler(sample)
        }
    }
}

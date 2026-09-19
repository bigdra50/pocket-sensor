import Foundation
import PocketSensorCore
import XCTest

final class WSTestClient: NSObject, URLSessionWebSocketDelegate, URLSessionTaskDelegate {
    private var session: URLSession!
    private var task: URLSessionWebSocketTask!
    private let lock = NSLock()
    private var texts: [[String: Any]] = []
    private var binaries: [Data] = []
    private var openedProtocol: String?
    private var didOpen = false
    private var didFail = false
    private var openExpectation: XCTestExpectation?
    private var failExpectation: XCTestExpectation?
    private var textWaiter: (predicate: ([String: Any]) -> Bool, expectation: XCTestExpectation)?
    private var binaryWaiter: (predicate: (Data) -> Bool, expectation: XCTestExpectation)?

    init(port: UInt16, protocols: [String]) {
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 5
        session = URLSession(configuration: config, delegate: self, delegateQueue: OperationQueue())
        let url = URL(string: "ws://127.0.0.1:\(port)")!
        task = session.webSocketTask(with: url, protocols: protocols)
        task.resume()
        listen()
    }

    func close() {
        task.cancel(with: .goingAway, reason: nil)
        session.finishTasksAndInvalidate()
    }

    func sendJSON(_ object: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: object)
        let text = String(data: data, encoding: .utf8)!
        task.send(.string(text)) { _ in }
    }

    func sendData(_ data: Data) {
        task.send(.data(data)) { _ in }
    }

    func waitOpen(timeout: TimeInterval = 5) -> String? {
        lock.lock()
        if didOpen {
            let value = openedProtocol
            lock.unlock()
            return value
        }
        if didFail {
            lock.unlock()
            return nil
        }
        let exp = XCTestExpectation(description: "ws open")
        openExpectation = exp
        lock.unlock()
        let result = XCTWaiter.wait(for: [exp], timeout: timeout)
        XCTAssertEqual(result, .completed, "websocket did not open")
        lock.lock()
        defer { lock.unlock() }
        return openedProtocol
    }

    func waitFail(timeout: TimeInterval = 5) {
        lock.lock()
        if didFail {
            lock.unlock()
            return
        }
        let exp = XCTestExpectation(description: "ws fail")
        failExpectation = exp
        lock.unlock()
        let result = XCTWaiter.wait(for: [exp], timeout: timeout)
        XCTAssertEqual(result, .completed, "websocket did not fail")
    }

    func waitText(timeout: TimeInterval = 5, predicate: @escaping ([String: Any]) -> Bool) -> [String: Any] {
        lock.lock()
        if let index = texts.firstIndex(where: predicate) {
            let value = texts.remove(at: index)
            lock.unlock()
            return value
        }
        let exp = XCTestExpectation(description: "ws text")
        textWaiter = (predicate, exp)
        lock.unlock()
        let result = XCTWaiter.wait(for: [exp], timeout: timeout)
        XCTAssertEqual(result, .completed, "timed out waiting for text")
        lock.lock()
        defer { lock.unlock() }
        if let index = texts.firstIndex(where: predicate) {
            return texts.remove(at: index)
        }
        return [:]
    }

    func waitOp(_ op: String, timeout: TimeInterval = 5) -> [String: Any] {
        waitText(timeout: timeout) { ($0["op"] as? String) == op }
    }

    func waitBinary(timeout: TimeInterval = 5, predicate: @escaping (Data) -> Bool = { _ in true }) -> Data {
        lock.lock()
        if let index = binaries.firstIndex(where: predicate) {
            let value = binaries.remove(at: index)
            lock.unlock()
            return value
        }
        let exp = XCTestExpectation(description: "ws binary")
        binaryWaiter = (predicate, exp)
        lock.unlock()
        let result = XCTWaiter.wait(for: [exp], timeout: timeout)
        XCTAssertEqual(result, .completed, "timed out waiting for binary")
        lock.lock()
        defer { lock.unlock() }
        if let index = binaries.firstIndex(where: predicate) {
            return binaries.remove(at: index)
        }
        return Data()
    }

    func waitHandshake() -> (info: [String: Any], advertise: [String: Any], services: [String: Any]) {
        let info = waitOp("serverInfo")
        let advertise = waitOp("advertise")
        let services = waitOp("advertiseServices")
        return (info, advertise, services)
    }

    var pendingBinaryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return binaries.count
    }

    func drainBinaries() -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        let copy = binaries
        binaries.removeAll()
        return copy
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocolName: String?
    ) {
        lock.lock()
        didOpen = true
        openedProtocol = protocolName
        let exp = openExpectation
        openExpectation = nil
        lock.unlock()
        exp?.fulfill()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        if !didOpen {
            didFail = true
            let exp = failExpectation
            failExpectation = nil
            lock.unlock()
            exp?.fulfill()
            return
        }
        lock.unlock()
    }

    private func listen() {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.string(let text)):
                if let data = text.data(using: .utf8),
                   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                {
                    self.pushText(object)
                }
                self.listen()
            case .success(.data(let data)):
                self.pushBinary(data)
                self.listen()
            default:
                break
            }
        }
    }

    private func pushText(_ object: [String: Any]) {
        lock.lock()
        texts.append(object)
        let waiter = textWaiter
        if let waiter, waiter.predicate(object) {
            textWaiter = nil
            lock.unlock()
            waiter.expectation.fulfill()
            return
        }
        lock.unlock()
    }

    private func pushBinary(_ data: Data) {
        lock.lock()
        binaries.append(data)
        let waiter = binaryWaiter
        if let waiter, waiter.predicate(data) {
            binaryWaiter = nil
            lock.unlock()
            waiter.expectation.fulfill()
            return
        }
        lock.unlock()
    }
}

func encodedCDR<T: CDREncodable>(_ value: T) -> Data {
    var encoder = CDREncoder()
    encoder.encode(value)
    return encoder.data
}

func simExecutableURL() -> URL? {
    for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
        let candidate = bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("pocketsensor-sim")
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
    }
    let fallback = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".build/debug/pocketsensor-sim")
    if FileManager.default.fileExists(atPath: fallback.path) {
        return fallback
    }
    return nil
}

func jsonUInt32(_ value: Any?) -> UInt32? {
    guard let value else { return nil }
    if let n = value as? UInt32 { return n }
    if let n = value as? Int, n >= 0 { return UInt32(n) }
    if let n = value as? NSNumber {
        let v = n.int64Value
        if v < 0 || v > Int64(UInt32.max) { return nil }
        return UInt32(v)
    }
    return nil
}

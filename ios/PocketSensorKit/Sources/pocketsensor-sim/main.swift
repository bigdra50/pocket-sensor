import Darwin
import Foundation
import PocketSensorCore
import PocketSensorServer

let args = parseSimArgs(CommandLine.arguments)
let startMonoNs = Int64(bitPattern: DispatchTime.now().uptimeNanoseconds)
let anchor = ClockAnchor(wallNs: wallClockNs(), monoNs: startMonoNs)
let sessionId = UUID().uuidString
let config = ServerConfig(
    port: args.port,
    deviceName: args.name,
    sessionId: sessionId,
    advertiseBonjour: args.advertiseBonjour
)
let parameters = ParameterStore(specs: Contract.parameters)
let server = FoxgloveServer(
    config: config,
    parameters: parameters,
    anchor: anchor,
    monoClockNs: { Int64(bitPattern: DispatchTime.now().uptimeNanoseconds) }
)
let device = SimulatedDevice(server: server, anchor: anchor, startMonoNs: startMonoNs, deviceName: args.name)
device.setSessionId(sessionId)

let stopOnce = NSLock()
var stopped = false
func stopAndExit() {
    stopOnce.lock()
    defer { stopOnce.unlock() }
    if stopped { return }
    stopped = true
    device.stop()
    exit(0)
}

signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigint.setEventHandler(handler: stopAndExit)
sigterm.setEventHandler(handler: stopAndExit)
sigint.resume()
sigterm.resume()

server.onStateChange = { state in
    if state == "ready", let port = server.actualPort {
        let line = "READY port=\(port)\n"
        if let data = line.data(using: .utf8) {
            FileHandle.standardOutput.write(data)
        }
        fflush(stdout)
        device.start()
    }
    if !args.quiet, state != "ready" {
        fputs("listener \(state)\n", stderr)
    }
}

server.start()

if let duration = args.duration {
    DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: stopAndExit)
}

dispatchMain()

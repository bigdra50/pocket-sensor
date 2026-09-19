import Darwin
import Foundation

/// en0（Wi-Fi）と、有線 / USB らしい IPv4 だけを画面へ出す。
enum LinkAddresses {
    struct Record: Equatable, Hashable {
        var name: String
        var address: String
    }

    static func current() -> [Record] {
        var collected: [(name: String, address: String)] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(first) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let iface = ptr {
            defer { ptr = iface.pointee.ifa_next }
            let flags = Int32(iface.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard let addr = iface.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let status = getnameinfo(
                addr,
                socklen_t(addr.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard status == 0 else { continue }
            collected.append((String(cString: iface.pointee.ifa_name), String(cString: host)))
        }
        return select(from: collected)
    }

    /// lo / awdl / utun などは出さない。en0 と en2 以降、ncm、eth を残す。
    static func select(from interfaces: [(name: String, address: String)]) -> [Record] {
        interfaces.compactMap { item in
            shouldShow(item.name) ? Record(name: item.name, address: item.address) : nil
        }
    }

    static func shouldShow(_ name: String) -> Bool {
        if name == "en0" { return true }
        if name.hasPrefix("en") { return true }
        if name.hasPrefix("ncm") { return true }
        if name.hasPrefix("eth") { return true }
        return false
    }
}

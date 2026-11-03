import Foundation
import Darwin

/// Send Wake-on-LAN UDP broadcasts locally without SSH.
enum WakeOnLAN {
    /// Parse colon/dash-separated or compact MAC addresses into six bytes.
    static func parseMAC(_ s: String) -> [UInt8]? {
        let hex = s.lowercased().filter { $0.isHexDigit }
        let clean = s.lowercased().filter { !$0.isWhitespace && $0 != ":" && $0 != "-" && $0 != "." }
        guard hex.count == 12, clean.count == 12 else { return nil }
        var out: [UInt8] = []
        var i = hex.startIndex
        for _ in 0..<6 {
            let j = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
            out.append(b); i = j
        }
        return out
    }

    static func format(_ mac: [UInt8]) -> String { mac.map { String(format: "%02x", $0) }.joined(separator: ":") }

    /// Magic packet: six 0xFF bytes followed by the MAC repeated 16 times.
    static func packet(_ mac: [UInt8]) -> [UInt8] { Array(repeating: 0xFF, count: 6) + Array((0..<16).map { _ in mac }.joined()) }

    /// Collect directed-broadcast addresses of all local IPv4 interfaces.
    static func directedBroadcasts() -> [String] {
        var result: [String] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return result }
        defer { freeifaddrs(ifap) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            let flags = Int32(cur.pointee.ifa_flags)
            if flags & IFF_UP != 0, flags & IFF_BROADCAST != 0, flags & IFF_LOOPBACK == 0,
               let a = cur.pointee.ifa_addr, a.pointee.sa_family == UInt8(AF_INET), let d = cur.pointee.ifa_dstaddr {
                var addr = d.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil { result.append(String(cString: buf)) }
            }
            p = cur.pointee.ifa_next
        }
        return Array(Set(result))
    }

    /// Empty broadcast sends to 255.255.255.255 and all local subnet broadcasts; return successful send count.
    @discardableResult
    static func send(mac: [UInt8], broadcast: String = "") throws -> Int {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw NSError(domain: "WakeOnLAN", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: String(localized: "Couldn't open a network socket.")]) }
        defer { close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        let data = packet(mac)
        let targets = broadcast.trimmingCharacters(in: .whitespaces).isEmpty ? ["255.255.255.255"] + directedBroadcasts() : [broadcast.trimmingCharacters(in: .whitespaces)]
        var sent = 0
        for t in targets {
            for port: UInt16 in [9, 7] {
                var sa = sockaddr_in()
                sa.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                sa.sin_family = sa_family_t(AF_INET)
                sa.sin_port = port.bigEndian
                guard inet_pton(AF_INET, t, &sa.sin_addr) == 1 else { continue }
                let n = withUnsafePointer(to: &sa) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, data, data.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
                if n == data.count { sent += 1 }
            }
        }
        if sent == 0 { throw NSError(domain: "WakeOnLAN", code: 1, userInfo: [NSLocalizedDescriptionKey: String(localized: "The wake packet couldn't be sent. Check the broadcast address and your network connection.")]) }
        return sent
    }
}

/// Check root/passwordless sudo before scheduling reboot/shutdown in the background after the SSH response completes.
enum PowerCommands {
    enum Action { case reboot, shutdown }

    static func script(_ a: Action) -> String {
        let cmd = a == .reboot ? "shutdown -r now || reboot" : "shutdown -h now || poweroff"
        return "export PATH=\"$PATH:/sbin:/usr/sbin\"; S=\"\"; if [ \"$(id -u)\" != 0 ]; then sudo -n true 2>/dev/null || { echo __NOSUDO__; exit 3; }; S=\"sudo -n\"; fi; "
            + "(sleep 2; $S sh -c '\(cmd)') >/dev/null 2>&1 & echo __SCHEDULED__"
    }

    /// Detect MAC from Linux's default-route interface or macOS en0.
    static let detectMAC = "if [ -d /sys/class/net ]; then i=$(ip route show default 2>/dev/null | awk '/default/{print $5; exit}'); [ -n \"$i\" ] && cat /sys/class/net/$i/address 2>/dev/null; else ifconfig en0 2>/dev/null | awk '/ether/{print $2; exit}'; fi"
}

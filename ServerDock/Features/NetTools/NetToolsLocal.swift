import Foundation
import Network
import Security
import CryptoKit
import SystemConfiguration
import CoreWLAN
import Darwin

typealias ToolEmit = @Sendable (ToolLine) -> Void

/// Local network tools use sockets/Network.framework; only Traceroute spawns a command and is unavailable in the sandbox.
enum LocalNet {
    // MARK: Name resolution

    struct Resolved { var storage: sockaddr_storage; var length: socklen_t; var family: Int32; var text: String }

    /// Resolve hostnames, preferring IPv4.
    static func resolve(_ host: String, port: String = "0", datagram: Bool = false) -> Resolved? {
        var hints = addrinfo(); hints.ai_family = AF_UNSPEC; hints.ai_socktype = datagram ? SOCK_DGRAM : SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, port, &hints, &res) == 0, let first = res else { return nil }
        defer { freeaddrinfo(res) }
        var best: UnsafeMutablePointer<addrinfo>? = nil
        var p: UnsafeMutablePointer<addrinfo>? = first
        while let cur = p { if cur.pointee.ai_family == AF_INET { best = cur; break }; if best == nil { best = cur }; p = cur.pointee.ai_next }
        guard let a = best, let sa = a.pointee.ai_addr else { return nil }
        var st = sockaddr_storage()
        memcpy(&st, sa, Int(a.pointee.ai_addrlen))
        var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        getnameinfo(sa, a.pointee.ai_addrlen, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST)
        return Resolved(storage: st, length: a.pointee.ai_addrlen, family: a.pointee.ai_family, text: String(cString: buf))
    }

    private static func setPort(_ r: inout Resolved, _ port: UInt16) {
        withUnsafeMutablePointer(to: &r.storage) { p in
            p.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { if r.family == AF_INET { $0.pointee.sin_port = port.bigEndian } }
            p.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { if r.family == AF_INET6 { $0.pointee.sin6_port = port.bigEndian } }
        }
    }

    private static func connectOrSend<T>(_ fd: Int32, _ r: inout Resolved, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        withUnsafePointer(to: &r.storage) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, r.length) } }
    }

    private static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000 }

    // MARK: ICMP Ping (unprivileged datagram sockets)

    static func checksum(_ d: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var i = 0
        while i + 1 < d.count { sum += UInt32(d[i]) << 8 | UInt32(d[i + 1]); i += 2 }
        if i < d.count { sum += UInt32(d[i]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
        return ~UInt16(sum & 0xffff)
    }

    static func ping(host: String, count: Int, emit: ToolEmit) {
        guard var r = resolve(host, datagram: true), r.family == AF_INET else {
            emit(ToolLine(text: String(localized: "Couldn't resolve “\(host)” to an IPv4 address."), kind: .error)); return
        }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard fd >= 0 else { emit(ToolLine(text: String(localized: "Couldn't open an ICMP socket."), kind: .error)); return }
        defer { close(fd) }
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        emit(ToolLine(text: "PING \(host) (\(r.text)): 56 data bytes", kind: .header))
        var rtts: [Double] = []; var sent = 0
        for seq in 0..<count {
            if Task.isCancelled { break }
            var pkt = [UInt8](repeating: 0, count: 64)
            pkt[0] = 8; pkt[4] = UInt8(truncatingIfNeeded: getpid() >> 8); pkt[5] = UInt8(truncatingIfNeeded: getpid()); pkt[6] = UInt8(seq >> 8 & 255); pkt[7] = UInt8(seq & 255)
            for i in 8..<64 { pkt[i] = UInt8(i) }
            let ck = checksum(pkt); pkt[2] = UInt8(ck >> 8); pkt[3] = UInt8(ck & 255)
            let t0 = now()
            let n = connectOrSend(fd, &r) { sa, len in sendto(fd, pkt, pkt.count, 0, sa, len) }
            sent += 1
            if n < 0 { emit(ToolLine(text: "seq=\(seq): " + String(cString: strerror(errno)), kind: .error)); sleep(1); continue }
            var got = false
            let deadline = t0 + 2000
            while now() < deadline && !Task.isCancelled {
                var buf = [UInt8](repeating: 0, count: 1500)
                let m = recv(fd, &buf, buf.count, 0)
                if m <= 0 { break }
                var off = 0, ttl = 0
                if buf[0] >> 4 == 4 { off = Int(buf[0] & 0x0f) * 4; ttl = Int(buf[8]) }
                guard Int(m) > off + 7 else { continue }
                let type = buf[off], rseq = Int(buf[off + 6]) << 8 | Int(buf[off + 7])
                if type == 0 && rseq == (seq & 0xffff) {
                    let ms = now() - t0; rtts.append(ms); got = true
                    emit(ToolLine(text: "\(Int(m) - off) bytes from \(r.text): icmp_seq=\(seq) ttl=\(ttl == 0 ? 64 : ttl) time=\(String(format: "%.2f", ms)) ms", kind: .ok)); break
                } else if type == 3 || type == 11 {
                    emit(ToolLine(text: "icmp_seq=\(seq): " + (type == 3 ? String(localized: "Destination unreachable") : String(localized: "Time exceeded")), kind: .error)); got = true; break
                }
            }
            if !got && !Task.isCancelled { emit(ToolLine(text: "Request timeout for icmp_seq \(seq)", kind: .warn)) }
            if seq < count - 1 && !Task.isCancelled { usleep(900_000) }
        }
        let loss = sent == 0 ? 0 : Double(sent - rtts.count) / Double(sent) * 100
        emit(ToolLine(text: "--- \(host) ping statistics ---", kind: .header))
        emit(ToolLine(text: "\(sent) packets transmitted, \(rtts.count) received, \(String(format: "%.0f", loss))% packet loss", kind: loss == 0 ? .ok : (loss < 100 ? .warn : .error)))
        if let mn = rtts.min(), let mx = rtts.max() {
            emit(ToolLine(text: String(format: "round-trip min/avg/max = %.2f/%.2f/%.2f ms", mn, rtts.reduce(0, +) / Double(rtts.count), mx), kind: .normal))
        }
    }

    // MARK: TCP / UDP

    /// Nonblocking connect/poll returns success/latency milliseconds or failure/reason.
    static func tcpProbe(_ base: Resolved, port: Int, timeoutMs: Int32) -> (open: Bool, ms: Double, reason: String) {
        var r = base; setPort(&r, UInt16(port))
        let fd = socket(r.family, SOCK_STREAM, 0)
        guard fd >= 0 else { return (false, 0, "socket") }
        defer { close(fd) }
        let flags = fcntl(fd, F_GETFL); _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let t0 = now()
        let rc = connectOrSend(fd, &r) { sa, len in connect(fd, sa, len) }
        if rc == 0 { return (true, now() - t0, "") }
        guard errno == EINPROGRESS else { return (false, 0, String(cString: strerror(errno))) }
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let pr = poll(&pfd, 1, timeoutMs)
        if pr == 0 { return (false, 0, "timeout") }
        var err: Int32 = 0; var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
        return err == 0 ? (true, now() - t0, "") : (false, 0, err == ECONNREFUSED ? "refused" : String(cString: strerror(err)))
    }

    static func tcpScan(host: String, ports: [Int], timeoutMs: Int32, showClosed: Bool, emit: ToolEmit) async {
        guard let base = resolve(host) else { emit(ToolLine(text: String(localized: "Couldn't resolve “\(host)”."), kind: .error)); return }
        emit(ToolLine(text: "\(host) (\(base.text)) — \(ports.count) TCP ports", kind: .header))
        var results: [Int: (Bool, Double, String)] = [:]
        let batch = 64
        var idx = 0
        while idx < ports.count, !Task.isCancelled {
            let chunk = Array(ports[idx..<min(idx + batch, ports.count)]); idx += batch
            await withTaskGroup(of: (Int, (Bool, Double, String)).self) { g in
                for p in chunk { g.addTask { (p, tcpProbe(base, port: p, timeoutMs: timeoutMs)) } }
                for await (p, r) in g { results[p] = r }
            }
        }
        var open = 0
        for p in ports.sorted() {
            guard let r = results[p] else { continue }
            let svc = PortsScanner.wellKnown[p] ?? ""
            if r.0 { open += 1; emit(ToolLine(text: String(format: "%5d/tcp  open      %7.1f ms  %@", p, r.1, svc), kind: .ok)) }
            else if showClosed { emit(ToolLine(text: String(format: "%5d/tcp  %-9@ %@", p, r.2 == "refused" ? "closed" : "filtered", svc), kind: .dim)) }
        }
        emit(ToolLine(text: String(localized: "\(open) open, \(results.count - open) closed or filtered"), kind: open > 0 ? .ok : .warn))
    }

    static func udpProbe(_ base: Resolved, port: Int, timeoutMs: Int32) -> String {
        var r = base; setPort(&r, UInt16(port))
        let fd = socket(r.family, SOCK_DGRAM, 0)
        guard fd >= 0 else { return "error" }
        defer { close(fd) }
        guard connectOrSend(fd, &r, { sa, len in connect(fd, sa, len) }) == 0 else { return "error" }
        var payload: [UInt8] = [0]
        if port == 53 { payload = dnsQueryPacket(name: "example.com", type: 1) }
        else if port == 123 { payload = [0x1b] + [UInt8](repeating: 0, count: 47) }
        _ = send(fd, payload, payload.count, 0)
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let pr = poll(&pfd, 1, timeoutMs)
        if pr == 0 { return "open|filtered" }
        var buf = [UInt8](repeating: 0, count: 512)
        let n = recv(fd, &buf, buf.count, 0)
        if n >= 0 { return "open" }
        return errno == ECONNREFUSED ? "closed" : "open|filtered"
    }

    static func udpScan(host: String, ports: [Int], timeoutMs: Int32, emit: ToolEmit) async {
        guard let base = resolve(host, datagram: true) else { emit(ToolLine(text: String(localized: "Couldn't resolve “\(host)”."), kind: .error)); return }
        emit(ToolLine(text: "\(host) (\(base.text)) — \(ports.count) UDP ports", kind: .header))
        var results: [Int: String] = [:]
        var idx = 0
        while idx < ports.count, !Task.isCancelled {
            let chunk = Array(ports[idx..<min(idx + 32, ports.count)]); idx += 32
            await withTaskGroup(of: (Int, String).self) { g in
                for p in chunk { g.addTask { (p, udpProbe(base, port: p, timeoutMs: timeoutMs)) } }
                for await (p, s) in g { results[p] = s }
            }
        }
        for p in ports.sorted() {
            guard let s = results[p] else { continue }
            emit(ToolLine(text: String(format: "%5d/udp  %-14@ %@", p, s, PortsScanner.wellKnown[p] ?? ""), kind: s == "open" ? .ok : (s == "closed" ? .dim : .warn)))
        }
        emit(ToolLine(text: String(localized: "UDP has no handshake: “open|filtered” means no reply came back — the port may be open, or a firewall dropped the probe."), kind: .dim))
    }

    // MARK: DNS

    enum DNSType: String, CaseIterable, Identifiable {
        case all = "ALL", a = "A", aaaa = "AAAA", mx = "MX", txt = "TXT", ns = "NS", cname = "CNAME", soa = "SOA", caa = "CAA", ptr = "PTR"
        var id: String { rawValue }
        var code: UInt16 { switch self { case .a: return 1; case .ns: return 2; case .cname: return 5; case .soa: return 6; case .ptr: return 12; case .mx: return 15; case .txt: return 16; case .aaaa: return 28; case .caa: return 257; case .all: return 0 } }
    }
    static let resolvers: [(name: String, address: String?)] = [
        (String(localized: "System default"), nil), ("Cloudflare 1.1.1.1", "1.1.1.1"), ("Google 8.8.8.8", "8.8.8.8"), ("Quad9 9.9.9.9", "9.9.9.9"),
    ]

    static func systemResolvers() -> [String] {
        if let store = SCDynamicStoreCreate(nil, "ServerDock" as CFString, nil, nil),
           let d = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString) as? [String: Any],
           let a = d["ServerAddresses"] as? [String], !a.isEmpty { return a }
        return ["1.1.1.1"]
    }

    static func dnsQueryPacket(name: String, type: UInt16, id: UInt16 = UInt16.random(in: 1...65535)) -> [UInt8] {
        var p: [UInt8] = [UInt8(id >> 8), UInt8(id & 255), 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]
        for label in name.trimmingCharacters(in: CharacterSet(charactersIn: ".")).split(separator: ".") { p.append(UInt8(min(label.utf8.count, 63))); p += Array(label.utf8.prefix(63)) }
        p += [0, UInt8(type >> 8), UInt8(type & 255), 0, 1]
        return p
    }

    /// Read compressed DNS names, returning name/next offset.
    static func readName(_ d: [UInt8], _ start: Int) -> (String, Int) {
        var labels: [String] = []; var i = start; var next = -1; var hops = 0
        while i < d.count, hops < 40 {
            let l = Int(d[i])
            if l == 0 { i += 1; break }
            if l & 0xC0 == 0xC0, i + 1 < d.count { if next < 0 { next = i + 2 }; i = (l & 0x3F) << 8 | Int(d[i + 1]); hops += 1; continue }
            i += 1
            guard i + l <= d.count else { break }
            labels.append(String(decoding: d[i..<i + l], as: UTF8.self)); i += l
        }
        return (labels.joined(separator: ".") + ".", next >= 0 ? next : i)
    }

    struct DNSRecord { var name: String; var type: UInt16; var ttl: UInt32; var text: String }

    static func parseDNS(_ d: [UInt8]) -> (records: [DNSRecord], rcode: Int, truncated: Bool)? {
        guard d.count >= 12 else { return nil }
        let flags = Int(d[2]) << 8 | Int(d[3]), qd = Int(d[4]) << 8 | Int(d[5]), an = Int(d[6]) << 8 | Int(d[7]), ns = Int(d[8]) << 8 | Int(d[9])
        var off = 12
        for _ in 0..<qd { off = readName(d, off).1 + 4 }
        var out: [DNSRecord] = []
        for _ in 0..<(an + ns) {
            guard off < d.count else { break }
            let (name, o1) = readName(d, off); off = o1
            guard off + 10 <= d.count else { break }
            let type = UInt16(d[off]) << 8 | UInt16(d[off + 1]); let ttl = UInt32(d[off + 4]) << 24 | UInt32(d[off + 5]) << 16 | UInt32(d[off + 6]) << 8 | UInt32(d[off + 7])
            let len = Int(d[off + 8]) << 8 | Int(d[off + 9]); off += 10
            guard off + len <= d.count else { break }
            let rd = off
            var text = ""
            switch type {
            case 1 where len == 4: text = d[rd..<rd + 4].map(String.init).joined(separator: ".")
            case 28 where len == 16:
                var a = in6_addr(); withUnsafeMutableBytes(of: &a) { $0.copyBytes(from: d[rd..<rd + 16]) }
                var b = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN)); inet_ntop(AF_INET6, &a, &b, socklen_t(INET6_ADDRSTRLEN)); text = String(cString: b)
            case 2, 5, 12: text = readName(d, rd).0
            case 15: text = "\(Int(d[rd]) << 8 | Int(d[rd + 1])) \(readName(d, rd + 2).0)"
            case 16:
                var parts: [String] = []; var i = rd
                while i < rd + len { let l = Int(d[i]); i += 1; guard i + l <= rd + len else { break }; parts.append("\"" + String(decoding: d[i..<i + l], as: UTF8.self) + "\""); i += l }
                text = parts.joined(separator: " ")
            case 6:
                let (m, o1) = readName(d, rd); let (r, o2) = readName(d, o1)
                func u32(_ i: Int) -> UInt32 { UInt32(d[i]) << 24 | UInt32(d[i + 1]) << 16 | UInt32(d[i + 2]) << 8 | UInt32(d[i + 3]) }
                if o2 + 20 <= d.count { text = "\(m) \(r) \(u32(o2)) \(u32(o2 + 4)) \(u32(o2 + 8)) \(u32(o2 + 12)) \(u32(o2 + 16))" } else { text = "\(m) \(r)" }
            case 257:
                if len >= 2 { let tl = Int(d[rd + 1]); if rd + 2 + tl <= rd + len { text = "\(d[rd]) \(String(decoding: d[rd + 2..<rd + 2 + tl], as: UTF8.self)) \"\(String(decoding: d[rd + 2 + tl..<rd + len], as: UTF8.self))\"" } }
            default: text = "(\(len) bytes)"
            }
            out.append(DNSRecord(name: name, type: type, ttl: ttl, text: text)); off = rd + len
        }
        return (out, flags & 0x0f, flags & 0x0200 != 0)
    }

    private static func exchange(_ packet: [UInt8], server: String, tcp: Bool) -> [UInt8]? {
        guard var r = resolve(server, port: "53", datagram: !tcp) else { return nil }
        let fd = socket(r.family, tcp ? SOCK_STREAM : SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size)); setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        guard connectOrSend(fd, &r, { sa, len in connect(fd, sa, len) }) == 0 else { return nil }
        if tcp {
            let framed = [UInt8(packet.count >> 8), UInt8(packet.count & 255)] + packet
            guard send(fd, framed, framed.count, 0) == framed.count else { return nil }
            var hdr = [UInt8](repeating: 0, count: 2)
            guard recv(fd, &hdr, 2, MSG_WAITALL) == 2 else { return nil }
            let n = Int(hdr[0]) << 8 | Int(hdr[1]); var buf = [UInt8](repeating: 0, count: n)
            guard recv(fd, &buf, n, MSG_WAITALL) == n else { return nil }
            return buf
        }
        guard send(fd, packet, packet.count, 0) == packet.count else { return nil }
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = recv(fd, &buf, buf.count, 0)
        return n > 0 ? Array(buf[0..<n]) : nil
    }

    /// JSON DNS-over-HTTPS fallback works when UDP 53 is blocked.
    static func dohQuery(name: String, type: String) async -> [DNSRecord]? {
        var comps = URLComponents(string: "https://cloudflare-dns.com/dns-query")!
        comps.queryItems = [URLQueryItem(name: "name", value: name), URLQueryItem(name: "type", value: type)]
        var req = URLRequest(url: comps.url!); req.setValue("application/dns-json", forHTTPHeaderField: "accept"); req.timeoutInterval = 8
        guard let (data, _) = try? await URLSession.shared.data(for: req), let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let answers = (j["Answer"] as? [[String: Any]]) ?? []
        return answers.map { DNSRecord(name: ($0["name"] as? String ?? "") + ".", type: UInt16($0["type"] as? Int ?? 0), ttl: UInt32($0["TTL"] as? Int ?? 0), text: $0["data"] as? String ?? "") }
    }

    static func reverseName(_ ip: String) -> String? {
        if let v4 = SubnetCalculator.parseIPv4(ip) { return "\(v4 & 255).\((v4 >> 8) & 255).\((v4 >> 16) & 255).\(v4 >> 24).in-addr.arpa" }
        var a = in6_addr()
        guard inet_pton(AF_INET6, ip, &a) == 1 else { return nil }
        let nibbles = withUnsafeBytes(of: &a) { $0.flatMap { [String($0 >> 4, radix: 16), String($0 & 15, radix: 16)] } }
        return nibbles.reversed().joined(separator: ".") + ".ip6.arpa"
    }

    static func typeName(_ t: UInt16) -> String {
        switch t { case 1: return "A"; case 2: return "NS"; case 5: return "CNAME"; case 6: return "SOA"; case 12: return "PTR"; case 15: return "MX"; case 16: return "TXT"; case 28: return "AAAA"; case 257: return "CAA"; default: return "TYPE\(t)" }
    }

    static func dnsLookup(name rawName: String, type: DNSType, resolver: String?, emit: ToolEmit) async {
        var name = rawName.trimmingCharacters(in: .whitespaces)
        var t = type
        if let rev = reverseName(name), type == .ptr || type == .all { name = rev; t = .ptr }
        let server = resolver ?? systemResolvers().first ?? "1.1.1.1"
        emit(ToolLine(text: "\(name)  @\(server)", kind: .header))
        let types: [DNSType] = t == .all ? [.a, .aaaa, .cname, .mx, .ns, .txt, .soa, .caa] : [t]
        var total = 0
        for ty in types {
            if Task.isCancelled { return }
            var recs: [DNSRecord]?; var via = "UDP"
            if let resp = exchange(dnsQueryPacket(name: name, type: ty.code), server: server, tcp: false), var p = parseDNS(resp) {
                if p.truncated, let full = exchange(dnsQueryPacket(name: name, type: ty.code), server: server, tcp: true), let p2 = parseDNS(full) { p = p2; via = "TCP" }
                if p.rcode == 3 { emit(ToolLine(text: "NXDOMAIN — \(name) " + String(localized: "doesn't exist"), kind: .error)); return }
                recs = p.records
            }
            if recs == nil, let doh = await dohQuery(name: name, type: ty.rawValue) { recs = doh; via = "DoH" }
            guard let recs else { emit(ToolLine(text: "\(ty.rawValue): " + String(localized: "no response (UDP and DNS-over-HTTPS both failed)"), kind: .error)); continue }
            let matching = recs.filter { $0.type == ty.code || ty == .all }
            if matching.isEmpty { if t != .all { emit(ToolLine(text: "\(ty.rawValue): " + String(localized: "no records"), kind: .warn)) }; continue }
            for r in matching { total += 1; emit(ToolLine(text: "\(r.name.padding(toLength: 30, withPad: " ", startingAt: 0)) \(String(r.ttl).padding(toLength: 6, withPad: " ", startingAt: 0)) IN \(typeName(r.type).padding(toLength: 6, withPad: " ", startingAt: 0)) \(r.text)", kind: .ok)) }
            if via != "UDP" { emit(ToolLine(text: "  (\(ty.rawValue) via \(via))", kind: .dim)) }
        }
        if total == 0 && t == .all { emit(ToolLine(text: String(localized: "No records found."), kind: .warn)) }
    }

    // MARK: System Traceroute (unavailable in sandbox builds)

    static func traceroute(host: String, maxHops: Int, emit: @escaping ToolEmit) async {
        if AppEnv.isMAS { emit(ToolLine(text: String(localized: "Traceroute on this Mac isn't available in the App Store build. Run it from a server instead."), kind: .warn)); return }
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/traceroute")
        p.arguments = ["-n", "-q", "1", "-w", "2", "-m", String(maxHops), host]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        final class Buf: @unchecked Sendable { var s = "" }
        let buf = Buf()
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData; guard !d.isEmpty else { return }
            buf.s += String(decoding: d, as: UTF8.self)
            while let nl = buf.s.firstIndex(of: "\n") { let line = String(buf.s[..<nl]); buf.s = String(buf.s[buf.s.index(after: nl)...]); emit(ToolLine(text: line, kind: line.contains("*") ? .warn : .normal)) }
        }
        do { try p.run() } catch { emit(ToolLine(text: error.localizedDescription, kind: .error)); return }
        await withTaskCancellationHandler { await Task.detached { p.waitUntilExit() }.value } onCancel: { p.terminate() }
        pipe.fileHandleForReading.readabilityHandler = nil
        if !buf.s.isEmpty { emit(ToolLine(text: buf.s)) }
    }

    // MARK: Whois

    static func whoisRaw(server: String, query: String) -> String? {
        guard var r = resolve(server, port: "43") else { return nil }
        let fd = socket(r.family, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var tv = timeval(tv_sec: 8, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size)); setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        guard connectOrSend(fd, &r, { sa, len in connect(fd, sa, len) }) == 0 else { return nil }
        let q = Array((query + "\r\n").utf8); _ = send(fd, q, q.count, 0)
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 8192)
        while out.count < 96 * 1024 { let n = recv(fd, &buf, buf.count, 0); if n <= 0 { break }; out.append(contentsOf: buf[0..<n]) }
        return String(decoding: out, as: UTF8.self)
    }

    static func whois(query: String, emit: ToolEmit) {
        var server = "whois.iana.org"
        var visited = Set<String>()
        for _ in 0..<3 {
            if Task.isCancelled { return }
            guard visited.insert(server).inserted else { break }
            emit(ToolLine(text: "# whois -h \(server) \(query)", kind: .header))
            guard let text = whoisRaw(server: server, query: query) else { emit(ToolLine(text: String(localized: "Couldn't reach \(server)."), kind: .error)); return }
            var next: String?
            for l in text.replacingOccurrences(of: "\r", with: "").split(separator: "\n", omittingEmptySubsequences: false) {
                let line = String(l); emit(ToolLine(text: line, kind: line.hasPrefix("%") || line.hasPrefix("#") ? .dim : .normal))
                let low = line.lowercased()
                if next == nil, low.hasPrefix("refer:") || low.hasPrefix("whois:") || low.hasPrefix("registrar whois server:") {
                    let v = line.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                    if !v.isEmpty, v != server { next = v.replacingOccurrences(of: "whois://", with: "").replacingOccurrences(of: "/", with: "") }
                }
            }
            guard let n = next else { break }
            server = n
        }
    }

    // MARK: SSL certificates

    private static func flatten(_ v: Any?) -> [(String, String)] {
        var out: [(String, String)] = []
        if let arr = v as? [[String: Any]] {
            for e in arr {
                let label = e[kSecPropertyKeyLabel as String] as? String ?? ""
                let val = e[kSecPropertyKeyValue as String]
                if let s = val as? String { out.append((label, s)) } else if let n = val as? NSNumber { out.append((label, n.stringValue)) }
                else { out += flatten(val) }
            }
        }
        return out
    }

    private static let oidNames = ["2.5.4.3": "CN", "2.5.4.6": "C", "2.5.4.7": "L", "2.5.4.8": "ST", "2.5.4.10": "O", "2.5.4.11": "OU"]

    static func certDetails(_ cert: SecCertificate) -> (subject: String, issuer: String, notBefore: Date?, notAfter: Date?, sans: [String]) {
        let keys = [kSecOIDX509V1SubjectName, kSecOIDX509V1IssuerName, kSecOIDX509V1ValidityNotBefore, kSecOIDX509V1ValidityNotAfter, kSecOIDSubjectAltName] as CFArray
        let vals = SecCertificateCopyValues(cert, keys, nil) as? [String: Any] ?? [:]
        func entry(_ k: CFString) -> [String: Any]? { vals[k as String] as? [String: Any] }
        func name(_ k: CFString) -> String { flatten(entry(k)?[kSecPropertyKeyValue as String] as? [[String: Any]]).map { "\(oidNames[$0.0] ?? $0.0)=\($0.1)" }.joined(separator: ", ") }
        func date(_ k: CFString) -> Date? { (entry(k)?[kSecPropertyKeyValue as String] as? NSNumber).map { Date(timeIntervalSinceReferenceDate: $0.doubleValue) } }
        let sans = flatten(entry(kSecOIDSubjectAltName)?[kSecPropertyKeyValue as String] as? [[String: Any]]).filter { $0.0.lowercased().contains("dns") }.map(\.1)
        let subject = name(kSecOIDX509V1SubjectName)
        return (subject.isEmpty ? ((SecCertificateCopySubjectSummary(cert) as String?) ?? "") : subject, name(kSecOIDX509V1IssuerName), date(kSecOIDX509V1ValidityNotBefore), date(kSecOIDX509V1ValidityNotAfter), sans)
    }

    static func sslCertificate(host: String, port: Int, emit: @escaping ToolEmit) async {
        final class Box: @unchecked Sendable { var chain: [SecCertificate] = []; var valid = false; var error = ""; var version = ""; var cipher = "" }
        let box = Box()
        let queue = DispatchQueue(label: "ssl-probe")
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, host)
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            let t = sec_trust_copy_ref(trust).takeRetainedValue()
            box.chain = (SecTrustCopyCertificateChain(t) as? [SecCertificate]) ?? []
            var err: CFError?; box.valid = SecTrustEvaluateWithError(t, &err); box.error = err.map { CFErrorCopyDescription($0) as String? ?? "" } ?? ""
            complete(true)   // Permit invalid certificates for inspection; assess validity separately above.
        }, queue)
        let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(port)) ?? 443, using: NWParameters(tls: tls))
        let ok: Bool = await withCheckedContinuation { cont in
            final class Once: @unchecked Sendable { var done = false }
            let once = Once()
            conn.stateUpdateHandler = { s in
                switch s {
                case .ready:
                    if let md = conn.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata {
                        let m = md.securityProtocolMetadata
                        box.version = "\(sec_protocol_metadata_get_negotiated_tls_protocol_version(m).rawValue)"
                        box.cipher = "\(sec_protocol_metadata_get_negotiated_tls_ciphersuite(m).rawValue)"
                    }
                    if !once.done { once.done = true; cont.resume(returning: true) }
                case .failed, .cancelled:
                    if !once.done { once.done = true; cont.resume(returning: false) }
                default: break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 10) { if !once.done { once.done = true; conn.cancel(); cont.resume(returning: false) } }
        }
        conn.cancel()
        guard ok || !box.chain.isEmpty, let leaf = box.chain.first else { emit(ToolLine(text: String(localized: "Couldn't complete a TLS handshake with \(host):\(port)."), kind: .error)); return }
        let d = certDetails(leaf)
        emit(ToolLine(text: "\(host):\(port)", kind: .header))
        emit(ToolLine(text: box.valid ? String(localized: "Trusted by this Mac") : String(localized: "Not trusted: ") + box.error, kind: box.valid ? .ok : .error))
        emit(ToolLine(text: "Subject      \(d.subject)"))
        emit(ToolLine(text: "Issuer       \(d.issuer)"))
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        if let nb = d.notBefore { emit(ToolLine(text: "Valid from   \(f.string(from: nb))")) }
        if let na = d.notAfter {
            let days = Int(na.timeIntervalSinceNow / 86400)
            emit(ToolLine(text: "Valid until  \(f.string(from: na))  (" + (days < 0 ? String(localized: "expired \(-days) days ago") : String(localized: "\(days) days left")) + ")", kind: days < 0 ? .error : (days < 30 ? .warn : .ok)))
        }
        if !d.sans.isEmpty { emit(ToolLine(text: "Names        \(d.sans.joined(separator: ", "))")) }
        let fp = SHA256.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02X", $0) }.joined(separator: ":")
        emit(ToolLine(text: "SHA-256      \(fp)", kind: .dim))
        if box.chain.count > 1 {
            emit(ToolLine(text: String(localized: "Certificate chain"), kind: .header))
            for (i, c) in box.chain.enumerated() { emit(ToolLine(text: "  \(i). " + ((SecCertificateCopySubjectSummary(c) as String?) ?? "?"), kind: .dim)) }
        }
    }

    // MARK: Certificate Transparency subdomain discovery

    /// Collect hostnames from crt.sh, falling back to Cert Spotter.
    static func ctNames(domain: String, includeExpired: Bool, fetch: (URL) async -> Data?) async -> (names: Set<String>, certs: Int, source: String)? {
        let d = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        var names = Set<String>()
        var comps = URLComponents(string: "https://crt.sh/")!
        comps.queryItems = [URLQueryItem(name: "q", value: "%." + d), URLQueryItem(name: "output", value: "json")] + (includeExpired ? [] : [URLQueryItem(name: "exclude", value: "expired")])
        if let url = comps.url, let data = await fetch(url), let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for e in arr { for n in ((e["name_value"] as? String) ?? "").split(separator: "\n") { names.insert(String(n).lowercased()) } }
            return (names, arr.count, "crt.sh")
        }
        var c2 = URLComponents(string: "https://api.certspotter.com/v1/issuances")!
        c2.queryItems = [URLQueryItem(name: "domain", value: d), URLQueryItem(name: "include_subdomains", value: "true"), URLQueryItem(name: "expand", value: "dns_names")] + (includeExpired ? [] : [URLQueryItem(name: "match_wildcards", value: "false")])
        if let url = c2.url, let data = await fetch(url), let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for e in arr { for n in (e["dns_names"] as? [String]) ?? [] { names.insert(n.lowercased()) } }
            return (names, arr.count, "Cert Spotter")
        }
        return nil
    }

    static func localFetch(_ url: URL) async -> Data? {
        var req = URLRequest(url: url); req.timeoutInterval = 60; req.setValue("ServerDock", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    /// Normalize/disclose discovered names; resolveNames optionally shows resolution status.
    static func emitSubdomains(domain: String, result: (names: Set<String>, certs: Int, source: String), resolveNames: Bool, emit: ToolEmit) async {
        let d = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        let inScope = result.names.filter { $0 == d || $0.hasSuffix("." + d) }
        let wildcards = inScope.filter { $0.hasPrefix("*.") }.sorted()
        let hosts = inScope.filter { !$0.hasPrefix("*.") && !$0.contains(" ") }.sorted()
        emit(ToolLine(text: String(localized: "\(hosts.count) host names from \(result.certs) certificates (\(result.source))"), kind: .header))
        var resolved: [String: String] = [:]
        if resolveNames {
            emit(ToolLine(text: String(localized: "Checking which names resolve…"), kind: .dim))
            let list = Array(hosts.prefix(600))
            var idx = 0
            while idx < list.count, !Task.isCancelled {
                let chunk = Array(list[idx..<min(idx + 24, list.count)]); idx += 24
                await withTaskGroup(of: (String, String?).self) { g in
                    for h in chunk { g.addTask { (h, resolve(h)?.text) } }
                    for await (h, ip) in g { if let ip { resolved[h] = ip } }
                }
            }
        }
        for h in hosts {
            if resolveNames { emit(ToolLine(text: h.padding(toLength: 46, withPad: " ", startingAt: 0) + (resolved[h] ?? "—"), kind: resolved[h] != nil ? .ok : .dim)) }
            else { emit(ToolLine(text: h)) }
        }
        if !wildcards.isEmpty { emit(ToolLine(text: String(localized: "Wildcard certificates"), kind: .header)); wildcards.forEach { emit(ToolLine(text: $0, kind: .dim)) } }
        if resolveNames { emit(ToolLine(text: String(localized: "\(resolved.count) of \(min(hosts.count, 600)) resolve to an address."), kind: .ok)) }
    }

    // MARK: Network information

    static func networkInfo(emit: ToolEmit) async {
        emit(ToolLine(text: String(localized: "This Mac"), kind: .header))
        var ifaces: [String: (flags: Int32, v4: [String], v6: [String], mac: String, mtu: Int)] = [:]
        var order: [String] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifap) == 0, let first = ifap {
            var p: UnsafeMutablePointer<ifaddrs>? = first
            while let cur = p {
                let name = String(cString: cur.pointee.ifa_name)
                if ifaces[name] == nil { ifaces[name] = (Int32(cur.pointee.ifa_flags), [], [], "", 0); order.append(name) }
                if let a = cur.pointee.ifa_addr {
                    switch Int32(a.pointee.sa_family) {
                    case AF_INET:
                        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN)); var sin = a.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                        inet_ntop(AF_INET, &sin, &buf, socklen_t(INET_ADDRSTRLEN))
                        var mask = ""
                        if let m = cur.pointee.ifa_netmask { let mv = m.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }; mask = "/\(mv.nonzeroBitCount)" }
                        ifaces[name]?.v4.append(String(cString: buf) + mask)
                    case AF_INET6:
                        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN)); var s6 = a.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                        inet_ntop(AF_INET6, &s6, &buf, socklen_t(INET6_ADDRSTRLEN)); let s = String(cString: buf)
                        if !s.hasPrefix("fe80") { ifaces[name]?.v6.append(s) }
                    case AF_LINK:
                        a.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { dl in
                            let n = Int(dl.pointee.sdl_alen)
                            if n == 6 { let off = MemoryLayout<sockaddr_dl>.offset(of: \.sdl_data)! + Int(dl.pointee.sdl_nlen)
                                let mac = (0..<6).map { UnsafeRawPointer(dl).load(fromByteOffset: off + $0, as: UInt8.self) }; ifaces[name]?.mac = mac.map { String(format: "%02x", $0) }.joined(separator: ":") }
                        }
                    default: break
                    }
                }
                p = cur.pointee.ifa_next
            }
            freeifaddrs(ifap)
        }
        for n in order {
            guard let i = ifaces[n], i.flags & IFF_LOOPBACK == 0, !i.v4.isEmpty || !i.v6.isEmpty else { continue }
            let up = i.flags & IFF_UP != 0 && i.flags & IFF_RUNNING != 0
            emit(ToolLine(text: "\(n.padding(toLength: 8, withPad: " ", startingAt: 0)) \(up ? "up  " : "down") \((i.mac == "02:00:00:00:00:00" ? "" : i.mac).padding(toLength: 18, withPad: " ", startingAt: 0)) \((i.v4 + i.v6.prefix(2)).joined(separator: "  "))", kind: up ? .ok : .dim))
        }
        if let store = SCDynamicStoreCreate(nil, "ServerDock" as CFString, nil, nil) {
            if let g = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any] {
                emit(ToolLine(text: "Gateway      \(g["Router"] as? String ?? "—")  (\(g["PrimaryInterface"] as? String ?? "?"))"))
            }
            emit(ToolLine(text: "DNS servers  " + systemResolvers().joined(separator: ", ")))
        }
        if let w = CWWiFiClient.shared().interface(), w.powerOn() {
            let band = w.wlanChannel().map { "ch \($0.channelNumber)" } ?? ""
            emit(ToolLine(text: "Wi-Fi        \(w.ssid() ?? String(localized: "(name hidden — needs location permission)"))  RSSI \(w.rssiValue()) dBm  \(Int(w.transmitRate())) Mbps  \(band)"))
        }
        if let data = await localFetch(URL(string: "https://api.ipify.org")!), let ip = String(data: data, encoding: .utf8) {
            emit(ToolLine(text: "Public IP    \(ip.trimmingCharacters(in: .whitespacesAndNewlines))", kind: .ok))
        } else { emit(ToolLine(text: "Public IP    " + String(localized: "unavailable (offline?)"), kind: .dim)) }
    }
}

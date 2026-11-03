import Foundation

/// Network tool kinds.
enum NetTool: String, CaseIterable, Identifiable {
    case info, ping, dns, tcp, udp, trace, http, whois, ssl, subdomains, subnet, ports
    var id: String { rawValue }

    /// Tools grouped separately under Certificates in the sidebar.
    static let certificateTools: [NetTool] = [.ssl, .subdomains]

    var title: String {
        switch self {
        case .info: return String(localized: "Network Info")
        case .ping: return "Ping"
        case .dns: return String(localized: "DNS Lookup")
        case .tcp: return String(localized: "TCP Port Test")
        case .udp: return String(localized: "UDP Port Probe")
        case .trace: return "Traceroute"
        case .http: return String(localized: "HTTP Check")
        case .whois: return "Whois"
        case .ssl: return String(localized: "SSL Certificate")
        case .subdomains: return String(localized: "Subdomain Finder (CT)")
        case .subnet: return String(localized: "Subnet Calculator")
        case .ports: return String(localized: "Port Reference")
        }
    }
    var symbol: String {
        switch self {
        case .info: return "network"; case .ping: return "dot.radiowaves.left.and.right"; case .dns: return "magnifyingglass"
        case .tcp: return "point.3.connected.trianglepath.dotted"; case .udp: return "paperplane"; case .trace: return "point.topleft.down.to.point.bottomright.curvepath"; case .http: return "waveform.badge.magnifyingglass"
        case .whois: return "person.text.rectangle"; case .ssl: return "lock.shield"; case .subdomains: return "list.bullet.indent"
        case .subnet: return "square.grid.3x3"; case .ports: return "list.number"
        }
    }
    var summary: String {
        switch self {
        case .info: return String(localized: "Interfaces, addresses, gateway, DNS servers and the public IP.")
        case .ping: return String(localized: "Check that a host answers and how long the round trip takes.")
        case .dns: return String(localized: "Look up A, AAAA, MX, TXT, NS, CNAME, SOA, CAA and PTR records.")
        case .tcp: return String(localized: "Test which TCP ports accept connections, with latency.")
        case .udp: return String(localized: "Probe UDP ports. UDP has no handshake, so “open|filtered” is common.")
        case .trace: return String(localized: "Show the network path (hops) to a destination.")
        case .http: return String(localized: "Request a URL and see the status code, timings, redirect and headers — from this Mac or from a server.")
        case .whois: return String(localized: "Registration details for a domain or IP address.")
        case .ssl: return String(localized: "Read a server's TLS certificate: subject, issuer, validity, names and fingerprint.")
        case .subdomains: return String(localized: "Find host names under a domain in public Certificate Transparency logs.")
        case .subnet: return String(localized: "CIDR analysis: network, broadcast, mask, usable range and address type.")
        case .ports: return String(localized: "Common TCP/UDP port numbers and what they are used for.")
        }
    }
    /// Short sidebar-row description.
    var brief: String {
        switch self {
        case .info: return String(localized: "Addresses · gateway · DNS")
        case .ping: return "ICMP"
        case .dns: return "A · MX · TXT · NS"
        case .tcp: return String(localized: "Open or closed, with latency")
        case .udp: return "open | filtered"
        case .trace: return String(localized: "Hops to a destination")
        case .http: return String(localized: "Status · time · headers")
        case .whois: return String(localized: "Domain / IP registration")
        case .ssl: return String(localized: "Certificate and expiry")
        case .subdomains: return "crt.sh · Cert Spotter"
        case .subnet: return "CIDR"
        case .ports: return String(localized: "Common port numbers")
        }
    }

    /// Tools selectable for local/server execution; calculators/reference tables are location-independent.
    var hasLocation: Bool { self != .subnet && self != .ports }
    var needsTarget: Bool { self != .info && self != .ports }
    var targetPlaceholder: String {
        switch self {
        case .subnet: return "192.168.1.0/24"
        case .dns: return "example.com"
        case .http: return "https://example.com/health"
        case .subdomains: return "example.com"
        case .whois: return "example.com or 8.8.8.8"
        default: return "example.com or 192.168.0.1"
        }
    }
}

/// One console-result line.
struct ToolLine: Identifiable {
    enum Kind { case normal, ok, warn, error, dim, header }
    let id = UUID()
    var text: String
    var kind: Kind = .normal
}

/// Parse port lists/ranges such as 80,443,8000-8100.
enum PortSpec {
    static let presets: [(String, String)] = [
        (String(localized: "Web"), "80,443,8080,8443"), (String(localized: "SSH / FTP"), "21,22,990,2222"), (String(localized: "Mail"), "25,110,143,465,587,993,995"),
        (String(localized: "Databases"), "3306,5432,6379,27017,1433,9200"), (String(localized: "Remote access"), "22,3389,5900,5901"),
        (String(localized: "Top 20"), "21,22,23,25,53,80,110,143,443,445,993,995,1723,3306,3389,5432,5900,8080,8443,9090"),
    ]

    static func parse(_ text: String, limit: Int = 2048) -> (ports: [Int], error: String?) {
        var out: [Int] = []
        var seen = Set<Int>()
        for part in text.split(whereSeparator: { $0 == "," || $0 == " " }) {
            let p = part.trimmingCharacters(in: .whitespaces)
            if p.isEmpty { continue }
            let bounds = p.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
            if bounds.count == 1, let n = Int(bounds[0]), (1...65535).contains(n) { if seen.insert(n).inserted { out.append(n) } }
            else if bounds.count == 2, let a = Int(bounds[0]), let b = Int(bounds[1]), (1...65535).contains(a), (1...65535).contains(b), a <= b {
                for n in a...b { if seen.insert(n).inserted { out.append(n) }; if out.count > limit { break } }
            } else { return ([], String(localized: "“\(p)” isn't a valid port or range (use 80,443 or 1-1024).")) }
            if out.count > limit { return ([], String(localized: "Too many ports (limit \(limit)).")) }
        }
        if out.isEmpty { return ([], String(localized: "Enter at least one port.")) }
        return (out, nil)
    }
}

/// IPv4 subnet calculator.
enum SubnetCalculator {
    static func parseIPv4(_ s: String) -> UInt32? {
        let p = s.split(separator: ".", omittingEmptySubsequences: false)
        guard p.count == 4 else { return nil }
        var v: UInt32 = 0
        for x in p { guard let n = UInt32(x), n <= 255 else { return nil }; v = v << 8 | n }
        return v
    }
    static func str(_ v: UInt32) -> String { "\(v >> 24).\((v >> 16) & 255).\((v >> 8) & 255).\(v & 255)" }
    static func binary(_ v: UInt32) -> String { (0..<4).map { i in String(String((v >> UInt32(24 - 8 * i)) & 255, radix: 2).leftPad(8)) }.joined(separator: ".") }

    /// Convert CIDR or IP/netmask input into result lines.
    static func analyze(_ input: String) -> [ToolLine] {
        let t = input.trimmingCharacters(in: .whitespaces)
        var ip: UInt32?, prefix: Int?
        if let slash = t.firstIndex(of: "/") {
            ip = parseIPv4(String(t[..<slash]))
            let rest = String(t[t.index(after: slash)...])
            if let n = Int(rest), (0...32).contains(n) { prefix = n }
            else if let m = parseIPv4(rest), let n = prefixLength(mask: m) { prefix = n }
        } else {
            let parts = t.split(separator: " ").map(String.init)
            if parts.count == 2 { ip = parseIPv4(parts[0]); if let m = parseIPv4(parts[1]) { prefix = prefixLength(mask: m) } }
            else if parts.count == 1 { ip = parseIPv4(parts[0]); prefix = 32 }
        }
        guard let ip, let prefix else { return [ToolLine(text: String(localized: "Enter an IPv4 address with a prefix, for example 192.168.1.0/24 or 10.0.0.5 255.255.255.0."), kind: .error)] }
        let mask: UInt32 = prefix == 0 ? 0 : ~UInt32(0) << UInt32(32 - prefix)
        let net = ip & mask, bcast = net | ~mask
        let total = UInt64(1) << UInt64(32 - prefix)
        let usable: UInt64 = prefix >= 31 ? total : total - 2
        let first = prefix >= 31 ? net : net + 1, last = prefix >= 31 ? bcast : bcast - 1
        func row(_ k: String, _ v: String) -> ToolLine { ToolLine(text: k.padding(toLength: 22, withPad: " ", startingAt: 0) + v) }
        return [
            ToolLine(text: "\(str(ip))/\(prefix)", kind: .header),
            row(String(localized: "Network address"), str(net)), row(String(localized: "Broadcast address"), str(bcast)),
            row(String(localized: "Subnet mask"), str(mask)), row(String(localized: "Wildcard mask"), str(~mask)),
            row(String(localized: "First usable host"), str(first)), row(String(localized: "Last usable host"), str(last)),
            row(String(localized: "Total addresses"), "\(total)"), row(String(localized: "Usable hosts"), "\(usable)"),
            row(String(localized: "IP class"), ipClass(ip)), row(String(localized: "Address type"), addressType(ip)),
            row(String(localized: "Mask (binary)"), binary(mask)), row(String(localized: "Address (binary)"), binary(ip)),
        ]
    }

    static func prefixLength(mask: UInt32) -> Int? {
        let inv = ~mask
        return (inv & (inv &+ 1)) == 0 ? mask.nonzeroBitCount : nil   // Valid masks require contiguous one bits.
    }
    static func ipClass(_ v: UInt32) -> String {
        switch v >> 24 { case 0..<128: return "A"; case 128..<192: return "B"; case 192..<224: return "C"; case 224..<240: return "D (multicast)"; default: return "E (reserved)" }
    }
    static func addressType(_ v: UInt32) -> String {
        let a = v >> 24, b = (v >> 16) & 255
        if a == 10 || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168) { return String(localized: "Private") }
        if a == 127 { return String(localized: "Loopback") }
        if a == 169 && b == 254 { return String(localized: "Link-local (APIPA)") }
        if a == 100 && (64...127).contains(b) { return String(localized: "Carrier-grade NAT (100.64.0.0/10)") }
        if a >= 224 && a < 240 { return String(localized: "Multicast") }
        if a >= 240 { return String(localized: "Reserved") }
        if a == 0 { return String(localized: "“This network” (0.0.0.0/8)") }
        return String(localized: "Public")
    }
}

private extension String {
    func leftPad(_ n: Int) -> String { count >= n ? self : String(repeating: "0", count: n - count) + self }
}

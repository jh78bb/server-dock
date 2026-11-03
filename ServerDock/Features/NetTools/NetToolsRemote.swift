import Foundation

/// Build remote scripts using installed dig/host/nc/traceroute/openssl and available fallbacks.
enum RemoteNet {
    static func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }

    static func script(_ tool: NetTool, target: String, ports: [Int], count: Int, dnsType: String, resolver: String?, timeout: Int) -> String {
        let t = q(target)
        switch tool {
        case .info:
            return """
            echo "## $(hostname 2>/dev/null)"
            if command -v ip >/dev/null 2>&1; then ip -br addr 2>/dev/null; echo; ip route 2>/dev/null | head -5
            else ifconfig 2>/dev/null | grep -E '^[a-z0-9]+:|inet ' ; netstat -rn 2>/dev/null | head -8; fi
            echo; echo "## DNS"; grep -E '^(nameserver|search)' /etc/resolv.conf 2>/dev/null
            echo; echo "## Public IP"
            (curl -s -m 6 https://api.ipify.org || wget -qO- -T 6 https://api.ipify.org) 2>/dev/null; echo
            """
        case .ping:
            return "ping -c \(count) -W 2 \(t) 2>&1 || ping -c \(count) \(t) 2>&1"
        case .dns:
            let r = resolver.map { " @" + q($0) } ?? ""
            let types = dnsType == "ALL" ? ["A", "AAAA", "CNAME", "MX", "NS", "TXT", "SOA", "CAA"] : [dnsType]
            let dig = types.map { "dig +noall +answer +time=3 +tries=1\(r) \($0) \(t)" }.joined(separator: "; ")
            let ns = resolver.map { " " + q($0) } ?? ""
            return """
            if command -v dig >/dev/null 2>&1; then \(dig)
            elif command -v host >/dev/null 2>&1; then host -a \(t)\(ns) 2>&1
            elif command -v nslookup >/dev/null 2>&1; then nslookup \(t)\(ns) 2>&1
            else getent ahosts \(t) 2>&1 || echo "No DNS tool (dig/host/nslookup) on this server."; fi
            """
        case .tcp:
            let list = ports.map(String.init).joined(separator: " ")
            return """
            for p in \(list); do
              if command -v nc >/dev/null 2>&1; then nc -z -w \(timeout) \(t) $p >/dev/null 2>&1 && echo "$p open" || echo "$p closed"
              elif command -v timeout >/dev/null 2>&1; then timeout \(timeout) bash -c "exec 3<>/dev/tcp/\(target)/$p" >/dev/null 2>&1 && echo "$p open" || echo "$p closed"
              else echo "$p unknown"; fi
            done
            """
        case .udp:
            let list = ports.map(String.init).joined(separator: " ")
            return """
            command -v nc >/dev/null 2>&1 || { echo "__NONC__"; exit 0; }
            for p in \(list); do nc -zu -w \(timeout) \(t) $p >/dev/null 2>&1 && echo "$p open|filtered" || echo "$p closed"; done
            """
        case .trace:
            return "if command -v traceroute >/dev/null 2>&1; then traceroute -n -w 2 -q 1 -m 20 \(t) 2>&1; elif command -v tracepath >/dev/null 2>&1; then tracepath -n \(t) 2>&1; else echo 'traceroute/tracepath is not installed on this server.'; fi"
        case .whois:
            return "command -v whois >/dev/null 2>&1 && whois \(t) 2>&1 || echo '__NOWHOIS__'"
        case .ssl:
            let p = ports.first ?? 443
            return """
            command -v openssl >/dev/null 2>&1 || { echo "openssl is not installed on this server."; exit 0; }
            echo | openssl s_client -servername \(t) -connect \(t):\(p) -showcerts 2>/dev/null > /tmp/.sd_ssl.$$
            grep -E 'Verify return code|Protocol|Cipher is|Verification' /tmp/.sd_ssl.$$ | head -5
            sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' /tmp/.sd_ssl.$$ | awk '/END CERTIFICATE/{print; exit} {print}' | openssl x509 -noout -subject -issuer -dates -fingerprint -sha256 -ext subjectAltName 2>&1
            rm -f /tmp/.sd_ssl.$$
            """
        case .subdomains, .subnet, .ports, .http:
            return ""
        }
    }

    static func lines(_ tool: NetTool, output: String, ports: [Int]) -> [ToolLine] {
        let raw = output.replacingOccurrences(of: "\r", with: "").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        switch tool {
        case .tcp, .udp:
            if output.contains("__NONC__") { return [ToolLine(text: String(localized: "nc (netcat) isn't installed on this server."), kind: .error)] }
            var out: [ToolLine] = []
            for l in raw {
                let f = l.split(separator: " ").map(String.init)
                guard f.count == 2, let p = Int(f[0]) else { if !l.isEmpty { out.append(ToolLine(text: l, kind: .dim)) }; continue }
                let svc = PortsScanner.wellKnown[p] ?? ""
                let proto = tool == .tcp ? "tcp" : "udp"
                out.append(ToolLine(text: String(format: "%5d/%@  %-14@ %@", p, proto, f[1], svc), kind: f[1] == "open" ? .ok : (f[1] == "closed" ? .dim : .warn)))
            }
            return out
        case .whois:
            if output.contains("__NOWHOIS__") { return [ToolLine(text: String(localized: "whois isn't installed on this server. Try “This Mac”."), kind: .error)] }
            return raw.map { ToolLine(text: $0, kind: $0.hasPrefix("%") || $0.hasPrefix("#") ? .dim : .normal) }
        case .ping:
            return raw.map { l in ToolLine(text: l, kind: l.contains("bytes from") ? .ok : (l.contains("100% packet loss") || l.contains("unreachable") || l.contains("unknown host") ? .error : .normal)) }
        default:
            return raw.map { ToolLine(text: $0, kind: $0.hasPrefix("##") ? .header : .normal) }
        }
    }

    /// Convert HTTP-check results into shared local/remote console lines.
    static func httpLines(_ r: HTTPCheckResult) -> [ToolLine] {
        func ms(_ v: Double?) -> String { v.map { $0 < 1000 ? String(format: "%.0f ms", $0) : String(format: "%.2f s", $0 / 1000) } ?? "—" }
        var out: [ToolLine] = []
        let code = r.statusCode
        let kind: ToolLine.Kind = r.error != nil || (code ?? 0) >= 400 ? .error : ((code ?? 0) >= 300 ? .warn : .ok)
        out.append(ToolLine(text: code.map { "\($0) \(HTTPURLResponse.localizedString(forStatusCode: $0).capitalized)" } ?? String(localized: "No response"), kind: kind))
        if let e = r.error { out.append(ToolLine(text: e, kind: .error)) }
        out.append(ToolLine(text: "Total        \(ms(r.totalMs))"))
        out.append(ToolLine(text: "Connect      \(ms(r.connectMs))"))
        out.append(ToolLine(text: "First byte   \(ms(r.firstByteMs))"))
        if let b = r.bytes { out.append(ToolLine(text: "Size         \(ByteCountFormatter.string(fromByteCount: b, countStyle: .file))")) }
        if !r.remoteIP.isEmpty { out.append(ToolLine(text: "Address      \(r.remoteIP)")) }
        if !r.redirect.isEmpty { out.append(ToolLine(text: "→ \(r.redirect)", kind: .warn)) }
        if !r.headers.isEmpty {
            out.append(ToolLine(text: String(localized: "Response headers"), kind: .header))
            for h in r.headers { out.append(ToolLine(text: "\(h.0): \(h.1)", kind: .dim)) }
        }
        return out
    }
}

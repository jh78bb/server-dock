import Foundation

/// Firewall backend: ufw/firewalld support mutations; nftables/iptables are read-only.
enum FirewallBackend: String {
    case ufw, firewalld, nftables, iptables, none
    var title: String {
        switch self {
        case .ufw: return "ufw"; case .firewalld: return "firewalld"; case .nftables: return "nftables"
        case .iptables: return "iptables"; case .none: return String(localized: "None")
        }
    }
    var canEdit: Bool { self == .ufw || self == .firewalld }
}

/// Rule includes display target/action/source/comment and structured editable spec.
struct FWRule: Identifiable, Hashable {
    let id: String
    var number: Int?          // ufw rule number.
    var zone: String?         // firewalld zone.
    var kind: String          // ufw: "rule" / firewalld: "service" · "port" · "rich" · "source"
    var target: String        // Target port/service/app/full rich rule.
    var action: String        // ALLOW IN / DENY IN / accept …
    var source: String        // Source.
    var comment: String
    var isV6: Bool
    var raw: String
    var editable: Bool
    var ufw: UfwSpec?
    var fwd: FirewalldSpec?
}

struct UfwSpec: Hashable {
    var action = "allow"      // allow / deny / reject / limit
    var direction = "in"      // in / out
    var proto = "any"         // any / tcp / udp
    var port = ""             // Port number/range/list/app profile; empty matches all ports.
    var from = ""             // Empty matches any source.
    var comment = ""
}

struct FirewalldSpec: Hashable {
    enum Kind: String { case port, service, rich }
    var kind: Kind = .port
    var zone = ""
    var port = ""
    var proto = "tcp"
    var service = ""
    var source = ""           // Rich-rule source IP/CIDR; empty matches anywhere.
    var action = "accept"     // rich: accept / reject / drop
    var richRaw = ""          // Original parsed rich rule for deletion.
}

struct FirewallState {
    var backend: FirewallBackend = .none
    var installed: Set<String> = []
    var active = false
    var defaults = ""                    // ufw: "deny (incoming), allow (outgoing), disabled (routed)"
    var defaultIncomingDeny = false
    var rules: [FWRule] = []
    var zones: [String] = []
    var rawText = ""                     // Read-only nftables/iptables output.
    var needsRoot = false
    var note = ""
}

enum FirewallScanner {
    static func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }

    // MARK: Reading

    static func readScript(sudo: Bool) -> String {
        """
        export LC_ALL=C
        [ "$(uname -s 2>/dev/null)" = Linux ] || { echo "__NOTLINUX__"; exit 0; }
        S="\(sudo ? "sudo -n" : "")"
        echo "__DETECT__"
        for c in ufw firewall-cmd nft iptables; do command -v $c >/dev/null 2>&1 && echo "$c=yes"; done
        for s in ufw firewalld nftables; do a=$(systemctl is-active $s 2>/dev/null); [ -n "$a" ] && echo "svc:$s=$a"; done
        echo "__UFW__"
        if command -v ufw >/dev/null 2>&1; then $S ufw status numbered 2>&1; echo "__UFWV__"; $S ufw status verbose 2>&1 | grep -i '^default'; fi
        echo "__FWD__"
        if command -v firewall-cmd >/dev/null 2>&1; then
          $S firewall-cmd --state 2>&1
          for z in $($S firewall-cmd --get-active-zones 2>/dev/null | grep -v '^[[:space:]]'); do echo "__ZONE__ $z"; $S firewall-cmd --zone=$z --list-all 2>&1; done
        fi
        echo "__NFT__"
        if command -v nft >/dev/null 2>&1; then $S nft list ruleset 2>&1 | head -300; fi
        echo "__IPT__"
        if command -v iptables >/dev/null 2>&1; then $S iptables -S 2>&1 | head -200; fi
        """
    }

    static func isPermissionError(_ s: String) -> Bool {
        let l = s.lowercased()
        return l.contains("need to be root") || l.contains("permission denied") || l.contains("not permitted") || l.contains("superuser")
            || l.contains("a password is required") || l.contains("you must be root") || l.contains("must be root") || l.contains("authorization failed")
    }

    static func parse(_ out: String) -> (state: FirewallState, notLinux: Bool) {
        var st = FirewallState()
        if out.contains("__NOTLINUX__") { return (st, true) }
        var sections: [String: [String]] = [:]
        var cur = ""
        var zoneLines: [(zone: String, lines: [String])] = []
        for raw in out.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n") {
            if raw.hasPrefix("__ZONE__ ") { cur = "ZONE"; zoneLines.append((String(raw.dropFirst(9)).trimmingCharacters(in: .whitespaces), [])); continue }
            if raw.hasPrefix("__"), raw.hasSuffix("__") { cur = String(raw.dropFirst(2).dropLast(2)); continue }
            if cur == "ZONE" { zoneLines[zoneLines.count - 1].lines.append(raw) } else { sections[cur, default: []].append(raw) }
        }
        var svc: [String: String] = [:]
        for l in sections["DETECT"] ?? [] {
            let t = l.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("svc:") {
                let kv = t.dropFirst(4).split(separator: "=", maxSplits: 1).map(String.init)
                if kv.count == 2 { svc[kv[0]] = kv[1] }
            } else if t.hasSuffix("=yes") { st.installed.insert(String(t.dropLast(4))) }
        }

        // ufw
        let ufwText = (sections["UFW"] ?? []).joined(separator: "\n")
        let ufwActive = ufwText.contains("Status: active")
        let ufwRules = parseUfw(ufwText)
        let defaultLine = (sections["UFWV"] ?? []).first { $0.lowercased().hasPrefix("default:") }?.dropFirst(8).trimmingCharacters(in: .whitespaces) ?? ""

        // firewalld
        let fwdState = (sections["FWD"] ?? []).first?.trimmingCharacters(in: .whitespaces) ?? ""
        let fwdRunning = fwdState == "running"
        var fwdRules: [FWRule] = []
        var zones: [String] = []
        for z in zoneLines {
            zones.append(z.zone)
            fwdRules += parseFirewalldZone(z.zone, z.lines)
        }

        // Prefer an enabled firewall, otherwise an installed one.
        if ufwActive || svc["ufw"] == "active" {
            st.backend = .ufw; st.active = ufwActive
        } else if fwdRunning || svc["firewalld"] == "active" {
            st.backend = .firewalld; st.active = fwdRunning
        } else if st.installed.contains("ufw") {
            st.backend = .ufw; st.active = false
        } else if st.installed.contains("firewall-cmd") {
            st.backend = .firewalld; st.active = false
        } else if st.installed.contains("nft") {
            st.backend = .nftables; st.active = true
        } else if st.installed.contains("iptables") {
            st.backend = .iptables; st.active = true
        }

        switch st.backend {
        case .ufw:
            st.rules = ufwRules
            st.defaults = defaultLine
            st.defaultIncomingDeny = defaultLine.lowercased().contains("deny (incoming)") || defaultLine.lowercased().contains("reject (incoming)")
            st.needsRoot = isPermissionError(ufwText)
        case .firewalld:
            st.rules = fwdRules; st.zones = zones
            st.needsRoot = isPermissionError((sections["FWD"] ?? []).joined(separator: "\n"))
        case .nftables:
            st.rawText = (sections["NFT"] ?? []).joined(separator: "\n"); st.needsRoot = isPermissionError(st.rawText)
        case .iptables:
            st.rawText = (sections["IPT"] ?? []).joined(separator: "\n"); st.needsRoot = isPermissionError(st.rawText)
        case .none: break
        }
        // Show raw nft/iptables reference output even without an editable backend.
        if st.backend.canEdit {
            st.rawText = [(sections["NFT"] ?? []).joined(separator: "\n"), (sections["IPT"] ?? []).joined(separator: "\n")]
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n\n")
        }
        return (st, false)
    }

    // MARK: ufw parsing

    private static let ufwRegex = try! NSRegularExpression(
        pattern: #"^\[\s*(\d+)\]\s+(.+?)\s{2,}(ALLOW|DENY|REJECT|LIMIT)(?:\s+(IN|OUT|FWD))?\s{2,}(.*?)(?:\s+#\s*(.*))?$"#)

    static func parseUfw(_ text: String) -> [FWRule] {
        var out: [FWRule] = []
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            let ns = t as NSString
            guard let m = ufwRegex.firstMatch(in: t, range: NSRange(location: 0, length: ns.length)) else { continue }
            func g(_ i: Int) -> String { m.range(at: i).location == NSNotFound ? "" : ns.substring(with: m.range(at: i)).trimmingCharacters(in: .whitespaces) }
            let number = Int(g(1)) ?? 0
            var to = g(2), action = g(3), dir = g(4), from = g(5)
            let comment = g(6)
            let v6 = to.contains("(v6)")
            to = to.replacingOccurrences(of: " (v6)", with: "")
            from = from.replacingOccurrences(of: " (v6)", with: "")
            if dir.isEmpty { dir = "IN" }
            var rule = FWRule(id: "ufw-\(number)-\(t)", number: number, zone: nil, kind: "rule", target: to, action: "\(action) \(dir)", source: from,
                              comment: comment, isV6: v6, raw: t, editable: false, ufw: nil, fwd: nil)
            if let spec = ufwSpec(to: to, action: action, dir: dir, from: from, comment: comment) { rule.ufw = spec; rule.editable = !v6 }
            out.append(rule)
        }
        return out
    }

    /// Convert ufw To/From to editable specs; complex interface/destination-IP rules return nil and support deletion only.
    static func ufwSpec(to: String, action: String, dir: String, from: String, comment: String) -> UfwSpec? {
        if to.contains(" on ") || from.contains(" on ") || dir == "FWD" { return nil }
        var s = UfwSpec()
        s.action = action.lowercased(); s.direction = dir.lowercased(); s.comment = comment
        s.from = (from == "Anywhere" || from.isEmpty) ? "" : from
        if to == "Anywhere" { s.port = "" }
        else if let slash = to.lastIndex(of: "/"), ["tcp", "udp"].contains(String(to[to.index(after: slash)...])),
                to[..<slash].allSatisfy({ $0.isNumber || ",:".contains($0) }) {
            s.port = String(to[..<slash]); s.proto = String(to[to.index(after: slash)...])
        } else if to.allSatisfy({ $0.isNumber || ",:".contains($0) }) { s.port = to }
        else if to.first?.isLetter == true, !to.contains(" on ") {
            // App profiles such as OpenSSH/Nginx Full; dotted values are IP/hostnames and remain noneditable.
            if to.contains(".") || to.contains(":") { return nil }
            s.port = to
        } else { return nil }
        return s
    }

    // MARK: firewalld parsing

    static func parseFirewalldZone(_ zone: String, _ lines: [String]) -> [FWRule] {
        var out: [FWRule] = []
        var inRich = false
        for raw in lines {
            let line = raw.replacingOccurrences(of: "\t", with: "  ")
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            if inRich, line.hasPrefix("    ") || raw.hasPrefix("\t") {
                out.append(rich(zone, t)); continue
            }
            inRich = false
            guard let colon = t.firstIndex(of: ":") else { continue }
            let key = String(t[..<colon]), val = String(t[t.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            switch key {
            case "services":
                for s in val.split(separator: " ") {
                    let n = String(s)
                    var r = FWRule(id: "fwd-\(zone)-svc-\(n)", number: nil, zone: zone, kind: "service", target: n, action: "accept", source: "", comment: "",
                                   isV6: false, raw: n, editable: true, ufw: nil, fwd: FirewalldSpec(kind: .service, zone: zone, service: n))
                    r.raw = "service \(n)"; out.append(r)
                }
            case "ports":
                for p in val.split(separator: " ") {
                    let s = String(p); let parts = s.split(separator: "/").map(String.init)
                    guard parts.count == 2 else { continue }
                    out.append(FWRule(id: "fwd-\(zone)-port-\(s)", number: nil, zone: zone, kind: "port", target: s, action: "accept", source: "", comment: "",
                                      isV6: false, raw: "port \(s)", editable: true, ufw: nil,
                                      fwd: FirewalldSpec(kind: .port, zone: zone, port: parts[0], proto: parts[1])))
                }
            case "sources":
                for s in val.split(separator: " ") {
                    out.append(FWRule(id: "fwd-\(zone)-src-\(s)", number: nil, zone: zone, kind: "source", target: String(localized: "All traffic from this source"), action: "accept",
                                      source: String(s), comment: "", isV6: false, raw: "source \(s)", editable: false, ufw: nil, fwd: nil))
                }
            case "rich rules": inRich = true
                if !val.isEmpty { out.append(rich(zone, val)) }
            default: break
            }
        }
        return out
    }

    /// Parse a rich rule such as IPv4 source 1.2.3.4, TCP port 22, accept.
    private static func rich(_ zone: String, _ text: String) -> FWRule {
        func attr(_ key: String) -> String? {
            guard let r = text.range(of: "\(key)=\"") else { return nil }
            return String(text[r.upperBound...].prefix { $0 != "\"" })
        }
        let hasDetail = attr("service name") != nil || attr("forward-port") != nil || text.contains("masquerade") || text.contains("icmp-block")
        var action = "accept"
        if text.hasSuffix(" reject") || text.contains(" reject ") { action = "reject" }
        else if text.hasSuffix(" drop") || text.contains(" drop ") { action = "drop" }
        let source = attr("source address") ?? ""
        var target = text
        var spec: FirewalldSpec?
        if let port = attr("port port"), !hasDetail {
            let proto = attr("protocol") ?? "tcp"
            target = "\(port)/\(proto)"
            spec = FirewalldSpec(kind: .rich, zone: zone, port: port, proto: proto, source: source, action: action, richRaw: text)
        }
        return FWRule(id: "fwd-\(zone)-rich-\(text)", number: nil, zone: zone, kind: "rich", target: target, action: action, source: source, comment: "",
                      isV6: attr("family") == "ipv6", raw: text, editable: spec != nil, ufw: nil,
                      fwd: spec ?? FirewalldSpec(kind: .rich, zone: zone, richRaw: text))
    }

    // MARK: Command construction

    static let ipRegex = try! NSRegularExpression(pattern: #"^(\d{1,3}(\.\d{1,3}){3}(/\d{1,2})?|[0-9a-fA-F:]+(/\d{1,3})?)$"#)
    static func validAddress(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return true }
        return ipRegex.firstMatch(in: t, range: NSRange(location: 0, length: (t as NSString).length)) != nil && (t.contains(".") || t.contains(":"))
    }
    static func validPort(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return false }
        return t.allSatisfy { $0.isNumber || ",:-".contains($0) } && t.first?.isNumber == true
    }

    static func ufwProblem(_ s: UfwSpec) -> String? {
        let port = s.port.trimmingCharacters(in: .whitespaces), from = s.from.trimmingCharacters(in: .whitespaces)
        if port.isEmpty && from.isEmpty { return String(localized: "Enter a port, an application profile, or a source address.") }
        if !port.isEmpty, port.first?.isNumber == true {
            if !validPort(port) { return String(localized: "Enter a port like 22, a range like 6000:6007 or a list like 80,443.") }
            if (port.contains(":") || port.contains(",")) && s.proto == "any" { return String(localized: "Ranges and lists need TCP or UDP.") }
        }
        if !port.isEmpty, port.first?.isNumber != true, s.proto != "any" { return String(localized: "Application profiles don't take a protocol.") }
        if !from.isEmpty, !validAddress(from) { return String(localized: "The source must be an IP address or CIDR like 10.0.0.0/24.") }
        if s.comment.contains("\n") { return String(localized: "The comment must be one line.") }
        return nil
    }

    /// Build ufw [insert N] allow|deny|reject|limit in|out; caller adds sudo.
    static func ufwAdd(_ s: UfwSpec, insertAt: Int? = nil) -> String {
        var c = "ufw"
        if let n = insertAt { c += " insert \(n)" }
        c += " \(s.action) \(s.direction)"
        let port = s.port.trimmingCharacters(in: .whitespaces), from = s.from.trimmingCharacters(in: .whitespaces)
        let isApp = !port.isEmpty && port.first?.isNumber != true
        if from.isEmpty {
            if isApp { c += " \(q(port))" }
            else { c += " \(port)" + (s.proto != "any" ? "/\(s.proto)" : "") }
        } else {
            if s.proto != "any", !isApp { c += " proto \(s.proto)" }
            c += " from \(from)"
            if isApp { c += " to any app \(q(port))" }
            else if !port.isEmpty { c += " to any port \(port)" }
        }
        let cm = s.comment.trimmingCharacters(in: .whitespaces)
        if !cm.isEmpty { c += " comment \(q(cm))" }
        return c
    }

    static func firewalldProblem(_ s: FirewalldSpec) -> String? {
        if s.zone.isEmpty { return String(localized: "Choose a zone.") }
        switch s.kind {
        case .port:
            if !validPort(s.port) { return String(localized: "Enter a port like 8080 or a range like 6000-6007.") }
        case .service:
            if s.service.trimmingCharacters(in: .whitespaces).isEmpty || !s.service.allSatisfy({ $0.isLetter || $0.isNumber || "-_".contains($0) }) {
                return String(localized: "Enter a service name like http or ssh.")
            }
        case .rich:
            if !validPort(s.port) { return String(localized: "Enter a port like 8080 or a range like 6000-6007.") }
            if !s.source.isEmpty, !validAddress(s.source) { return String(localized: "The source must be an IP address or CIDR like 10.0.0.0/24.") }
        }
        return nil
    }

    static func richRule(_ s: FirewalldSpec) -> String {
        var r = "rule"
        let src = s.source.trimmingCharacters(in: .whitespaces)
        if !src.isEmpty { r += " family=\"\(src.contains(":") ? "ipv6" : "ipv4")\" source address=\"\(src)\"" }
        r += " port port=\"\(s.port)\" protocol=\"\(s.proto)\" \(s.action)"
        return r
    }

    /// firewalld add command includes permanent configuration and reload.
    static func firewalldAdd(_ s: FirewalldSpec) -> String {
        let z = "--zone=\(q(s.zone))"
        let arg: String
        switch s.kind {
        case .port: arg = "--add-port=\(s.port)/\(s.proto)"
        case .service: arg = "--add-service=\(s.service)"
        case .rich: arg = "--add-rich-rule=\(q(richRule(s)))"
        }
        return "firewall-cmd --permanent \(z) \(arg) && firewall-cmd --reload"
    }

    static func firewalldRemove(_ s: FirewalldSpec) -> String {
        let z = "--zone=\(q(s.zone))"
        let arg: String
        switch s.kind {
        case .port: arg = "--remove-port=\(s.port)/\(s.proto)"
        case .service: arg = "--remove-service=\(s.service)"
        case .rich: arg = "--remove-rich-rule=\(q(s.richRaw.isEmpty ? richRule(s) : s.richRaw))"
        }
        return "firewall-cmd --permanent \(z) \(arg) && firewall-cmd --reload"
    }

    // MARK: Lockout prevention

    /// Whether the rule permits incoming SSH, including all-port allowances.
    static func allowsSSH(_ r: FWRule, sshPort: Int) -> Bool {
        if let u = r.ufw {
            guard ["allow", "limit"].contains(u.action), u.direction == "in" else { return false }
            let port = u.port
            if port.isEmpty { return true }
            if port.first?.isLetter == true { return ["openssh", "ssh"].contains(port.lowercased()) }
            return u.proto != "udp" && portCovers(port, sshPort)
        }
        if r.kind == "service" { return r.target == "ssh" && sshPort == 22 }
        if let f = r.fwd, r.kind == "port" || r.kind == "rich" { return f.action == "accept" && f.proto == "tcp" && portCovers(f.port, sshPort) }
        return r.action.hasPrefix("ALLOW") && r.target == "Anywhere"      // Unparsed complex ufw rule.
    }

    static func portCovers(_ spec: String, _ port: Int) -> Bool {
        for part in spec.split(whereSeparator: { $0 == "," }) {
            let p = String(part)
            if let dash = p.firstIndex(where: { $0 == ":" || $0 == "-" }) {
                if let a = Int(p[..<dash]), let b = Int(p[p.index(after: dash)...]), a <= port, port <= b { return true }
            } else if Int(p) == port { return true }
        }
        return false
    }

    /// Whether an unrestricted-source deny/reject rule blocks SSH or all ports.
    static func ufwBlocksSSH(_ s: UfwSpec, sshPort: Int) -> Bool {
        guard ["deny", "reject"].contains(s.action), s.direction == "in", s.proto != "udp" else { return false }
        let port = s.port.trimmingCharacters(in: .whitespaces)
        let all = port.isEmpty
        let ssh = port.first?.isNumber == true ? portCovers(port, sshPort) : ["openssh", "ssh"].contains(port.lowercased())
        return (all || ssh) && s.from.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

import SwiftUI

/// One listening socket/open port.
struct ListenPort: Identifiable, Hashable {
    let proto: String        // tcp / udp
    let address: String      // 0.0.0.0, 127.0.0.1, [::] …
    let port: Int
    let process: String      // sshd process name, empty without permission.
    var pid: Int? = nil
    var user: String = ""
    var id: String { "\(proto)-\(address)-\(port)" }
    /// Loopback-only listeners are not externally reachable.
    var isPublic: Bool {
        let a = address.lowercased()
        return !(a.hasPrefix("127.") || a == "::1" || a == "[::1]" || a == "localhost")
    }
}

/// Security summary built exclusively through read-only server commands.
struct SecuritySummary {
    var os = ""
    var lastLogins: [String] = []
    var failedLogins24h: Int?           // nil means no readable log or insufficient permissions.
    var ports: [ListenPort] = []
    var firewall: [(name: String, state: String)] = []
    var rootLogin: String?              // PermitRootLogin value; nil uses the default.
    var passwordAuth: String?
    var sshPort: String?
    var extraRootAccounts: [String] = []   // Non-root-named account with UID 0.
    var sessions: [String] = []
    var scannedAt = Date()

    var isLinux: Bool { os == "Linux" }
    var publicPorts: [ListenPort] { ports.filter(\.isPublic) }
    var firewallActive: Bool { firewall.contains { $0.state == "active" } }
}

enum SecurityScanner {
    /// Read-only inspection script uses __NAME__ section markers.
    static let script = """
    export LC_ALL=C
    os=$(uname -s 2>/dev/null); echo "__OS__=$os"
    [ "$os" = Linux ] || exit 0
    echo "__LAST__"; last -n 5 -a -w 2>/dev/null | grep -v '^$' | grep -v 'begins' | head -5
    f=na
    if [ -n "$(journalctl -n 1 -q --no-pager 2>/dev/null)" ]; then
      f=$(journalctl --since "24 hours ago" --no-pager -q 2>/dev/null | grep -Ec "sshd.*(Failed password|Invalid user|authentication failure)")
    elif [ -r /var/log/auth.log ]; then
      f=$(tail -n 50000 /var/log/auth.log 2>/dev/null | grep -Ec "sshd.*(Failed password|Invalid user)")
    elif [ -r /var/log/secure ]; then
      f=$(tail -n 50000 /var/log/secure 2>/dev/null | grep -Ec "sshd.*(Failed password|Invalid user)")
    fi
    echo "__FAILED__=$f"
    echo "__PORTS__"; (ss -H -tulnp 2>/dev/null || ss -H -tuln 2>/dev/null || netstat -tuln 2>/dev/null | tail -n +3)
    echo "__FW__"; for s in ufw firewalld nftables; do a=$(systemctl is-active $s 2>/dev/null); [ -n "$a" ] && echo "$s=$a"; done
    echo "__SSHD__"; for c in /etc/ssh/sshd_config.d/*.conf /etc/ssh/sshd_config; do [ -r "$c" ] && grep -Ei "^[[:space:]]*(PermitRootLogin|PasswordAuthentication|Port)[[:space:]]" "$c"; done 2>/dev/null
    echo "__UID0__"; awk -F: '$3==0 && $1!="root"{print $1}' /etc/passwd 2>/dev/null
    echo "__WHO__"; who 2>/dev/null | head -8
    """

    static func parse(_ out: String) -> SecuritySummary {
        var s = SecuritySummary()
        var section = ""
        var seenSSHD = Set<String>()
        for raw in out.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("__OS__=") { s.os = String(line.dropFirst(7)); continue }
            if line.hasPrefix("__FAILED__=") { s.failedLogins24h = Int(line.dropFirst(11)); continue }
            if line.hasPrefix("__"), line.hasSuffix("__") { section = line; continue }
            guard !line.isEmpty else { continue }
            switch section {
            case "__LAST__": s.lastLogins.append(line)
            case "__PORTS__": if let p = parsePort(line) { s.ports.append(p) }
            case "__FW__":
                let kv = line.split(separator: "=", maxSplits: 1).map(String.init)
                if kv.count == 2 { s.firewall.append((kv[0], kv[1])) }
            case "__SSHD__":
                let p = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                guard p.count >= 2 else { continue }
                let key = p[0].lowercased()
                guard seenSSHD.insert(key).inserted else { continue }   // sshd uses the first matching setting.
                switch key {
                case "permitrootlogin": s.rootLogin = p[1].lowercased()
                case "passwordauthentication": s.passwordAuth = p[1].lowercased()
                case "port": s.sshPort = p[1]
                default: break
                }
            case "__UID0__": s.extraRootAccounts.append(line)
            case "__WHO__": s.sessions.append(line)
            default: break
            }
        }
        // Deduplicate IPv4/IPv6 copies and sort by port.
        var seen = Set<String>()
        s.ports = s.ports.filter { seen.insert("\($0.proto)-\($0.port)-\($0.isPublic)").inserted }.sorted { $0.port < $1.port }
        s.scannedAt = Date()
        return s
    }

    /// Parse protocol/local address/port/process from ss -tulnp or netstat -tuln.
    static func parsePort(_ line: String) -> ListenPort? {
        let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard f.count >= 5, f[0].hasPrefix("tcp") || f[0].hasPrefix("udp") else { return nil }
        let proto = f[0].hasPrefix("tcp") ? "tcp" : "udp"
        let isNetstat = Int(f[1]) != nil          // netstat: Proto Recv-Q Send-Q Local Foreign
        let local = isNetstat ? f[3] : f[4]
        guard let colon = local.lastIndex(of: ":"), let port = Int(local[local.index(after: colon)...]) else { return nil }
        var addr = String(local[..<colon])
        if addr.isEmpty || addr == "*" { addr = "0.0.0.0" }
        var proc = ""
        var pid: Int?
        if let r = line.range(of: "((\"") {
            let rest = line[r.upperBound...]
            proc = String(rest.prefix { $0 != "\"" })
            if let p = rest.range(of: "pid=") { pid = Int(rest[p.upperBound...].prefix { $0.isNumber }) }
        }
        return ListenPort(proto: proto, address: addr, port: port, process: proc, pid: pid)
    }
}

extension AppModel {
    /// Fetch overview security results, reusing five-minute cache unless force=true.
    func scanSecurity(_ host: Host, force: Bool = false) {
        let live = hosts.first(where: { $0.id == host.id }) ?? host
        guard !live.isRDP, !live.isLocal, let ssh = live.ssh, ssh.hasUsableCredentials, !ssh.host.isEmpty else { return }
        if !force, let s = securitySummaries[host.id], Date().timeIntervalSince(s.scannedAt) < 300 { return }
        guard securityScanning.insert(host.id).inserted else { return }
        Task { @MainActor in
            defer { securityScanning.remove(host.id) }
            let r = await RemoteFS(ssh).run(SecurityScanner.script, timeout: 40)
            guard r.code == 0 else { return }   // Retain previous results on connection failure.
            securitySummaries[host.id] = SecurityScanner.parse(String(decoding: r.data, as: UTF8.self))
        }
    }
}

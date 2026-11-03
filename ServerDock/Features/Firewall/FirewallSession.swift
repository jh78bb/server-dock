import Foundation
import SwiftUI

/// All remote firewall commands live here; reread before mutation to detect stale UI/server state.
@MainActor
final class FirewallSession: ObservableObject {
    enum Phase: Equatable { case loading, ready, notLinux, failed(String) }

    let host: Host
    private let fs: RemoteFS
    @Published private(set) var phase: Phase = .loading
    @Published private(set) var state = FirewallState()
    @Published private(set) var busy = false
    @Published var notice: String?              // Failure output.
    @Published var info: String?                // Success output.
    @Published private(set) var scannedAt = Date()
    @Published var useSudo: Bool { didSet { UserDefaults.standard.set(useSudo, forKey: "firewallSudo." + host.id) } }

    init(host: Host) {
        self.host = host
        fs = RemoteFS(host.ssh ?? SSHConnection())
        useSudo = UserDefaults.standard.bool(forKey: "firewallSudo." + host.id)
    }

    /// Current SSH port for lockout checks.
    var sshPort: Int { host.ssh?.port ?? 22 }

    func refresh() { Task { await load() } }

    @discardableResult
    func load() async -> Bool {
        let r = await fs.run(FirewallScanner.readScript(sudo: useSudo), timeout: 40)
        if r.code == -1 { phase = .failed(String(decoding: r.stderr, as: UTF8.self)); return false }
        let parsed = FirewallScanner.parse(String(decoding: r.data, as: UTF8.self))
        if parsed.notLinux { phase = .notLinux; return false }
        state = parsed.state
        scannedAt = Date()
        phase = .ready
        return true
    }

    // MARK: Lockout prevention

    /// Deletion is risky if default policy blocks and no remaining rule permits SSH.
    func riskOfDeleting(_ rules: [FWRule]) -> String? {
        guard state.active, state.backend.canEdit else { return nil }
        let removed = Set(rules.map(\.id))
        let removedAllowedSSH = rules.contains { FirewallScanner.allowsSSH($0, sshPort: sshPort) }
        guard removedAllowedSSH else { return nil }
        let remaining = state.rules.filter { !removed.contains($0.id) }
        if remaining.contains(where: { FirewallScanner.allowsSSH($0, sshPort: sshPort) }) { return nil }
        if state.backend == .ufw && !state.defaultIncomingDeny { return nil }
        return String(localized: "This removes the only rule that allows SSH (port \(sshPort)). Once applied, new SSH connections — including this app's — may be refused. Only continue if you can still reach the server another way (console, VNC, provider panel).")
    }

    func riskOfAdding(_ spec: UfwSpec) -> String? {
        guard state.active, FirewallScanner.ufwBlocksSSH(spec, sshPort: sshPort) else { return nil }
        return String(localized: "This rule blocks incoming connections on SSH port \(sshPort) from everywhere. Once applied, new SSH connections — including this app's — may be refused.")
    }

    func riskOfEnabling() -> String? {
        if state.backend == .ufw, !state.rules.contains(where: { FirewallScanner.allowsSSH($0, sshPort: sshPort) }) {
            return String(localized: "No rule allows SSH (port \(sshPort)) yet. With ufw enabled and incoming traffic denied by default, you would be locked out. Allow SSH first (the “Allow SSH and Enable” option does both).")
        }
        return nil
    }

    // MARK: Execution

    private func sudo(_ cmd: String) -> String { "$S " + cmd.replacingOccurrences(of: " && ", with: " && $S ") }

    private func script(_ lines: [String]) -> String {
        "export LC_ALL=C; S=\"\(useSudo ? "sudo -n" : "")\"; { " + lines.joined(separator: "; ") + "; } 2>&1"
    }

    /// Run, report results, reread rules, and return success.
    @discardableResult
    func execute(_ lines: [String]) async -> Bool {
        busy = true
        defer { busy = false }
        notice = nil; info = nil
        let r = await fs.run(script(lines), timeout: 60)
        let out = (String(decoding: r.data, as: UTF8.self) + String(decoding: r.stderr, as: UTF8.self)).trimmingCharacters(in: .whitespacesAndNewlines)
        if r.code != 0 {
            var text = out
            if !useSudo, FirewallScanner.isPermissionError(out) || out.isEmpty {
                text += "\n\n" + String(localized: "Changing the firewall needs root. Turn on the sudo option above if this account has passwordless sudo.")
            }
            notice = text.isEmpty ? String(localized: "The command failed.") : text
        } else if !out.isEmpty {
            info = out
        }
        await load()
        return r.code == 0
    }

    func addUfw(_ spec: UfwSpec, insertAt: Int?) async {
        await execute([sudo(FirewallScanner.ufwAdd(spec, insertAt: insertAt))])
    }

    /// Reread/check identity before deletion; abort external changes to avoid deleting shifted rule numbers.
    func delete(_ rules: [FWRule]) async {
        guard await load() else { return }
        let current = Set(state.rules.map(\.id))
        guard rules.allSatisfy({ current.contains($0.id) }) else {
            notice = String(localized: "The rules changed on the server since this list was loaded. The list was refreshed — review it and try again.")
            return
        }
        var lines: [String] = []
        switch state.backend {
        case .ufw:
            // Delete highest rule numbers first to prevent shifting.
            for r in rules.sorted(by: { ($0.number ?? 0) > ($1.number ?? 0) }) { if let n = r.number { lines.append(sudo("ufw --force delete \(n)")) } }
        case .firewalld:
            for r in rules { if let f = r.fwd { lines.append(sudo(FirewallScanner.firewalldRemove(f))) } }
        default: return
        }
        guard !lines.isEmpty else { return }
        await execute([lines.joined(separator: " && ")])
    }

    /// ufw edit replaces the rule/IPv6 counterpart at the same position; restore old rules if insertion fails.
    func editUfw(_ rule: FWRule, to spec: UfwSpec) async {
        guard let old = rule.ufw, let n = rule.number else { return }
        guard await load(), state.rules.contains(where: { $0.id == rule.id }) else {
            notice = String(localized: "The rules changed on the server since this list was loaded. The list was refreshed — review it and try again.")
            return
        }
        var numbers = [n]
        if let twin = state.rules.first(where: { $0.isV6 && $0.target == rule.target && $0.action == rule.action && $0.comment == rule.comment }),
           let tn = twin.number { numbers.append(tn) }
        let first = numbers.min() ?? n
        let dels = numbers.sorted(by: >).map { sudo("ufw --force delete \($0)") }.joined(separator: " && ")
        let line = "\(dels) && { \(sudo(FirewallScanner.ufwAdd(spec, insertAt: first))) || \(sudo(FirewallScanner.ufwAdd(old, insertAt: first))); }"
        await execute([line])
    }

    func addFirewalld(_ spec: FirewalldSpec) async { await execute([sudo(FirewallScanner.firewalldAdd(spec))]) }

    func editFirewalld(_ rule: FWRule, to spec: FirewalldSpec) async {
        guard let old = rule.fwd else { return }
        guard await load(), state.rules.contains(where: { $0.id == rule.id }) else {
            notice = String(localized: "The rules changed on the server since this list was loaded. The list was refreshed — review it and try again.")
            return
        }
        let line = "\(sudo(FirewallScanner.firewalldRemove(old))) && { \(sudo(FirewallScanner.firewalldAdd(spec))) || \(sudo(FirewallScanner.firewalldAdd(old))); }"
        await execute([line])
    }

    func setUfwEnabled(_ on: Bool, allowSSHFirst: Bool = false) async {
        var lines: [String] = []
        if on && allowSSHFirst { lines.append(sudo("ufw allow \(sshPort)/tcp comment 'SSH'")) }
        lines.append(sudo(on ? "ufw --force enable" : "ufw disable"))
        await execute([lines.joined(separator: " && ")])
    }

    func setUfwDefault(incoming policy: String) async {
        await execute([sudo("ufw default \(policy) incoming")])
    }
}

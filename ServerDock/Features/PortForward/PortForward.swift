import Foundation

/// Port-forwarding type corresponding to OpenSSH -L / -R / -D.
enum ForwardKind: String, Codable, CaseIterable {
    case local, remote, dynamic

    var title: String {
        switch self {
        case .local:   return String(localized: "Local")
        case .remote:  return String(localized: "Remote")
        case .dynamic: return String(localized: "Dynamic")
        }
    }

    /// Explain below the form field that the target address resolves relative to the opposite SSH endpoint, a common source of confusion.
    var hint: String {
        switch self {
        case .local:
            return String(localized: "Open a listening port on this Mac; incoming traffic is tunneled to a target resolved by the server, so localhost means the server itself (reach a remote service bound only to its private network).")
        case .remote:
            return String(localized: "Open a listening port on the server; incoming traffic is tunneled to a target reachable from this Mac (exposes a local service to the server side).")
        case .dynamic:
            return String(localized: "Open a SOCKS5 proxy port on this Mac; apps that use it route traffic out through the server (no target needed).")
        }
    }
}

/// A persisted port-forwarding rule bound to a host, excluding runtime state.
struct ForwardRule: Identifiable, Codable, Hashable {
    var id = UUID()
    var hostId: String
    var name: String = ""
    var kind: ForwardKind = .local
    var bindAddress: String = "127.0.0.1"   // Listener bind address: 127.0.0.1 for local-only access, 0.0.0.0 to expose it to the LAN.
    var listenPort: Int = 0                  // Listening port.
    var destHost: String = "localhost"       // Target host, unused for dynamic forwarding.
    var destPort: Int = 0                    // Target port, unused for dynamic forwarding.

    /// Decode missing fields with defaults so older forwards.json files still load.
    enum CodingKeys: String, CodingKey {
        case id, hostId, name, kind, bindAddress, listenPort, destHost, destPort
    }
    init(id: UUID = UUID(), hostId: String, name: String = "", kind: ForwardKind = .local,
         bindAddress: String = "127.0.0.1", listenPort: Int = 0,
         destHost: String = "localhost", destPort: Int = 0) {
        self.id = id; self.hostId = hostId; self.name = name; self.kind = kind
        self.bindAddress = bindAddress; self.listenPort = listenPort
        self.destHost = destHost; self.destPort = destPort
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        hostId = try c.decodeIfPresent(String.self, forKey: .hostId) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        kind = try c.decodeIfPresent(ForwardKind.self, forKey: .kind) ?? .local
        bindAddress = try c.decodeIfPresent(String.self, forKey: .bindAddress) ?? "127.0.0.1"
        listenPort = try c.decodeIfPresent(Int.self, forKey: .listenPort) ?? 0
        destHost = try c.decodeIfPresent(String.self, forKey: .destHost) ?? "localhost"
        destPort = try c.decodeIfPresent(Int.self, forKey: .destPort) ?? 0
    }

    /// Source-to-destination summary shown in the list.
    var summary: String {
        let bind = bindAddress.isEmpty ? "127.0.0.1" : bindAddress
        switch kind {
        case .local:   return "\(bind):\(listenPort) → \(destHost):\(destPort)"
        case .remote:  return "\(bind):\(listenPort) ← \(destHost):\(destPort)"
        case .dynamic: return "SOCKS5 \(bind):\(listenPort)"
        }
    }

    /// Require a valid listener port; local/remote forwarding also requires a valid target host and port.
    var validationError: String? {
        guard (1...65535).contains(listenPort) else { return String(localized: "Listen port must be between 1 and 65535") }
        if kind != .dynamic {
            if destHost.trimmingCharacters(in: .whitespaces).isEmpty { return String(localized: "Enter a target host") }
            guard (1...65535).contains(destPort) else { return String(localized: "Target port must be between 1 and 65535") }
        }
        return nil
    }
}

/// Process-wide registry of live libssh2 tunnel close actions, used on app exit to release server-side -R listeners gracefully.
/// Lock-protected and safe on any thread, including synchronous exit callbacks; avoids MainActor isolation and macOS-14-only assumeIsolated.
/// In-process libssh2 threads/sockets are reclaimed on process termination; this registry primarily provides graceful cleanup.
final class ForwardProcessRegistry: @unchecked Sendable {
    static let shared = ForwardProcessRegistry()
    private let lock = NSLock()
    private var items: [Int: () -> Void] = [:]
    private var nextId = 0

    /// Register a close action and return its handle.
    func register(_ close: @escaping () -> Void) -> Int {
        lock.lock(); defer { lock.unlock() }
        let id = nextId; nextId += 1; items[id] = close; return id
    }
    func unregister(_ id: Int) { lock.lock(); items[id] = nil; lock.unlock() }
    func terminateAll() {
        lock.lock(); let all = Array(items.values); items.removeAll(); lock.unlock()
        for close in all { close() }
    }
}

/// Per-host forwarding runtime manager; each started rule corresponds to an ssh -N subprocess.
/// Reuse existing SSH credentials and askpass without server installation; process exit indicates forwarding failure/disconnection.
@MainActor
final class ForwardManager: ObservableObject {
    enum RuleStatus: Equatable {
        case stopped, starting, active, failed(String)

        var isRunning: Bool {
            switch self { case .starting, .active: return true; default: return false }
        }
    }

    private var ssh: SSHConnection
    @Published private(set) var statuses: [UUID: RuleStatus] = [:]
    // Each migrated tunnel uses a dedicated libssh2 session and a C-layer pump (ServerDockSSHForward*).
    private var sessions: [UUID: SSHSession] = [:]
    private var forwards: [UUID: OpaquePointer] = [:]        // ServerDockSSHForward*
    private var boxes: [UUID: UnsafeMutableRawPointer] = [:] // on_state callback context, carrying StateBox through Unmanaged.
    private var regIds: [UUID: Int] = [:]                    // Exit-registry handle.

    // Watchdog state: intended tracks rules the user wants running; startedRules retains their configurations for restarts.
    // failCount controls backoff; restartWork deduplicates scheduled restarts.
    private var intended: Set<UUID> = []
    private var startedRules: [UUID: ForwardRule] = [:]
    private var failCount: [UUID: Int] = [:]
    private var restartWork: [UUID: DispatchWorkItem] = [:]

    // Restart backoff is base * 2^failureCount, capped at cap. Do not restart offline; the network-recovery callback restarts tunnels.
    private static let backoffBase: TimeInterval = 2
    private static let backoffCap: TimeInterval = 30
    // Fatal failures require configuration fixes or a free port; the watchdog must not retry. Initial entries match the C engine's English errors.
    private static let fatalSubstrings = ["already in use", "Authentication failed", "HOSTKEY_MISMATCH",
                                          "request rejected", String(localized: "Host not configured")]

    /// Context for asynchronous on_state(ok=0) disconnection callbacks.
    private final class StateBox {
        let cb: (String) -> Void
        init(_ cb: @escaping (String) -> Void) { self.cb = cb }
    }

    init(ssh: SSHConnection) { self.ssh = ssh }

    func status(_ id: UUID) -> RuleStatus { statuses[id] ?? .stopped }

    /// Whether a tunnel has a fatal failure (port conflict/authentication/forwarding denied) with retries disabled; used for the red menu-bar indicator.
    /// Count only non-retrying failures, excluding transient .failed states during reconnection backoff to avoid flashing red.
    var hasFatalFailure: Bool {
        statuses.contains { id, status in
            if case .failed = status { return !intended.contains(id) }
            return false
        }
    }

    /// Whether any tunnel is intended to run, determining whether the watchdog needs to tick.
    var hasIntended: Bool { !intended.isEmpty }

    /// Explicit start: mark intended, reset backoff, then launch.
    func start(_ rule: ForwardRule, ssh: SSHConnection? = nil) {
        if let ssh { self.ssh = ssh }
        intended.insert(rule.id)
        startedRules[rule.id] = rule
        failCount[rule.id] = 0
        restartWork[rule.id]?.cancel(); restartWork[rule.id] = nil
        launch(rule)
    }

    /// Shared launch path for explicit starts/restarts; preserve intended/backoff, create a dedicated session in the background, and start C forwarding.
    private func launch(_ rule: ForwardRule) {
        guard forwards[rule.id] == nil, sessions[rule.id] == nil else { return }
        guard NetworkMonitor.shared.isOnline else { statuses[rule.id] = .failed(String(localized: "Waiting for Network")); return }
        guard !ssh.host.isEmpty else { statuses[rule.id] = .failed(String(localized: "Host not configured")); return }

        statuses[rule.id] = .starting
        let conn = ssh
        let id = rule.id
        let kind: Int32 = rule.kind == .local ? 0 : (rule.kind == .remote ? 1 : 2)
        let (bind, lport, dhost, dport) = (rule.bindAddress, rule.listenPort, rule.destHost, rule.destPort)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let a = conn.libssh2Auth
            let session: SSHSession
            do {
                session = try SSHSession.connect(host: conn.host, port: conn.port, user: conn.user,
                                                 password: a.password, keyPath: a.keyPath, keyPassphrase: a.keyPassphrase,
                                                 jump: conn.jumpHost)
            } catch {
                let msg = (error as? SSHSession.SSHError)?.message ?? String(localized: "Connection Failed")
                Task { @MainActor in self?.onFailure(id, reason: msg) }
                return
            }
            guard let raw = session.rawHandle else {
                session.close()
                Task { @MainActor in self?.onFailure(id, reason: String(localized: "Connection Failed")) }
                return
            }
            let box = Unmanaged.passRetained(StateBox { msg in
                Task { @MainActor in self?.onDropped(id, reason: msg) }
            }).toOpaque()
            var err = [CChar](repeating: 0, count: 256)
            guard let fwd = serverdock_ssh_forward_open(raw, kind, bind, Int32(lport), dhost, Int32(dport),
                                                   { ud, ok, msg in
                                                       guard let ud, ok == 0 else { return }
                                                       Unmanaged<StateBox>.fromOpaque(ud).takeUnretainedValue()
                                                           .cb(msg.map { String(cString: $0) } ?? String(localized: "Disconnected"))
                                                   }, box, &err, 256) else {
                Unmanaged<StateBox>.fromOpaque(box).release()
                session.close()
                let reason = String(cString: err)
                Task { @MainActor in self?.onFailure(id, reason: reason) }
                return
            }
            Task { @MainActor in self?.onEstablished(id, session: session, forward: fwd, box: box) }
        }
    }

    /// After background setup succeeds, register and mark active; immediately tear down if stopped meanwhile.
    private func onEstablished(_ id: UUID, session: SSHSession, forward: OpaquePointer, box: UnsafeMutableRawPointer) {
        guard intended.contains(id) else {
            serverdock_ssh_forward_close(forward); session.close()
            Unmanaged<StateBox>.fromOpaque(box).release()
            return
        }
        sessions[id] = session
        forwards[id] = forward
        boxes[id] = box
        regIds[id] = ForwardProcessRegistry.shared.register {
            serverdock_ssh_forward_close(forward); session.close()
        }
        statuses[id] = .active
        failCount[id] = 0
    }

    /// On connection/authentication/listen failure, mark failed. Do not retry fatal errors; back off and restart transient ones.
    private func onFailure(_ id: UUID, reason: String) {
        statuses[id] = .failed(reason)
        guard intended.contains(id) else { return }
        if Self.fatalSubstrings.contains(where: { reason.contains($0) }) {
            intended.remove(id); failCount[id] = nil
            restartWork[id]?.cancel(); restartWork[id] = nil
        } else {
            scheduleRestart(id)
        }
    }

    /// On asynchronous C on_state disconnection, tear down and restart as a transient failure.
    private func onDropped(_ id: UUID, reason: String) {
        guard sessions[id] != nil else { return }   // Ignore callbacks after stop/teardown.
        teardown(id)
        statuses[id] = .failed(reason.isEmpty ? String(localized: "Disconnected") : reason)
        guard intended.contains(id) else { return }
        scheduleRestart(id)
    }

    /// Close forwarding/session and unregister without changing intended/backoff; shared by stop and network reconnect.
    private func teardown(_ id: UUID) {
        if let regId = regIds[id] { ForwardProcessRegistry.shared.unregister(regId); regIds[id] = nil }
        if let fwd = forwards[id] { serverdock_ssh_forward_close(fwd); forwards[id] = nil }   // After stopping and joining the pump, no callbacks remain.
        if let box = boxes[id] { Unmanaged<StateBox>.fromOpaque(box).release(); boxes[id] = nil }
        if let s = sessions[id] { s.close(); sessions[id] = nil }
    }

    /// Explicit stop: clear intended, backoff, and pending restart, then terminate.
    func stop(_ id: UUID) {
        intended.remove(id)
        failCount[id] = nil
        restartWork[id]?.cancel(); restartWork[id] = nil
        teardown(id)
        statuses[id] = .stopped
    }

    func stopAll() { for id in Set(forwards.keys).union(intended) { stop(id) } }

    /// On network loss cancel pending restarts; on recovery reset backoff and immediately reconnect all intended tunnels.
    func handleNetworkChange() {
        if !NetworkMonitor.shared.isOnline {
            for (_, w) in restartWork { w.cancel() }
            restartWork.removeAll()
            return
        }
        for id in intended {
            guard let rule = startedRules[id] else { continue }
            restartWork[id]?.cancel(); restartWork[id] = nil
            failCount[id] = 0
            teardown(id)            // Discard and reconnect the old session invalidated by the network change.
            launch(rule)
        }
    }

    /// Periodic watchdog: while online, schedule a restart for intended disconnected tunnels with no pending restart.
    /// Catches missed process-exit signals. Skip offline and let network recovery handle reconnection.
    func watchdogTick() {
        guard NetworkMonitor.shared.isOnline else { return }
        for id in intended where !status(id).isRunning && restartWork[id] == nil {
            scheduleRestart(id)
        }
    }

    /// Schedule a deduplicated backoff restart for an intended tunnel; do not schedule offline.
    private func scheduleRestart(_ id: UUID) {
        guard intended.contains(id), restartWork[id] == nil else { return }
        guard NetworkMonitor.shared.isOnline, startedRules[id] != nil else { return }
        let n = failCount[id] ?? 0
        let delay = min(Self.backoffBase * pow(2, Double(n)), Self.backoffCap)
        failCount[id] = n + 1
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.restartWork[id] = nil
            guard self.intended.contains(id), NetworkMonitor.shared.isOnline,
                  !self.status(id).isRunning, let rule = self.startedRules[id] else { return }
            self.launch(rule)
        }
        restartWork[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

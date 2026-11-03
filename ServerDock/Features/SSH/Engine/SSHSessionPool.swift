import Foundation

// MARK: - Derive libssh2 authentication parameters

extension SSHConnection {
    /// Map connection settings to libssh2 authentication parameters, resolving keys consistently with sshArguments:
    /// Key login materializes a library keyId or uses keyPath; password supplies its passphrase.
    /// Password/ask mode uses the saved or session-entered password for password authentication.
    var libssh2Auth: (password: String?, keyPath: String?, keyPassphrase: String?) {
        if authMethod == .key {
            let path = keyId.isEmpty ? keyPath : (KeyMaterializer.path(forKeyId: keyId) ?? keyPath)
            return (nil, path.isEmpty ? nil : path, password.isEmpty ? nil : password)
        }
        if authMethod == .agent {
            // C engine recognizes agent: and uses libssh2 agent auth; suffix is the socket or SSH_AUTH_SOCK if empty.
            return (nil, "agent:" + (resolvedAgentSocket ?? ""), nil)
        }
        return (password.isEmpty ? nil : password, nil, nil)
    }
}

// MARK: - Process-wide per-host session pool

/// Process-wide per-host libssh2 session pool replacing OpenSSH ControlMaster.
///
/// Design:
/// Short operations use withSession: borrow a warm host connection, then return it. Authenticate only when initially connecting;
/// later operations reuse warm sessions. Concurrent operations borrow different connections instead of serializing on one session.
/// Long-running/streaming PTY, upload/download, monitoring, and extraction operations use dedicated connections,
/// closed after use. Never block pooled sessions with these operations; otherwise extraction would prevent browsing.
/// SSHSession remains non-thread-safe, but the pool grants one borrower exclusive ownership at a time.
///
/// This provides concurrency for RemoteFS and terminal migration away from /usr/bin/ssh.
final class SSHSessionPool {
    static let shared = SSHSessionPool()
    private init() {}

    /// Pool key matches ControlMaster %C semantics: operations sharing host:port:user reuse warm connections.
    private struct Key: Hashable { let host: String; let port: Int; let user: String }

    private struct Pooled { let session: SSHSession; let idleSince: Date }

    private var idle: [Key: [Pooled]] = [:]
    private let lock = NSLock()
    /// Maximum idle warm connections per host; close extras when returned to prevent accumulation.
    private let maxIdlePerHost = 4
    /// Discard/reconnect sessions idle longer than this threshold because the server may have closed them; more conservative than the former 120s ControlPersist.
    private let idleTTL: TimeInterval = 90

    private func key(_ c: SSHConnection) -> Key { Key(host: c.host, port: c.port, user: c.user) }

    /// Borrow for a short operation and recycle after body returns. If body throws, discard the possibly disconnected session rather than polluting the pool.
    /// body runs synchronously and blocks the caller. SSHSession.exec internally serializes operations safely across threads;
    /// always call from a background thread.
    func withSession<T>(_ c: SSHConnection, _ body: (SSHSession) throws -> T) throws -> T {
        let s = try borrow(c)
        do {
            let r = try body(s)
            giveBack(c, s)
            return r
        } catch {
            s.close()
            throw error
        }
    }

    /// Explicit borrow/return lets callers such as RemoteFS.run decide whether to recycle or discard. Canceled/timed-out sessions must be discarded,
    /// because their cancel flag is set and channel state may be dirty. Borrow, run, then recycle on success or discard on failure/cancel.
    func take(_ c: SSHConnection) throws -> SSHSession { try borrow(c) }
    func recycle(_ c: SSHConnection, _ s: SSHSession) { giveBack(c, s) }
    func discard(_ s: SSHSession) { s.close() }

    /// Create an exclusive non-pooled connection for long-running/streaming work; the caller must close().
    func dedicated(_ c: SSHConnection) throws -> SSHSession { try connect(c) }

    /// Close all warm connections for a host when no tabs/views remain, replacing ssh -O exit.
    func closeHost(_ c: SSHConnection) {
        lock.lock(); let list = idle.removeValue(forKey: key(c)) ?? []; lock.unlock()
        for p in list { p.session.close() }
    }

    /// Close every host's warm connections on exit/global reset.
    func closeAll() {
        lock.lock(); let all = idle.values.flatMap { $0 }; idle.removeAll(); lock.unlock()
        for p in all { p.session.close() }
    }

    // MARK: - Internals

    private func borrow(_ c: SSHConnection) throws -> SSHSession {
        let k = key(c)
        let now = Date()
        while true {
            lock.lock()
            guard var list = idle[k], let p = list.popLast() else { lock.unlock(); break }
            idle[k] = list
            lock.unlock()
            if now.timeIntervalSince(p.idleSince) < idleTTL {
                return p.session            // Reuse the warm connection directly.
            }
            p.session.close()               // Too old or possibly disconnected: close and try the next session.
        }
        return try connect(c)               // Create a connection when the pool is empty.
    }

    private func giveBack(_ c: SSHConnection, _ s: SSHSession) {
        let k = key(c)
        lock.lock()
        var list = idle[k] ?? []
        if list.count < maxIdlePerHost {
            list.append(Pooled(session: s, idleSince: Date()))
            idle[k] = list
            lock.unlock()
        } else {
            lock.unlock()
            s.close()                       // Close extra connections when the pool is full.
        }
    }

    private func connect(_ c: SSHConnection) throws -> SSHSession {
        let a = c.libssh2Auth
        return try SSHSession.connect(host: c.host, port: c.port, user: c.user,
                                      password: a.password, keyPath: a.keyPath, keyPassphrase: a.keyPassphrase,
                                      jump: c.jumpHost.trimmingCharacters(in: .whitespaces))
    }
}

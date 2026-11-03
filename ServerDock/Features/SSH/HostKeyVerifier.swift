import Foundation

/// Host-key fingerprint information for first-connection verification.
struct HostKeyInfo {
    let host: String
    let port: Int
    let keyLine: String   // known_hosts trust line: "<host|[host]:port> <keytype> <base64key>".
    let sha256: String
    let md5: String
    var changed = false    // true means a changed recorded key/possible MITM; warn prominently.
}

enum HostKeyDecision { case cancel, once, save }

/// libssh2 host-key verification replacing ssh-keyscan/ssh-keygen subprocesses.
/// Use persistent and temporary-session known_hosts files. Save permanent trust to the real file; accept-once trust expires on restart.
/// SSHSession.connect enforces MITM checks through serverdock_ssh_open before authentication, rejecting mismatches.
/// This class handles interactive pre-connection confirmation for unknown/changed keys.
enum HostKeyVerifier {
    enum Preflight { case known, prompt(HostKeyInfo), changed(HostKeyInfo), scanFailed }

    static var realKnownHosts: String { NSHomeDirectory() + "/.ssh/known_hosts" }
    static var sessionKnownHosts: String { NSHomeDirectory() + "/.serverdock/session_known_hosts" }

    /// Space-separated UserKnownHostsFile paths for the ssh subprocess paths not yet migrated.
    static func userKnownHostsArg() -> String { "\(realKnownHosts) \(sessionKnownHosts)" }

    /// Clear temporary trust at startup so accept-once hosts require verification after restart.
    static func resetSession() {
        ensureParentDir(sessionKnownHosts)
        try? Data().write(to: URL(fileURLWithPath: sessionKnownHosts))
    }

    /// Blocking preflight, preferably in the background: handshake to obtain the host key and compare known_hosts without authentication/password transmission.
    static func preflight(host: String, port: Int) -> Preflight {
        var scan = ServerDockHostKeyScan()
        serverdock_ssh_scan_hostkey(host, Int32(port), realKnownHosts, sessionKnownHosts, &scan)
        switch scan.status {
        case 0:  return .known
        case 1:  return info(host, port, scan).map { .prompt($0) } ?? .scanFailed
        case 2:  return info(host, port, scan).map { var i = $0; i.changed = true; return .changed(i) } ?? .scanFailed
        default: return .scanFailed   // -1 denotes connection/handshake failure; let the actual connection report the error.
        }
    }

    /// Append one trust line without rewriting the user's file: persist=true uses real known_hosts, false uses the temporary session file.
    static func trust(_ info: HostKeyInfo, persist: Bool) {
        let file = persist ? realKnownHosts : sessionKnownHosts
        ensureParentDir(file)
        let line = info.keyLine.hasSuffix("\n") ? info.keyLine : info.keyLine + "\n"
        if let fh = FileHandle(forWritingAtPath: file) {
            fh.seekToEndOfFile(); fh.write(Data(line.utf8)); try? fh.close()
        } else {
            try? line.write(toFile: file, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Internals

    private static func info(_ host: String, _ port: Int, _ scan: ServerDockHostKeyScan) -> HostKeyInfo? {
        let line = cstr(scan.line)
        guard !line.isEmpty else { return nil }
        return HostKeyInfo(host: host, port: port, keyLine: line,
                           sha256: cstr(scan.sha256), md5: cstr(scan.md5))
    }

    /// Convert a fixed C char array imported as a Swift tuple to String.
    private static func cstr<T>(_ tuple: T) -> String {
        var t = tuple
        return withUnsafeBytes(of: &t) { raw in
            String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
    }

    private static func ensureParentDir(_ path: String) {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
}

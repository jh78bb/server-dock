import Foundation

/// An authenticated in-process libssh2 connection supporting repeated exec calls, with later SFTP/PTY/forwarding extensions.
/// libssh2 sessions are not thread-safe; serialize every native-handle operation on this class's serial queue.
/// connect/exec are synchronous and block the caller; use a background queue.
final class SSHSession: @unchecked Sendable {
    struct SSHError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
        /// A known-host-key mismatch, possibly MITM; distinguish this from ordinary connection failures in the UI.
        var isHostKeyMismatch: Bool { message.hasPrefix("HOSTKEY_MISMATCH") }
    }
    struct ExecResult { let output: String; let stderr: String; let exitCode: Int }
    /// Binary-safe RemoteFS.run exec result: raw stdout/stderr bytes and timedOut/cancelled flags for abnormal termination.
    struct ExecBytes { let stdout: Data; let stderr: Data; let exitCode: Int32; let timedOut: Bool; let cancelled: Bool }

    private var handle: OpaquePointer?          // ServerDockSSHSession*
    private let queue: DispatchQueue
    let fingerprintSHA256: String
    let fingerprintMD5: String

    private init(handle: OpaquePointer, queue: DispatchQueue) {
        self.handle = handle
        self.queue = queue
        self.fingerprintSHA256 = String(cString: serverdock_ssh_session_sha256(handle))
        self.fingerprintMD5 = String(cString: serverdock_ssh_session_md5(handle))
    }

    /// Connect, handshake, and authenticate synchronously on a background thread. A nonempty keyPath selects public-key authentication.
    /// Check known_hosts after handshake and before authentication. Reject only explicit mismatches; permit unknown hosts.
    static func connect(host: String, port: Int, user: String,
                        password: String?, keyPath: String?, keyPassphrase: String?,
                        jump: String = "") throws -> SSHSession {
        var err = [CChar](repeating: 0, count: 256)
        let real = HostKeyVerifier.realKnownHosts
        let session = HostKeyVerifier.sessionKnownHosts
        guard let h = serverdock_ssh_open(host, Int32(port), user, password, keyPath, keyPassphrase,
                                     real, session, jump, &err, 256) else {
            throw SSHError(message: String(cString: err))
        }
        return SSHSession(handle: h, queue: DispatchQueue(label: "serverdock.ssh.\(host):\(port)"))
    }

    /// Execute a command and return stdout, stderr, and exit code.
    func exec(_ command: String, outCap: Int = 1 << 18, errCap: Int = 8192) throws -> ExecResult {
        try queue.sync {
            guard let h = handle else { throw SSHError(message: String(localized: "Session closed")) }
            var out = [CChar](repeating: 0, count: outCap)
            var errout = [CChar](repeating: 0, count: errCap)
            var exitCode: Int32 = 0
            var err = [CChar](repeating: 0, count: 256)
            let rc = serverdock_ssh_exec(h, command, &out, Int32(outCap), &errout, Int32(errCap), &exitCode, &err, 256)
            if rc != 0 { throw SSHError(message: String(cString: err)) }
            return ExecResult(output: String(cString: out), stderr: String(cString: errout), exitCode: Int(exitCode))
        }
    }

    /// Binary-safe exec with stdin, overall timeout, and cancellation for RemoteFS.run; blocks synchronously and must run in the background.
    /// Timeout/cancellation returns timedOut/cancelled instead of throwing; channel errors throw SSHError.
    func execBytes(_ command: String, stdin: Data? = nil, timeout: Double,
                   outCap: Int = 1 << 20, errCap: Int = 1 << 16) throws -> ExecBytes {
        try queue.sync {
            guard let h = handle else { throw SSHError(message: String(localized: "Session closed")) }
            var out = [CChar](repeating: 0, count: outCap)
            var errb = [CChar](repeating: 0, count: errCap)
            var outLen: Int32 = 0, errLen: Int32 = 0, code: Int32 = 0
            var emsg = [CChar](repeating: 0, count: 256)
            let tmo = Int32((max(1, min(timeout, 86_400)) * 1000).rounded())
            let rc: Int32
            if let data = stdin, !data.isEmpty {
                rc = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                    serverdock_ssh_exec2(h, command,
                                    raw.baseAddress?.assumingMemoryBound(to: CChar.self), Int32(data.count),
                                    &out, Int32(outCap), &outLen, &errb, Int32(errCap), &errLen,
                                    &code, tmo, &emsg, 256)
                }
            } else {
                rc = serverdock_ssh_exec2(h, command, nil, 0,
                                     &out, Int32(outCap), &outLen, &errb, Int32(errCap), &errLen,
                                     &code, tmo, &emsg, 256)
            }
            if rc == -1 { throw SSHError(message: String(cString: emsg)) }
            let outData = Data(bytes: out, count: Int(outLen))
            let errData = Data(bytes: errb, count: Int(errLen))
            return ExecBytes(stdout: outData, stderr: errData, exitCode: code,
                             timedOut: rc == 1, cancelled: rc == 2)
        }
    }

    /// Streaming upload exec replaces spawned ssh + cat. pull fills buf up to cap bytes, returning bytes written, 0 for EOF, negative for cancel.
    /// Return (rc, exitCode), with rc 0=completed, 1=canceled; channel errors throw SSHError. Synchronous; call in the background.
    private final class PullBox {
        let pull: (UnsafeMutablePointer<CChar>, Int32) -> Int32
        init(_ pull: @escaping (UnsafeMutablePointer<CChar>, Int32) -> Int32) { self.pull = pull }
    }
    func execUpload(_ command: String,
                    pull: @escaping (UnsafeMutablePointer<CChar>, Int32) -> Int32) throws -> (rc: Int, exitCode: Int) {
        try queue.sync {
            guard let h = handle else { throw SSHError(message: String(localized: "Session closed")) }
            let box = Unmanaged.passRetained(PullBox(pull)).toOpaque()
            defer { Unmanaged<PullBox>.fromOpaque(box).release() }
            var exitCode: Int32 = 0
            var err = [CChar](repeating: 0, count: 256)
            let rc = serverdock_ssh_exec_upload(h, command, { ud, buf, cap in
                guard let ud, let buf else { return -1 }
                return Unmanaged<PullBox>.fromOpaque(ud).takeUnretainedValue().pull(buf, cap)
            }, box, &exitCode, &err, 256)
            if rc == -1 { throw SSHError(message: String(cString: err)) }
            return (Int(rc), Int(exitCode))
        }
    }

    /// Streaming exec blocks the current thread until EOF/error/cancel; use a dedicated background thread.
    /// Only one stream may run per session; HostMonitor uses a separate session. onData runs on that background thread.
    /// Merge stderr into onData. Completion returns a channel error (nil for normal/canceled termination) and remote exitCode, or -1 if unknown.
    private final class DataBox { let onData: (Data) -> Void; init(_ f: @escaping (Data) -> Void) { onData = f } }
    @discardableResult
    func execStream(_ command: String, onData: @escaping (Data) -> Void) -> (error: String?, exitCode: Int) {
        guard let h = handle else { return (String(localized: "Session closed"), -1) }
        let box = Unmanaged.passRetained(DataBox(onData)).toOpaque()
        var err = [CChar](repeating: 0, count: 256)
        var code: Int32 = -1
        let rc = serverdock_ssh_exec_stream(h, command, { ud, bytes, len in
            guard let ud, let bytes, len > 0 else { return }
            let cb = Unmanaged<DataBox>.fromOpaque(ud).takeUnretainedValue()
            cb.onData(Data(bytes: bytes, count: Int(len)))
        }, box, &code, &err, 256)
        Unmanaged<DataBox>.fromOpaque(box).release()
        return (rc == 0 ? nil : String(cString: err), Int(code))
    }

    /// Interrupt a stream by setting a C volatile flag from any thread. Bypass the serial queue to avoid deadlocking against the blocked stream.
    func cancel() {
        if let h = handle { serverdock_ssh_cancel(h) }
    }

    /// Native ServerDockSSHSession* for SFTP C calls; access only on the owner's serial queue, using an exclusive SFTP session.
    var rawHandle: OpaquePointer? { handle }

    func close() {
        queue.sync {
            if let h = handle { serverdock_ssh_close(h); handle = nil }
        }
    }

    deinit {
        // Normally close() first. deinit has no other references/concurrent access, so it can free directly as a fallback.
        if let h = handle { serverdock_ssh_close(h) }
    }
}

import Foundation

// MARK: - SFTP types exposed to RemoteFS

/// open pflags match libssh2 LIBSSH2_FXF_* directly.
enum SFTPFlag {
    static let READ: UInt32 = 0x1, WRITE: UInt32 = 0x2, APPEND: UInt32 = 0x4
    static let CREAT: UInt32 = 0x8, TRUNC: UInt32 = 0x10
}

private enum FX {     // SFTP protocol status code (LIBSSH2_FX_*).
    static let NO_SUCH_FILE: UInt32 = 2
    static let PERMISSION_DENIED: UInt32 = 3
}

/// SFTPError code is protocol STATUS or custom >=0xF000; isTransport triggers shell fallback for native/connection failures.
struct SFTPError: Error {
    let code: UInt32
    let message: String
    var isTransport = false
    var isNoSuchFile: Bool { code == FX.NO_SUCH_FILE }
    var isPermission: Bool { code == FX.PERMISSION_DENIED }
}

/// SFTP attributes used by this client.
struct SFTPAttrs {
    var size: UInt64? = nil
    var permissions: UInt32? = nil
    var mtime: UInt32? = nil
    /// Optimistic-lock mtime:size token; nil if fields are missing.
    var versionToken: String? {
        guard let m = mtime, let s = size else { return nil }
        return "\(m):\(s)"
    }
    init() {}
    init(_ a: ServerDockSFTPAttrs) {
        if a.has_size != 0 { size = a.size }
        if a.has_perm != 0 { permissions = a.permissions }
        if a.has_mtime != 0 { mtime = a.mtime }
    }
}

// MARK: - Dedicated per-host libssh2/SFTP connection with serialized requests

/// Lazily create a dedicated, nonpooled long-lived SSHSession so SFTP and short exec operations do not block each other.
/// Initialize SFTP on it and serialize all calls because libssh2 sessions are not thread-safe. Public APIs are async;
/// dispatch blocking work to the serial queue and bridge continuations without blocking the caller's executor.
/// Expose opaque eight-byte Data handles backed by ID/pointer mapping, preventing callers retaining invalid pointers.
final class SFTPSession: @unchecked Sendable {
    private let ssh: SSHConnection
    private let queue = DispatchQueue(label: "serverdock.sftp")
    private var conn: SSHSession?                              // Dedicated connection.
    private var sftp: UnsafeMutableRawPointer?                 // LIBSSH2_SFTP*
    private var failure: SFTPError?                            // Sticky after a transport failure; the caller discards/recreates this session.
    private var handles: [UInt64: UnsafeMutableRawPointer] = [:]
    private var nextId: UInt64 = 1

    /// Native rename_ex supports posix-rename atomic overwrites; posixRename falls back on unsupported servers.
    let supportsPosixRename = true

    init(_ ssh: SSHConnection) { self.ssh = ssh }

    // MARK: Serialized execution

    /// Run block synchronously on the serial queue; async wrappers do not block callers.
    private func perform<T>(_ block: @escaping () -> T) async -> T {
        await withCheckedContinuation { (c: CheckedContinuation<T, Never>) in
            queue.async { c.resume(returning: block()) }
        }
    }

    /// Connect/initialize SFTP on the serial queue only; nil means ready, otherwise return the failure reason.
    private func ensureLocked() -> SFTPError? {
        if let failure { return failure }
        if sftp != nil { return nil }
        do {
            let a = ssh.libssh2Auth
            let c = try SSHSession.connect(host: ssh.host, port: ssh.port, user: ssh.user,
                                           password: a.password, keyPath: a.keyPath, keyPassphrase: a.keyPassphrase,
                                           jump: ssh.jumpHost)
            guard let raw = c.rawHandle, let sp = serverdock_sftp_init(raw) else {
                c.close()
                let e = SFTPError(code: 0xF001, message: String(localized: "SFTP initialization failed"), isTransport: true)
                failure = e; return e
            }
            conn = c; sftp = sp
            return nil
        } catch {
            let msg = (error as? SSHSession.SSHError)?.message ?? String(localized: "SFTP connection failed")
            let e = SFTPError(code: 0xF002, message: msg, isTransport: true)
            failure = e; return e
        }
    }

    /// Convert C status to SFTPError on the serial queue; >=0xF000 marks sticky transport failure.
    private func makeError(_ code: Int32) -> SFTPError {
        let c = UInt32(bitPattern: code)
        if c >= 0xF000 {
            let e = SFTPError(code: c, message: String(localized: "SFTP connection error"), isTransport: true)
            failure = e
            return e
        }
        return SFTPError(code: c, message: String(localized: "SFTP error \(c)"))
    }

    // MARK: Handle encoding (eight-byte little-endian IDs)

    private static func encode(_ id: UInt64) -> Data {
        var v = id.littleEndian
        return withUnsafeBytes(of: &v) { Data($0) }
    }
    private func handleId(_ data: Data) -> UInt64? {
        guard data.count == 8 else { return nil }
        var v: UInt64 = 0
        for (i, b) in data.enumerated() { v |= UInt64(b) << (8 * i) }
        return v
    }
    private func handlePtr(_ data: Data) -> UnsafeMutableRawPointer? {
        guard let id = handleId(data) else { return nil }
        return handles[id]
    }
    private func badHandle() -> SFTPError { SFTPError(code: 0xF011, message: String(localized: "Invalid SFTP Handle"), isTransport: true) }

    // MARK: Lifecycle

    /// Idempotent explicit shutdown from RemoteFS cleanup closes handles, subsystem, and underlying connection.
    func shutdown() async {
        await perform {
            for (_, hp) in self.handles { serverdock_sftp_close(hp) }
            self.handles.removeAll()
            if let sftp = self.sftp { serverdock_sftp_shutdown(sftp); self.sftp = nil }
            self.conn?.close(); self.conn = nil
            if self.failure == nil { self.failure = SFTPError(code: 0xF007, message: String(localized: "SFTP closed"), isTransport: true) }
        }
    }

    // MARK: Paths / directories

    func realpath(_ path: String) async throws -> String {
        let r: Result<String, SFTPError> = await perform {
            if let e = self.ensureLocked() { return .failure(e) }
            guard let raw = self.conn?.rawHandle, let sftp = self.sftp else { return .failure(self.makeError(0xF000)) }
            var buf = [CChar](repeating: 0, count: 4096)
            let rc = serverdock_sftp_realpath(raw, sftp, path, &buf, 4096)
            return rc == 0 ? .success(String(cString: buf)) : .failure(self.makeError(rc))
        }
        return try r.get()
    }

    func opendir(_ path: String) async throws -> Data {
        let r: Result<UInt64, SFTPError> = await perform {
            if let e = self.ensureLocked() { return .failure(e) }
            guard let raw = self.conn?.rawHandle, let sftp = self.sftp else { return .failure(self.makeError(0xF000)) }
            guard let hp = serverdock_sftp_opendir(raw, sftp, path) else {
                let code = Int32(serverdock_sftp_last_errno(sftp))
                return .failure(self.makeError(code == 0 ? 0xF000 : code))
            }
            let id = self.nextId; self.nextId &+= 1
            self.handles[id] = hp
            return .success(id)
        }
        return Self.encode(try r.get())
    }

    /// Directory batch of up to 512 entries; nil denotes EOF.
    func readdir(_ handle: Data) async throws -> [(name: String, attrs: SFTPAttrs)]? {
        let r: Result<[(String, SFTPAttrs)], SFTPError> = await perform {
            guard let hp = self.handlePtr(handle) else { return .failure(self.badHandle()) }
            var items: [(String, SFTPAttrs)] = []
            var nameBuf = [CChar](repeating: 0, count: 1024)
            for _ in 0..<512 {
                var a = ServerDockSFTPAttrs()
                let n = nameBuf.withUnsafeMutableBufferPointer { bp in
                    serverdock_sftp_readdir(hp, bp.baseAddress, 1024, &a)
                }
                if n > 0 { items.append((String(cString: nameBuf), SFTPAttrs(a))) }
                else if n == 0 { break }                       // EOF
                else { return .failure(SFTPError(code: 0xF000, message: String(localized: "SFTP directory read failed"), isTransport: true)) }
            }
            return .success(items)
        }
        let items = try r.get()
        return items.isEmpty ? nil : items.map { (name: $0.0, attrs: $0.1) }
    }

    func closeHandle(_ handle: Data) async {
        await perform {
            if let id = self.handleId(handle), let hp = self.handles.removeValue(forKey: id) {
                serverdock_sftp_close(hp)
            }
        }
    }

    // MARK: stat

    func stat(_ path: String) async throws -> SFTPAttrs { try await statImpl(path, follow: true) }
    func lstat(_ path: String) async throws -> SFTPAttrs { try await statImpl(path, follow: false) }
    private func statImpl(_ path: String, follow: Bool) async throws -> SFTPAttrs {
        let r: Result<SFTPAttrs, SFTPError> = await perform {
            if let e = self.ensureLocked() { return .failure(e) }
            guard let raw = self.conn?.rawHandle, let sftp = self.sftp else { return .failure(self.makeError(0xF000)) }
            var a = ServerDockSFTPAttrs()
            let rc = serverdock_sftp_stat(raw, sftp, path, follow ? 1 : 0, &a)
            return rc == 0 ? .success(SFTPAttrs(a)) : .failure(self.makeError(rc))
        }
        return try r.get()
    }
    func fstat(_ handle: Data) async throws -> SFTPAttrs {
        let r: Result<SFTPAttrs, SFTPError> = await perform {
            guard let hp = self.handlePtr(handle) else { return .failure(self.badHandle()) }
            var a = ServerDockSFTPAttrs()
            let rc = serverdock_sftp_fstat(hp, &a)
            return rc == 0 ? .success(SFTPAttrs(a)) : .failure(self.makeError(rc))
        }
        return try r.get()
    }

    // MARK: File reads/writes

    func open(_ path: String, pflags: UInt32) async throws -> Data {
        let r: Result<UInt64, SFTPError> = await perform {
            if let e = self.ensureLocked() { return .failure(e) }
            guard let raw = self.conn?.rawHandle, let sftp = self.sftp else { return .failure(self.makeError(0xF000)) }
            guard let hp = serverdock_sftp_open(raw, sftp, path, pflags) else {
                let code = Int32(serverdock_sftp_last_errno(sftp))
                return .failure(self.makeError(code == 0 ? 0xF000 : code))
            }
            let id = self.nextId; self.nextId &+= 1
            self.handles[id] = hp
            return .success(id)
        }
        return Self.encode(try r.get())
    }

    /// Read one block; nil denotes EOF.
    func read(_ handle: Data, offset: UInt64, length: UInt32) async throws -> Data? {
        let r: Result<Data?, SFTPError> = await perform {
            guard let hp = self.handlePtr(handle) else { return .failure(self.badHandle()) }
            var buf = [UInt8](repeating: 0, count: Int(length))
            let n = buf.withUnsafeMutableBytes { mb in
                serverdock_sftp_read(hp, offset, mb.baseAddress?.assumingMemoryBound(to: CChar.self), Int32(length))
            }
            if n > 0 { return .success(Data(buf.prefix(n))) }
            if n == 0 { return .success(nil) }                 // EOF
            return .failure(SFTPError(code: 0xF000, message: String(localized: "SFTP read failed"), isTransport: true))
        }
        return try r.get()
    }

    func write(_ handle: Data, offset: UInt64, data: Data) async throws {
        let r: SFTPError? = await perform {
            guard let hp = self.handlePtr(handle) else { return self.badHandle() }
            if data.isEmpty { return nil }
            let n = data.withUnsafeBytes { rb in
                serverdock_sftp_write(hp, offset, rb.baseAddress?.assumingMemoryBound(to: CChar.self), Int32(data.count))
            }
            return n == data.count ? nil : SFTPError(code: 0xF000, message: String(localized: "SFTP write failed"), isTransport: true)
        }
        if let r { throw r }
    }

    // MARK: Rename / delete / permissions

    func remove(_ path: String) async throws { try await simple { serverdock_sftp_unlink($0, $1, path) } }
    func rmdir(_ path: String) async throws  { try await simple { serverdock_sftp_rmdir($0, $1, path) } }
    func mkdir(_ path: String) async throws  { try await simple { serverdock_sftp_mkdir($0, $1, path) } }
    func setPermissions(_ path: String, _ mode: UInt32) async throws {
        try await simple { serverdock_sftp_setstat_perm($0, $1, path, mode) }
    }
    func rename(from: String, to: String) async throws {
        try await simple { serverdock_sftp_rename($0, $1, from, to, 0) }
    }
    /// Prefer atomic posix-rename; unsupported servers fall back to non-atomic target-delete plus ordinary rename.
    func posixRename(from: String, to: String) async throws {
        let r: SFTPError? = await perform {
            if let e = self.ensureLocked() { return e }
            guard let raw = self.conn?.rawHandle, let sftp = self.sftp else { return self.makeError(0xF000) }
            if serverdock_sftp_rename(raw, sftp, from, to, 1) == 0 { return nil }
            _ = serverdock_sftp_unlink(raw, sftp, to)
            let rc2 = serverdock_sftp_rename(raw, sftp, from, to, 0)
            return rc2 == 0 ? nil : self.makeError(rc2)
        }
        if let r { throw r }
    }

    private func simple(_ op: @escaping (OpaquePointer, UnsafeMutableRawPointer) -> Int32) async throws {
        let r: SFTPError? = await perform {
            if let e = self.ensureLocked() { return e }
            guard let raw = self.conn?.rawHandle, let sftp = self.sftp else { return self.makeError(0xF000) }
            let rc = op(raw, sftp)
            return rc == 0 ? nil : self.makeError(rc)
        }
        if let r { throw r }
    }
}

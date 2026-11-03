import Foundation

struct RemoteFSError: Error {
    let message: String
    /// External changes detected during save cause optimistic-lock conflict and overwrite/reload/cancel UI.
    var isConflict: Bool = false
    /// Read/write permission denial enables editor Open/Save with sudo.
    var isPermission: Bool = false
}

/// Distinguish sudo failures from script failures to decide whether to reprompt for a password.
enum SudoFailure: Error {
    case passwordRequired          // Password required; passwordless sudo is unavailable.
    case wrongPassword
    case requiresTTY               // sudoers enables requiretty.
    case notPermitted(String)      // User is not in sudoers, sudo is missing, or a similar failure occurred.
    case fs(RemoteFSError)         // Elevation succeeded but the read/write itself failed, e.g. conflict or missing file.

    var message: String {
        switch self {
        case .passwordRequired: return String(localized: "sudo requires a password")
        case .wrongPassword: return String(localized: "Incorrect sudo password")
        case .requiresTTY: return String(localized: "This server's sudo requires a terminal (requiretty), so it can't be used from the editor.")
        case .notPermitted(let m): return m
        case .fs(let e): return e.message
        }
    }
}

// MARK: - Upload v2 transport types

/// Transfer signal as one atomic state.
enum UploadSignal { case run, cancel, pause }

/// Lock-protected cross-thread per-file control stores signal and transferred-byte progress.
final class UploadControl: @unchecked Sendable {
    private let lock = NSLock()
    private var _signal: UploadSignal = .run
    private var _sent: Int64 = 0
    func set(_ s: UploadSignal) { lock.lock(); _signal = s; lock.unlock() }
    var signal: UploadSignal { lock.lock(); defer { lock.unlock() }; return _signal }
    func setSent(_ v: Int64) { lock.lock(); _sent = v; lock.unlock() }
    var sent: Int64 { lock.lock(); defer { lock.unlock() }; return _sent }
}

/// Cancellation handle retains active libssh2; cancel() sets a flag so exec stops and closes its channel.
/// Thread-safe interruption of potentially long commands such as deletion.
final class CommandHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var session: SSHSession?
    private var cancelled = false

    /// Attach borrowed sessions, canceling immediately if cancellation arrived earlier.
    func bind(_ s: SSHSession) {
        lock.lock(); let c = cancelled; if !c { session = s }; lock.unlock()
        if c { s.cancel() }
    }
    /// Detach after execution so later cancel() cannot mark a recycled session already reused by another borrower.
    func unbind() { lock.lock(); session = nil; lock.unlock() }
    func cancel() {
        lock.lock(); cancelled = true; let s = session; lock.unlock()
        s?.cancel()
    }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

/// Transfer results do not return resume offsets; the caller must stat remote .part afterward.
/// Locally sent bytes may include pipe buffers beyond persisted data; using them as offsets creates holes (review R1).
enum UploadOutcome: Equatable { case completed, cancelled, paused, failed(String) }

/// Probe remote .part size and final-file existence/size before upload.
struct UploadProbe { let partSize: Int64; let finalExists: Bool; let finalSize: Int64 }

/// Browser/tree loading state.
enum LoadPhase: Equatable { case loading, loaded, error(String) }

/// Remote directory entry.
struct RemoteFile: Identifiable, Hashable {
    enum Kind { case directory, file, symlink, other }
    let name: String
    let path: String          // Absolute path.
    let kind: Kind
    let size: Int64
    let modified: Date?
    var id: String { path }
    var isDir: Bool { kind == .directory }
}

/// Remote operations through system ssh, reusing SSHConnection settings and askpass.
/// Short-lived ssh operations share ControlMaster so authentication occurs once.
final class RemoteFS {
    private let ssh: SSHConnection
    init(_ ssh: SSHConnection) { self.ssh = ssh }
    /// Local Mac delegates to LocalFS instead of SFTP/SSH.
    private var isLocal: Bool { ssh.isLocal }

    /// Deinitialization terminates SFTP subprocess/reader as a fallback for temporary home-query instances
    /// and closed browser/tree/editor tabs, preventing process/thread/pipe-buffer leaks. Transfers clean up separately on completion.
    deinit {
        if let s = _sftp { Task { await s.shutdown() } }
    }

    // MARK: - Lazy serialized SFTP; transport failure makes shell fallback sticky
    private var _sftp: SFTPSession?
    private let sftpLock = NSLock()
    private var sftpUsable = true

    private var isSftpUsable: Bool { sftpLock.lock(); defer { sftpLock.unlock() }; return sftpUsable }
    private func session() -> SFTPSession {
        sftpLock.lock(); defer { sftpLock.unlock() }
        if let s = _sftp { return s }
        let s = SFTPSession(ssh); _sftp = s; return s
    }
    /// Mark SFTP unavailable, terminate its subprocess, and use shell-exec afterward.
    private func markSftpDown() {
        sftpLock.lock(); let s = _sftp; sftpUsable = false; _sftp = nil; sftpLock.unlock()
        Task { await s?.shutdown() }
    }

    /// Explicitly close the SFTP subprocess/reader/buffers after transfer completion/history removal.
    /// Idempotent; retain sftpUsable so retries/resume/.part cleanup can recreate sessions later.
    func closeSession() {
        sftpLock.lock(); let s = _sftp; _sftp = nil; sftpLock.unlock()
        if let s { Task { await s.shutdown() } }
    }

    /// Network changes close stale SFTP and clear sticky shell fallback, recreating SFTP on the next operation.
    /// The caller closes stale ControlMaster once per host; see AppModel.reconnectFileViewsAfterNetworkChange.
    /// Do not repeat closeMaster/ssh -O exit for every instance of the same host.
    func resetForReconnect() {
        sftpLock.lock(); let s = _sftp; _sftp = nil; sftpUsable = true; sftpLock.unlock()
        Task { await s?.shutdown() }
    }
    /// Derive file kind from SFTP permission bits; missing permissions mean .other (review R3).
    private func kindFromMode(_ perm: UInt32?) -> RemoteFile.Kind {
        guard let m = perm else { return .other }
        switch m & 0o170000 {
        case 0o040000: return .directory
        case 0o120000: return .symlink
        case 0o100000: return .file
        default:       return .other
        }
    }

    struct OpResult { let data: Data; let stderr: Data; let code: Int32 }

    /// Execute via the login shell, draining output incrementally to avoid full-buffer deadlocks.
    /// Nonempty stdin sends large data, e.g. file writes, to subprocess standard input.
    func run(_ remoteCommand: String, stdin: Data? = nil, timeout: Double = 20,
             handle: CommandHandle? = nil) async -> OpResult {
        if isLocal {
            let r = await LocalFS.runShell(remoteCommand, stdin: stdin, timeout: timeout)
            return OpResult(data: r.data, stderr: r.stderr, code: r.code)
        }
        let conn = ssh
        return await withCheckedContinuation { (cont: CheckedContinuation<OpResult, Never>) in
            DispatchQueue.global().async {
                let pool = SSHSessionPool.shared
                let s: SSHSession
                do { s = try pool.take(conn) }      // Borrow a warm connection, amortizing authentication on first use and replacing ControlMaster.
                catch {
                    let msg = (error as? SSHSession.SSHError)?.message ?? String(localized: "Connection Failed")
                    cont.resume(returning: OpResult(data: Data(), stderr: Data(msg.utf8), code: -1))
                    return
                }
                handle?.bind(s)                     // Bind the cancellation handle so user cancellation calls s.cancel() to interrupt the exec loop.
                do {
                    let r = try s.execBytes(remoteCommand, stdin: stdin, timeout: timeout)
                    handle?.unbind()
                    if r.timedOut || r.cancelled { pool.discard(s) } else { pool.recycle(conn, s) }
                    let code = (r.timedOut || r.cancelled) ? -1 : r.exitCode
                    cont.resume(returning: OpResult(data: r.stdout, stderr: r.stderr, code: code))
                } catch {
                    handle?.unbind()
                    pool.discard(s)                 // Discard channel-level errors, possibly caused by disconnects, without returning a bad session to the pool.
                    let msg = (error as? SSHSession.SSHError)?.message ?? String(localized: "Execution Failed")
                    cont.resume(returning: OpResult(data: Data(), stderr: Data(msg.utf8), code: -1))
                }
            }
        }
    }

    // MARK: - Upload (.part finalization, append, and cancellation)

    /// SFTP STAT returns nil only for missing files; throw all other errors, including transport failures.
    private func sftpStatOrNil(_ path: String) async throws -> SFTPAttrs? {
        do { return try await session().stat(path) }
        catch let e as SFTPError where e.isNoSuchFile { return nil }
    }

    /// Probe .part resume size and final-file existence/size for name conflicts.
    func probeUpload(remotePath: String) async -> UploadProbe {
        if isLocal {
            let fm = FileManager.default
            func size(_ p: String) -> Int64 { ((try? fm.attributesOfItem(atPath: p))?[.size] as? NSNumber)?.int64Value ?? 0 }
            return UploadProbe(partSize: size(remotePath + ".part"), finalExists: fm.fileExists(atPath: remotePath), finalSize: size(remotePath))
        }
        if isSftpUsable {
            do {
                let part = try await sftpStatOrNil(remotePath + ".part")
                let final = try await sftpStatOrNil(remotePath)
                return UploadProbe(partSize: Int64(part?.size ?? 0),
                                   finalExists: final != nil,
                                   finalSize: Int64(final?.size ?? 0))
            }
            catch let e as SFTPError where e.isTransport { markSftpDown() }
            catch { return UploadProbe(partSize: 0, finalExists: false, finalSize: 0) }
        }
        return await probeUploadViaShell(remotePath: remotePath)
    }
    private func probeUploadViaShell(remotePath: String) async -> UploadProbe {
        let b64 = Data(remotePath.utf8).base64EncodedString()
        let cmd = "P=$(printf %s '\(b64)'|base64 -d); T=\"$P.part\"; ps=-1; fs=-1; fe=0; " +
            "if [ -e \"$T\" ]; then ps=$(stat -c %s \"$T\" 2>/dev/null || stat -f %z \"$T\" 2>/dev/null); fi; " +
            "if [ -e \"$P\" ]; then fe=1; fs=$(stat -c %s \"$P\" 2>/dev/null || stat -f %z \"$P\" 2>/dev/null); fi; " +
            "echo \"$ps $fs $fe\""
        let r = await run(cmd, timeout: 20)
        let parts = (String(data: r.data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ").map { Int64($0) ?? -1 }
        guard r.code == 0, parts.count >= 3 else {
            return UploadProbe(partSize: 0, finalExists: false, finalSize: 0)
        }
        return UploadProbe(partSize: max(0, parts[0]), finalExists: parts[2] == 1, finalSize: max(0, parts[1]))
    }

    /// After transfer, inherit original permissions and atomically rename .part over the final file.
    func finalizeUpload(remotePath: String) async -> Result<Void, RemoteFSError> {
        if isLocal {
            let fm = FileManager.default
            do {
                let part = URL(fileURLWithPath: remotePath + ".part"), dest = URL(fileURLWithPath: remotePath)
                if fm.fileExists(atPath: remotePath) { _ = try fm.replaceItemAt(dest, withItemAt: part) }
                else { try fm.moveItem(at: part, to: dest) }
                return .success(())
            } catch { return .failure(RemoteFSError(message: String(localized: "Write Failed"))) }
        }
        if isSftpUsable {
            do { try await sftpFinalize(remotePath); return .success(()) }
            catch let e as SFTPError where e.isTransport { markSftpDown() }
            catch let e as SFTPError { return .failure(RemoteFSError(message: e.message)) }
            catch { return .failure(RemoteFSError(message: String(localized: "Write Failed"))) }
        }
        return await finalizeUploadViaShell(remotePath: remotePath)
    }
    private func sftpFinalize(_ remotePath: String) async throws {
        let s = session()
        let part = remotePath + ".part"
        if let perm = (try await sftpStatOrNil(remotePath))?.permissions {
            _ = try? await s.setPermissions(part, perm)    // Inherit original permissions on a best-effort basis.
        }
        if s.supportsPosixRename {
            try await s.posixRename(from: part, to: remotePath)    // Atomic overwrite (review R7).
        } else {
            do { try await s.rename(from: part, to: remotePath) }
            catch { _ = try? await s.remove(remotePath); try await s.rename(from: part, to: remotePath) }
        }
    }
    private func finalizeUploadViaShell(remotePath: String) async -> Result<Void, RemoteFSError> {
        let b64 = Data(remotePath.utf8).base64EncodedString()
        let cmd = "P=$(printf %s '\(b64)'|base64 -d); T=\"$P.part\"; " +
            "if [ -e \"$P\" ]; then chmod --reference=\"$P\" \"$T\" 2>/dev/null || " +
            "chmod \"$(stat -f %Lp \"$P\" 2>/dev/null)\" \"$T\" 2>/dev/null; fi; " +
            "mv -f \"$T\" \"$P\""
        let r = await run(cmd, timeout: 30)
        return r.code == 0 ? .success(()) : .failure(RemoteFSError(message: String(localized: "Write Failed (Exit Code \(r.code))")))
    }

    /// Best-effort removal of abandoned remote .part after cancellation; later probes handle failures.
    func cleanupPart(remotePath: String) async {
        if isLocal { try? FileManager.default.removeItem(atPath: remotePath + ".part"); return }
        if isSftpUsable {
            do { try await session().remove(remotePath + ".part"); return }
            catch let e as SFTPError where e.isTransport { markSftpDown() }
            catch { return }
        }
        let b64 = Data(remotePath.utf8).base64EncodedString()
        _ = await run("P=$(printf %s '\(b64)'|base64 -d); rm -f \"$P.part\"", timeout: 15)
    }

    // MARK: - Create / download

    /// Create a directory, failing if present; prefer SFTP with shell fallback.
    func mkdir(_ path: String) async -> Result<Void, RemoteFSError> {
        if isLocal { return await LocalFS.mkdir(path) }
        if isSftpUsable {
            do { try await session().mkdir(path); return .success(()) }
            catch let e as SFTPError where e.isTransport { markSftpDown() }
            catch let e as SFTPError {
                return .failure(RemoteFSError(message: e.isPermission ? String(localized: "No create permission") : e.message))
            }
            catch { return .failure(RemoteFSError(message: String(localized: "Couldn't Create Folder"))) }
        }
        let b64 = Data(path.utf8).base64EncodedString()
        let r = await run("P=$(printf %s '\(b64)'|base64 -d); mkdir -- \"$P\"")
        return r.code == 0 ? .success(()) : .failure(Self.shellErr(r, String(localized: "Couldn't Create Folder")))
    }

    /// Create an empty file with noclobber to prevent overwriting.
    func createFile(_ path: String) async -> Result<Void, RemoteFSError> {
        if isLocal { return await LocalFS.createFile(path) }
        let b64 = Data(path.utf8).base64EncodedString()
        let r = await run("P=$(printf %s '\(b64)'|base64 -d); set -C; : > \"$P\"")
        return r.code == 0 ? .success(()) : .failure(RemoteFSError(message: String(localized: "Couldn't create file (it may already exist or you lack permission)")))
    }

    /// Stream SFTP chunks into a local file without loading it all into memory; control reports progress/cancellation.
    /// Use a dedicated RemoteFS/SFTP instance so transfers do not block browsing.
    /// Resume downloads at startOffset>0, appending locally and reading remotely at that offset.
    func download(_ remotePath: String, to localURL: URL, startOffset: Int64 = 0, control: UploadControl) async -> UploadOutcome {
        if isLocal { return await LocalFS.copy(from: remotePath, to: localURL.path, startOffset: startOffset, control: control) }
        guard isSftpUsable else { return .failed(String(localized: "SFTP Connection Required")) }
        do {
            let handle = try await session().open(remotePath, pflags: SFTPFlag.READ)
            let fh: FileHandle
            if startOffset > 0, FileManager.default.fileExists(atPath: localURL.path) {
                // Fail if the partial local file cannot be opened; never truncate/recreate and lose data or create holes.
                guard let h = try? FileHandle(forWritingTo: localURL) else {
                    await session().closeHandle(handle); return .failed(String(localized: "Couldn't write to local file"))
                }
                _ = try? h.seekToEnd()
                fh = h
            } else {
                FileManager.default.createFile(atPath: localURL.path, contents: nil)
                guard let h = try? FileHandle(forWritingTo: localURL) else {
                    await session().closeHandle(handle); return .failed(String(localized: "Couldn't write to local file"))
                }
                fh = h
            }
            var offset: UInt64 = startOffset > 0 ? UInt64(startOffset) : 0
            control.setSent(Int64(offset))
            while true {
                let sig = control.signal
                if sig == .cancel { try? fh.close(); await session().closeHandle(handle); return .cancelled }
                if sig == .pause { try? fh.close(); await session().closeHandle(handle); return .paused }  // Keep the local partial file.
                guard let chunk = try await session().read(handle, offset: offset, length: 32768),
                      !chunk.isEmpty else { break }
                fh.write(chunk)
                offset += UInt64(chunk.count)
                control.setSent(Int64(offset))
            }
            try? fh.close()
            await session().closeHandle(handle)
            return .completed
        } catch let e as SFTPError where e.isTransport {
            markSftpDown(); return .failed(String(localized: "Connection Interrupted"))
        } catch let e as SFTPError {
            return .failed(e.isPermission ? String(localized: "No read permission") : e.message)
        } catch {
            return .failed(String(localized: "Download failed"))
        }
    }

    private static func shellErr(_ r: OpResult, _ fallback: String) -> RemoteFSError {
        let err = String(data: r.stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return RemoteFSError(message: err.isEmpty ? fallback : err)
    }

    /// Upload to remotePath.part using offset SFTP writes for resume or single-pipe cat fallback.
    func upload(localURL: URL, toRemote remotePath: String,
                startOffset: Int64, control: UploadControl) async -> UploadOutcome {
        if isLocal { return await LocalFS.copy(from: localURL.path, to: remotePath + ".part", startOffset: startOffset, control: control) }
        if isSftpUsable {
            return await sftpUpload(localURL: localURL, toRemote: remotePath, startOffset: startOffset, control: control)
        }
        return await uploadViaShell(localURL: localURL, toRemote: remotePath, startOffset: startOffset, control: control)
    }

    /// SFTP upload: OPEN(.part) -> FSTAT clamps the offset to avoid holes (R4) -> 32K WRITE loop -> CLOSE.
    /// Handle errors without throwing: transport errors markSftpDown and return .failed; retries fall back to shell and re-probe the offset.
    private func sftpUpload(localURL: URL, toRemote remotePath: String,
                           startOffset: Int64, control: UploadControl) async -> UploadOutcome {
        let s = session()
        let part = remotePath + ".part"
        let pflags = startOffset > 0 ? (SFTPFlag.WRITE | SFTPFlag.CREAT)
                                     : (SFTPFlag.WRITE | SFTPFlag.CREAT | SFTPFlag.TRUNC)
        do {
            let h = try await s.open(part, pflags: pflags)
            var off: UInt64 = 0
            if startOffset > 0 {
                let real = (try await s.fstat(h)).size ?? 0
                off = min(UInt64(startOffset), real)      // Resume from the actual remote .part size (R4).
            }
            guard let input = try? FileHandle(forReadingFrom: localURL) else {
                await s.closeHandle(h); return .failed(String(localized: "Couldn't read local file"))
            }
            if off > 0 { try? input.seek(toOffset: off) }
            var sent = Int64(off)
            control.setSent(sent)
            while true {
                let sig = control.signal
                if sig == .cancel { try? input.close(); await s.closeHandle(h); return .cancelled }
                if sig == .pause { try? input.close(); await s.closeHandle(h); return .paused }  // Keep the remote .part.
                let chunk: Data
                do {
                    guard let c = try input.read(upToCount: 32 * 1024), !c.isEmpty else { break }   // EOF
                    chunk = c
                } catch { try? input.close(); await s.closeHandle(h); return .failed(String(localized: "Error reading local file")) }
                do { try await s.write(h, offset: UInt64(sent), data: chunk) }
                catch let e as SFTPError where e.isTransport {
                    try? input.close(); await s.closeHandle(h); markSftpDown(); return .failed(String(localized: "Connection Interrupted"))
                } catch let e as SFTPError {
                    try? input.close(); await s.closeHandle(h)
                    return .failed(e.isPermission ? String(localized: "No write permission") : e.message)
                }
                sent += Int64(chunk.count)
                control.setSent(sent)
            }
            try? input.close()
            await s.closeHandle(h)
            return .completed
        } catch let e as SFTPError where e.isTransport {
            markSftpDown(); return .failed(String(localized: "Connection Interrupted"))
        } catch let e as SFTPError {
            return .failed(e.isPermission ? String(localized: "No write permission") : e.message)
        } catch {
            return .failed(String(localized: "Upload failed"))
        }
    }

    /// Single-pipe fallback: supply ssh stdin (cat > / cat >>), using the same reliable path as v1.
    private func uploadViaShell(localURL: URL, toRemote remotePath: String,
                startOffset: Int64,
                control: UploadControl) async -> UploadOutcome {
        // In-process libssh2 streaming upload replaces spawned ssh + cat: an exclusive connection feeds local file chunks through pull callbacks
        // to remote `cat >`, supporting pause/cancel while preserving .part for resume.
        let b64 = Data(remotePath.utf8).base64EncodedString()
        let redir = startOffset > 0 ? ">>" : ">"
        let remoteCmd = "P=$(printf %s '\(b64)'|base64 -d); T=\"$P.part\"; cat \(redir) \"$T\""
        let conn = ssh

        return await withCheckedContinuation { (cont: CheckedContinuation<UploadOutcome, Never>) in
            DispatchQueue.global().async {
                let session: SSHSession
                do { session = try SSHSessionPool.shared.dedicated(conn) }
                catch {
                    cont.resume(returning: .failed((error as? SSHSession.SSHError)?.message ?? String(localized: "Couldn't Connect")))
                    return
                }
                defer { session.close() }
                guard let input = try? FileHandle(forReadingFrom: localURL) else {
                    cont.resume(returning: .failed(String(localized: "Couldn't read local file"))); return
                }
                defer { try? input.close() }
                if startOffset > 0 { try? input.seek(toOffset: UInt64(startOffset)) }
                var sent = startOffset
                control.setSent(sent)

                var reason = 0   // 0 = normal, 1 = canceled, 2 = paused, 3 = read error.
                let pull: (UnsafeMutablePointer<CChar>, Int32) -> Int32 = { buf, cap in
                    switch control.signal {
                    case .cancel: reason = 1; return -1
                    case .pause:  reason = 2; return -1
                    case .run:    break
                    }
                    let want = min(Int(cap), 256 * 1024)
                    let chunk: Data
                    do {
                        guard let c = try input.read(upToCount: want), !c.isEmpty else { return 0 }  // EOF
                        chunk = c
                    } catch { reason = 3; return -1 }
                    let count = chunk.count
                    _ = chunk.withUnsafeBytes { memcpy(buf, $0.baseAddress, count) }
                    sent += Int64(count)
                    control.setSent(sent)
                    return Int32(count)
                }

                let outcome: UploadOutcome
                do {
                    let r = try session.execUpload(remoteCmd, pull: pull)
                    if reason == 1 { outcome = .cancelled }
                    else if reason == 2 { outcome = .paused }                 // Preserve remote .part for resume.
                    else if reason == 3 { outcome = .failed(String(localized: "Error reading local file")) }
                    else if r.rc == 0 && r.exitCode == 0 { outcome = .completed }
                    else { outcome = .failed(String(localized: "Upload interrupted (exit code \(r.exitCode))")) }
                } catch {
                    outcome = .failed((error as? SSHSession.SSHError)?.message ?? String(localized: "Connection Interrupted"))
                }
                cont.resume(returning: outcome)
            }
        }
    }

    // MARK: - File reads/writes

    func read(_ path: String, limit: Int) async -> Result<(data: Data, version: String?), RemoteFSError> {
        if isLocal { return await LocalFS.read(path, limit: limit) }
        if isSftpUsable {
            do { return .success(try await sftpRead(path, limit: limit)) }
            catch let e as SFTPError where e.isTransport { markSftpDown() }
            catch let e as SFTPError {
                return .failure(RemoteFSError(message: e.isNoSuchFile ? String(localized: "File Doesn't Exist")
                    : (e.isPermission ? String(localized: "No read permission") : e.message),
                    isPermission: e.isPermission))
            }
            catch { return .failure(RemoteFSError(message: String(localized: "Couldn't read file"))) }
        }
        return await readViaShell(path, limit: limit)
    }

    private func sftpRead(_ path: String, limit: Int) async throws -> (data: Data, version: String?) {
        let s = session()
        let h = try await s.open(path, pflags: SFTPFlag.READ)
        do {
            let version = (try await s.fstat(h)).versionToken   // "mtime:size", using FSTAT to follow symlinks (review R9).
            var data = Data()
            while data.count < limit {
                let want = UInt32(min(32 * 1024, limit - data.count))
                guard let chunk = try await s.read(h, offset: UInt64(data.count), length: want),
                      !chunk.isEmpty else { break }
                data.append(chunk)
            }
            await s.closeHandle(h)
            return (data, version)
        } catch {
            await s.closeHandle(h); throw error
        }
    }

    /// Read a remote file with binary-safe base64 transport, up to `limit` bytes.
    /// Return content plus a version token (`mtime:size`) for optimistic locking, or nil when stat is unavailable. Output is the version line followed by base64 content.
    private func readViaShell(_ path: String, limit: Int) async -> Result<(data: Data, version: String?), RemoteFSError> {
        // Limit reads with head -c; base64 protects control characters from shell/transport corruption.
        return decodeShellRead(await run(Self.shellReadScript(path, limit: limit), timeout: 40))
    }

    /// Read command shared by readViaShell and sudo reads.
    private static func shellReadScript(_ path: String, limit: Int) -> String {
        let b64 = Data(path.utf8).base64EncodedString()
        return "P=$(printf %s '\(b64)'|base64 -d); " +
            "if [ ! -e \"$P\" ]; then echo __SERVERDOCK_NOENT__ >&2; exit 2; fi; " +
            "if [ -d \"$P\" ]; then echo __SERVERDOCK_ISDIR__ >&2; exit 3; fi; " +
            "echo \"__SERVERDOCK_VER__:$(stat -c '%Y:%s' \"$P\" 2>/dev/null || stat -f '%m:%z' \"$P\" 2>/dev/null)\"; " +
            "head -c \(limit) \"$P\" | base64"
    }

    /// Parse the version-token first line and base64 body; map marked nonzero exits to errors.
    private func decodeShellRead(_ r: OpResult) -> Result<(data: Data, version: String?), RemoteFSError> {
        if r.code != 0 {
            let err = String(data: r.stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let msg: String
            var perm = false
            if err.contains("__SERVERDOCK_NOENT__") { msg = String(localized: "File Doesn't Exist") }
            else if err.contains("__SERVERDOCK_ISDIR__") { msg = String(localized: "This is a directory") }
            else if err.contains("Permission denied") || err.contains("permission") { msg = String(localized: "No read permission"); perm = true }
            else { msg = err.isEmpty ? String(localized: "Couldn't read file (exit code \(r.code))") : err }
            return .failure(RemoteFSError(message: msg, isPermission: perm))
        }
        // Separate the version line from the base64 body.
        var version: String? = nil
        var body = r.data
        if let nl = r.data.firstIndex(of: 0x0A) {
            let firstLine = String(data: r.data[r.data.startIndex..<nl], encoding: .utf8) ?? ""
            if firstLine.hasPrefix("__SERVERDOCK_VER__:") {
                let v = String(firstLine.dropFirst("__SERVERDOCK_VER__:".count))
                version = v.isEmpty ? nil : v
                body = Data(r.data[r.data.index(after: nl)...])
            }
        }
        guard let decoded = Data(base64Encoded: body, options: .ignoreUnknownCharacters) else {
            return .failure(RemoteFSError(message: String(localized: "Failed to decode content")))
        }
        return .success((decoded, version))
    }

    /// Write remotely with optimistic concurrency. Send base64 content through stdin and first write a temporary file in the same directory.
    /// If expectedVersion is set, compare current mtime:size before finalization; a mismatch exits with code 9 without overwriting.
    /// Prefer atomic mv replacement after chmod/chown --reference inherits the original permissions/owner.
    /// If mv or metadata inheritance is unavailable (unwritable directory, non-GNU system, or non-root user), fall back to cat > in place, preserving inode/owner without extra permission requirements.
    /// Return the new mtime:size token after success so the caller can update its baseline.
    func write(_ path: String, data: Data, expectedVersion: String?) async -> Result<String, RemoteFSError> {
        if isLocal { return await LocalFS.write(path, data: data, expectedVersion: expectedVersion) }
        if isSftpUsable {
            do { return .success(try await sftpWrite(path, data: data, expectedVersion: expectedVersion)) }
            catch let e as SFTPError where e.isTransport { markSftpDown() }
            catch let e as RemoteFSError { return .failure(e) }                // Conflicts and related errors are already mapped.
            catch let e as SFTPError { return .failure(RemoteFSError(message: e.isPermission ? String(localized: "No write permission") : e.message, isPermission: e.isPermission)) }
            catch { return .failure(RemoteFSError(message: String(localized: "Save failed"))) }
        }
        return await writeViaShell(path, data: data, expectedVersion: expectedVersion)
    }

    /// SFTP write: three-state STAT conflict check -> .serverdock-tmp -> inherit permissions -> atomic rename, preferably posix-rename -> new version token.
    private func sftpWrite(_ path: String, data: Data, expectedVersion: String?) async throws -> String {
        let s = session()
        let existing = try await sftpStatOrNil(path)        // Missing file returns nil; transport errors throw.
        if let st = existing, let exp = expectedVersion, !exp.isEmpty {
            if let token = st.versionToken {
                if token != exp { throw RemoteFSError(message: String(localized: "The file was modified by another program or session"), isConflict: true) }
            } else {
                throw RemoteFSError(message: String(localized: "Couldn't Verify File Version"), isConflict: true)   // The file exists but attributes are incomplete (review R6).
            }
        }
        let tmp = path + ".serverdock-tmp"
        let h = try await s.open(tmp, pflags: SFTPFlag.WRITE | SFTPFlag.CREAT | SFTPFlag.TRUNC)
        do {
            var off = 0
            while off < data.count {
                let end = min(off + 32 * 1024, data.count)
                let lo = data.index(data.startIndex, offsetBy: off)
                let hi = data.index(data.startIndex, offsetBy: end)
                try await s.write(h, offset: UInt64(off), data: data.subdata(in: lo..<hi))
                off = end
            }
            await s.closeHandle(h)
        } catch { await s.closeHandle(h); throw error }
        if let perm = existing?.permissions { _ = try? await s.setPermissions(tmp, perm) }
        if s.supportsPosixRename {
            try await s.posixRename(from: tmp, to: path)
        } else {
            do { try await s.rename(from: tmp, to: path) }
            catch { _ = try? await s.remove(path); try await s.rename(from: tmp, to: path) }
        }
        return (try? await s.stat(path))?.versionToken ?? ""
    }

    private func writeViaShell(_ path: String, data: Data, expectedVersion: String?) async -> Result<String, RemoteFSError> {
        let b64 = Data(path.utf8).base64EncodedString()
        let payload = Data(data.base64EncodedString().utf8)
        let exp = expectedVersion ?? ""          // Our stat result contains only digits and a colon (mtime:size), so it is safe to inline.
        let stat = "stat -c '%Y:%s' \"$P\" 2>/dev/null || stat -f '%m:%z' \"$P\" 2>/dev/null"
        let cmd = "P=$(printf %s '\(b64)'|base64 -d); EXP='\(exp)'; T=\"$P.serverdock-tmp.$$\"; " +
            "if base64 -d > \"$T\" 2>/dev/null; then " +
            "  if [ -e \"$P\" ]; then " +
            "    CUR=$(\(stat)); " +
            "    if [ -n \"$EXP\" ] && [ \"$CUR\" != \"$EXP\" ]; then rm -f \"$T\"; echo __SERVERDOCK_CONFLICT__ >&2; exit 9; fi; " +
            "    if chmod --reference=\"$P\" \"$T\" 2>/dev/null && chown --reference=\"$P\" \"$T\" 2>/dev/null && mv -f \"$T\" \"$P\" 2>/dev/null; then \(stat); " +
            "    elif cat \"$T\" > \"$P\" 2>/dev/null; then rm -f \"$T\"; \(stat); " +
            "    else rm -f \"$T\"; echo __SERVERDOCK_WRITEFAIL__ >&2; exit 7; fi; " +
            "  else " +
            "    if mv -f \"$T\" \"$P\" 2>/dev/null; then \(stat); else rm -f \"$T\"; echo __SERVERDOCK_WRITEFAIL__ >&2; exit 7; fi; " +
            "  fi; " +
            "else rm -f \"$T\" 2>/dev/null; echo __SERVERDOCK_TMPFAIL__ >&2; exit 8; fi"
        let r = await run(cmd, stdin: payload, timeout: 60)
        if r.code != 0 {
            let err = String(data: r.stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if err.contains("__SERVERDOCK_CONFLICT__") {
                return .failure(RemoteFSError(message: String(localized: "The file was modified by another program or session"), isConflict: true))
            }
            let msg: String
            var perm = false
            if err.contains("__SERVERDOCK_WRITEFAIL__") || err.contains("Permission denied") { msg = String(localized: "No write permission"); perm = true }
            else if err.contains("__SERVERDOCK_TMPFAIL__") { msg = String(localized: "Couldn't create a temporary file in the destination directory"); perm = true }
            else { msg = err.isEmpty ? String(localized: "Save failed (exit code \(r.code))") : err }
            return .failure(RemoteFSError(message: msg, isPermission: perm))
        }
        let newVer = String(data: r.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return .success(newVer)
    }

    // MARK: - sudo reads/writes (Open/Save with sudo)

    /// Read as root using the readViaShell output format. A nil password tries only passwordless sudo (-n).
    func sudoRead(_ path: String, limit: Int, password: String?) async -> Result<(data: Data, version: String?), SudoFailure> {
        switch await runSudo(Self.shellReadScript(path, limit: limit), password: password, stdin: nil, timeout: 40) {
        case .failure(let f): return .failure(f)
        case .success(let r):
            switch decodeShellRead(r) {
            case .success(let v): return .success(v)
            case .failure(let e): return .failure(.fs(e))
            }
        }
    }

    /// Write as root: decode into a root-owned temporary file, check the version, then cat > the original in place,
    /// preserving its owner and permissions. New files use root's umask. Return the new version token on success.
    func sudoWrite(_ path: String, data: Data, expectedVersion: String?, password: String?) async -> Result<String, SudoFailure> {
        let b64 = Data(path.utf8).base64EncodedString()
        let exp = expectedVersion ?? ""
        let stat = "stat -c '%Y:%s' \"$P\" 2>/dev/null || stat -f '%m:%z' \"$P\" 2>/dev/null"
        let script = "P=$(printf %s '\(b64)'|base64 -d); EXP='\(exp)'; " +
            "T=$(mktemp 2>/dev/null) || { echo __SERVERDOCK_TMPFAIL__ >&2; exit 8; }; " +
            "if ! base64 -d > \"$T\" 2>/dev/null; then rm -f \"$T\"; echo __SERVERDOCK_TMPFAIL__ >&2; exit 8; fi; " +
            "if [ -e \"$P\" ] && [ -n \"$EXP\" ]; then CUR=$(\(stat)); " +
            "  if [ \"$CUR\" != \"$EXP\" ]; then rm -f \"$T\"; echo __SERVERDOCK_CONFLICT__ >&2; exit 9; fi; fi; " +
            "if cat \"$T\" > \"$P\"; then rm -f \"$T\"; \(stat); else rm -f \"$T\"; echo __SERVERDOCK_WRITEFAIL__ >&2; exit 7; fi"
        let payload = Data(data.base64EncodedString().utf8)
        switch await runSudo(script, password: password, stdin: payload, timeout: 60) {
        case .failure(let f): return .failure(f)
        case .success(let r):
            if r.code != 0 {
                let err = String(data: r.stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if err.contains("__SERVERDOCK_CONFLICT__") {
                    return .failure(.fs(RemoteFSError(message: String(localized: "The file was modified by another program or session"), isConflict: true)))
                }
                let msg: String
                if err.contains("__SERVERDOCK_WRITEFAIL__") { msg = String(localized: "Save failed") + (err.isEmpty ? "" : ": \(err)") }
                else if err.contains("__SERVERDOCK_TMPFAIL__") { msg = String(localized: "Couldn't create a temporary file") }
                else { msg = err.isEmpty ? String(localized: "Save failed (exit code \(r.code))") : err }
                return .failure(.fs(RemoteFSError(message: msg)))
            }
            return .success(String(data: r.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        }
    }

    /// Run a sh script through sudo.
    /// With no password, use sudo -n and return .passwordRequired if a password is necessary.
    /// With a password, validate separately using sudo -S -v; incorrect-password retries consume stdin and would otherwise swallow file data.
    /// After validation, execute with sudo -S using one password line followed by data; sudo reads only through the newline.
    /// Send the password only through stdin, never the command line/process list.
    private func runSudo(_ script: String, password: String?, stdin: Data?, timeout: Double) async -> Result<OpResult, SudoFailure> {
        let quoted = "'" + script.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let r: OpResult
        if let password {
            let pw = Data((password + "\n").utf8)
            let v = await run("sudo -S -p '' -v", stdin: pw, timeout: 15)
            if v.code != 0 { return .failure(Self.sudoFailure(v.stderr) ?? .wrongPassword) }
            var input = pw
            if let stdin { input.append(stdin) }
            r = await run("sudo -S -p '' sh -c \(quoted)", stdin: input, timeout: timeout)
        } else {
            r = await run("sudo -n sh -c \(quoted)", stdin: stdin, timeout: timeout)
        }
        if r.code != 0, let f = Self.sudoFailure(r.stderr) { return .failure(f) }
        return .success(r)
    }

    /// Identify sudo's own failures in stderr, separately from script failures.
    private static func sudoFailure(_ stderr: Data) -> SudoFailure? {
        let err = String(data: stderr, encoding: .utf8) ?? ""
        let lower = err.lowercased()
        if lower.contains("must have a tty") || lower.contains("requiretty") { return .requiresTTY }
        if lower.contains("password is required") || lower.contains("terminal is required") || lower.contains("askpass") {
            return .passwordRequired
        }
        if lower.contains("incorrect password") || lower.contains("sorry, try again") || lower.contains("no password was provided") {
            return .wrongPassword
        }
        if lower.contains("not in the sudoers") || lower.contains("not allowed to") || lower.contains("may not run sudo") {
            return .notPermitted(String(localized: "This account isn't allowed to use sudo on the server."))
        }
        if lower.contains("sudo: command not found") || lower.contains("sudo: not found") {
            return .notPermitted(String(localized: "sudo isn't installed on the server."))
        }
        return nil
    }

    // MARK: - File management (delete / rename / permissions)

    /// Delete files/directories. SFTP v3 lacks recursive directory deletion, so directories always use shell rm -rf (review R19).
    /// Shell directory deletion may be slow and supports cancellation through handle; SFTP file deletion is immediate and does not use handle.
    func delete(_ path: String, isDir: Bool, handle: CommandHandle? = nil) async -> Result<Void, RemoteFSError> {
        if isLocal { return await LocalFS.delete(path) }
        if isDir { return await deleteViaShell(path, isDir: true, handle: handle) }
        if isSftpUsable {
            do { try await session().remove(path); return .success(()) }
            catch let e as SFTPError where e.isTransport { markSftpDown() }
            catch let e as SFTPError {
                return .failure(RemoteFSError(message: e.isPermission ? String(localized: "No delete permission")
                    : (e.isNoSuchFile ? String(localized: "File Doesn't Exist") : e.message)))
            }
            catch { return .failure(RemoteFSError(message: String(localized: "Delete failed"))) }
        }
        return await deleteViaShell(path, isDir: false, handle: handle)
    }
    private func deleteViaShell(_ path: String, isDir: Bool,
                               handle: CommandHandle? = nil) async -> Result<Void, RemoteFSError> {
        let b64 = Data(path.utf8).base64EncodedString()
        let rm = isDir ? "rm -rf" : "rm -f"
        let cmd = "P=$(printf %s '\(b64)'|base64 -d); \(rm) -- \"$P\""
        let r = await run(cmd, handle: handle)
        if r.code != 0 {
            let err = String(data: r.stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let msg = err.localizedCaseInsensitiveContains("permission") ? String(localized: "No delete permission")
                : (err.isEmpty ? String(localized: "Delete failed (exit code \(r.code))") : err)
            return .failure(RemoteFSError(message: msg))
        }
        return .success(())
    }

    /// Rename/move, refusing existing destinations to prevent overwriting.
    func rename(_ from: String, to: String) async -> Result<Void, RemoteFSError> {
        if isLocal { return await LocalFS.rename(from, to: to) }
        if isSftpUsable {
            do {
                if try await sftpStatOrNil(to) != nil { return .failure(RemoteFSError(message: String(localized: "Target name already exists"))) }
                try await session().rename(from: from, to: to)
                return .success(())
            }
            catch let e as SFTPError where e.isTransport { markSftpDown() }
            catch let e as SFTPError {
                // SFTP v3 RENAME does not overwrite; an existing target usually returns FAILURE.
                return .failure(RemoteFSError(message: e.isPermission ? String(localized: "No rename permission") : String(localized: "Target name already exists")))
            }
            catch { return .failure(RemoteFSError(message: String(localized: "Rename Failed"))) }
        }
        return await renameViaShell(from, to: to)
    }
    private func renameViaShell(_ from: String, to: String) async -> Result<Void, RemoteFSError> {
        let bf = Data(from.utf8).base64EncodedString()
        let bt = Data(to.utf8).base64EncodedString()
        let cmd = "F=$(printf %s '\(bf)'|base64 -d); T=$(printf %s '\(bt)'|base64 -d); " +
            "if [ -e \"$T\" ]; then echo __SERVERDOCK_EXISTS__ >&2; exit 9; fi; mv -- \"$F\" \"$T\""
        let r = await run(cmd)
        if r.code != 0 {
            let err = String(data: r.stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let msg: String
            if err.contains("__SERVERDOCK_EXISTS__") { msg = String(localized: "Target name already exists") }
            else if err.localizedCaseInsensitiveContains("permission") { msg = String(localized: "No rename permission") }
            else { msg = err.isEmpty ? String(localized: "Rename failed (exit code \(r.code))") : err }
            return .failure(RemoteFSError(message: msg))
        }
        return .success(())
    }

    /// Change permissions using an octal mode string, e.g. "755".
    func chmod(_ path: String, mode: String) async -> Result<Void, RemoteFSError> {
        if isLocal { return await LocalFS.chmod(path, mode: mode) }
        if isSftpUsable {
            guard let m = UInt32(mode, radix: 8) else { return .failure(RemoteFSError(message: String(localized: "Invalid permission value"))) }
            do { try await session().setPermissions(path, m); return .success(()) }
            catch let e as SFTPError where e.isTransport { markSftpDown() }
            catch let e as SFTPError { return .failure(RemoteFSError(message: e.isPermission ? String(localized: "No permission to change permissions") : e.message)) }
            catch { return .failure(RemoteFSError(message: String(localized: "Failed to change permissions"))) }
        }
        return await chmodViaShell(path, mode: mode)
    }
    private func chmodViaShell(_ path: String, mode: String) async -> Result<Void, RemoteFSError> {
        let b64 = Data(path.utf8).base64EncodedString()
        let cmd = "P=$(printf %s '\(b64)'|base64 -d); chmod \(mode) -- \"$P\""
        let r = await run(cmd)
        if r.code != 0 {
            let err = String(data: r.stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let msg = err.localizedCaseInsensitiveContains("permission") ? String(localized: "No permission to change permissions")
                : (err.isEmpty ? String(localized: "Failed to change permissions (exit code \(r.code))") : err)
            return .failure(RemoteFSError(message: msg))
        }
        return .success(())
    }

    /// Whether the path exists.
    func exists(_ path: String) async -> Bool {
        if isLocal { return LocalFS.exists(path) }
        if isSftpUsable {
            do { _ = try await session().stat(path); return true }
            catch let e as SFTPError where e.isNoSuchFile { return false }
            catch let e as SFTPError where e.isTransport { markSftpDown(); return await existsViaShell(path) }
            catch { return false }
        }
        return await existsViaShell(path)
    }
    private func existsViaShell(_ path: String) async -> Bool {
        let b64 = Data(path.utf8).base64EncodedString()
        let r = await run("P=$(printf %s '\(b64)'|base64 -d); [ -e \"$P\" ] && echo __Y__ || echo __N__")
        return (String(data: r.data, encoding: .utf8) ?? "").contains("__Y__")
    }

    /// Current permissions: low 12 octal bits, including setuid/setgid/sticky.
    func statPerms(_ path: String) async -> Result<Int, RemoteFSError> {
        if isLocal { return await LocalFS.statPerms(path) }
        if isSftpUsable {
            do {
                guard let p = (try await session().stat(path)).permissions else {
                    return .failure(RemoteFSError(message: String(localized: "Couldn't read permissions")))
                }
                return .success(Int(p & 0o7777))
            }
            catch let e as SFTPError where e.isTransport { markSftpDown() }
            catch { return .failure(RemoteFSError(message: String(localized: "Couldn't read permissions"))) }
        }
        return await statPermsViaShell(path)
    }
    private func statPermsViaShell(_ path: String) async -> Result<Int, RemoteFSError> {
        let b64 = Data(path.utf8).base64EncodedString()
        let cmd = "P=$(printf %s '\(b64)'|base64 -d); stat -c '%a' \"$P\" 2>/dev/null || stat -f '%Lp' \"$P\" 2>/dev/null"
        let r = await run(cmd)
        let s = String(data: r.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard r.code == 0, let v = Int(s, radix: 8) else {
            return .failure(RemoteFSError(message: String(localized: "Couldn't read permissions")))
        }
        return .success(v)
    }

    /// Disconnect the host's shared ControlMaster connection underlying file browsing.
    /// Close idle warm libssh2 pooled connections for this host, replacing ControlMaster's ssh -O exit.
    /// Called when no host tabs remain or the network changes, promptly releasing sockets and remote processes.
    /// Close only idle pooled connections, leaving borrowed/running sessions alone. Each SFTP instance owns a dedicated connection reclaimed by shutdown.
    func closeMaster() {
        if isLocal { return }
        SSHSessionPool.shared.closeHost(ssh)
    }

    /// Absolute home directory of the login user.
    func home() async -> String {
        if isLocal { return LocalFS.home() }
        if isSftpUsable {
            do { let p = try await session().realpath("."); return p.isEmpty ? "/" : p }
            catch let e as SFTPError where e.isTransport { markSftpDown() }
            catch { /* Operation-level failure: fall back to shell. */ }
        }
        return await homeViaShell()
    }
    private func homeViaShell() async -> String {
        let r = await run("cd && pwd")
        let s = String(data: r.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return s.isEmpty ? "/" : s
    }

    func list(_ path: String) async -> Result<[RemoteFile], RemoteFSError> {
        if isLocal { return await LocalFS.list(path) }
        if isSftpUsable {
            do { return .success(try await sftpList(path)) }
            catch let e as SFTPError where e.isTransport { markSftpDown() }
            catch let e as SFTPError {
                return .failure(RemoteFSError(message: e.isNoSuchFile ? String(localized: "Directory doesn't exist")
                    : (e.isPermission ? String(localized: "No access permission") : e.message)))
            }
            catch { return .failure(RemoteFSError(message: String(localized: "Failed to list directory"))) }
        }
        return await listViaShell(path)
    }

    private func sftpList(_ path: String) async throws -> [RemoteFile] {
        let s = session()
        let h = try await s.opendir(path)
        var files: [RemoteFile] = []
        do {
            while let batch = try await s.readdir(h) {
                for (name, attrs) in batch where name != "." && name != ".." {
                    files.append(RemoteFile(
                        name: name, path: join(path, name),
                        kind: kindFromMode(attrs.permissions),
                        size: Int64(attrs.size ?? 0),
                        modified: attrs.mtime.map { Date(timeIntervalSince1970: TimeInterval($0)) }))
                }
            }
            await s.closeHandle(h)
        } catch {
            await s.closeHandle(h); throw error
        }
        return sorted(files)
    }

    /// List an absolute directory, preferring GNU find -printf for size/time and falling back to ls -1Ap for names/types.
    private func listViaShell(_ path: String) async -> Result<[RemoteFile], RemoteFSError> {
        let b64 = Data(path.utf8).base64EncodedString()
        // Primary path: GNU find with NUL-separated records containing type, bytes, mtime seconds, and basename separated by tabs.
        let gnu = "P=$(printf %s '\(b64)'|base64 -d); " +
            "find \"$P\" -maxdepth 1 -mindepth 1 -printf '%y\\t%s\\t%Ts\\t%f\\0' 2>/dev/null"
        var r = await run(gnu)
        if r.code == 0, !r.data.isEmpty {
            return .success(sorted(parseFind(r.data, base: path)))
        }
        if r.code == 0, r.data.isEmpty {
            // An empty result may mean an empty directory or unsupported find; use ls to distinguish them.
        }
        // BSD-compatible fallback: ls -1Ap, providing names and trailing directory slashes only.
        let fb = "P=$(printf %s '\(b64)'|base64 -d); ls -1Ap -- \"$P\""
        r = await run(fb)
        if r.code == 0 {
            return .success(sorted(parseLs(r.data, base: path)))
        }
        let err = String(data: r.stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return .failure(RemoteFSError(message: err.isEmpty ? String(localized: "Couldn't list directory (exit code \(r.code))") : err))
    }

    // MARK: - Parsing

    private func parseFind(_ data: Data, base: String) -> [RemoteFile] {
        var out: [RemoteFile] = []
        for rec in data.split(separator: 0, omittingEmptySubsequences: true) {
            guard let s = String(data: Data(rec), encoding: .utf8) else { continue }
            let p = s.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
            guard p.count == 4 else { continue }
            let name = String(p[3])
            let kind: RemoteFile.Kind
            switch p[0] {
            case "d": kind = .directory
            case "f": kind = .file
            case "l": kind = .symlink
            default: kind = .other
            }
            let size = Int64(p[1]) ?? 0
            let mtime = Double(p[2]).map { Date(timeIntervalSince1970: $0) }
            out.append(RemoteFile(name: name, path: join(base, name), kind: kind, size: size, modified: mtime))
        }
        return out
    }

    private func parseLs(_ data: Data, base: String) -> [RemoteFile] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var out: [RemoteFile] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            var name = String(raw)
            var kind: RemoteFile.Kind = .file
            if name.hasSuffix("/") { name.removeLast(); kind = .directory }
            else if name.hasSuffix("@") { name.removeLast(); kind = .symlink }
            if name.isEmpty || name == "." || name == ".." { continue }
            out.append(RemoteFile(name: name, path: join(base, name), kind: kind, size: 0, modified: nil))
        }
        return out
    }

    private func sorted(_ files: [RemoteFile]) -> [RemoteFile] {
        files.sorted { a, b in
            if a.isDir != b.isDir { return a.isDir }   // Directories first.
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    private func join(_ base: String, _ name: String) -> String {
        base == "/" ? "/" + name : base + "/" + name
    }
}

/// Format a byte count as a human-readable file size.
func humanSize(_ bytes: Int64) -> String {
    guard bytes > 0 else { return "—" }
    let units = ["B", "K", "M", "G", "T"]
    var v = Double(bytes); var i = 0
    while v >= 1024, i < units.count - 1 { v /= 1024; i += 1 }
    return i == 0 ? "\(bytes) B" : String(format: "%.1f%@", v, units[i])
}

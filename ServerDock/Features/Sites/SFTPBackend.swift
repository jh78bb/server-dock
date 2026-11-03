import Foundation

/// SFTP backend reuses built-in libssh2 RemoteFS with password/private-key authentication.
/// Use real absolute server paths from /; initial path is configured start or login home.
final class SFTPBackend: SiteBackend {
    private let site: Site
    private let fs: RemoteFS

    init(site: Site, secret: String) {
        self.site = site
        var c = SSHConnection()
        c.user = site.username
        c.host = site.host.trimmingCharacters(in: .whitespaces)
        c.port = site.port > 0 ? site.port : 22
        c.password = secret                      // Password for password auth, passphrase for key auth.
        c.authMethod = site.keyPath.isEmpty ? .password : .key
        c.keyPath = (site.keyPath as NSString).expandingTildeInPath
        c.useBuiltinSSH = true                   // Built-in libssh2, not system ssh.
        fs = RemoteFS(c)
    }

    private func unwrap<T>(_ r: Result<T, RemoteFSError>) throws -> T {
        switch r {
        case .success(let v): return v
        case .failure(let e): throw SiteError(e.message)
        }
    }

    func connect() async throws { _ = try unwrap(await fs.list("/")) }

    func initialPath() async -> String {
        let start = site.path.trimmingCharacters(in: .whitespaces)
        return start.isEmpty ? await fs.home() : SitePath.normalize(start)
    }

    func list(_ path: String) async throws -> [SiteEntry] {
        try unwrap(await fs.list(SitePath.normalize(path))).map {
            SiteEntry(name: $0.name, path: $0.path, isDir: $0.isDir,
                      size: $0.size, modified: $0.modified)
        }
    }

    func download(_ entry: SiteEntry, to local: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        try await transfer(total: entry.size, progress: progress) { control in
            await self.fs.download(entry.path, to: local, control: control)
        }
    }

    func upload(_ local: URL, to path: String, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let total = (try? FileManager.default.attributesOfItem(atPath: local.path)[.size] as? Int64) ?? 0
        try await transfer(total: total, progress: progress) { control in
            await self.fs.upload(localURL: local, toRemote: path, startOffset: 0, control: control)
        }
        try unwrap(await fs.finalizeUpload(remotePath: path))   // Atomically replace .part with the final name.
    }

    /// Bridge RemoteFS cancellation/progress, periodically reading UploadControl.sent.
    private func transfer(total: Int64, progress: @escaping @Sendable (Int64, Int64) -> Void,
                          _ op: @escaping (UploadControl) async -> UploadOutcome) async throws {
        let control = UploadControl()
        let poller = Task {
            while !Task.isCancelled {
                progress(control.sent, total)
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
        defer { poller.cancel() }
        let outcome = await withTaskCancellationHandler { await op(control) } onCancel: { control.set(.cancel) }
        switch outcome {
        case .completed: progress(total, total)
        case .cancelled, .paused: throw CancellationError()
        case .failed(let m): throw SiteError(m)
        }
    }

    func makeDirectory(_ path: String) async throws { try unwrap(await fs.mkdir(SitePath.normalize(path))) }

    func delete(_ entry: SiteEntry) async throws { try unwrap(await fs.delete(entry.path, isDir: entry.isDir)) }

    func rename(_ entry: SiteEntry, to newPath: String) async throws { try unwrap(await fs.rename(entry.path, to: newPath)) }

    func disconnect() async { fs.closeSession(); fs.closeMaster() }
}

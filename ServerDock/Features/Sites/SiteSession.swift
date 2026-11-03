import Foundation
import AppKit

/// Upload/download state shown in the site's bottom transfer list.
struct SiteTransfer: Identifiable {
    enum Direction { case download, upload }
    enum State: Equatable { case running, done, failed(String), cancelled }
    let id = UUID()
    let name: String
    let direction: Direction
    var done: Int64 = 0
    var total: Int64 = 0
    var state: State = .running

    var fraction: Double { total > 0 ? min(1, Double(done) / Double(total)) : 0 }
}

/// Site-tab navigation, entries, selection, transfers, and backend operations.
@MainActor
final class SiteSession: ObservableObject {
    let site: Site
    private let backend: SiteBackend

    @Published private(set) var path = "/"
    @Published private(set) var entries: [SiteEntry] = []
    @Published private(set) var phase: LoadPhase = .loading
    @Published var transfers: [SiteTransfer] = []
    @Published var notice: String?          // One-shot delete/rename operation errors.

    private var loadTask: Task<Void, Never>?
    private var transferTasks: [UUID: Task<Void, Never>] = [:]
    private var loadGeneration = 0

    init(site: Site) {
        self.site = site
        self.backend = SiteBackendFactory.make(site, secret: SiteKeychain.secret(site.id))
    }

    var supportsRename: Bool { backend.supportsRename }
    var isRoot: Bool { path == "/" }
    /// Whether this is the bucket list at a bucketless S3 site's root.
    var isBucketList: Bool { site.kind == .s3 && site.path.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")).isEmpty && path == "/" }

    // MARK: Navigation

    func start() {
        Task { [weak self] in
            guard let self else { return }
            // Open the backend's initial path, e.g. SFTP home; navigate reports connection failures.
            let initial = (try? await backend.connect()) != nil ? await backend.initialPath() : "/"
            navigate(to: initial)
        }
    }
    func refresh() { navigate(to: path) }
    func goUp() { navigate(to: SitePath.parent(path)) }

    func navigate(to newPath: String) {
        let target = SitePath.normalize(newPath)
        loadTask?.cancel()
        loadGeneration += 1
        let gen = loadGeneration
        phase = .loading
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await backend.connect()
                let items = try await backend.list(target)
                guard gen == self.loadGeneration else { return }
                self.path = target
                self.entries = items
                self.phase = .loaded
            } catch is CancellationError {
            } catch {
                guard gen == self.loadGeneration else { return }
                self.path = target
                self.entries = []
                self.phase = .error(error.localizedDescription)
            }
        }
    }

    func entry(_ id: String) -> SiteEntry? { entries.first { $0.id == id } }

    // MARK: File operations

    func makeFolder(_ name: String) {
        guard let n = Self.validName(name) else { notice = String(localized: "Invalid folder name."); return }
        run { [self] in try await backend.makeDirectory(SitePath.join(path, n)) }
    }

    func rename(_ e: SiteEntry, to name: String) {
        guard let n = Self.validName(name) else { notice = String(localized: "Invalid name."); return }
        guard n != e.name else { return }
        run { [self] in try await backend.rename(e, to: SitePath.join(SitePath.parent(e.path), n)) }
    }

    func delete(_ items: [SiteEntry]) {
        run { [self] in for e in items { try await backend.delete(e) } }
    }

    /// Execute and refresh the list; report failures as notices.
    private func run(_ op: @escaping () async throws -> Void) {
        Task { [weak self] in
            guard let self else { return }
            do { try await op() } catch is CancellationError {} catch { self.notice = error.localizedDescription }
            self.refresh()
        }
    }

    private static func validName(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.isEmpty || t.contains("/") || t == "." || t == ".." ? nil : t
    }

    // MARK: Transfers

    /// Download selection into folder, recursively for directories.
    func download(_ items: [SiteEntry], to folder: URL) {
        startTransferBatch { [self] add in
            for e in items { try await downloadRecursive(e, into: folder, add: add) }
        }
    }

    private func downloadRecursive(_ e: SiteEntry, into dir: URL, add: @escaping (String, SiteTransfer.Direction) -> UUID) async throws {
        try Task.checkCancellation()
        let dst = dir.appendingPathComponent(e.name)
        if e.isDir {
            try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
            for child in try await backend.list(e.path) { try await downloadRecursive(child, into: dst, add: add) }
        } else {
            let tid = add(e.name, .download)
            try await track(tid) { progress in try await self.backend.download(e, to: dst, progress: progress) }
        }
    }

    /// Upload local files/folders into cwd, recursively for directories.
    func upload(_ urls: [URL]) {
        let base = path
        startTransferBatch(refresh: true) { [self] add in
            for u in urls { try await uploadRecursive(u, into: base, add: add) }
        }
    }

    private func uploadRecursive(_ u: URL, into dir: String, add: @escaping (String, SiteTransfer.Direction) -> UUID) async throws {
        try Task.checkCancellation()
        let remote = SitePath.join(dir, u.lastPathComponent)
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir)
        if isDir.boolValue {
            try await backend.makeDirectory(remote)
            for c in try FileManager.default.contentsOfDirectory(at: u, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                try await uploadRecursive(c, into: remote, add: add)
            }
        } else {
            let tid = add(u.lastPathComponent, .upload)
            try await track(tid) { progress in try await self.backend.upload(u, to: remote, progress: progress) }
        }
    }

    private func startTransferBatch(refresh: Bool = false, _ body: @escaping (@escaping (String, SiteTransfer.Direction) -> UUID) async throws -> Void) {
        let batchId = UUID()
        let add: (String, SiteTransfer.Direction) -> UUID = { [weak self] name, dir in
            let t = SiteTransfer(name: name, direction: dir)
            self?.transfers.append(t)
            return t.id
        }
        let task = Task { [weak self] in
            guard let self else { return }
            do { try await body(add) } catch is CancellationError {} catch { self.notice = error.localizedDescription }
            self.transferTasks[batchId] = nil
            if refresh { self.refresh() }
        }
        transferTasks[batchId] = task
    }

    /// Wrap one transfer to record progress and completion state.
    private func track(_ id: UUID, _ op: @escaping (@escaping @Sendable (Int64, Int64) -> Void) async throws -> Void) async throws {
        let progress: @Sendable (Int64, Int64) -> Void = { [weak self] done, total in
            Task { @MainActor in self?.updateTransfer(id, done: done, total: total) }
        }
        do {
            try await op(progress)
            setTransfer(id) { $0.state = .done; if $0.total > 0 { $0.done = $0.total } }
        } catch is CancellationError {
            setTransfer(id) { $0.state = .cancelled }
            throw CancellationError()
        } catch {
            setTransfer(id) { $0.state = .failed(error.localizedDescription) }
            throw error
        }
    }

    private func updateTransfer(_ id: UUID, done: Int64, total: Int64) {
        setTransfer(id) { if $0.state == .running { $0.done = done; $0.total = max(total, 0) } }
    }

    private func setTransfer(_ id: UUID, _ f: (inout SiteTransfer) -> Void) {
        guard let i = transfers.firstIndex(where: { $0.id == id }) else { return }
        f(&transfers[i])
    }

    func cancelTransfers() {
        for t in transferTasks.values { t.cancel() }
        for i in transfers.indices where transfers[i].state == .running { transfers[i].state = .cancelled }
    }

    func clearFinishedTransfers() { transfers.removeAll { $0.state != .running } }
    var hasRunningTransfer: Bool { transfers.contains { $0.state == .running } }

    // MARK: Opening

    /// Download temporarily and open with the default app; changes do not sync back.
    func openWithDefaultApp(_ e: SiteEntry) {
        guard !e.isDir else { navigate(to: e.path); return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("serverdock-site-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dst = dir.appendingPathComponent(e.name)
        startTransferBatch { [self] add in
            let tid = add(e.name, .download)
            try await track(tid) { progress in try await self.backend.download(e, to: dst, progress: progress) }
            NSWorkspace.shared.open(dst)
        }
    }

    // MARK: Closing

    func close() {
        loadTask?.cancel()
        for t in transferTasks.values { t.cancel() }
        let b = backend
        Task { await b.disconnect() }
    }
}

import Foundation
import SwiftUI

/// Docker tab state runs commands through existing SSH/RemoteFS.run, requiring no exposed daemon TCP port.
@MainActor
final class DockerSession: ObservableObject {
    enum Phase: Equatable {
        case loading
        case ready
        case notInstalled
        case permissionDenied(String)   // Insufficient permissions, e.g. not in the docker group.
        case daemonDown(String)         // Daemon is not running.
        case failed(String)
    }

    let host: Host
    private let fs: RemoteFS
    /// Installed docker/podman engines.
    let engines: [String]

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var containers: [DockerContainer] = []
    @Published private(set) var busyIds = Set<String>()
    @Published private(set) var refreshing = false
    @Published var notice: String?                 // Last operation output/error shown in a dismissible banner.
    @Published var inspectText: (name: String, text: String)?

    /// Per-host preference to run docker through passwordless sudo.
    @Published var useSudo: Bool { didSet { UserDefaults.standard.set(useSudo, forKey: sudoKey) } }
    /// Optional docker stats CPU/memory sampling adds some server load.
    @Published var showStats: Bool { didSet { UserDefaults.standard.set(showStats, forKey: "dockerStats") } }
    @Published var autoRefresh: Bool { didSet { UserDefaults.standard.set(autoRefresh, forKey: "dockerAutoRefresh") } }

    private var sudoKey: String { "dockerSudo." + host.id }
    private var loop: Task<Void, Never>?
    private var generation = 0

    /// Choose between installed engines, remembering the host preference.
    @Published var engine: String { didSet { UserDefaults.standard.set(engine, forKey: "containerEngine." + host.id); containers = []; images = []; refresh() } }
    @Published private(set) var images: [DockerImage] = []
    @Published private(set) var imageBusy = false

    init(host: Host, engines: [String] = ["docker"]) {
        self.host = host
        self.engines = engines.isEmpty ? ["docker"] : engines
        let saved = UserDefaults.standard.string(forKey: "containerEngine." + host.id) ?? ""
        self.engine = self.engines.contains(saved) ? saved : (self.engines.first ?? "docker")
        self.fs = RemoteFS(host.ssh ?? SSHConnection())
        let d = UserDefaults.standard
        useSudo = d.bool(forKey: "dockerSudo." + host.id)
        showStats = d.object(forKey: "dockerStats") as? Bool ?? true
        autoRefresh = d.object(forKey: "dockerAutoRefresh") as? Bool ?? true
    }

    // MARK: Auto-refresh (visible tabs only)

    func startAutoRefresh() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard let self, !Task.isCancelled else { return }
                if self.autoRefresh, self.phase == .ready, self.busyIds.isEmpty { await self.load() }
            }
        }
    }

    func stopAutoRefresh() { loop?.cancel(); loop = nil }

    func stop() { stopAutoRefresh(); generation &+= 1; fs.closeSession() }

    // MARK: Lists

    func refresh() { Task { await load(showSpinner: true) } }

    private func load(showSpinner: Bool = false) async {
        if refreshing { return }
        refreshing = true
        if showSpinner, containers.isEmpty { phase = .loading }
        generation &+= 1
        let gen = generation
        let r = await fs.run(DockerCommands.psScript(sudo: useSudo, engine: engine), timeout: 30)
        defer { refreshing = false }
        guard gen == generation else { return }
        let out = String(decoding: r.data, as: UTF8.self)
        let err = String(decoding: r.stderr, as: UTF8.self)
        if out.contains("__NODOCKER__") || r.code == 127 { containers = []; phase = .notInstalled; return }
        if r.code != 0 {
            let text = (out + "\n" + err).trimmingCharacters(in: .whitespacesAndNewlines)
            containers = []
            phase = Self.classify(text)
            return
        }
        var list = out.split(whereSeparator: \.isNewline).compactMap { DockerContainer.parse(psLine: String($0)) }
        // Retain previous stats to avoid flicker.
        let old = Dictionary(uniqueKeysWithValues: containers.map { ($0.id, $0) })
        for i in list.indices { if let o = old[list[i].id] { list[i].cpu = o.cpu; list[i].memUsage = o.memUsage; list[i].memPercent = o.memPercent } }
        containers = list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        phase = .ready
        if showStats, list.contains(where: \.isRunning) { Task { await loadStats(gen: gen) } }
    }

    private func loadStats(gen: Int) async {
        let r = await fs.run(DockerCommands.statsScript(sudo: useSudo, engine: engine), timeout: 40)
        guard gen == generation, r.code == 0 else { return }
        let stats = String(decoding: r.data, as: UTF8.self).split(whereSeparator: \.isNewline)
            .compactMap { DockerContainer.parse(statsLine: String($0)) }
        let byName = Dictionary(stats.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        for i in containers.indices {
            if let s = byName[containers[i].name] { containers[i].cpu = s.cpu; containers[i].memUsage = s.mem; containers[i].memPercent = s.memPct }
            else if !containers[i].isRunning { containers[i].cpu = ""; containers[i].memUsage = ""; containers[i].memPercent = "" }
        }
    }

    /// Classify errors as permissions, stopped daemon, or other.
    static func classify(_ text: String) -> Phase {
        let l = text.lowercased()
        if l.contains("permission denied") || l.contains("a password is required") || l.contains("a terminal is required")
            || l.contains("not in the sudoers") { return .permissionDenied(text) }
        if l.contains("cannot connect to the docker daemon") || l.contains("is the docker daemon running")
            || l.contains("connection refused") || l.contains("no such file or directory") && l.contains("docker.sock") {
            return .daemonDown(text)
        }
        return .failed(text.isEmpty ? String(localized: "Docker returned an error.") : text)
    }

    // MARK: Actions

    /// Apply container actions and refresh; show Docker failure output in a banner.
    func perform(_ action: DockerAction, on items: [DockerContainer]) {
        guard !items.isEmpty else { return }
        let ids = items.map(\.id)
        busyIds.formUnion(ids)
        Task {
            let timeout: Double = action == .stop || action == .restart ? 30 + 15 * Double(ids.count) : 60
            let r = await fs.run(DockerCommands.action(action, ids: ids, sudo: useSudo, engine: engine), timeout: timeout)
            busyIds.subtract(ids)
            if r.code != 0 {
                let text = (String(decoding: r.data, as: UTF8.self) + String(decoding: r.stderr, as: UTF8.self))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                notice = text.isEmpty ? String(localized: "\(action.title) failed.") : text
            }
            await load()
        }
    }

    func inspect(_ c: DockerContainer) {
        Task {
            let r = await fs.run(DockerCommands.inspect(id: c.id, sudo: useSudo, engine: engine), timeout: 30)
            let text = String(decoding: r.data, as: UTF8.self) + String(decoding: r.stderr, as: UTF8.self)
            inspectText = (c.name, text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    // MARK: Images

    func loadImages() {
        Task {
            let r = await fs.run(DockerCommands.imagesScript(sudo: useSudo, engine: engine), timeout: 30)
            guard r.code == 0 else {
                notice = (String(decoding: r.data, as: UTF8.self) + String(decoding: r.stderr, as: UTF8.self)).trimmingCharacters(in: .whitespacesAndNewlines)
                return
            }
            images = String(decoding: r.data, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap { DockerImage.parse(String($0)) }
                .sorted { $0.reference.localizedStandardCompare($1.reference) == .orderedAscending }
        }
    }

    /// Shared image-operation runner reports output and refreshes after pull/remove/prune/create.
    private func runImageOp(_ script: String, timeout: Double, success: String? = nil) {
        imageBusy = true
        Task {
            let r = await fs.run(script, timeout: timeout)
            imageBusy = false
            let out = (String(decoding: r.data, as: UTF8.self) + String(decoding: r.stderr, as: UTF8.self)).trimmingCharacters(in: .whitespacesAndNewlines)
            if r.code != 0 { notice = out.isEmpty ? String(localized: "The command failed.") : out }
            else if let success { notice = nil; _ = success }
            loadImages()
            await load()
        }
    }

    func pull(_ ref: String) { runImageOp(DockerCommands.pull(ref, sudo: useSudo, engine: engine), timeout: 600) }
    func removeImages(_ items: [DockerImage], force: Bool) { runImageOp(DockerCommands.removeImages(ids: items.map(\.id), force: force, sudo: useSudo, engine: engine), timeout: 120) }
    func pruneImages() { runImageOp(DockerCommands.pruneImages(sudo: useSudo, engine: engine), timeout: 120) }
    func run(_ spec: RunSpec) { runImageOp(DockerCommands.runScript(spec, sudo: useSudo, engine: engine), timeout: 300) }
}

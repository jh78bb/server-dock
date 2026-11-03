import Foundation
import SwiftUI

/// Service-tab state runs systemctl through existing SSH/RemoteFS.run.
@MainActor
final class ServiceSession: ObservableObject {
    enum Phase: Equatable {
        case loading, ready, notAvailable
        case failed(String)
    }

    let host: Host
    private let fs: RemoteFS

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var services: [SystemdService] = []
    @Published private(set) var busy = Set<String>()
    @Published private(set) var refreshing = false
    @Published var notice: String?
    @Published var statusText: (name: String, text: String)?

    /// Remember per-host passwordless-sudo preference for mutations.
    @Published var useSudo: Bool { didSet { UserDefaults.standard.set(useSudo, forKey: "serviceSudo." + host.id) } }
    @Published var autoRefresh: Bool { didSet { UserDefaults.standard.set(autoRefresh, forKey: "serviceAutoRefresh") } }

    private var loop: Task<Void, Never>?

    init(host: Host) {
        self.host = host
        self.fs = RemoteFS(host.ssh ?? SSHConnection())
        useSudo = UserDefaults.standard.bool(forKey: "serviceSudo." + host.id)
        autoRefresh = UserDefaults.standard.object(forKey: "serviceAutoRefresh") as? Bool ?? true
    }

    var failedCount: Int { services.filter(\.isFailed).count }
    var runningCount: Int { services.filter(\.isRunning).count }

    func startAutoRefresh() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard let self, !Task.isCancelled else { return }
                if self.autoRefresh, self.phase == .ready, self.busy.isEmpty { await self.load() }
            }
        }
    }
    func stopAutoRefresh() { loop?.cancel(); loop = nil }
    func stop() { stopAutoRefresh(); fs.closeSession() }

    func refresh() { Task { await load(spinner: true) } }

    private func load(spinner: Bool = false) async {
        if refreshing { return }
        refreshing = true
        if spinner, services.isEmpty { phase = .loading }
        defer { refreshing = false }
        let r = await fs.run(ServiceCommands.listScript(), timeout: 30)
        let out = String(decoding: r.data, as: UTF8.self)
        if out.contains("__NOSYSTEMD__") || r.code == 127 { services = []; phase = .notAvailable; return }
        guard r.code != -1 else {
            phase = .failed(String(decoding: r.stderr, as: UTF8.self)); return
        }
        let parts = out.components(separatedBy: ServiceCommands.marker)
        let units = (parts.first ?? "").split(whereSeparator: \.isNewline).compactMap { SystemdService.parse(unitLine: String($0)) }
        var files: [String: String] = [:]
        if parts.count > 1 {
            for l in parts[1].split(whereSeparator: \.isNewline) { if let (n, s) = SystemdService.parse(fileLine: String(l)) { files[n] = s } }
        }
        services = SystemdService.merge(units: units, files: files)
        phase = .ready
    }

    /// Apply service actions and refresh; show errors and sudo guidance for permissions.
    func perform(_ action: ServiceAction, on items: [SystemdService]) {
        guard !items.isEmpty else { return }
        let names = items.map(\.name)
        busy.formUnion(names)
        Task {
            let r = await fs.run(ServiceCommands.action(action, names: names, sudo: useSudo), timeout: 60 + 20 * Double(names.count))
            busy.subtract(names)
            if r.code != 0 {
                var text = (String(decoding: r.data, as: UTF8.self) + String(decoding: r.stderr, as: UTF8.self))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let l = text.lowercased()
                if !useSudo, l.contains("access denied") || l.contains("authentication required") || l.contains("permission denied")
                    || l.contains("not privileged") {
                    text += "\n\n" + String(localized: "This account isn't allowed to change services. Turn on the sudo option above if it has passwordless sudo.")
                }
                notice = text.isEmpty ? String(localized: "\(action.title) failed.") : text
            }
            await load()
        }
    }

    func showStatus(_ s: SystemdService) {
        Task {
            let r = await fs.run(ServiceCommands.status(name: s.name, sudo: useSudo), timeout: 30)
            statusText = (s.name, (String(decoding: r.data, as: UTF8.self) + String(decoding: r.stderr, as: UTF8.self)).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

import Foundation
import SwiftUI

/// Process-tab state reads ps and sends kill -s through existing SSH/RemoteFS.run.
@MainActor
final class ProcessSession: ObservableObject {
    enum Phase: Equatable { case loading, ready, failed(String) }

    let host: Host
    private let fs: RemoteFS
    @Published private(set) var phase: Phase = .loading
    @Published private(set) var rows: [ProcessRow] = []
    @Published private(set) var refreshing = false
    @Published private(set) var busy = false
    @Published var notice: String?
    @Published var details: (pid: Int, text: String)?
    @Published private(set) var updatedAt = Date()

    @Published var useSudo: Bool { didSet { UserDefaults.standard.set(useSudo, forKey: "processSudo." + host.id) } }
    @Published var autoRefresh: Bool { didSet { UserDefaults.standard.set(autoRefresh, forKey: "processAutoRefresh") } }
    private var loop: Task<Void, Never>?

    init(host: Host) {
        self.host = host
        fs = RemoteFS(host.ssh ?? SSHConnection())
        useSudo = UserDefaults.standard.bool(forKey: "processSudo." + host.id)
        autoRefresh = UserDefaults.standard.object(forKey: "processAutoRefresh") as? Bool ?? true
    }

    /// Login username for My Processes filtering.
    var loginUser: String { host.isLocal ? NSUserName() : (host.ssh?.user ?? "") }

    func startAutoRefresh() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard let self, !Task.isCancelled else { return }
                if self.autoRefresh, self.phase == .ready, !self.busy { await self.load() }
            }
        }
    }
    func stopAutoRefresh() { loop?.cancel(); loop = nil }
    func stop() { stopAutoRefresh(); fs.closeSession() }

    func refresh() { Task { await load(spinner: true) } }

    private func load(spinner: Bool = false) async {
        if refreshing { return }
        refreshing = true
        if spinner, rows.isEmpty { phase = .loading }
        defer { refreshing = false }
        let r = await fs.run(ProcessCommands.listScript, timeout: 20)
        if r.code == -1 { phase = .failed(String(decoding: r.stderr, as: UTF8.self)); return }
        let out = String(decoding: r.data, as: UTF8.self)
        let parsed = out.split(whereSeparator: \.isNewline).compactMap { ProcessRow.parse(String($0)) }
        guard !parsed.isEmpty else {
            phase = .failed(out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? String(localized: "No process list was returned.") : out)
            return
        }
        rows = parsed
        updatedAt = Date()
        phase = .ready
    }

    /// Signal selected processes, show kill failures/sudo guidance, and refresh.
    func send(_ signal: ProcessSignal, to items: [ProcessRow]) {
        guard !items.isEmpty else { return }
        busy = true
        Task {
            let r = await fs.run(ProcessCommands.kill(signal, pids: items.map(\.pid), sudo: useSudo), timeout: 20)
            busy = false
            if r.code != 0 {
                var text = (String(decoding: r.data, as: UTF8.self) + String(decoding: r.stderr, as: UTF8.self)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !useSudo, text.lowercased().contains("not permitted") || text.lowercased().contains("permission") {
                    text += "\n\n" + String(localized: "Signalling other users' processes needs root. Turn on the sudo option above if this account has passwordless sudo.")
                }
                notice = text.isEmpty ? String(localized: "The signal couldn't be sent.") : text
            }
            await load()
        }
    }

    func showDetails(_ p: ProcessRow) {
        Task {
            let r = await fs.run(ProcessCommands.details(pid: p.pid), timeout: 20)
            details = (p.pid, (String(decoding: r.data, as: UTF8.self) + String(decoding: r.stderr, as: UTF8.self)).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

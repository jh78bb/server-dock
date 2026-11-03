import SwiftUI
import AppKit

/// Execution result for one host.
struct MultiRunResult: Identifiable {
    enum State: Equatable { case waiting, running, done, skipped(String), cancelled }
    let id: String             // hostId
    var name: String
    var state: State = .waiting
    var exitCode: Int32 = 0
    var stdout = ""
    var stderr = ""
    var seconds: Double = 0

    var succeeded: Bool { state == .done && exitCode == 0 }
    var failed: Bool { state == .done && exitCode != 0 }
    var output: String { [stdout, stderr].filter { !$0.isEmpty }.joined(separator: stdout.isEmpty || stderr.isEmpty ? "" : "\n") }
}

/// Run history stores command/targets/per-server summaries, retaining at most 4KB output per server.
struct MultiRunRecord: Codable, Identifiable {
    struct Item: Codable {
        var hostId: String
        var name: String
        var state: String          // done / skipped / cancelled
        var note: String           // Reason for skipped execution.
        var exitCode: Int32
        var seconds: Double
        var stdout: String
        var stderr: String
    }
    var id = UUID()
    var date = Date()
    var command: String
    var items: [Item]
    var ok: Int { items.filter { $0.state == "done" && $0.exitCode == 0 }.count }
    var failed: Int { items.filter { $0.state == "done" && $0.exitCode != 0 }.count }
}

enum MultiRunHistoryStore {
    private static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("serverdock", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("multirun-history.json")
    }
    static func load() -> [MultiRunRecord] {
        guard let d = try? Data(contentsOf: url), let r = try? JSONDecoder().decode([MultiRunRecord].self, from: d) else { return [] }
        return r
    }
    static func save(_ records: [MultiRunRecord]) {
        guard !AppEnv.isScreenshotDemo, let d = try? JSONEncoder().encode(Array(records.prefix(50))) else { return }
        try? d.write(to: url, options: .atomic)
    }
}

/// Run the same command on up to four servers concurrently, grouping results by server.
@MainActor
final class MultiRunModel: ObservableObject {
    @Published var selected = Set<String>()
    @Published var command = ""
    @Published var timeout: Double = 60
    @Published private(set) var results: [MultiRunResult] = []
    @Published private(set) var running = false
    @Published private(set) var history: [MultiRunRecord] = MultiRunHistoryStore.load()
    @Published private(set) var viewingHistory = false     // Viewing saved results, not a rerun.

    private var task: Task<Void, Never>?
    private var handles: [String: CommandHandle] = [:]
    private static let maxOutput = 64 * 1024
    private static let concurrency = 4

    /// Highlight potentially destructive delete/shutdown/format commands in confirmation.
    static func riskyReason(_ cmd: String) -> String? {
        let c = cmd.lowercased()
        let patterns: [(String, String)] = [
            ("rm -rf", "rm -rf"), ("rm -fr", "rm -fr"), ("shutdown", "shutdown"), ("reboot", "reboot"), ("poweroff", "poweroff"),
            ("halt", "halt"), ("mkfs", "mkfs"), ("dd if=", "dd"), ("> /dev/sd", "> /dev/sd"), ("chmod -r 777 /", "chmod -R 777 /"),
            ("systemctl stop", "systemctl stop"), ("userdel", "userdel"), ("drop database", "DROP DATABASE"), ("iptables -f", "iptables -F"),
        ]
        return patterns.first { c.contains($0.0) }?.1
    }

    func run(hosts: [Host]) {
        guard !running else { return }
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return }
        let targets = hosts.filter { selected.contains($0.id) }
        results = targets.map { MultiRunResult(id: $0.id, name: $0.name) }
        running = true
        viewingHistory = false
        let timeout = self.timeout
        task = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                var next = 0
                func launch() {
                    guard next < targets.count, let self else { return }
                    let h = targets[next]; next += 1
                    group.addTask { await self.runOne(h, cmd, timeout: timeout) }
                }
                for _ in 0..<Self.concurrency { launch() }
                while await group.next() != nil { launch() }
            }
            self?.running = false
            self?.recordHistory(command: cmd)
        }
    }

    /// Record finished runs newest-first, capped at 50.
    private func recordHistory(command: String) {
        guard !results.isEmpty, !results.allSatisfy({ $0.state == .cancelled }) else { return }
        let items = results.map { r -> MultiRunRecord.Item in
            var state = "done", note = ""
            switch r.state {
            case .skipped(let why): state = "skipped"; note = why
            case .cancelled, .waiting, .running: state = "cancelled"
            case .done: break
            }
            return MultiRunRecord.Item(hostId: r.id, name: r.name, state: state, note: note, exitCode: r.exitCode, seconds: r.seconds,
                                       stdout: String(r.stdout.prefix(4096)), stderr: String(r.stderr.prefix(4096)))
        }
        history.insert(MultiRunRecord(command: command, items: items), at: 0)
        if history.count > 50 { history.removeLast(history.count - 50) }
        MultiRunHistoryStore.save(history)
    }

    /// Restore history command/targets into the editor and display saved results.
    func load(_ r: MultiRunRecord) {
        command = r.command
        selected = Set(r.items.map(\.hostId))
        results = r.items.map { i in
            var res = MultiRunResult(id: i.hostId, name: i.name)
            switch i.state {
            case "done": res.state = .done
            case "skipped": res.state = .skipped(i.note)
            default: res.state = .cancelled
            }
            res.exitCode = i.exitCode; res.seconds = i.seconds; res.stdout = i.stdout; res.stderr = i.stderr
            return res
        }
        viewingHistory = true
    }

    func deleteRecord(_ id: UUID) { history.removeAll { $0.id == id }; MultiRunHistoryStore.save(history) }
    func clearHistory() { history = []; MultiRunHistoryStore.save(history) }

    private func runOne(_ host: Host, _ cmd: String, timeout: Double) async {
        if Task.isCancelled { update(host.id) { $0.state = .cancelled }; return }
        guard let ssh = host.ssh, !host.isRDP else { update(host.id) { $0.state = .skipped(String(localized: "Not an SSH host")) }; return }
        guard ssh.hasUsableCredentials else {
            update(host.id) { $0.state = .skipped(String(localized: "Password required — open this host once and enter it")) }; return
        }
        update(host.id) { $0.state = .running }
        let handle = CommandHandle()
        setHandle(host.id, handle)
        let start = Date()
        let r = await RemoteFS(ssh).run(cmd, timeout: timeout, handle: handle)
        let secs = Date().timeIntervalSince(start)
        setHandle(host.id, nil)
        update(host.id) { res in
            if handle.isCancelled { res.state = .cancelled; return }
            res.state = .done
            res.exitCode = r.code
            res.seconds = secs
            res.stdout = Self.clip(r.data)
            res.stderr = Self.clip(r.stderr)
            if r.code == -1 && res.stderr.isEmpty { res.stderr = String(localized: "Timed out or connection failed.") }
        }
    }

    private func setHandle(_ id: String, _ h: CommandHandle?) { handles[id] = h }

    private func update(_ id: String, _ f: (inout MultiRunResult) -> Void) {
        guard let i = results.firstIndex(where: { $0.id == id }) else { return }
        f(&results[i])
    }

    private static func clip(_ d: Data) -> String {
        let s = String(decoding: d.prefix(maxOutput), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return d.count > maxOutput ? s + "\n… (\(ByteCountFormatter.string(fromByteCount: Int64(d.count), countStyle: .file)) total, truncated)" : s
    }

    func cancel() {
        task?.cancel()
        for h in handles.values { h.cancel() }
        for i in results.indices where results[i].state == .waiting { results[i].state = .cancelled }
    }

    func retryFailed(hosts: [Host]) {
        let failedIds = Set(results.filter { $0.failed || $0.state == .cancelled }.map(\.id))
        guard !failedIds.isEmpty else { return }
        selected = failedIds
        run(hosts: hosts)
    }

    var summary: (ok: Int, failed: Int, skipped: Int) {
        (results.filter(\.succeeded).count, results.filter(\.failed).count,
         results.filter { if case .skipped = $0.state { return true }; return $0.state == .cancelled }.count)
    }

    var allText: String {
        results.map { "=== \($0.name) (exit \($0.exitCode)) ===\n\($0.output)" }.joined(separator: "\n\n")
    }
}

struct MultiRunSheet: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var theme = ThemeManager.shared
    @StateObject private var run = MultiRunModel()
    @Environment(\.dismiss) private var dismiss
    @State private var confirming = false
    @State private var expanded = Set<String>()
    @State private var showHistory = false

    /// Runnable hosts: SSH and this Mac.
    private var candidates: [Host] { model.hosts.filter { !$0.isRDP } }
    private var groups: [String] {
        var seen: [String] = []
        for h in candidates where !seen.contains(h.isLocal ? "" : h.group) { seen.append(h.isLocal ? "" : h.group) }
        return seen.filter { !$0.isEmpty } + (candidates.contains { $0.isLocal } ? [""] : [])
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(lucideSymbol: "rectangle.stack.badge.play").foregroundStyle(Pal.tint)
                Text("Run Command on Multiple Servers").font(.system(size: 15, weight: .semibold)).foregroundStyle(Pal.text)
                Spacer()
                Button { dismiss() } label: { Image(lucideSymbol: "xmark").font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.overlay) }
                    .buttonStyle(.plain).pointerCursor()
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            Divider().overlay(Pal.fill(0.06))
            HStack(spacing: 0) {
                hostPicker.frame(width: 250)
                Divider().overlay(Pal.fill(0.06))
                VStack(spacing: 0) { commandArea; Divider().overlay(Pal.fill(0.06)); resultsArea }
            }
        }
        .frame(width: 900, height: 640)
        .background(Pal.solidBase)
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .confirmationDialog(confirmTitle, isPresented: $confirming, titleVisibility: .visible) {
            Button("Run", role: MultiRunModel.riskyReason(run.command) != nil ? .destructive : nil) {
                expanded = []
                run.run(hosts: candidates)
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text(confirmMessage) }
    }

    private var confirmTitle: String { String(localized: "Run on \(run.selected.count) servers?") }
    private var confirmMessage: String {
        var m = run.command.trimmingCharacters(in: .whitespacesAndNewlines)
        if m.count > 300 { m = String(m.prefix(300)) + "…" }
        if let r = MultiRunModel.riskyReason(run.command) {
            m += "\n\n" + String(localized: "This command contains “\(r)”, which can stop services or delete data on every selected server.")
        }
        return m
    }

    // MARK: Host selection

    private var hostPicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Servers").font(.system(size: 12, weight: .semibold)).foregroundStyle(Pal.subtext)
                Text("\(run.selected.count)/\(candidates.count)").font(.system(size: 11)).foregroundStyle(Pal.overlay)
                Spacer()
                Button("All") { run.selected = Set(candidates.map(\.id)) }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Pal.tint).pointerCursor()
                Button("None") { run.selected = [] }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Pal.tint).pointerCursor()
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(groups, id: \.self) { g in
                        let hs = candidates.filter { (g.isEmpty ? $0.isLocal : (!$0.isLocal && $0.group == g)) }
                        if !hs.isEmpty {
                            Button {
                                let ids = Set(hs.map(\.id))
                                if ids.isSubset(of: run.selected) { run.selected.subtract(ids) } else { run.selected.formUnion(ids) }
                            } label: {
                                Text(g.isEmpty ? String(localized: "This Mac") : g).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Pal.overlay)
                                    .padding(.horizontal, 6).padding(.top, 8).padding(.bottom, 2)
                            }
                            .buttonStyle(.plain).pointerCursor().help(String(localized: "Select or clear this whole group"))
                            ForEach(hs) { h in hostRow(h) }
                        }
                    }
                }
                .padding(.horizontal, 8).padding(.bottom, 10)
            }
        }
    }

    private func hostRow(_ h: Host) -> some View {
        let on = run.selected.contains(h.id)
        return Button {
            if on { run.selected.remove(h.id) } else { run.selected.insert(h.id) }
        } label: {
            HStack(spacing: 8) {
                Image(lucideSymbol: on ? "checkmark.square.fill" : "square").font(.system(size: 13)).foregroundStyle(on ? h.accent : Pal.overlay)
                Circle().fill(h.accent).frame(width: 7, height: 7)
                Text(verbatim: h.name).font(.system(size: 12.5)).foregroundStyle(Pal.text).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6).padding(.vertical, 5).contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor()
    }

    // MARK: Command

    private var commandArea: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Command").font(.system(size: 12, weight: .semibold)).foregroundStyle(Pal.subtext)
                Spacer()
                Button { showHistory.toggle() } label: {
                    Label("History", lucideSymbol: "clock.arrow.circlepath").font(.system(size: 11)).foregroundStyle(run.history.isEmpty ? Pal.overlay : Pal.tint)
                }
                .buttonStyle(.plain).pointerCursor()
                .popover(isPresented: $showHistory, arrowEdge: .bottom) { historyList }
                if !model.snippets.isEmpty {
                    Menu {
                        ForEach(model.snippets.filter { Snippet.variableNames(in: $0.content).isEmpty }) { sn in
                            Button(sn.name) { run.command = sn.content }
                        }
                    } label: { Label("Scripts", lucideSymbol: "chevron.left.forwardslash.chevron.right").font(.system(size: 11)) }
                    .menuStyle(.borderlessButton).fixedSize()
                }
            }
            ThemedTextEditor(placeholder: "e.g. uptime && df -h /", text: $run.command).frame(height: 96)
            HStack(spacing: 12) {
                Text("Timeout").font(.system(size: 11)).foregroundStyle(Pal.subtext)
                SegmentedControl(options: [(value: 15.0, verbatim: "15s"), (value: 60.0, verbatim: "60s"), (value: 300.0, verbatim: "5m")], selection: $run.timeout)
                    .frame(width: 170)
                Spacer()
                if run.running {
                    SecondaryButton(title: "Stop") { run.cancel() }
                }
                PrimaryButton(title: "Run", enabled: !run.running && !run.selected.isEmpty
                              && !run.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, tint: Pal.tint) { confirming = true }
            }
            Text("Runs once on each selected server through its SSH login shell, up to 4 at a time. There is no terminal, so use sudo -n for privileged commands.")
                .font(.system(size: 10.5)).foregroundStyle(Pal.overlay)
        }
        .padding(16)
    }

    // MARK: History

    private var historyList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Run History").font(.system(size: 13, weight: .semibold)).foregroundStyle(Pal.text)
                Spacer()
                if !run.history.isEmpty { Button("Clear") { run.clearHistory() }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Pal.red).pointerCursor() }
            }
            if run.history.isEmpty {
                Text("Runs you finish are listed here so you can look at their output again or run them once more.").font(.system(size: 11.5)).foregroundStyle(Pal.overlay).fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(run.history) { r in
                            HStack(spacing: 8) {
                                Button { run.load(r); expanded = []; showHistory = false } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(verbatim: r.command.split(whereSeparator: \.isNewline).first.map(String.init) ?? r.command)
                                            .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Pal.text).lineLimit(1).truncationMode(.tail)
                                        HStack(spacing: 6) {
                                            Text(r.date, format: .dateTime.month().day().hour().minute()).font(.system(size: 10)).foregroundStyle(Pal.overlay)
                                            Text("\(r.items.count) servers").font(.system(size: 10)).foregroundStyle(Pal.overlay)
                                            Text(verbatim: "\(r.ok) OK").font(.system(size: 10, weight: .medium)).foregroundStyle(Pal.green)
                                            if r.failed > 0 { Text(verbatim: "\(r.failed) " + String(localized: "failed")).font(.system(size: 10, weight: .medium)).foregroundStyle(Pal.red) }
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                }.buttonStyle(.plain).pointerCursor().help(String(localized: "Load the command, servers and results"))
                                Button { run.deleteRecord(r.id) } label: { Image(lucideSymbol: "xmark").font(.system(size: 9)).foregroundStyle(Pal.overlay) }.buttonStyle(.plain).pointerCursor()
                            }
                            .padding(.horizontal, 8).padding(.vertical, 6).background(Pal.fill(0.04), in: RoundedRectangle(cornerRadius: 7))
                        }
                    }
                }.frame(maxHeight: 300)
            }
        }
        .padding(14).frame(width: 380)
    }

    // MARK: Results

    private var resultsArea: some View {
        VStack(alignment: .leading, spacing: 0) {
            if run.results.isEmpty {
                Text("Results appear here.").font(.system(size: 12)).foregroundStyle(Pal.overlay)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let s = run.summary
                HStack(spacing: 12) {
                    Text(run.viewingHistory ? String(localized: "Results (from history)") : String(localized: "Results")).font(.system(size: 12, weight: .semibold)).foregroundStyle(Pal.subtext)
                    pill("\(s.ok) OK", Pal.green)
                    if s.failed > 0 { pill("\(s.failed) " + String(localized: "failed"), Pal.red) }
                    if s.skipped > 0 { pill("\(s.skipped) " + String(localized: "skipped"), Pal.overlay) }
                    if run.running { ProgressView().controlSize(.small) }
                    Spacer()
                    if !run.running && (s.failed > 0 || s.skipped > 0) {
                        Button("Retry Failed") { run.retryFailed(hosts: candidates) }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Pal.tint).pointerCursor()
                    }
                    Button("Copy All") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(run.allText, forType: .string) }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Pal.tint).pointerCursor()
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                ScrollView {
                    VStack(spacing: 4) { ForEach(run.results) { r in resultRow(r) } }.padding(.horizontal, 12).padding(.bottom, 12)
                }
            }
        }
    }

    private func pill(_ t: String, _ c: Color) -> some View {
        Text(verbatim: t).font(.system(size: 11, weight: .medium)).foregroundStyle(c)
            .padding(.horizontal, 8).padding(.vertical, 2).background(c.opacity(0.12), in: Capsule())
    }

    private func resultRow(_ r: MultiRunResult) -> some View {
        let open = expanded.contains(r.id)
        let (label, color): (String, Color) = {
            switch r.state {
            case .waiting: return (String(localized: "Waiting"), Pal.overlay)
            case .running: return (String(localized: "Running…"), Pal.yellow)
            case .cancelled: return (String(localized: "Cancelled"), Pal.overlay)
            case .skipped(let why): return (why, Pal.overlay)
            case .done: return r.exitCode == 0 ? ("exit 0", Pal.green) : ("exit \(r.exitCode)", Pal.red)
            }
        }()
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                if open { expanded.remove(r.id) } else { expanded.insert(r.id) }
            } label: {
                HStack(spacing: 8) {
                    Image(lucideSymbol: open ? "chevron.down" : "chevron.right").font(.system(size: 9)).foregroundStyle(Pal.overlay).frame(width: 10)
                    Circle().fill(color).frame(width: 8, height: 8)
                    Text(verbatim: r.name).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Pal.text)
                    Text(verbatim: label).font(.system(size: 11)).foregroundStyle(color).lineLimit(1)
                    if r.state == .done { Text(String(format: "%.1fs", r.seconds)).font(.system(size: 10.5)).foregroundStyle(Pal.overlay) }
                    Spacer(minLength: 8)
                    if !open, !r.output.isEmpty {
                        Text(verbatim: r.output.split(whereSeparator: \.isNewline).first.map(String.init) ?? "")
                            .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Pal.overlay).lineLimit(1).truncationMode(.tail)
                            .frame(maxWidth: 260, alignment: .trailing)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 7).contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointerCursor()
            if open {
                VStack(alignment: .leading, spacing: 6) {
                    if r.stdout.isEmpty && r.stderr.isEmpty {
                        Text("(no output)").font(.system(size: 11)).foregroundStyle(Pal.overlay)
                    }
                    if !r.stdout.isEmpty { Text(verbatim: r.stdout).font(.system(size: 11, design: .monospaced)).foregroundStyle(Pal.text).textSelection(.enabled) }
                    if !r.stderr.isEmpty { Text(verbatim: r.stderr).font(.system(size: 11, design: .monospaced)).foregroundStyle(Pal.red).textSelection(.enabled) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28).padding(.bottom, 10)
            }
        }
        .background(Pal.fill(0.04), in: RoundedRectangle(cornerRadius: 8))
    }
}

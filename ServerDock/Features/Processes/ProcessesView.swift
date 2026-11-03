import SwiftUI
import AppKit

/// Process table sorts CPU/memory and offers terminate/kill/pause/reload signals.
/// Confirm terminating/suspending signals, separately warning for PID 1/sshd.
struct ProcessesView: View {
    @ObservedObject var session: ProcessSession
    let model: AppModel
    @ObservedObject private var theme = ThemeManager.shared

    private enum Filter { case all, mine, busy }

    @State private var selection = Set<Int>()
    @State private var query = ""
    @State private var filter: Filter = .all
    @State private var sortOrder = [KeyPathComparator(\ProcessRow.cpu, order: .reverse)]
    @State private var pending: (signal: ProcessSignal, items: [ProcessRow])?

    private var visible: [ProcessRow] {
        let q = query.lowercased()
        return session.rows.filter { p in
            switch filter {
            case .all: break
            case .mine: if p.user != session.loginUser { return false }
            case .busy: if p.cpu < 1 && p.mem < 1 { return false }
            }
            return q.isEmpty || p.command.lowercased().contains(q) || String(p.pid) == q || p.user.lowercased().contains(q)
        }.sorted(using: sortOrder)
    }

    private var selected: [ProcessRow] { session.rows.filter { selection.contains($0.pid) } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Pal.fill(0.06))
            if let n = session.notice { banner(n) }
            content
        }
        .background(Pal.base)
        .onAppear { session.startAutoRefresh() }
        .onDisappear { session.stopAutoRefresh() }
        .sheet(item: Binding(get: { session.details.map { DetailItem(pid: $0.pid, text: $0.text) } }, set: { if $0 == nil { session.details = nil } })) { DetailSheet(item: $0) }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
            if let p = pending {
                Button(p.signal.title, role: p.signal.destructive ? .destructive : nil) { session.send(p.signal, to: p.items); pending = nil }
                Button("Cancel", role: .cancel) { pending = nil }
            }
        } message: { Text(confirmMessage) }
    }

    private var confirmTitle: String {
        guard let p = pending else { return "" }
        let what = p.items.count == 1 ? "\(p.items[0].name) (\(p.items[0].pid))" : String(localized: "\(p.items.count) processes")
        return String(localized: "Send \(p.signal.title) to \(what)?")
    }

    private var confirmMessage: String {
        guard let p = pending else { return "" }
        var m: [String] = []
        if p.items.contains(where: { $0.pid == 1 }) { m.append(String(localized: "PID 1 is the system's init process. Killing it can bring the whole server down.")) }
        if p.items.contains(where: { $0.command.contains("sshd") }) { m.append(String(localized: "This includes sshd. Ending the wrong sshd process can cut your own connection or stop SSH for everyone.")) }
        switch p.signal {
        case .kill: m.append(String(localized: "The process is killed immediately without cleaning up. Unsaved data may be lost."))
        case .term: m.append(String(localized: "The process is asked to shut down. Most programs exit cleanly."))
        case .stop: m.append(String(localized: "The process is frozen until it receives Resume (SIGCONT)."))
        default: break
        }
        return m.joined(separator: "\n\n")
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(lucideSymbol: "list.bullet.rectangle").font(.system(size: 14)).foregroundStyle(session.host.accent)
                Text("Processes").font(.system(size: 14, weight: .semibold)).foregroundStyle(Pal.text)
                if session.phase == .ready {
                    Text("\(session.rows.count) processes").font(.system(size: 11)).foregroundStyle(Pal.overlay)
                    if session.rows.contains(where: \.isZombie) {
                        Text("\(session.rows.filter(\.isZombie).count) zombie").font(.system(size: 11)).foregroundStyle(Pal.yellow)
                    }
                }
                Spacer()
                if session.refreshing { ProgressView().controlSize(.small) }
                Toggle("Auto", isOn: $session.autoRefresh).toggleStyle(.checkbox).font(.system(size: 11)).help(String(localized: "Refresh every 4 seconds"))
                Toggle("sudo", isOn: $session.useSudo).toggleStyle(.checkbox).font(.system(size: 11))
                    .help(String(localized: "Send signals with passwordless sudo (sudo -n)"))
                iconButton("arrow.clockwise", String(localized: "Refresh")) { session.refresh() }
            }
            if session.phase == .ready {
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(lucideSymbol: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Pal.overlay)
                        TextField(String(localized: "Search command, user or PID…"), text: $query).textFieldStyle(.plain).font(.system(size: 12)).frame(width: 200)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5).background(Pal.fill(0.06), in: RoundedRectangle(cornerRadius: 7))
                    SegmentedControl(options: [(value: Filter.all, label: LocalizedStringKey("All")), (value: Filter.mine, label: LocalizedStringKey("Mine")),
                                               (value: Filter.busy, label: LocalizedStringKey("Busy"))], selection: $filter).frame(width: 240)
                    Spacer()
                    actions
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var actions: some View {
        let sel = selected
        let none = sel.isEmpty
        return HStack(spacing: 2) {
            iconButton("xmark.circle", String(localized: "Terminate (SIGTERM)"), disabled: none) { request(.term, sel) }
            iconButton("bolt.fill", String(localized: "Force Kill (SIGKILL)"), disabled: none) { request(.kill, sel) }
            iconButton("pause.fill", String(localized: "Pause (SIGSTOP)"), disabled: none) { request(.stop, sel) }
            iconButton("play.fill", String(localized: "Resume (SIGCONT)"), disabled: none) { request(.cont, sel) }
            iconButton("arrow.triangle.2.circlepath", String(localized: "Reload / Hang Up (SIGHUP)"), disabled: none) { request(.hup, sel) }
            Divider().frame(height: 16).padding(.horizontal, 4)
            iconButton("info.circle", String(localized: "Details"), disabled: sel.count != 1) { if let p = sel.first { session.showDetails(p) } }
        }
    }

    private func request(_ signal: ProcessSignal, _ items: [ProcessRow]) {
        guard !items.isEmpty else { return }
        if signal.confirm || items.contains(where: { $0.pid == 1 }) { pending = (signal, items) } else { session.send(signal, to: items) }
    }

    private func iconButton(_ symbol: String, _ help: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(lucideSymbol: symbol).font(.system(size: 12)).foregroundStyle(disabled ? Pal.overlay.opacity(0.5) : Pal.subtext)
                .frame(width: 28, height: 26).contentShape(Rectangle())
        }.buttonStyle(.plain).pointerCursor().disabled(disabled).help(help)
    }

    private func banner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(lucideSymbol: "exclamationmark.triangle.fill").foregroundStyle(Pal.yellow)
            ScrollView { Text(text).font(.system(size: 11, design: .monospaced)).foregroundStyle(Pal.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 90)
            Button { session.notice = nil } label: { Image(lucideSymbol: "xmark").font(.system(size: 10)).foregroundStyle(Pal.overlay) }.buttonStyle(.plain).pointerCursor()
        }
        .padding(10).background(Pal.yellow.opacity(0.10))
    }

    // MARK: Body

    @ViewBuilder
    private var content: some View {
        switch session.phase {
        case .loading:
            VStack(spacing: 10) { ProgressView(); Text("Loading processes…").font(.system(size: 12)).foregroundStyle(Pal.subtext) }.frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let m):
            VStack(spacing: 10) {
                Image(lucideSymbol: "exclamationmark.triangle").font(.system(size: 30)).foregroundStyle(Pal.overlay)
                Text("Couldn't read the process list").font(.system(size: 14, weight: .semibold)).foregroundStyle(Pal.text)
                Text(m).font(.system(size: 11, design: .monospaced)).foregroundStyle(Pal.subtext).multilineTextAlignment(.center).frame(maxWidth: 480)
                Button { session.refresh() } label: {
                    Text("Retry").font(.system(size: 12)).foregroundStyle(Pal.tint).padding(.horizontal, 14).padding(.vertical, 6)
                        .background(Pal.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 7)).contentShape(Rectangle())
                }.buttonStyle(.plain).pointerCursor()
            }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            Table(visible, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("PID", value: \.pid) { p in Text(verbatim: String(p.pid)).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Pal.subtext) }.width(min: 50, ideal: 64, max: 90)
                TableColumn("Name", value: \.name) { p in
                    HStack(spacing: 6) {
                        Circle().fill(p.isZombie ? Pal.yellow : (p.isStopped ? Pal.red : (p.cpu >= 50 ? Pal.red : (p.cpu >= 10 ? Pal.yellow : Pal.green)))).frame(width: 7, height: 7)
                        Text(verbatim: p.name).lineLimit(1)
                    }
                }.width(min: 110, ideal: 160)
                TableColumn("User", value: \.user) { p in Text(verbatim: p.user).foregroundStyle(Pal.subtext).lineLimit(1) }.width(min: 60, ideal: 90)
                TableColumn("CPU %", value: \.cpu) { p in Text(verbatim: String(format: "%.1f", p.cpu)).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(p.cpu >= 50 ? Pal.red : Pal.text) }.width(min: 56, ideal: 64, max: 80)
                TableColumn("Mem %", value: \.mem) { p in Text(verbatim: String(format: "%.1f", p.mem)).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Pal.text) }.width(min: 56, ideal: 64, max: 80)
                TableColumn("RSS", value: \.rssKB) { p in
                    Text(verbatim: p.rssMB >= 1024 ? String(format: "%.1f GB", p.rssMB / 1024) : String(format: "%.0f MB", p.rssMB)).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Pal.subtext)
                }.width(min: 60, ideal: 76, max: 96)
                TableColumn("State", value: \.state) { p in Text(verbatim: p.state).font(.system(size: 11, design: .monospaced)).foregroundStyle(Pal.subtext) }.width(min: 44, ideal: 52, max: 70)
                TableColumn("Running", value: \.elapsed) { p in Text(verbatim: p.elapsed).font(.system(size: 11, design: .monospaced)).foregroundStyle(Pal.subtext) }.width(min: 70, ideal: 90, max: 120)
                TableColumn("Command", value: \.command) { p in Text(verbatim: p.command).font(.system(size: 11, design: .monospaced)).foregroundStyle(Pal.subtext).lineLimit(1).truncationMode(.middle).help(p.command) }
            }
            .contextMenu(forSelectionType: Int.self) { ids in
                let items = session.rows.filter { ids.contains($0.pid) }
                if !items.isEmpty { rowMenu(items) }
            } primaryAction: { ids in
                if ids.count == 1, let p = session.rows.first(where: { $0.pid == ids.first }) { session.showDetails(p) }
            }
            .overlay { if visible.isEmpty { Text("No matching processes").font(.system(size: 12)).foregroundStyle(Pal.overlay).allowsHitTesting(false) } }
        }
    }

    @ViewBuilder
    private func rowMenu(_ items: [ProcessRow]) -> some View {
        ForEach(ProcessSignal.allCases) { s in
            Button(s.title, role: s.destructive ? .destructive : nil) { request(s, items) }
        }
        if items.count == 1, let p = items.first {
            Divider()
            Button("Details") { session.showDetails(p) }
            Button("Copy Command") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(p.command, forType: .string) }
            Button("Copy PID") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(String(p.pid), forType: .string) }
        }
    }
}

private struct DetailItem: Identifiable { let pid: Int; let text: String; var id: Int { pid } }

private struct DetailSheet: View {
    let item: DetailItem
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var theme = ThemeManager.shared
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(verbatim: "PID \(item.pid)").font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(Pal.text)
                Spacer()
                Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(item.text, forType: .string) }
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(14)
            Divider().overlay(Pal.fill(0.06))
            ScrollView([.vertical, .horizontal]) {
                Text(item.text).font(.system(size: 11, design: .monospaced)).foregroundStyle(Pal.text).textSelection(.enabled).padding(14).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 760, height: 520).background(Pal.solidBase).preferredColorScheme(theme.isDark ? .dark : .light)
    }
}

import SwiftUI
import AppKit

/// Service table includes state/startup/description, lifecycle actions, journalctl -f, and detailed status.
/// Confirm stopping services or changing boot behavior.
struct ServicesView: View {
    @ObservedObject var session: ServiceSession
    let model: AppModel
    @ObservedObject private var theme = ThemeManager.shared

    private enum Filter: String { case all, running, failed, inactive }

    @State private var selection = Set<String>()
    @State private var query = ""
    @State private var filter: Filter = .all
    @State private var sortOrder = [KeyPathComparator(\SystemdService.name, comparator: .localizedStandard)]
    @State private var pending: (action: ServiceAction, items: [SystemdService])?

    private var visible: [SystemdService] {
        let q = query.lowercased()
        return session.services.filter { s in
            switch filter {
            case .all: break
            case .running: if !s.isRunning { return false }
            case .failed: if !s.isFailed { return false }
            case .inactive: if s.isActive { return false }
            }
            return q.isEmpty || s.name.lowercased().contains(q) || s.description.lowercased().contains(q)
        }.sorted(using: sortOrder)
    }

    private var selected: [SystemdService] { session.services.filter { selection.contains($0.id) } }

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
        .sheet(item: Binding(get: { session.statusText.map { StatusItem(name: $0.name, text: $0.text) } },
                             set: { if $0 == nil { session.statusText = nil } })) { StatusSheet(item: $0) }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible) {
            if let p = pending {
                Button(p.action.title, role: p.action == .restart ? nil : .destructive) { session.perform(p.action, on: p.items); pending = nil }
                Button("Cancel", role: .cancel) { pending = nil }
            }
        } message: { Text(confirmMessage) }
    }

    // MARK: Confirmation

    private var confirmTitle: String {
        guard let p = pending else { return "" }
        let what = p.items.count == 1 ? "\"\(p.items[0].shortName)\"" : String(localized: "\(p.items.count) services")
        switch p.action {
        case .stop: return String(localized: "Stop \(what)?")
        case .restart: return String(localized: "Restart \(what)?")
        case .disable: return String(localized: "Disable \(what) at boot?")
        default: return p.action.title
        }
    }

    private var confirmMessage: String {
        switch pending?.action {
        case .stop: return String(localized: "The service stops until it is started again. Services that depend on it may stop too, and an SSH or network service may cut your own connection.")
        case .restart: return String(localized: "The service is stopped and started again. Connections in progress are dropped.")
        case .disable: return String(localized: "The service won't start automatically at the next boot. It keeps running now.")
        default: return ""
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(lucideSymbol: "gearshape.2").font(.system(size: 14)).foregroundStyle(session.host.accent)
                Text("Services").font(.system(size: 14, weight: .semibold)).foregroundStyle(Pal.text)
                if session.phase == .ready {
                    Text("\(session.runningCount) running · \(session.services.count) total")
                        .font(.system(size: 11)).foregroundStyle(Pal.overlay)
                    if session.failedCount > 0 {
                        Text("\(session.failedCount) failed").font(.system(size: 11, weight: .semibold)).foregroundStyle(Pal.red)
                            .padding(.horizontal, 7).padding(.vertical, 2).background(Pal.red.opacity(0.12), in: Capsule())
                    }
                }
                Spacer()
                if session.refreshing { ProgressView().controlSize(.small) }
                Toggle("Auto", isOn: $session.autoRefresh).toggleStyle(.checkbox).font(.system(size: 11))
                    .help(String(localized: "Refresh every 10 seconds"))
                Toggle("sudo", isOn: $session.useSudo).toggleStyle(.checkbox).font(.system(size: 11))
                    .help(String(localized: "Run changes with passwordless sudo (sudo -n)"))
                iconButton("arrow.clockwise", help: String(localized: "Refresh")) { session.refresh() }
            }
            if session.phase == .ready {
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(lucideSymbol: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Pal.overlay)
                        TextField(String(localized: "Search services…"), text: $query)
                            .textFieldStyle(.plain).font(.system(size: 12)).frame(width: 180)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Pal.fill(0.06), in: RoundedRectangle(cornerRadius: 7))
                    SegmentedControl(options: [(value: Filter.all, label: LocalizedStringKey("All")),
                                               (value: Filter.running, label: LocalizedStringKey("Running")),
                                               (value: Filter.failed, label: LocalizedStringKey("Failed")),
                                               (value: Filter.inactive, label: LocalizedStringKey("Inactive"))], selection: $filter)
                        .frame(width: 300)
                    Spacer()
                    actionButtons
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var actionButtons: some View {
        let sel = selected
        let none = sel.isEmpty
        return HStack(spacing: 2) {
            iconButton("play.fill", help: String(localized: "Start"), disabled: none || sel.allSatisfy(\.isActive)) { request(.start, sel.filter { !$0.isActive }) }
            iconButton("stop.fill", help: String(localized: "Stop"), disabled: none || !sel.contains(where: \.isActive)) { request(.stop, sel.filter(\.isActive)) }
            iconButton("arrow.clockwise.circle", help: String(localized: "Restart"), disabled: none) { request(.restart, sel) }
            iconButton("arrow.triangle.2.circlepath", help: String(localized: "Reload configuration"), disabled: none || !sel.contains(where: \.isActive)) { request(.reload, sel.filter(\.isActive)) }
            Divider().frame(height: 16).padding(.horizontal, 4)
            iconButton("text.append", help: String(localized: "Logs"), disabled: sel.count != 1) { if let s = sel.first { model.openServiceLogs(s, host: session.host, sudo: session.useSudo) } }
            iconButton("info.circle", help: String(localized: "Status"), disabled: sel.count != 1) { if let s = sel.first { session.showStatus(s) } }
            Divider().frame(height: 16).padding(.horizontal, 4)
            iconButton("power", help: String(localized: "Enable at Boot"), disabled: none || !sel.contains { $0.canToggleEnable && !$0.isEnabled }) { request(.enable, sel.filter { $0.canToggleEnable && !$0.isEnabled }) }
            iconButton("poweroff", help: String(localized: "Disable at Boot"), disabled: none || !sel.contains { $0.canToggleEnable && $0.isEnabled }) { request(.disable, sel.filter { $0.canToggleEnable && $0.isEnabled }) }
        }
    }

    private func request(_ action: ServiceAction, _ items: [SystemdService]) {
        guard !items.isEmpty else { return }
        if action.confirm { pending = (action, items) } else { session.perform(action, on: items) }
    }

    private func iconButton(_ symbol: String, help: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(lucideSymbol: symbol).font(.system(size: 12)).foregroundStyle(disabled ? Pal.overlay.opacity(0.5) : Pal.subtext)
                .frame(width: 28, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor().disabled(disabled).help(help)
    }

    private func banner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(lucideSymbol: "exclamationmark.triangle.fill").foregroundStyle(Pal.yellow)
            ScrollView { Text(text).font(.system(size: 11, design: .monospaced)).foregroundStyle(Pal.text)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 100)
            Button { session.notice = nil } label: { Image(lucideSymbol: "xmark").font(.system(size: 10)).foregroundStyle(Pal.overlay) }
                .buttonStyle(.plain).pointerCursor()
        }
        .padding(10).background(Pal.yellow.opacity(0.10))
    }

    // MARK: Body

    @ViewBuilder
    private var content: some View {
        switch session.phase {
        case .loading:
            VStack(spacing: 10) { ProgressView(); Text("Loading services…").font(.system(size: 12)).foregroundStyle(Pal.subtext) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready: table
        case .notAvailable:
            message("gearshape.2", String(localized: "systemd isn't available on this server"),
                    String(localized: "This tab manages systemd services. The server doesn't run systemd (it may be macOS, Alpine, a container, or another init system)."))
        case .failed(let m):
            message("exclamationmark.triangle", String(localized: "Couldn't read services"), m)
        }
    }

    private func message(_ symbol: String, _ title: String, _ detail: String) -> some View {
        VStack(spacing: 10) {
            Image(lucideSymbol: symbol).font(.system(size: 30)).foregroundStyle(Pal.overlay)
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Pal.text)
            Text(detail).font(.system(size: 12)).foregroundStyle(Pal.subtext).multilineTextAlignment(.center).frame(maxWidth: 460)
            Button { session.refresh() } label: {
                Text("Retry").font(.system(size: 12)).foregroundStyle(Pal.tint)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Pal.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 7)).contentShape(Rectangle())
            }.buttonStyle(.plain).pointerCursor()
        }
        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var table: some View {
        ZStack {
            Table(visible, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Name", value: \.name) { s in
                    HStack(spacing: 7) {
                        Circle().fill(color(s)).frame(width: 8, height: 8)
                        Text(s.shortName).lineLimit(1)
                        if session.busy.contains(s.id) { ProgressView().controlSize(.mini) }
                    }
                }.width(min: 140, ideal: 220)
                TableColumn("State", value: \.stateRank) { s in
                    Text("\(s.active) (\(s.sub))").foregroundStyle(s.isFailed ? Pal.red : Pal.subtext).lineLimit(1)
                }.width(min: 100, ideal: 140)
                TableColumn("Boot", value: \.enabled) { s in
                    Text(s.enabled.isEmpty ? "—" : s.enabled).foregroundStyle(s.isEnabled ? Pal.green : Pal.subtext)
                }.width(min: 60, ideal: 90, max: 110)
                TableColumn("Description", value: \.description) { s in
                    Text(s.description).foregroundStyle(Pal.subtext).lineLimit(1).truncationMode(.tail)
                }
            }
            .contextMenu(forSelectionType: String.self) { ids in
                let items = session.services.filter { ids.contains($0.id) }
                if !items.isEmpty { rowMenu(items) }
            } primaryAction: { ids in
                if ids.count == 1, let s = session.services.first(where: { $0.id == ids.first }) { session.showStatus(s) }
            }
            if visible.isEmpty {
                Text(session.services.isEmpty ? String(localized: "No services found") : String(localized: "No matching services"))
                    .font(.system(size: 12)).foregroundStyle(Pal.overlay).allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private func rowMenu(_ items: [SystemdService]) -> some View {
        Button("Start") { request(.start, items.filter { !$0.isActive }) }.disabled(items.allSatisfy(\.isActive))
        Button("Stop") { request(.stop, items.filter(\.isActive)) }.disabled(!items.contains(where: \.isActive))
        Button("Restart") { request(.restart, items) }
        Button("Reload configuration") { request(.reload, items.filter(\.isActive)) }.disabled(!items.contains(where: \.isActive))
        if items.count == 1, let s = items.first {
            Divider()
            Button("Logs") { model.openServiceLogs(s, host: session.host, sudo: session.useSudo) }
            Button("Status") { session.showStatus(s) }
            Button("Copy Name") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s.name, forType: .string) }
        }
        Divider()
        Button("Enable at Boot") { request(.enable, items.filter { $0.canToggleEnable && !$0.isEnabled }) }
            .disabled(!items.contains { $0.canToggleEnable && !$0.isEnabled })
        Button("Disable at Boot") { request(.disable, items.filter { $0.canToggleEnable && $0.isEnabled }) }
            .disabled(!items.contains { $0.canToggleEnable && $0.isEnabled })
    }

    private func color(_ s: SystemdService) -> Color {
        if s.isFailed { return Pal.red }
        if s.isRunning { return Pal.green }
        if s.isActive { return Pal.yellow }
        return Pal.overlay
    }
}

private struct StatusItem: Identifiable { let name: String; let text: String; var id: String { name } }

private struct StatusSheet: View {
    let item: StatusItem
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(verbatim: "systemctl status \(item.name)").font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(Pal.text)
                Spacer()
                Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(item.text, forType: .string) }
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(14)
            Divider().overlay(Pal.fill(0.06))
            ScrollView([.vertical, .horizontal]) {
                Text(item.text).font(.system(size: 11, design: .monospaced)).foregroundStyle(Pal.text)
                    .textSelection(.enabled).padding(14).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 760, height: 520).background(Pal.solidBase).preferredColorScheme(theme.isDark ? .dark : .light)
    }
}

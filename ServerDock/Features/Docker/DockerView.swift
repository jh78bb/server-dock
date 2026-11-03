import SwiftUI
import AppKit

/// Container management lists status/image/CPU/memory/ports and start/stop/restart/pause/remove/logs/shell/inspect actions.
/// Confirm service-affecting stop/restart/kill/remove operations before execution.
struct DockerView: View {
    @ObservedObject var session: DockerSession
    let model: AppModel
    @ObservedObject private var theme = ThemeManager.shared

    private enum Filter: String, CaseIterable { case all, running, stopped }

    @State private var selection = Set<String>()
    @State private var query = ""
    @State private var filter: Filter = .all
    @State private var sortOrder = [KeyPathComparator(\DockerContainer.name, comparator: .localizedStandard)]
    @State private var pending: (action: DockerAction, items: [DockerContainer])?
    @State private var mode: Mode = .containers
    @State private var runRequest: RunSpec?

    private enum Mode { case containers, images }

    private var visible: [DockerContainer] {
        let q = query.lowercased()
        return session.containers.filter { c in
            switch filter {
            case .all: break
            case .running: if !c.isRunning && !c.isPaused { return false }
            case .stopped: if c.isRunning || c.isPaused { return false }
            }
            return q.isEmpty || c.name.lowercased().contains(q) || c.image.lowercased().contains(q) || c.id.hasPrefix(q)
        }.sorted(using: sortOrder)
    }

    private var selected: [DockerContainer] { session.containers.filter { selection.contains($0.id) } }
    private var runningCount: Int { session.containers.filter(\.isRunning).count }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Pal.fill(0.06))
            if let n = session.notice { noticeBanner(n) }
            content
        }
        .background(Pal.base)
        .onAppear { session.startAutoRefresh() }
        .sheet(item: Binding(get: { runRequest.map { RunItem(spec: $0) } }, set: { if $0 == nil { runRequest = nil } })) { item in
            RunContainerSheet(engine: session.engine, spec: item.spec) { session.run($0) }
        }
        .onDisappear { session.stopAutoRefresh() }
        .sheet(item: Binding(get: { session.inspectText.map { InspectItem(name: $0.name, text: $0.text) } },
                             set: { if $0 == nil { session.inspectText = nil } })) { item in
            InspectSheet(item: item)
        }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible) {
            if let p = pending {
                Button(p.action.title, role: p.action.destructive ? .destructive : nil) {
                    session.perform(p.action, on: p.items); pending = nil
                }
                Button("Cancel", role: .cancel) { pending = nil }
            }
        } message: { Text(confirmMessage) }
    }

    // MARK: Confirmation text

    private var confirmTitle: String {
        guard let p = pending else { return "" }
        let what = p.items.count == 1 ? "\"\(p.items[0].name)\"" : String(localized: "\(p.items.count) containers")
        switch p.action {
        case .stop: return String(localized: "Stop \(what)?")
        case .restart: return String(localized: "Restart \(what)?")
        case .kill: return String(localized: "Kill \(what)?")
        case .remove: return String(localized: "Remove \(what)?")
        default: return p.action.title
        }
    }

    private var confirmMessage: String {
        switch pending?.action {
        case .stop: return String(localized: "The container stops serving requests until it is started again.")
        case .restart: return String(localized: "The container is stopped and started again. Connections in progress are dropped.")
        case .kill: return String(localized: "Sends SIGKILL immediately, without letting the process shut down cleanly.")
        case .remove: return String(localized: "Running containers are force-stopped first. The container and its writable layer are deleted; volumes are kept. This can't be undone.")
        default: return ""
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(lucideSymbol: "shippingbox").font(.system(size: 14)).foregroundStyle(session.host.accent)
                Text(verbatim: session.engine == "podman" ? "Podman" : "Docker").font(.system(size: 14, weight: .semibold)).foregroundStyle(Pal.text)
                if session.engines.count > 1 {
                    SegmentedControl(options: session.engines.map { (value: $0, verbatim: $0 == "podman" ? "Podman" : "Docker") }, selection: $session.engine).frame(width: 150)
                }
                if session.phase == .ready {
                    Text("\(runningCount) running · \(session.containers.count) total")
                        .font(.system(size: 11)).foregroundStyle(Pal.overlay)
                }
                Spacer()
                if session.refreshing { ProgressView().controlSize(.small) }
                Toggle("Resources", isOn: $session.showStats).toggleStyle(.checkbox).font(.system(size: 11))
                    .help(String(localized: "Show CPU and memory (runs docker stats on the server)"))
                    .onChange(of: session.showStats) { on in if on { session.refresh() } }
                Toggle("Auto", isOn: $session.autoRefresh).toggleStyle(.checkbox).font(.system(size: 11))
                    .help(String(localized: "Refresh every 8 seconds"))
                Toggle("sudo", isOn: $session.useSudo).toggleStyle(.checkbox).font(.system(size: 11))
                    .help(String(localized: "Run docker with passwordless sudo (sudo -n)"))
                    .onChange(of: session.useSudo) { _ in session.refresh() }
                iconButton("arrow.clockwise", help: String(localized: "Refresh")) { session.refresh() }
            }
            if session.phase == .ready {
                HStack(spacing: 8) {
                    SegmentedControl(options: [(value: Mode.containers, label: LocalizedStringKey("Containers")), (value: Mode.images, label: LocalizedStringKey("Images"))], selection: $mode).frame(width: 190)
                    if mode == .containers {
                    HStack(spacing: 6) {
                        Image(lucideSymbol: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Pal.overlay)
                        TextField(String(localized: "Search containers…"), text: $query)
                            .textFieldStyle(.plain).font(.system(size: 12)).frame(width: 180)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Pal.fill(0.06), in: RoundedRectangle(cornerRadius: 7))
                    SegmentedControl(options: [(value: Filter.all, label: LocalizedStringKey("All")),
                                               (value: Filter.running, label: LocalizedStringKey("Running")),
                                               (value: Filter.stopped, label: LocalizedStringKey("Stopped"))], selection: $filter)
                        .frame(width: 220)
                    }
                    Spacer()
                    if mode == .containers {
                        iconButton("plus.circle", help: String(localized: "Run a container…")) { runRequest = RunSpec() }
                        actionButtons
                    }
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    /// Selection toolbar disabled without selected containers.
    private var actionButtons: some View {
        let sel = selected
        let none = sel.isEmpty
        return HStack(spacing: 2) {
            iconButton("play.fill", help: String(localized: "Start"), disabled: none || sel.allSatisfy(\.isRunning)) { request(.start, sel.filter { !$0.isRunning }) }
            iconButton("stop.fill", help: String(localized: "Stop"), disabled: none || !sel.contains(where: \.isRunning)) { request(.stop, sel.filter(\.isRunning)) }
            iconButton("arrow.clockwise.circle", help: String(localized: "Restart"), disabled: none) { request(.restart, sel) }
            iconButton("pause.fill", help: String(localized: "Pause"), disabled: none || !sel.contains(where: \.isRunning)) { request(.pause, sel.filter(\.isRunning)) }
            Divider().frame(height: 16).padding(.horizontal, 4)
            iconButton("text.append", help: String(localized: "Logs"), disabled: sel.count != 1) { if let c = sel.first { model.openDockerLogs(container: c, host: session.host, sudo: session.useSudo, engine: session.engine) } }
            iconButton("terminal", help: String(localized: "Open Shell in Container"), disabled: sel.count != 1 || !(sel.first?.isRunning ?? false)) { if let c = sel.first { model.openDockerShell(container: c, host: session.host, sudo: session.useSudo, engine: session.engine) } }
            iconButton("doc.text.magnifyingglass", help: String(localized: "Inspect"), disabled: sel.count != 1) { if let c = sel.first { session.inspect(c) } }
            Divider().frame(height: 16).padding(.horizontal, 4)
            iconButton("trash", help: String(localized: "Remove"), disabled: none) { request(.remove, sel) }
        }
    }

    private func request(_ action: DockerAction, _ items: [DockerContainer]) {
        guard !items.isEmpty else { return }
        if action.confirm { pending = (action, items) } else { session.perform(action, on: items) }
    }

    private func iconButton(_ symbol: String, help: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(lucideSymbol: symbol).font(.system(size: 12))
                .foregroundStyle(disabled ? Pal.overlay.opacity(0.5) : Pal.subtext)
                .frame(width: 28, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor().disabled(disabled).help(help)
    }

    private func noticeBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(lucideSymbol: "exclamationmark.triangle.fill").foregroundStyle(Pal.yellow)
            ScrollView { Text(text).font(.system(size: 11, design: .monospaced)).foregroundStyle(Pal.text)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(maxHeight: 90)
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
            VStack(spacing: 10) { ProgressView(); Text("Loading containers…").font(.system(size: 12)).foregroundStyle(Pal.subtext) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            if mode == .containers { table } else { DockerImagesPane(session: session, runSpecRequest: $runRequest) }
        case .notInstalled:
            problem(symbol: "shippingbox", title: String(localized: "Docker isn't available on this server"),
                    detail: String(localized: "The docker command wasn't found for this login user. Install Docker, or check that it's on the PATH of the SSH login shell."),
                    hint: nil, sudoButton: false)
        case .permissionDenied(let msg):
            problem(symbol: "lock", title: String(localized: "No permission to use Docker"),
                    detail: msg,
                    hint: String(localized: "Add your user to the docker group (sudo usermod -aG docker $USER, then log in again), or enable the sudo option above if this account has passwordless sudo."),
                    sudoButton: !session.useSudo)
        case .daemonDown(let msg):
            problem(symbol: "bolt.slash", title: String(localized: "The Docker daemon isn't running"),
                    detail: msg,
                    hint: String(localized: "Start it on the server, for example: sudo systemctl start docker"), sudoButton: false)
        case .failed(let msg):
            problem(symbol: "exclamationmark.triangle", title: String(localized: "Couldn't read Docker state"),
                    detail: msg, hint: nil, sudoButton: false)
        }
    }

    private func problem(symbol: String, title: String, detail: String, hint: String?, sudoButton: Bool) -> some View {
        VStack(spacing: 10) {
            Image(lucideSymbol: symbol).font(.system(size: 30)).foregroundStyle(Pal.overlay)
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Pal.text)
            Text(detail).font(.system(size: 11, design: .monospaced)).foregroundStyle(Pal.subtext)
                .multilineTextAlignment(.center).textSelection(.enabled).frame(maxWidth: 480)
            if let hint { Text(hint).font(.system(size: 12)).foregroundStyle(Pal.overlay).multilineTextAlignment(.center).frame(maxWidth: 480) }
            HStack(spacing: 8) {
                if sudoButton {
                    Button { session.useSudo = true; session.refresh() } label: { pill(String(localized: "Retry with sudo")) }
                        .buttonStyle(.plain).pointerCursor()
                }
                Button { session.refresh() } label: { pill(String(localized: "Retry")) }
                    .buttonStyle(.plain).pointerCursor()
            }
        }
        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func pill(_ t: String) -> some View {
        Text(t).font(.system(size: 12)).foregroundStyle(Pal.tint)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(Pal.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 7)).contentShape(Rectangle())
    }

    private var table: some View {
        ZStack {
            Table(visible, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Name", value: \.name) { c in
                    HStack(spacing: 7) {
                        Circle().fill(color(c)).frame(width: 8, height: 8)
                        Text(c.name).lineLimit(1)
                        if session.busyIds.contains(c.id) { ProgressView().controlSize(.mini) }
                    }
                }.width(min: 120, ideal: 180)
                TableColumn("Image", value: \.image) { c in Text(c.image).foregroundStyle(Pal.subtext).lineLimit(1).truncationMode(.middle) }
                    .width(min: 100, ideal: 170)
                TableColumn("Status", value: \.stateRank) { c in
                    Text(c.status).foregroundStyle(c.isUnhealthy ? Pal.red : Pal.subtext).lineLimit(1)
                }.width(min: 90, ideal: 150)
                TableColumn("CPU", value: \.cpuValue) { c in Text(c.cpu).foregroundStyle(Pal.subtext) }.width(min: 50, ideal: 60, max: 80)
                TableColumn("Memory", value: \.memValue) { c in
                    Text(c.memUsage.split(separator: "/").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? "")
                        .foregroundStyle(Pal.subtext).help(c.memUsage)
                }.width(min: 70, ideal: 90, max: 120)
                TableColumn("Ports") { c in Text(c.ports).foregroundStyle(Pal.subtext).lineLimit(1).truncationMode(.middle).help(c.ports) }
                    .width(min: 100, ideal: 200)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                let items = session.containers.filter { ids.contains($0.id) }
                if !items.isEmpty { rowMenu(items) }
            } primaryAction: { ids in
                if ids.count == 1, let c = session.containers.first(where: { $0.id == ids.first }) { session.inspect(c) }
            }
            if visible.isEmpty {
                Text(session.containers.isEmpty ? String(localized: "No containers on this server") : String(localized: "No matching containers"))
                    .font(.system(size: 12)).foregroundStyle(Pal.overlay).allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private func rowMenu(_ items: [DockerContainer]) -> some View {
        Button("Start") { request(.start, items.filter { !$0.isRunning }) }.disabled(items.allSatisfy(\.isRunning))
        Button("Stop") { request(.stop, items.filter(\.isRunning)) }.disabled(!items.contains(where: \.isRunning))
        Button("Restart") { request(.restart, items) }
        if items.contains(where: \.isPaused) { Button("Resume") { request(.unpause, items.filter(\.isPaused)) } }
        else { Button("Pause") { request(.pause, items.filter(\.isRunning)) }.disabled(!items.contains(where: \.isRunning)) }
        if items.count == 1, let c = items.first {
            Divider()
            Button("Logs") { model.openDockerLogs(container: c, host: session.host, sudo: session.useSudo, engine: session.engine) }
            Button("Open Shell in Container") { model.openDockerShell(container: c, host: session.host, sudo: session.useSudo, engine: session.engine) }.disabled(!c.isRunning)
            Button("Inspect") { session.inspect(c) }
            Button("Copy Container ID") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(c.id, forType: .string) }
        }
        Divider()
        Button("Kill", role: .destructive) { request(.kill, items.filter(\.isRunning)) }.disabled(!items.contains(where: \.isRunning))
        Button("Remove", role: .destructive) { request(.remove, items) }
    }

    private func color(_ c: DockerContainer) -> Color {
        if c.isUnhealthy { return Pal.red }
        switch c.state {
        case "running": return Pal.green
        case "paused", "restarting": return Pal.yellow
        default: return Pal.overlay
        }
    }
}

private struct RunItem: Identifiable { let id = UUID(); let spec: RunSpec }

private struct InspectItem: Identifiable { let name: String; let text: String; var id: String { name } }

private struct InspectSheet: View {
    let item: InspectItem
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(verbatim: "docker inspect \(item.name)").font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(Pal.text)
                Spacer()
                Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(item.text, forType: .string) }
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(14)
            Divider().overlay(Pal.fill(0.06))
            ScrollView([.vertical, .horizontal]) {
                Text(item.text).font(.system(size: 11, design: .monospaced)).foregroundStyle(Pal.text)
                    .textSelection(.enabled).padding(14).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 720, height: 560)
        .background(Pal.solidBase)
        .preferredColorScheme(theme.isDark ? .dark : .light)
    }
}

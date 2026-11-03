import SwiftUI

/// Shared host sheet and all-server forwarding workspace.
struct PortForwardView: View {
    @ObservedObject var model: AppModel
    var host: Host? = nil
    @ObservedObject private var theme = ThemeManager.shared

    // Non-nil presents the form with an edited rule, or an empty rule for this host when creating one.
    @State private var formRule: ForwardRule? = nil
    @State private var isNew = false
    // Non-nil presents delete confirmation. dontAskAgain sets model.skipForwardDeleteConfirm for this app run only.
    @State private var pendingDelete: ForwardRule? = nil
    @State private var dontAskAgain = false
    @State private var showWebPopover = false
    @State private var webDest = "localhost"
    @State private var webPort = ""
    @State private var webHTTPS = false

    @State private var search = ""

    private var hosts: [Host] { host.map { [$0] } ?? model.forwardingHosts }
    private var rules: [ForwardRule] {
        model.forwards.filter { rule in
            guard hosts.contains(where: { $0.id == rule.hostId }) else { return false }
            if host == nil, let filter = model.forwardFilterHostId, rule.hostId != filter { return false }
            let hostName = model.host(rule.hostId)?.name ?? ""
            return search.isEmpty || "\(hostName) \(rule.name) \(rule.summary) \(rule.kind.title)"
                .localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Pal.fill(0.06))
            if let rule = formRule {
                ForwardRuleForm(
                    existing: isNew ? nil : rule,
                    hosts: hosts,
                    initialHostId: rule.hostId,
                    privacyMode: model.privacyMode,
                    onSave: { saved in
                        model.saveForwardRule(saved)
                        search = ""
                        if host == nil, model.forwardFilterHostId != nil {
                            model.forwardFilterHostId = saved.hostId
                        }
                        formRule = nil
                    },
                    onCancel: { formRule = nil }
                )
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
                .id(rule.id)   // Rebuild when the edited rule changes so @State does not retain the previous rule's fields.
            } else {
                listContent
            }
        }
        .frame(width: host == nil ? nil : 600, height: host == nil ? nil : 600)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Pal.solidBase)
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .overlay {
            // Disable hit testing without a dialog; a fading fullscreen transition layer must not briefly block underlying clicks.
            ZStack {
                if let rule = pendingDelete {
                    deleteConfirm(rule).transition(.opacity)
                }
            }
            .allowsHitTesting(pendingDelete != nil)
        }
        .animation(.easeOut(duration: 0.15), value: pendingDelete?.id)
    }

    /// Delete immediately if Don't ask again was selected this run; otherwise request confirmation.
    private func requestDelete(_ rule: ForwardRule) {
        if model.skipForwardDeleteConfirm {
            model.deleteForwardRule(rule)
        } else {
            dontAskAgain = false
            pendingDelete = rule
        }
    }

    /// Delete-confirmation dialog reusing the settings checkbox; Don't ask again applies only for this run.
    @ViewBuilder
    private func deleteConfirm(_ rule: ForwardRule) -> some View {
        let name = rule.name.isEmpty ? (rule.kind.title + String(localized: "Forwarding")) : rule.name
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
                .onTapGesture { pendingDelete = nil }
            VStack(alignment: .leading, spacing: 14) {
                Text("Delete forwarding rule “\(name)”?")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Pal.text)
                Text("This stops its running tunnel and removes the rule. This can't be undone.")
                    .font(.system(size: 13)).foregroundStyle(Pal.subtext)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    ThemedCheckbox(isOn: dontAskAgain) { dontAskAgain.toggle() }
                    Text("Don't Ask Again This Time")
                        .font(.system(size: 12)).foregroundStyle(Pal.subtext)
                        .onTapGesture { dontAskAgain.toggle() }
                    Spacer(minLength: 0)
                }

                HStack(spacing: 10) {
                    Spacer()
                    SecondaryButton(title: "Cancel") { pendingDelete = nil }
                    Button {
                        if dontAskAgain { model.skipForwardDeleteConfirm = true }
                        model.deleteForwardRule(rule)
                        pendingDelete = nil
                    } label: {
                        Text("Delete").font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                            .padding(.horizontal, 16).padding(.vertical, 7)
                            .background(Pal.red, in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
            .padding(20)
            .frame(width: 360)
            .background(Pal.solidMantle, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Pal.fill(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(lucideSymbol: "arrow.left.arrow.right")
                .font(.system(size: 14, weight: .medium)).foregroundStyle(Pal.tint)
                .frame(width: 30, height: 30)
                .background(Pal.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text("Port Forwarding").font(.system(size: 15, weight: .semibold)).foregroundStyle(Pal.text)
                Text(formRule != nil ? (isNew ? String(localized: "New Rule") : String(localized: "Edit"))
                     : (host?.name ?? model.host(model.forwardFilterHostId)?.name ?? String(localized: "All Servers")))
                    .font(.system(size: 11)).foregroundStyle(Pal.overlay)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if formRule == nil {
                if host != nil {
                    Button { showWebPopover = true } label: {
                        HStack(spacing: 5) {
                            Image(lucideSymbol: "globe").font(.system(size: 11, weight: .semibold))
                            Text("Open Web Service").font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(Pal.tint)
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .background(Pal.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .popover(isPresented: $showWebPopover, arrowEdge: .bottom) { webPopover }
                }
                Button { startNew() } label: {
                    HStack(spacing: 5) {
                        Image(lucideSymbol: "plus").font(.system(size: 11, weight: .semibold))
                        Text("New Rule").font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(Pal.tint)
                    .padding(.horizontal, 11).padding(.vertical, 6)
                    .background(Pal.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
            if host != nil {
                Button { model.forwardPanelHost = nil } label: {
                    Image(lucideSymbol: "xmark")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.overlay)
                        .frame(width: 26, height: 26)
                        .background(Pal.fill(0.05), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    // MARK: - Rule list

    private var listContent: some View {
        VStack(spacing: 0) {
            if host == nil {
                HStack(spacing: 10) {
                    Image(lucideSymbol: "magnifyingglass").foregroundStyle(Pal.overlay)
                    TextField("Search forwarding rules…", text: $search)
                        .textFieldStyle(.plain)
                    if !search.isEmpty {
                        Button { search = "" } label: { Image(lucideSymbol: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(Pal.overlay)
                    }
                    Spacer(minLength: 0)
                    Text("\(rules.count)").monospacedDigit().foregroundStyle(Pal.subtext)
                }
                .font(.system(size: 12))
                .padding(12)
                .background(Pal.fill(0.04), in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 18).padding(.top, 14)
            }
            if rules.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(hosts.filter { server in rules.contains { $0.hostId == server.id } }) { server in
                            VStack(alignment: .leading, spacing: 8) {
                                if host == nil {
                                    HStack(spacing: 8) {
                                        Circle().fill(server.accent).frame(width: 7, height: 7)
                                        Text(server.name).foregroundStyle(Pal.text)
                                        Spacer()
                                        Text("\(model.activeForwardCount(hostId: server.id))")
                                            .monospacedDigit().foregroundStyle(Pal.green)
                                        Text("Running").foregroundStyle(Pal.overlay)
                                    }
                                    .font(.system(size: 12, weight: .medium)).padding(.horizontal, 4)
                                }
                                ForEach(rules.filter { $0.hostId == server.id }) { rule in
                                    ForwardRow(
                                        rule: rule,
                                        manager: model.forwardManager(for: server),
                                        privacyMode: model.privacyMode,
                                        onToggle: { model.toggleForward(rule) },
                                        onOpenWeb: { https in model.openForwardInApp(rule, https: https) },
                                        onEdit: { startEdit(rule) },
                                        onDelete: { requestDelete(rule) }
                                    )
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 18).padding(.vertical, 16)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(lucideSymbol: "arrow.left.arrow.right")
                .font(.system(size: 30)).foregroundStyle(Pal.overlay)
            Text(search.isEmpty ? String(localized: "No forwarding rules yet") : String(localized: "No matching forwarding rules")).font(.system(size: 13)).foregroundStyle(Pal.subtext)
            Text("Securely reach internal services through an SSH tunnel, with nothing to install on the server.")
                .font(.system(size: 11)).foregroundStyle(Pal.overlay)
                .multilineTextAlignment(.center).frame(maxWidth: 320)
            Button { startNew() } label: {
                Text("New Rule").font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.tint)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Pal.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Small server-web tunnel form with common administration-page presets.
    private var webPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Open Web Service").font(.system(size: 13, weight: .semibold)).foregroundStyle(Pal.text)
            Text("Creates an SSH tunnel to a web page on the server and opens it in a tab here.")
                .font(.system(size: 11)).foregroundStyle(Pal.overlay).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Target host").font(.system(size: 11)).foregroundStyle(Pal.subtext)
                    ThemedTextField(verbatim: "localhost", text: $webDest)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Port").font(.system(size: 11)).foregroundStyle(Pal.subtext)
                    ThemedTextField(verbatim: "8080", text: $webPort, onSubmit: openWeb).frame(width: 84)
                }
            }
            Toggle("HTTPS", isOn: $webHTTPS).toggleStyle(.checkbox).font(.system(size: 12))
            Menu("Presets") {
                ForEach(Self.webPresets, id: \.0) { p in
                    Button("\(p.0) — \(p.1)") { webPort = String(p.1); webHTTPS = p.2 }
                }
            }.menuStyle(.borderlessButton).fixedSize()
            HStack {
                Spacer()
                PrimaryButton(title: "Open", enabled: Int(webPort).map { (1...65535).contains($0) } ?? false, tint: Pal.tint, action: openWeb)
            }
        }
        .padding(16).frame(width: 300)
    }

    private static let webPresets: [(String, Int, Bool)] = [
        ("Proxmox VE", 8006, true), ("Synology DSM", 5001, true), ("Portainer", 9443, true), ("Cockpit", 9090, true),
        ("Grafana", 3000, false), ("Jenkins", 8080, false), ("Prometheus", 9090, false), ("Kibana", 5601, false),
    ]

    private func openWeb() {
        guard let host, let p = Int(webPort), (1...65535).contains(p) else { return }
        showWebPopover = false
        model.openWebService(host: host, destHost: webDest, destPort: p, https: webHTTPS)
    }

    private func startNew() {
        formRule = ForwardRule(hostId: host?.id ?? model.forwardFilterHostId ?? "")
        isNew = true
    }
    private func startEdit(_ rule: ForwardRule) {
        formRule = rule
        isNew = false
    }
}

/// One rule row: status dot, summary, start/stop, edit, and delete.
private struct ForwardRow: View {
    let rule: ForwardRule
    @ObservedObject var manager: ForwardManager
    var privacyMode = false
    let onToggle: () -> Void
    let onOpenWeb: (Bool) -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    @ObservedObject private var theme = ThemeManager.shared
    @State private var hover = false

    private var status: ForwardManager.RuleStatus { manager.status(rule.id) }

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(statusColor).frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(rule.name.isEmpty ? rule.kind.title + String(localized: "Forwarding") : rule.name)
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(Pal.text)
                    kindBadge
                }
                HStack(spacing: 6) {
                    Text(rule.summary)
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(Pal.subtext)
                        .lineLimit(1).truncationMode(.middle)
                        .privacyBlur(privacyMode)
                    if case .failed(let reason) = status {
                        TruncatableText(text: "· \(reason)", color: Pal.red)
                    }
                }
            }
            Spacer(minLength: 8)

            Text(statusText).font(.system(size: 11)).foregroundStyle(statusColor)

            // Start/stop.
            Button(action: onToggle) {
                Image(lucideSymbol: status.isRunning ? "stop.fill" : "play.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(status.isRunning ? Pal.red : Pal.green)
                    .frame(width: 26, height: 26)
                    .background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointerCursor()
            .help(status.isRunning ? String(localized: "Stop") : String(localized: "Start"))

            // Open running local forwards in an in-app web tab.
            if rule.kind == .local, status == .active {
                Menu {
                    Button("Open as HTTP in App") { onOpenWeb(false) }
                    Button("Open as HTTPS in App") { onOpenWeb(true) }
                } label: {
                    Image(lucideSymbol: "globe").font(.system(size: 11)).foregroundStyle(Pal.tint)
                        .frame(width: 26, height: 26)
                        .background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 7))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help(String(localized: "Open in an app tab"))
            }

            // Editing is disabled while running.
            Button(action: onEdit) {
                Image(lucideSymbol: "pencil").font(.system(size: 11)).foregroundStyle(Pal.subtext)
                    .frame(width: 26, height: 26)
                    .background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointerCursor()
            .disabled(status.isRunning)
            .opacity(status.isRunning ? 0.4 : 1)
            .help(status.isRunning ? String(localized: "Stop before editing") : String(localized: "Edit"))

            Button(action: onDelete) {
                Image(lucideSymbol: "trash").font(.system(size: 11)).foregroundStyle(Pal.subtext)
                    .frame(width: 26, height: 26)
                    .background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointerCursor()
            .help(String(localized: "Delete"))
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
        .background(hover ? Pal.fill(0.05) : Pal.fill(0.03), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Pal.fill(0.06), lineWidth: 1))
        .animation(.easeOut(duration: 0.12), value: hover)
        .onHover { hover = $0 }
    }

    private var kindBadge: some View {
        Text(rule.kind.title)
            .font(.system(size: 9, weight: .medium)).foregroundStyle(Pal.overlay)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Pal.fill(0.08), in: RoundedRectangle(cornerRadius: 4))
    }

    private var statusColor: Color {
        switch status {
        case .stopped:  return Pal.overlay
        case .starting: return Pal.yellow
        case .active:   return Pal.green
        case .failed:   return Pal.red
        }
    }
    private var statusText: String {
        switch status {
        case .stopped:  return String(localized: "Stopped")
        case .starting: return String(localized: "Connecting")
        case .active:   return String(localized: "Running")
        case .failed:   return String(localized: "Failed")
        }
    }
}

/// Server selection is always first; the common case only needs a remote port.
private struct ForwardRuleForm: View {
    let existing: ForwardRule?
    let hosts: [Host]
    let privacyMode: Bool
    let onSave: (ForwardRule) -> Void
    let onCancel: () -> Void
    @ObservedObject private var theme = ThemeManager.shared

    @State private var hostId: String
    @State private var kind: ForwardKind
    @State private var name: String
    @State private var bind: String
    @State private var remotePort: String
    @State private var customLocalPort: String
    @State private var proxyPort: String
    @State private var samePort: Bool
    @State private var destHost: String
    @State private var advanced: Bool
    @State private var error: String?

    init(existing: ForwardRule?, hosts: [Host], initialHostId: String, privacyMode: Bool,
         onSave: @escaping (ForwardRule) -> Void, onCancel: @escaping () -> Void) {
        self.existing = existing
        self.hosts = hosts
        self.privacyMode = privacyMode
        self.onSave = onSave
        self.onCancel = onCancel
        let r = existing ?? ForwardRule(hostId: initialHostId)
        let remote = r.kind == .remote ? r.listenPort : r.destPort
        let local = r.kind == .remote ? r.destPort : r.listenPort
        _hostId = State(initialValue: r.hostId)
        _kind = State(initialValue: r.kind)
        _name = State(initialValue: r.name)
        _bind = State(initialValue: r.bindAddress)
        _remotePort = State(initialValue: remote == 0 ? "" : String(remote))
        _customLocalPort = State(initialValue: local == 0 ? "" : String(local))
        _proxyPort = State(initialValue: r.kind == .dynamic && r.listenPort != 0 ? String(r.listenPort) : "1080")
        _samePort = State(initialValue: existing == nil || local == remote)
        _destHost = State(initialValue: r.destHost)
        _advanced = State(initialValue: r.bindAddress != "127.0.0.1" || r.destHost != "localhost")
    }

    private var selectedHost: Host? { hosts.first { $0.id == hostId } }
    private var localPort: String { samePort ? remotePort : customLocalPort }
    private var draft: ForwardRule {
        var rule = existing ?? ForwardRule(hostId: hostId)
        rule.hostId = hostId
        rule.kind = kind
        rule.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = bind.trimmingCharacters(in: .whitespacesAndNewlines)
        rule.bindAddress = address.isEmpty ? "127.0.0.1" : address
        rule.destHost = destHost.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .local:
            rule.listenPort = port(localPort)
            rule.destPort = port(remotePort)
        case .remote:
            rule.listenPort = port(remotePort)
            rule.destPort = port(localPort)
        case .dynamic:
            rule.listenPort = port(proxyPort)
        }
        return rule
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    serverPicker
                    if selectedHost != nil {
                        labeled(String(localized: "Type"), hint: kind.hint) {
                            SegmentedControl(
                                options: ForwardKind.allCases.map { (value: $0, verbatim: $0.title) },
                                selection: $kind
                            )
                            .frame(maxWidth: 300)
                        }
                        portsSection
                        connectionPreview
                        labeled(String(localized: "Alias (optional)")) {
                            ThemedTextField(placeholder: "e.g. Production DB", text: $name)
                        }
                        DisclosureGroup(isExpanded: $advanced) {
                            VStack(alignment: .leading, spacing: 14) {
                                if kind != .dynamic {
                                    labeled(String(localized: "Target Host"), hint: destHostHint) {
                                        ThemedTextField(verbatim: "localhost", text: $destHost)
                                    }
                                }
                                labeled(String(localized: "Bind Address"), hint: String(localized: "The interface address to bind on the listening side. Use 127.0.0.1 for local access only, or 0.0.0.0 to expose it on your LAN.")) {
                                    ThemedTextField(verbatim: "127.0.0.1", text: $bind)
                                }
                            }
                            .padding(.top, 12)
                        } label: {
                            Text("Advanced Settings").font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.subtext)
                        }
                        .tint(Pal.overlay)
                    } else {
                        Text("Select a server, then enter the remote service port.")
                            .font(.system(size: 12)).foregroundStyle(Pal.overlay)
                    }
                    if let error {
                        Text(error).font(.system(size: 12)).foregroundStyle(Pal.red)
                    }
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider().overlay(Pal.fill(0.06))
            HStack(spacing: 10) {
                Spacer()
                SecondaryButton(title: "Cancel", action: onCancel)
                PrimaryButton(title: existing == nil ? "Add" : "Save",
                              enabled: selectedHost != nil, tint: Pal.tint, action: save)
            }
            .padding(.horizontal, 22).padding(.vertical, 14)
        }
        .onChange(of: hostId) { _ in error = nil }
        .onChange(of: kind) { _ in error = nil }
        .onChange(of: remotePort) { _ in error = nil }
        .onChange(of: customLocalPort) { _ in error = nil }
        .onChange(of: proxyPort) { _ in error = nil }
    }

    private var serverPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Server").font(.system(size: 12, weight: .semibold)).foregroundStyle(Pal.text)
            Picker("Server", selection: $hostId) {
                Text("Select a server…").tag("")
                ForEach(hosts) { server in
                    Text(privacyMode ? server.name : "\(server.name) · \(server.addr)").tag(server.id)
                }
            }
            .labelsHidden().pickerStyle(.menu)
            .disabled(existing != nil)
            .frame(maxWidth: .infinity, alignment: .leading)
            if let selectedHost {
                Text(selectedHost.addr).font(.system(size: 11)).foregroundStyle(Pal.overlay)
                    .privacyBlur(privacyMode)
            }
            if hosts.isEmpty {
                Text("Add an SSH server before creating a forwarding rule.")
                    .font(.system(size: 11)).foregroundStyle(Pal.overlay)
            }
        }
    }

    @ViewBuilder
    private var portsSection: some View {
        if kind == .dynamic {
            labeled(String(localized: "Proxy Port"), hint: String(localized: "Open a SOCKS5 proxy on this Mac.")) {
                ThemedTextField(verbatim: "1080", text: $proxyPort, autofocus: true, onSubmit: save)
                    .frame(maxWidth: 180)
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                labeled(String(localized: "Remote Port"), hint: kind == .remote
                        ? String(localized: "The port opened on the server.")
                        : String(localized: "The port the remote service listens on.")) {
                    ThemedTextField(placeholder: "e.g. 5432", text: $remotePort, autofocus: true, onSubmit: save)
                        .frame(maxWidth: 180)
                }
                if existing == nil {
                    HStack(spacing: 6) {
                        ForEach(Self.presets, id: \.port) { preset in
                            Button {
                                remotePort = String(preset.port)
                                error = nil
                            } label: {
                                Text(preset.name).font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(Pal.subtext)
                                    .padding(.horizontal, 8).padding(.vertical, 5)
                                    .background(Pal.fill(0.05), in: Capsule())
                            }
                            .buttonStyle(.plain).pointerCursor()
                            .help(String(preset.port))
                        }
                    }
                }
                Toggle("Use the same local port", isOn: Binding(
                    get: { samePort },
                    set: { value in
                        if !value && customLocalPort.isEmpty { customLocalPort = remotePort }
                        samePort = value
                        error = nil
                    }
                ))
                .toggleStyle(.checkbox).font(.system(size: 12)).foregroundStyle(Pal.subtext)
                if samePort {
                    HStack(spacing: 6) {
                        Text("Local Port").foregroundStyle(Pal.overlay)
                        Text(remotePort.isEmpty ? "—" : remotePort).monospacedDigit().foregroundStyle(Pal.text)
                    }
                    .font(.system(size: 12))
                } else {
                    labeled(String(localized: "Local Port")) {
                        ThemedTextField(placeholder: "e.g. 15432", text: $customLocalPort, onSubmit: save)
                            .frame(maxWidth: 180)
                    }
                }
            }
        }
    }

    private static let presets: [(name: String, port: Int)] = [
        ("PostgreSQL", 5432), ("MySQL", 3306), ("Redis", 6379), ("HTTP", 8080),
    ]

    private var connectionPreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(kind == .remote ? String(localized: "Server → This Mac") : String(localized: "This Mac → Server"))
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(Pal.tint)
            Text(endpointPreview)
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(Pal.text)
                .lineLimit(2).textSelection(.enabled)
            Text(kind == .dynamic ? String(localized: "Use this local port as a SOCKS5 proxy.")
                 : kind == .remote ? String(localized: "Connections to the remote port reach a service on this Mac.")
                 : String(localized: "Connect to the local port to reach the service on your server."))
                .font(.system(size: 11)).foregroundStyle(Pal.subtext)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Pal.tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }

    private var endpointPreview: String {
        let rule = draft
        let listening = kind == .dynamic ? proxyPort : (kind == .remote ? remotePort : localPort)
        let target = kind == .remote ? localPort : remotePort
        let listenText = listening.isEmpty ? "—" : listening
        let targetText = target.isEmpty ? "—" : target
        if kind == .dynamic { return "SOCKS5 \(rule.bindAddress):\(listenText)" }
        return "\(rule.bindAddress):\(listenText) → \(rule.destHost):\(targetText)"
    }

    private var destHostHint: String {
        kind == .remote
            ? String(localized: "Resolved from this machine's perspective. localhost refers to this machine itself.")
            : String(localized: "Resolved from the server's perspective. localhost refers to the server itself—exactly how you reach a remote database that only listens on the internal network.")
    }

    private func labeled<C: View>(_ title: String, hint: String? = nil, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.text)
                if let hint {
                    Image(lucideSymbol: "questionmark.circle").font(.system(size: 10))
                        .foregroundStyle(Pal.overlay).tooltip(hint)
                }
            }
            content()
        }
    }

    private func port(_ value: String) -> Int {
        Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    private func save() {
        guard selectedHost != nil else { error = String(localized: "Select a server…"); return }
        let rule = draft
        if let validation = rule.validationError { error = validation; return }
        onSave(rule)
    }
}

/// Sidebar filters for the all-server workspace, independent of the host search field.
struct ForwardHostsPanel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                filterRow(String(localized: "All Servers"), hostId: nil, color: Pal.tint, count: model.forwards.count)
                ForEach(model.forwardingHosts) { host in
                    filterRow(host.name, hostId: host.id, color: host.accent,
                              count: model.forwardRules(for: host.id).count)
                }
            }
            .padding(.horizontal, 12)
        }
    }

    private func filterRow(_ title: String, hostId: String?, color: Color, count: Int) -> some View {
        Button {
            model.forwardFilterHostId = hostId
            model.openAllForwards()
        } label: {
            HStack(spacing: 8) {
                Image(lucideSymbol: hostId == nil ? "square.stack.3d.up" : "server.rack")
                    .foregroundStyle(color).frame(width: 18)
                Text(title).lineLimit(1).foregroundStyle(Pal.text)
                Spacer(minLength: 4)
                Text("\(count)").monospacedDigit().foregroundStyle(Pal.overlay)
            }
            .font(.system(size: 12)).padding(10)
            .background(model.forwardFilterHostId == hostId ? Pal.fill(0.08) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor()
    }
}

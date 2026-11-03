import AppKit
import SwiftUI

struct HostOverview: View {
    let host: Host
    @ObservedObject var model: AppModel
    @ObservedObject private var theme = ThemeManager.shared
    @State private var showLogPicker = false
    @State private var showWake = false
    @State private var showHTTPAdd = false

    /// Host/server theme accent.
    private var accent: Color { host.accent }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                hero

                if !isRDP, let ws = liveHost.specs?.warnings, !ws.isEmpty { warningsSection(ws) }

                // Place monitoring directly below overview so server health appears first.
                if host.ssh != nil {
                    if needsAuth {
                        monitorAuthPlaceholder
                    } else {
                        MonitorPanel(monitor: model.hostMonitor(for: liveHost), accent: host.accent,
                                     onEditConnection: { model.beginEditHost(liveHost) })
                    }
                }

                if isRDP {
                    rdpInfoSection
                } else {
                    quickAccess
                    // Separate service status from actions for predictable card placement.
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 16, alignment: .top)],
                              alignment: .leading, spacing: 16) {
                        if !host.isLocal { securityCard }
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 16, alignment: .top)],
                              alignment: .leading, spacing: 16) {
                        favoritesCard
                        recentCard
                        logsCard
                    }
                }

                if !host.notes.isEmpty { notesSection }

            }
            .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 32)
            .frame(maxWidth: 1440, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        // Run monitoring only while the overview is visible; start on selection and stop a few seconds after leaving to keep it lightweight.
        // Skip SSH probing/monitoring entirely for RDP hosts.
        .task(id: host.id) { model.probeDocker(host); model.scanSecurity(host) }   // Check installation before showing the Docker tile.
        .onAppear {
            guard !isRDP else { return }
            model.probeHostIfNeeded(liveHost)
            model.overviewAppeared(liveHost)
        }
        // For ask-mode hosts, start sampling after the session password arrives and needsAuth becomes false.
        .onChange(of: needsAuth) { stillNeeds in
            if !isRDP, !stillNeeds {
                model.probeHostIfNeeded(liveHost)
                model.overviewAppeared(liveHost)
            }
        }
        .onDisappear { if !isRDP { model.overviewDisappeared(host.id) } }
    }

    /// Whether the host uses RDP, determining overview actions and whether to run the SSH monitoring lifecycle.
    private var isRDP: Bool { host.isRDP }

    /// Use the live model host, not Workspace's snapshot, for password and other changes; HostOverview already observes model.
    private var liveHost: Host { model.host(host.id) ?? host }

    /// Before an ask-mode password is entered, show placeholders instead of an endless establishing-monitor message.
    private var needsAuth: Bool {
        liveHost.ssh?.authMethod == .ask && (liveHost.ssh?.password ?? "").isEmpty
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 18) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 24) {
                    hostIdentity
                    Spacer(minLength: 16)
                    hostHeaderActions
                }
                VStack(alignment: .leading, spacing: 16) {
                    hostIdentity
                    hostHeaderActions
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    statusBadge
                    latencyLabel
                }
                VStack(alignment: .leading, spacing: 8) {
                    statusBadge
                    latencyLabel
                }
            }

            HStack(spacing: 10) {
                if !isRDP {
                    specsLine.frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Spacer(minLength: 0)
                }
                if !host.isLocal, liveHost.status != .online, model.wolMacs[host.id] != nil {
                    Button { model.wake(liveHost) } label: {
                        Label("Wake", lucideSymbol: "sun.max")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Pal.green)
                            .padding(.horizontal, 14).frame(height: 38)
                            .background(Pal.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain).pointerCursor()
                    .help(String(localized: "Send a Wake-on-LAN packet"))
                }
                Group {
                    if isRDP { remoteDesktopButton } else { connectButton }
                }
                .fixedSize()
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Pal.fill(0.025), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Pal.fill(0.10), lineWidth: 1))
    }

    private var hostIdentity: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(lucideSymbol: isRDP ? "display" : (host.isLocal ? "laptopcomputer" : "server.rack"))
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(accent)
                .frame(width: 48, height: 48)
                .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 5) {
                Text(isRDP ? "Remote Desktop" : "Overview")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Pal.subtext)
                Text(liveHost.name)
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(Pal.textBright)
                    .lineLimit(2)
                // Render ports as strings to avoid thousands separators.
                Text(isRDP ? "\(liveHost.ipOrHost) · Port \(String(liveHost.rdp?.port ?? 3389))"
                           : (host.isLocal ? "\(liveHost.addr) · \(String(localized: "This Mac"))"
                                           : "\(liveHost.addr) · Port \(String(liveHost.port))"))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Pal.subtext)
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                    .privacyBlur(model.privacyMode)
            }
        }
    }

    /// Place host settings atop the card and connection actions below.
    @ViewBuilder
    private var hostHeaderActions: some View {
        if !host.isLocal {
            HStack(spacing: 8) {
                Button {
                    if isRDP { model.editingRDPHost = liveHost }
                    else { model.beginEditHost(liveHost) }
                } label: {
                    Label("Edit", lucideSymbol: "pencil")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Pal.subtext)
                        .padding(.horizontal, 12).frame(height: 32)
                        .background(Pal.fill(0.045), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain).pointerCursor()
                powerMenu
            }
            .fixedSize()
        }
    }

    @ViewBuilder
    private var latencyLabel: some View {
        if liveHost.status == .online, let ms = liveHost.latencyMs {
            let level = LatencyLevel(ms: ms)
            HStack(spacing: 5) {
                Image(lucideSymbol: "waveform.path").font(.system(size: 10))
                Text("\(ms) ms").font(.system(size: 12, design: .monospaced))
                Text(level.title).font(.system(size: 11))
            }
            .foregroundStyle(level.color)
        }
    }

    private var remoteDesktopButton: some View {
        Button { model.openHostRDP(liveHost) } label: {
            Label(model.rdpHosts.contains(host.id) ? "Remote Desktop · Running" : "Remote Desktop",
                  lucideSymbol: "arrow.up.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 17).frame(height: 38)
                .background(accent, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain).pointerCursor()
    }

    /// Single-row system-summary chips scroll horizontally; disk usage >=90% is red.
    @ViewBuilder
    private var specsLine: some View {
        if let s = liveHost.specs, !s.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if !s.os.isEmpty { specChip("desktopcomputer", s.os) }
                    if host.isLocal, !s.model.isEmpty { specChip("laptopcomputer", s.model) }
                    if host.isLocal, !s.chip.isEmpty { specChip("cpu", s.chip) }
                    if !s.cores.isEmpty { specChip("cpu", String(localized: "\(s.cores) cores")) }
                    if !s.memory.isEmpty { specChip("memorychip", s.memory) }
                    if !s.disk.isEmpty { specChip("internaldrive", s.disk, warn: s.diskHighPct >= 90) }
                    if !s.gpu.isEmpty { specChip("display", s.gpu) }
                }
            }
        } else if model.probingHosts.contains(host.id) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Fetching system info…").font(.system(size: 11)).foregroundStyle(Pal.overlay)
            }
        } else {
            Color.clear.frame(height: 1)
        }
    }

    private func specChip(_ symbol: String, _ text: String, warn: Bool = false) -> some View {
        HStack(spacing: 4) {
            Image(lucideSymbol: symbol).font(.system(size: 9))
            Text(verbatim: text).font(.system(size: 11)).lineLimit(1)
        }
        .foregroundStyle(warn ? Pal.red : Pal.subtext)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(warn ? Pal.red.opacity(0.12) : Pal.fill(0.07), in: Capsule())
        .fixedSize()
    }

    /// Power menu configures/sends Wake-on-LAN and confirms reboot/shutdown.
    private var powerMenu: some View {
        Menu {
            Button { showWake = true } label: { Label("Wake-on-LAN…", lucideSymbol: "sun.max") }
            if host.ssh != nil {
                Divider()
                Button { model.pendingPower = (host, .reboot) } label: { Label("Reboot…", lucideSymbol: "arrow.clockwise") }
                Button(role: .destructive) { model.pendingPower = (host, .shutdown) } label: { Label("Shut Down…", lucideSymbol: "power") }
            }
        } label: {
            Label("Power Menu", lucideSymbol: "power")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Pal.subtext)
                .padding(.horizontal, 12).frame(height: 32)
                .background(Pal.fill(0.045), in: RoundedRectangle(cornerRadius: 8))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().pointerCursor()
        .help(String(localized: "Power: Wake-on-LAN, reboot, shut down"))
        .popover(isPresented: $showWake, arrowEdge: .bottom) { WakePopover(model: model, host: host) }
    }

    /// Treat a host with a terminal tab as connected, matching connectToHostWorkspace.
    private var connectedTerminalTabId: Int? {
        model.tabs.first(where: { $0.kind == .terminal && $0.hostId == host.id })?.id
    }

    private var connectButton: some View {
        let connecting = model.connectingHost?.id == host.id
        let connectedTabId = connectedTerminalTabId
        return Button {
            if let connectedTabId {
                model.closeTab(connectedTabId)
            } else {
                model.connectToHostWorkspace(host)
            }
        } label: {
            HStack(spacing: 8) {
                if connecting {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Image(lucideSymbol: connectedTabId != nil ? "bolt.horizontal.circle" : "bolt.horizontal.circle.fill")
                        .font(.system(size: 15, weight: .semibold))
                }
                Text(connecting ? "Connecting…" : (connectedTabId != nil ? "Disconnect" : "Connect"))
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(connectedTabId != nil ? Pal.text : Color.white)
            .padding(.horizontal, 17).frame(height: 38)
            .background(connectedTabId != nil ? Pal.fill(0.08) : accent, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor(!connecting)
        .disabled(connecting)
        .help(String(localized: connectedTabId != nil ? "Close Terminal" : "Open Terminal"))
    }

    /// Quick-access grid: remote files/AI/disk/Docker/HTTP/forwarding; local Mac system-app shortcuts.
    private var quickAccess: some View {
        VStack(alignment: .leading, spacing: 13) {
            sectionTitle("square.grid.2x2", String(localized: "Quick Access"))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 215), spacing: 10)], alignment: .leading, spacing: 10) {
                if host.isLocal {
                    tile("externaldrive", String(localized: "Open Disk Utility"), detail: "") { openSystemApp("com.apple.DiskUtility") }
                    if model.hasDocker(host) { tile("shippingbox", model.engineTitle(host), detail: String(localized: "Containers")) { model.openDocker(host) } }
                    tile("chart.pie", String(localized: "Space Analyzer"), detail: diskHint) { openDiskAnalysis() }
                    tile("waveform.path.ecg", String(localized: "Open Activity Monitor"), detail: "") { openSystemApp("com.apple.ActivityMonitor") }
                    tile("list.bullet.rectangle", String(localized: "Processes"), detail: String(localized: "CPU · Memory")) { model.openProcesses(host) }
                    tile("wrench.and.screwdriver", String(localized: "Network Tools"), detail: "DNS · Ping · TCP") { model.openNetTools(NetToolsRequest(host: host)) }
                    tile("waveform.badge.magnifyingglass", String(localized: "HTTP Check"), detail: "GET · HEAD") { model.openNetTools(NetToolsRequest(host: host, tool: .http)) }
                    tile("network", String(localized: "Open Ports"), detail: String(localized: "Listening")) { model.portsHost = host }
                    tile("info.circle", String(localized: "Open System Information"), detail: "") { openSystemApp("com.apple.SystemProfiler") }
                } else {
                    tile("sparkles", String(localized: "AI Assistant"), detail: String(localized: "Ask")) { model.openHostAIChat(host) }
                    tile("chart.pie", String(localized: "Space Analyzer"), detail: diskHint) { openDiskAnalysis() }
                    if model.hasDocker(host) { tile("shippingbox", model.engineTitle(host), detail: String(localized: "Containers")) { model.openDocker(host) } }
                    if model.hasSystemd(host) { tile("gearshape.2", String(localized: "Services"), detail: String(localized: "systemd")) { model.openServices(host) } }
                    tile("list.bullet.rectangle", String(localized: "Processes"), detail: String(localized: "CPU · Memory")) { model.openProcesses(host) }
                    tile("network", String(localized: "Open Ports"), detail: String(localized: "Listening")) { model.portsHost = host }
                    tile("waveform.badge.magnifyingglass", String(localized: "HTTP Check"), detail: "GET · HEAD") { model.openNetTools(NetToolsRequest(host: host, tool: .http)) }
                    tile("wrench.and.screwdriver", String(localized: "Network Tools"), detail: "DNS · Ping · TCP") { model.openNetTools(NetToolsRequest(host: host)) }
                    if model.osKind[host.id] == "Linux" { tile("flame", String(localized: "Firewall"), detail: String(localized: "Rules")) { model.firewallRequest = FirewallRequest(host: host) } }
                    tile("arrow.left.arrow.right", String(localized: "Port Forwarding"),
                         detail: model.hasRunningForward(hostId: host.id) ? String(localized: "Running") : String(localized: "Open")) {
                        model.openForwardPanel(host)
                    }
                }
            }
        }
        .cardStyle()
    }

    private func tileLabel(_ symbol: String, _ title: String, detail: String) -> some View {
        HStack(spacing: 10) {
            Image(lucideSymbol: symbol).font(.system(size: 14))
                .foregroundStyle(accent)
                .frame(width: 32, height: 32)
                .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Pal.text).lineLimit(1)
                if !detail.isEmpty { Text(detail).font(.system(size: 10.5)).foregroundStyle(Pal.overlay).lineLimit(1) }
            }
            Spacer(minLength: 2)
            Image(lucideSymbol: "chevron.right").font(.system(size: 9)).foregroundStyle(Pal.overlay)
        }
        .padding(.horizontal, 12).padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
        .background(Pal.fill(0.025), in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
    }

    private func tile(_ symbol: String, _ title: String, detail: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) { tileLabel(symbol, title, detail: detail) }
            .buttonStyle(OverviewHoverStyle()).pointerCursor()
    }

    /// Disk warnings identify the affected mount on its tile.
    private var diskHint: String {
        if let s = liveHost.specs, s.diskHighPct >= 90 { return "\(s.diskHighMount) · \(s.diskHighPct)%" }
        return String(localized: "Analyze")
    }

    /// Disk analysis starts at the warned mount, otherwise home.
    private func openDiskAnalysis() {
        if let s = liveHost.specs, s.diskHighPct >= 90, !s.diskHighMount.isEmpty {
            model.openDiskUsage(path: s.diskHighMount, host: host)
            return
        }
        let ssh = host.ssh ?? SSHConnection()
        Task {
            let home = await RemoteFS(ssh).home()
            model.openDiskUsage(path: home, host: host)
        }
    }

    // MARK: Log viewing (tail)

    /// Read-only Linux security card: failed SSH logins, exposed ports, firewall, SSH configuration, recent logins.
    @ViewBuilder
    private var securityCard: some View {
        if let s = model.securitySummaries[host.id], s.isLinux {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    sectionTitle("lock.shield", String(localized: "Security"))
                    Spacer()
                    if model.securityScanning.contains(host.id) { ProgressView().controlSize(.mini) }
                    Button { model.scanSecurity(host, force: true) } label: {
                        Image(lucideSymbol: "arrow.clockwise").font(.system(size: 11)).foregroundStyle(Pal.subtext)
                            .frame(width: 28, height: 28)
                            .background(Pal.fill(0.04), in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).pointerCursor().help(String(localized: "Scan again"))
                }
                securityRows(s)
                Text("Read-only checks. Updated \(s.scannedAt.formatted(date: .omitted, time: .shortened)).")
                    .font(.system(size: 10)).foregroundStyle(Pal.overlay)
            }
            .cardStyle()
        } else if model.securityScanning.contains(host.id), !host.isLocal, !isRDP {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("lock.shield", String(localized: "Security"))
                HStack(spacing: 7) { ProgressView().controlSize(.small); Text("Checking…").font(.system(size: 12)).foregroundStyle(Pal.overlay) }
            }
            .cardStyle()
        }
    }

    @ViewBuilder
    private func securityRows(_ s: SecuritySummary) -> some View {
        // Failed logins.
        if let n = s.failedLogins24h {
            secRow("person.crop.circle.badge.exclamationmark", String(localized: "Failed SSH logins (24h)"), "\(n)",
                   n >= 100 ? Pal.red : (n >= 10 ? Pal.yellow : Pal.green))
        } else {
            secRow("person.crop.circle.badge.exclamationmark", String(localized: "Failed SSH logins (24h)"), String(localized: "No access to logs"), Pal.overlay)
        }
        // Externally exposed ports.
        let pub = s.publicPorts
        let listed = pub.prefix(6).map { String($0.port) }.joined(separator: ", ") + (pub.count > 6 ? " …" : "")
        Button { model.portsHost = host } label: {
            secRowLabel("network", String(localized: "Public ports"), pub.isEmpty ? String(localized: "None") : "\(pub.count) · \(listed)", pub.count > 10 ? Pal.yellow : Pal.text)
        }
        .buttonStyle(.plain).pointerCursor().help(String(localized: "Open the port viewer"))
        // Firewall; click to manage rules.
        Button { model.firewallRequest = FirewallRequest(host: host) } label: {
            if s.firewall.isEmpty {
                secRowLabel("flame", String(localized: "Firewall"), String(localized: "Not detected"), Pal.yellow)
            } else {
                secRowLabel("flame", String(localized: "Firewall"), s.firewall.map { "\($0.name) \($0.state)" }.joined(separator: " · "), s.firewallActive ? Pal.green : Pal.yellow)
            }
        }
        .buttonStyle(.plain).pointerCursor().help(String(localized: "Manage firewall rules"))
        // SSH configuration.
        let root = s.rootLogin ?? "default"
        let rootBad = ["yes"].contains(root)
        secRow("terminal", String(localized: "SSH root login"), root == "default" ? String(localized: "Default") : root,
               rootBad ? Pal.red : (root == "no" || root == "prohibit-password" || root == "without-password" ? Pal.green : Pal.overlay))
        if let p = s.passwordAuth {
            secRow("key", String(localized: "SSH password login"), p, p == "yes" ? Pal.yellow : Pal.green)
        }
        if !s.extraRootAccounts.isEmpty {
            secRow("exclamationmark.triangle", String(localized: "Extra UID 0 accounts"), s.extraRootAccounts.joined(separator: ", "), Pal.red)
        }
        // Recent logins.
        if let l = s.lastLogins.first {
            secRow("clock", String(localized: "Last login"), l.split(whereSeparator: { $0 == " " }).prefix(9).joined(separator: " "), Pal.subtext)
        }
        if !s.sessions.isEmpty {
            secRow("person.2", String(localized: "Signed in now"), "\(s.sessions.count)", Pal.subtext)
        }
    }

    private func secRow(_ symbol: String, _ label: String, _ value: String, _ color: Color) -> some View {
        secRowLabel(symbol, label, value, color)
    }

    private func secRowLabel(_ symbol: String, _ label: String, _ value: String, _ color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(lucideSymbol: symbol).font(.system(size: 11)).foregroundStyle(accent).frame(width: 16)
            Text(label).font(.system(size: 12)).foregroundStyle(Pal.subtext)
            Spacer(minLength: 8)
            Text(verbatim: value).font(.system(size: 12, weight: .medium)).foregroundStyle(color)
                .lineLimit(1).truncationMode(.tail)
        }
        .contentShape(Rectangle())
    }

    /// HTTP card lists saved URLs with status/latency, checked on overview opening and row clicks.
    private var httpChecksCard: some View {
        let list = model.httpChecks(for: host.id)
        let mixed = Set(list.map(\.fromServer)).count > 1
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle("waveform.badge.magnifyingglass", String(localized: "HTTP Check"))
                itemCount(list.count)
                Spacer()
                if !list.isEmpty {
                    Button { model.runAllHTTPChecks(host: host) } label: {
                        Image(lucideSymbol: "arrow.clockwise").font(.system(size: 11)).foregroundStyle(Pal.subtext)
                            .frame(width: 28, height: 28)
                            .background(Pal.fill(0.04), in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).pointerCursor().help(String(localized: "Check all"))
                }
                Button { showHTTPAdd.toggle() } label: {
                    Image(lucideSymbol: "plus").font(.system(size: 11, weight: .medium)).foregroundStyle(Pal.subtext)
                        .frame(width: 28, height: 28)
                            .background(Pal.fill(0.04), in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointerCursor().help(String(localized: "Add a URL"))
                .popover(isPresented: $showHTTPAdd, arrowEdge: .bottom) {
                    HTTPCheckAddPopover(isLocalHost: host.isLocal) { item in
                        model.addHTTPCheck(item, host: host); showHTTPAdd = false
                    }
                }
            }
            if list.isEmpty {
                emptyState("link", String(localized: "No URLs yet. Add the addresses you want to keep an eye on with +."))
            } else {
                ForEach(list) { item in
                    HTTPCheckRow(item: item, result: model.httpResults[item.id], running: model.httpRunning.contains(item.id),
                                 fromServerLabel: mixed || !item.fromServer && !host.isLocal,
                                 onRun: { model.runHTTPCheck(item, host: host) },
                                 onDetails: { model.httpCheckPrefill = item.url; model.httpCheckHost = host },
                                 onRemove: { model.removeHTTPCheck(item, hostId: host.id) })
                }
            }
        }
        .cardStyle(minHeight: 170)
    }

    /// Show only user-added per-host log paths; click to tail live.
    /// Header + selects common logs or manual paths; row close/context menu removes them.
    private var logsCard: some View {
        let list = model.hostLogs[host.id] ?? []
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle("text.alignleft", String(localized: "Logs"))
                itemCount(list.count)
                Spacer()
                Button { showLogPicker.toggle() } label: {
                    Image(lucideSymbol: "plus").font(.system(size: 11, weight: .medium)).foregroundStyle(Pal.subtext)
                        .frame(width: 28, height: 28)
                            .background(Pal.fill(0.04), in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointerCursor()
                .help(String(localized: "Add a log file"))
                .popover(isPresented: $showLogPicker, arrowEdge: .bottom) {
                    LogFilePicker(fs: RemoteFS(host.ssh ?? SSHConnection()), alreadyAdded: Set(list)) { paths in
                        paths.forEach { model.addLog($0, hostId: host.id) }
                        showLogPicker = false
                    }
                }
            }
            if list.isEmpty {
                emptyState("text.alignleft", String(localized: "No logs yet. Add the log files you follow with +."))
            } else {
                ForEach(list, id: \.self) { path in
                    LogRow(path: path, accent: accent,
                           onOpen: { model.openTail(path: path, host: host) },
                           onRemove: { model.removeLog(path, hostId: host.id) })
                }
            }
        }
        .cardStyle(minHeight: 170)
    }

    // MARK: Favorites / recent files / snippets

    private var favoritesCard: some View {
        let list = Array((model.favorites[host.id] ?? []).prefix(6))
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle("star", String(localized: "Favorites"))
                itemCount((model.favorites[host.id] ?? []).count)
                Spacer()
            }
            if list.isEmpty {
                emptyState("star", String(localized: "No favorites yet. Add one with ★ in the file panel."))
            } else {
                ForEach(list) { fav in
                    pathRow(icon: fav.isDir ? "folder.fill" : "doc", title: fav.name, subtitle: fav.path) {
                        if fav.isDir { model.openHostFiles(host, at: fav.path) }
                        else { model.openFavorite(fav, host: host, tree: nil) }
                    }
                }
            }
        }
        .cardStyle(minHeight: 170)
    }

    private var recentCard: some View {
        let list = Array((model.recentFiles[host.id] ?? []).prefix(6))
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle("clock.arrow.circlepath", String(localized: "Recent Files"))
                itemCount((model.recentFiles[host.id] ?? []).count)
                Spacer()
            }
            if list.isEmpty {
                emptyState("clock.arrow.circlepath", String(localized: "Files you open will show up here."))
            } else {
                ForEach(list) { r in
                    pathRow(icon: "doc.text", title: r.name, subtitle: r.path) {
                        model.openFile(RemoteFile(name: r.name, path: r.path, kind: .file, size: 0, modified: nil), host: host)
                    }
                }
            }
        }
        .cardStyle(minHeight: 170)
    }

    private func pathRow(icon: String, title: String, subtitle: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            HStack(spacing: 9) {
                Image(lucideSymbol: icon).font(.system(size: 12)).foregroundStyle(accent).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Pal.text).lineLimit(1)
                    Text(verbatim: subtitle).font(.system(size: 10, design: .monospaced)).foregroundStyle(Pal.overlay)
                        .lineLimit(1).truncationMode(.head)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .contentShape(Rectangle())
        }
        .buttonStyle(OverviewHoverStyle()).pointerCursor()
    }

    private func openSystemApp(_ bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
    }

    /// Warning actions: disk -> usage analysis, password -> passwd.
    private func warningAction(_ w: HostWarning) -> (title: String, run: () -> Void)? {
        switch w.id {
        case "disk": return (String(localized: "Analyze"), { openDiskAnalysis() })
        case "pw": return (String(localized: "Change in terminal"), { model.sendCommandToTerminal(hostId: host.id, command: "passwd") })
        default: return nil
        }
    }

    /// Important warnings: expiry, disk pressure, failed services, reboot required.
    private func warningsSection(_ ws: [HostWarning]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(ws) { w in
                let tint: Color = w.level == .critical ? .red : (w.level == .warning ? .orange : .blue)
                HStack(alignment: .top, spacing: 10) {
                    Image(lucideSymbol: w.level == .info ? "info.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(tint).frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(w.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Pal.text)
                        Text(w.detail).font(.system(size: 12)).foregroundStyle(Pal.subtext)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                    Spacer(minLength: 0)
                    if let action = warningAction(w) {
                        Button(action.title, action: action.run)
                            .buttonStyle(.plain).pointerCursor()
                            .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(tint)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(tint.opacity(0.35), lineWidth: 1))
            }
        }
    }

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("text.alignleft", String(localized: "Notes"))
            Text(host.notes)
                .font(.system(size: 12)).foregroundStyle(Pal.subtext)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .cardStyle()
    }

    private func sectionTitle(_ symbol: String, _ title: String) -> some View {
        HStack(spacing: 9) {
            Image(lucideSymbol: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(accent)
                .frame(width: 26, height: 26)
                .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Pal.textBright)
        }
    }

    private func itemCount(_ count: Int) -> some View {
        Text(verbatim: "\(count)")
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(Pal.subtext)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Pal.fill(0.05), in: Capsule())
    }

    private func emptyState(_ symbol: String, _ message: String) -> some View {
        VStack(spacing: 9) {
            Image(lucideSymbol: symbol)
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(Pal.overlay.opacity(0.65))
            Text(message)
                .font(.system(size: 11.5))
                .foregroundStyle(Pal.subtext)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 82)
        .padding(.vertical, 10)
    }

    private func accessRow(_ symbol: String, _ title: String, detail: String,
                           loading: Bool = false, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            HStack(spacing: 10) {
                Group {
                    if loading { ProgressView().controlSize(.small) }
                    else { Image(lucideSymbol: symbol).font(.system(size: 13)) }
                }
                .foregroundStyle(accent)
                .frame(width: 30, height: 30)
                .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.text)
                Spacer(minLength: 4)
                Text(detail).font(.system(size: 10)).foregroundStyle(Pal.overlay)
                Image(lucideSymbol: "chevron.right").font(.system(size: 9)).foregroundStyle(Pal.overlay)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor()
    }

    private var monitorAuthPlaceholder: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("waveform.path.ecg", String(localized: "Monitoring"))
            HStack(spacing: 12) {
                Image(lucideSymbol: "lock.circle").font(.system(size: 24)).foregroundStyle(Pal.overlay)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Start monitoring after connecting").font(.system(size: 13)).foregroundStyle(Pal.subtext)
                    Text("This host is set to \"Always Ask.\" After you connect successfully with a password, monitoring data will be collected for this session.")
                        .font(.system(size: 11)).foregroundStyle(Pal.overlay)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button { model.verifyConnect(host) } label: {
                    Text("Connect").font(.system(size: 12)).foregroundStyle(accent)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointerCursor()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Pal.fill(0.04), in: RoundedRectangle(cornerRadius: 10))
        }
        .cardStyle()
    }

    /// RDP host connection summary.
    @ViewBuilder
    private var rdpInfoSection: some View {
        if let r = host.rdp {
            let items: [(String, String, Bool)] = {
                var a: [(String, String, Bool)] = []                 // (label, value, whether privacy mode blurs it).
                if !host.os.isEmpty { a.append((String(localized: "System"), host.os, false)) }
                a.append((String(localized: "Address"), r.host, true))
                a.append((String(localized: "Port"), String(r.port), false))
                a.append((String(localized: "Username"), r.user, true))
                if !r.domain.isEmpty { a.append((String(localized: "Domain"), r.domain, false)) }
                a.append((String(localized: "Default Resolution"), "\(r.width) × \(r.height)", false))
                a.append((String(localized: "Color Depth"), String(localized: "\(r.colorDepth)-bit"), false))
                a.append((String(localized: "Security Layer"), r.security.label, false))
                if !host.group.isEmpty { a.append((String(localized: "Group"), host.group, false)) }
                return a
            }()
            VStack(alignment: .leading, spacing: 16) {
                sectionTitle("info.circle", String(localized: "Connection Info"))

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), alignment: .leading)],
                          alignment: .leading, spacing: 16) {
                    ForEach(items, id: \.0) { label, value, blur in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(label).font(.system(size: 11)).foregroundStyle(Pal.overlay)
                            Text(value).font(.system(size: 13, weight: .medium)).foregroundStyle(Pal.text)
                                .textSelection(.enabled)
                                .lineLimit(1).truncationMode(.middle)
                                .privacyBlur(blur && model.privacyMode)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .cardStyle()
        }
    }

    private var statusBadge: some View {
        let (label, fg, bg): (String, Color, Color) = {
            switch liveHost.status {
            case .online: return (String(localized: "Online"), Pal.green, Pal.green.opacity(0.15))
            case .offline: return (String(localized: "Offline"), Pal.overlay, Pal.overlay.opacity(0.15))
            case .unknown: return (String(localized: "Unknown"), Pal.yellow, Pal.yellow.opacity(0.15))
            }
        }()
        return Text(label).font(.system(size: 11)).foregroundStyle(fg)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(bg, in: RoundedRectangle(cornerRadius: 6))
    }

}

/// Native-style live host monitor with per-core CPU heatmap, memory, GPU cards, disks, network, and uptime.
/// Data streams from [[HostMonitor]]; adapt sections to available data, hide absent GPUs, and wrap large core grids.
private struct MonitorPanel: View {
    @ObservedObject var monitor: HostMonitor
    let accent: Color   // Host-theme accent for memory/disk/upload.
    let onEditConnection: () -> Void
    @ObservedObject private var theme = ThemeManager.shared
    @ObservedObject private var settings = AppSettings.shared

    // Accents: host for memory/disk/upload, green download, purple GPU/swap.
    private static let green = Color(hex: 0x28CD41)
    private static let purple = Color(hex: 0xAF52DE)

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 9) {
                Image(lucideSymbol: "waveform.path.ecg")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(accent)
                    .frame(width: 26, height: 26)
                    .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                Text("Monitoring")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Pal.textBright)
                Spacer()
                Circle().fill(monitor.phase == .live ? Self.green : Pal.overlay).frame(width: 6, height: 6)
            }
            if !settings.monitorNoticeHidden && !settings.monitorNoticeAckedThisSession {
                HStack(spacing: 10) {
                    Text("Note: Monitoring only collects data and reads status. It never runs or deploys any shell script on the target machine.")
                        .font(.system(size: 11)).foregroundStyle(Pal.subtext)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button { settings.monitorNoticeAckedThisSession = true } label: {
                        Text("Got It").font(.system(size: 11, weight: .medium)).foregroundStyle(accent)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .tooltip(String(localized: "Won't show again this session. To disable permanently, turn on \"Hide Monitoring Notice\" in Settings › General."))
                }
                .padding(12)
                .background(Pal.fill(0.035), in: RoundedRectangle(cornerRadius: 9))
            }
            content
        }
        .cardStyle()
    }

    @ViewBuilder
    private var content: some View {
        if let m = monitor.metrics {
            // Keep CPU/memory/network together; many-volume lists span the next row.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 14, alignment: .top)],
                      alignment: .leading, spacing: 14) {
                cpuSection(m)
                memorySection(m)
                networkSection(m)
            }
            if !m.gpus.isEmpty { gpuSection(m.gpus) }
            if !m.disks.isEmpty { diskSection(m.disks) }
            if m.cpuTempC != nil || m.diskReadBps != nil || m.iowaitPercent != nil { sensorsAndIOSection(m) }
            if !m.interfaces.isEmpty { interfacesSection(m) }
        } else if monitor.phase == .unsupported || monitor.phase == .stopped || monitor.phase == .authenticationFailed {
            VStack(alignment: .leading, spacing: 8) {
                Text(monitor.phase == .authenticationFailed
                     ? "Authentication failed. Check the username, password, or SSH key."
                     : monitor.phase == .stopped
                        ? "Monitoring stopped after repeated failures"
                        : "Real-time monitoring isn't supported on this system yet")
                    .font(.system(size: 13)).foregroundStyle(Pal.overlay)
                monitorErrorDetail
                HStack(spacing: 8) {
                    if monitor.phase == .authenticationFailed {
                        SecondaryButton(title: "Edit Host") { onEditConnection() }
                    }
                    SecondaryButton(title: "Retry") { monitor.retry() }
                }
            }
            .padding(.vertical, 6)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text(monitor.phase == .error ? "Monitoring connection lost, retrying…" : "Setting up monitoring…")
                        .font(.system(size: 12)).foregroundStyle(Pal.overlay)
                }
                if monitor.phase == .error { monitorErrorDetail }
            }
            .padding(.vertical, 6)
        }
    }

    /// Selectable/copyable monitor failure details, including connection errors, remote output, and exit code.
    @ViewBuilder
    private var monitorErrorDetail: some View {
        if let err = monitor.lastError {
            Text(verbatim: err)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Pal.subtext)
                .lineLimit(8)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Sections

    private func cpuSection(_ m: HostMetrics) -> some View {
        section("cpu", String(localized: "CPU Core Load")) {
            card {
                VStack(alignment: .leading, spacing: 11) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        num(m.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "—",
                            size: 22, weight: .bold, color: Pal.textBright)
                        if !m.perCore.isEmpty {
                            Text("\(m.perCore.count) cores").font(.system(size: 11)).foregroundStyle(Pal.overlay)
                        }
                        Spacer()
                    }
                    plainNum(String(format: String(localized: "Load %.2f / %.2f / %.2f"), m.load1, m.load5, m.load15),
                             size: 10, design: .monospaced, color: Pal.overlay)
                    if m.perCore.isEmpty {
                        Text("Sampling…").font(.system(size: 10)).foregroundStyle(Pal.overlay)
                    } else {
                        heatmap(m.perCore)
                    }
                }
            }
        }
    }

    /// Per-core heatmap grid wraps to available width with 10pt squares and 3pt gaps, sizing height automatically.
    /// Vector layers avoid bitmap drawing overhead; update colors on samples without continuous animation.
    private func heatmap(_ cores: [Double]) -> some View {
        let cell: CGFloat = 10, gap: CGFloat = 3
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: cell, maximum: cell), spacing: gap)],
                         alignment: .leading, spacing: gap) {
            ForEach(Array(cores.enumerated()), id: \.offset) { _, load in
                RoundedRectangle(cornerRadius: 2)
                    .fill(heatColor(load))
                    .frame(width: cell, height: cell)
            }
        }
    }

    /// Map utilization from cool green HSB hue 0.33 to warm red 0.
    /// Use a t-squared curve to keep low/moderate load calm green and reserve warm colors for high load, avoiding muddy yellow/olive midtones.
    /// In light mode reduce brightness and increase saturation for contrast against pale cards.
    private func heatColor(_ load: Double) -> Color {
        let t = min(1, max(0, load / 100))
        let warm = t * t
        let hue = 0.33 * (1 - warm)
        // Reduce brightness/saturation for a muted matte color instead of glaring green in dark mode.
        return theme.isDark
            ? Color(hue: hue, saturation: 0.58, brightness: 0.76)
            : Color(hue: hue, saturation: 0.78, brightness: 0.66)
    }

    private func memorySection(_ m: HostMetrics) -> some View {
        section("memorychip", String(localized: "Memory")) {
            card {
                VStack(spacing: 12) {
                    usageRow(name: String(localized: "Memory"), percent: m.memTotalKB > 0 ? m.memPercent : 0,
                             left: "\(human(m.memUsedKB)) / \(human(m.memTotalKB))", right: "RAM", color: accent)
                    if m.hasSwap {
                        usageRow(name: String(localized: "Swap"), percent: m.swapPercent,
                                 left: "\(human(m.swapUsedKB)) / \(human(m.swapTotalKB))", right: "SWAP", color: Self.purple)
                    }
                }
            }
        }
    }

    private func diskSection(_ disks: [DiskUsage]) -> some View {
        section("internaldrive", String(localized: "Volume")) {
            card {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 24)],
                          alignment: .leading, spacing: 14) {
                    ForEach(disks) { diskRow($0) }
                }
            }
        }
    }

    private func diskRow(_ d: DiskUsage) -> some View {
        usageRow(name: d.mount, percent: d.percent,
                 left: "\(human(d.usedKB)) / \(human(d.totalKB))",
                 right: d.percent >= 90 ? "CRITICAL" : "DISK", color: accent)
    }

    /// Linux CPU temperature, I/O wait, physical-disk rates/IOPS.
    private func sensorsAndIOSection(_ m: HostMetrics) -> some View {
        section("thermometer.medium", String(localized: "Temperature & Disk I/O")) {
            card {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 18)], alignment: .leading, spacing: 14) {
                    if let t = m.cpuTempC {
                        metric(String(localized: "CPU temperature"), String(format: "%.0f °C", t), t >= 85 ? Pal.red : (t >= 70 ? Pal.yellow : Pal.textBright))
                    }
                    if let w = m.iowaitPercent {
                        metric(String(localized: "I/O wait"), String(format: "%.1f %%", w), w >= 20 ? Pal.red : (w >= 5 ? Pal.yellow : Pal.textBright))
                    }
                    if m.diskReadBps != nil {
                        metric(String(localized: "Disk read"), rate(m.diskReadBps), Pal.textBright, sub: String(format: "%.0f IOPS", m.diskReadIOPS ?? 0))
                        metric(String(localized: "Disk write"), rate(m.diskWriteBps), Pal.textBright, sub: String(format: "%.0f IOPS", m.diskWriteIOPS ?? 0))
                    }
                }
            }
        }
    }

    /// Interface state/link speed/IP/current rate/cumulative traffic.
    private func interfacesSection(_ m: HostMetrics) -> some View {
        section("network", String(localized: "Network Interfaces")) {
            card {
                VStack(alignment: .leading, spacing: 10) {
                    if let rx = m.netRxTotal, let tx = m.netTxTotal {
                        HStack(spacing: 14) {
                            Text("Since boot").font(.system(size: 11)).foregroundStyle(Pal.overlay)
                            plainNum("↓ " + total(rx), size: 12, weight: .medium, design: .monospaced, color: Self.green)
                            plainNum("↑ " + total(tx), size: 12, weight: .medium, design: .monospaced, color: accent)
                            Spacer()
                        }
                        Divider().overlay(Pal.fill(0.06))
                    }
                    ForEach(m.interfaces.prefix(10)) { n in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Circle().fill(n.isUp ? Self.green : Pal.overlay).frame(width: 7, height: 7)
                            Text(verbatim: n.name).font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(Pal.text).frame(width: 90, alignment: .leading)
                            Text(verbatim: n.addresses.isEmpty ? "—" : n.addresses).font(.system(size: 11, design: .monospaced)).foregroundStyle(Pal.subtext).lineLimit(1)
                            if let sp = n.speedMbps { Text(verbatim: sp >= 1000 ? "\(sp / 1000) Gbps" : "\(sp) Mbps").font(.system(size: 10)).foregroundStyle(Pal.overlay) }
                            Spacer(minLength: 6)
                            plainNum("↓ " + rate(n.rxRate), size: 11, design: .monospaced, color: Self.green)
                            plainNum("↑ " + rate(n.txRate), size: 11, design: .monospaced, color: accent)
                            Text(verbatim: total(n.rxTotal) + " / " + total(n.txTotal)).font(.system(size: 10, design: .monospaced)).foregroundStyle(Pal.overlay)
                        }
                    }
                }
            }
        }
    }

    private func metric(_ label: String, _ value: String, _ color: Color, sub: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 10.5)).foregroundStyle(Pal.overlay)
            Text(verbatim: value).font(.system(size: 17, weight: .bold, design: .rounded)).foregroundStyle(color)
            if let sub { Text(verbatim: sub).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Pal.subtext) }
        }
    }

    private func total(_ bytes: Double) -> String {
        let f = ByteCountFormatter(); f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]; f.countStyle = .decimal
        return f.string(fromByteCount: Int64(bytes))
    }

    private func gpuSection(_ gpus: [GPUInfo]) -> some View {
        section("bolt", String(localized: "GPU (\(gpus.count))")) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 10)], alignment: .leading, spacing: 10) {
                ForEach(gpus) { g in gpuCard(g) }
            }
        }
    }

    private func gpuCard(_ g: GPUInfo) -> some View {
        card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(g.name).font(.system(size: 9, weight: .medium)).foregroundStyle(Pal.subtext)
                        .lineLimit(1).truncationMode(.tail)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Pal.fill(0.06), in: RoundedRectangle(cornerRadius: 3))
                    Spacer(minLength: 4)
                    num("\(g.tempC)°", size: 10, weight: .bold, color: Self.purple)
                }
                HStack(alignment: .bottom) {
                    num("\(Int(g.utilPercent))%", size: 17, weight: .bold, color: Pal.textBright)
                    Spacer(minLength: 6)
                    gpuDots(g.utilPercent)
                }
                bar(g.utilPercent, color: Self.purple)
                HStack {
                    Text("VRAM").font(.system(size: 9)).foregroundStyle(Pal.overlay)
                    Spacer()
                    plainNum("\(gib(g.memUsedMB)) / \(gib(g.memTotalMB)) GB", size: 9, design: .monospaced, color: Pal.overlay)
                }
            }
        }
    }

    /// GPU mini-grid: 5x2 dots, lighting the first N purple according to utilization and leaving the rest gray.
    private func gpuDots(_ util: Double) -> some View {
        let lit = Int((min(100, max(0, util)) / 10).rounded())
        return LazyVGrid(columns: Array(repeating: GridItem(.fixed(4), spacing: 3), count: 5), spacing: 3) {
            ForEach(0..<10, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i < lit ? Self.purple : Pal.fill(0.16))
                    .frame(width: 4, height: 4)
            }
        }
        .frame(width: 32)
        .animation(.easeOut(duration: 0.3), value: lit)
    }

    private func networkSection(_ m: HostMetrics) -> some View {
        section("network", String(localized: "Network")) {
            card {
                VStack(spacing: 10) {
                    GeometryReader { geo in
                        // Fixed-width rates avoid digit jitter; the chart fills remaining space.
                        // Stack upload/download vertically in narrow cards to prevent overflow.
                        let stacked = geo.size.width < 300
                        HStack(spacing: 12) {
                            NetSparkline(samples: monitor.netHistory, tick: monitor.netTick,
                                         interval: monitor.sampleInterval, down: Self.green, up: accent)
                                .frame(maxWidth: .infinity)
                                .frame(height: geo.size.height)
                            netStats(m, stacked: stacked).fixedSize()
                        }
                    }
                    .frame(height: 40)
                    Text(uptimeText(m.uptimeSecs))
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(Pal.overlay)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// Lay upload/download rates horizontally in wide cards and vertically in narrow ones; fixedSize prevents overflow/chart jitter.
    @ViewBuilder
    private func netStats(_ m: HostMetrics, stacked: Bool) -> some View {
        let down = netStat("arrow.down", rate(m.netRxBytesPerSec), Self.green)
        let up = netStat("arrow.up", rate(m.netTxBytesPerSec), accent)
        if stacked {
            VStack(alignment: .leading, spacing: 3) { down; up }
        } else {
            HStack(spacing: 14) { down; up }
        }
    }

    private func netStat(_ icon: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Image(lucideSymbol: icon).font(.system(size: 11, weight: .bold)).foregroundStyle(color)
            // Fix width so changing rate digits cannot resize the layout and shake the flexible chart.
            num(value, size: 12, weight: .semibold, color: Pal.text)
                .frame(width: 76, alignment: .leading)
        }
    }

    // MARK: Shared components

    /// Section with a small icon and muted title.
    private func section<C: View>(_ icon: String, _ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(lucideSymbol: icon).font(.system(size: 10, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(Pal.overlay)
            content()
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// macOS material card.
    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content()
            .padding(13)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Pal.fill(0.025), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Pal.fill(0.06), lineWidth: 1))
    }

    /// Shared memory/disk row: name, percentage, thin bar, and usage details. At >=90%, turn red and show a warning label.
    private func usageRow(name: String, percent: Double, left: String, right: String, color: Color) -> some View {
        let critical = percent >= 90
        return VStack(spacing: 5) {
            HStack {
                Text(name).font(.system(size: 11, weight: .medium)).foregroundStyle(Pal.text)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                num("\(Int(percent))%", size: 11, design: .default, color: Pal.subtext)
            }
            bar(percent, color: critical ? Pal.red : color)
            HStack {
                plainNum(left, size: 10, design: .monospaced, color: Pal.overlay)
                Spacer()
                Text(critical ? "CRITICAL" : right)
                    .font(.system(size: 9, weight: critical ? .bold : .regular))
                    .foregroundStyle(critical ? Pal.red : Pal.overlay)
            }
        }
    }

    /// Thin 4px progress bar.
    private func bar(_ percent: Double, color: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Pal.fill(0.10))
                Capsule().fill(color)
                    .frame(width: max(0, min(1, percent / 100)) * geo.size.width)
            }
        }
        .frame(height: 4)
        .animation(.easeOut(duration: 0.45), value: percent)
    }

    /// Use contentTransition.numericText for odometer-style upward digit transitions and monospaced digits for stable width.
    /// Key the animation by the displayed string so it triggers only when displayed content changes.
    private func num(_ s: String, size: CGFloat, weight: Font.Weight = .regular,
                     design: Font.Design = .rounded, color: Color) -> some View {
        Text(s)
            .font(.system(size: size, weight: weight, design: design))
            .foregroundStyle(color)
            .monospacedDigit()
            .contentTransition(.numericText())
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: s)
    }

    /// Secondary numbers stay monospaced without numericText transitions, avoiding expensive simultaneous per-glyph animations.
    private func plainNum(_ s: String, size: CGFloat, weight: Font.Weight = .regular,
                          design: Font.Design = .rounded, color: Color) -> some View {
        Text(s)
            .font(.system(size: size, weight: weight, design: design))
            .foregroundStyle(color)
            .monospacedDigit()
    }

    // MARK: Formatting

    /// Format kB (1K blocks) using base 1000 to match overview-spec units.
    private func human(_ kb: Int64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        f.countStyle = .decimal
        return f.string(fromByteCount: kb * 1024)
    }

    /// Convert VRAM MiB to GiB with one decimal, matching nvidia-smi conventions.
    private func gib(_ mb: Int64) -> String { String(format: "%.1f", Double(mb) / 1024) }

    private func rate(_ bps: Double?) -> String {
        guard let bps else { return "—" }
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.countStyle = .decimal
        return f.string(fromByteCount: Int64(bps)) + "/s"
    }

    private func uptimeText(_ secs: Double) -> String {
        let s = Int(secs)
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return String(localized: "Up \(d)d \(h)h \(m)m") }
        if h > 0 { return String(localized: "Up \(h)h \(m)m") }
        return String(localized: "Up \(m) min")
    }
}

/// Network chart: smooth download-green/upload-blue curves moving left at a steady conveyor-belt rate.
/// Use native vector Shape strokes and TimelineView frame limiting instead of Canvas bitmap layers to reduce memory.
/// At one grid step every 1-2 seconds, 20fps is smooth. Drive phase by elapsed time since the last sample divided by sample interval.
private struct NetSparkline: View {
    let samples: [NetSample]
    let tick: Int
    let interval: Double
    let down: Color
    let up: Color
    @State private var lastTick: Date = .distantPast

    private static let visible = 40
    private static let fps = 20.0
    private static let stroke = StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)

    var body: some View {
        // Reuse rx/tx/maxV between samples; do not recompute them on every TimelineView frame.
        let maxV = max(1, samples.flatMap { [$0.rx, $0.tx] }.max() ?? 1)
        let rx = win(samples.map(\.rx), maxV)
        let tx = win(samples.map(\.tx), maxV)
        TimelineView(.animation(minimumInterval: 1.0 / Self.fps)) { tl in
            let phase = phase(at: tl.date)
            ZStack {
                NetCurve(values: rx, phase: phase, visible: Self.visible).stroke(down.opacity(0.9), style: Self.stroke)
                NetCurve(values: tx, phase: phase, visible: Self.visible).stroke(up.opacity(0.9), style: Self.stroke)
            }
            .clipped()   // Shape does not clip automatically like Canvas; clip offscreen points at both sides.
        }
        .onChange(of: tick) { _ in lastTick = Date() }
    }

    /// Scroll phase 0..1 is the elapsed fraction since the last sample; hold at 1 before sampling starts.
    private func phase(at now: Date) -> CGFloat {
        guard lastTick != .distantPast else { return 1 }
        return CGFloat(min(1, max(0, now.timeIntervalSince(lastTick) / interval)))
    }

    /// Normalize the latest visible+2 samples to 0..1, leaving one offscreen point per side; pad initial shortages with the first value for seamless movement.
    private func win(_ raw: [Double], _ maxV: Double) -> [Double] {
        let n = Self.visible + 2
        let norm = raw.map { min(1, max(0, $0 / maxV)) }
        if norm.count >= n { return Array(norm.suffix(n)) }
        return Array(repeating: norm.first ?? 0, count: n - norm.count) + norm
    }
}

/// Catmull-Rom smooth line through normalized points; count=visible+2.
/// Draw point i at x=(i-phase)*step. phase 0->1 shifts left one step; offscreen points keep [0,width] boundaries continuous without edge jumps.
private struct NetCurve: Shape {
    let values: [Double]
    let phase: CGFloat
    let visible: Int

    func path(in rect: CGRect) -> Path {
        guard values.count > 1 else { return Path() }
        let step = rect.width / CGFloat(visible)
        let pts = values.enumerated().map { i, y in
            CGPoint(x: (CGFloat(i) - phase) * step, y: rect.height * (1 - CGFloat(min(1, max(0, y)))))
        }
        var path = Path()
        path.move(to: pts[0])
        for i in 0..<pts.count - 1 {
            let p0 = i > 0 ? pts[i - 1] : pts[i]
            let p1 = pts[i]
            let p2 = pts[i + 1]
            let p3 = i + 2 < pts.count ? pts[i + 2] : p2
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        return path
    }
}


private extension View {
    /// Shared overview-card appearance.
    func cardStyle(minHeight: CGFloat = 0) -> some View {
        self.padding(18)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
            .background(Pal.fill(0.025), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Pal.fill(0.08), lineWidth: 1))
    }
}


/// Consistent hover feedback for overview tiles and file rows.
private struct OverviewHoverStyle: ButtonStyle {
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Pal.fill(hovered ? 0.065 : 0), in: RoundedRectangle(cornerRadius: 10))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .onHover { hovered = $0 }
    }
}

/// Log row shows name/path and a close button on hover.
private struct LogRow: View {
    let path: String
    let accent: Color
    let onOpen: () -> Void
    let onRemove: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 9) {
            Button(action: onOpen) {
                HStack(spacing: 9) {
                    Image(lucideSymbol: "text.append").font(.system(size: 12)).foregroundStyle(accent).frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: (path as NSString).lastPathComponent)
                            .font(.system(size: 12.5, weight: .medium)).foregroundStyle(Pal.text).lineLimit(1)
                        Text(verbatim: (path as NSString).deletingLastPathComponent)
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(Pal.overlay)
                            .lineLimit(1).truncationMode(.head)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointerCursor()
            Button(action: onRemove) {
                Image(lucideSymbol: "xmark").font(.system(size: 9)).foregroundStyle(Pal.overlay)
                    .frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointerCursor().help(String(localized: "Remove from Logs"))
            .opacity(hover ? 1 : 0)
            .allowsHitTesting(hover)
            .accessibilityHidden(!hover)
        }
        .padding(8)
        .background(Pal.fill(hover ? 0.065 : 0), in: RoundedRectangle(cornerRadius: 10))
        .onHover { hover = $0 }
        .contextMenu { Button("Remove from Logs", role: .destructive, action: onRemove) }
    }
}


/// Save MAC/optional broadcast and send magic packets; detect server MAC through SSH when available.
private struct WakePopover: View {
    @ObservedObject var model: AppModel
    let host: Host
    @State private var mac = ""
    @State private var broadcast = ""
    @State private var detecting = false
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Wake-on-LAN").font(.system(size: 13, weight: .semibold)).foregroundStyle(Pal.text)
            Text("Sends a magic packet from this Mac to power on a sleeping or powered-off server. The server's network card must have Wake-on-LAN enabled (BIOS/UEFI and the OS), and this Mac must be on the same network.")
                .font(.system(size: 11)).foregroundStyle(Pal.overlay).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                Text("MAC address").font(.system(size: 11)).foregroundStyle(Pal.subtext)
                HStack(spacing: 6) {
                    ThemedTextField(verbatim: "aa:bb:cc:dd:ee:ff", text: $mac)
                    if host.ssh != nil {
                        Button { detect() } label: {
                            HStack(spacing: 4) { if detecting { ProgressView().controlSize(.mini) }; Text("Detect") }
                                .font(.system(size: 11)).foregroundStyle(Pal.tint).padding(.horizontal, 8).padding(.vertical, 6)
                                .background(Pal.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
                        }.buttonStyle(.plain).pointerCursor().disabled(detecting).help(String(localized: "Read the MAC address from the server over SSH (needs it to be online)"))
                    }
                }
                if !mac.isEmpty, WakeOnLAN.parseMAC(mac) == nil { Text("That doesn't look like a MAC address.").font(.system(size: 10.5)).foregroundStyle(Pal.yellow) }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Broadcast address (optional)").font(.system(size: 11)).foregroundStyle(Pal.subtext)
                ThemedTextField(verbatim: "192.168.0.255", text: $broadcast)
            }
            HStack {
                Spacer()
                SecondaryButton(title: "Save") { model.setWOL(hostId: host.id, mac: mac, broadcast: broadcast) }
                PrimaryButton(title: "Send Wake Packet", enabled: WakeOnLAN.parseMAC(mac) != nil, tint: Pal.tint) {
                    model.setWOL(hostId: host.id, mac: mac, broadcast: broadcast); model.wake(host)
                }
            }
        }
        .padding(16).frame(width: 360)
        .onAppear { if !loaded { loaded = true; mac = model.wolMacs[host.id] ?? ""; broadcast = model.wolBroadcasts[host.id] ?? "" } }
    }

    private func detect() {
        guard let ssh = host.ssh else { return }
        detecting = true
        Task {
            let r = await RemoteFS(ssh).run(PowerCommands.detectMAC, timeout: 15)
            let out = String(decoding: r.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if let m = WakeOnLAN.parseMAC(out) { mac = WakeOnLAN.format(m) } else { model.keyOpError = String(localized: "Couldn't read the MAC address from the server.") }
            detecting = false
        }
    }
}

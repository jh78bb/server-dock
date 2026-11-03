import SwiftUI

/// Bottom workspace status bar shows server connection/latency/cwd,
/// optional CPU/memory/load and active transfers/forwarding, only for connected active SSH hosts.
struct StatusBar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var tabs: TabsModel
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        let host = model.statusBarHost
        // Keep a zero-sized anchor mounted so onAppear/onChange run even without content.
        VStack(spacing: 0) {
            Color.clear.frame(width: 0, height: 0)
            if let host {
                content(host)
            } else if let rd = model.activeRemoteDesktopSession {
                RemoteDesktopStatusBar(session: rd, model: model)
            }
        }
        .onAppear { syncMonitor(host) }
        .onChange(of: host?.id) { _ in syncMonitor(model.statusBarHost) }
        .onChange(of: settings.statusBarLiveStats) { _ in syncMonitor(model.statusBarHost) }
    }

    private func content(_ host: Host) -> some View {
        HStack(spacing: 12) {
            if let term = tabs.terminalTab(inGroup: host.id), let conn = model.terminalConn(for: term.id) {
                ConnectionStatus(model: model, host: host, conn: conn)
                divider
                PathStatus(conn: conn)
                if settings.statusBarGit { GitStatus(host: host, conn: conn) }
            } else {
                ConnectionStatus(model: model, host: host, conn: nil)
            }
            Spacer(minLength: 8)
            if settings.statusBarLiveStats {
                LiveStats(monitor: model.hostMonitor(for: host))
                divider
            }
            TransferForwardStatus(model: model, host: host)
            divider
            liveToggle
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .frame(maxWidth: .infinity)
        // Separate rounded panel matching workspace/file panels above.
        .background(Pal.base)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.leading, 3).padding(.trailing, 6).padding(.top, 3).padding(.bottom, 6)
    }

    /// Section separator.
    private var divider: some View {
        Rectangle().fill(Pal.fill(0.14)).frame(width: 1, height: 16)
    }

    private var liveToggle: some View {
        Button { settings.statusBarLiveStats.toggle() } label: {
            HStack(spacing: 4) {
                Image(lucideSymbol: "waveform.path.ecg").font(.system(size: 11, weight: .medium))
                if !settings.statusBarLiveStats {
                    Text("Live Stats").font(.system(size: 11))
                }
            }
            .foregroundStyle(settings.statusBarLiveStats ? Pal.tint : Pal.overlay)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor()
        .help(settings.statusBarLiveStats
              ? String(localized: "Stop live CPU/memory stats")
              : String(localized: "Show live CPU/memory stats (opens one extra background connection to this server)"))
    }

    /// Retain monitoring while status-bar metrics are requested, even without overview.
    private func syncMonitor(_ host: Host?) {
        let want = settings.statusBarLiveStats ? host : nil
        let old = model.statusBarMonitorHostId
        model.statusBarMonitorHostId = want?.id
        if let old, old != want?.id { model.overviewDisappeared(old) }
        if let want { model.overviewAppeared(want) }
    }
}

/// Connection dot, server name, user@host, latency.
private struct ConnectionStatus: View {
    @ObservedObject var model: AppModel
    let host: Host
    let conn: TerminalConn?

    var body: some View {
        HStack(spacing: 7) {
            if let conn { Dot(conn: conn, host: host) } else { Circle().fill(Pal.green).frame(width: 7, height: 7) }
            Text(host.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(host.accent).lineLimit(1)
            Text(verbatim: host.addr).font(.system(size: 12)).foregroundStyle(Pal.overlay).lineLimit(1)
                .privacyBlur(model.privacyMode)
            if host.status == .offline {
                Text("Offline").font(.system(size: 12)).foregroundStyle(Pal.red)
            } else if let ms = host.latencyMs {
                Text(verbatim: "\(ms) ms").font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(LatencyLevel(ms: ms).color)
                    .help(String(localized: "Response time to this server (refreshed every 30 seconds)"))
            }
        }
        .fixedSize()
    }

    private struct Dot: View {
        @ObservedObject var conn: TerminalConn
        let host: Host
        var body: some View {
            let dropped = conn.phase == .dropped
            Circle().fill(dropped ? Pal.yellow : Pal.green).frame(width: 7, height: 7)
                .help(dropped ? String(localized: "Disconnected — reconnecting…") : String(localized: "Connected"))
        }
    }
}

/// OSC 7 cwd; click copies the path.
private struct PathStatus: View {
    @ObservedObject var conn: TerminalConn
    @State private var copied = false

    var body: some View {
        if let cwd = conn.cwd {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(cwd, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            } label: {
                HStack(spacing: 5) {
                    Image(lucideSymbol: copied ? "checkmark" : "folder.fill").font(.system(size: 10))
                        .foregroundStyle(copied ? Pal.green : Pal.overlay)
                    Text(verbatim: cwd).font(.system(size: 12, design: .monospaced)).foregroundStyle(Pal.subtext)
                        .lineLimit(1).truncationMode(.head)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Pal.fill(0.06), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointerCursor()
            .help(String(localized: "Click to copy the current path"))
        }
    }
}

/// Live CPU/memory/load/uptime while monitoring runs.
private struct LiveStats: View {
    @ObservedObject var monitor: HostMonitor

    var body: some View {
        if let m = monitor.metrics {
            HStack(spacing: 10) {
                if let cpu = m.cpuPercent { stat("CPU", String(format: "%.0f%%", cpu), level: cpu) }
                stat("MEM", String(format: "%.0f%%", m.memPercent), level: m.memPercent)
                stat("LOAD", String(format: "%.2f", m.load1), level: nil)
                if m.uptimeSecs > 0 { stat("UP", Self.uptime(m.uptimeSecs), level: nil) }
            }
            .fixedSize()
        } else if monitor.phase == .error || monitor.phase == .stopped || monitor.phase == .unsupported {
            Text("Stats unavailable").font(.system(size: 10)).foregroundStyle(Pal.overlay)
        } else {
            ProgressView().controlSize(.mini).scaleEffect(0.6)
        }
    }

    private func stat(_ label: String, _ value: String, level: Double?) -> some View {
        HStack(spacing: 4) {
            Text(verbatim: label).font(.system(size: 10, weight: .semibold)).foregroundStyle(Pal.overlay)
            Text(verbatim: value).font(.system(size: 12, design: .monospaced))
                .foregroundStyle(color(level))
        }
    }

    private func color(_ level: Double?) -> Color {
        guard let level else { return Pal.subtext }
        return level >= 90 ? Pal.red : (level >= 70 ? Pal.yellow : Pal.subtext)
    }

    private static func uptime(_ secs: Double) -> String {
        let s = Int(secs)
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}

/// Background tray opens task popover and shows forwarding count.
/// Show active transfer count beside the tray.
private struct TransferForwardStatus: View {
    @ObservedObject var model: AppModel
    let host: Host
    @State private var showTasks = false

    var body: some View {
        let active = model.nonForwardActiveCount
        let forwards = model.activeForwardCount(hostId: host.id)
        HStack(spacing: 12) {
            if forwards > 0 {
                Button { model.openForwardPanel(host) } label: {
                    HStack(spacing: 3) {
                        Image(lucideSymbol: "arrow.left.arrow.right").font(.system(size: 10))
                        Text(verbatim: "\(forwards)").font(.system(size: 12, design: .monospaced))
                    }
                    .foregroundStyle(Pal.green)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointerCursor()
                .help(String(localized: "Active port forwards — click to manage"))
            }
            Button { showTasks.toggle() } label: {
                HStack(spacing: 4) {
                    Image(lucideSymbol: "arrow.up.arrow.down").font(.system(size: 10, weight: .medium))
                    Text("Transfers").font(.system(size: 11))
                    if active > 0 {
                        Text(verbatim: "\(active)").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Pal.tint, in: Capsule())
                    }
                }
                .foregroundStyle(active > 0 || showTasks ? Pal.tint : Pal.overlay)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointerCursor()
            .help(String(localized: "Uploads, downloads and other background tasks"))
            .popover(isPresented: $showTasks, arrowEdge: .top) {
                BackgroundCenterPanel(model: model, dismiss: { showTasks = false })
            }
        }
        .fixedSize()
    }
}


// MARK: - Git information

/// Status-bar repository state from porcelain v2 branch status and latest commit.
struct GitInfo: Equatable {
    var branch: String
    var detached: Bool
    var upstream: String?
    var ahead = 0
    var behind = 0
    var changed = 0
    var untracked = 0
    var lastCommit: String?   // "abc1234  subject  3 hours ago"

    var isClean: Bool { changed == 0 && untracked == 0 }

    static func parse(_ output: String) -> GitInfo? {
        let parts = output.components(separatedBy: "\n---\n")
        var info = GitInfo(branch: "", detached: false)
        var oid = ""
        var sawHead = false
        for line in parts[0].split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("# branch.oid ") { oid = String(line.dropFirst(13)) }
            else if line.hasPrefix("# branch.head ") {
                let h = String(line.dropFirst(14)); sawHead = true
                if h == "(detached)" { info.detached = true } else { info.branch = h }
            } else if line.hasPrefix("# branch.upstream ") { info.upstream = String(line.dropFirst(18)) }
            else if line.hasPrefix("# branch.ab ") {
                for tok in line.dropFirst(12).split(separator: " ") {
                    if tok.hasPrefix("+") { info.ahead = Int(tok.dropFirst()) ?? 0 }
                    if tok.hasPrefix("-") { info.behind = Int(tok.dropFirst()) ?? 0 }
                }
            } else if line.hasPrefix("1 ") || line.hasPrefix("2 ") || line.hasPrefix("u ") { info.changed += 1 }
            else if line.hasPrefix("? ") { info.untracked += 1 }
        }
        guard sawHead else { return nil }
        if info.detached { info.branch = String(oid.prefix(7)) }
        if parts.count > 1 {
            let f = parts[1].trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\t")
            if f.count >= 3 { info.lastCommit = "\(f[0])  \(f[1])  ·  \(f[2])" }
            else if !f[0].isEmpty { info.lastCommit = f.joined(separator: "  ") }
        }
        return info
    }

    /// Read-only cwd queries return nil outside repositories/on failure.
    /// Disable fsmonitor against configured arbitrary commands, avoid locks, and enforce five-second timeout.
    static func fetch(host: Host, cwd: String) async -> GitInfo? {
        guard let ssh = host.ssh else { return nil }
        let b64 = Data(cwd.utf8).base64EncodedString()
        let script = """
        P=$(printf %s '\(b64)' | base64 -d) || exit 1
        cd "$P" 2>/dev/null || exit 1
        T=""; command -v timeout >/dev/null 2>&1 && T="timeout 5"
        GIT_OPTIONAL_LOCKS=0 $T git -c core.fsmonitor=false status --porcelain=v2 --branch 2>/dev/null || exit 1
        echo '---'
        GIT_OPTIONAL_LOCKS=0 $T git -c core.fsmonitor=false log -1 --format='%h%x09%s%x09%cr' 2>/dev/null
        exit 0
        """
        let quoted = "'" + script.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let r = await RemoteFS(ssh).run("sh -c \(quoted)", timeout: 8)
        guard r.code == 0, let out = String(data: r.data, encoding: .utf8) else {
            // Silently ignore nonrepository exit 1 without stderr; log only connection/execution failures.
            let err = String(data: r.stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if r.code == -1 || !err.isEmpty { NSLog("[Git] %@ — exit %d %@", cwd, r.code, err) }
            return nil
        }
        return parse(out)
    }
}

/// Branch/change/ahead-behind badge refreshes on cwd changes/every 30s; click opens details.
private struct GitStatus: View {
    let host: Host
    @ObservedObject var conn: TerminalConn
    @State private var info: GitInfo?
    @State private var showDetail = false
    @State private var refresh = 0

    private struct Key: Equatable { let cwd: String?; let dropped: Bool; let refresh: Int }

    var body: some View {
        // Empty Groups do not mount .task; attach to a persistent zero-sized view.
        ZStack {
            Color.clear.frame(width: 0, height: 0)
                .task(id: Key(cwd: conn.cwd, dropped: conn.phase == .dropped, refresh: refresh)) {
                    guard let cwd = conn.cwd, conn.phase == .live else { info = nil; return }
                    while !Task.isCancelled {
                        let result = await GitInfo.fetch(host: host, cwd: cwd)
                        if Task.isCancelled { return }
                        info = result
                        if result == nil { return }   // Stop polling nonrepositories until cwd changes.
                        try? await Task.sleep(nanoseconds: 30_000_000_000)
                    }
                }
            if let info { badge(info) }
        }
        .fixedSize()
    }

    private func badge(_ info: GitInfo) -> some View {
        Button { showDetail.toggle() } label: {
            HStack(spacing: 5) {
                Image(lucideSymbol: "arrow.triangle.branch").font(.system(size: 10, weight: .medium)).foregroundStyle(Pal.tint)
                Text(verbatim: info.branch).font(.system(size: 12, design: .monospaced)).lineLimit(1)
                    .frame(maxWidth: 160, alignment: .leading)
                if info.ahead > 0 { Text(verbatim: "↑\(info.ahead)").font(.system(size: 11, design: .monospaced)).foregroundStyle(Pal.green) }
                if info.behind > 0 { Text(verbatim: "↓\(info.behind)").font(.system(size: 11, design: .monospaced)).foregroundStyle(Pal.yellow) }
                if info.isClean {
                    Image(lucideSymbol: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Pal.green)
                } else {
                    Text(verbatim: "●\(info.changed + info.untracked)").font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Pal.yellow)
                }
            }
            .foregroundStyle(Pal.subtext)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Pal.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor()
        .help(String(localized: "Git status of the current folder"))
        .popover(isPresented: $showDetail, arrowEdge: .top) { detail(info) }
    }

    private func detail(_ info: GitInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(lucideSymbol: "arrow.triangle.branch").foregroundStyle(Pal.tint)
                Text(verbatim: info.branch).font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Pal.text)
                if info.detached { Text("detached").font(.system(size: 10)).foregroundStyle(Pal.yellow) }
            }
            row("Upstream", info.upstream ?? String(localized: "None"))
            if info.upstream != nil {
                row("Ahead / Behind", "↑\(info.ahead)  ↓\(info.behind)")
            }
            row("Changed files", "\(info.changed)")
            row("Untracked files", "\(info.untracked)")
            if let last = info.lastCommit { row("Last commit", last) }
            Divider().overlay(Pal.fill(0.08))
            HStack {
                Text("Updated every 30 seconds").font(.system(size: 10)).foregroundStyle(Pal.overlay)
                Spacer()
                Button { refresh += 1 } label: {
                    Label("Refresh", lucideSymbol: "arrow.clockwise").font(.system(size: 11)).foregroundStyle(Pal.tint)
                }
                .buttonStyle(.plain).pointerCursor()
            }
        }
        .padding(14)
        .frame(width: 320)
        .background(Pal.solidBase)
    }

    private func row(_ title: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title).font(.system(size: 11)).foregroundStyle(Pal.overlay).frame(width: 96, alignment: .leading)
            Text(verbatim: value).font(.system(size: 11, design: .monospaced)).foregroundStyle(Pal.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

/// VNC/RDP status bar shows connection/protocol/address/user/resolution/duration/latency.
private struct RemoteDesktopStatusBar: View {
    @ObservedObject var session: RDPSession
    @ObservedObject var model: AppModel

    private var host: Host { model.host(session.host.id) ?? session.host }
    private var conn: RDPConnection? { host.rdp }

    private var state: (String, Color) {
        switch session.phase {
        case .pending: return (String(localized: "Not connected"), Pal.overlay)
        case .connecting: return (String(localized: "Connecting…"), Pal.yellow)
        case .connected: return (String(localized: "Connected"), Pal.green)
        case .failed: return (String(localized: "Connection failed"), Pal.red)
        case .disconnected: return (String(localized: "Disconnected"), Pal.red)
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Circle().fill(state.1).frame(width: 7, height: 7)
                Text(state.0).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Pal.text)
            }
            if let c = conn {
                divider
                item("display", c.protocolType == .vnc ? "VNC" : "RDP")
                item("network", "\(c.host):\(String(c.port))", blur: true)
                if !c.user.isEmpty { item("person", c.user, blur: true) }
            }
            if let img = session.image { divider; item("rectangle.dashed", "\(img.width) × \(img.height)") }
            Spacer(minLength: 8)
            if let since = session.connectedAt, session.phase == .connected {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    item("clock", duration(ctx.date.timeIntervalSince(since)))
                }
            }
            if host.status == .online, let ms = host.latencyMs {
                divider
                item("waveform.path", "\(ms) ms")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .frame(maxWidth: .infinity)
        .background(Pal.base)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.leading, 3).padding(.trailing, 6).padding(.top, 3).padding(.bottom, 6)
    }

    private var divider: some View { Rectangle().fill(Pal.fill(0.14)).frame(width: 1, height: 16) }

    private func item(_ symbol: String, _ text: String, blur: Bool = false) -> some View {
        HStack(spacing: 5) {
            Image(lucideSymbol: symbol).font(.system(size: 10.5)).foregroundStyle(Pal.overlay)
            Text(verbatim: text).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Pal.subtext)
                .lineLimit(1).privacyBlur(blur && model.privacyMode)
        }
    }

    private func duration(_ t: TimeInterval) -> String {
        let s = Int(max(0, t)); return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}

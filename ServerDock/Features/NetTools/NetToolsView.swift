import SwiftUI

/// Network-tool request defaults to server execution for nonlocal hosts.
struct NetToolsRequest: Identifiable {
    let id = UUID()
    var host: Host? = nil
    var tool: NetTool = .info
    var target: String = ""
    var ports: String? = nil
}

@MainActor
final class NetToolsSession: ObservableObject {
    @Published var lines: [ToolLine] = []
    @Published var running = false
    let tool: NetTool
    @Published var target = ""
    @Published var onServer = false
    @Published var serverId = ""
    @Published var portsText = "80,443"
    @Published var pingCount = 4
    @Published var dnsType: LocalNet.DNSType = .all
    @Published var resolverIdx = 0
    @Published var timeoutSec = 2
    @Published var showClosed = false
    @Published var includeExpired = false
    @Published var resolveNames = true
    @Published var maxHops = 20
    @Published var httpHead = false
    @Published var httpFollow = true
    @Published var httpInsecure = false
    @Published var portFilter = ""
    @Published var lineFilter = ""
    init(tool: NetTool) { self.tool = tool }
    private var task: Task<Void, Never>?
    private var pending: [ToolLine] = []
    private var flushScheduled = false

    /// Batch lines from multiple threads to prevent scrolling/redraw storms.
    nonisolated func emit(_ line: ToolLine) {
        Task { @MainActor in
            self.pending.append(line)
            if !self.flushScheduled {
                self.flushScheduled = true
                try? await Task.sleep(nanoseconds: 60_000_000)
                self.lines.append(contentsOf: self.pending); self.pending.removeAll(); self.flushScheduled = false
            }
        }
    }

    func start(_ work: @escaping @Sendable () async -> Void) {
        guard !running else { return }
        lines = []; running = true
        task = Task.detached { [weak self] in
            await work()
            try? await Task.sleep(nanoseconds: 120_000_000)
            await MainActor.run { self?.running = false }
        }
    }

    func stop() { task?.cancel() }

    func apply(_ r: NetToolsRequest) {
        if let h = r.host, !h.isLocal, h.ssh != nil { onServer = true; serverId = h.id }
        if !r.target.isEmpty { target = r.target }
        if let p = r.ports { portsText = p }
    }

    func clear() { lines = [] }
}

struct NetToolsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var f: NetToolsSession
    @ObservedObject private var theme = ThemeManager.shared
    private var session: NetToolsSession { f }

    private var servers: [Host] { model.hosts.filter { !$0.isLocal && $0.ssh != nil } }
    private var serverHost: Host? { servers.first { $0.id == f.serverId } ?? servers.first }
    private var remote: Bool { f.tool.hasLocation && f.onServer && serverHost != nil }
    private var tint: Color { Pal.tint }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                Divider().overlay(Pal.fill(0.06))
                if f.tool == .ports { portReference } else { runner }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Pal.solidBase)
        .preferredColorScheme(theme.isDark ? .dark : .light)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: f.tool.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Pal.text)
                Text(verbatim: f.tool.summary).font(.system(size: 11.5)).foregroundStyle(Pal.overlay)
            }
            Spacer()
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    // MARK: Execution view

    private var runner: some View {
        VStack(alignment: .leading, spacing: 10) {
            if f.tool.hasLocation { locationRow }
            HStack(spacing: 8) {
                if f.tool.needsTarget {
                    ThemedTextField(verbatim: f.tool.targetPlaceholder, text: $f.target, autofocus: true, onSubmit: run)
                }
                if f.tool == .tcp || f.tool == .udp {
                    ThemedTextField(verbatim: "80,443,8000-8100", text: $f.portsText, onSubmit: run).frame(width: 190)
                    Menu {
                        ForEach(PortSpec.presets, id: \.0) { p in Button(p.0) { f.portsText = p.1 } }
                    } label: { Image(lucideSymbol: "list.bullet") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
                if f.tool == .ssl { ThemedTextField(verbatim: "443", text: $f.portsText, onSubmit: run).frame(width: 70) }
                if session.running {
                    SecondaryButton(title: "Stop") { session.stop() }
                } else {
                    PrimaryButton(title: f.tool == .subnet ? "Calculate" : "Run", enabled: canRun, tint: tint, action: run)
                }
            }
            options
            if f.tool == .http { httpExtras }
            console
        }
        .padding(18)
    }

    private var locationRow: some View {
        HStack(spacing: 10) {
            SegmentedControl(options: [(value: false, label: LocalizedStringKey("This Mac")), (value: true, label: LocalizedStringKey("Server"))], selection: $f.onServer)
                .frame(width: 200)
            if f.onServer {
                if servers.isEmpty {
                    Text("No SSH servers saved.").font(.system(size: 11.5)).foregroundStyle(Pal.overlay)
                } else {
                    Menu {
                        ForEach(servers) { h in Button(h.name) { f.serverId = h.id } }
                    } label: {
                        HStack(spacing: 5) { Text(verbatim: serverHost?.name ?? ""); Image(lucideSymbol: "chevron.up.chevron.down").font(.system(size: 9)) }
                            .font(.system(size: 12)).foregroundStyle(Pal.text)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
            }
            Spacer()
        }
    }

    /// HTTP Check uses the selected server's saved URL and terminal curl action.
    @ViewBuilder private var httpExtras: some View {
        let host: Host? = remote ? serverHost : model.localHost
        let saved = host.map { model.httpChecks(for: $0.id) } ?? []
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let host, let url = HTTPChecker.normalizedURL(f.target) {
                    Button { model.addHTTPCheck(HTTPCheckItem(url: url.absoluteString, fromServer: remote, head: f.httpHead, insecure: f.httpInsecure), host: host) } label: {
                        Label(String(localized: "Save"), lucideSymbol: "star").font(.system(size: 11.5))
                    }.buttonStyle(.plain).foregroundStyle(Pal.subtext).pointerCursor()
                        .help(String(localized: "Keep this address in the saved list for this host"))
                    Button {
                        let flags = (f.httpHead ? " -I" : "") + (f.httpFollow ? " -L" : "") + (f.httpInsecure ? " -k" : "")
                        model.sendCommandToTerminal(hostId: host.id, command: "curl -sS -i\(flags) -m 15 " + RemoteNet.q(url.absoluteString))
                    } label: { Label(String(localized: "Run in Terminal"), lucideSymbol: "terminal").font(.system(size: 11.5)) }
                        .buttonStyle(.plain).foregroundStyle(Pal.subtext).pointerCursor()
                        .help(String(localized: "Send the equivalent curl command to \(host.name)'s terminal"))
                }
                Spacer()
            }
            if !saved.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(saved) { item in
                            Button { f.target = item.url; f.httpHead = item.head; f.httpInsecure = item.insecure } label: {
                                Text(verbatim: item.display).font(.system(size: 11.5)).foregroundStyle(Pal.text).lineLimit(1)
                                    .padding(.horizontal, 9).padding(.vertical, 4).background(Pal.fill(0.06), in: Capsule())
                            }
                            .buttonStyle(.plain).pointerCursor()
                            .contextMenu { Button("Remove", role: .destructive) { if let h = host { model.removeHTTPCheck(item, hostId: h.id) } } }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var options: some View {
        HStack(spacing: 16) {
            switch f.tool {
            case .ping:
                Stepper("Count: \(f.pingCount)", value: $f.pingCount, in: 1...30)
            case .dns:
                Menu {
                    ForEach(LocalNet.DNSType.allCases) { t in Button(t.rawValue) { f.dnsType = t } }
                } label: { Text("Type: \(f.dnsType.rawValue)") }.menuStyle(.borderlessButton).fixedSize()
                Menu {
                    ForEach(Array(LocalNet.resolvers.enumerated()), id: \.offset) { i, r in Button(r.name) { f.resolverIdx = i } }
                } label: { Text("Resolver: \(LocalNet.resolvers[f.resolverIdx].name)") }.menuStyle(.borderlessButton).fixedSize()
            case .tcp, .udp:
                Stepper("Timeout: \(f.timeoutSec) s", value: $f.timeoutSec, in: 1...10)
                if f.tool == .tcp { Toggle("Show closed ports", isOn: $f.showClosed).toggleStyle(.checkbox) }
            case .http:
                SegmentedControl(options: [(value: false, verbatim: "GET"), (value: true, verbatim: "HEAD")], selection: $f.httpHead).frame(width: 120)
                Toggle("Follow redirects", isOn: $f.httpFollow).toggleStyle(.checkbox)
                Toggle("Ignore certificate errors", isOn: $f.httpInsecure).toggleStyle(.checkbox)
            case .trace:
                Stepper("Max hops: \(f.maxHops)", value: $f.maxHops, in: 5...40)
            case .subdomains:
                Toggle("Include expired certificates", isOn: $f.includeExpired).toggleStyle(.checkbox)
                Toggle("Check which names resolve", isOn: $f.resolveNames).toggleStyle(.checkbox)
            default: EmptyView()
            }
            Spacer()
        }
        .font(.system(size: 12)).foregroundStyle(Pal.subtext)
    }

    private var visibleLines: [ToolLine] {
        f.lineFilter.isEmpty ? session.lines : session.lines.filter { $0.text.localizedCaseInsensitiveContains(f.lineFilter) || $0.kind == .header }
    }

    private var console: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(lucideSymbol: "line.3.horizontal.decrease").font(.system(size: 10)).foregroundStyle(Pal.overlay)
                ThemedTextField(placeholder: "Filter", text: $f.lineFilter)
                if session.running { ProgressView().controlSize(.small) }
                Text("\(session.lines.count)").font(.system(size: 11, design: .monospaced)).foregroundStyle(Pal.overlay)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(visibleLines.map(\.text).joined(separator: "\n"), forType: .string)
                } label: { Image(lucideSymbol: "doc.on.doc").font(.system(size: 11)) }
                    .buttonStyle(.plain).foregroundStyle(Pal.overlay).pointerCursor().help(String(localized: "Copy All"))
                    .disabled(session.lines.isEmpty)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            Divider().overlay(Pal.fill(0.06))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(visibleLines) { l in
                            Text(verbatim: l.text.isEmpty ? " " : l.text)
                                .font(.system(size: 11.5, weight: l.kind == .header ? .semibold : .regular, design: .monospaced))
                                .foregroundStyle(color(l.kind)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).id(l.id)
                        }
                    }
                    .padding(10)
                }
                .onChange(of: session.lines.count) { _, _ in if let last = visibleLines.last { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
            .overlay { if session.lines.isEmpty && !session.running { Text("Results appear here.").font(.system(size: 12)).foregroundStyle(Pal.overlay) } }
        }
        .background(Pal.fill(0.04), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Pal.fill(0.10), lineWidth: 1))
    }

    private func color(_ k: ToolLine.Kind) -> Color {
        switch k { case .normal: return Pal.text; case .ok: return Pal.green; case .warn: return Pal.yellow; case .error: return Pal.red; case .dim: return Pal.overlay; case .header: return tint }
    }

    // MARK: Port reference

    private var portReference: some View {
        let rows = PortsScanner.wellKnown.sorted { $0.key < $1.key }.filter {
            f.portFilter.isEmpty || String($0.key).contains(f.portFilter) || $0.value.localizedCaseInsensitiveContains(f.portFilter)
        }
        return VStack(spacing: 10) {
            ThemedTextField(placeholder: "Search port or service", text: $f.portFilter)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows, id: \.key) { r in
                        HStack {
                            Text(verbatim: String(r.key)).font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(tint).frame(width: 70, alignment: .leading)
                            Text(verbatim: r.value).font(.system(size: 12.5)).foregroundStyle(Pal.text)
                            Spacer()
                            Button("Test") { model.openNetTools(NetToolsRequest(tool: .tcp, ports: String(r.key))) }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Pal.overlay).pointerCursor()
                        }
                        .padding(.vertical, 6).padding(.horizontal, 8)
                        Divider().overlay(Pal.fill(0.05))
                    }
                }
            }
        }
        .padding(18)
    }

    // MARK: Run

    private var canRun: Bool { !f.tool.needsTarget || !f.target.trimmingCharacters(in: .whitespaces).isEmpty }

    private func run() {
        guard canRun, !session.running else { return }
        let tgt = f.target.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "").split(separator: "/").first.map(String.init) ?? ""
        let spec = PortSpec.parse(f.portsText)
        if (f.tool == .tcp || f.tool == .udp || f.tool == .ssl), spec.ports.isEmpty { session.emit(ToolLine(text: spec.error ?? String(localized: "Enter at least one port."), kind: .error)); return }
        let emit: ToolEmit = { [session] l in session.emit(l) }
        let ports = spec.ports, count = f.pingCount, dns = f.dnsType, resolver = LocalNet.resolvers[f.resolverIdx].address, timeout = f.timeoutSec
        let hops = f.maxHops, showClosed = f.showClosed, expired = f.includeExpired, resolveNames = f.resolveNames, tool = f.tool
        let rawTarget = f.target.trimmingCharacters(in: .whitespaces)

        if tool == .subnet { SubnetCalculator.analyze(rawTarget).forEach(emit); return }

        if tool == .http {
            guard let url = HTTPChecker.normalizedURL(rawTarget) else { emit(ToolLine(text: String(localized: "Enter a valid http:// or https:// address."), kind: .error)); return }
            let opts = HTTPCheckOptions(url: url.absoluteString, head: f.httpHead, follow: f.httpFollow, insecure: f.httpInsecure)
            let server = remote ? serverHost : nil
            session.start {
                emit(ToolLine(text: "\(opts.head ? "HEAD" : "GET") \(url.absoluteString)" + (server.map { "  @ \($0.name)" } ?? "  @ " + String(localized: "This Mac")), kind: .header))
                let r: HTTPCheckResult
                if let h = server, let ssh = h.ssh { r = await HTTPChecker.runOnServer(url, opts, fs: RemoteFS(ssh)) }
                else { r = await HTTPChecker.runLocally(url, opts) }
                RemoteNet.httpLines(r).forEach(emit)
            }
            return
        }

        if remote, let h = serverHost, let ssh = h.ssh {
            let fs = RemoteFS(ssh)
            session.start {
                if tool == .subdomains {
                    emit(ToolLine(text: String(localized: "Querying CT logs from \(h.name)…"), kind: .dim))
                    let res = await LocalNet.ctNames(domain: tgt, includeExpired: expired) { url in
                        let r = await fs.run("curl -s -m 60 -A ServerDock " + RemoteNet.q(url.absoluteString), timeout: 75)
                        return r.data.isEmpty ? nil : r.data
                    }
                    guard let res else { emit(ToolLine(text: String(localized: "Couldn't fetch CT data (needs curl on the server, and crt.sh / Cert Spotter reachable)."), kind: .error)); return }
                    await LocalNet.emitSubdomains(domain: tgt, result: res, resolveNames: false, emit: emit)
                    return
                }
                emit(ToolLine(text: "$ \(h.name)", kind: .dim))
                let script = RemoteNet.script(tool, target: tgt, ports: ports, count: count, dnsType: dns.rawValue, resolver: resolver, timeout: timeout)
                let r = await fs.run(script, timeout: Double(max(30, ports.count * (timeout + 1) + 20)))
                let out = String(decoding: r.data, as: UTF8.self) + String(decoding: r.stderr, as: UTF8.self)
                RemoteNet.lines(tool, output: out, ports: ports).forEach(emit)
            }
            return
        }

        session.start {
            switch tool {
            case .info: await LocalNet.networkInfo(emit: emit)
            case .ping: LocalNet.ping(host: tgt, count: count, emit: emit)
            case .dns: await LocalNet.dnsLookup(name: tgt, type: dns, resolver: resolver, emit: emit)
            case .tcp: await LocalNet.tcpScan(host: tgt, ports: ports, timeoutMs: Int32(timeout * 1000), showClosed: f.showClosed, emit: emit)
            case .udp: await LocalNet.udpScan(host: tgt, ports: ports, timeoutMs: Int32(timeout * 1000), emit: emit)
            case .trace: await LocalNet.traceroute(host: tgt, maxHops: hops, emit: emit)
            case .whois: LocalNet.whois(query: tgt, emit: emit)
            case .ssl: await LocalNet.sslCertificate(host: tgt, port: ports.first ?? 443, emit: emit)
            case .subdomains:
                emit(ToolLine(text: String(localized: "Querying Certificate Transparency logs… this can take a while for large domains."), kind: .dim))
                guard let res = await LocalNet.ctNames(domain: tgt, includeExpired: expired, fetch: LocalNet.localFetch) else {
                    emit(ToolLine(text: String(localized: "Couldn't fetch CT data. crt.sh is often busy — try again, or run it from a server."), kind: .error)); return
                }
                await LocalNet.emitSubdomains(domain: tgt, result: res, resolveNames: f.resolveNames, emit: emit)
            case .subnet, .ports, .http: break
            }
        }
    }
}

/// Tools sidebar groups collapsible management/network sections; clicks open corresponding tabs.
struct ToolsPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var tabs: TabsModel
    @State private var collapsed: Set<String> = []
    @State private var hover: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 5) {
                header("manage", String(localized: "Manage"))
                if !collapsed.contains("manage") {
                    row(id: "keys", symbol: "key.viewfinder", title: String(localized: "SSH Key Manager"), detail: "~/.ssh", active: model.isKeyManagerActive) { model.openKeyManager() }
                }
                header("network", String(localized: "Network"))
                if !collapsed.contains("network") { toolRows(NetTool.allCases.filter { !NetTool.certificateTools.contains($0) }) }
                header("certs", String(localized: "Certificates"))
                if !collapsed.contains("certs") { toolRows(NetTool.certificateTools) }
            }
            .padding(.horizontal, 12).padding(.top, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func toolRows(_ list: [NetTool]) -> some View {
        ForEach(list) { t in
            row(id: t.rawValue, symbol: t.symbol, title: t.title, detail: t.brief, active: model.isNetToolActive(t)) { model.openNetTools(NetToolsRequest(tool: t)) }
        }
    }

    private func header(_ key: String, _ title: String) -> some View {
        let isCollapsed = collapsed.contains(key)
        return Button {
            if isCollapsed { collapsed.remove(key) } else { collapsed.insert(key) }
        } label: {
            HStack(spacing: 7) {
                Image(lucideSymbol: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(Pal.overlay)
                    .frame(width: 11).rotationEffect(.degrees(isCollapsed ? -90 : 0))
                Image(lucideSymbol: "folder").font(.system(size: 12)).foregroundStyle(Pal.subtext)
                Text(verbatim: title).font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.subtext)
                Spacer(minLength: 0)
            }
            .padding(.leading, 2).padding(.trailing, 9).padding(.top, 12).padding(.bottom, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor()
        .animation(.easeOut(duration: 0.15), value: isCollapsed)
    }

    private func row(id: String, symbol: String, title: String, detail: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(lucideSymbol: symbol).font(.system(size: 13)).frame(width: 22)
                    .foregroundStyle(active ? Pal.tint : Pal.subtext)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title).font(.system(size: 13, weight: active ? .medium : .regular))
                        .foregroundStyle(active ? Pal.textBright : Pal.text).lineLimit(1)
                    Text(verbatim: detail).font(.system(size: 11)).foregroundStyle(Pal.subtext).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, 11).padding(.trailing, 7).padding(.vertical, 9)
            .background(active ? Pal.fill(0.105) : (hover == id ? Pal.fill(0.055) : Color.clear), in: RoundedRectangle(cornerRadius: 11))
            .animation(.easeOut(duration: 0.18), value: active)
            .animation(.easeOut(duration: 0.12), value: hover)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor()
        .onHover { hover = $0 ? id : (hover == id ? nil : hover) }
    }
}

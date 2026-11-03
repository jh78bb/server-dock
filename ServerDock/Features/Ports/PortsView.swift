import SwiftUI
import AppKit

/// Read-only listener scan uses Linux ss/netstat or macOS lsof.
enum PortsScanner {
    static func script(sudo: Bool) -> String {
        let s = sudo ? "sudo -n " : ""
        return """
        export LC_ALL=C
        os=$(uname -s 2>/dev/null); echo "__OS__=$os"
        case "$os" in
          Linux) ( \(s)ss -H -tulnp 2>/dev/null || ss -H -tulnp 2>/dev/null || ss -H -tuln 2>/dev/null || netstat -tuln 2>/dev/null | tail -n +3 ) ;;
          Darwin) \(s)lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null; \(s)lsof -nP -iUDP 2>/dev/null ;;
          *) netstat -an 2>/dev/null | grep -i listen ;;
        esac
        """
    }

    static func parse(_ out: String) -> (os: String, ports: [ListenPort]) {
        var os = ""
        var ports: [ListenPort] = []
        for raw in out.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("__OS__=") { os = String(line.dropFirst(7)); continue }
            if let p = SecurityScanner.parsePort(line) { ports.append(p); continue }
            if let p = parseLsof(line) { ports.append(p) }
        }
        var seen = Set<String>()
        ports = ports.filter { seen.insert("\($0.proto)-\($0.port)-\($0.isPublic)").inserted }.sorted { $0.port < $1.port }
        return (os, ports)
    }

    /// lsof -nP -i row: COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME [(LISTEN)].
    static func parseLsof(_ line: String) -> ListenPort? {
        let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard f.count >= 9, f[0] != "COMMAND", let pid = Int(f[1]) else { return nil }
        let node = f[7].uppercased()
        guard node == "TCP" || node == "UDP" else { return nil }
        var name = f[8]
        if name.contains("->") { return nil }               // Exclude established sockets; retain listeners only.
        if let paren = name.firstIndex(of: "(") { name = String(name[..<paren]) }
        guard let colon = name.lastIndex(of: ":"), let port = Int(name[name.index(after: colon)...]) else { return nil }
        var addr = String(name[..<colon])
        if addr == "*" || addr.isEmpty { addr = "0.0.0.0" }
        let cmd = f[0].replacingOccurrences(of: "\\x20", with: " ").trimmingCharacters(in: .whitespaces)
        return ListenPort(proto: node.lowercased(), address: addr, port: port, process: cmd, pid: pid, user: f[2])
    }

    /// Common service-port names as reference hints.
    static let wellKnown: [Int: String] = [
        21: "FTP", 22: "SSH", 23: "Telnet", 25: "SMTP", 53: "DNS", 67: "DHCP", 68: "DHCP", 80: "HTTP", 110: "POP3", 123: "NTP", 137: "NetBIOS", 139: "SMB", 143: "IMAP",
        161: "SNMP", 389: "LDAP", 443: "HTTPS", 445: "SMB", 465: "SMTPS", 514: "Syslog", 587: "SMTP", 631: "CUPS", 636: "LDAPS", 873: "rsync", 993: "IMAPS", 995: "POP3S",
        1194: "OpenVPN", 1433: "MSSQL", 1521: "Oracle", 1883: "MQTT", 2049: "NFS", 2375: "Docker", 2376: "Docker TLS", 3000: "Dev/Grafana", 3306: "MySQL", 3389: "RDP",
        5000: "Dev server", 5353: "mDNS", 5432: "PostgreSQL", 5601: "Kibana", 5672: "RabbitMQ", 5900: "VNC", 6379: "Redis", 6443: "Kubernetes API", 8006: "Proxmox",
        8080: "HTTP alt", 8443: "HTTPS alt", 8883: "MQTT TLS", 9000: "Portainer/PHP-FPM", 9090: "Prometheus/Cockpit", 9200: "Elasticsearch", 9443: "Portainer",
        11211: "Memcached", 27017: "MongoDB", 51820: "WireGuard",
    ]
    /// Heuristic for ports worth opening as web services.
    static func looksLikeWeb(_ p: ListenPort) -> Bool {
        p.proto == "tcp" && [80, 443, 3000, 5000, 5601, 8000, 8006, 8080, 8081, 8088, 8443, 8888, 9000, 9090, 9200, 9443].contains(p.port)
    }
    static func looksLikeHTTPS(_ p: ListenPort) -> Bool { [443, 8006, 8443, 9443].contains(p.port) }
}

@MainActor
final class PortsSession: ObservableObject {
    enum Phase: Equatable { case loading, ready, failed(String) }
    let host: Host
    private let fs: RemoteFS
    @Published private(set) var phase: Phase = .loading
    @Published private(set) var ports: [ListenPort] = []
    @Published private(set) var os = ""
    @Published private(set) var scannedAt = Date()
    @Published var useSudo: Bool { didSet { UserDefaults.standard.set(useSudo, forKey: "portsSudo." + host.id) } }

    init(host: Host) {
        self.host = host
        fs = RemoteFS(host.ssh ?? SSHConnection())
        useSudo = UserDefaults.standard.bool(forKey: "portsSudo." + host.id)
    }

    func refresh() {
        phase = ports.isEmpty ? .loading : phase
        Task {
            let r = await fs.run(PortsScanner.script(sudo: useSudo), timeout: 25)
            if r.code == -1 { phase = .failed(String(decoding: r.stderr, as: UTF8.self)); return }
            let parsed = PortsScanner.parse(String(decoding: r.data, as: UTF8.self))
            os = parsed.os; ports = parsed.ports; scannedAt = Date(); phase = .ready
        }
    }
}

/// Listener sheet shows TCP/UDP exposure, service names, and owning processes.
struct PortsView: View {
    @ObservedObject var model: AppModel
    @StateObject private var session: PortsSession
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var theme = ThemeManager.shared

    private enum Filter { case all, publicOnly, localOnly }
    @State private var filter: Filter = .all
    @State private var query = ""
    @State private var selection = Set<String>()
    @State private var sortOrder = [KeyPathComparator(\ListenPort.port)]

    init(model: AppModel, host: Host) {
        self.model = model
        _session = StateObject(wrappedValue: PortsSession(host: host))
    }

    private var host: Host { session.host }

    private var visible: [ListenPort] {
        let q = query.lowercased()
        return session.ports.filter { p in
            switch filter {
            case .all: break
            case .publicOnly: if !p.isPublic { return false }
            case .localOnly: if p.isPublic { return false }
            }
            return q.isEmpty || String(p.port).contains(q) || p.process.lowercased().contains(q)
                || (PortsScanner.wellKnown[p.port] ?? "").lowercased().contains(q) || p.address.contains(q)
        }.sorted(using: sortOrder)
    }

    private var selected: ListenPort? { session.ports.first { selection.contains($0.id) } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(lucideSymbol: "network").foregroundStyle(host.accent)
                Text("Open Ports").font(.system(size: 15, weight: .semibold)).foregroundStyle(Pal.text)
                Text(host.name).font(.system(size: 11)).foregroundStyle(Pal.overlay)
                Spacer()
                if session.phase == .ready {
                    Text("\(session.ports.filter(\.isPublic).count) public · \(session.ports.count) total")
                        .font(.system(size: 11)).foregroundStyle(Pal.overlay)
                }
                Toggle("sudo", isOn: $session.useSudo).toggleStyle(.checkbox).font(.system(size: 11))
                    .help(String(localized: "Run the scan with passwordless sudo to see process names for every user"))
                    .onChange(of: session.useSudo) { _ in session.refresh() }
                iconButton("arrow.clockwise", String(localized: "Scan again")) { session.refresh() }
                Button { dismiss() } label: { Image(lucideSymbol: "xmark").font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.overlay) }
                    .buttonStyle(.plain).pointerCursor()
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            Divider().overlay(Pal.fill(0.06))

            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(lucideSymbol: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Pal.overlay)
                    TextField(String(localized: "Search port, process or service…"), text: $query).textFieldStyle(.plain).font(.system(size: 12)).frame(width: 200)
                }
                .padding(.horizontal, 8).padding(.vertical, 5).background(Pal.fill(0.06), in: RoundedRectangle(cornerRadius: 7))
                SegmentedControl(options: [(value: Filter.all, label: LocalizedStringKey("All")),
                                           (value: Filter.publicOnly, label: LocalizedStringKey("Public")),
                                           (value: Filter.localOnly, label: LocalizedStringKey("This server only"))], selection: $filter)
                    .frame(width: 300)
                Spacer()
                actions
            }
            .padding(.horizontal, 16).padding(.vertical, 10)

            processHint
            content
            Divider().overlay(Pal.fill(0.06))
            Text("Public: reachable from other machines (any address except loopback). This server only: bound to 127.0.0.1 / ::1. Process names of other users need sudo. A firewall may still block a public port.")
                .font(.system(size: 10.5)).foregroundStyle(Pal.overlay).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16).padding(.vertical, 8)
        }
        .frame(width: 820, height: 560)
        .background(Pal.solidBase)
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .onAppear { session.refresh() }
    }

    @ViewBuilder
    private var content: some View {
        switch session.phase {
        case .loading:
            VStack(spacing: 10) { ProgressView(); Text("Scanning…").font(.system(size: 12)).foregroundStyle(Pal.subtext) }.frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let m):
            VStack(spacing: 10) {
                Image(lucideSymbol: "exclamationmark.triangle").font(.system(size: 28)).foregroundStyle(Pal.red)
                Text(m).font(.system(size: 12)).foregroundStyle(Pal.subtext).multilineTextAlignment(.center).frame(maxWidth: 420)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            ZStack {
                Table(visible, selection: $selection, sortOrder: $sortOrder) {
                    TableColumn("Port", value: \.port) { p in
                        Text(verbatim: "\(p.proto)/\(p.port)").font(.system(size: 12, design: .monospaced))
                    }.width(min: 80, ideal: 100)
                    TableColumn("Exposure", value: \.exposureRank) { p in
                        Text(p.isPublic ? String(localized: "Public") : String(localized: "This server only"))
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(p.isPublic ? Pal.yellow : Pal.green)
                            .padding(.horizontal, 7).padding(.vertical, 2).background((p.isPublic ? Pal.yellow : Pal.green).opacity(0.12), in: Capsule())
                    }.width(min: 100, ideal: 120)
                    TableColumn("Address", value: \.address) { p in Text(verbatim: p.address).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Pal.subtext) }
                        .width(min: 90, ideal: 120)
                    TableColumn("Service", value: \.serviceName) { p in Text(verbatim: PortsScanner.wellKnown[p.port] ?? "—").foregroundStyle(Pal.subtext) }
                        .width(min: 80, ideal: 130)
                    TableColumn("Process", value: \.process) { p in
                        Text(verbatim: p.process.isEmpty ? "—" : (p.pid.map { "\(p.process) (\($0))" } ?? p.process)).foregroundStyle(Pal.subtext).lineLimit(1)
                    }
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    if let p = session.ports.first(where: { ids.contains($0.id) }) { rowMenu(p) }
                }
                if visible.isEmpty {
                    Text("No matching ports").font(.system(size: 12)).foregroundStyle(Pal.overlay).allowsHitTesting(false)
                }
            }
        }
    }

    /// Explain missing process names due to permissions and offer sudo.
    @ViewBuilder
    private var processHint: some View {
        let missing = session.ports.filter { $0.process.isEmpty }.count
        if session.phase == .ready, missing > 0, session.os == "Linux" || session.os == "Darwin" {
            HStack(alignment: .top, spacing: 8) {
                Image(lucideSymbol: "info.circle").foregroundStyle(Pal.overlay)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(missing) ports have no process name.").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Pal.text)
                    Text(session.useSudo
                         ? String(localized: "sudo is on, but the server may need a password for sudo (only passwordless sudo -n works), or these sockets belong to the kernel or a container.")
                         : String(localized: "The system only reveals the process of a port to its owner or to root, so services run by other users (nginx, mysql, docker…) show nothing without root."))
                        .font(.system(size: 11)).foregroundStyle(Pal.subtext).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if !session.useSudo {
                    Button { session.useSudo = true; session.refresh() } label: {
                        Text("Scan with sudo").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Pal.tint)
                            .padding(.horizontal, 10).padding(.vertical, 5).background(Pal.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain).pointerCursor()
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8).background(Pal.fill(0.04))
        }
    }

    // MARK: Actions

    private var actions: some View {
        let p = selected
        return HStack(spacing: 2) {
            iconButton("globe", String(localized: "Open in a web tab"), disabled: p == nil || p?.proto != "tcp") { if let p { openWeb(p) } }
            iconButton("arrow.left.arrow.right", String(localized: "Create a port forward"), disabled: p == nil || p?.proto != "tcp" || host.isLocal) { if let p { forward(p) } }
            iconButton("waveform.badge.magnifyingglass", String(localized: "Add an HTTP check"), disabled: p == nil || p?.proto != "tcp") { if let p { addCheck(p) } }
            iconButton("flame", String(localized: "Firewall rule for this port"), disabled: p == nil || host.isLocal || session.os != "Linux") { if let p { firewall(p) } }
            iconButton("doc.on.doc", String(localized: "Copy address"), disabled: p == nil) { if let p { copy(p) } }
        }
    }

    @ViewBuilder
    private func rowMenu(_ p: ListenPort) -> some View {
        if p.proto == "tcp" {
            Button("Open in a web tab") { openWeb(p) }
            if !host.isLocal { Button("Create a port forward") { forward(p) } }
            Button("Add an HTTP check") { addCheck(p) }
            Divider()
        }
        if !host.isLocal, session.os == "Linux" { Button("Firewall rule for this port") { firewall(p) } }
        Button("Copy address") { copy(p) }
    }

    private func firewall(_ p: ListenPort) {
        dismiss()
        DispatchQueue.main.async { model.firewallRequest = FirewallRequest(host: host, port: p.port, proto: p.proto) }
    }

    private func openWeb(_ p: ListenPort) {
        dismiss()
        if host.isLocal {
            if let u = URL(string: "\(PortsScanner.looksLikeHTTPS(p) ? "https" : "http")://localhost:\(p.port)/") { NSWorkspace.shared.open(u) }
        } else {
            model.openWebService(host: host, destHost: "localhost", destPort: p.port, https: PortsScanner.looksLikeHTTPS(p))
        }
    }

    private func forward(_ p: ListenPort) {
        dismiss()
        model.openWebService(host: host, destHost: "localhost", destPort: p.port, https: false, openTab: false)
    }

    private func addCheck(_ p: ListenPort) {
        dismiss()
        let scheme = PortsScanner.looksLikeHTTPS(p) ? "https" : "http"
        model.addHTTPCheck(HTTPCheckItem(url: "\(scheme)://localhost:\(p.port)/", fromServer: !host.isLocal, head: false, insecure: PortsScanner.looksLikeHTTPS(p)), host: host)
    }

    private func copy(_ p: ListenPort) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("\(p.address):\(p.port)", forType: .string)
    }

    private func iconButton(_ symbol: String, _ help: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(lucideSymbol: symbol).font(.system(size: 12)).foregroundStyle(disabled ? Pal.overlay.opacity(0.5) : Pal.subtext)
                .frame(width: 28, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor().disabled(disabled).help(help)
    }
}

private extension ListenPort {
    var exposureRank: Int { isPublic ? 0 : 1 }
    var serviceName: String { PortsScanner.wellKnown[port] ?? "" }
}

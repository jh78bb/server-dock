import SwiftUI

/// One URL saved in the overview HTTP card.
struct HTTPCheckItem: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var url: String
    var fromServer = true      // Server curl / this Mac.
    var head = false
    var insecure = false

    /// Short display name omits the scheme.
    var display: String {
        url.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
    }
}

extension AppModel {
    func httpChecks(for hostId: String) -> [HTTPCheckItem] { httpChecks[hostId] ?? [] }

    func addHTTPCheck(_ item: HTTPCheckItem, host: Host) {
        guard !(httpChecks[host.id] ?? []).contains(where: { $0.url == item.url && $0.fromServer == item.fromServer }) else { return }
        httpChecks[host.id, default: []].append(item)
        saveHTTPChecks()
        runHTTPCheck(item, host: host)
    }

    func removeHTTPCheck(_ item: HTTPCheckItem, hostId: String) {
        httpChecks[hostId]?.removeAll { $0.id == item.id }
        if httpChecks[hostId]?.isEmpty == true { httpChecks[hostId] = nil }
        httpResults[item.id] = nil
        saveHTTPChecks()
    }

    func saveHTTPChecks() {
        guard !AppEnv.isScreenshotDemo, let data = try? JSONEncoder().encode(httpChecks) else { return }
        UserDefaults.standard.set(data, forKey: "hostHTTPChecks")
    }

    static func loadHTTPChecks() -> [String: [HTTPCheckItem]] {
        guard let data = UserDefaults.standard.data(forKey: "hostHTTPChecks"),
              let m = try? JSONDecoder().decode([String: [HTTPCheckItem]].self, from: data) else { return [:] }
        return m
    }

    /// Check one item unless already running.
    func runHTTPCheck(_ item: HTTPCheckItem, host: Host) {
        guard httpRunning.insert(item.id).inserted, let url = HTTPChecker.normalizedURL(item.url) else { return }
        let remote = !host.isLocal && item.fromServer
        let ssh = host.ssh ?? SSHConnection()
        if remote && !ssh.hasUsableCredentials { httpRunning.remove(item.id); return }   // Skip ask-mode checks until a password is entered.
        let opts = HTTPCheckOptions(url: url.absoluteString, head: item.head, follow: false, insecure: item.insecure)
        Task { @MainActor in
            let r = remote ? await HTTPChecker.runOnServer(url, opts, fs: RemoteFS(ssh)) : await HTTPChecker.runLocally(url, opts)
            httpResults[item.id] = r
            httpRunning.remove(item.id)
        }
    }

    func runAllHTTPChecks(host: Host) {
        for item in httpChecks(for: host.id) { runHTTPCheck(item, host: host) }
    }
}

/// HTTP card row shows status/address/code/time; click to recheck.
struct HTTPCheckRow: View {
    let item: HTTPCheckItem
    let result: HTTPCheckResult?
    let running: Bool
    let fromServerLabel: Bool
    let onRun: () -> Void
    let onDetails: () -> Void
    let onRemove: () -> Void
    @State private var hover = false

    private var color: Color {
        guard let r = result else { return Pal.overlay }
        if r.error != nil { return Pal.red }
        let c = r.statusCode ?? 0
        return c >= 400 ? Pal.red : (c >= 300 ? Pal.yellow : Pal.green)
    }

    private var summary: String {
        guard let r = result else { return "—" }
        if r.error != nil { return String(localized: "Failed") }
        let ms = r.totalMs.map { $0 < 1000 ? String(format: "%.0f ms", $0) : String(format: "%.1f s", $0 / 1000) } ?? ""
        return "\(r.statusCode ?? 0) · \(ms)"
    }

    var body: some View {
        HStack(spacing: 9) {
            Button(action: onRun) {
                HStack(spacing: 9) {
                    if running { ProgressView().controlSize(.mini).frame(width: 10, height: 10) }
                    else { Circle().fill(color).frame(width: 8, height: 8).frame(width: 10) }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: item.display).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Pal.text)
                            .lineLimit(1).truncationMode(.middle)
                        if fromServerLabel {
                            Text(item.fromServer ? String(localized: "From server") : String(localized: "From this Mac"))
                                .font(.system(size: 10)).foregroundStyle(Pal.overlay)
                        }
                    }
                    Spacer(minLength: 4)
                    Text(verbatim: summary).font(.system(size: 11, design: .monospaced)).foregroundStyle(color == Pal.overlay ? Pal.overlay : color)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointerCursor()
            .help(result?.error ?? String(localized: "Check now"))
            if hover {
                Button(action: onRemove) {
                    Image(lucideSymbol: "xmark").font(.system(size: 9)).foregroundStyle(Pal.overlay)
                        .frame(width: 18, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointerCursor().help(String(localized: "Remove"))
            }
        }
        .onHover { hover = $0 }
        .contextMenu {
            Button("Check Now", action: onRun)
            Button("Details…", action: onDetails)
            Divider()
            Button("Remove", role: .destructive, action: onRemove)
        }
    }
}

/// HTTP-card + popover saves an entered URL.
struct HTTPCheckAddPopover: View {
    let isLocalHost: Bool
    let onAdd: (HTTPCheckItem) -> Void
    @State private var url = ""
    @State private var fromServer = true
    @State private var head = false
    @State private var insecure = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add HTTP Check").font(.system(size: 13, weight: .semibold)).foregroundStyle(Pal.text)
            ThemedTextField(verbatim: "http://localhost:8080/health", text: $url, autofocus: true, onSubmit: add)
            if !isLocalHost {
                SegmentedControl(options: [(value: true, label: LocalizedStringKey("From Server")),
                                           (value: false, label: LocalizedStringKey("From This Mac"))], selection: $fromServer)
            }
            HStack(spacing: 14) {
                SegmentedControl(options: [(value: false, verbatim: "GET"), (value: true, verbatim: "HEAD")], selection: $head)
                    .frame(width: 110)
                Toggle("Ignore certificate errors", isOn: $insecure).toggleStyle(.checkbox).font(.system(size: 11))
            }
            HStack {
                Spacer()
                PrimaryButton(title: "Add", enabled: HTTPChecker.normalizedURL(url) != nil, tint: Pal.tint, action: add)
            }
        }
        .padding(16).frame(width: 320)
    }

    private func add() {
        guard let u = HTTPChecker.normalizedURL(url) else { return }
        onAdd(HTTPCheckItem(url: u.absoluteString, fromServer: isLocalHost ? false : fromServer, head: head, insecure: insecure))
    }
}

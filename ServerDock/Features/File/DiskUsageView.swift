import AppKit
import SwiftUI

extension Notification.Name {
    /// Request expansion of the folded folder-content list when opening disk analysis.
    static let revealFolderFileList = Notification.Name("ServerDock.revealFolderFileList")
}

/// Reuse one per-host du session, navigating it instead of adding tabs for other folders.
/// Run the same RemoteFS.run script remotely for SSH or locally for this Mac.
@MainActor
final class DiskUsageSession: ObservableObject {
    struct Entry: Identifiable {
        var id: String { path }
        let name: String
        let path: String
        let bytes: Int64
        let isDir: Bool
    }

    enum Phase: Equatable { case loading, loaded, failed(String) }

    let host: Host
    private let fs: RemoteFS
    @Published private(set) var path: String
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var total: Int64 = 0
    @Published private(set) var phase: Phase = .loading
    @Published var oneFileSystem = true {
        didSet { if oldValue != oneFileSystem { clearCache(); refresh() } }
    }

    private var handle: CommandHandle?
    private var task: Task<Void, Never>?
    private var back: [String] = []

    // Cache analyzed directories for immediate back/up/revisit navigation.
    // Also collect three descendant levels because du traverses them anyway,
    // showing known subfolder sizes immediately while file entries load afterward.
    private struct Snapshot { let entries: [Entry]; let total: Int64; let date: Date }
    private var snapshots: [String: Snapshot] = [:]
    private var dirIndex: [String: Int64] = [:]           // Known folder path to size.
    private static let cacheLifetime: TimeInterval = 300   // Reanalyze after five minutes.
    private static let depth = 3
    @Published private(set) var cachedAt: Date?            // Analysis time when showing cached results.

    init(host: Host, path: String) {
        self.host = host
        self.fs = RemoteFS(host.ssh ?? SSHConnection())
        self.path = path
    }

    var canGoUp: Bool { path != "/" }
    var canGoBack: Bool { !back.isEmpty }

    /// Navigate with recent cached results, otherwise analyze; display known descendant sizes immediately.
    func navigate(to p: String, recordHistory: Bool = true) {
        if recordHistory, p != path { back.append(path) }
        cancel()
        path = p
        if let snap = snapshots[p], Date().timeIntervalSince(snap.date) < Self.cacheLifetime {
            entries = snap.entries; total = snap.total; cachedAt = snap.date; phase = .loaded
            return
        }
        showKnownChildren(of: p)
        scan()
    }

    /// Show known child sizes provisionally; files arrive after analysis.
    private func showKnownChildren(of p: String) {
        let prefix = p == "/" ? "/" : p + "/"
        let kids = dirIndex.filter { k, _ in
            k.hasPrefix(prefix) && k != p && !k.dropFirst(prefix.count).contains("/")
        }
        guard !kids.isEmpty else { entries = []; total = 0; return }
        entries = kids.map { Entry(name: ($0.key as NSString).lastPathComponent, path: $0.key, bytes: $0.value, isDir: true) }.sorted { $0.bytes > $1.bytes }
        total = dirIndex[p] ?? entries.reduce(0) { $0 + $1.bytes }
    }

    func goUp() { navigate(to: FileTreeState.parentPath(path)) }

    func goBack() {
        guard let p = back.popLast() else { return }
        navigate(to: p, recordHistory: false)
    }

    func cancel() {
        handle?.cancel()
        task?.cancel()
    }

    /// Refresh discards this folder's cache and reanalyzes.
    func refresh() {
        snapshots[path] = nil
        cancel()
        scan()
    }

    private func clearCache() { snapshots = [:]; dirIndex = [:] }

    private func scan() {
        phase = .loading
        cachedAt = nil
        let target = path
        let h = CommandHandle()
        handle = h
        let x = oneFileSystem ? "-x" : ""
        let q = AppModel.shellQuote(target)
        let n = Self.depth
        // GNU/BSD/new BusyBox du use -d; older GNU uses --max-depth. BSD cannot combine -a/-d,
        // so merge folder du with direct-file find/du. Collect three levels, omitting deeper-than-first folders below 256KB.
        let script = "p=\(q); if du -d 0 /dev/null >/dev/null 2>&1; then D='-d \(n)'; else D='--max-depth=\(n)'; fi; "
            + "d=$(printf %s \"$p\" | awk -F/ '{print NF}'); "
            + "{ du -k \(x) $D \"$p\" | awk -F'\\t' -v d=\"$d\" -v p=\"$p\" '{ c=split($2,a,\"/\"); if ($1>=256 || c<=d+1 || $2==p) print }'; "
            + "find \"$p\" -mindepth 1 -maxdepth 1 -type f -exec du -k {} +; } 2>/dev/null "
            + "| sort -rn | head -4000; echo '@@DIRS@@'; "
            + "ls -1Ap \"$p\" 2>/dev/null | grep '/$'"
        task = Task { [weak self] in
            guard let self else { return }
            let r = await self.fs.run(script, timeout: 300, handle: h)
            if Task.isCancelled || h.isCancelled || self.path != target { return }
            if r.code < 0 {
                self.phase = .failed(String(decoding: r.stderr, as: UTF8.self))
                return
            }
            self.parse(String(decoding: r.data, as: UTF8.self), base: target)
        }
    }

    private func parse(_ out: String, base: String) {
        let parts = out.components(separatedBy: "@@DIRS@@")
        let dirNames = Set((parts.count > 1 ? parts[1] : "")
            .split(separator: "\n").map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "/")) })
        var list: [Entry] = []
        var totalBytes: Int64 = 0
        let baseNorm = base.count > 1 && base.hasSuffix("/") ? String(base.dropLast()) : base
        let parentPrefix = baseNorm == "/" ? "/" : baseNorm + "/"
        for line in parts[0].split(separator: "\n") {
            let cols = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: true)
            guard cols.count == 2, let kb = Int64(cols[0].trimmingCharacters(in: .whitespaces)) else { continue }
            let p = String(cols[1])
            let pNorm = p.count > 1 && p.hasSuffix("/") ? String(p.dropLast()) : p
            if pNorm == baseNorm { totalBytes = kb * 1024; continue }
            let rel = pNorm.hasPrefix(parentPrefix) ? String(pNorm.dropFirst(parentPrefix.count)) : ""
            if rel.contains("/") {                      // Remember deeper descendant sizes for instant later navigation.
                dirIndex[pNorm] = kb * 1024
                continue
            }
            let name = (pNorm as NSString).lastPathComponent
            let isDir = dirNames.contains(name)
            if isDir { dirIndex[pNorm] = kb * 1024 }
            list.append(Entry(name: name, path: pNorm, bytes: kb * 1024, isDir: isDir))
        }
        entries = list.sorted { $0.bytes > $1.bytes }
        total = totalBytes > 0 ? totalBytes : list.reduce(0) { $0 + $1.bytes }
        if total > 0 { dirIndex[baseNorm] = total }
        snapshots[baseNorm] = Snapshot(entries: entries, total: total, date: Date())
        phase = .loaded
    }
}

/// Editor-area disk analysis sorts children by size with bars; clicking folders navigates/reanalyzes.
struct DiskUsageView: View {
    @ObservedObject var session: DiskUsageSession
    let model: AppModel
    @ObservedObject private var theme = ThemeManager.shared
    @State private var hasFullDiskAccess = FullDiskAccess.isGranted
    @State private var dismissedFDA = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Pal.fill(0.08)).frame(height: 1)
            if session.host.isLocal, !hasFullDiskAccess, !dismissedFDA { fullDiskAccessBanner }
            content
        }
        .background(Pal.base)
    }

    private var accent: Color { session.host.accent }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                navButton("chevron.left", help: String(localized: "Back"), enabled: session.canGoBack) { session.goBack() }
                navButton("arrow.up", help: String(localized: "Parent Folder"), enabled: session.canGoUp) { session.goUp() }
                breadcrumb
                Spacer(minLength: 8)
                Toggle(isOn: $session.oneFileSystem) {
                    Text("Stay on one filesystem").font(.system(size: 11)).foregroundStyle(Pal.subtext)
                }
                .toggleStyle(.checkbox)
                .help(String(localized: "Skip other mounted disks (du -x). Turn off to include them; it can be slow."))
                navButton("arrow.clockwise", help: String(localized: "Refresh"), enabled: true) { session.refresh() }
                navButton("sidebar.right", help: String(localized: "Reveal in File Tree"), enabled: true) {
                    model.jumpToExplorer(path: session.path, host: session.host)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(lucideSymbol: "chart.bar.xaxis").font(.system(size: 13)).foregroundStyle(accent)
                Text(session.phase == .loaded ? humanSize(session.total) : "—")
                    .font(.system(size: 24, weight: .semibold, design: .rounded)).foregroundStyle(Pal.textBright)
                    .monospacedDigit()
                Text("in \(session.entries.count) items").font(.system(size: 12)).foregroundStyle(Pal.overlay)
                if session.phase == .loading { ProgressView().controlSize(.small) }
                Spacer()
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var breadcrumb: some View {
        let comps = session.path.split(separator: "/").map(String.init)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                crumb("/", target: "/")
                ForEach(Array(comps.enumerated()), id: \.offset) { i, c in
                    Image(lucideSymbol: "chevron.right").font(.system(size: 8)).foregroundStyle(Pal.overlay)
                    crumb(c, target: "/" + comps[0...i].joined(separator: "/"))
                }
            }
        }
    }

    private func crumb(_ text: String, target: String) -> some View {
        Button { if target != session.path { session.navigate(to: target) } } label: {
            Text(verbatim: text).font(.system(size: 12, design: .monospaced))
                .foregroundStyle(target == session.path ? Pal.text : Pal.subtext)
                .padding(.horizontal, 4).padding(.vertical, 2)
        }
        .buttonStyle(.plain).pointerCursor()
    }

    private func navButton(_ symbol: String, help: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(lucideSymbol: symbol).font(.system(size: 11, weight: .medium))
                .foregroundStyle(enabled ? Pal.subtext : Pal.overlay.opacity(0.4))
                .frame(width: 26, height: 24)
                .background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor(enabled).disabled(!enabled).help(help)
    }

    // MARK: Full Disk Access (this Mac)

    /// Without Full Disk Access, protected Mail/Messages/Photos/Safari folders cannot be sized.
    /// Only users can enable this permission; open System Settings rather than requesting directly.
    private var fullDiskAccessBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(lucideSymbol: "lock.shield").font(.system(size: 15)).foregroundStyle(Pal.yellow)
            VStack(alignment: .leading, spacing: 4) {
                Text("Full Disk Access is needed for a complete result").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Pal.text)
                Text("Without it, protected folders (Mail, Messages, Photos, Safari, …) are skipped and sizes look smaller than they are. Turn on ServerDock under Privacy & Security › Full Disk Access, then quit and reopen the app.")
                    .font(.system(size: 11.5)).foregroundStyle(Pal.subtext).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Button { FullDiskAccess.openSettings() } label: {
                        Text("Open Privacy Settings").font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 5).background(accent, in: RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(.plain).pointerCursor()
                    Button("Check Again") { hasFullDiskAccess = FullDiskAccess.isGranted; if hasFullDiskAccess { session.refresh() } }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Pal.subtext).pointerCursor()
                    Button("Not Now") { dismissedFDA = true }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Pal.overlay).pointerCursor()
                }.padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Pal.yellow.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Pal.yellow.opacity(0.35), lineWidth: 1))
        .padding(.horizontal, 16).padding(.vertical, 10)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            hasFullDiskAccess = FullDiskAccess.isGranted
        }
    }

    // MARK: List

    @ViewBuilder
    private var content: some View {
        switch session.phase {
        case .failed(let msg):
            VStack(spacing: 8) {
                Image(lucideSymbol: "exclamationmark.triangle").font(.system(size: 24)).foregroundStyle(Pal.overlay)
                Text("Couldn't analyze this folder").font(.system(size: 13)).foregroundStyle(Pal.subtext)
                if !msg.isEmpty { Text(msg).font(.system(size: 11)).foregroundStyle(Pal.overlay).textSelection(.enabled) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loading where session.entries.isEmpty:
            VStack(spacing: 10) {
                ProgressView()
                Text("Measuring folder sizes… large folders can take a while.")
                    .font(.system(size: 12)).foregroundStyle(Pal.overlay)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            if session.entries.isEmpty {
                Text("This folder is empty.").font(.system(size: 12)).foregroundStyle(Pal.overlay)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(session.entries) { e in
                            UsageRow(entry: e, total: session.total, accent: accent, host: session.host, model: model) {
                                open(e)
                            }
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                }
                .opacity(session.phase == .loading ? 0.5 : 1)
            }
        }
    }

    /// Folders navigate/analyze/select in tree; files open in the editor.
    private func open(_ e: DiskUsageSession.Entry) {
        if e.isDir {
            session.navigate(to: e.path)
            model.jumpToExplorer(path: e.path, host: session.host)
        } else {
            // du reports allocated rather than logical size; pass zero and let the editor loader enforce its exact limit.
            model.openFile(RemoteFile(name: e.name, path: e.path, kind: .file, size: 0, modified: nil), host: session.host)
        }
    }
}

private struct UsageRow: View {
    let entry: DiskUsageSession.Entry
    let total: Int64
    let accent: Color
    let host: Host
    let model: AppModel
    let action: () -> Void
    @State private var hover = false

    private var fraction: Double { total > 0 ? min(1, Double(entry.bytes) / Double(total)) : 0 }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(lucideSymbol: entry.isDir ? "folder.fill" : "doc")
                    .font(.system(size: 13)).foregroundStyle(entry.isDir ? accent : Pal.subtext).frame(width: 18)
                Text(entry.name).font(.system(size: 13)).foregroundStyle(Pal.text)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(minWidth: 120, maxWidth: 260, alignment: .leading)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Pal.fill(0.07))
                        Capsule().fill(accent.opacity(entry.isDir ? 0.85 : 0.5))
                            .frame(width: max(2, geo.size.width * fraction))
                    }
                }
                .frame(height: 6)
                Text(String(format: "%.1f%%", fraction * 100)).font(.system(size: 11)).foregroundStyle(Pal.overlay)
                    .monospacedDigit().frame(width: 48, alignment: .trailing)
                Text(humanSize(entry.bytes)).font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.text)
                    .monospacedDigit().frame(width: 70, alignment: .trailing)
                Image(lucideSymbol: "chevron.right").font(.system(size: 9)).foregroundStyle(Pal.overlay)
                    .opacity(entry.isDir ? 1 : 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(hover ? Pal.fill(0.055) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor()
        .onHover { hover = $0 }
        .help(entry.path)
        .contextMenu {
            Button { model.copyRemotePath(entry.path) } label: { Label("Copy Path", lucideSymbol: "doc.on.doc") }
            Button { model.jumpToExplorer(path: entry.path, host: host) } label: {
                Label("Reveal in File Tree", lucideSymbol: "sidebar.right")
            }
            Button { model.openHostTerminal(host, at: entry.isDir ? entry.path : FileTreeState.parentPath(entry.path)) } label: {
                Label("Open Terminal Here", lucideSymbol: "terminal")
            }
        }
    }
}

/// Check macOS Full Disk Access and open its settings.
enum FullDiskAccess {
    /// Reading TCC requires this permission (otherwise EPERM); restart after enabling.
    static var isGranted: Bool {
        let fd = open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
        if fd >= 0 { close(fd); return true }
        return errno != EPERM && errno != EACCES
    }

    static func openSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(u) }
    }
}

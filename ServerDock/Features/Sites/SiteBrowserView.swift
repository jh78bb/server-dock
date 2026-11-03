import SwiftUI
import AppKit

/// Site browser combines breadcrumbs, table, transfers; double-click navigates/opens, dropped files upload.
struct SiteBrowserView: View {
    @ObservedObject var session: SiteSession
    @ObservedObject private var theme = ThemeManager.shared
    @State private var selection = Set<String>()
    @State private var sortOrder = [KeyPathComparator(\SiteEntry.name, comparator: .localizedStandard)]
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var renaming: SiteEntry?
    @State private var renameText = ""
    @State private var deleting: [SiteEntry] = []
    @State private var dropTargeted = false

    private var sorted: [SiteEntry] {
        // Sort folders first, then each group by the selected column.
        let dirs = session.entries.filter(\.isDir).sorted(using: sortOrder)
        let files = session.entries.filter { !$0.isDir }.sorted(using: sortOrder)
        return dirs + files
    }

    private var selectedEntries: [SiteEntry] { session.entries.filter { selection.contains($0.id) } }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(Pal.fill(0.06))
            ZStack {
                table
                overlayState
            }
            if !session.transfers.isEmpty {
                Divider().overlay(Pal.fill(0.06))
                TransferList(session: session)
            }
            statusBar
        }
        .background(Pal.base)
        .onChange(of: session.path) { _ in selection.removeAll() }
        .alert("New Folder", isPresented: $showNewFolder) {
            TextField("Folder name", text: $newFolderName)
            Button("Create") { session.makeFolder(newFolderName) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("New name", text: $renameText)
            Button("Rename") { if let e = renaming { session.rename(e, to: renameText) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog(deleting.count == 1 ? String(localized: "Delete \"\(deleting[0].name)\"?") : String(localized: "Delete \(deleting.count) items?"),
                            isPresented: Binding(get: { !deleting.isEmpty }, set: { if !$0 { deleting = [] } })) {
            Button("Delete", role: .destructive) { session.delete(deleting); selection.removeAll(); deleting = [] }
            Button("Cancel", role: .cancel) { deleting = [] }
        } message: {
            Text("This permanently deletes the items from the server, including everything inside folders. It can't be undone.")
        }
        .alert("Operation Failed", isPresented: Binding(get: { session.notice != nil }, set: { if !$0 { session.notice = nil } })) {
            Button("OK", role: .cancel) { session.notice = nil }
        } message: { Text(session.notice ?? "") }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 6) {
            toolButton("chevron.up", help: String(localized: "Parent Folder"), disabled: session.isRoot) { session.goUp() }
            breadcrumb
            Spacer(minLength: 8)
            if FinderMount.supports(session.site) {
                toolButton("macwindow.badge.plus", help: String(localized: "Mount in Finder")) { mountInFinder() }
            }
            toolButton("arrow.clockwise", help: String(localized: "Refresh")) { session.refresh() }
            toolButton("folder.badge.plus", help: session.isBucketList ? String(localized: "New Bucket") : String(localized: "New Folder")) {
                newFolderName = ""; showNewFolder = true
            }
            toolButton("arrow.up.doc", help: String(localized: "Upload…"), disabled: session.isBucketList) { chooseUpload() }
            toolButton("arrow.down.doc", help: String(localized: "Download…"), disabled: selectedEntries.isEmpty || session.isBucketList) { chooseDownload(selectedEntries) }
            toolButton("trash", help: String(localized: "Delete"), disabled: selectedEntries.isEmpty) { deleting = selectedEntries }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var breadcrumb: some View {
        let comps = SitePath.components(session.path)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                crumb(session.site.name, path: "/", icon: session.site.kind.symbol, last: comps.isEmpty)
                ForEach(Array(comps.enumerated()), id: \.offset) { idx, name in
                    Image(lucideSymbol: "chevron.right").font(.system(size: 8)).foregroundStyle(Pal.overlay)
                    crumb(name, path: "/" + comps.prefix(idx + 1).joined(separator: "/"), icon: nil, last: idx == comps.count - 1)
                }
            }
        }
    }

    private func crumb(_ title: String, path: String, icon: String?, last: Bool) -> some View {
        Button { session.navigate(to: path) } label: {
            HStack(spacing: 4) {
                if let icon { Image(lucideSymbol: icon).font(.system(size: 11)) }
                Text(title).font(.system(size: 12, weight: last ? .semibold : .regular)).lineLimit(1)
            }
            .foregroundStyle(last ? Pal.text : Pal.subtext)
            .padding(.horizontal, 6).padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor()
    }

    private func toolButton(_ symbol: String, help: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(lucideSymbol: symbol).font(.system(size: 13))
                .foregroundStyle(disabled ? Pal.overlay.opacity(0.5) : Pal.subtext)
                .frame(width: 28, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor().disabled(disabled).help(help)
    }

    // MARK: File table

    private var table: some View {
        Table(sorted, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { e in
                HStack(spacing: 7) {
                    Image(lucideSymbol: e.isDir ? (session.isBucketList ? "shippingbox" : "folder.fill") : Self.icon(for: e.name))
                        .foregroundStyle(e.isDir ? Pal.mauve : Pal.subtext).frame(width: 16)
                    Text(e.name).lineLimit(1)
                }
            }
            TableColumn("Size", value: \.sortSize) { e in
                Text(e.isDir ? "—" : ByteCountFormatter.string(fromByteCount: e.size, countStyle: .file))
                    .foregroundStyle(Pal.subtext)
            }.width(min: 60, ideal: 80, max: 120)
            TableColumn("Modified", value: \.sortModified) { e in
                Text(e.modified.map { Self.dateFormat.string(from: $0) } ?? "—").foregroundStyle(Pal.subtext)
            }.width(min: 100, ideal: 140, max: 200)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            let items = session.entries.filter { ids.contains($0.id) }
            if items.isEmpty {
                Button("New Folder") { newFolderName = ""; showNewFolder = true }
                Button("Upload…") { chooseUpload() }.disabled(session.isBucketList)
                Button("Refresh") { session.refresh() }
            } else {
                if items.count == 1, let e = items.first {
                    Button(e.isDir ? "Open" : "Open with Default App") { open(e) }
                }
                Button("Download…") { chooseDownload(items) }.disabled(session.isBucketList)
                if items.count == 1, let e = items.first, session.supportsRename, !session.isBucketList {
                    Button("Rename…") { renameText = e.name; renaming = e }
                }
                Divider()
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(items.map(\.path).joined(separator: "\n"), forType: .string)
                }
                Divider()
                Button("Delete", role: .destructive) { deleting = items }
            }
        } primaryAction: { ids in
            if let id = ids.first, ids.count == 1, let e = session.entry(id) { open(e) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !session.isBucketList else { return false }
            session.upload(urls.filter(\.isFileURL))
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 8).stroke(Pal.mauve, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .background(Pal.mauve.opacity(0.06)).padding(6).allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private var overlayState: some View {
        switch session.phase {
        case .loading:
            if session.entries.isEmpty {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.regular)
                    Text("Connecting…").font(.system(size: 12)).foregroundStyle(Pal.subtext)
                }
            }
        case .error(let msg):
            VStack(spacing: 10) {
                Image(lucideSymbol: "exclamationmark.triangle").font(.system(size: 26)).foregroundStyle(Pal.red)
                Text(msg).font(.system(size: 12)).foregroundStyle(Pal.subtext)
                    .multilineTextAlignment(.center).textSelection(.enabled).frame(maxWidth: 360)
                Button { session.refresh() } label: {
                    Text("Retry").font(.system(size: 12)).foregroundStyle(Pal.mauve)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(Pal.mauve.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointerCursor()
            }
            .padding(20)
            .background(Pal.base.opacity(0.95))
        case .loaded:
            if session.entries.isEmpty {
                Text("This folder is empty").font(.system(size: 12)).foregroundStyle(Pal.overlay).allowsHitTesting(false)
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if case .loading = session.phase, !session.entries.isEmpty { ProgressView().controlSize(.small) }
            Text(statusText).font(.system(size: 11)).foregroundStyle(Pal.overlay)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(Pal.mantle.opacity(0.5))
    }

    private var statusText: String {
        let n = session.entries.count
        let base = String(localized: "\(n) items")
        return selection.isEmpty ? base : base + " · " + String(localized: "\(selection.count) selected")
    }

    // MARK: Actions

    private func mountInFinder() {
        let site = session.site
        Task {
            do { try await FinderMount.mountAndReveal(site, password: SiteKeychain.secret(site.id)) }
            catch { session.notice = error.localizedDescription }
        }
    }

    private func open(_ e: SiteEntry) {
        if e.isDir { session.navigate(to: e.path) } else { session.openWithDefaultApp(e) }
    }

    private func chooseUpload() {
        let p = NSOpenPanel()
        p.canChooseFiles = true; p.canChooseDirectories = true; p.allowsMultipleSelection = true
        p.prompt = String(localized: "Upload")
        if p.runModal() == .OK { session.upload(p.urls) }
    }

    private func chooseDownload(_ items: [SiteEntry]) {
        let p = NSOpenPanel()
        p.canChooseFiles = false; p.canChooseDirectories = true; p.canCreateDirectories = true
        p.prompt = String(localized: "Download Here")
        p.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        if p.runModal() == .OK, let dir = p.url { session.download(items, to: dir) }
    }

    private static func icon(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "svg", "bmp", "tiff": return "photo"
        case "mp4", "mov", "mkv", "avi", "webm": return "film"
        case "mp3", "wav", "flac", "m4a", "aac", "ogg": return "music.note"
        case "zip", "gz", "tgz", "tar", "7z", "rar", "bz2", "xz": return "doc.zipper"
        case "pdf": return "doc.richtext"
        case "txt", "md", "log", "json", "yml", "yaml", "xml", "csv", "conf", "ini": return "doc.text"
        case "swift", "py", "js", "ts", "go", "rs", "java", "c", "cpp", "h", "sh", "rb", "php", "html", "css": return "chevron.left.forwardslash.chevron.right"
        default: return "doc"
        }
    }

    private static let dateFormat: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
    }()
}

/// Bottom transfer list: progress, cancel, clear completed.
private struct TransferList: View {
    @ObservedObject var session: SiteSession
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Transfers").font(.system(size: 11, weight: .medium)).foregroundStyle(Pal.subtext)
                Spacer()
                if session.hasRunningTransfer {
                    Button("Cancel All") { session.cancelTransfers() }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Pal.red).pointerCursor()
                }
                Button("Clear Finished") { session.clearFinishedTransfers() }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Pal.mauve).pointerCursor()
                    .disabled(session.transfers.allSatisfy { $0.state == .running })
            }
            .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 3)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(session.transfers) { t in row(t) }
                }
                .padding(.horizontal, 12).padding(.bottom, 6)
            }
            .frame(maxHeight: 110)
        }
        .background(Pal.mantle.opacity(0.4))
    }

    private func row(_ t: SiteTransfer) -> some View {
        HStack(spacing: 8) {
            Image(lucideSymbol: t.direction == .upload ? "arrow.up.circle" : "arrow.down.circle")
                .font(.system(size: 12)).foregroundStyle(Pal.subtext)
            Text(t.name).font(.system(size: 12)).foregroundStyle(Pal.text).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            switch t.state {
            case .running:
                ProgressView(value: t.fraction).frame(width: 90).controlSize(.small)
                Text(verbatim: "\(Int(t.fraction * 100))%").font(.system(size: 11)).foregroundStyle(Pal.overlay).frame(width: 34, alignment: .trailing)
            case .done:
                Image(lucideSymbol: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(Pal.green)
            case .cancelled:
                Text("Cancelled").font(.system(size: 11)).foregroundStyle(Pal.overlay)
            case .failed(let m):
                Text(m).font(.system(size: 11)).foregroundStyle(Pal.red).lineLimit(1).help(m)
            }
        }
        .padding(.vertical, 2)
    }
}

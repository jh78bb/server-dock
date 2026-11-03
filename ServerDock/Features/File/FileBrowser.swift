import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// TEMPORARILY UNUSED: host-list inline trees replace the main file browser.
/// Per-tab file-browser navigation state cached by AppModel.
@MainActor
final class BrowserState: ObservableObject, FileOpsTarget {
    @Published var path: String = ""
    @Published var entries: [RemoteFile] = []
    @Published var phase: LoadPhase = .loading
    @Published var showHidden = false
    @Published var selection: Set<String> = []   // Selected file paths for multi-file download.
    @Published var hoveredPath: String? = nil     // Hovered row, reported by the shared interaction layer.
    var marqueeBase: Set<String> = []             // Selection snapshot from before rectangle selection, restored on Escape.

    private let fs: RemoteFS
    private var backStack: [String] = []
    private var loadTask: Task<Void, Never>?
    private var started = false

    var initialPath: String?   // Initial directory; nil means the home directory.

    init(fs: RemoteFS) { self.fs = fs }

    /// Navigate to a directory or set it as initial before first loading.
    func open(_ p: String) {
        if started { navigate(to: p) } else { initialPath = p }
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoUp: Bool { path != "/" && !path.isEmpty }

    /// Entries filtered by the hidden-file preference.
    var visible: [RemoteFile] {
        showHidden ? entries : entries.filter { !$0.name.hasPrefix(".") }
    }

    /// Current selection.
    var selectedFiles: [RemoteFile] { visible.filter { selection.contains($0.path) } }

    private var anchorPath: String?   // Range-selection anchor.

    /// Click selects one; Command toggles; Shift selects from the anchor.
    func click(_ p: String, cmd: Bool, shift: Bool) {
        let paths = visible.map(\.path)
        if shift, let anchor = anchorPath,
           let a = paths.firstIndex(of: anchor), let b = paths.firstIndex(of: p) {
            selection = Set(paths[min(a, b)...max(a, b)])   // Keep the anchor unchanged.
        } else if cmd {
            if selection.contains(p) { selection.remove(p) } else { selection.insert(p) }
            anchorPath = p
        } else {
            selection = [p]
            anchorPath = p
        }
    }

    /// Load home on first appearance.
    func startIfNeeded() {
        guard !started else { return }
        started = true
        loadTask = Task {
            let start: String
            if let initialPath { start = initialPath } else { start = await fs.home() }
            await load(start, pushBack: false)
        }
    }

    func enter(_ file: RemoteFile) {
        guard file.isDir else { return }
        navigate(to: file.path)
    }

    func goUp() {
        guard canGoUp else { return }
        let parent = (path as NSString).deletingLastPathComponent
        navigate(to: parent.isEmpty ? "/" : parent)
    }

    func goBack() {
        guard let prev = backStack.popLast() else { return }
        loadTask?.cancel()
        loadTask = Task { await load(prev, pushBack: false) }
    }

    func reload() {
        loadTask?.cancel()
        let p = path
        loadTask = Task { await load(p, pushBack: false) }
    }

    /// On network recovery reset SFTP/reload cwd; skip never-browsed views.
    func reconnect() {
        guard !path.isEmpty else { return }
        fs.resetForReconnect()
        reload()
    }

    private func navigate(to newPath: String) {
        loadTask?.cancel()
        let from = path
        loadTask = Task {
            await load(newPath, pushBack: true, from: from)
        }
    }

    private func load(_ newPath: String, pushBack: Bool, from: String? = nil) async {
        phase = .loading
        let result = await fs.list(newPath)
        if Task.isCancelled { return }
        switch result {
        case .success(let files):
            if pushBack, let from, !from.isEmpty { backStack.append(from) }
            path = newPath
            entries = files
            selection = []      // Clear selection when changing directories.
            anchorPath = nil
            phase = .loaded
        case .failure(let e):
            phase = .error(e.message)
        }
    }

    func cancel() { loadTask?.cancel() }

    // MARK: - FileOpsTarget (shared sidebar/browser context actions)

    func performDelete(_ file: RemoteFile, handle: CommandHandle?) async -> Result<Void, RemoteFSError> {
        let r = await fs.delete(file.path, isDir: file.isDir, handle: handle)
        if case .success = r { reload() }
        return r
    }

    func performRename(_ file: RemoteFile, newName: String) async -> Result<String, RemoteFSError> {
        let parent = (file.path as NSString).deletingLastPathComponent
        let newPath = (parent == "/" || parent.isEmpty) ? "/" + newName : parent + "/" + newName
        let r = await fs.rename(file.path, to: newPath)
        switch r {
        case .success: reload(); return .success(newPath)
        case .failure(let e): return .failure(e)
        }
    }

    func performChmod(_ file: RemoteFile, mode: String) async -> Result<Void, RemoteFSError> {
        await fs.chmod(file.path, mode: mode)
    }

    func currentPerms(_ file: RemoteFile) async -> Int? {
        if case .success(let v) = await fs.statPerms(file.path) { return v }
        return nil
    }

    func performCreate(_ name: String, isDir: Bool, inDir dir: String) async -> Result<Void, RemoteFSError> {
        let path = (dir == "/" ? "" : dir) + "/" + name
        let r = isDir ? await fs.mkdir(path) : await fs.createFile(path)
        if case .success = r { reload() }
        return r
    }
}

/// TEMPORARILY UNUSED in the main area; preserve SFTP browser UI for restoration.
struct FileBrowser: View {
    @ObservedObject var state: BrowserState
    let host: Host
    let model: AppModel
    var onOpenFile: (RemoteFile) -> Void = { _ in }
    @ObservedObject private var theme = ThemeManager.shared
    @State private var dropTarget = false
    @State private var favTick = 0   // Recompute favorite-star rows after favorite changes.

    private static let dropBlue = Color(hex: 0x1E90FF)
    // Row height/top inset must match rendering for mouse-y-to-row conversion.
    static let rowHeight: CGFloat = 28
    static let topInset: CGFloat = 4
    /// Allow drop upload into cwd only with a connected path.
    private var canUpload: Bool { !state.path.isEmpty }

    /// Use cwd as the upload destination.
    private var currentDir: RemoteFile {
        let name = state.path == "/" ? "/" : (state.path as NSString).lastPathComponent
        return RemoteFile(name: name, path: state.path, kind: .directory, size: 0, modified: nil)
    }

    var body: some View {
        mainBody.onReceive(model.$favorites) { _ in favTick &+= 1 }
    }

    @ViewBuilder
    private var mainBody: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(Pal.fill(0.06))
            columnHeader
            Divider().overlay(Pal.fill(0.06))
            content
        }
        .background(Pal.base)
        .overlay { if dropTarget { dropOverlay } }
        .animation(.easeOut(duration: 0.12), value: dropTarget)
        .onDrop(of: [.fileURL], isTargeted: canUpload ? $dropTarget : nil) { providers in
            guard canUpload else { return false }
            loadURLs(providers) { urls in
                if !urls.isEmpty { model.uploadFiles(urls, toDir: state.path, host: host) }
            }
            return true
        }
        .onAppear { state.startIfNeeded() }
    }

    private var dropOverlay: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Self.dropBlue.opacity(0.07))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Self.dropBlue, lineWidth: 2))
            .overlay {
                VStack(spacing: 8) {
                    Image(lucideSymbol: "square.and.arrow.up").font(.system(size: 22, weight: .medium))
                    Text("Release to upload to the current directory").font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(Self.dropBlue)
                .padding(.horizontal, 18).padding(.vertical, 14)
                .background(Pal.solidMantle.opacity(0.92), in: RoundedRectangle(cornerRadius: 10))
            }
            .padding(6)
            .allowsHitTesting(false)
            .transition(.opacity)
    }

    private func loadURLs(_ providers: [NSItemProvider], _ completion: @escaping ([URL]) -> Void) {
        var urls: [URL] = []
        let group = DispatchGroup()
        for p in providers {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL { urls.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(urls) }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            iconButton("chevron.left", enabled: state.canGoBack) { state.goBack() }
            iconButton("chevron.up", enabled: state.canGoUp) { state.goUp() }
            iconButton("arrow.clockwise", enabled: true) { state.reload() }

            Text(state.path.isEmpty ? "…" : state.path)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Pal.subtext)
                .lineLimit(1).truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)

            if !state.selectedFiles.isEmpty {
                let dlFiles = state.selectedFiles.filter { !$0.isDir }
                if !dlFiles.isEmpty {
                    Button { model.downloadFiles(dlFiles, host: host) } label: {
                        HStack(spacing: 5) {
                            Image(lucideSymbol: "square.and.arrow.down").font(.system(size: 11))
                            Text("Download (\(dlFiles.count))").font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(Pal.tint)
                        .padding(.horizontal, 9).frame(height: 26)
                        .background(Pal.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .help(String(localized: "Download Selected Files"))
                }
                Button { model.requestBatchDelete(state.selectedFiles, host: host, target: state) } label: {
                    HStack(spacing: 5) {
                        Image(lucideSymbol: "trash").font(.system(size: 11))
                        Text("Delete (\(state.selectedFiles.count))").font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(Pal.red)
                    .padding(.horizontal, 9).frame(height: 26)
                    .background(Pal.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help(String(localized: "Delete Selected Items"))
            }

            Button { model.beginUpload(into: currentDir, host: host) } label: {
                Image(lucideSymbol: "square.and.arrow.up")
                    .font(.system(size: 12)).foregroundStyle(Pal.subtext)
                    .frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor(!state.path.isEmpty)
            .help(String(localized: "Upload file to the current directory"))
            .disabled(state.path.isEmpty)

            Button { state.showHidden.toggle() } label: {
                Image(lucideSymbol: state.showHidden ? "eye" : "eye.slash")
                    .font(.system(size: 12)).foregroundStyle(state.showHidden ? Pal.tint : Pal.overlay)
                    .frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help(state.showHidden ? String(localized: "Hide Dotfiles") : String(localized: "Show Hidden Files"))
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func iconButton(_ symbol: String, enabled: Bool, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(lucideSymbol: symbol).font(.system(size: 12, weight: .medium))
                .foregroundStyle(enabled ? Pal.subtext : Pal.overlay.opacity(0.4))
                .frame(width: 26, height: 26)
                .background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor(enabled)
        .disabled(!enabled)
    }

    private var columnHeader: some View {
        HStack(spacing: 0) {
            Text("Name").frame(maxWidth: .infinity, alignment: .leading)
            Text("Size").frame(width: 90, alignment: .trailing)
            Text("Modified").frame(width: 150, alignment: .trailing)
        }
        .font(.system(size: 11)).foregroundStyle(Pal.overlay)
        .padding(.horizontal, 16).padding(.vertical, 6)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch state.phase {
        case .loading:
            centered { ProgressView().controlSize(.small) }
        case .error(let msg):
            centered {
                VStack(spacing: 10) {
                    Image(lucideSymbol: "exclamationmark.triangle").font(.system(size: 24)).foregroundStyle(Pal.yellow)
                    Text(msg).font(.system(size: 12)).foregroundStyle(Pal.subtext)
                        .multilineTextAlignment(.center).textSelection(.enabled)
                    Button("Retry") { state.reload() }.buttonStyle(.plain).pointerCursor().foregroundStyle(Pal.tint)
                }
                .padding(.horizontal, 40)
            }
        case .loaded:
            // A shared AppKit layer owns clicks/double-clicks/hover/cursors/selection/context menus;
            // rows only render. GeometryReader fills the viewport so empty space receives events too.
            GeometryReader { geo in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(state.visible) { file in
                            FileRow(file: file,
                                    favorite: model.isFavorite(file.path, hostId: host.id),
                                    selected: state.selection.contains(file.path),
                                    hovered: state.hoveredPath == file.path)
                                .frame(height: Self.rowHeight)
                        }
                        if state.visible.isEmpty {
                            Text("Empty Folder").font(.system(size: 13)).foregroundStyle(Pal.overlay)
                                .frame(maxWidth: .infinity).padding(.top, 60)
                        }
                    }
                    .padding(.vertical, Self.topInset)
                    .frame(minHeight: geo.size.height, alignment: .top)
                    .overlay(
                        FileListInteraction(
                            rowCount: state.visible.count,
                            rowHeight: Self.rowHeight,
                            topInset: Self.topInset,
                            onPrimaryClick: { i, cmd, shift in handlePrimaryClick(i, cmd: cmd, shift: shift) },
                            onOpen: { i in handleOpen(i) },
                            onHover: { i in
                                state.hoveredPath = i.flatMap { state.visible.indices.contains($0) ? state.visible[$0].path : nil }
                            },
                            onMarquee: { idxs in handleMarquee(idxs) },
                            onMarqueeBegin: { state.marqueeBase = state.selection },
                            onMarqueeCancel: { state.selection = state.marqueeBase },
                            onEscape: { state.selection = [] },
                            makeMenu: { i in makeContextMenu(forIndex: i) }
                        )
                    )
                }
            }
        }
    }

    private func handlePrimaryClick(_ i: Int?, cmd: Bool, shift: Bool) {
        if let i, state.visible.indices.contains(i) {
            state.click(state.visible[i].path, cmd: cmd, shift: shift)
        } else if !cmd, !shift {
            state.selection = []   // Clear selection when clicking empty space.
        }
    }

    private func handleOpen(_ i: Int?) {
        guard let i, state.visible.indices.contains(i) else { return }
        let f = state.visible[i]
        if f.isDir { state.enter(f) } else { onOpenFile(f) }
    }

    private func handleMarquee(_ idxs: Set<Int>) {
        state.selection = Set(idxs.compactMap { state.visible.indices.contains($0) ? state.visible[$0].path : nil })
    }

    // MARK: - AppKit context menu (shared event handling suppresses SwiftUI contextMenu)

    private func makeContextMenu(forIndex i: Int?) -> NSMenu? {
        let menu = NSMenu()
        if let i, state.visible.indices.contains(i) {
            let file = state.visible[i]
            if !state.selection.contains(file.path) { state.selection = [file.path] }   // Right-clicking an unselected item selects it first.
            if state.selection.count > 1, state.selection.contains(file.path) {
                let sel = state.selectedFiles
                let dl = sel.filter { !$0.isDir }
                if !dl.isEmpty {
                    menu.addItem(ClosureMenuItem(title: String(localized: "Download Selected (\(dl.count))"), lucideSymbol: "square.and.arrow.down") {
                        model.downloadFiles(dl, host: host)
                    })
                    menu.addItem(.separator())
                }
                menu.addItem(ClosureMenuItem(title: String(localized: "Delete Selected (\(sel.count))"), lucideSymbol: "trash") {
                    model.requestBatchDelete(sel, host: host, target: state)
                })
            } else {
                addSingleFileItems(to: menu, file: file)
            }
        } else {
            addBlankItems(to: menu)
        }
        return menu
    }

    private func addSingleFileItems(to menu: NSMenu, file: RemoteFile) {
        if file.isDir {
            menu.addItem(ClosureMenuItem(title: String(localized: "Upload File…"), lucideSymbol: "square.and.arrow.up") {
                model.beginUpload(into: file, host: host)
            })
            menu.addItem(ClosureMenuItem(title: String(localized: "New File"), lucideSymbol: "doc.badge.plus") {
                model.fileMenuRequestCreate(isDir: false, inDir: file.path, host: host, target: state)
            })
            menu.addItem(ClosureMenuItem(title: String(localized: "New Folder"), lucideSymbol: "folder.badge.plus") {
                model.fileMenuRequestCreate(isDir: true, inDir: file.path, host: host, target: state)
            })
            menu.addItem(.separator())
        } else {
            menu.addItem(ClosureMenuItem(title: String(localized: "Download"), lucideSymbol: "square.and.arrow.down") {
                model.downloadFiles([file], host: host)
            })
            if ArchiveKind.detect(file.name) != nil {
                menu.addItem(ClosureMenuItem(title: String(localized: "Extract"), lucideSymbol: "doc.zipper") {
                    model.requestExtract(file, host: host)
                })
            }
            menu.addItem(.separator())
        }
        menu.addItem(ClosureMenuItem(title: String(localized: "Refresh"), lucideSymbol: "arrow.clockwise") { state.reload() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: String(localized: "Rename"), lucideSymbol: "pencil") {
            model.fileMenuRequestRename(file, host: host, target: state)
        })
        menu.addItem(ClosureMenuItem(title: String(localized: "Permissions"), lucideSymbol: "lock") {
            model.fileMenuRequestChmod(file, host: host, target: state)
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: String(localized: "Delete"), lucideSymbol: "trash") {
            model.fileMenuRequestDelete(file, host: host, target: state)
        })
    }

    private func addBlankItems(to menu: NSMenu) {
        menu.addItem(ClosureMenuItem(title: String(localized: "Upload file here"), lucideSymbol: "square.and.arrow.up") {
            model.beginUpload(into: currentDir, host: host)
        })
        menu.addItem(ClosureMenuItem(title: String(localized: "New File"), lucideSymbol: "doc.badge.plus") {
            model.fileMenuRequestCreate(isDir: false, inDir: state.path, host: host, target: state)
        })
        menu.addItem(ClosureMenuItem(title: String(localized: "New Folder"), lucideSymbol: "folder.badge.plus") {
            model.fileMenuRequestCreate(isDir: true, inDir: state.path, host: host, target: state)
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: String(localized: "Refresh"), lucideSymbol: "arrow.clockwise") { state.reload() })
    }

    private func centered<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        VStack { Spacer(); c(); Spacer() }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FileRow: View {
    let file: RemoteFile
    let favorite: Bool
    let selected: Bool
    let hovered: Bool
    // Observe theme changes so Pal colors update immediately instead of only after hover.
    @ObservedObject private var theme = ThemeManager.shared

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; return f
    }()

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 9) {
                FileTypeIcon(file: file, size: 13)
                    .frame(width: 18)
                Text(file.name).font(.system(size: 13)).foregroundStyle(Pal.text).lineLimit(1)
                if favorite { Image(lucideSymbol: "star.fill").font(.system(size: 8)).foregroundStyle(Pal.yellow).help(String(localized: "In Favorites")) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(file.isDir ? "—" : humanSize(file.size))
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(Pal.subtext)
                .frame(width: 90, alignment: .trailing)
            Text(file.modified.map { Self.dateFmt.string(from: $0) } ?? "—")
                .font(.system(size: 12)).foregroundStyle(Pal.overlay)
                .frame(width: 150, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .frame(maxHeight: .infinity)
        .background(selected ? Pal.tint.opacity(0.16) : (hovered ? Pal.fill(0.05) : Color.clear))
        // Only selected rows report remote-path global frames for download fly-in origins, avoiding unselected-row overhead.
        .background {
            if selected {
                GeometryReader { geo in
                    Color.clear
                        .onAppear { AppModel.shared.fileRowGlobalFrames[file.path] = geo.frame(in: .global) }
                        .onChange(of: geo.frame(in: .global)) { AppModel.shared.fileRowGlobalFrames[file.path] = $0 }
                        .onDisappear { AppModel.shared.fileRowGlobalFrames[file.path] = nil }
                }
            }
        }
        // Render only; parent FileListInteraction owns all mouse behavior.
    }
}

/// Closure-backed NSMenuItem uses itself as target, avoiding scattered @objc selectors.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, lucideSymbol: String? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        self.target = self
        if let lucideSymbol {
            self.image = AppIcon.image(lucideSymbol)
        }
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { handler() }
}

/// One interaction overlay handles list events in a shared coordinate space.
/// Fixed row heights map y to indices; rectangle dragging does not conflict with wheel/trackpad scrolling.
struct FileListInteraction: NSViewRepresentable {
    var rowCount: Int
    var rowHeight: CGFloat
    var topInset: CGFloat
    var onPrimaryClick: (_ index: Int?, _ cmd: Bool, _ shift: Bool) -> Void
    var onOpen: (_ index: Int?) -> Void
    var onHover: (_ index: Int?) -> Void
    var onMarquee: (_ indices: Set<Int>) -> Void
    var onMarqueeBegin: () -> Void
    var onMarqueeCancel: () -> Void
    var onEscape: () -> Void
    var makeMenu: (_ index: Int?) -> NSMenu?

    func makeNSView(context: Context) -> InteractionView { InteractionView() }

    func updateNSView(_ v: InteractionView, context: Context) {
        v.rowCount = rowCount
        v.rowHeight = rowHeight
        v.topInset = topInset
        v.onPrimaryClick = onPrimaryClick
        v.onOpen = onOpen
        v.onHover = onHover
        v.onMarquee = onMarquee
        v.onMarqueeBegin = onMarqueeBegin
        v.onMarqueeCancel = onMarqueeCancel
        v.onEscape = onEscape
        v.makeMenu = makeMenu
    }

    final class InteractionView: NSView {
        var rowCount = 0
        var rowHeight: CGFloat = 28
        var topInset: CGFloat = 4
        var onPrimaryClick: (Int?, Bool, Bool) -> Void = { _, _, _ in }
        var onOpen: (Int?) -> Void = { _ in }
        var onHover: (Int?) -> Void = { _ in }
        var onMarquee: (Set<Int>) -> Void = { _ in }
        var onMarqueeBegin: () -> Void = {}
        var onMarqueeCancel: () -> Void = {}
        var onEscape: () -> Void = {}
        var makeMenu: (Int?) -> NSMenu? = { _ in nil }

        private var dragStart: NSPoint?
        private var marqueeActive = false
        private var marqueeAborted = false
        private var marqueeRect: NSRect?

        override var isFlipped: Bool { true }   // Top-left origin with downward y, matching the row order.
        override var acceptsFirstResponder: Bool { true }   // Become first responder to receive Escape.

        // Draw selection directly in flipped coordinates; CALayer children do not flip with the view and would mirror it.
        override func draw(_ dirtyRect: NSRect) {
            guard let r = marqueeRect else { return }
            let accent = NSColor.selectedContentBackgroundColor
            accent.withAlphaComponent(0.18).setFill()
            accent.setStroke()
            let path = NSBezierPath(rect: r)
            path.fill()
            path.lineWidth = 1
            path.stroke()
        }

        /// Row under the event, or nil for empty space.
        private func index(at p: NSPoint) -> Int? {
            let y = p.y - topInset
            guard y >= 0 else { return nil }
            let i = Int(floor(y / rowHeight))
            return (0..<rowCount).contains(i) ? i : nil
        }

        private func indices(in rect: NSRect) -> Set<Int> {
            guard rowCount > 0, rowHeight > 0 else { return [] }
            let lo = Int(floor((rect.minY - topInset) / rowHeight))
            let hi = Int(floor((rect.maxY - topInset) / rowHeight))
            guard hi >= 0, lo < rowCount else { return [] }   // No vertical overlap between the rectangle and content.
            var out = Set<Int>()
            for i in max(0, lo)...min(rowCount - 1, hi) { out.insert(i) }
            return out
        }

        // Enable window mouseMoved events as a safeguard beyond the tracking area's flag.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.acceptsMouseMovedEvents = true
        }

        // Hover / cursor.
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited, .cursorUpdate],
                owner: self, userInfo: nil))
        }
        override func mouseMoved(with event: NSEvent) {
            onHover(index(at: convert(event.locationInWindow, from: nil)))
        }
        override func mouseExited(with event: NSEvent) { onHover(nil) }
        override func cursorUpdate(with event: NSEvent) {
            if index(at: convert(event.locationInWindow, from: nil)) != nil { NSCursor.pointingHand.set() }
            else { NSCursor.arrow.set() }
        }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)   // Take keyboard focus to receive Escape.
            let p = convert(event.locationInWindow, from: nil)
            if event.clickCount >= 2 {
                onOpen(index(at: p)); dragStart = nil; return
            }
            dragStart = p
            marqueeActive = false
            marqueeAborted = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start = dragStart, !marqueeAborted else { return }
            let p = convert(event.locationInWindow, from: nil)
            if !marqueeActive, hypot(p.x - start.x, p.y - start.y) > 4 {
                marqueeActive = true
                onMarqueeBegin()   // Snapshot the previous selection so Escape can restore it.
            }
            guard marqueeActive else { return }
            let rect = NSRect(x: min(start.x, p.x), y: min(start.y, p.y),
                              width: abs(p.x - start.x), height: abs(p.y - start.y))
            marqueeRect = rect
            needsDisplay = true
            onMarquee(indices(in: rect))
        }

        override func mouseUp(with event: NSEvent) {
            defer { dragStart = nil; marqueeActive = false; marqueeAborted = false }
            if marqueeAborted { marqueeRect = nil; needsDisplay = true; return }   // Selection canceled with Escape.
            if marqueeActive {
                marqueeRect = nil
                needsDisplay = true
                return
            }
            let p = convert(event.locationInWindow, from: nil)
            onPrimaryClick(index(at: p), event.modifierFlags.contains(.command), event.modifierFlags.contains(.shift))
        }

        // Escape cancels rectangle dragging and restores selection; otherwise clears selection.
        override func cancelOperation(_ sender: Any?) {
            if marqueeActive, !marqueeAborted {
                marqueeAborted = true
                marqueeRect = nil
                needsDisplay = true
                onMarqueeCancel()
            } else if dragStart == nil {
                onEscape()
            }
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            makeMenu(index(at: convert(event.locationInWindow, from: nil)))
        }
    }
}

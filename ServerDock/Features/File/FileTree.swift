import SwiftUI

/// Plain-data tree node avoids thousands of individually observed objects.
final class FileTreeNode {
    var file: RemoteFile                  // Mutable so a rename updates the local name/path in place.
    var children: [FileTreeNode]? = nil   // nil means not loaded yet.
    var isExpanded = false
    var isLoading = false
    init(file: RemoteFile) { self.file = file }
}

/// Flattened node/depth row; LazyVStack renders visible rows only.
struct FlatNode: Identifiable {
    let node: FileTreeNode
    let depth: Int
    var id: String { node.file.path }
}

/// Per-host/tab tree state flattens expanded nodes into flat,
/// keeping large trees efficient with visible-only LazyVStack rendering.
@MainActor
final class FileTreeState: ObservableObject, FileOpsTarget {
    private let fs: RemoteFS
    private var roots: [FileTreeNode] = []
    @Published var flat: [FlatNode] = []
    @Published var phase: LoadPhase = .loading
    @Published var selectedPath: String? = nil
    private var started = false
    private var revealTarget: String?
    /// Folder displayed in the content list, changed by tree selection or terminal cd.
    @Published private(set) var selectedDirPath: String?
    private(set) var selectedDirNode: FileTreeNode?
    private var revealGen = 0                      // Generation invalidating older reveals during consecutive cd changes.
    private var autoExpanded = Set<String>()       // Track automatically expanded folders separately for later collapse.

    init(fs: RemoteFS, revealOnLoad: String? = nil) {
        self.fs = fs
        self.revealTarget = revealOnLoad
    }

    func startIfNeeded() {
        guard !started else { return }
        started = true
        Task {
            let r = await fs.list("/")
            switch r {
            case .success(let files):
                roots = files.map { FileTreeNode(file: $0) }
                phase = .loaded
                rebuild()
                // After loading, obtain the newest reveal target, including requests received during preload.
                let target: String
                if let t = revealTarget { target = t } else { target = await fs.home() }
                await revealPath(target)
            case .failure(let e):
                phase = .error(e.message)
            }
        }
    }

    /// Expand/collapse a directory node.
    func toggle(_ node: FileTreeNode) {
        guard node.file.isDir else { return }
        autoExpanded.remove(node.file.path)   // Exclude manually manipulated folders from automatic collapse.
        node.isExpanded.toggle()
        if node.isExpanded, node.children == nil {
            node.isLoading = true
            rebuild(animated: true)
            Task {
                let ok = await load(node)
                // Collapse failed loads instead of showing false emptiness; retry on the next click.
                if !ok { node.isExpanded = false }
                rebuild(animated: true)
            }
        } else {
            rebuild(animated: true)
        }
        selectDir(node)   // Avoid duplicate loading while isLoading.
    }

    /// Select a folder for the content list and load it if needed.
    func selectDir(_ node: FileTreeNode) {
        guard node.file.isDir else { return }
        selectedDirNode = node
        selectedDirPath = node.file.path
        selectedPath = node.file.path
        if node.children == nil, !node.isLoading {
            node.isLoading = true
            Task {
                _ = await load(node)
                rebuild()
            }
        }
    }

    /// Direct files only; folders remain in the upper tree.
    var selectedDirItems: [FileTreeNode] { (selectedDirNode?.children ?? []).filter { !$0.file.isDir } }

    /// Return whether loading children succeeded; never cache failures, leaving children=nil.
    /// Otherwise one transient failure permanently looks empty and prevents reload on expansion.
    @discardableResult
    private func load(_ node: FileTreeNode) async -> Bool {
        let r = await fs.list(node.file.path)
        node.isLoading = false
        switch r {
        case .success(let files):
            node.children = files.map { FileTreeNode(file: $0) }
            return true
        case .failure:
            node.children = nil
            return false
        }
    }

    /// Reveal cwd after terminal cd by expanding ancestors/selecting the target.
    func reveal(_ path: String) {
        revealTarget = path
        guard phase == .loaded else { return }
        Task { await revealPath(path) }
    }

    /// Expand ancestors top-down with one UI update per step, then select the final item.
    /// First collapse prior auto-expanded branches outside the new path to prevent unbounded growth.
    private func revealPath(_ path: String) async {
        revealGen += 1
        let gen = revealGen
        let comps = path.split(separator: "/").map(String.init)

        var chain = Set<String>()
        var acc = ""
        for c in comps { acc += "/" + c; chain.insert(acc) }
        var collapsed = false
        for p in autoExpanded where !chain.contains(p) {
            if let n = node(at: p) { n.isExpanded = false; collapsed = true }
            autoExpanded.remove(p)
        }
        if collapsed { rebuild(animated: true) }

        var level = roots
        var target: FileTreeNode?
        for comp in comps {
            guard let node = level.first(where: { $0.file.name == comp }) else { break }
            target = node
            guard node.file.isDir else { break }
            // Stop on load failure without expansion/empty caching, leaving children=nil for retry.
            if node.children == nil {
                let ok = await load(node)
                if gen != revealGen { return }    // A newer reveal superseded this operation; stop.
                guard ok else { break }
            }
            if !node.isExpanded {
                node.isExpanded = true
                autoExpanded.insert(node.file.path)
                rebuild(animated: true)           // Publish each opened level for natural top-down expansion.
            }
            level = node.children ?? []
        }
        if gen != revealGen { return }
        selectedPath = target?.file.path
        if let t = target {
            selectedDirPath = t.file.isDir ? t.file.path : Self.parentPath(t.file.path)
        }
        rebuild(animated: true)
    }

    /// Flatten expanded nodes into display rows.
    private func rebuild(animated: Bool = false) {
        var out: [FlatNode] = []
        func walk(_ nodes: [FileTreeNode], _ depth: Int) {
            for n in nodes {
                out.append(FlatNode(node: n, depth: depth))
                if n.isExpanded, let ch = n.children { walk(ch, depth + 1) }
            }
        }
        walk(roots, 0)
        // Resolve the selected folder by path because refresh may replace nodes.
        if let p = selectedDirPath { selectedDirNode = node(at: p) ?? selectedDirNode }
        if animated {
            withAnimation(.easeOut(duration: 0.16)) { flat = out }
        } else {
            flat = out
        }
    }

    func reload() {
        started = false
        roots = []
        flat = []
        phase = .loading
        selectedPath = nil
        selectedDirPath = nil
        selectedDirNode = nil
        autoExpanded.removeAll()
        startIfNeeded()
    }

    /// Network recovery resets SFTP/reloads the tree, skipping never-loaded trees.
    func reconnect() {
        guard started else { return }
        fs.resetForReconnect()
        reload()
    }

    // MARK: - File context actions

    enum RefreshOutcome { case ok, gone, failed(String) }

    static func parentPath(_ p: String) -> String {
        guard let slash = p.lastIndex(of: "/"), slash != p.startIndex else { return "/" }
        return String(p[p.startIndex..<slash])
    }

    /// Find a node by path through depth-first search.
    func node(at path: String) -> FileTreeNode? {
        func walk(_ nodes: [FileTreeNode]) -> FileTreeNode? {
            for n in nodes {
                if n.file.path == path { return n }
                if let ch = n.children, let hit = walk(ch) { return hit }
            }
            return nil
        }
        return walk(roots)
    }

    /// Reload while preserving expansion; on failure use exists to distinguish deletion from transient errors.
    @discardableResult
    func refreshDir(_ path: String) async -> RefreshOutcome {
        if path == "/" || path.isEmpty {
            let r = await fs.list("/")
            if case .success(let files) = r { roots = files.map { FileTreeNode(file: $0) }; rebuild(); return .ok }
            return await fs.exists("/") ? .failed(String(localized: "Couldn't Refresh")) : .gone
        }
        guard let node = node(at: path), node.file.isDir else { return .failed(String(localized: "Not a directory")) }
        let r = await fs.list(path)
        switch r {
        case .success(let files):
            node.children = files.map { FileTreeNode(file: $0) }
            node.isExpanded = true
            rebuild()
            return .ok
        case .failure(let e):
            return await fs.exists(path) ? .failed(e.message) : .gone
        }
    }

    /// Refresh the file's parent directory.
    @discardableResult
    func refreshParent(of filePath: String) async -> RefreshOutcome {
        await refreshDir(Self.parentPath(filePath))
    }

    /// Remove missing/deleted nodes and select their parent.
    func removeAndSelectParent(_ path: String) {
        let parent = Self.parentPath(path)
        func remove(_ nodes: inout [FileTreeNode]) -> Bool {
            if let idx = nodes.firstIndex(where: { $0.file.path == path }) { nodes.remove(at: idx); return true }
            for n in nodes where n.children != nil {
                if remove(&n.children!) { return true }
            }
            return false
        }
        _ = remove(&roots)
        selectedPath = (parent == "/") ? nil : parent
        rebuild()
    }

    /// After successful remote deletion, remove locally and select the parent.
    func performDelete(_ file: RemoteFile, handle: CommandHandle?) async -> Result<Void, RemoteFSError> {
        let r = await fs.delete(file.path, isDir: file.isDir, handle: handle)
        if case .success = r { removeAndSelectParent(file.path) }
        return r
    }

    /// Rename within one directory, updating the local tree without relisting to preserve expanded descendants.
    /// Preserve selection, scroll only if necessary, and return the new path for editor synchronization.
    func performRename(_ file: RemoteFile, newName: String) async -> Result<String, RemoteFSError> {
        let parent = Self.parentPath(file.path)
        let newPath = parent == "/" ? "/" + newName : parent + "/" + newName
        let r = await fs.rename(file.path, to: newPath)
        switch r {
        case .success:
            renameLocally(oldPath: file.path, newName: newName, newPath: newPath)
            selectedPath = newPath
            rebuild()
            return .success(newPath)
        case .failure(let e):
            return .failure(e)
        }
    }

    /// Update node name/path and descendant directory prefixes recursively; resort the parent afterward.
    private func renameLocally(oldPath: String, newName: String, newPath: String) {
        guard let target = node(at: oldPath) else { return }   // Do not name this node; it would shadow node(at:).
        let f = target.file
        target.file = RemoteFile(name: newName, path: newPath, kind: f.kind, size: f.size, modified: f.modified)
        if f.isDir, let children = target.children {
            retargetPaths(children, oldBase: oldPath, newBase: newPath)
        }
        // Renaming may change the parent's alphabetical order; resort.
        let parent = Self.parentPath(oldPath)
        if let pnode = node(at: parent) {
            pnode.children = pnode.children.map(sortNodes)
        } else {
            roots = sortNodes(roots)   // Top level (parent == "/"), without a corresponding node.
        }
    }

    /// For renamed directories, replace oldBase with newBase recursively without changing descendant names.
    private func retargetPaths(_ nodes: [FileTreeNode], oldBase: String, newBase: String) {
        for n in nodes {
            let p = n.file.path
            guard p.hasPrefix(oldBase + "/") else { continue }
            let nf = n.file
            n.file = RemoteFile(name: nf.name, path: newBase + String(p.dropFirst(oldBase.count)),
                                kind: nf.kind, size: nf.size, modified: nf.modified)
            if let ch = n.children { retargetPaths(ch, oldBase: oldBase, newBase: newBase) }
        }
    }

    /// Sort directories first, then names case-insensitively, matching RemoteFS.sorted.
    private func sortNodes(_ nodes: [FileTreeNode]) -> [FileTreeNode] {
        nodes.sorted { a, b in
            if a.file.isDir != b.file.isDir { return a.file.isDir }
            return a.file.name.localizedCaseInsensitiveCompare(b.file.name) == .orderedAscending
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
        if case .success = r { _ = await refreshDir(dir) }
        return r
    }
}

/// Explorer-style remote sidebar tree following terminal cwd.
struct SidebarFileTree: View {
    @ObservedObject var state: FileTreeState
    let host: Host
    let model: AppModel
    @State private var favTick = 0   // Subscribe only to favorite changes for star updates, not the whole model.
    // Avoid stored closures; newly created closures look like changed inputs to SwiftUI.
    // Otherwise sidebar resizing recomputes thousands of rows. Call model.openFile internally to preserve comparable stored properties.
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        content.onReceive(model.$favorites) { _ in favTick &+= 1 }
    }

    @ViewBuilder
    private var content: some View {
        Group {
            switch state.phase {
            case .loading:
                centered { ProgressView().controlSize(.small) }
            case .error(let msg):
                centered {
                    VStack(spacing: 8) {
                        Text(msg).font(.system(size: 11)).foregroundStyle(Pal.subtext)
                            .multilineTextAlignment(.center).lineLimit(4)
                        Button("Retry") { state.reload() }.buttonStyle(.plain).pointerCursor().foregroundStyle(Pal.tint)
                    }
                    .padding(.horizontal, 16)
                }
            case .loaded:
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(state.flat) { item in
                                FlatRow(item: item,
                                        favorite: model.isFavorite(item.node.file.path, hostId: host.id),
                                        selected: state.selectedPath,
                                        host: host, model: model, tree: state,
                                        onTap: { state.toggle(item.node) },
                                        onOpenFile: { model.openFile($0, host: host) })
                                .id(item.node.file.path)
                                .transition(.opacity)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onChange(of: state.selectedPath) { sel in
                        guard let sel else { return }
                        // Scroll next run loop after row layout; same-transaction scrolling can jump before rows exist.
                        // anchor=nil scrolls minimally only if the target is outside the viewport.
                        DispatchQueue.main.async {
                            withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(sel, anchor: nil) }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { state.startIfNeeded() }
    }

    private func centered<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        VStack { Spacer(); c(); Spacer() }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Auxiliary panel flattens direct files from the selected/terminal directory below the tree.
/// Makes files visible among many folders; they remain in the tree too. Click opens the editor.
struct FolderFileList: View {
    @ObservedObject var state: FileTreeState
    let host: Host
    let model: AppModel
    @State private var favTick = 0
    let expanded: Bool          // false shows only the header.
    let onToggle: () -> Void
    @ObservedObject private var theme = ThemeManager.shared

    static let headerHeight: CGFloat = 36

    var body: some View {
        content.onReceive(model.$favorites) { _ in favTick &+= 1 }
    }

    @ViewBuilder
    private var content: some View {
        let items = state.selectedDirItems
        VStack(spacing: 0) {
            header(count: items.count)
            if !expanded {
                EmptyView()
            } else if state.selectedDirNode == nil {
                placeholder(String(localized: "Select a folder to list its files"))
            } else if state.selectedDirNode?.isLoading == true && items.isEmpty {
                VStack { Spacer(); ProgressView().controlSize(.small); Spacer() }.frame(maxWidth: .infinity)
            } else if items.isEmpty {
                placeholder(String(localized: "No files in this folder"))
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items, id: \.file.path) { node in
                            FolderFileRow(node: node, favorite: model.isFavorite(node.file.path, hostId: host.id), selected: state.selectedPath, host: host, model: model, tree: state)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Pal.fill(0.02))
    }

    private func header(count: Int) -> some View {
        HStack(spacing: 6) {
            Image(lucideSymbol: "folder.fill").font(.system(size: 11)).foregroundStyle(host.accent)
            VStack(alignment: .leading, spacing: 0) {
                Text(state.selectedDirPath.map { $0 == "/" ? "/" : ($0 as NSString).lastPathComponent } ?? String(localized: "Folder"))
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.text).lineLimit(1)
                if let p = state.selectedDirPath {
                    Text(verbatim: p).font(.system(size: 10)).foregroundStyle(Pal.overlay)
                        .lineLimit(1).truncationMode(.head)
                }
            }
            Spacer(minLength: 4)
            if state.selectedDirNode != nil {
                Text(verbatim: "\(count)").font(.system(size: 10)).foregroundStyle(Pal.overlay)
            }
            Image(lucideSymbol: expanded ? "chevron.down" : "chevron.up")
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(Pal.overlay)
                .frame(width: 22, height: 22)
        }
        .padding(.horizontal, 10).frame(height: Self.headerHeight)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)                 // Click anywhere on the header to toggle expansion.
        .pointerCursor()
        .help(expanded ? String(localized: "Hide File List") : String(localized: "Show File List"))
        .overlay(alignment: .bottom) {
            if expanded { Rectangle().fill(Pal.fill(0.08)).frame(height: 1) }
        }
    }

    private func placeholder(_ text: String) -> some View {
        VStack { Spacer(); Text(text).font(.system(size: 11)).foregroundStyle(Pal.overlay); Spacer() }
            .frame(maxWidth: .infinity)
    }
}

private struct FolderFileRow: View {
    let node: FileTreeNode
    let favorite: Bool
    let selected: String?
    let host: Host
    let model: AppModel
    let tree: FileTreeState
    @State private var hover = false
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        let file = node.file
        Button {
            model.openFile(file, host: host)
        } label: {
            HStack(spacing: 6) {
                FileTypeIcon(file: file, size: 12).frame(width: 16)
                Text(file.name).font(.system(size: 12)).foregroundStyle(Pal.text)
                    .lineLimit(1).truncationMode(.middle)
                if favorite { Image(lucideSymbol: "star.fill").font(.system(size: 8)).foregroundStyle(Pal.yellow).help(String(localized: "In Favorites")) }
                Spacer(minLength: 4)
                Text(humanSize(file.size)).font(.system(size: 10)).foregroundStyle(Pal.overlay)
            }
            .padding(.vertical, 4).padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected == file.path ? Pal.fill(0.11) : (hover ? Pal.fill(0.055) : Color.clear),
                        in: RoundedRectangle(cornerRadius: 9))
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor()
        .onHover { hover = $0 }
        .help(file.path)
        .contextMenu {
            Button { model.openHostTerminal(host, at: file.isDir ? file.path : FileTreeState.parentPath(file.path)) } label: {
                Label("Open Terminal Here", lucideSymbol: "terminal")
            }
            Button { model.copyRemotePath(file.path) } label: { Label("Copy Path", lucideSymbol: "doc.on.doc") }
            Divider()
            fileOpsMenuItems(file: file, host: host, model: model, target: tree,
                             onRefresh: { model.fileMenuRefresh(file, host: host, tree: tree) })
        }
    }
}

/// Nonrecursive row rendering plain values only.
private struct FlatRow: View {
    let item: FlatNode
    let favorite: Bool
    let selected: String?
    let host: Host
    let model: AppModel
    let tree: FileTreeState
    let onTap: () -> Void
    let onOpenFile: (RemoteFile) -> Void
    @State private var hover = false
    // Observe theme changes so Pal colors refresh immediately, as with FileRow.
    @ObservedObject private var theme = ThemeManager.shared

    /// Estimate truncation and show tooltips only when needed.
    /// Use character count/depth without expensive NSString measurement or observing sidebar width.
    /// Width is separate from AppModel; per-row drag/scroll measurement wastes CPU. Assume roughly 224px/30 characters.
    /// Include indentation depth because narrow sidebars reduce available characters.
    private var nameTruncated: Bool {
        item.node.file.name.count + item.depth * 2 > 30
    }

    var body: some View {
        let node = item.node
        Button {
            if node.file.isDir { onTap() } else { onOpenFile(node.file) }
        } label: {
            HStack(spacing: 4) {
                if node.file.isDir {
                    Image(lucideSymbol: node.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Pal.overlay)
                        .frame(width: 12)
                } else {
                    Spacer().frame(width: 12)
                }
                FileTypeIcon(file: node.file, size: 12)
                    .frame(width: 16)
                Text(node.file.name)
                    .font(.system(size: 12)).foregroundStyle(Pal.text)
                    .lineLimit(1).truncationMode(.middle)
                if favorite { Image(lucideSymbol: "star.fill").font(.system(size: 8)).foregroundStyle(Pal.yellow).help(String(localized: "In Favorites")) }
                Spacer(minLength: 0)
                if node.isLoading {
                    ProgressView().controlSize(.mini).scaleEffect(0.6)
                }
            }
            .padding(.vertical, 4)
            .padding(.leading, CGFloat(item.depth) * 12 + 10)
            .padding(.trailing, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected == node.file.path ? Pal.fill(0.11) : (hover ? Pal.fill(0.055) : Color.clear),
                        in: RoundedRectangle(cornerRadius: 9))
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hover = $0 }
        .contextMenu {
            Button {
                model.openHostTerminal(host, at: terminalDirectory)
            } label: {
                Label("Open Terminal Here", lucideSymbol: "terminal")
            }
            Button {
                model.copyRemotePath(node.file.path)
            } label: {
                Label("Copy Path", lucideSymbol: "doc.on.doc")
            }
            Divider()
            fileOpsMenuItems(file: node.file, host: host, model: model, target: tree,
                             onRefresh: { model.fileMenuRefresh(node.file, host: host, tree: tree) })
        }
        .tooltip(node.file.name, when: nameTruncated)
    }

    private var terminalDirectory: String {
        item.node.file.isDir ? item.node.file.path : FileTreeState.parentPath(item.node.file.path)
    }
}

import AppKit
import SwiftUI

/// VS Code-style workspace: current-server file/editor/overview/RDP above, its terminals in a lower panel,
/// resizable and hideable with Command-J. Terminal-only servers fill the workspace.
struct Workspace: View {
    // Hold model as plain let to call methods without subscribing to unrelated AppModel @Published updates.
    let model: AppModel
    @ObservedObject var tabs: TabsModel
    let layout: LayoutModel   // Only TerminalPanelSplit observes height/visibility, so dragging does not recompute the whole workspace.
    @ObservedObject private var theme = ThemeManager.shared
    // Freeze inactive-editor size after first layout. Only the active editor reflows on resize; hidden editors avoid TextKit layout work.
    @State private var frozenEditorSize: CGSize = .zero

    var body: some View {
        ZStack {
            Pal.base
            VStack(spacing: 0) {
                if let group = subTabGroup {
                    SubTabRow(model: model, tabs: tabs, group: group)
                }
                content
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Show child-tab rows when a server has nonterminal files/editor/overview tabs.
    private var subTabGroup: TabGroup? {
        guard let key = tabs.activeGroupKey else { return nil }
        guard let group = TabGroup.make(from: tabs.tabs).first(where: { $0.id == key }) else { return nil }
        let main = group.tabs.filter { $0.kind != .terminal }
        // Preconnection overview-only servers need no child row; the server tab identifies them before terminal/files appear.
        if main.isEmpty || (main.count == 1 && main[0].kind == .overview && group.tabs.count == 1) { return nil }
        return group
    }

    @ViewBuilder
    private var content: some View {
        if tabs.tabs.isEmpty {
            WelcomeView(model: model)
        } else {
            let key = tabs.activeGroupKey ?? ""
            let main = tabs.mainTab(inGroup: key)
            let term = tabs.terminalTab(inGroup: key)
            TerminalPanelSplit(layout: layout, hasMain: main != nil, hasTerminal: term != nil,
                               canOpenTerminal: term != nil || model.host(main?.hostId)?.ssh != nil,
                               onShowTerminal: {
                layout.terminalPanelVisible = true
                if let term {
                    model.selectTab(term.id)
                } else {
                    model.openTerminal(inGroup: key)
                }
            }) {
                mainArea(main)
            } panel: {
                if let term {
                    TerminalPanel(model: model, tabs: tabs, layout: layout, groupKey: key,
                                  current: term, canHide: main != nil) {
                        terminalView(term)
                    }
                }
            }
            .onChange(of: tabs.activeTabId) { id in
                // Selecting/opening a terminal automatically reveals its panel if hidden.
                if let id, tabs.tabs.first(where: { $0.id == id })?.kind == .terminal, !layout.terminalPanelVisible {
                    layout.terminalPanelVisible = true
                }
                model.focusActiveTab()
            }
            .onAppear {
                model.focusActiveTab()
                ClickFocusMonitor.install(model)
            }
        }
    }

    /// Keep editors alive across tab switches to preserve undo state; render only the current view for other tab types.
    private func mainArea(_ main: TabItem?) -> some View {
        // Hybrid rendering strategy:
        // Keep editor tabs mounted and toggle opacity without detaching. Editors have nested NSHostingView/SourceEditor layers;
        // detach/reattach would make SwiftUI recreate inner controllers, losing undo history and causing layout churn.
        // Render only current file/overview/RDP tabs. The bottom terminal panel likewise renders only its selected terminal;
        // the model retains terminal views, so detach/attach neither recreates them nor interrupts background activity.
        // GeometryReader supplies live dimensions to the active editor; hidden editors remain at frozenEditorSize without resize layout.
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                ForEach(tabs.tabs.filter { $0.kind == .editor }, id: \.id) { tab in
                    let isActive = tab.id == main?.id
                    tabView(tab)
                        .frame(width: isActive ? geo.size.width : max(1, frozenEditorSize.width),
                               height: isActive ? geo.size.height : max(1, frozenEditorSize.height))
                        .opacity(isActive ? 1 : 0)
                        .allowsHitTesting(isActive)
                        .zIndex(isActive ? 1 : 0)
                        .accessibilityHidden(!isActive)
                }
                if let main, main.kind != .editor {
                    tabView(main)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .zIndex(2)
                }
            }
            // Clamp to current geometry so a larger hidden frozen editor cannot expand the ZStack when the window shrinks; clip excess.
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
            // The main area can temporarily be zero-height on terminal-only servers; never freeze that as a hidden editor size.
            .onAppear { if frozenEditorSize == .zero, geo.size.height > 80 { frozenEditorSize = geo.size } }
            .onChange(of: geo.size) { s in if frozenEditorSize == .zero, s.height > 80 { frozenEditorSize = s } }
        }
    }

    /// One bottom-panel terminal, including quick toolbar and reconnect overlay.
    private func terminalView(_ tab: TabItem) -> some View {
        let terminal = model.terminalView(for: tab.id)   // Create the terminal first, which also creates its SSH conn.
        return VStack(spacing: 0) {
            // Show quick toolbar above SSH terminals only; local terminals have no conn.
            if let conn = model.terminalConn(for: tab.id), let host = model.host(tab.hostId) {
                TerminalToolbar(model: model, conn: conn, tabId: tab.id, host: host)
            }
            TerminalDropArea(terminal: terminal,
                             isActive: tab.id == tabs.activeTabId,
                             model: model, tabId: tab.id,
                             canUpload: model.host(tab.hostId)?.ssh != nil)
                .overlay {
                    if let conn = model.terminalConn(for: tab.id) {
                        TerminalReconnectOverlay(conn: conn) { model.manualReconnectTerminal(tab.id) }
                    }
                }
                .padding(10)
        }
        .id(tab.id)
    }

    @ViewBuilder
    private func tabView(_ tab: TabItem) -> some View {
        Group {
            switch tab.kind {
            case .terminal:
                terminalView(tab)
            case .overview:
                if let host = model.host(tab.hostId) {
                    HostOverview(host: host, model: model)
                }
            case .files:
                if let host = model.host(tab.hostId) {
                    FileBrowser(state: model.browserState(for: tab.id, host: host),
                                host: host, model: model,
                                onOpenFile: { model.openFile($0, host: host) })
                } else {
                    Text("No Hosts").font(.system(size: 13)).foregroundStyle(Pal.overlay)
                }
            case .editor:
                if let st = model.editorState(for: tab.id) {
                    FileViewerView(state: st, model: model, tabId: tab.id)
                } else {
                    Text("Couldn't Open File").font(.system(size: 13)).foregroundStyle(Pal.overlay)
                }
            case .rdp:
                if let host = model.host(tab.hostId) {
                    RDPSessionView(session: model.rdpSession(for: tab.id, host: host))
                } else {
                    Text("No Hosts").font(.system(size: 13)).foregroundStyle(Pal.overlay)
                }
            case .processes:
                if let s = model.processSession(for: tab.id) {
                    ProcessesView(session: s, model: model)
                } else {
                    Text("Couldn't Open File").font(.system(size: 13)).foregroundStyle(Pal.overlay)
                }
            case .script:
                if let s = model.scriptSession(for: tab.id) {
                    ScriptView(model: model, tabs: tabs, session: s)
                } else {
                    Text("Couldn't Open File").font(.system(size: 13)).foregroundStyle(Pal.overlay)
                }
            case .portForwards:
                PortForwardView(model: model)
            case .keyManager:
                SSHKeyManagerView(model: model.sshKeyManagerModel)
            case .netTools:
                if let s = model.netToolsSession(for: tab.id) {
                    NetToolsView(model: model, f: s)
                } else {
                    Text("Couldn't Open File").font(.system(size: 13)).foregroundStyle(Pal.overlay)
                }
            case .services:
                if let s = model.serviceSession(for: tab.id) {
                    ServicesView(session: s, model: model)
                } else {
                    Text("Couldn't Open File").font(.system(size: 13)).foregroundStyle(Pal.overlay)
                }
            case .web:
                if let s = model.webSession(for: tab.id) {
                    WebTabView(session: s)
                } else {
                    Text("Couldn't Open File").font(.system(size: 13)).foregroundStyle(Pal.overlay)
                }
            case .docker:
                if let s = model.dockerSession(for: tab.id) {
                    DockerView(session: s, model: model)
                } else {
                    Text("Couldn't Open File").font(.system(size: 13)).foregroundStyle(Pal.overlay)
                }
            case .site:
                if let s = model.siteSession(for: tab.id) {
                    SiteBrowserView(session: s)
                } else {
                    Text("Couldn't Open File").font(.system(size: 13)).foregroundStyle(Pal.overlay)
                }
            case .aiChat:
                if let host = model.host(tab.hostId) {
                    AIChatPanelView(model: model, host: host)
                } else {
                    Text("No Hosts").font(.system(size: 13)).foregroundStyle(Pal.overlay)
                }
            case .diskUsage:
                if let s = model.diskUsageSession(for: tab.id) {
                    DiskUsageView(session: s, model: model)
                } else {
                    Text("Couldn't Open File").font(.system(size: 13)).foregroundStyle(Pal.overlay)
                }
            case .tail:
                if let s = model.tailSession(for: tab.id) {
                    TailView(session: s)
                } else {
                    Text("Couldn't Open File").font(.system(size: 13)).foregroundStyle(Pal.overlay)
                }
            }
        }
        .id(tab.id)
    }
}

/// Only the main/terminal vertical split observes LayoutModel height/visibility, avoiding main-content recomputation while dragging.
struct TerminalPanelSplit<Main: View, Panel: View>: View {
    @ObservedObject var layout: LayoutModel
    let hasMain: Bool
    let hasTerminal: Bool
    let canOpenTerminal: Bool
    let onShowTerminal: () -> Void
    @ViewBuilder var main: Main
    @ViewBuilder var panel: Panel
    @State private var dragStart: CGFloat?

    private static var minPanel: CGFloat { 120 }
    private static var minMain: CGFloat { 120 }
    private static var dividerHeight: CGFloat { 5 }
    private static var collapsedBarHeight: CGFloat { 30 }

    var body: some View {
        GeometryReader { geo in
            let total = geo.size.height
            // Without main-area tabs, terminals fill the workspace; otherwise split according to panel visibility/height.
            let showPanel = hasTerminal && (layout.terminalPanelVisible || !hasMain)
            let showHandle = hasMain && !showPanel && canOpenTerminal
            let panelH: CGFloat = !hasMain ? total
                : min(max(layout.terminalPanelHeight, Self.minPanel), max(Self.minPanel, total - Self.minMain))
            let mainH: CGFloat = !hasMain ? 0 : (showPanel ? max(0, total - panelH - Self.dividerHeight)
                                                     : max(0, total - (showHandle ? Self.collapsedBarHeight : 0)))
            VStack(spacing: 0) {
                // Keep the main area mounted at zero height/opacity to preserve editors when selecting a terminal-only server.
                main
                    .frame(height: mainH)
                    .opacity(hasMain ? 1 : 0)
                    .allowsHitTesting(hasMain)
                if showPanel {
                    if hasMain { divider(total: total) }
                    panel.frame(height: hasMain ? panelH : total)
                } else if showHandle {
                    Button(action: onShowTerminal) {
                        HStack(spacing: 7) {
                            Image(lucideSymbol: "terminal")
                                .font(.system(size: 11))
                            Text("Terminal")
                                .font(.system(size: 11, weight: .medium))
                            Image(lucideSymbol: "chevron.up")
                                .font(.system(size: 9))
                            Spacer()
                        }
                        .foregroundStyle(Pal.overlay)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity)
                        .frame(height: Self.collapsedBarHeight)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .help(String(localized: "Toggle Terminal Panel (⌘J)"))
                    .background(Pal.mantle)
                    .overlay(alignment: .top) {
                        Rectangle().fill(Pal.fill(0.10)).frame(height: 1)
                    }
                }
            }
        }
    }

    /// Drag upward to increase panel height.
    private func divider(total: CGFloat) -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: Self.dividerHeight)
            .overlay(Rectangle().fill(Pal.fill(0.10)).frame(height: 1))
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { v in
                        let start = dragStart ?? layout.terminalPanelHeight
                        if dragStart == nil { dragStart = start }
                        let h = start - v.translation.height
                        layout.terminalPanelHeight = min(max(h, Self.minPanel), max(Self.minPanel, total - Self.minMain))
                    }
                    .onEnded { _ in dragStart = nil }
            )
    }
}

/// Bottom terminal panel: this server's terminal tabs on the left, New/Hide actions on the right.
struct TerminalPanel<Content: View>: View {
    let model: AppModel
    @ObservedObject var tabs: TabsModel
    let layout: LayoutModel
    let groupKey: String
    let current: TabItem
    let canHide: Bool          // Allow hiding only if a main area exists; otherwise the workspace would be empty.
    @ViewBuilder var content: Content

    var body: some View {
        let groupTabs = tabs.tabs.filter { $0.groupKey == groupKey }
        let group = TabGroup(id: groupKey, hostId: current.hostId, tabs: groupTabs)
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Text("TERMINAL")
                    .font(.system(size: 10, weight: .semibold)).tracking(0.6)
                    .foregroundStyle(Pal.overlay)
                    .padding(.trailing, 2)
                HostNamePill(model: model, hostId: current.hostId)
                    .padding(.trailing, 4)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(groupTabs.filter { $0.kind == .terminal }) { tab in
                            TabChip(tab: tab, model: model, tabs: tabs,
                                    displayTitle: group.subTitle(for: tab, host: model.host(tab.hostId)),
                                    highlighted: tab.id == current.id)
                        }
                    }
                }
                Spacer(minLength: 4)
                panelButton("plus", help: String(localized: "New Terminal")) {
                    model.openTerminal(inGroup: groupKey)
                }
                if canHide {
                    panelButton("chevron.down", help: String(localized: "Hide Terminal Panel (⌘J)")) {
                        layout.terminalPanelVisible = false
                        if let main = tabs.mainTab(inGroup: groupKey) { model.selectTab(main.id) }
                    }
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            content
        }
        .background(Pal.base)
    }

    private func panelButton(_ symbol: String, help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(lucideSymbol: symbol).font(.system(size: 11, weight: .medium))
                .foregroundStyle(Pal.overlay)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor().help(help)
    }
}

/// File-tree/favorites/recent tabs each use full panel height.
enum FilePanelTab: String, CaseIterable {
    case files, favorites, recent, snippets

    var symbol: String {
        switch self {
        case .files: return "folder"
        case .favorites: return "star"
        case .recent: return "clock"
        case .snippets: return "chevron.left.forwardslash.chevron.right"
        }
    }

    var title: String {
        switch self {
        case .files: return String(localized: "Files")
        case .favorites: return String(localized: "Favorites")
        case .recent: return String(localized: "Recent")
        case .snippets: return String(localized: "Scripts")
        }
    }
}

/// Right file panel combines cwd-following remote tree, favorites, and recent tabs.
/// Resize handle/header/server name/refresh/hide/tabs/content appear only for active SSH servers.
struct FilePanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var tabs: TabsModel
    @ObservedObject var layout: LayoutModel
    @ObservedObject private var theme = ThemeManager.shared
    @AppStorage("filePanelTab") private var tabRaw = FilePanelTab.files.rawValue
    @ObservedObject private var settings = AppSettings.shared

    private var tab: FilePanelTab { FilePanelTab(rawValue: tabRaw) ?? .files }

    var body: some View {
        if model.filePanelVisible {
            if let tree = model.activeFileTree {
                panel {
                    header(tree.state, tree.host)
                    tabStrip(tree.host, tabs: FilePanelTab.allCases)
                    switch tab {
                    case .files:
                        FilesTabContent(model: model, host: tree.host, tree: tree.state, treeId: tree.id, layout: layout)
                    case .favorites:
                        FavoritesList(model: model, host: tree.host) {
                            // Switch to Files and reveal opened folders.
                            tabRaw = FilePanelTab.files.rawValue
                            return tree.state
                        }
                    case .recent:
                        RecentFilesList(model: model, host: tree.host)
                    case .snippets:
                        SnippetsPanel(model: model, tabs: tabs)
                    }
                }
            }
        }
    }

    private func panel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 0) {
            FilePanelDivider(layout: layout)
            VStack(spacing: 0) { content() }
                .frame(width: layout.filePanelWidth)
                .background(Pal.base)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private func header(_ state: FileTreeState, _ host: Host) -> some View {
        HStack(spacing: 4) {
            HostNamePill(model: model, hostId: host.id)
            Spacer(minLength: 4)
            if tab == .files {
                headerButton(layout.filePanelListVisible ? "rectangle.bottomthird.inset.filled" : "rectangle",
                             help: layout.filePanelListVisible ? String(localized: "Hide File List") : String(localized: "Show File List")) {
                    layout.filePanelListVisible.toggle()
                }
                followToggle
                headerButton("arrow.clockwise", help: String(localized: "Refresh")) { state.reload() }
            }
            headerButton("xmark", help: String(localized: "Hide File Panel (⌥⌘B)")) { model.filePanelVisible = false }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
    }

    /// Only selected tabs show icon/name/count; others use icons to fit narrow panels.
    private func tabStrip(_ host: Host, tabs available: [FilePanelTab]) -> some View {
        HStack(spacing: 2) {
            ForEach(available, id: \.self) { t in
                let selected = tab == t
                let count = t == .favorites ? (model.favorites[host.id]?.count ?? 0)
                          : t == .recent ? (model.recentFiles[host.id]?.count ?? 0) : 0
                Button { tabRaw = t.rawValue } label: {
                    HStack(spacing: 4) {
                        Image(lucideSymbol: selected && t == .favorites ? "star.fill" : t.symbol)
                            .font(.system(size: 11))
                            .foregroundStyle(selected && t == .favorites ? Pal.yellow : (selected ? Pal.text : Pal.overlay))
                        if selected {
                            Text(t.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Pal.text)
                                .lineLimit(1)
                            if count > 0 {
                                Text(verbatim: "\(count)").font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(Pal.overlay)
                                    .padding(.horizontal, 4).padding(.vertical, 1)
                                    .background(Pal.fill(0.08), in: Capsule())
                            }
                        }
                    }
                    .frame(maxWidth: selected ? .infinity : 34).padding(.vertical, 5)
                    .background(selected ? Pal.fill(0.09) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointerCursor().help(t.title)
            }
        }
        .padding(.horizontal, 8).padding(.bottom, 6)
        .overlay(alignment: .bottom) { Rectangle().fill(Pal.fill(0.08)).frame(height: 1) }
    }

    /// Toggle following terminal cd; enabling immediately reveals current cwd.
    private var followToggle: some View {
        let on = settings.fileTreeFollowsTerminal
        return Button {
            settings.fileTreeFollowsTerminal.toggle()
            if settings.fileTreeFollowsTerminal { model.syncFileTreeToTerminal() }
        } label: {
            Image(lucideSymbol: on ? "location.fill" : "location").font(.system(size: 11, weight: .medium))
                .foregroundStyle(on ? Pal.tint : Pal.overlay)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor()
        .help(on ? String(localized: "Following the terminal's folder — click to stop")
                 : String(localized: "Not following the terminal — click to follow its folder"))
    }

    private func headerButton(_ symbol: String, help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(lucideSymbol: symbol).font(.system(size: 11, weight: .medium))
                .foregroundStyle(Pal.overlay)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor().help(help)
    }
}

/// Files tab splits tree above and optional resizable direct-file list below.
struct FilesTabContent: View {
    let model: AppModel
    let host: Host
    let tree: FileTreeState
    let treeId: String
    @ObservedObject var layout: LayoutModel
    @State private var dragStart: CGFloat?

    private static let minList: CGFloat = 90
    private static let minTree: CGFloat = 110

    var body: some View {
        GeometryReader { geo in
            let visible = layout.filePanelListVisible
            let listH = min(max(layout.filePanelListHeight, Self.minList), max(Self.minList, geo.size.height - Self.minTree))
            VStack(spacing: 0) {
                SidebarFileTree(state: tree, host: host, model: model)
                    .id(treeId)
                if visible { divider(total: geo.size.height) }
                else { Rectangle().fill(Pal.fill(0.10)).frame(height: 1) }
                // Collapsed lists retain a clickable header for reopening.
                FolderFileList(state: tree, host: host, model: model, expanded: visible) {
                    layout.filePanelListVisible.toggle()
                }
                .frame(height: visible ? listH : FolderFileList.headerHeight)
            }
            .onReceive(NotificationCenter.default.publisher(for: .revealFolderFileList)) { _ in
                layout.filePanelListVisible = true   // Disk analysis also expands the folded folder list.
            }
        }
    }

    private func divider(total: CGFloat) -> some View {
        Rectangle().fill(Color.clear).frame(height: 5)
            .overlay(Rectangle().fill(Pal.fill(0.10)).frame(height: 1))
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { v in
                        let start = dragStart ?? layout.filePanelListHeight
                        if dragStart == nil { dragStart = start }
                        layout.filePanelListHeight = min(max(start - v.translation.height, Self.minList),
                                                         max(Self.minList, total - Self.minTree))
                    }
                    .onEnded { _ in dragStart = nil }
            )
    }
}

/// Favorites pin frequent paths/files for quick access after connection.
/// Folders reveal in tree; files open editors; hover offers terminal navigation/removal.
struct FavoritesList: View {
    @ObservedObject var model: AppModel
    let host: Host
    /// Switch to Files and return the tree for folder navigation.
    let showFilesTree: () -> FileTreeState
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        let items = model.favorites[host.id] ?? []
        if items.isEmpty {
            emptyState(symbol: "star",
                       text: String(localized: "Right-click a folder or file and choose Add to Favorites, or use the ★ in the terminal bar, to pin it here."))
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(items) { fav in
                        FavoriteRow(model: model, host: host, fav: fav, showFilesTree: showFilesTree)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

/// Recent Files returns to files opened on this server.
struct RecentFilesList: View {
    @ObservedObject var model: AppModel
    let host: Host
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        let items = model.recentFiles[host.id] ?? []
        if items.isEmpty {
            emptyState(symbol: "clock", text: String(localized: "Files you open on this server show up here."))
        } else {
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button { model.clearRecentFiles(hostId: host.id) } label: {
                        Text("Clear History").font(.system(size: 10)).foregroundStyle(Pal.overlay)
                            .padding(.horizontal, 10).padding(.vertical, 5).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).pointerCursor()
                }
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { item in RecentFileRow(model: model, host: host, item: item) }
                    }
                    .padding(.bottom, 4)
                }
            }
        }
    }
}

@ViewBuilder
private func emptyState(symbol: String, text: String) -> some View {
    VStack(spacing: 10) {
        Spacer()
        Image(lucideSymbol: symbol).font(.system(size: 22)).foregroundStyle(Pal.overlay)
        Text(text).font(.system(size: 11)).foregroundStyle(Pal.overlay)
            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 20)
        Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
}

private struct RecentFileRow: View {
    @ObservedObject var model: AppModel
    let host: Host
    let item: RecentFile
    @State private var hover = false

    private var file: RemoteFile {
        RemoteFile(name: item.name, path: item.path, kind: .file, size: 0, modified: nil)
    }

    var body: some View {
        let fav = model.isFavorite(item.path, hostId: host.id)
        HStack(spacing: 6) {
            FileTypeIcon(file: file, size: 11).frame(width: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(item.name).font(.system(size: 12)).foregroundStyle(Pal.text).lineLimit(1)
                Text((item.path as NSString).deletingLastPathComponent)
                    .font(.system(size: 10)).foregroundStyle(Pal.overlay)
                    .lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 0)
            if hover || fav {
                Button { model.toggleFavorite(path: item.path, isDir: false, hostId: host.id) } label: {
                    Image(lucideSymbol: fav ? "star.fill" : "star").font(.system(size: 10, weight: .medium))
                        .foregroundStyle(fav ? Pal.yellow : Pal.overlay)
                        .frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointerCursor()
                .help(fav ? String(localized: "Remove from Favorites") : String(localized: "Add to Favorites"))
            }
            if hover {
                Button { model.removeRecentFile(item.path, hostId: host.id) } label: {
                    Image(lucideSymbol: "xmark").font(.system(size: 10, weight: .medium)).foregroundStyle(Pal.overlay)
                        .frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointerCursor().help(String(localized: "Remove from History"))
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(hover ? Pal.fill(0.05) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { model.openFile(file, host: host) }
        .onHover { hover = $0 }
        .pointerCursor()
        .help(item.path)
        .contextMenu {
            Button { model.toggleFavorite(path: item.path, isDir: false, hostId: host.id) } label: {
                Label(fav ? "Remove from Favorites" : "Add to Favorites", lucideSymbol: fav ? "star.slash" : "star")
            }
            Button { model.copyRemotePath(item.path) } label: { Label("Copy File Path", lucideSymbol: "doc.on.doc") }
            Divider()
            Button(role: .destructive) { model.removeRecentFile(item.path, hostId: host.id) } label: {
                Label("Remove from History", lucideSymbol: "xmark")
            }
        }
    }
}

private struct FavoriteRow: View {
    @ObservedObject var model: AppModel
    let host: Host
    let fav: FavoritePath
    let showFilesTree: () -> FileTreeState
    @State private var hover = false

    var body: some View {
        HStack(spacing: 6) {
            Image(lucideSymbol: fav.isDir ? "folder.fill" : "doc.text")
                .font(.system(size: 11)).foregroundStyle(fav.isDir ? host.accent : Pal.subtext)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(fav.name).font(.system(size: 12)).foregroundStyle(Pal.text).lineLimit(1)
                Text(fav.path).font(.system(size: 10)).foregroundStyle(Pal.overlay)
                    .lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 0)
            if hover {
                if fav.isDir {
                    rowButton("terminal", help: String(localized: "Go Here in Terminal")) {
                        model.openHostTerminal(host, at: fav.path)
                    }
                }
                rowButton("xmark", help: String(localized: "Remove from Favorites")) {
                    model.removeFavorite(fav.id, hostId: host.id)
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(hover ? Pal.fill(0.05) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            model.openFavorite(fav, host: host, tree: fav.isDir ? showFilesTree() : nil)
        }
        .onHover { hover = $0 }
        .pointerCursor()
        .help(fav.path)
        .contextMenu {
            if fav.isDir {
                Button { model.openHostTerminal(host, at: fav.path) } label: {
                    Label("Go Here in Terminal", lucideSymbol: "terminal")
                }
            }
            Button { model.copyRemotePath(fav.path) } label: { Label("Copy File Path", lucideSymbol: "doc.on.doc") }
            Divider()
            Button(role: .destructive) { model.removeFavorite(fav.id, hostId: host.id) } label: {
                Label("Remove from Favorites", lucideSymbol: "star.slash")
            }
        }
    }

    private func rowButton(_ symbol: String, help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(lucideSymbol: symbol).font(.system(size: 10, weight: .medium)).foregroundStyle(Pal.overlay)
                .frame(width: 20, height: 20).contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor().help(help)
    }
}

/// File-panel divider moves only a guide while dragging, committing once on release to avoid terminal reflow.
struct FilePanelDivider: View {
    @ObservedObject var layout: LayoutModel
    @State private var dragStart: CGFloat?
    @State private var pending: CGFloat = 0

    private static let minWidth: CGFloat = 180
    private static let maxWidth: CGFloat = 640

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 6)
            .contentShape(Rectangle())
            .overlay {
                if let start = dragStart {
                    Rectangle().fill(Pal.tint.opacity(0.55)).frame(width: 2)
                        .offset(x: start - pending)
                        .allowsHitTesting(false)
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active: NSCursor.resizeLeftRight.set()
                case .ended: NSCursor.arrow.set()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { v in
                        if dragStart == nil { dragStart = layout.filePanelWidth }
                        pending = min(max((dragStart ?? 0) - v.translation.width, Self.minWidth), Self.maxWidth)
                        NSCursor.resizeLeftRight.set()
                    }
                    .onEnded { _ in
                        if dragStart != nil { layout.filePanelWidth = pending }
                        dragStart = nil
                    }
            )
    }
}

/// Small server-colored terminal-header badge, omitted for local terminals.
struct HostNamePill: View {
    @ObservedObject var model: AppModel
    let hostId: String?

    var body: some View {
        if let host = model.host(hostId) {
            HStack(spacing: 5) {
                Circle().fill(host.accent).frame(width: 6, height: 6)
                Text(host.name).font(.system(size: 10, weight: .semibold)).lineLimit(1)
                    .foregroundStyle(host.accent)
            }
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(host.accent.opacity(0.14), in: Capsule())
        }
    }
}

/// Global mouse-down observer activates the clicked terminal/editor tab, switching focus between simultaneously visible main/terminal areas.
@MainActor
enum ClickFocusMonitor {
    private static var installed = false
    static func install(_ model: AppModel) {
        guard !installed else { return }
        installed = true
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak model] event in
            if let model, let content = event.window?.contentView {
                let p = content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
                if let hit = content.hitTest(p) {
                    MainActor.assumeIsolated { model.noteClick(in: hit) }
                }
            }
            return event
        }
    }
}

/// Welcome shows getting-started/recent-host columns, feature cards, and shortcuts, stacking when narrow.
struct WelcomeView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var theme = ThemeManager.shared

    private struct CapabilityGroup: Identifiable {
        let id: String
        let symbol: String
        let color: Color
        let title: String
        let summary: String
        let highlights: [String]
    }

    private struct FeaturedTool: Identifiable {
        let id: String
        let symbol: String
        let color: Color
        let title: String
        let detail: String
    }

    private static func tint(_ i: Int) -> Color {
        HostPalette.color(hex: HostPalette.presets[i % HostPalette.presets.count]) ?? Pal.mauve
    }

    private let featuredTools: [FeaturedTool] = [
        FeaturedTool(id: "tail", symbol: "text.append", color: tint(1),
                     title: String(localized: "Live Log Tail"),
                     detail: String(localized: "Follow a log file as it grows, with filter, pause and auto-scroll. Right-click any text file.")),
        FeaturedTool(id: "disk", symbol: "chart.bar.xaxis", color: tint(2),
                     title: String(localized: "Disk Usage Analyzer"),
                     detail: String(localized: "See which folders eat your disk and drill down level by level. Right-click a folder.")),
        FeaturedTool(id: "ai", symbol: "sparkles", color: tint(5),
                     title: String(localized: "AI Assistant"),
                     detail: String(localized: "Ask Codex or Claude CLI about a server and send the suggested commands straight to its terminal.")),
        FeaturedTool(id: "snippets", symbol: "text.badge.plus", color: tint(6),
                     title: String(localized: "Command Scripts"),
                     detail: String(localized: "Save frequent commands with {{variables}}, then run or insert them into any terminal in one click.")),
    ]

    private let capabilityGroups: [CapabilityGroup] = [
        CapabilityGroup(id: "connect", symbol: "server.rack", color: tint(0),
                        title: String(localized: "Connect & Control"),
                        summary: String(localized: "Reach your servers and desktops from one workspace."),
                        highlights: [String(localized: "SSH Terminal & Files"), String(localized: "Remote Desktop"),
                                     String(localized: "Port Forwarding")]
                            + (AppEnv.localTerminalEnabled ? [String(localized: "This Mac as a Host")] : [])),
        CapabilityGroup(id: "files", symbol: "folder", color: tint(4),
                        title: String(localized: "Files & Editing"),
                        summary: String(localized: "Move, inspect and edit remote files without leaving the app."),
                        highlights: [String(localized: "Remote Code Editor"), String(localized: "Resumable Transfers"),
                                     String(localized: "Extract Archives"), String(localized: "Image Preview"),
                                     String(localized: "Open With & Share")]),
        CapabilityGroup(id: "monitor", symbol: "chart.xyaxis.line", color: tint(3),
                        title: String(localized: "Monitor & Diagnose"),
                        summary: String(localized: "See health, latency and changes before they become problems."),
                        highlights: [String(localized: "Host Monitoring"), String(localized: "Load Alerts"),
                                     String(localized: "Ping List")]),
        CapabilityGroup(id: "tools", symbol: "square.grid.2x2", color: tint(6),
                        title: String(localized: "Work Smarter"),
                        summary: String(localized: "Keep commands, context and terminals close at hand."),
                        highlights: [String(localized: "Command Toolbox"), String(localized: "Terminal Panel"),
                                     String(localized: "Git Status Bar")]),
        CapabilityGroup(id: "organize", symbol: "rectangle.grid.1x2", color: tint(2),
                        title: String(localized: "Organize Workspace"),
                        summary: String(localized: "Find your places and make the workspace your own."),
                        highlights: [String(localized: "Favorites & Recent Files"), String(localized: "Server Colors"),
                                     String(localized: "Import from iTerm2"), String(localized: "7 Languages")]),
        CapabilityGroup(id: "safety", symbol: "lock.shield", color: tint(7),
                        title: String(localized: "Security & Maintenance"),
                        summary: String(localized: "Manage access and keep sensitive details under control."),
                        highlights: [String(localized: "SSH Key Manager"), String(localized: "Edit as Root (sudo)"),
                                     String(localized: "Privacy Mode"), String(localized: "Auto Update")]),
    ]

    /// Up to six remote hosts, recently used first then unused hosts in list order.
    private var recentHosts: [(host: Host, last: Date?)] {
        let all = model.hosts.filter { !$0.isLocal }
        let used = all.compactMap { h in model.hostLastUsed[h.id].map { (h, $0) } }.sorted { $0.1 > $1.1 }
        let unused = all.filter { model.hostLastUsed[$0.id] == nil }
        return (used.map { ($0.0, Optional($0.1)) } + unused.map { ($0, nil) }).prefix(6).map { (host: $0.0, last: $0.1) }
    }

    private var hasHistory: Bool { model.hosts.contains { !$0.isLocal && model.hostLastUsed[$0.id] != nil } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                header
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 24) {
                        startColumn.frame(minWidth: 280, maxWidth: .infinity, alignment: .leading)
                        if !recentHosts.isEmpty { hostsColumn.frame(minWidth: 280, maxWidth: .infinity, alignment: .leading) }
                    }
                    VStack(alignment: .leading, spacing: 30) {
                        startColumn
                        if !recentHosts.isEmpty { hostsColumn }
                    }
                }
                featureSection
                shortcuts
            }
            .frame(maxWidth: 900, alignment: .leading)
            .padding(.horizontal, 36).padding(.vertical, 36)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 16) {
            Image("ServerDockBrandMark", bundle: .app)
                .resizable().interpolation(.high)
                .frame(width: 56, height: 56)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text("ServerDock").font(.system(size: 25, weight: .semibold)).foregroundStyle(Pal.textBright)
                Text("Your servers, one workbench.").font(.system(size: 13)).foregroundStyle(Pal.subtext)
                HStack(spacing: 8) {
                    Text(AppInfo.versionLine).font(.system(size: 11)).foregroundStyle(Pal.overlay)
                    Text(verbatim: "·").foregroundStyle(Pal.overlay)
                    Button { UpdateController.shared.checkForUpdates() } label: {
                        Text("Check for Updates").font(.system(size: 11)).foregroundStyle(Pal.subtext)
                    }
                    .buttonStyle(.plain).pointerCursor()
                }
            }
            Spacer(minLength: 0)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Pal.fill(0.04), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Pal.fill(0.08), lineWidth: 1))
    }

    // MARK: Get started / recent hosts

    private var startColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(String(localized: "Start"))
            VStack(spacing: 2) {
                startRow("plus", String(localized: "Add Host"), String(localized: "Connect to a server over SSH")) {
                    model.showAddHost = true
                }
                if AppEnv.localTerminalEnabled {   // Hide local-terminal entry points in MAS sandbox builds.
                    startRow("terminal", String(localized: "Open Local Terminal"), String(localized: "Work directly on this Mac")) {
                        model.openLocalTerminal()
                    }
                }
                startRow("square.and.arrow.down", String(localized: "Import from iTerm2"),
                         String(localized: "Bring in your existing SSH profiles")) { model.presentImportITerm() }
                startRow("key", String(localized: "SSH Key Manager"), String(localized: "Manage the keys in ~/.ssh")) {
                    model.openKeyManager()
                }
                startRow("gearshape", String(localized: "Settings"), String(localized: "Theme, language, terminal and more")) {
                    model.showSettings = true
                }
            }
            .padding(8)
            .background(Pal.fill(0.035), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private var hostsColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(hasHistory ? String(localized: "Recent Hosts") : String(localized: "Your Hosts"))
            VStack(spacing: 2) {
                ForEach(recentHosts, id: \.host.id) { item in hostRow(item.host, last: item.last) }
            }
            .padding(8)
            .background(Pal.fill(0.035), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private func startRow(_ symbol: String, _ title: String, _ detail: String, action: @escaping () -> Void) -> some View {
        WelcomeRow(action: action) {
            Image(lucideSymbol: symbol).font(.system(size: 13, weight: .medium))
                .foregroundStyle(Pal.mauve)
                .frame(width: 32, height: 32)
                .background(Pal.mauve.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Pal.text)
                Text(detail).font(.system(size: 11)).foregroundStyle(Pal.overlay).lineLimit(1)
            }
        }
    }

    private func hostRow(_ host: Host, last: Date?) -> some View {
        WelcomeRow(action: { model.openHost(host) }) {
            Image(lucideSymbol: host.isRDP ? "display" : "server.rack").font(.system(size: 13))
                .foregroundStyle(host.accent)
                .frame(width: 32, height: 32)
                .background(host.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text(host.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Pal.text).lineLimit(1)
                Text(host.addr).font(.system(size: 11)).foregroundStyle(Pal.overlay).lineLimit(1)
                    .privacyBlur(model.privacyMode)
            }
            Spacer(minLength: 6)
            if let last {
                Text(Self.relative.localizedString(for: last, relativeTo: Date()))
                    .font(.system(size: 11)).foregroundStyle(Pal.overlay)
            }
        }
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    // MARK: Features

    private var featureSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle(String(localized: "What You Can Do"))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 330), spacing: 12, alignment: .top)], spacing: 12) {
                ForEach(featuredTools) { tool in featuredToolCard(tool) }
            }
            Text("More Capabilities")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(Pal.overlay)
                .padding(.top, 8)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 330), spacing: 14, alignment: .top)], spacing: 14) {
                ForEach(capabilityGroups) { group in capabilityCard(group) }
            }
        }
    }

    private func featuredToolCard(_ tool: FeaturedTool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(lucideSymbol: tool.symbol).font(.system(size: 16, weight: .medium))
                .foregroundStyle(tool.color)
                .frame(width: 36, height: 36)
                .background(tool.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 5) {
                Text(tool.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Pal.textBright)
                Text(tool.detail).font(.system(size: 11)).foregroundStyle(Pal.subtext)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(tool.color.opacity(0.055), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(tool.color.opacity(0.16), lineWidth: 1))
    }

    private func capabilityCard(_ group: CapabilityGroup) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(lucideSymbol: group.symbol).font(.system(size: 17, weight: .medium))
                    .foregroundStyle(group.color)
                    .frame(width: 38, height: 38)
                    .background(group.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Pal.textBright)
                    Text(group.summary).font(.system(size: 11)).foregroundStyle(Pal.subtext)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(group.highlights, id: \.self) { highlight in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(group.color).frame(width: 4, height: 4)
                        Text(highlight).font(.system(size: 11)).foregroundStyle(Pal.text)
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Pal.fill(0.04), in: RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).stroke(Pal.fill(0.07), lineWidth: 1))
    }

    private var shortcuts: some View {
        HStack(spacing: 20) {
            Text("Shortcuts").font(.system(size: 12, weight: .semibold)).foregroundStyle(Pal.overlay)
            shortcut("⌘J", String(localized: "Terminal"))
            shortcut("⌥⌘B", String(localized: "Files"))
            shortcut("⌘W", String(localized: "Close Tab"))
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(Pal.overlay)
            .padding(.bottom, 2)
    }

    private func shortcut(_ keys: String, _ label: String) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: keys).font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Pal.text)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Pal.fill(0.08), in: RoundedRectangle(cornerRadius: 4))
            Text(label).font(.system(size: 12)).foregroundStyle(Pal.subtext)
        }
    }
}

/// Welcome row button has no background until subtle hover highlighting.
private struct WelcomeRow<Content: View>: View {
    let action: () -> Void
    @ViewBuilder var content: Content
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                content
                Spacer(minLength: 4)
                Image(lucideSymbol: "chevron.right").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Pal.overlay).opacity(hover ? 1 : 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(hover ? Pal.fill(0.06) : Color.clear, in: RoundedRectangle(cornerRadius: 11))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor()
        .onHover { hover = $0 }
    }
}

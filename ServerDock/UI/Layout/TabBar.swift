import SwiftUI

/// Two-level tab bar: servers/local-terminal group above, current server's main-area file/editor/overview tabs below.
/// Terminals live in the workspace's bottom [[TerminalPanel]], with their own tab strip.
/// TabsModel remains a flat list; group only for presentation, ordered by each group's first tab.
struct TabBar: View {
    let model: AppModel
    @ObservedObject var tabs: TabsModel
    let layout: LayoutModel
    @ObservedObject private var theme = ThemeManager.shared
    @State private var groupFrames: [Int: CGRect] = [:]   // Server-chip layout frames indexed by group position.

    private var groups: [TabGroup] { TabGroup.make(from: tabs.tabs) }

    private var activeGroupKey: String? {
        tabs.tabs.first { $0.id == tabs.activeTabId }.map(TabGroup.key(for:))
    }

    var body: some View {
        let groups = self.groups
        let activeKey = activeGroupKey
        let activeIndex = groups.firstIndex { $0.id == activeKey }
        let activeGroupFrame = activeIndex.flatMap { groupFrames[$0] }
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 6) {
                TabStrip(
                    newKey: groups.count,
                    activeKey: activeIndex ?? 0,
                    activeMinX: activeGroupFrame?.minX ?? 0,
                    activeMaxX: activeGroupFrame?.maxX ?? 0
                ) {
                    HStack(spacing: 4) {
                        ForEach(Array(groups.enumerated()), id: \.element.id) { idx, group in
                            HostGroupChip(group: group, model: model, active: group.id == activeKey) {
                                selectGroup(group)
                            }
                            .background(GeometryReader { g in
                                Color.clear.preference(key: TabFramesKey.self,
                                                       value: [idx: g.frame(in: .named("hoststrip"))])
                            })
                        }
                    }
                    .coordinateSpace(name: "hoststrip")
                    .onPreferenceChange(TabFramesKey.self) { groupFrames = $0 }
                }
                TerminalPanelToggle(model: model, tabs: tabs, layout: layout)
                FilePanelToggle(model: model)
                WorkspaceGuideButton()
                if AppEnv.localTerminalEnabled {   // Hide local-terminal entry points in MAS sandbox builds.
                    Button {
                        model.openLocalTerminal()
                    } label: {
                        Image(lucideSymbol: "plus").font(.system(size: 13)).foregroundStyle(Pal.overlay)
                            .frame(width: 24, height: 34)
                            .offset(y: -5)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .help(String(localized: "Open Local Terminal"))
                }
            }
            .padding(.horizontal, 8)
            // Align workspace/sidebar tops at 46pt and vertically center tabs with traffic lights.
            .frame(height: 44)
            .offset(y: 5)
        }
        .frame(maxWidth: .infinity)
        .background(Pal.mantle)
    }

    /// Click a server to return to its most recent main-area tab, falling back to its terminal.
    private func selectGroup(_ group: TabGroup) {
        if let t = tabs.mainTab(inGroup: group.id) ?? tabs.terminalTab(inGroup: group.id) {
            model.selectTab(t.id)
        }
    }
}

/// Child tabs sit inside the content card using its background.
struct SubTabRow: View {
    let model: AppModel
    @ObservedObject var tabs: TabsModel
    let group: TabGroup
    @State private var frames: [Int: CGRect] = [:]

    /// Lower row: current-server child tabs and a right-side New menu for SSH hosts.
    var body: some View {
        let mainId = tabs.mainTab(inGroup: group.id)?.id
        let active = mainId.flatMap { frames[$0] }
        let mainTabs = group.tabs.filter { $0.kind != .terminal }
        return HStack(alignment: .center, spacing: 6) {
            TabStrip(
                newKey: mainTabs.count,
                activeKey: mainId ?? 0,
                activeMinX: active?.minX ?? 0,
                activeMaxX: active?.maxX ?? 0
            ) {
                HStack(spacing: 4) {
                    ForEach(mainTabs) { tab in
                        TabChip(tab: tab, model: model, tabs: tabs,
                                displayTitle: group.subTitle(for: tab, host: model.host(tab.hostId)),
                                highlighted: tab.id == mainId)
                            .background(GeometryReader { g in
                                Color.clear.preference(key: TabFramesKey.self,
                                                       value: [tab.id: g.frame(in: .named("tabstrip"))])
                            })
                    }
                }
                .coordinateSpace(name: "tabstrip")
                .onPreferenceChange(TabFramesKey.self) { frames = $0 }
            }
            if let host = model.host(group.hostId), !host.isRDP {
                #if DEBUG
                // Debug-only terminal/files/overview/AI menu; hide in Release.
                    Menu {
                        Text(verbatim: "🛠 DEBUG ONLY — developer test menu")   // Clearly label the menu as unavailable in Release.
                        Divider()
                        Button { model.openHostTerminal(host, forceNew: true) } label: { Label("New Terminal", lucideSymbol: "terminal") }
                        Button { model.openHostFiles(host) } label: { Label("Browse Files", lucideSymbol: "folder") }
                        Button { model.openHost(host) } label: { Label("Host Overview", lucideSymbol: "square.grid.2x2") }
                        if !host.isLocal {
                            Button { model.openHostAIChat(host) } label: { Label("AI Assistant", lucideSymbol: "bubble.left.and.bubble.right") }
                        }
                    } label: {
                        Image(lucideSymbol: "plus").font(.system(size: 12)).foregroundStyle(Pal.overlay)
                            .frame(width: 24, height: 26)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .pointerCursor()
                    .offset(y: -4)
                    .help(String(localized: "Open in This Server"))
                #endif
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 5)
        .padding(.leading, -4)
        .background(alignment: .bottom) {
            // Server-colored content separator.
            Rectangle().fill(model.host(group.hostId)?.accent.opacity(0.35) ?? Pal.fill(0.06)).frame(height: 1)
        }
    }
}

/// All tabs belonging to one server/local-terminal group.
struct TabGroup: Identifiable {
    let id: String
    let hostId: String?
    var tabs: [TabItem]

    static func key(for tab: TabItem) -> String { tab.groupKey }

    static func make(from tabs: [TabItem]) -> [TabGroup] {
        var order: [String] = []
        var byKey: [String: TabGroup] = [:]
        for t in tabs {
            let k = key(for: t)
            if byKey[k] == nil { order.append(k); byKey[k] = TabGroup(id: k, hostId: t.hostId, tabs: []) }
            byKey[k]?.tabs.append(t)
        }
        return order.compactMap { byKey[$0] }
    }

    /// Child titles omit the server name shown above: show kind, numbered terminals, editor filename, or a custom user title.
    func subTitle(for tab: TabItem, host: Host?) -> String {
        // Generated titles are the base name or base name (n), as in AppModel.uniqueTabTitle; preserve other titles as user renames.
        let base = host?.name ?? String(localized: "Terminal")
        let renamed = !(tab.title == base || (tab.title.hasPrefix(base + " (") && tab.title.hasSuffix(")")))
        switch tab.kind {
        case .editor:
            return tab.title
        case .terminal:
            if renamed { return tab.title }
            let terms = tabs.filter { $0.kind == .terminal }
            guard terms.count > 1, let n = terms.firstIndex(where: { $0.id == tab.id }) else { return String(localized: "Terminal") }
            return String(localized: "Terminal \(n + 1)")
        case .files:
            return renamed ? tab.title : String(localized: "Files")
        case .overview:
            return renamed ? tab.title : String(localized: "Overview")
        case .rdp:
            return renamed ? tab.title : String(localized: "Remote Desktop")
        case .aiChat:
            return renamed ? tab.title : String(localized: "AI Assistant")
        case .tail:
            return tab.title
        case .diskUsage:
            return renamed ? tab.title : String(localized: "Space Analyzer")
        case .site:
            return String(localized: "Files")
        case .docker:
            return "Docker"
        case .web:
            return tab.title
        case .services:
            return String(localized: "Services")
        case .processes:
            return String(localized: "Processes")
        case .netTools, .keyManager, .script, .portForwards:
            return tab.title
        }
    }
}

/// Server chip shows status/name/tab count; its context menu opens terminal/files/overview or closes all server tabs.
struct HostGroupChip: View {
    let group: TabGroup
    @ObservedObject var model: AppModel     // Observe online/offline host changes.
    let active: Bool
    let onSelect: () -> Void
    @State private var hover = false

    private var host: Host? { model.host(group.hostId) }
    /// Storage groups use protocol icons instead of server status dots.
    private var site: Site? { model.site(forTabKey: group.hostId) }

    private var isNetTools: Bool { group.hostId == AppModel.netToolsKey }
    private var isPortForwards: Bool { group.hostId == AppModel.portForwardsKey }
    private var isScripts: Bool { group.hostId == AppModel.scriptsKey }

    private var title: String {
        isPortForwards ? String(localized: "Port Forwarding") : isScripts ? String(localized: "Scripts") : isNetTools ? String(localized: "Tools") : (site?.name ?? host?.name ?? String(localized: "Local"))
    }

    private var statusColor: Color {
        switch host?.status {
        case .online: return Pal.green
        case .offline: return Pal.red
        default: return Pal.overlay
        }
    }

    private var dirtyCount: Int {
        group.tabs.filter { $0.kind == .editor && (model.editorState(for: $0.id)?.isDirty ?? false) }.count
    }

    var body: some View {
        HStack(spacing: 7) {
            if host != nil {
                Circle().fill(host?.status == .offline ? Pal.overlay : (host?.accent ?? statusColor)).frame(width: 7, height: 7)
            } else if isPortForwards {
                Image(lucideSymbol: "arrow.left.arrow.right").font(.system(size: 11))
                    .foregroundStyle(active ? Pal.mauve : Pal.overlay).frame(width: 12)
            } else if isScripts {
                Image(lucideSymbol: "chevron.left.forwardslash.chevron.right").font(.system(size: 11))
                    .foregroundStyle(active ? Pal.mauve : Pal.overlay).frame(width: 12)
            } else if isNetTools {
                Image(lucideSymbol: "wrench.and.screwdriver").font(.system(size: 11))
                    .foregroundStyle(active ? Pal.mauve : Pal.overlay).frame(width: 12)
            } else if let site {
                Image(lucideSymbol: site.kind.symbol).font(.system(size: 11))
                    .foregroundStyle(active ? Pal.mauve : Pal.overlay).frame(width: 12)
            } else {
                Image(lucideSymbol: "laptopcomputer").font(.system(size: 11))
                    .foregroundStyle(active ? Pal.text : Pal.overlay).frame(width: 12)
            }
            Text(title).font(.system(size: 12, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? Pal.text : Pal.subtext)
                .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            if group.tabs.count > 1 {
                Text(verbatim: "\(group.tabs.count)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Pal.overlay)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Pal.fill(0.08), in: Capsule())
            }
            if dirtyCount > 0 {
                Circle().fill(Pal.yellow).frame(width: 6, height: 6)
                    .help(String(localized: "Has unsaved files"))
            }
            Button {
                model.closeTabs(group.tabs.map(\.id))
            } label: {
                Image(lucideSymbol: "xmark").font(.system(size: 9))
                    .foregroundStyle(Pal.overlay)
                    .frame(width: 16, height: 16)
                    .background(hover ? Pal.fill(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .opacity(active || hover ? 1 : 0)
            .help(String(localized: "Close All Tabs of This Server"))
        }
        .padding(.leading, 10).padding(.trailing, 6).padding(.vertical, 5)
        .background(
            active ? (host?.accent.opacity(0.18) ?? Pal.fill(0.10)) : (hover ? Pal.fill(0.04) : Color.clear),
            in: RoundedRectangle(cornerRadius: 7)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hover = $0 }
        .pointerCursor()
        .contextMenu {
            if let host, !host.isRDP {
                Button { model.openHostTerminal(host, forceNew: true) } label: { Label("New Terminal", lucideSymbol: "terminal") }
                Button { model.openHostFiles(host) } label: { Label("Browse Files", lucideSymbol: "folder") }
                Button { model.openHost(host) } label: { Label("Host Overview", lucideSymbol: "square.grid.2x2") }
                if model.hasDocker(host) { Button { model.openDocker(host) } label: { Label(model.engineTitle(host), lucideSymbol: "shippingbox") } }
                if model.hasSystemd(host) { Button { model.openServices(host) } label: { Label("Services", lucideSymbol: "gearshape.2") } }
                if !host.isLocal {
                    Button { model.openHostAIChat(host) } label: { Label("AI Assistant", lucideSymbol: "bubble.left.and.bubble.right") }
                }
                Divider()
            }
            Button { model.closeTabs(group.tabs.map(\.id)) } label: {
                Label("Close All Tabs of This Server", lucideSymbol: "xmark.circle")
            }
            Button { model.closeTabs(model.tabs.filter { TabGroup.key(for: $0) != group.id }.map(\.id)) } label: {
                Label("Close Other Servers", lucideSymbol: "xmark.octagon")
            }
        }
    }
}

/// Collect chip frames in content coordinates to reveal neighbors when selecting edge tabs.
private struct TabFramesKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

struct TabChip: View {
    let tab: TabItem
    let model: AppModel
    @ObservedObject var tabs: TabsModel
    var displayTitle: String? = nil   // Grouped child rows show only kind/filename because the server name is already above.
    var highlighted: Bool? = nil      // Current main-area/terminal-panel tab; nil uses global activeTabId.
    @ObservedObject private var theme = ThemeManager.shared
    @State private var hover = false

    private var symbol: String {
        switch tab.kind {
        case .overview: return "square.grid.2x2"
        case .terminal: return "terminal"
        case .files: return "folder"
        case .editor: return "doc.text"
        case .rdp: return "display"
        case .aiChat: return "bubble.left.and.bubble.right"
        case .tail: return "text.append"
        case .diskUsage: return "chart.bar.xaxis"
        case .site: return "externaldrive.connected.to.line.below"
        case .docker: return "shippingbox"
        case .web: return "globe"
        case .services: return "gearshape.2"
        case .processes: return "list.bullet.rectangle"
        case .netTools: return "wrench.and.screwdriver"
        case .keyManager: return "key.viewfinder"
        case .script: return "chevron.left.forwardslash.chevron.right"
        case .portForwards: return "arrow.left.arrow.right"
        }
    }

    /// Overview tabs use a monochrome OS distribution logo; other tabs use feature icons.
    @ViewBuilder
    private func tabIcon(active: Bool) -> some View {
        let fg = active ? Pal.text : Pal.overlay
        if tab.kind == .overview, let host = model.host(tab.hostId), let fontName = OSLogo.fontName,
           let logo = OSLogo.info(for: host.isRDP ? "windows" : (host.specs?.os ?? host.os)) {
            // Fix icon width so narrow tab rows cannot collapse it as the sole flexible item; title and close button already have fixed sizing.
            Text(logo.glyph).font(.custom(fontName, size: 12)).foregroundStyle(fg).frame(width: 12)
        } else {
            Image(lucideSymbol: symbol).font(.system(size: 11)).foregroundStyle(fg).frame(width: 12)
        }
    }

    var body: some View {
        let active = highlighted ?? (tabs.activeTabId == tab.id)
        HStack(spacing: 7) {
            tabIcon(active: active)
            Text(displayTitle ?? tab.title).font(.system(size: 12))
                .foregroundStyle(active ? Pal.text : Pal.subtext)
                .lineLimit(1).fixedSize(horizontal: true, vertical: false)   // Do not truncate; let the tab strip scroll horizontally.
            // Unsaved editor tabs show a dot, replaced by the close button on hover.
            if tab.kind == .editor, let st = model.editorState(for: tab.id) {
                EditorTabClose(state: st, hover: hover, active: active) { model.closeTab(tab.id) }
            } else {
                Button {
                    model.closeTab(tab.id)
                } label: {
                    Image(lucideSymbol: "xmark").font(.system(size: 9))
                        .foregroundStyle(Pal.overlay)
                        .frame(width: 16, height: 16)
                        .background(
                            hover ? Pal.fill(0.1) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 4)
                        )
                }
                .buttonStyle(.plain)
                .opacity(active || hover ? 1 : 0)
            }
        }
        .padding(.leading, 10).padding(.trailing, 6).padding(.vertical, 5)
        .background(
            active ? Pal.fill(0.08) : (hover ? Pal.fill(0.04) : Color.clear),
            in: RoundedRectangle(cornerRadius: 7)
        )
        .contentShape(Rectangle())
        .onTapGesture { model.selectTab(tab.id) }
        .onHover { hover = $0 }
        .pointerCursor()
        .accessibilityIdentifier(String(tab.id))
        .help(tab.kind == .editor ? (tab.filePath ?? "") : "")
        .contextMenu {
            Button { model.closeTab(tab.id) } label: { Label("Close Current", lucideSymbol: "xmark") }
            Button {
                model.closeTabs(tabs.tabs.filter { $0.id != tab.id && TabGroup.key(for: $0) == TabGroup.key(for: tab) }.map(\.id))
            } label: { Label("Close Others", lucideSymbol: "xmark.circle") }
            Button { model.closeAllTabs() } label: { Label("Close All", lucideSymbol: "xmark.octagon") }
            Divider()
            Button { model.requestRenameTab(tab.id) } label: { Label("Rename", lucideSymbol: "pencil") }
        }
    }
}

/// Observe EditorState separately for immediate dirty-state updates; show dirty dot when unsaved, close button when saved/hovered.
private struct EditorTabClose: View {
    @ObservedObject var state: EditorState
    let hover: Bool
    let active: Bool
    let onClose: () -> Void

    var body: some View {
        ZStack {
            if state.isDirty && !hover {
                Circle().fill(Pal.yellow).frame(width: 7, height: 7).frame(width: 16, height: 16)
            } else {
                Button(action: onClose) {
                    Image(lucideSymbol: "xmark").font(.system(size: 9))
                        .foregroundStyle(Pal.overlay)
                        .frame(width: 16, height: 16)
                        .background(hover ? Pal.fill(0.1) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .opacity(active || hover || state.isDirty ? 1 : 0)
            }
        }
        .frame(width: 16, height: 16)
    }
}

/// Workspace help explains terminal/file panel/editor/overview together.
struct WorkspaceGuideButton: View {
    @State private var show = false

    var body: some View {
        Button { show.toggle() } label: {
            Image(lucideSymbol: "questionmark.circle").font(.system(size: 13))
                .foregroundStyle(show ? Pal.mauve : Pal.overlay)
                .frame(width: 24, height: 34)
                .offset(y: -5)
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(String(localized: "Workspace Guide"))
        .popover(isPresented: $show, arrowEdge: .bottom) { WorkspaceGuideView() }
    }
}

private struct WorkspaceGuideView: View {
    @ObservedObject private var theme = ThemeManager.shared

    private struct Item: Identifiable {
        let id = UUID()
        let symbol: String
        let title: String
        let detail: String
    }

    private let items: [Item] = [
        Item(symbol: "terminal", title: String(localized: "Terminal"),
             detail: String(localized: "Your shell on the server. On its own it fills the workspace; once you open a file it moves to a panel at the bottom. Add more with +, hide or show with ⌘J. The bar above it has upload, scripts, port forwarding and more (see its ? button).")),
        Item(symbol: "sidebar.right", title: String(localized: "File Panel (right)"),
             detail: String(localized: "The server's files next to the terminal, in four tabs: Files (the file tree on top and, below it, a list of just the files in the selected folder — follows your cd; drag the divider to resize or hide the list), Favorites (pin folders and files you visit often: right-click → Add to Favorites, or ★ in the terminal bar), Recent (files you opened lately) and Scripts (saved commands to run or insert in the terminal). Click a file to edit it; right-click to upload, rename, download, open in another app or share. Drag the panel's left edge to resize; hide or show with ⌥⌘B.")),
        Item(symbol: "doc.text", title: String(localized: "Editor"),
             detail: String(localized: "Files open as tabs above the terminal, with find and replace, sudo save and more (see the editor's ? button).")),
        Item(symbol: "square.grid.2x2", title: String(localized: "Host Overview"),
             detail: String(localized: "Status, specs, live CPU, memory, disk and network charts, warnings, and Quick Access tiles: Space Analyzer (what is using the disk), Processes, Open Ports, Network Tools, HTTP Check, Docker, Services and Firewall where they apply. Below are Favorites, Recent Files, Logs and (for Linux servers) a Security summary. Open it from the terminal bar's gauge button or by clicking the host in the sidebar.")),
        Item(symbol: "wrench.and.screwdriver", title: String(localized: "Tools"),
             detail: String(localized: "The wrench in the left bar lists the tools: SSH Key Manager, and network tools — Network Info, Ping, DNS Lookup, TCP/UDP port tests, Traceroute, HTTP Check, Whois, SSL Certificate, Subdomain Finder (public certificate logs), Subnet Calculator and a Port Reference. Each opens in its own tab; most can run from this Mac or from a server.")),
        Item(symbol: "chevron.left.forwardslash.chevron.right", title: String(localized: "Scripts"),
             detail: String(localized: "Saved commands. Click one to open it in the main area: fill in its {{variables}} (defaults and choices are supported), pick the terminal to run in, then Run, type it without pressing Return, or copy it. The ▶ in the list sends it straight away.")),
        Item(symbol: "sidebar.left", title: String(localized: "Left Panel"),
             detail: String(localized: "The icons on the far left switch the list: Hosts, Remote Desktop, Storage, Tools, Key and Scripts. Switching tabs moves the list to match (for example a Network Tools tab shows the tool list).")),
        Item(symbol: "rectangle.bottomthird.inset.filled", title: String(localized: "Status Bar"),
             detail: String(localized: "Along the bottom: connection state, response time, the terminal's current folder (click to copy), the Git branch and changes when that folder is a repository, active port forwards, and a Transfers button that opens the list of uploads, downloads and other background tasks. Turn on Live Stats for CPU, memory, load and uptime.")),
        Item(symbol: "circle.lefthalf.filled", title: String(localized: "Server Colors"),
             detail: String(localized: "Each server has its own color (sidebar, tabs, terminal panel) so you can tell servers apart. Change it in Edit Host.")),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Workspace Guide").font(.system(size: 13, weight: .semibold)).foregroundStyle(Pal.text)
                Text("Connect once and get a shell and the server's files side by side — run commands, browse and edit without switching pages.")
                    .font(.system(size: 11)).foregroundStyle(Pal.subtext)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 12) {
                ForEach(items) { item in
                    HStack(alignment: .top, spacing: 10) {
                        Image(lucideSymbol: item.symbol).font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Pal.mauve)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.text)
                            Text(item.detail).font(.system(size: 11)).foregroundStyle(Pal.subtext)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            Divider().overlay(Pal.fill(0.08))
            HStack(spacing: 14) {
                shortcut("⌘J", String(localized: "Terminal"))
                shortcut("⌥⌘B", String(localized: "Files"))
                shortcut("⌘W", String(localized: "Close Tab"))
            }
        }
        .padding(16)
        .frame(width: 340)
        .background(Pal.solidBase)
        .preferredColorScheme(theme.isDark ? .dark : .light)
    }

    private func shortcut(_ keys: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(verbatim: keys).font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Pal.text)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(Pal.fill(0.08), in: RoundedRectangle(cornerRadius: 4))
            Text(label).font(.system(size: 11)).foregroundStyle(Pal.subtext)
        }
    }
}

/// Toggle the file panel with Option-Command-B.
struct FilePanelToggle: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Button { model.filePanelVisible.toggle() } label: {
            Image(lucideSymbol: model.filePanelVisible ? "sidebar.right" : "sidebar.trailing")
                .font(.system(size: 13)).foregroundStyle(model.filePanelVisible ? Pal.tint : Pal.overlay)
                .frame(width: 24, height: 34)
                .offset(y: -5)
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .keyboardShortcut("b", modifiers: [.command, .option])
        .help(String(localized: "Toggle File Panel (⌥⌘B)"))
    }
}

/// Terminal panel toggle (Command-J / Control-backtick, like VS Code): show/focus terminal or hide/restore main-area focus.
/// Create a terminal if the current server has none.
struct TerminalPanelToggle: View {
    let model: AppModel
    @ObservedObject var tabs: TabsModel
    @ObservedObject var layout: LayoutModel

    var body: some View {
        Button(action: toggle) {
            Image(lucideSymbol: layout.terminalPanelVisible ? "rectangle.bottomthird.inset.filled" : "rectangle")
                .font(.system(size: 13)).foregroundStyle(layout.terminalPanelVisible ? Pal.tint : Pal.overlay)
                .frame(width: 24, height: 34)
                .offset(y: -5)
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .keyboardShortcut("j", modifiers: .command)
        .background {
            Button("", action: toggle).keyboardShortcut("`", modifiers: .control).hidden()
        }
        .help(String(localized: "Toggle Terminal Panel (⌘J)"))
    }

    private func toggle() {
        guard let key = tabs.activeGroupKey else { layout.terminalPanelVisible.toggle(); return }
        let term = tabs.terminalTab(inGroup: key)
        if layout.terminalPanelVisible, term != nil, tabs.mainTab(inGroup: key) != nil {
            layout.terminalPanelVisible = false
            if let main = tabs.mainTab(inGroup: key) { model.selectTab(main.id) }
        } else if let term {
            layout.terminalPanelVisible = true
            model.selectTab(term.id)
        } else {
            layout.terminalPanelVisible = true
            model.openTerminal(inGroup: key)
        }
    }
}

import SwiftUI

struct Sidebar: View {
    @ObservedObject var model: AppModel
    // Observe TabsModel too, since tab changes must update activeHostId highlights and activeFileTree.
    @ObservedObject var tabs: TabsModel
    @ObservedObject var layout: LayoutModel
    @ObservedObject private var theme = ThemeManager.shared
    @ObservedObject private var settings = AppSettings.shared
    @FocusState private var searchFocused: Bool
    // Collapsed group names for this app run only; not persisted across restart.
    @State private var collapsedGroups: Set<String> = []
    @State private var dropTargetHostId: String?
    @State private var dropTargetGroup: String?
    @State private var showPingList = false
    @State private var isFullScreen = false

    private var filteredHosts: [Host] {
        // The Hosts panel lists SSH hosts only; RDP hosts belong to the RDP panel.
        let sshHosts = model.hosts.filter { !$0.isRDP && !$0.isLocal }
        guard !model.query.isEmpty else { return sshHosts }
        let q = model.query.lowercased()
        return sshHosts.filter {
            $0.name.lowercased().contains(q) || $0.addr.lowercased().contains(q)
        }
    }

    private var groups: [String] {
        model.sshGroupNames.filter { group in
            model.query.isEmpty || filteredHosts.contains { $0.group == group }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
            if model.section == .hosts {
                HStack(spacing: 6) {
                    Text(sectionTitle)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(Pal.textBright)
                    Text("\(model.hosts.filter { !$0.isRDP && !$0.isLocal }.count)")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(Pal.subtext)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Pal.fill(0.08), in: Capsule())
                    Spacer()
                    sidebarHeaderButton("plus", help: String(localized: "Add Host")) {
                        model.showAddHost = true
                    }
                    sidebarHeaderButton("slider.horizontal.3", help: String(localized: "Manage Hosts")) {
                        model.showHostManager = true
                    }
                }
            } else { HStack {
                Text(sectionTitle)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Pal.textBright)
                Spacer()
                if model.section == .sshKeys {
                    sidebarHeaderButton("square.and.arrow.down", help: String(localized: "Import Existing Private Key")) {
                        model.presentImportKey()
                    }
                    sidebarHeaderButton("plus", help: String(localized: "Generate New Key")) {
                        model.showGenerateKey = true
                    }
                } else if model.section == .sites {
                    sidebarHeaderButton("plus", help: String(localized: "Add Storage")) {
                        model.showAddSite = true
                    }
                } else if model.section == .hosts || model.section == .rdp {
                    if model.section == .hosts {
                        sidebarHeaderButton("plus", help: String(localized: "Add Host")) {
                            model.showAddHost = true
                        }
                        sidebarHeaderButton("slider.horizontal.3", help: String(localized: "Manage Hosts")) {
                            model.showHostManager = true
                        }
                    }
                    if model.section == .rdp {
                        sidebarHeaderButton("plus", help: String(localized: "Add Remote Desktop Host")) {
                            model.showAddRDPHost = true
                        }
                    }
                }
            } } }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 14)

            if model.section == .hosts {
                searchBox(showPing: true)
                if settings.showLocalHost, let local = model.localHost {   // Pin above remote hosts; absent in MAS sandbox builds.
                    LocalTerminalRow(model: model, host: local, isActive: isLocalTerminalActive)
                        .padding(.horizontal, 12).padding(.top, 12)
                }
                if filteredHosts.isEmpty && groups.isEmpty {
                    hostEmptyState
                } else {
                    ScrollView { hostList }.padding(.top, 13)
                }
            } else if model.section == .files {
                filesPanel
            } else if model.section == .rdp {
                searchBox(showPing: true)
                rdpPanel
            } else if model.section == .sites {
                SitesPanel(model: model)
                    .padding(.top, 0)
            } else if model.section == .portForwards {
                ForwardHostsPanel(model: model)
            } else if model.section == .tools {
                Spacer().frame(height: 4)
                ToolsPanel(model: model, tabs: tabs)
            } else if model.section == .snippets {
                Spacer().frame(height: 4)
                SnippetsPanel(model: model, tabs: tabs)
            } else if model.section == .sshKeys {
                Spacer().frame(height: 10)
                searchBox(String(localized: "Search Keys…"))
                KeysPanel(model: model)
            } else {
                Spacer()
                Text("\(sectionTitle) module in development")
                    .font(.system(size: 12)).foregroundStyle(Pal.overlay)
            }

            Spacer(minLength: 0)
            if model.section == .hosts { hostListFooter }
        }
        .frame(width: max(224, layout.sidebarWidth), alignment: .leading)
        .frame(maxHeight: .infinity)
        .background(Pal.base)
        .clipShape(RoundedRectangle(cornerRadius: 12))   // Rounded-top panel card floating over the window background.
        .padding(.top, isFullScreen ? 8 : 46)
        .padding(.bottom, 6)
        .frame(width: layout.sidebarWidth, alignment: .leading)
        .frame(maxHeight: .infinity)
        .background(Pal.mantle)
        .clipped()
        .onChange(of: tabs.activeTabId) { _ in searchFocused = false }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { _ in
            isFullScreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { _ in
            isFullScreen = false
        }
    }

    /// Sidebar footer: Add Host and List for host/section management.
    private var hostListFooter: some View {
        HStack(spacing: 8) {
            footerButton("plus", String(localized: "Add")) { model.showAddHost = true }
            footerButton("list.bullet", String(localized: "List")) { model.showHostManager = true }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8).padding(.bottom, 12)
    }

    private func footerButton(_ symbol: String, _ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, lucideSymbol: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Pal.text)
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .background(Pal.fill(0.045), in: RoundedRectangle(cornerRadius: 10))
    }

    private var sectionTitle: String {
        switch model.section {
        case .hosts: return String(localized: "Host")
        case .files: return String(localized: "Files")
        case .sshKeys: return String(localized: "Key")
        case .rdp: return String(localized: "Remote Desktop")
        case .snippets: return String(localized: "Scripts")
        case .sites: return String(localized: "Storage")
        case .tools: return String(localized: "Tools")
        case .portForwards: return String(localized: "Port Forwarding")
        case .settings: return String(localized: "Settings")
        }
    }

    private func sidebarHeaderButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(lucideSymbol: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Pal.subtext)
                .frame(width: 28, height: 28)
                .background(Pal.fill(0.045), in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(help)
    }

    private func searchBox(_ placeholder: String = String(localized: "Search Hosts…"), showPing: Bool = false) -> some View {
        HStack(spacing: 7) {
            Image(lucideSymbol: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Pal.overlay)
            TextField(placeholder, text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Pal.text)
                .focused($searchFocused)
            if showPing {
                Button { showPingList.toggle() } label: {
                    Image(lucideSymbol: "waveform.path.ecg")
                        .font(.system(size: 12))
                        .foregroundStyle(showPingList ? Pal.text : Pal.overlay)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help(String(localized: "View Ping"))
                .popover(isPresented: $showPingList, arrowEdge: .bottom) { PingListView(model: model) }
            }
            // Privacy mode hides IPs/hostnames in lists/overview for screenshots or screen sharing.
            Button { model.privacyMode.toggle() } label: {
                Image(lucideSymbol: model.privacyMode ? "eye.slash" : "eye")
                    .font(.system(size: 12))
                    .foregroundStyle(model.privacyMode ? Pal.text : Pal.overlay)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help(model.privacyMode ? String(localized: "Show Real Info") : String(localized: "Redacted Display (Hide IP / Hostname)"))
        }
        .padding(.horizontal, 11)
        .frame(height: 34)
        .background(Pal.fill(0.055), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 12)
    }

    /// Files panel shows the active host's file tree, or a prompt if none exists.
    @ViewBuilder
    private var filesPanel: some View {
        if let tree = model.activeFileTree {
            SidebarFileTree(state: tree.state, host: tree.host, model: model)
                .id(tree.id)
        } else {
            VStack(spacing: 10) {
                Spacer()
                Image(lucideSymbol: "folder").font(.system(size: 26)).foregroundStyle(Pal.overlay)
                Text("Open a host to\nbrowse files here")
                    .font(.system(size: 12)).foregroundStyle(Pal.subtext)
                    .multilineTextAlignment(.center)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// RDP panel lists searchable RDP hosts, with an add-host guide when empty.
    @ViewBuilder
    private var rdpPanel: some View {
        let allRDP = model.hosts.filter { $0.isRDP }
        let q = model.query.lowercased()
        let rdpHosts = q.isEmpty ? allRDP
            : allRDP.filter { $0.name.lowercased().contains(q) || $0.addr.lowercased().contains(q) }

        if allRDP.isEmpty {
            VStack(spacing: 10) {
                Spacer().frame(height: 40)
                Image(lucideSymbol: "display").font(.system(size: 26)).foregroundStyle(Pal.overlay)
                Text("No remote desktop hosts yet").font(.system(size: 13)).foregroundStyle(Pal.subtext)
                Button { model.showAddRDPHost = true } label: {
                    Text("Add Remote Desktop Host").font(.system(size: 12)).foregroundStyle(Pal.text)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(Pal.fill(0.075), in: RoundedRectangle(cornerRadius: 9))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerCursor()
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
        } else if rdpHosts.isEmpty {
            VStack(spacing: 10) {
                Spacer().frame(height: 40)
                Image(lucideSymbol: "magnifyingglass").font(.system(size: 26)).foregroundStyle(Pal.overlay)
                Text("No Matching Hosts").font(.system(size: 13)).foregroundStyle(Pal.subtext)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            let rdpGroups = rdpHosts.reduce(into: [String]()) { acc, h in
                if !acc.contains(h.group) { acc.append(h.group) }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(rdpGroups, id: \.self) { group in
                        reorderableGroupHeader(group, isRDP: true)
                        if !collapsedGroups.contains(group) {
                            ForEach(rdpHosts.filter { $0.group == group }) { host in
                                reorderableRDPRow(host)
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var hostEmptyState: some View {
        VStack(spacing: 10) {
            Spacer().frame(height: 40)
            let noHosts = !model.hosts.contains { !$0.isLocal && !$0.isRDP }
            Image(lucideSymbol: noHosts ? "server.rack" : "magnifyingglass")
                .font(.system(size: 26)).foregroundStyle(Pal.overlay)
            Text(noHosts ? "No hosts yet" : "No Matching Hosts")
                .font(.system(size: 13)).foregroundStyle(Pal.subtext)
            if noHosts {
                Button { model.showAddHost = true } label: {
                    Text("Add Host").font(.system(size: 12)).foregroundStyle(Pal.text)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(Pal.fill(0.075), in: RoundedRectangle(cornerRadius: 9))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
    }

    private var hostList: some View {
        return LazyVStack(alignment: .leading, spacing: 5) {
            ForEach(groups, id: \.self) { group in
                reorderableGroupHeader(group, isRDP: false)
                if !collapsedGroups.contains(group) {
                    ForEach(filteredHosts.filter { $0.group == group }) { host in
                        reorderableSSHRow(host)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func reorderableSSHRow(_ host: Host) -> some View {
        let row = HostRow(host: host, model: model, isActive: model.activeHostId == host.id)
            .background(dropTargetHostId == host.id ? Pal.fill(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 11))
        if model.query.isEmpty {
            row.draggable("host:\(host.id)")
                .dropDestination(for: String.self) { items, location in
                    guard let item = items.first else { return false }
                    if item.hasPrefix("host:") {
                        return model.moveHost(String(item.dropFirst(5)), relativeTo: host.id, after: location.y > 28)
                    }
                    // Dropping a section on an item targets that item's section position.
                    let prefix = "group:ssh:"
                    guard item.hasPrefix(prefix) else { return false }
                    return dropGroup(String(item.dropFirst(prefix.count)), on: host.group, isRDP: false)
                } isTargeted: { targeted in
                    dropTargetHostId = targeted ? host.id : nil
                }
        } else { row }
    }

    @ViewBuilder
    private func reorderableRDPRow(_ host: Host) -> some View {
        let row = RDPHostRow(host: host, model: model, isActive: model.activeHostId == host.id)
            .background(dropTargetHostId == host.id ? Pal.fill(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 11))
        if model.query.isEmpty {
            row.draggable("host:\(host.id)")
                .dropDestination(for: String.self) { items, location in
                    guard let item = items.first else { return false }
                    if item.hasPrefix("host:") {
                        return model.moveHost(String(item.dropFirst(5)), relativeTo: host.id, after: location.y > 28)
                    }
                    // Dropping a section on an item targets that item's section position.
                    let prefix = "group:rdp:"
                    guard item.hasPrefix(prefix) else { return false }
                    return dropGroup(String(item.dropFirst(prefix.count)), on: host.group, isRDP: true)
                } isTargeted: { targeted in
                    dropTargetHostId = targeted ? host.id : nil
                }
        } else { row }
    }

    @ViewBuilder
    private func reorderableGroupHeader(_ group: String, isRDP: Bool) -> some View {
        let header = groupHeader(group)
            .background(dropTargetGroup == group ? Pal.fill(0.10) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8))
        if model.query.isEmpty {
            let prefix = isRDP ? "group:rdp:" : "group:ssh:"
            header.draggable(prefix + group)
                .dropDestination(for: String.self) { items, location in
                    guard let item = items.first else { return false }
                    if item.hasPrefix("host:") {   // Dropping an item on a section header moves it into that section.
                        let id = String(item.dropFirst(5))
                        guard let h = model.hosts.first(where: { $0.id == id }), h.isRDP == isRDP, h.group != group else { return false }
                        model.assignHost(id, toGroup: group)
                        return true
                    }
                    guard item.hasPrefix(prefix) else { return false }
                    return model.moveHostGroup(String(item.dropFirst(prefix.count)), relativeTo: group,
                                               isRDP: isRDP, after: location.y > 19)
                } isTargeted: { targeted in
                    dropTargetGroup = targeted ? group : nil
                }
        } else { header }
    }

    /// Section drops insert after when moving down, before when moving up.
    private func dropGroup(_ name: String, on target: String, isRDP: Bool) -> Bool {
        var names: [String] = isRDP ? [] : model.sshGroupNames
        if isRDP { for h in model.hosts where h.isRDP && !names.contains(h.group) { names.append(h.group) } }
        guard let from = names.firstIndex(of: name), let to = names.firstIndex(of: target) else { return false }
        return model.moveHostGroup(name, relativeTo: target, isRDP: isRDP, after: from < to)
    }

    private func groupHeader(_ group: String) -> some View {
        let collapsed = collapsedGroups.contains(group)
        return Button {
            if collapsed { collapsedGroups.remove(group) } else { collapsedGroups.insert(group) }
        } label: {
            HStack(spacing: 7) {
                // Disclosure icon matches the group-name font size/width; down when expanded and right when collapsed.
                Image(lucideSymbol: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Pal.overlay)
                    .frame(width: 11)
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
                Image(lucideSymbol: "folder")
                    .font(.system(size: 12))
                    .foregroundStyle(Pal.subtext)
                Text(group.isEmpty ? String(localized: "Ungrouped") : group)
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.subtext)
                Spacer(minLength: 0)
                Image(lucideSymbol: "line.3.horizontal")
                    .font(.system(size: 9)).foregroundStyle(Pal.overlay.opacity(0.65))
                    .help(String(localized: "Drag to reorder"))
            }
            .padding(.leading, 2).padding(.trailing, 9).padding(.top, 17).padding(.bottom, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .animation(.easeOut(duration: 0.15), value: collapsed)
    }

    /// Whether the active tab belongs to the local host, for row highlighting.
    private var isLocalTerminalActive: Bool {
        guard let id = tabs.activeTabId, let t = tabs.tabs.first(where: { $0.id == id }) else { return false }
        return t.hostId == Host.localId
    }
}

/// Host organizer centralizes add/import and section/host management.
struct HostManagerView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var theme = ThemeManager.shared
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showAddHost = false
    @State private var editingHost: Host?
    @State private var showGroupEditor = false
    @State private var groupBeingRenamed: String?
    @State private var groupName = ""
    @State private var groupBeingDeleted: String?
    @State private var hostBeingDeleted: Host?
    @State private var dropTargetSection: String?
    @State private var dropTargetManagedHost: String?
    @State private var dropTargetManagedGroup: String?

    private var sshHosts: [Host] { model.hosts.filter { !$0.isLocal && !$0.isRDP } }
    private var ungrouped: String { String(localized: "Ungrouped") }
    private var proposedGroup: String { groupName.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var groupNameValid: Bool {
        !proposedGroup.isEmpty && (proposedGroup == groupBeingRenamed || !model.sshGroupNames.contains(proposedGroup))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Manage Hosts").font(.system(size: 17, weight: .semibold)).foregroundStyle(Pal.text)
                    Text("Organize SSH hosts and sections")
                        .font(.system(size: 12)).foregroundStyle(Pal.subtext)
                }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.plain).foregroundStyle(Pal.mauve).pointerCursor()
            }
            .padding(20)

            Divider().overlay(Pal.fill(0.06))

            HStack(spacing: 10) {
                Button { showAddHost = true } label: { Label("Add Host", lucideSymbol: "plus") }
                Button { startGroupEditor() } label: { Label("New Section", lucideSymbol: "folder.badge.plus") }
                Menu {
                    Button("Import Servers…") { model.presentImportHosts() }
                    Button("Import from iTerm2") { model.presentImportITerm() }
                } label: { Label("Import", lucideSymbol: "square.and.arrow.down") }
                Button { model.presentExportHosts() } label: { Label("Export Servers…", lucideSymbol: "square.and.arrow.up") }
                Spacer()
            }
            .buttonStyle(.bordered)
            .padding(.horizontal, 20).padding(.vertical, 14)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    preferencesCard
                    if model.sshGroupNames.isEmpty {
                        VStack(spacing: 10) {
                            Image(lucideSymbol: "server.rack").font(.system(size: 28)).foregroundStyle(Pal.overlay)
                            Text("No hosts or sections yet").font(.system(size: 13)).foregroundStyle(Pal.subtext)
                            Text("Add a host, create a section, or import from iTerm2.")
                                .font(.system(size: 12)).foregroundStyle(Pal.overlay)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 80)
                    }
                    ForEach(model.sshGroupNames, id: \.self) { group in
                        sectionCard(group)
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 740, height: 620)
        .background(Pal.solidBase)
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .sheet(isPresented: $showAddHost) { AddHostView(model: model) }
        .sheet(item: $editingHost) { AddHostView(model: model, editing: $0) }
        .alert(groupBeingRenamed == nil ? "New Section" : "Rename Section", isPresented: $showGroupEditor) {
            TextField("Section name", text: $groupName)
            Button("Save") {
                if let old = groupBeingRenamed {
                    _ = model.renameHostGroup(old, to: proposedGroup)
                } else {
                    _ = model.addHostGroup(proposedGroup)
                }
                groupBeingRenamed = nil
            }
            .disabled(!groupNameValid)
            Button("Cancel", role: .cancel) { groupBeingRenamed = nil }
        } message: {
            Text("Sections organize SSH hosts. Empty sections are kept.")
        }
        .confirmationDialog("Delete Section?", isPresented: Binding(
            get: { groupBeingDeleted != nil }, set: { if !$0 { groupBeingDeleted = nil } }
        )) {
            Button("Delete Section", role: .destructive) {
                if let group = groupBeingDeleted { model.removeHostGroup(group) }
                groupBeingDeleted = nil
            }
            Button("Cancel", role: .cancel) { groupBeingDeleted = nil }
        } message: {
            Text("Hosts in this section will move to Ungrouped.")
        }
        .alert("Delete Host?", isPresented: Binding(
            get: { hostBeingDeleted != nil }, set: { if !$0 { hostBeingDeleted = nil } }
        )) {
            Button("Delete Host", role: .destructive) {
                if let host = hostBeingDeleted { model.deleteHost(host.id) }
                hostBeingDeleted = nil
            }
            Button("Cancel", role: .cancel) { hostBeingDeleted = nil }
        } message: {
            Text("This host's saved configuration will be removed.")
        }
        .alert("Import from iTerm2", isPresented: Binding(
            get: { model.hostImportNotice != nil }, set: { if !$0 { model.hostImportNotice = nil } }
        )) {
            Button("OK", role: .cancel) { model.hostImportNotice = nil }
        } message: {
            Text(model.hostImportNotice ?? "")
        }
    }

    private var preferencesCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Host List Options")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Pal.text)
            if model.localHost != nil {
                Toggle("Show Local Host in Host List", isOn: $settings.showLocalHost)
                    .toggleStyle(.switch)
                    .onChange(of: settings.showLocalHost) { visible in
                        if !visible && settings.startupBehavior == .overview {
                            settings.startupBehavior = .welcome
                        }
                    }
            }
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Show on App Launch").font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.text)
                    Text("Opens the selected page or host overview at launch.")
                        .font(.system(size: 11)).foregroundStyle(Pal.subtext)
                }
                Spacer()
                Menu {
                    Button("Welcome Page") { settings.startupBehavior = .welcome }
                    if settings.showLocalHost && model.localHost != nil {
                        Button("Local Overview") { settings.startupBehavior = .overview }
                    }
                    if model.localHost != nil {
                        Button("New Terminal") { settings.startupBehavior = .terminal }
                    }
                    if !model.hosts.filter({ !$0.isLocal }).isEmpty { Divider() }
                    ForEach(model.hosts.filter { !$0.isLocal }) { host in
                        Button(host.name) {
                            settings.startupHostId = host.id
                            settings.startupBehavior = .host
                        }
                    }
                } label: {
                    HStack(spacing: 7) {
                        Text(startupSelectionTitle).lineLimit(1)
                        Image(lucideSymbol: "chevron.up.chevron.down").font(.system(size: 10))
                    }
                    .font(.system(size: 12)).foregroundStyle(Pal.text)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Pal.fill(0.07), in: RoundedRectangle(cornerRadius: 7))
                }
                .frame(maxWidth: 220)
            }
        }
        .padding(14)
        .background(Pal.fill(0.04), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Pal.fill(0.10), lineWidth: 1))
    }

    private var startupSelectionTitle: String {
        switch settings.startupBehavior {
        case .welcome: return String(localized: "Welcome Page")
        case .overview: return String(localized: "Local Overview")
        case .terminal: return String(localized: "New Terminal")
        case .host:
            return model.hosts.first(where: { $0.id == settings.startupHostId })?.name
                ?? String(localized: "Welcome Page")
        }
    }

    private func sectionCard(_ group: String) -> some View {
        let index = model.sshGroupNames.firstIndex(of: group) ?? 0
        let members = sshHosts.filter { $0.group == group }
        return VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(lucideSymbol: "folder").foregroundStyle(Pal.mauve)
                Text(group.isEmpty ? ungrouped : group)
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Pal.text)
                Text("\(members.count)").font(.system(size: 11)).foregroundStyle(Pal.overlay)
                Spacer()
                Button { moveGroup(group, by: -1) } label: { Image(lucideSymbol: "chevron.up") }
                    .disabled(index == 0).help(String(localized: "Move Up"))
                Button { moveGroup(group, by: 1) } label: { Image(lucideSymbol: "chevron.down") }
                    .disabled(index == model.sshGroupNames.count - 1).help(String(localized: "Move Down"))
                Menu {
                    Button("Rename Section") { startGroupEditor(renaming: group) }
                    Button("Delete Section", role: .destructive) { groupBeingDeleted = group }
                        .disabled(group == ungrouped)
                } label: { Image(lucideSymbol: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 28)
            }
            .buttonStyle(.plain).foregroundStyle(Pal.subtext).pointerCursor()
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(dropTargetManagedGroup == group ? Pal.mauve.opacity(0.12) : Color.clear)
            .draggable("managed-group:ssh:\(group)")
            .dropDestination(for: String.self) { items, location in
                guard let item = items.first else { return false }
                if item.hasPrefix("host:") { return dropHost(String(item.dropFirst(5)), intoGroup: group) }
                guard item.hasPrefix("managed-group:ssh:") else { return false }
                let source = String(item.dropFirst("managed-group:ssh:".count))
                return moveManagedGroup(source, relativeTo: group, after: location.y >= 20)
            } isTargeted: { targeted in
                dropTargetManagedGroup = targeted ? group : nil
                dropTargetSection = targeted ? group : (dropTargetSection == group ? nil : dropTargetSection)
            }
            if members.isEmpty {
                Text("No hosts in this section")
                    .font(.system(size: 12)).foregroundStyle(Pal.overlay)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.bottom, 13)
                    .contentShape(Rectangle())
                    .dropDestination(for: String.self) { items, _ in
                        guard let item = items.first, item.hasPrefix("host:") else { return false }
                        return dropHost(String(item.dropFirst(5)), intoGroup: group)
                    } isTargeted: { targeted in
                        dropTargetSection = targeted ? group : (dropTargetSection == group ? nil : dropTargetSection)
                    }
            } else {
                ForEach(members) { host in
                    Divider().overlay(Pal.fill(0.05))
                    hostRow(host)
                }
            }
        }
        .background(Pal.fill(0.04), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(
            dropTargetSection == group ? Pal.mauve.opacity(0.75) : Pal.fill(0.10),
            lineWidth: dropTargetSection == group ? 1.5 : 1
        ))
    }

    /// Move items between sections; ignore same-section moves.
    private func dropHost(_ hostID: String, intoGroup group: String) -> Bool {
        guard sshHosts.contains(where: { $0.id == hostID && $0.group != group }) else { return false }
        model.assignHost(hostID, toGroup: group)
        return true
    }

    private func hostRow(_ host: Host) -> some View {
        let row = HStack(spacing: 10) {
            Image(lucideSymbol: "server.rack").foregroundStyle(host.accent).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(host.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Pal.text)
                Text(host.addr).font(.system(size: 11)).foregroundStyle(Pal.subtext)
            }
            Spacer()
            Button("Edit") { editingHost = host }
                .buttonStyle(.plain).foregroundStyle(Pal.mauve)
            Menu {
                ForEach(model.sshGroupNames.filter { $0 != host.group }, id: \.self) { group in
                    Button(group.isEmpty ? ungrouped : group) { model.assignHost(host.id, toGroup: group) }
                }
            } label: { Image(lucideSymbol: "folder.badge.gearshape") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .help(String(localized: "Move to Section"))
            Menu {
                Button("Move Up") { model.moveHost(host.id, by: -1) }
                    .disabled(!model.canMoveHost(host.id, by: -1))
                Button("Move Down") { model.moveHost(host.id, by: 1) }
                    .disabled(!model.canMoveHost(host.id, by: 1))
                Divider()
                Button("Duplicate Host") { model.duplicateHost(host) }
                Button("Delete Host", role: .destructive) { hostBeingDeleted = host }
            } label: { Image(lucideSymbol: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(dropTargetManagedHost == host.id ? Pal.mauve.opacity(0.12) : Color.clear)

        return row
            .draggable("host:\(host.id)")
            .dropDestination(for: String.self) { items, location in
                guard let item = items.first else { return false }
                if item.hasPrefix("managed-group:ssh:") {   // Dropping sections on items also reorders sections.
                    let name = String(item.dropFirst("managed-group:ssh:".count))
                    guard let from = model.sshGroupNames.firstIndex(of: name),
                          let to = model.sshGroupNames.firstIndex(of: host.group) else { return false }
                    return moveManagedGroup(name, relativeTo: host.group, after: from < to)
                }
                guard item.hasPrefix("host:") else { return false }
                let sourceID = String(item.dropFirst("host:".count))
                guard let source = sshHosts.first(where: { $0.id == sourceID }), sourceID != host.id else { return false }
                if source.group != host.group {
                    model.assignHost(sourceID, toGroup: host.group)
                }
                return model.moveHost(sourceID, relativeTo: host.id, after: location.y >= 18)
            } isTargeted: { targeted in
                dropTargetManagedHost = targeted ? host.id : nil
            }
    }

    private func startGroupEditor(renaming group: String? = nil) {
        groupBeingRenamed = group
        groupName = group ?? ""
        showGroupEditor = true
    }

    private func moveGroup(_ group: String, by offset: Int) {
        guard let index = model.sshGroupNames.firstIndex(of: group),
              model.sshGroupNames.indices.contains(index + offset) else { return }
        _ = model.moveHostGroup(group, relativeTo: model.sshGroupNames[index + offset],
                                isRDP: false, after: offset > 0)
    }

    private func moveManagedGroup(_ group: String, relativeTo target: String, after: Bool) -> Bool {
        guard group != target, model.sshGroupNames.contains(group), model.sshGroupNames.contains(target) else { return false }
        return model.moveHostGroup(group, relativeTo: target, isRDP: false, after: after)
    }
}

private struct SidebarHostIcon: View {
    let host: Host
    let isActive: Bool

    var body: some View {
        Image(lucideSymbol: host.isRDP ? (host.rdp?.protocolType == .vnc ? "macwindow" : "display") : "server.rack")
            .font(.system(size: 17, weight: .regular))
            .foregroundStyle(isActive ? Pal.textBright : Pal.subtext)
            .frame(width: 24, height: 28)
            .overlay(alignment: .bottomTrailing) {
                // Connection dot uses server color online, gray offline/unknown.
                Circle().fill(host.status == .online ? host.accent : Pal.overlay.opacity(0.7))
                    .frame(width: 6, height: 6)
                    .overlay(Circle().stroke(Pal.base, lineWidth: 1))
                    .offset(x: 1, y: 1)
            }
    }
}

struct HostRow: View {
    let host: Host
    @ObservedObject var model: AppModel
    let isActive: Bool   // Passed down from the TabsModel-observing Sidebar so host highlights update immediately.
    @ObservedObject private var theme = ThemeManager.shared
    @State private var hover = false

    var body: some View {
        Button {
            model.openHost(host)
        } label: {
            HStack(spacing: 8) {
                SidebarHostIcon(host: host, isActive: isActive)
                VStack(alignment: .leading, spacing: 2) {
                    Text(host.name).font(.system(size: 13, weight: isActive ? .medium : .regular))
                        .foregroundStyle(isActive ? Pal.textBright : Pal.text)
                        .lineLimit(1)
                    Text(host.ipOrHost)
                        .font(.system(size: 11)).foregroundStyle(Pal.subtext)
                        .lineLimit(1)
                        .privacyBlur(model.privacyMode)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // Show row latency only above 100ms; the search-adjacent Ping view shows all hosts.
                if host.status == .online, let ms = host.latencyMs, ms > 100 {
                    Text(verbatim: "\(ms) ms").font(.system(size: 11)).foregroundStyle(LatencyLevel(ms: ms).color)
                }
            }
            .padding(.leading, 11).padding(.trailing, 7).padding(.vertical, 10)
            .background(
                isActive ? Pal.fill(0.105) : (hover ? Pal.fill(0.055) : Color.clear),
                in: RoundedRectangle(cornerRadius: 11)
            )
            .animation(.easeOut(duration: 0.18), value: isActive)   // Smoothly fade selection highlighting.
            .animation(.easeOut(duration: 0.12), value: hover)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hover = $0 }
        .contextMenu {
            Button("Open Terminal") { model.openHostTerminal(host) }
            Button("New Terminal") { model.openHostTerminal(host, forceNew: true) }
            Button("Open File") { model.openHostFiles(host) }
            Button("Edit Host") { model.beginEditHost(host) }
            Button("Duplicate Host") { model.duplicateHost(host) }
            Divider()
            Button("Move Up") { model.moveHost(host.id, by: -1) }
                .disabled(!model.canMoveHost(host.id, by: -1))
            Button("Move Down") { model.moveHost(host.id, by: 1) }
                .disabled(!model.canMoveHost(host.id, by: 1))
            Divider()
            Button("Delete Host", role: .destructive) { model.requestDeleteHost(host) }
        }
    }
}

/// Click an RDP host row to connect to its desktop.
struct RDPHostRow: View {
    let host: Host
    @ObservedObject var model: AppModel
    let isActive: Bool   // Like HostRow, receive active state from Sidebar for immediate highlight updates.
    @ObservedObject private var theme = ThemeManager.shared
    @State private var hover = false

    var body: some View {
        Button {
            model.openHost(host)   // Like SSH hosts, open the overview first; its Remote Desktop action initiates connection.
        } label: {
            HStack(spacing: 8) {
                SidebarHostIcon(host: host, isActive: isActive)
                VStack(alignment: .leading, spacing: 2) {
                    Text(host.name).font(.system(size: 13, weight: isActive ? .medium : .regular))
                        .foregroundStyle(isActive ? Pal.textBright : Pal.text)
                        .lineLimit(1)
                    Text(host.ipOrHost)
                        .font(.system(size: 11)).foregroundStyle(Pal.subtext)
                        .lineLimit(1)
                        .privacyBlur(model.privacyMode)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, 11).padding(.trailing, 7).padding(.vertical, 10)
            .background(
                isActive ? Pal.fill(0.105) : (hover ? Pal.fill(0.055) : Color.clear),
                in: RoundedRectangle(cornerRadius: 11)
            )
            .animation(.easeOut(duration: 0.18), value: isActive)   // Smoothly fade selection highlighting.
            .animation(.easeOut(duration: 0.12), value: hover)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hover = $0 }
        .contextMenu {
            Button("Remote Desktop") { model.openHostRDP(host) }
            Button("Edit Host") { model.editingRDPHost = host }
            Button("Duplicate Host") { model.duplicateHost(host) }
            Divider()
            Button("Move Up") { model.moveHost(host.id, by: -1) }
                .disabled(!model.canMoveHost(host.id, by: -1))
            Button("Move Down") { model.moveHost(host.id, by: 1) }
                .disabled(!model.canMoveHost(host.id, by: 1))
            Divider()
            Button("Delete Host", role: .destructive) { model.requestDeleteHost(host) }
        }
    }
}


/// All-host latency popover probes once on opening.
struct PingListView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Ping").font(.system(size: 12, weight: .semibold)).foregroundStyle(Pal.text)
                Spacer()
                Button { model.refreshAllStatuses() } label: {
                    Image(lucideSymbol: "arrow.clockwise").font(.system(size: 11)).foregroundStyle(Pal.overlay)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointerCursor().help(String(localized: "Refresh"))
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            Divider().overlay(Pal.fill(0.08))
            let listed = model.hosts.filter { !$0.isLocal }
            if listed.isEmpty {
                Text("No Hosts").font(.system(size: 12)).foregroundStyle(Pal.overlay).padding(14)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(listed) { host in
                            HStack(spacing: 8) {
                                Circle().fill(host.accent.opacity(0.8)).frame(width: 6, height: 6)
                                Text(host.name).font(.system(size: 12)).foregroundStyle(Pal.text).lineLimit(1)
                                Spacer(minLength: 12)
                                if host.status == .online, let ms = host.latencyMs {
                                    Text(verbatim: "\(ms) ms").font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(LatencyLevel(ms: ms).color)
                                } else if host.status == .offline {
                                    Text("Offline").font(.system(size: 11)).foregroundStyle(Pal.red)
                                } else {
                                    Text(verbatim: "—").font(.system(size: 11)).foregroundStyle(Pal.overlay)
                                }
                            }
                            .padding(.horizontal, 12).padding(.vertical, 6)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 320)
            }
        }
        .frame(width: 240)
        .background(Pal.solidBase)
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .onAppear { model.refreshAllStatuses() }
    }
}


/// Local Mac row matches remote icon/name/subtitle styling and stays pinned first.
/// Click opens overview; context actions open/recreate terminals directly.
struct LocalTerminalRow: View {
    @ObservedObject var model: AppModel
    let host: Host
    let isActive: Bool
    @ObservedObject private var theme = ThemeManager.shared
    @State private var hover = false

    private var subtitle: String { host.addr }

    private var isOpen: Bool { model.tabs.contains { $0.kind == .terminal && $0.hostId == Host.localId } }

    var body: some View {
        Button {
            model.openHost(host)
        } label: {
            HStack(spacing: 11) {
                ZStack(alignment: .bottomTrailing) {
                    Image(lucideSymbol: "terminal")
                        .font(.system(size: 17))
                        .foregroundStyle(host.accent)
                        .frame(width: 24, height: 28)
                    Circle().fill(host.accent).frame(width: 6, height: 6)
                        .overlay(Circle().stroke(Pal.base, lineWidth: 1))
                        .offset(x: 1, y: 1)
                }
                .frame(width: 24, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Local Terminal").font(.system(size: 13, weight: isActive ? .medium : .regular))
                        .foregroundStyle(isActive ? Pal.textBright : Pal.text)
                    Text(verbatim: subtitle).font(.system(size: 11)).foregroundStyle(Pal.subtext).lineLimit(1)
                        .privacyBlur(model.privacyMode)
                }
                Spacer()
            }
            .padding(.horizontal, 11).padding(.vertical, 10)
            .background(
                isActive ? Pal.fill(0.105) : (hover ? Pal.fill(0.055) : Color.clear),
                in: RoundedRectangle(cornerRadius: 11)
            )
            .animation(.easeOut(duration: 0.18), value: isActive)
            .animation(.easeOut(duration: 0.12), value: hover)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hover = $0 }
        .contextMenu {
            Button("Open Terminal") { model.openHostTerminal(host) }
            Button("New Terminal") { model.openHostTerminal(host, forceNew: true) }
        }
    }
}

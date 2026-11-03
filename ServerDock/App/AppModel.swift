import AppKit
import Combine
import Darwin
import SwiftTerm
import SwiftUI
import UniformTypeIdentifiers

/// Host fingerprint awaiting first-connection verification; respond returns the user's choice to the caller.
struct PendingHostKey: Identifiable {
    let id = UUID()
    let info: HostKeyInfo
    let respond: (HostKeyDecision) -> Void
}

// Limit online probing to six concurrent TCP probes to bound thread/CPU usage even with many hosts.
// Keep this at file scope rather than inside @MainActor AppModel. DispatchQueue/Semaphore are thread-safe and not actor-isolated,
// so background Sendable closures can use them without main-actor static-property isolation warnings.
private let reachQueue = DispatchQueue(label: "serverdock.reach", qos: .utility, attributes: .concurrent)
private let reachLimit = DispatchSemaphore(value: 6)

/// Separate NSWindow/RDPSessionView host for New Window RDP sessions, entering full screen by default.
/// The rootView strongly retains the session; AppModel retains this controller. Closing disconnects and invokes the release callback.
final class RDPWindowController: NSWindowController, NSWindowDelegate {
    let session: RDPSession
    var onClose: (() -> Void)?

    /// Host ID used to deduplicate/focus the one connection per host.
    var hostId: String { session.host.id }

    /// Restore the window by unminimizing it and bringing it forward.
    func focus() {
        guard let w = window else { return }
        if w.isMiniaturized { w.deminiaturize(nil) }
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    init(session: RDPSession) {
        self.session = session
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = session.host.name
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.contentView = NSHostingView(rootView: RDPSessionView(session: session))
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.center()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Bring forward and show; fullscreen=true enters full screen according to the new-window behavior preference.
    func present(fullscreen: Bool) {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        guard fullscreen else { return }
        // Wait one run-loop turn before toggleFullScreen; calling immediately after makeKeyAndOrderFront may be ignored.
        DispatchQueue.main.async { [weak self] in
            guard let w = self?.window, !w.styleMask.contains(.fullScreen) else { return }
            w.toggleFullScreen(nil)
        }
    }

    func windowWillClose(_ notification: Notification) {
        session.disconnect()
        onClose?()
    }
}



@MainActor
final class AppModel: ObservableObject {
    @Published var section: Section = .hosts
    @Published var query: String = ""
    // Session-only privacy mode hides list/overview IPs and hostnames, toggled by the search-field eye button; not persisted.
    @Published var privacyMode: Bool = false

    // Keep tab state in [[TabsModel]] so TabBar/Workspace avoid recomputation from unrelated AppModel @Published changes.
    // Forwarding computed properties preserve internal tabs/activeTabId references while views observe tabsModel directly.
    let tabsModel = TabsModel()
    var tabs: [TabItem] {
        get { tabsModel.tabs }
        set { tabsModel.tabs = newValue }
    }
    var activeTabId: Int? {
        get { tabsModel.activeTabId }
        set {
            tabsModel.activeTabId = newValue
            if let id = newValue, let hid = tabsModel.tabs.first(where: { $0.id == id })?.hostId { noteHostUsed(hid) }
        }
    }

    // MARK: Recently used hosts (Welcome's Recent Hosts)
    /// Host ID to last tab-open/selection time, stored in UserDefaults separately from host data.
    private(set) var hostLastUsed: [String: Date] = {
        let raw = UserDefaults.standard.dictionary(forKey: "hostLastUsed") as? [String: Double] ?? [:]
        return raw.mapValues { Date(timeIntervalSince1970: $0) }
    }()

    private func noteHostUsed(_ id: String) {
        let now = Date()
        if let last = hostLastUsed[id], now.timeIntervalSince(last) < 5 { return }   // Throttle persistence instead of writing on every tab selection.
        hostLastUsed[id] = now
        if AppEnv.isScreenshotDemo { return }
        UserDefaults.standard.set(hostLastUsed.mapValues { $0.timeIntervalSince1970 }, forKey: "hostLastUsed")
    }
    // Sidebar width also lives in independent [[LayoutModel]], so resizing does not trigger this object's
    // objectWillChange and recompute heavy TabBar/Workspace views on every frame; see LayoutModel.
    @Published var settingsTab: SettingsTab = .general
    @Published var showSettings = false
    @Published var showAddHost = false
    @Published var showHostManager = false
    @Published var editingHost: Host? = nil   // Non-nil opens the host form in edit mode.
    @Published var showAddRDPHost = false
    @Published var editingRDPHost: Host? = nil   // Non-nil opens the RDP host form in edit mode.
    // SSH key library.
    @Published var sshKeys: [SSHKey] = []
    @Published var showGenerateKey = false        // Show Generate Key dialog.
    @Published var detailKey: SSHKey? = nil        // Non-nil shows key details.
    @Published var keyOpError: String? = nil       // Key generation/import error message.
    // Storage sites: SMB / WebDAV / S3-compatible storage.
    @Published var sites: [Site] = []
    @Published var showAddSite = false
    @Published var editingSite: Site? = nil
    @Published var siteBeingDeleted: Site? = nil     // Site awaiting deletion confirmation.
    var siteSessions: [Int: SiteSession] = [:]
    // Snippets.
    @Published var snippets: [Snippet] = []
    @Published var showCreateSnippet = false               // Show New Snippet dialog.
    @Published var editingSnippet: Snippet? = nil          // Non-nil shows snippet editing/details.
    /// Terminal AI assistant input panel; the remote shell checks whether the corresponding CLI exists before executing commands.
    @Published var aiProfileEdit: ProfileEditRequest? = nil   // AI profile add/edit dialog opened by the command generator.
    @Published var aiPromptContext: AIPromptContext? = nil
    @Published var pendingSnippetRun: SnippetRunRequest? = nil  // Non-nil shows variable-value input.
    @Published var pendingSnippetAction: Snippet? = nil    // Non-nil shows the Insert/Run choice.
    @Published var snippetNotice: String? = nil            // Snippet notice, such as no available terminal.
    @Published var hostImportNotice: String? = nil         // iTerm2 import result notice.
    @Published var pendingAskAuth: Host? = nil     // Pre-connection password prompt for ask-mode hosts.
    private var pendingAskContinuation: (() -> Void)?   // Action to execute after password confirmation, such as terminal/files/forwarding.
    private var connectingContinuation: (() -> Void)?   // Original action to execute after successful connection verification.
    var connectingActionHint = String(localized: "Opening terminal…")          // Connection-dialog success text varies by action and is read by ContentView.
    private var askVerifiedHosts: Set<String> = []      // Ask-mode hosts whose session password is already verified; later file/forwarding access connects without another dialog.
    @Published var pendingHostKey: PendingHostKey? = nil   // First-connection host fingerprint awaiting verification.
    @Published var connectingHost: Host? = nil   // Connecting host shown in the progress dialog.
    @Published var connectingRDP: RDPSession? = nil   // Connecting RDP session before its tab opens; overlay the current view and open the tab only after success.
    @Published var pendingRDPOpen: RDPSession? = nil   // Connected session awaiting the user's inline/new-window choice.
    @Published private(set) var rdpHosts: Set<String> = []   // Host IDs with existing inline/window RDP connections, used for the overview's Running state.
    private var rdpWindowControllers: [RDPWindowController] = []   // Retain separate RDP windows and their sessions until closed.

    // File context-action dialog for delete/rename/permissions/refresh conflicts/notices.
    @Published var pendingFileDelete: FileOpContext? = nil
    @Published var pendingFileRename: FileOpContext? = nil
    @Published var pendingFileChmod: ChmodContext? = nil
    @Published var pendingFileCreate: CreateContext? = nil   // New file/folder name prompt.
    @Published var pendingFileRefresh: RefreshConflictContext? = nil
    @Published var pendingFileInfo: FileInfoContext? = nil
    // Concurrent upload/download queue, capped by maxConcurrentTransfers. Excess tasks wait; finished tasks remain until cleared.
    @Published var transfers: [UploadTask] = []
    // Expanded transfer-dialog task ID, or nil. Tasks continue in the background and are managed in the bottom-left center.
    @Published var focusedTransferId: UUID? = nil
    // One-shot fly-in event for dialog-free downloads; clear after animation rather than retaining ongoing CPU/memory work.
    @Published var flyTransfer: FlyEvent? = nil
    // Background button's reported global center, used as the fly-in destination.
    var backgroundButtonCenter: CGPoint = .zero
    // Selected-row global frames indexed by remote path; use as fly-in origin, falling back to pointer position.
    var fileRowGlobalFrames: [String: CGRect] = [:]
    @Published var extractTask: ExtractTask? = nil // Current extraction task, or nil.
    @Published var showExtractDialog = false       // Extraction dialog visibility; hiding leaves the task running with a compact status beside settings.
    @Published var fileDeleteBusy = false          // Keep the dialog and delete-button spinner visible during deletion; allow cancellation.
    private var deleteHandle: CommandHandle?        // Cancel active deletion by terminating remote rm.
    @Published var pendingBatchDelete: BatchDeleteContext? = nil   // Batch-delete confirmation dialog.
    @Published var batchDeleteBusy = false         // Keep the batch-delete dialog and spinner visible while processing.
    @Published var pendingHostDelete: Host? = nil  // Delete-host confirmation.

    @Published var hosts: [Host] = []
    /// Host session history for terminal/upload/forwarding, shown in Recent Sessions.
    @Published var sessions: [SessionEvent] = []
    /// Persist all forwarding rules; [[ForwardManager]] maintains runtime state separately.
    @Published var forwards: [ForwardRule] = []
    /// Non-nil shows that host's forwarding manager.
    @Published var forwardPanelHost: Host? = nil
    @Published var forwardFilterHostId: String? = nil
    @Published var securitySummaries: [String: SecuritySummary] = [:]   // Per-host security summary for the overview card.
    @Published var securityScanning = Set<String>()
    @Published var firewallRequest: FirewallRequest? = nil   // Firewall view.
    @Published var portsHost: Host? = nil          // Open-ports sheet.
    /// Per-host Wake-on-LAN MAC/broadcast addresses, persisted in UserDefaults.
    @Published var wolMacs: [String: String] = (UserDefaults.standard.dictionary(forKey: "wolMacs") as? [String: String]) ?? [:]
    @Published var wolBroadcasts: [String: String] = (UserDefaults.standard.dictionary(forKey: "wolBroadcasts") as? [String: String]) ?? [:]
    @Published var infoNotice: String? = nil      // Success/information notice, e.g. power command sent.
    @Published var pendingPower: (host: Host, action: PowerCommands.Action)? = nil   // Pending reboot/shutdown confirmation.
    /// Per-host tmux session to attach when opening a terminal; empty disables automatic attachment.
    @Published var tmuxAuto: [String: String] = (UserDefaults.standard.dictionary(forKey: "tmuxAuto") as? [String: String]) ?? [:]
    func setTmuxAuto(hostId: String, name: String) {
        let n = name.trimmingCharacters(in: .whitespaces).filter { $0.isLetter || $0.isNumber || "-_.".contains($0) }
        if n.isEmpty { tmuxAuto[hostId] = nil } else { tmuxAuto[hostId] = n }
        UserDefaults.standard.set(tmuxAuto, forKey: "tmuxAuto")
    }
    @Published var showPalette = false            // Command-K command palette.
    @Published var showMultiRun = false           // Run commands on multiple servers.
    @Published var httpCheckHost: Host? = nil      // HTTP status-check sheet.
    /// Show custom quit confirmation for active background tasks when true.
    @Published var pendingQuitConfirm = false
    // Explicit menu-bar Quit ServerDock mode: confirmation stops tasks and exits regardless of the hide-to-menu-bar setting.
    @Published var pendingQuitForce = false
    /// Host ID currently undergoing SSH system-information probing.
    @Published var probingHosts: Set<String> = []

    @Published private(set) var hostGroups: [String] = []

    /// Existing groups, including RDP groups, offered by the add-host form.
    var groupNames: [String] {
        var seen = hostGroups
        for h in hosts where !h.isLocal && !seen.contains(h.group) { seen.append(h.group) }
        return seen
    }

    var sshGroupNames: [String] { hostGroups }

    private func registerHostGroup(_ name: String) {
        guard !hostGroups.contains(name) else { return }
        hostGroups.append(name)
        HostStore.saveHostGroups(hostGroups)
    }

    @discardableResult
    func addHostGroup(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !hostGroups.contains(trimmed) else { return false }
        registerHostGroup(trimmed)
        return true
    }

    @discardableResult
    func renameHostGroup(_ oldName: String, to newName: String) -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = hostGroups.firstIndex(of: oldName), !trimmed.isEmpty,
              (trimmed == oldName || !hostGroups.contains(trimmed)) else { return false }
        hostGroups[index] = trimmed
        for i in hosts.indices where !hosts[i].isLocal && !hosts[i].isRDP && hosts[i].group == oldName {
            hosts[i].group = trimmed
        }
        HostStore.saveHostGroups(hostGroups)
        HostStore.saveHostOrder(hosts)
        return true
    }

    func removeHostGroup(_ name: String) {
        guard hostGroups.contains(name) else { return }
        let fallback = String(localized: "Ungrouped")
        guard name != fallback else { return }
        for i in hosts.indices where !hosts[i].isLocal && !hosts[i].isRDP && hosts[i].group == name {
            hosts[i].group = fallback
        }
        hostGroups.removeAll { $0 == name }
        if hosts.contains(where: { !$0.isLocal && !$0.isRDP && $0.group == fallback }) {
            registerHostGroup(fallback)
        } else {
            HostStore.saveHostGroups(hostGroups)
        }
        HostStore.saveHostOrder(hosts)
    }

    func assignHost(_ id: String, toGroup name: String) {
        guard hostGroups.contains(name), let index = hosts.firstIndex(where: { $0.id == id && !$0.isRDP && !$0.isLocal }) else { return }
        hosts[index].group = name
        HostStore.saveHostOrder(hosts)
    }

    /// Reorder hosts within one group, sorting SSH and RDP independently.
    @discardableResult
    func moveHost(_ id: String, relativeTo targetId: String, after: Bool) -> Bool {
        guard id != targetId,
              let source = hosts.first(where: { $0.id == id }),
              let target = hosts.first(where: { $0.id == targetId }),
              source.isRDP == target.isRDP, source.group == target.group else { return false }
        let slots = hosts.indices.filter { hosts[$0].isRDP == source.isRDP && hosts[$0].group == source.group }
        var ordered = slots.map { hosts[$0] }
        guard let from = ordered.firstIndex(where: { $0.id == id }) else { return false }
        let moving = ordered.remove(at: from)
        guard let targetIndex = ordered.firstIndex(where: { $0.id == targetId }) else { return false }
        ordered.insert(moving, at: targetIndex + (after ? 1 : 0))
        guard slots.map({ hosts[$0].id }) != ordered.map(\.id) else { return false }
        for (slot, host) in zip(slots, ordered) { hosts[slot] = host }
        HostStore.saveHostOrder(hosts)
        return true
    }

    /// Move one position for context-menu/keyboard actions.
    @discardableResult
    func moveHost(_ id: String, by offset: Int) -> Bool {
        guard let source = hosts.first(where: { $0.id == id }) else { return false }
        let siblings = hosts.filter { $0.isRDP == source.isRDP && $0.group == source.group }
        guard let index = siblings.firstIndex(where: { $0.id == id }),
              siblings.indices.contains(index + offset) else { return false }
        return moveHost(id, relativeTo: siblings[index + offset].id, after: offset > 0)
    }

    func canMoveHost(_ id: String, by offset: Int) -> Bool {
        guard let source = hosts.first(where: { $0.id == id }) else { return false }
        let siblings = hosts.filter { $0.isRDP == source.isRDP && $0.group == source.group }
        guard let index = siblings.firstIndex(where: { $0.id == id }) else { return false }
        return siblings.indices.contains(index + offset)
    }

    /// Reorder groups while preserving within-group and opposite-protocol (SSH/RDP) order.
    @discardableResult
    func moveHostGroup(_ name: String, relativeTo targetName: String, isRDP: Bool, after: Bool) -> Bool {
        guard name != targetName else { return false }
        if !isRDP {
            guard let from = hostGroups.firstIndex(of: name), hostGroups.contains(targetName) else { return false }
            hostGroups.remove(at: from)
            guard let target = hostGroups.firstIndex(of: targetName) else { return false }
            hostGroups.insert(name, at: target + (after ? 1 : 0))
            HostStore.saveHostGroups(hostGroups)
            return true
        }
        let slots = hosts.indices.filter { hosts[$0].isRDP == isRDP }
        let current = slots.map { hosts[$0] }
        var names: [String] = []
        for host in current where !names.contains(host.group) { names.append(host.group) }
        guard let from = names.firstIndex(of: name) else { return false }
        names.remove(at: from)
        guard let targetIndex = names.firstIndex(of: targetName) else { return false }
        names.insert(name, at: targetIndex + (after ? 1 : 0))
        let ordered = names.flatMap { group in current.filter { $0.group == group } }
        guard current.map(\.id) != ordered.map(\.id) else { return false }
        for (slot, host) in zip(slots, ordered) { hosts[slot] = host }
        HostStore.saveHostOrder(hosts)
        return true
    }

    func addHost(from draft: HostDraft) {
        let conn = draft.buildConnection()
        let name = draft.name.trimmingCharacters(in: .whitespaces)
        let addr = "\(conn.user)@\(conn.host)"
        let id = "host-\(UUID().uuidString)"
        let newHost = Host(
            id: id,
            name: name,
            addr: addr,
            group: draft.resolvedGroup,
            status: .unknown,
            os: String(localized: "Unknown"),
            port: conn.port,
            ssh: conn,
            notes: draft.notes.trimmingCharacters(in: .whitespaces),
            colorHex: draft.colorHex
        )
        hosts.append(newHost)
        registerHostGroup(newHost.group)
        HostStore.saveHosts(hosts)
        checkReachability(newHost)
    }

    /// This Mac's synthetic host follows remote-host flows but cannot be persisted/edited/deleted/reordered.
    private static func makeLocalHost() -> Host {
        var conn = SSHConnection()
        conn.isLocal = true
        conn.user = NSUserName()
        conn.host = "localhost"
        conn.port = 0
        conn.authMethod = .key   // Bypass password flow; local hosts require no authentication.
        let mac = ProcessInfo.processInfo.hostName.split(separator: ".").first.map(String.init) ?? "localhost"
        return Host(id: Host.localId, name: String(localized: "Local Terminal"), addr: "\(NSUserName())@\(mac)",
                    group: "__local__", status: .online, os: "macOS", port: 0, ssh: conn, colorHex: "#1976D2")   // Unique group value prevents mixing with other hosts in moveHost.
    }

    /// Assign/persist automatic colors to legacy uncolored hosts once; subsequent colors remain fixed.
    private func assignMissingHostColors() {
        guard hosts.contains(where: { $0.colorHex == nil }) else { return }
        for i in hosts.indices where hosts[i].colorHex == nil {
            hosts[i].colorHex = HostPalette.autoAssign(existing: hosts)
        }
        HostStore.saveHostOrder(hosts)
    }

    func beginEditHost(_ host: Host) {
        editingHost = host
    }

    func presentExportHosts() {
        guard !AppLock.shared.isLocked else { return }
        let panel = NSSavePanel()
        panel.title = String(localized: "Export Servers")
        panel.message = String(localized: "Exports SSH, RDP and VNC settings, notes and sections. Passwords and private keys are not included. Keep this file private; commands and notes may contain sensitive information.")
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "ServerDock-servers.json"
        guard panel.runModal() == .OK, let url = panel.url, !AppLock.shared.isLocked else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            try HostArchive.encode(hosts: hosts, groups: hostGroups).write(to: url, options: .atomic)
        } catch {
            showHostTransferResult(title: String(localized: "Export Servers"), message: error.localizedDescription)
        }
    }

    func presentImportHosts() {
        guard !AppLock.shared.isLocked else { return }
        let panel = NSOpenPanel()
        panel.title = String(localized: "Import Servers")
        panel.message = String(localized: "Choose a ServerDock JSON export. Existing servers are kept and duplicates are skipped. Re-enter passwords and select private keys after importing on another Mac.")
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, !AppLock.shared.isLocked else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let archive = try HostArchive.decode(Data(contentsOf: url))
            let result = archive.merging(into: hosts, knownKeyIDs: Set(sshKeys.map(\.id)))
            hosts = result.hosts
            for group in archive.groups { _ = addHostGroup(group) }
            for host in archive.hosts where !host.isLocal && !host.isRDP { _ = addHostGroup(host.group) }
            if result.added > 0 { HostStore.saveHostOrder(hosts) }
            showHostTransferResult(title: String(localized: "Import Servers"),
                                   message: String(localized: "Imported \(result.added) servers (\(result.skipped) duplicates skipped). Passwords and private keys are not included."))
        } catch {
            showHostTransferResult(title: String(localized: "Import Servers"), message: error.localizedDescription)
        }
    }

    private func showHostTransferResult(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
    }

    /// Select iTerm2 profile-export JSON and restore its SSH profiles as hosts.
    func presentImportITerm() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Import from iTerm2")
        panel.message = String(localized: "Choose an iTerm2 profile JSON (Settings › Profiles › Other Actions › Save Profile as JSON)")
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        var candidates: [ITermImport.Candidate] = []
        for url in panel.urls {
            do {
                candidates += try ITermImport.parse(Data(contentsOf: url))
            } catch {
                keyOpError = "\(url.lastPathComponent): " + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                return
            }
        }
        let (added, skipped) = importITermHosts(candidates)
        hostImportNotice = candidates.isEmpty
            ? String(localized: "No SSH profiles were found in the selected file.")
            : String(localized: "Imported \(added) hosts from iTerm2 (\(skipped) duplicates skipped).")
    }

    /// Add candidates as SSH hosts, skipping existing user@host:port matches; return added/skipped counts.
    @discardableResult
    func importITermHosts(_ candidates: [ITermImport.Candidate]) -> (Int, Int) {
        var added = 0, skipped = 0
        var existing = Set(hosts.compactMap { h in h.ssh.map { "\($0.user)@\($0.host):\($0.port)" } })
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // Without -i, use ssh's default private key if available; otherwise ask for a password on each connection.
        let defaultKey = ["id_ed25519", "id_ecdsa", "id_rsa"].map { "\(home)/.ssh/\($0)" }
            .first { FileManager.default.fileExists(atPath: $0) }
        for c in candidates {
            var conn = SSHConnection()
            conn.user = c.user.isEmpty ? NSUserName() : c.user
            conn.host = c.host
            conn.port = c.port
            conn.useBuiltinSSH = false
            conn.sshCommand = c.sshCommand
            conn.initialCommand = c.initialCommand
            let key = c.keyPath.isEmpty ? defaultKey : (c.keyPath as NSString).expandingTildeInPath
            if let key {
                conn.authMethod = .key
                conn.keyPath = key
            } else {
                conn.authMethod = .ask
            }
            let sig = "\(conn.user)@\(conn.host):\(conn.port)"
            guard existing.insert(sig).inserted else { skipped += 1; continue }
            let host = Host(id: "host-\(UUID().uuidString)", name: c.name, addr: "\(conn.user)@\(conn.host)",
                            group: c.group, status: .unknown, os: String(localized: "Unknown"),
                            port: conn.port, ssh: conn, colorHex: HostPalette.autoAssign(existing: hosts))
            hosts.append(host)
            registerHostGroup(host.group)
            checkReachability(host)
            added += 1
        }
        if added > 0 { HostStore.saveHosts(hosts) }
        return (added, skipped)
    }

    /// Update the existing host from the edited form while preserving ID/status/system.
    func updateHost(id: String, from draft: HostDraft) {
        guard let idx = hosts.firstIndex(where: { $0.id == id }) else { return }
        let conn = draft.buildConnection()
        let old = hosts[idx]
        // Whether SSH connection settings changed: address, port, user, password, auth, key, encoding, algorithms, proxy, timeout, etc.
        // Name/note/group-only edits leave this false, avoiding redundant reachability probes, monitor reconnects, and state flicker.
        let connectionChanged = old.ssh != conn
        hosts[idx] = Host(
            id: id,
            name: draft.name.trimmingCharacters(in: .whitespaces),
            addr: "\(conn.user)@\(conn.host)",
            group: draft.resolvedGroup,
            status: old.status,
            os: old.os,
            port: conn.port,
            ssh: conn,
            notes: draft.notes.trimmingCharacters(in: .whitespaces),
            colorHex: draft.colorHex
        )
        // Preserve latency results; invalidate cached system information only when connection settings change,
        // so name/note/group edits do not trigger SSH probing or a flashing probing icon.
        hosts[idx].latencyMs = old.latencyMs
        hosts[idx].specs = connectionChanged ? nil : old.specs
        registerHostGroup(hosts[idx].group)
        HostStore.saveHosts(hosts)
        if connectionChanged {
            checkReachability(hosts[idx])
            hostMonitors[id]?.updateConnection(conn)   // Reconnect an active monitor with updated settings; otherwise do nothing.
        }
    }

    /// Add an RDP (Windows Remote Desktop) host.
    func addRDPHost(name: String, group: String, notes: String, rdp: RDPConnection, colorHex: String) {
        let id = "host-\(UUID().uuidString)"
        let newHost = Host(
            id: id,
            name: name,
            addr: rdp.protocolType == .vnc ? rdp.host : "\(rdp.user)@\(rdp.host)",
            group: group,
            status: .unknown,
            os: rdp.protocolType == .vnc ? "VNC" : "Windows",
            port: rdp.port,
            ssh: nil,
            notes: notes,
            rdp: rdp,
            colorHex: colorHex
        )
        hosts.append(newHost)
        HostStore.saveHosts(hosts)
        checkReachability(newHost)
    }

    /// Save VNC credentials only after successful login with Save selected; passwords go to Keychain.
    func setWOL(hostId: String, mac: String, broadcast: String) {
        let m = mac.trimmingCharacters(in: .whitespaces)
        if m.isEmpty { wolMacs[hostId] = nil } else { wolMacs[hostId] = m }
        let b = broadcast.trimmingCharacters(in: .whitespaces)
        if b.isEmpty { wolBroadcasts[hostId] = nil } else { wolBroadcasts[hostId] = b }
        UserDefaults.standard.set(wolMacs, forKey: "wolMacs"); UserDefaults.standard.set(wolBroadcasts, forKey: "wolBroadcasts")
    }

    /// Send a magic packet, then poll until the awakened server appears online in overview.
    func wake(_ host: Host) {
        guard let raw = wolMacs[host.id], let mac = WakeOnLAN.parseMAC(raw) else { keyOpError = String(localized: "Enter this server's MAC address first."); return }
        do {
            _ = try WakeOnLAN.send(mac: mac, broadcast: wolBroadcasts[host.id] ?? "")
            infoNotice = String(localized: "Wake packet sent to \(WakeOnLAN.format(mac)). The server should be reachable in a minute or two.")
            Task { @MainActor in
                for _ in 0..<24 {   // Poll every five seconds for roughly two minutes.
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    self.checkReachability(host)
                    if self.hosts.first(where: { $0.id == host.id })?.status == .online { return }
                }
            }
        } catch { keyOpError = error.localizedDescription }
    }

    /// Execute confirmed reboot/shutdown; connection soon drops. Requires root or passwordless sudo.
    func performPower(_ host: Host, _ action: PowerCommands.Action) {
        guard let ssh = host.ssh else { return }
        Task { @MainActor in
            let r = await RemoteFS(ssh).run(PowerCommands.script(action), timeout: 20)
            let out = String(decoding: r.data, as: UTF8.self)
            if out.contains("__SCHEDULED__") {
                infoNotice = action == .reboot ? String(localized: "\(host.name) is rebooting. The connection will drop for a minute.") : String(localized: "\(host.name) is shutting down. Use Wake-on-LAN or the power button to start it again.")
                Task { for _ in 0..<6 { try? await Task.sleep(nanoseconds: 5_000_000_000); self.checkReachability(host) } }
            } else if out.contains("__NOSUDO__") {
                keyOpError = String(localized: "This account isn't root and has no passwordless sudo, so it can't reboot or shut down the server.")
            } else {
                keyOpError = (out + String(decoding: r.stderr, as: UTF8.self)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    func saveVNCCredentials(hostId: String, user: String, password: String) {
        guard let i = hosts.firstIndex(where: { $0.id == hostId }), hosts[i].rdp != nil else { return }
        if !user.isEmpty { hosts[i].rdp?.user = user }
        hosts[i].rdp?.password = password
        HostStore.saveHosts(hosts)
    }

    /// Update the RDP host from its edited form while preserving ID/status.
    func updateRDPHost(id: String, name: String, group: String, notes: String, rdp: RDPConnection, colorHex: String) {
        guard let idx = hosts.firstIndex(where: { $0.id == id }) else { return }
        let old = hosts[idx]
        hosts[idx] = Host(
            id: id,
            name: name,
            addr: rdp.protocolType == .vnc ? rdp.host : "\(rdp.user)@\(rdp.host)",
            group: group,
            status: old.status,
            os: rdp.protocolType == .vnc ? "VNC" : "Windows",
            port: rdp.port,
            ssh: nil,
            notes: notes,
            rdp: rdp,
            colorHex: colorHex
        )
        HostStore.saveHosts(hosts)
        checkReachability(hosts[idx])
    }

    /// Duplicate connection settings, notes, color, group, and password immediately after the original as "name copy".
    func duplicateHost(_ host: Host) {
        guard !host.isLocal, let idx = hosts.firstIndex(where: { $0.id == host.id }) else { return }
        let suffix = String(localized: "copy")
        let copy = Host(
            id: "host-\(UUID().uuidString)",
            name: "\(host.name) \(suffix)",
            addr: host.addr,
            group: host.group,
            status: .unknown,
            os: host.os,
            port: host.port,
            ssh: host.ssh,
            notes: host.notes,
            specs: host.specs,
            rdp: host.rdp,
            colorHex: host.colorHex
        )
        hosts.insert(copy, at: idx + 1)
        HostStore.saveHosts(hosts)
        checkReachability(copy)
    }

    /// Request host deletion, showing confirmation according to settings or deleting immediately when disabled.
    func requestDeleteHost(_ host: Host) {
        if AppSettings.shared.confirmHostDelete {
            pendingHostDelete = host
        } else {
            deleteHost(host.id)
        }
    }
    func confirmHostDelete() {
        if let h = pendingHostDelete { deleteHost(h.id) }
        pendingHostDelete = nil
    }
    func cancelHostDelete() { pendingHostDelete = nil }

    func deleteHost(_ id: String) {
        if AppSettings.shared.startupBehavior == .host && AppSettings.shared.startupHostId == id {
            AppSettings.shared.startupHostId = ""
            AppSettings.shared.startupBehavior = .welcome
        }
        // Stop the host's forwarding tunnels and clear rules before deletion so no ssh -N remains running.
        forwardManagers[id]?.stopAll()
        forwardManagers.removeValue(forKey: id)
        if forwardFilterHostId == id { forwardFilterHostId = nil }
        forwardCancellables.removeValue(forKey: id)
        if forwards.contains(where: { $0.hostId == id }) {
            forwards.removeAll { $0.hostId == id }
            HostStore.saveForwards(forwards)
        }
        hosts.removeAll { $0.id == id }
        sessions.removeAll { $0.hostId == id }
        if favorites.removeValue(forKey: id) != nil { HostStore.saveFavorites(favorites) }
        if recentFiles.removeValue(forKey: id) != nil { HostStore.saveRecents(recentFiles) }
        if hostLogs.removeValue(forKey: id) != nil { saveHostLogs() }
        if let items = httpChecks.removeValue(forKey: id) { items.forEach { httpResults[$0.id] = nil }; saveHTTPChecks() }
        HostKeychain.delete(id)
        HostStore.saveHosts(hosts)
        HostStore.saveSessions(sessions)
    }

    // ---------- Storage sites (SMB / WebDAV / S3) ----------

    /// Deduplicated site groups in appearance order for edit-form selection.
    var siteGroupNames: [String] {
        var seen: [String] = []
        for s in sites where !s.group.isEmpty && !seen.contains(s.group) { seen.append(s.group) }
        return seen
    }

    func site(_ id: String?) -> Site? {
        guard let id else { return nil }
        return sites.first { $0.id == id }
    }

    /// Site corresponding to tab-group key site:<id>.
    func site(forTabKey key: String?) -> Site? { site(Site.siteId(fromTabKey: key)) }

    func addSite(_ site: Site, secret: String) {
        sites.append(site)
        SiteKeychain.set(site.id, secret)
        SiteStore.save(sites)
    }

    func updateSite(_ site: Site, secret: String) {
        guard let i = sites.firstIndex(where: { $0.id == site.id }) else { return }
        sites[i] = site
        SiteKeychain.set(site.id, secret)
        SiteStore.save(sites)
        for t in tabs where t.kind == .site && t.hostId == site.tabKey {   // Update open-tab titles only; changed connection settings apply on reopening.
            if let ti = tabs.firstIndex(where: { $0.id == t.id }) { tabs[ti].title = site.name }
        }
    }

    func duplicateSite(_ site: Site) {
        var copy = Site(name: site.name + " " + String(localized: "Copy"), kind: site.kind, host: site.host, port: site.port,
                        useTLS: site.useTLS, username: site.username, path: site.path, region: site.region,
                        pathStyle: site.pathStyle, insecureTLS: site.insecureTLS, group: site.group)
        copy.name = copy.name.trimmingCharacters(in: .whitespaces)
        addSite(copy, secret: SiteKeychain.secret(site.id))
    }

    func deleteSite(_ site: Site) {
        closeTabs(tabs.filter { $0.kind == .site && $0.hostId == site.tabKey }.map(\.id))
        sites.removeAll { $0.id == site.id }
        SiteKeychain.remove(site.id)
        SiteStore.save(sites)
    }

    /// Open a site tab, or select it if already open.
    func openSite(_ site: Site) {
        if let existing = tabs.first(where: { $0.kind == .site && $0.hostId == site.tabKey }) {
            selectTab(existing.id)
            return
        }
        if site.kind == .sftp {   // Verify SFTP server fingerprints before connecting.
            Task { @MainActor in
                guard await verifyFingerprint(host: site.host.trimmingCharacters(in: .whitespaces), port: site.port > 0 ? site.port : 22) else { return }
                if tabs.contains(where: { $0.kind == .site && $0.hostId == site.tabKey }) { return }   // Prevent duplicate clicks during verification.
                openSiteTab(site)
            }
            return
        }
        openSiteTab(site)
    }

    private func openSiteTab(_ site: Site) {
        let id = addTab(.site, title: site.name, hostId: site.tabKey)
        let session = SiteSession(site: site)
        siteSessions[id] = session
        session.start()
    }

    func siteSession(for tabId: Int) -> SiteSession? { siteSessions[tabId] }

    /// Mount SMB/WebDAV for Finder access and reveal it there.
    func mountSiteInFinder(_ site: Site) {
        Task { @MainActor in
            do { try await FinderMount.mountAndReveal(site, password: SiteKeychain.secret(site.id)) }
            catch { keyOpError = error.localizedDescription }
        }
    }

    // ---------- SSH key library ----------
    /// Generate a key pair, storing private material in Keychain and metadata in JSON.
    func generateKey(name: String, type: SSHKeyType, comment: String, passphrase: String) {
        do {
            let g = try KeyTools.generate(type: type, comment: comment, passphrase: passphrase)
            let key = SSHKey(name: name.isEmpty ? String(localized: "Untitled Key") : name, type: type,
                             publicKey: g.publicKey, fingerprint: g.fingerprint,
                             comment: comment, hasPassphrase: !passphrase.isEmpty)
            KeyKeychain.set(key.id, g.privateKey)
            sshKeys.append(key)
            KeyStore.save(sshKeys)
        } catch {
            keyOpError = (error as? KeyError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Choose an existing private key to import.
    func presentImportKey() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Import Private Key")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true   // Show hidden files for private keys under ~/.ssh.
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = importKey(from: url)
    }

    /// Import a private file into the Keychain-backed key library with metadata and return the new key.
    /// MAS AddHostView imports selected external keys and uses keyId, avoiding sandbox restrictions on arbitrary paths.
    @discardableResult
    func importKey(from url: URL) -> SSHKey? {
        do {
            let pem = try String(contentsOf: url, encoding: .utf8)
            let info = try KeyTools.importInfo(privatePath: url.path)
            let key = SSHKey(name: url.deletingPathExtension().lastPathComponent,
                             type: info.type, publicKey: info.publicKey,
                             fingerprint: info.fingerprint, comment: info.comment,
                             hasPassphrase: info.hasPassphrase)
            KeyKeychain.set(key.id, pem)
            sshKeys.append(key)
            KeyStore.save(sshKeys)
            return key
        } catch {
            keyOpError = (error as? KeyError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }

    func deleteKey(_ key: SSHKey) {
        sshKeys.removeAll { $0.id == key.id }
        KeyKeychain.remove(key.id)
        KeyMaterializer.remove(key.id)   // Remove materialized private-key working files from disk.
        KeyStore.save(sshKeys)
        if detailKey?.id == key.id { detailKey = nil }
    }

    func renameKey(_ id: String, to name: String) {
        guard let i = sshKeys.firstIndex(where: { $0.id == id }) else { return }
        sshKeys[i].name = name.isEmpty ? sshKeys[i].name : name
        KeyStore.save(sshKeys)
    }

    /// Copy the public key for pasting into the server's authorized_keys.
    func copyPublicKey(_ key: SSHKey) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(key.publicKey, forType: .string)
    }

    // ---------- Snippets ----------
    /// Existing snippet groups, deduplicated in original order for group selection.
    var snippetGroupNames: [String] {
        var seen: [String] = []
        for s in snippets {
            let g = s.group.trimmingCharacters(in: .whitespaces)
            if !g.isEmpty && !seen.contains(g) { seen.append(g) }
        }
        return seen
    }

    func addSnippet(name: String, content: String, group: String) {
        snippets.append(Snippet(name: name.isEmpty ? String(localized: "Untitled Script") : name, content: content, group: group))
        SnippetStore.save(snippets)
    }

    func updateSnippet(_ id: String, name: String, content: String, group: String) {
        guard let i = snippets.firstIndex(where: { $0.id == id }) else { return }
        snippets[i].name = name.isEmpty ? snippets[i].name : name
        snippets[i].content = content
        snippets[i].group = group
        snippets[i].updatedAt = Date()
        SnippetStore.save(snippets)
    }

    func deleteSnippet(_ snippet: Snippet) {
        snippets.removeAll { $0.id == snippet.id }
        SnippetStore.save(snippets)
        if editingSnippet?.id == snippet.id { editingSnippet = nil }
    }

    /// Copy snippet content to the clipboard.
    func copySnippet(_ snippet: Snippet) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(snippet.content, forType: .string)
    }

    /// Default snippet action for Play/double-click follows settings: run, insert, or ask.
    /// Explicit Run/Insert context-menu actions bypass this default-action flow.
    func triggerSnippet(_ snippet: Snippet) {
        switch AppSettings.shared.snippetAction {
        case .insert: sendSnippet(snippet, run: false)
        case .run:    sendSnippet(snippet, run: true)
        case .ask:    pendingSnippetAction = snippet
        }
    }

    /// For Insert/Run choices, remember=true saves the preference before sending so later uses need no prompt.
    func resolveSnippetAction(_ snippet: Snippet, run: Bool, remember: Bool) {
        pendingSnippetAction = nil
        if remember { AppSettings.shared.snippetAction = run ? .run : .insert }
        sendSnippet(snippet, run: run)
    }

    func cancelSnippetAction() { pendingSnippetAction = nil }

    /// Send to the current terminal, first prompting for any {{variables}}.
    /// run=true appends a newline to execute; false inserts at the prompt for the user to confirm with Enter.
    func sendSnippet(_ snippet: Snippet, run: Bool) {
        let vars = Snippet.variableNames(in: snippet.content)
        if vars.isEmpty {
            deliverSnippet(snippet.content, run: run)
        } else {
            pendingSnippetRun = SnippetRunRequest(snippet: snippet, variables: vars, run: run)
        }
    }

    func submitSnippetRun(_ values: [String: String]) {
        guard let req = pendingSnippetRun else { return }
        pendingSnippetRun = nil
        deliverSnippet(Snippet.substitute(req.snippet.content, values: values), run: req.run)
    }

    func cancelSnippetRun() { pendingSnippetRun = nil }

    /// Whether a terminal tab exists for enabling snippet execution.
    /// Check TabsModel tab existence only, allowing the observing panel to refresh immediately when terminals open/close.
    /// Do not depend on terminal views being instantiated in the non-@Published terminals dictionary;
    /// otherwise opening a terminal after visiting Snippets would not refresh the Run button until returning to the module.
    var hasSnippetTarget: Bool { snippetTargetTabId() != nil }

    // MARK: Script tabs (fill variables, run/copy in the main area)
    static let scriptsKey = "__scripts__"
    private var scriptSessions: [Int: ScriptSession] = [:]

    func scriptSession(for tabId: Int) -> ScriptSession? { scriptSessions[tabId] }

    /// One tab per script, storing its ID in tab.filePath; preferHost preselects its terminal.
    func openScript(_ snippet: Snippet, preferHost: String? = nil) {
        var tabId: Int
        if let t = tabs.first(where: { $0.kind == .script && $0.filePath == snippet.id }) {
            tabId = t.id; activeTabId = t.id
        } else {
            tabId = addTab(.script, title: snippet.name, hostId: Self.scriptsKey, filePath: snippet.id)
            scriptSessions[tabId] = ScriptSession(snippetId: snippet.id)
        }
        if let h = preferHost, let term = tabs.first(where: { $0.kind == .terminal && $0.hostId == h }) { scriptSessions[tabId]?.targetTabId = term.id }
    }

    func closeScriptTab(_ snippetId: String) {
        closeTabs(tabs.filter { $0.kind == .script && $0.filePath == snippetId }.map(\.id))
    }

    func isScriptActive(_ snippetId: String) -> Bool {
        guard let id = activeTabId, let t = tabs.first(where: { $0.id == id }) else { return false }
        return t.kind == .script && t.filePath == snippetId
    }

    /// Open terminals available for scripts, numbered when several belong to the same server.
    var scriptTargets: [ScriptTarget] {
        let terms = tabs.filter { $0.kind == .terminal }
        var count: [String: Int] = [:]
        let names = terms.map { t in host(t.hostId)?.name ?? String(localized: "Local") }
        for n in names { count[n, default: 0] += 1 }
        var seen: [String: Int] = [:]
        return zip(terms, names).map { t, n in
            seen[n, default: 0] += 1
            return ScriptTarget(id: t.id, title: (count[n] ?? 0) > 1 ? "\(n) (\(seen[n]!))" : n)
        }
    }

    /// Send a script to the terminal tab, optionally clearing with Ctrl-L first; return false if not ready.
    @discardableResult
    func sendScript(_ text: String, run: Bool, clearFirst: Bool, tabId: Int) -> Bool {
        guard terminals[tabId] != nil || termDrivers[tabId] != nil else { return false }
        let line = run ? text + "\n" : text
        if clearFirst {
            sendTerminalText(tabId, "\u{0c}")
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 150_000_000)
                self?.sendTerminalText(tabId, line)
            }
        } else { sendTerminalText(tabId, line) }
        return true
    }

    func duplicateSnippet(_ s: Snippet) {
        addSnippet(name: s.name + " " + String(localized: "Copy"), content: s.content, group: s.group)
    }

    /// Choose the active terminal tab first, otherwise the sole open terminal tab.
    private func snippetTargetTabId() -> Int? {
        if let id = activeTabId, tabs.first(where: { $0.id == id })?.kind == .terminal { return id }
        // When focus is in the editor/main area, target the current server's bottom-panel terminal.
        if let key = tabsModel.activeGroupKey, let t = tabsModel.terminalTab(inGroup: key) { return t.id }
        let termTabs = tabs.filter { $0.kind == .terminal }
        return termTabs.count == 1 ? termTabs[0].id : nil
    }

    private func deliverSnippet(_ text: String, run: Bool) {
        guard let id = snippetTargetTabId(), let tv = terminals[id] else {
            snippetNotice = String(localized: "Open and switch to a terminal before running a script.")
            return
        }
        let line = run ? text + "\n" : text
        // Inject SSH input through the libssh2 driver; local input uses LocalProcessTerminalView directly.
        if let driver = termDrivers[id] { driver.sendText(line) } else { tv.send(txt: line) }
    }

    // ---------- Session history ----------
    /// Record and persist one session event.
    func recordSession(hostId: String, kind: SessionKind, detail: String) {
        sessions.append(SessionEvent(hostId: hostId, kind: kind, detail: detail, timestamp: Date()))
        // Retain at most 50 entries per host to bound history growth.
        let perHost = Dictionary(grouping: sessions, by: \.hostId)
        var trimmed: [SessionEvent] = []
        for (_, evs) in perHost {
            trimmed += evs.sorted { $0.timestamp > $1.timestamp }.prefix(50)
        }
        sessions = trimmed
        HostStore.saveSessions(sessions)
    }

    /// Recent sessions for one host, newest first, limited to limit entries.
    func recentSessions(for hostId: String, limit: Int = 6) -> [SessionEvent] {
        sessions
            .filter { $0.hostId == hostId }
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(limit)
            .map { $0 }
    }

    // ---------- Live monitoring ----------
    // One monitor per open host, retained until all its tabs close; stop when leaving, with no files deployed on the server.
    private var hostMonitors: [String: HostMonitor] = [:]
    // Alert debounce tracks consecutive out-of-range samples and last alert time by hostId|metric.
    private var alertStreak: [String: Int] = [:]
    private var alertLast: [String: Date] = [:]

    private static let alertThreshold = 90.0          // Percentage threshold.
    private static let alertSustainFrames = 15         // Consecutive samples, approximately 30 seconds at 2 seconds/sample.
    private static let alertCooldown: TimeInterval = 300

    private var monitorStartWork: [String: DispatchWorkItem] = [:]   // Debounce until the overview remains selected before sampling.
    private var monitorStopWork: [String: DispatchWorkItem] = [:]    // Delay stopping after leaving; cancel if returning quickly to avoid tab-switch reconnection churn.
    private static let monitorDebounce: TimeInterval = 0.4           // Do not start until the selected host remains visible for this duration.
    private static let monitorStopGrace: TimeInterval = 4            // Grace period retaining the monitor connection after leaving.

    /// Host ID requiring live status-bar metrics, keeping monitoring alive even without an overview tab.
    var statusBarMonitorHostId: String?

    /// Status-bar server: active SSH host with an existing terminal/files/editor tab.
    var statusBarHost: Host? {
        guard let id = activeTabId, let tab = tabs.first(where: { $0.id == id }),
              let host = host(tab.hostId), host.ssh != nil else { return nil }
        let connected = tabs.contains {
            $0.groupKey == tab.groupKey && ($0.kind == .terminal || $0.kind == .files || $0.kind == .editor)
        }
        return connected ? host : nil
    }

    /// Active VNC/RDP session for the bottom status bar.
    var activeRemoteDesktopSession: RDPSession? {
        guard let id = activeTabId, let tab = tabs.first(where: { $0.id == id }), tab.kind == .rdp else { return nil }
        return rdpSessions[id]
    }

    var showsStatusBar: Bool { statusBarHost != nil || activeRemoteDesktopSession != nil }

    /// Number of running forwarding rules for this server.
    func activeForwardCount(hostId: String) -> Int {
        forwardManagers[hostId]?.statuses.values.filter(\.isRunning).count ?? 0
    }

    /// Get/lazily create a host monitor without starting it; sampling runs only for the active overview, via overviewAppeared.
    func hostMonitor(for host: Host) -> HostMonitor {
        if let m = hostMonitors[host.id] { return m }
        let m = HostMonitor(ssh: host.ssh ?? SSHConnection())
        let hid = host.id
        m.onSample = { [weak self] metrics in self?.evaluateAlerts(hostId: hid, metrics) }
        m.onAuthenticationFailure = { [weak self] in self?.requestMonitorPassword(hostId: hid) }
        hostMonitors[host.id] = m
        return m
    }

    /// Debounce overview activation; leaving before the delay cancels startup so rapid host switching does not launch many monitors.
    /// Only the host the user actually remains on should sample.
    func overviewAppeared(_ host: Host) {
        monitorStopWork[host.id]?.cancel()                 // Returning cancels pending delayed stop and keeps the connection without reconnecting.
        monitorStopWork.removeValue(forKey: host.id)
        // Skip sampling before ask-mode credentials are entered, showing placeholders instead of repeated background SSH auth failures/hangs.
        if !(host.ssh?.hasUsableCredentials ?? true) { return }
        monitorStartWork[host.id]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.monitorStartWork.removeValue(forKey: host.id)
            let m = self.hostMonitor(for: host)
            m.updateConnection(self.host(host.id)?.ssh ?? host.ssh ?? SSHConnection())   // Refresh with the live password to avoid stale/incorrect cached credentials.
            m.start()   // start is idempotent if already running.
        }
        monitorStartWork[host.id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.monitorDebounce, execute: work)
    }

    /// On overview deactivation, cancel pending startup and stop after the grace period; returning quickly cancels the stop.
    /// Retain monitoring while the status bar displays this server's live metrics.
    func overviewDisappeared(_ hostId: String) {
        if statusBarMonitorHostId == hostId { return }
        monitorStartWork[hostId]?.cancel()
        monitorStartWork.removeValue(forKey: hostId)
        monitorStopWork[hostId]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.monitorStopWork.removeValue(forKey: hostId)
            self?.hostMonitors[hostId]?.stop()
        }
        monitorStopWork[hostId] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.monitorStopGrace, execute: work)
    }

    /// Release the monitor and alert state completely once no tabs remain for the host.
    private func stopMonitorIfUnused(_ hostId: String) {
        guard !tabs.contains(where: { $0.hostId == hostId }) else { return }
        monitorStartWork[hostId]?.cancel()
        monitorStartWork.removeValue(forKey: hostId)
        monitorStopWork[hostId]?.cancel()
        monitorStopWork.removeValue(forKey: hostId)
        hostMonitors[hostId]?.stop()
        hostMonitors.removeValue(forKey: hostId)
        alertStreak = alertStreak.filter { !$0.key.hasPrefix(hostId + "|") }
        alertLast = alertLast.filter { !$0.key.hasPrefix(hostId + "|") }
    }

    // ---------- Port forwarding ----------
    // One runtime manager per host; tunnels persist in the background until explicitly stopped or app exit.
    private var forwardManagers: [String: ForwardManager] = [:]
    // Bridge low-frequency manager start/stop/failure changes to this object for forwarding dots/background-center refresh.
    // Forwarding changes are sparse unlike per-frame transfer progress, so forwarding objectWillChange does not cause redraw storms.
    private var forwardCancellables: [String: AnyCancellable] = [:]

    /// Get/lazily create a host's forwarding manager.
    func forwardManager(for host: Host) -> ForwardManager {
        if let m = forwardManagers[host.id] { return m }
        let m = ForwardManager(ssh: host.ssh ?? SSHConnection())
        forwardCancellables[host.id] = m.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
        forwardManagers[host.id] = m
        return m
    }

    /// All active forwarding tunnels, transfers, and extraction for the bottom-left background center.
    /// Include activity objects so rows observe live state/progress directly; views resolve hostId grouping/names.
    var backgroundActivities: [BackgroundActivity] {
        var out: [BackgroundActivity] = []
        for rule in forwards {
            if let m = forwardManagers[rule.hostId], m.status(rule.id).isRunning {
                out.append(BackgroundActivity(id: "fwd-\(rule.id.uuidString)", hostId: rule.hostId,
                                              fallbackHostName: "", isFinished: false,
                                              payload: .forward(rule: rule, manager: m)))
            }
        }
        for t in transfers {
            let finished = (t.phase == .done || t.phase == .cancelled)
            out.append(BackgroundActivity(id: "xfer-\(t.id.uuidString)", hostId: t.hostId,
                                          fallbackHostName: t.hostName, isFinished: finished,
                                          payload: .transfer(t)))
        }
        if let e = extractTask {
            let finished: Bool = { switch e.phase { case .done, .failed: return true; default: return false } }()
            out.append(BackgroundActivity(id: "ext-\(e.id.uuidString)", hostId: e.hostId,
                                          fallbackHostName: e.hostName, isFinished: finished,
                                          payload: .extract(e)))
        }
        return out
    }

    /// Remove a transfer record from the center, first canceling it if running/queued/paused.
    func removeTransfer(_ id: UUID) {
        if let t = transfers.first(where: { $0.id == id }),
           t.phase == .running || t.phase == .queued || t.phase == .paused {
            t.cancel()
        }
        transfers.removeAll { $0.id == id }
        if focusedTransferId == id { focusedTransferId = nil }
        pumpTransferQueue()
    }
    /// Clear a finished extraction record.
    func clearExtract() { extractTask = nil; showExtractDialog = false }

    /// Whether extraction is completed/failed.
    private var isExtractFinished: Bool {
        guard let e = extractTask else { return false }
        switch e.phase { case .done, .failed: return true; default: return false }
    }
    /// Whether the center has clearable completed/canceled transfers or finished extraction.
    var hasFinishedBackground: Bool {
        transfers.contains { $0.phase == .done || $0.phase == .cancelled } || isExtractFinished
    }
    /// Clear all finished background records without affecting active/queued transfers or running tunnels.
    func clearFinishedBackground() {
        let removed = Set(transfers.filter { $0.phase == .done || $0.phase == .cancelled }.map { $0.id })
        transfers.removeAll { removed.contains($0.id) }
        if let id = focusedTransferId, removed.contains(id) { focusedTransferId = nil }
        if isExtractFinished { extractTask = nil; showExtractDialog = false }
        pumpTransferQueue()
    }

    /// Background count: running tunnels, active/queued transfers, and active extraction.
    var activeBackgroundCount: Int {
        var n = 0
        for rule in forwards where forwardManagers[rule.hostId]?.status(rule.id).isRunning == true { n += 1 }
        n += transfers.filter { $0.phase == .running || $0.phase == .queued || $0.phase == .paused }.count
        if extractTask?.phase == .running { n += 1 }
        return n
    }

    /// Unhandled background failures include failed transfer files, extraction failure, or fatal forwarding errors; used by the red pulse.
    /// Failure records keep the indicator red until cleared/retried, providing a natural acknowledgment point.
    var hasBackgroundFailure: Bool {
        if transfers.contains(where: { $0.hasFailure }) { return true }
        if case .failed = extractTask?.phase { return true }
        if forwardManagers.values.contains(where: { $0.hasFatalFailure }) { return true }
        return false
    }

    /// Any running forwarding tunnel is represented by the green center pulse instead of the numeric badge.
    var hasRunningForward: Bool {
        forwards.contains { forwardManagers[$0.hostId]?.status($0.id).isRunning == true }
    }

    /// Numeric badge counts active/queued/paused transfers plus active extraction, excluding forwarding.
    var nonForwardActiveCount: Int {
        var n = transfers.filter { $0.phase == .running || $0.phase == .queued || $0.phase == .paused }.count
        if extractTask?.phase == .running { n += 1 }
        return n
    }

    /// Host forwarding rules in creation order.
    func forwardRules(for hostId: String) -> [ForwardRule] {
        forwards.filter { $0.hostId == hostId }
    }

    /// Read-only running-tunnel check without creating a manager, safe inside view body.
    func hasRunningForward(hostId: String) -> Bool {
        guard let m = forwardManagers[hostId] else { return false }
        return forwards.contains { $0.hostId == hostId && m.status($0.id).isRunning }
    }

    static let portForwardsKey = "__portforwards__"

    var forwardingHosts: [Host] {
        hosts.filter { !$0.isLocal && !$0.isRDP && $0.ssh != nil }
    }

    func openAllForwards() {
        section = .portForwards
        if let tab = tabs.first(where: { $0.kind == .portForwards }) {
            activeTabId = tab.id
        } else {
            addTab(.portForwards, title: String(localized: "Port Forwarding"), hostId: Self.portForwardsKey)
        }
    }

    /// Open a host's forwarding manager.
    func openForwardPanel(_ host: Host) {
        requireAuth(host) { [weak self] in self?.proceedForward(host.id) }
    }

    /// Unverified ask-mode hosts first show connection verification. Verified ask-mode/password/key hosts open forwarding directly without another prompt.
    private func proceedForward(_ hostId: String) {
        guard let host = hosts.first(where: { $0.id == hostId }) else { return }
        if host.ssh?.authMethod == .ask, !askVerifiedHosts.contains(hostId) {
            connectThen(hostId, hint: String(localized: "Opening port forwarding…")) { [weak self] in
                self?.forwardPanelHost = self?.hosts.first(where: { $0.id == hostId })
            }
        } else {
            forwardPanelHost = host
        }
    }

    /// Dismiss all sheets (settings/add-host/forwarding/etc.) before quitting/hiding:
    /// sheets cover the ContentView quit overlay and their window-modal state may prevent termination.
    func dismissAllSheets() {
        showSettings = false
        showAddHost = false
        editingHost = nil
        showAddRDPHost = false
        editingRDPHost = nil
        forwardPanelHost = nil
    }

    /// Skip forwarding deletion confirmation only for this app run after Don't ask again is checked.
    /// Prompt again on restart; deliberately keep this temporary preference outside persistent settings.
    var skipForwardDeleteConfirm = false

    /// Start/stop a rule, recording a forwarding session when started.
    func toggleForward(_ rule: ForwardRule) {
        guard let host = hosts.first(where: { $0.id == rule.hostId }) else { return }
        let m = forwardManager(for: host)
        if m.status(rule.id).isRunning {
            m.stop(rule.id)
        } else {
            requireAuth(host) { [weak self] in
                guard let self else { return }
                if host.ssh?.authMethod == .ask, !self.askVerifiedHosts.contains(host.id) {
                    self.connectThen(host.id, hint: String(localized: "Opening port forwarding…")) { [weak self] in
                        self?.startForward(rule.id)
                    }
                } else {
                    self.startForward(rule.id)
                }
            }
        }
    }

    private func startForward(_ id: UUID) {
        guard let rule = forwards.first(where: { $0.id == id }),
              let host = host(rule.hostId), rule.validationError == nil else { return }
        let manager = forwardManager(for: host)
        guard !manager.status(id).isRunning else { return }
        manager.start(rule, ssh: host.ssh)
        recordSession(hostId: host.id, kind: .portForward, detail: rule.summary)
    }

    /// Add/update a rule by ID.
    func saveForwardRule(_ rule: ForwardRule) {
        if let i = forwards.firstIndex(where: { $0.id == rule.id }) { forwards[i] = rule }
        else { forwards.append(rule) }
        HostStore.saveForwards(forwards)
    }

    /// Delete a rule after stopping its tunnel, then persist the removal.
    func deleteForwardRule(_ rule: ForwardRule) {
        if let host = hosts.first(where: { $0.id == rule.hostId }) {
            forwardManager(for: host).stop(rule.id)
        }
        forwards.removeAll { $0.id == rule.id }
        HostStore.saveForwards(forwards)
    }

    /// Notify only for sustained metric threshold violations after cooldown. Resolve the live host by ID so renamed hosts use their new name.
    private func evaluateAlerts(hostId: String, _ m: HostMetrics) {
        guard AppSettings.shared.resourceAlerts, let host = hosts.first(where: { $0.id == hostId }) else { return }
        checkAlert(host: host, metric: "cpu", label: String(localized: "CPU Usage"), value: m.cpuPercent)
        checkAlert(host: host, metric: "mem", label: String(localized: "Memory Usage"), value: m.memTotalKB > 0 ? m.memPercent : nil)
        checkAlert(host: host, metric: "disk", label: String(localized: "Disk Usage"), value: m.disks.map(\.percent).max())   // Most-full partition.
    }

    private func checkAlert(host: Host, metric: String, label: String, value: Double?) {
        let key = host.id + "|" + metric
        guard let v = value, v >= Self.alertThreshold else { alertStreak[key] = 0; return }
        let n = (alertStreak[key] ?? 0) + 1
        alertStreak[key] = n
        guard n >= Self.alertSustainFrames else { return }
        alertStreak[key] = 0   // Reset accumulation to prevent repeated triggers during cooldown.
        let last = alertLast[key] ?? .distantPast
        guard Date().timeIntervalSince(last) >= Self.alertCooldown else { return }
        alertLast[key] = Date()
        Notifier.notify(title: String(localized: "\(host.name) Resource Alert"),
                        body: String(localized: "\(label) \(Int(v))%, for about \(Self.alertSustainFrames * 2) s"))
    }

    // ---------- System-information probing ----------
    /// One-shot remote script outputs key=value lines. MEM/DISK/VRAM use raw bytes, which the client formats in base 1000
    /// to avoid varying free -h/df -h Gi/Mi units. DISK contains two byte counts: used and total.
    /// VRAM/GPU are nonempty only when an NVIDIA GPU/nvidia-smi is available.
    private static let probeScript = """
    [ ! -r /etc/os-release ] || . /etc/os-release
    if [ "$(uname -s)" = Darwin ]; then
      echo "OS=macOS $(sw_vers -productVersion 2>/dev/null)"
      echo "MODEL=$(sysctl -n hw.model 2>/dev/null)"
      echo "CHIP=$(sysctl -n machdep.cpu.brand_string 2>/dev/null)"
    else
      echo "OS=${PRETTY_NAME:-$(uname -sr)}"
    fi
    echo "CORES=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null)"
    mem=$(awk '/MemTotal/{printf "%.0f", $2*1024; exit}' /proc/meminfo 2>/dev/null)
    [ -z "$mem" ] && mem=$(sysctl -n hw.memsize 2>/dev/null)
    echo "MEM=$mem"
    disk_root=/
    [ "$(uname -s)" != Darwin ] || disk_root=/System/Volumes/Data
    echo "DISK=$(df -k "$disk_root" 2>/dev/null | awk 'NR==2{printf "%.0f %.0f", $3*1024, $2*1024}')"
    vram=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | awk '{s+=$1} END{if(s>0) printf "%.0f", s*1048576}')
    echo "VRAM=$vram"
    echo "GPU=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)"
    if [ "$(uname -s)" != Darwin ]; then
      # Important warnings: password/account expiry (chage), disk usage, failed units, reboot required.
      now=$(date +%s)
      chg=$(LC_ALL=C chage -l "$(id -un)" 2>/dev/null)
      for k in "Password expires:PWEXP" "Account expires:ACCEXP"; do
        label=${k%%:*}; key=${k##*:}
        v=$(printf '%s\n' "$chg" | awk -F': ' -v l="$label" '$1==l{print $2; exit}')
        case "$v" in
          ""|never) ;;
          *"must be changed"*) echo "$key=-1" ;;
          *) t=$(LC_ALL=C date -d "$v" +%s 2>/dev/null) && echo "$key=$(( (t - now) / 86400 ))" ;;
        esac
      done
      # Check only real writable filesystems; exclude read-only Android /system, /apex, snap squashfs, ISO,
      # and virtual filesystems that otherwise always appear full.
      for mp in $(awk '$4 ~ /^rw(,|$)/ && $3 ~ /^(ext[234]|xfs|btrfs|zfs|f2fs|vfat|exfat|ntfs3?|fuseblk|jfs|nfs4?|cifs)$/ {print $2}' /proc/mounts 2>/dev/null); do
        df -P -k "$mp" 2>/dev/null | awk 'NR==2{p=$5; gsub("%","",p); print p+0, $6}'
      done | sort -rn | head -1 | sed 's/^/DISKHI=/'
      if [ -f /var/run/reboot-required ]; then echo "REBOOT=1"; fi
      echo "WARNDONE=1"
    fi
    """

    /// System-information TTL reuses OS/spec/disk results without another SSH probe while valid.
    private static let specsTTL: TimeInterval = 30 * 60   // 30 minutes.

    /// On opening an overview, probe real system information through background SSH and cache it.
    /// Skip if probedAt is within specsTTL; system information changes slowly and need not be probed on every visit.
    func probeHostIfNeeded(_ host: Host) {
        guard let ssh = host.ssh, !ssh.host.isEmpty, ssh.hasUsableCredentials,
              !probingHosts.contains(host.id) else { return }
        if let specs = host.specs, let probedAt = specs.probedAt,
           Date().timeIntervalSince(probedAt) < Self.specsTTL,
           (host.isLocal || specs.warnProbed),   // Reprobe old cached results once if they lack warning fields.
           (!host.isLocal || (!specs.model.isEmpty && !specs.chip.isEmpty)) { return }
        probingHosts.insert(host.id)
        let id = host.id
        if host.isLocal {
            // Run the same probe script directly on this Mac for the local host.
            Task { @MainActor [weak self] in
                let r = await LocalFS.runShell(Self.probeScript, stdin: nil, timeout: 20)
                self?.applyProbe(id: id, output: String(decoding: r.data, as: UTF8.self))
            }
            return
        }

        // In-process libssh2 replaces spawned /usr/bin/ssh: borrow a warm pooled connection, exec the probe script, and parse.
        // probeScript/applyProbe stay unchanged; only transport changes. Reuse pooled connections without repeated authentication, replacing ControlMaster.
        let conn = ssh
        let script = Self.probeScript
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let output = (try? SSHSessionPool.shared.withSession(conn) { try $0.exec(script).output }) ?? ""
            Task { @MainActor in self?.applyProbe(id: id, output: output) }
        }
    }

    private func applyProbe(id: String, output: String) {
        probingHosts.remove(id)
        guard let idx = hosts.firstIndex(where: { $0.id == id }) else { return }
        var specs = HostSpecs()
        for line in output.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
            let val = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            switch key {
            case "OS": specs.os = val
            case "CORES": specs.cores = val
            case "MEM": if let b = Int64(val) { specs.memory = Self.fmtBytes(b) }
            case "DISK":
                // "used bytes total bytes" becomes "53.7 GB / 215 GB".
                let p = val.split(separator: " ")
                if p.count == 2, let u = Int64(p[0]), let t = Int64(p[1]) {
                    specs.disk = "\(Self.fmtBytes(u)) / \(Self.fmtBytes(t))"
                }
            case "VRAM": if let b = Int64(val), b > 0 { specs.vram = Self.fmtBytes(b) }
            case "GPU": specs.gpu = val
            case "MODEL": specs.model = val
            case "CHIP": specs.chip = val
            case "PWEXP": specs.pwExpireDays = Int(val)
            case "ACCEXP": specs.accExpireDays = Int(val)
            case "DISKHI":
                let p = val.split(separator: " ", maxSplits: 1)
                if p.count == 2, let pct = Int(p[0]) { specs.diskHighPct = pct; specs.diskHighMount = String(p[1]) }
            case "FAILED": specs.failedUnits = Int(val) ?? 0
            case "REBOOT": specs.rebootRequired = (val == "1")
            case "WARNDONE": specs.warnProbed = true
            default: break
            }
        }
        // macOS df counts purgeable caches/snapshots as used, overstating actual disk pressure.
        // Recalculate using Finder's available-capacity-for-important-usage measure.
        if hosts[idx].isLocal {
            let home = FileManager.default.homeDirectoryForCurrentUser
            if let v = try? home.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeNameKey]),
               let total = v.volumeTotalCapacity, total > 0, let free = v.volumeAvailableCapacityForImportantUsage {
                specs.diskHighPct = Int((Double(Int64(total) - free) / Double(total) * 100).rounded())
                specs.diskHighMount = v.volumeName ?? "/"
                specs.warnProbed = true
            }
        }
        guard !specs.isEmpty else { return }   // Keep existing results if probing fails due to connection/authentication errors.
        specs.probedAt = Date()                // Record probe time for TTL caching.
        hosts[idx].specs = specs
        hosts[idx].status = .online            // Successful probing proves the host is online.
        HostStore.saveHosts(hosts)
    }

    /// Format bytes in decimal KB/MB/GB/TB rather than binary units,
    /// avoiding varying Gi/Mi displays across machines/values; e.g. 17179869184 -> "17.18 GB".
    private static func fmtBytes(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        f.countStyle = .decimal
        return f.string(fromByteCount: bytes)
    }

    // ---------- Online detection ----------
    // reachQueue/reachLimit are defined at file scope; see the file header.
    // Both are thread-safe and non-actor-isolated there, allowing background Sendable use without concurrency warnings.
    private var statusTimer: Timer?

    /// Perform lightweight TCP reachability checks for all hosts on startup/refresh/timer.
    func refreshAllStatuses() {
        if AppEnv.isScreenshotDemo { return }
        for host in hosts { checkReachability(host) }
    }

    /// Periodically probe online status/latency only while the app is active; pause on focus loss to save CPU.
    private func startStatusTimer() {
        guard statusTimer == nil else { return }
        let t = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshAllStatuses() }
        }
        t.tolerance = 5   // Allow timer coalescing to save additional power.
        statusTimer = t
    }

    private func stopStatusTimer() {
        statusTimer?.invalidate()
        statusTimer = nil
    }

    /// Probe without logging in: measure application-layer RTT; success records online/latency, failure/timeout records offline.
    func checkReachability(_ host: Host) {
        if host.isLocal { return }   // This Mac is always online.
        let id = host.id
        let isRDP = host.isRDP
        let h: String, p: Int
        if let ssh = host.ssh, !ssh.host.isEmpty {
            h = ssh.host; p = ssh.port
        } else if let rdp = host.rdp, !rdp.host.isEmpty {
            h = rdp.host; p = rdp.port
        } else {
            return
        }
        reachQueue.async { [weak self] in
            reachLimit.wait()
            defer { reachLimit.signal() }
            // RDP has no SSH banner, so use plain TCP reachability; SSH retains its one-RTT probe.
            let (ok, ms) = isRDP ? Self.tcpLatency(host: h, port: p) : Self.sshLatency(host: h, port: p)
            Task { @MainActor in self?.setStatus(id, ok ? .online : .offline, latencyMs: ms) }
        }
    }

    /// For bannerless RDP, TCP connection success indicates online and handshake duration gives approximate latency.
    private nonisolated static func tcpLatency(host: String, port: Int) -> (Bool, Int?) {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let info = res, let addr = info.pointee.ai_addr else {
            return (false, nil)
        }
        defer { freeaddrinfo(res) }
        let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        if fd < 0 { return (false, nil) }
        defer { close(fd) }
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let t = DispatchTime.now()
        if connect(fd, addr, info.pointee.ai_addrlen) != 0 {
            if errno != EINPROGRESS { return (false, nil) }
            if !waitFD(fd, POLLOUT, 5) { return (false, nil) }
            var soErr: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &len)
            if soErr != 0 { return (false, nil) }
        }
        let ms = Int(Double(DispatchTime.now().uptimeNanoseconds - t.uptimeNanoseconds) / 1_000_000)
        return (true, ms)
    }

    /// Connect to the SSH port for reachability, then measure a pure round trip after tunnel establishment.
    /// TUN proxies intercept TCP/ICMP handshakes locally, producing false ~2ms values.
    /// Discard the initial banner timing, which includes tunnel setup; send our version and time receipt of server KEXINIT.
    /// This round trip reaches the real server through the proxy. Take the first clean sample >=3ms, avoiding false zeroes from coalesced packets.
    private nonisolated static func sshLatency(host: String, port: Int) -> (Bool, Int?) {
        var online = false
        var smallSample: Int? = nil
        for _ in 0..<3 {
            let (ok, rtt) = probeOnce(host: host, port: port, timeoutSec: 5)
            if ok { online = true }
            if let rtt {
                if rtt >= 3 { return (true, rtt) }   // Use the clean sample immediately.
                smallSample = rtt                    // A sample below 3ms may be coalesced; retain it provisionally and continue sampling.
            }
        }
        return (online, online ? smallSample : nil)
    }

    /// One probe: connect, read banner, send version, time KEXINIT; return TCP reachability and optional pure RTT milliseconds.
    private nonisolated static func probeOnce(host: String, port: Int, timeoutSec: Double) -> (Bool, Int?) {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let info = res, let addr = info.pointee.ai_addr else {
            return (false, nil)
        }
        defer { freeaddrinfo(res) }

        let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        if fd < 0 { return (false, nil) }
        defer { close(fd) }
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        // Connect using nonblocking socket plus poll.
        if connect(fd, addr, info.pointee.ai_addrlen) != 0 {
            if errno != EINPROGRESS { return (false, nil) }
            if !waitFD(fd, POLLOUT, timeoutSec) { return (false, nil) }
            var soErr: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &len)
            if soErr != 0 { return (false, nil) }
        }
        // An established TCP connection means online.
        var buf = [UInt8](repeating: 0, count: 512)
        // Read/discard initial banner timing, which includes proxy tunnel setup.
        if !waitFD(fd, POLLIN, timeoutSec) { return (true, nil) }
        if recv(fd, &buf, buf.count, 0) <= 0 { return (true, nil) }
        // Send our version and time KEXINIT; the established tunnel yields one pure RTT.
        let ver = "SSH-2.0-serverdock\r\n"
        _ = ver.withCString { send(fd, $0, strlen($0), 0) }
        let t = DispatchTime.now()
        if !waitFD(fd, POLLIN, timeoutSec) { return (true, nil) }
        if recv(fd, &buf, buf.count, 0) <= 0 { return (true, nil) }
        let ms = Int(Double(DispatchTime.now().uptimeNanoseconds - t.uptimeNanoseconds) / 1_000_000)
        return (true, ms)
    }

    /// Wait for POLLIN/POLLOUT on fd; return false for timeout/error.
    private nonisolated static func waitFD(_ fd: Int32, _ event: Int32, _ timeoutSec: Double) -> Bool {
        var pfd = pollfd(fd: fd, events: Int16(event), revents: 0)
        return poll(&pfd, 1, Int32(timeoutSec * 1000)) > 0
    }

    private func setStatus(_ id: String, _ status: HostStatus, latencyMs: Int? = nil) {
        guard let idx = hosts.firstIndex(where: { $0.id == id }) else { return }
        // Runtime state is not persisted; probe again at next startup.
        if hosts[idx].status != status { hosts[idx].status = status }
        if hosts[idx].latencyMs != latencyMs { hosts[idx].latencyMs = latencyMs }
    }

    private var terminals: [Int: LocalProcessTerminalView] = [:]
    private var termDrivers: [Int: SSHTerminalDriver] = [:]   // Per-tab libssh2 terminal drivers.
    private var rdpSessions: [Int: RDPSession] = [:]
    private var nextTabId = 1
    private var themeCancellable: AnyCancellable?

    private var settingsCancellable: AnyCancellable?
    private var watchdogTimer: Timer?

    /// Global singleton keeps background-task state accessible to AppDelegate/menu-bar/quit handlers independently of windows.
    static let shared = AppModel()

    private init() {
        // Load hosts and session history from disk.
        if AppEnv.isScreenshotDemo {
            hosts = (HostStore.loadScreenshotHost().map { [$0] } ?? []) + Self.screenshotDemoHosts()
            hostGroups = ["Live Demo", "Production", "Development", "Infrastructure"]
            hostLastUsed = [:]
        } else {
            hosts = (AppEnv.localTerminalEnabled ? [Self.makeLocalHost()] : []) + HostStore.loadHosts()
            hostGroups = HostStore.loadHostGroups()
        }
        for host in hosts where !host.isLocal && !host.isRDP && !hostGroups.contains(host.group) {
            hostGroups.append(host.group)
        }
        if !AppEnv.isScreenshotDemo { HostStore.saveHostGroups(hostGroups) }
        assignMissingHostColors()
        sessions = AppEnv.isScreenshotDemo ? [] : HostStore.loadSessions()
        forwards = AppEnv.isScreenshotDemo ? [] : HostStore.loadForwards()
        favorites = AppEnv.isScreenshotDemo ? [:] : HostStore.loadFavorites()
        recentFiles = AppEnv.isScreenshotDemo ? [:] : HostStore.loadRecents()
        sshKeys = AppEnv.isScreenshotDemo ? [] : KeyStore.load()
        snippets = AppEnv.isScreenshotDemo ? [] : SnippetStore.load()
        sites = AppEnv.isScreenshotDemo ? [] : SiteStore.load().filter { AppEnv.smbEnabled || $0.kind != .smb }
        if AppEnv.smbEnabled { SMBBackend.cleanupStaleMounts() }   // Clean up SMB mounts left by a previous run.
        HostTint.shared.lookup = { [weak self] id in self?.host(id)?.accent }
        HostKeyVerifier.resetSession()   // Clear temporary accept-once known_hosts trust.
        // Probe all hosts once at startup.
        defer { refreshAllStatuses() }

        // Themed views already observe ThemeManager.shared/AppSettings.shared directly,
        // so do not forward their objectWillChange through AppModel and rebuild the whole view tree again.
        // Subscribe only for side effects: refresh terminal colors/transparency after theme/settings changes.
        themeCancellable = ThemeManager.shared.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.applyThemeToTerminals() }
        }
        settingsCancellable = AppSettings.shared.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async {
                self?.applyThemeToTerminals()
                self?.applyTerminalSettings()
                self?.pumpTransferQueue()   // The concurrency limit may have increased; immediately try starting queued transfers.
            }
        }

        // Reconnect immediately on Wi-Fi/wired changes or recovery instead of waiting for SSH keepalive timeout.
        // Reconnect monitors, then disconnected terminals once online, and reset file connections so subsequent operations restore SFTP.
        NetworkMonitor.shared.onChange = { [weak self] online in
            guard let self else { return }
            for (_, m) in self.hostMonitors { m.handleNetworkChange() }
            for (_, fm) in self.forwardManagers { fm.handleNetworkChange() }
            if online {
                self.reconnectDroppedTerminals()
                self.reconnectFileViewsAfterNetworkChange()
            }
        }

        // Probe status/latency every 30s while active; pause when inactive to save CPU/power.
        startStatusTimer()
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.startStatusTimer(); self?.refreshAllStatuses() }
        }
        nc.addObserver(forName: NSApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.stopStatusTimer() }
        }
        // Stop all forwarding tunnels before exit; ssh -N has no stdout dependency and may survive its parent, requiring explicit termination.
        // Use the thread-safe process registry from nonisolated synchronous exit callbacks without macOS-14-only assumeIsolated.
        nc.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            ForwardProcessRegistry.shared.terminateAll()
        }

        // Every 20s, watchdog intended tunnels and schedule restarts for dropped ones, catching missed exit signals.
        // Act only when tunnels are intended to run; the low-frequency overhead is negligible. ForwardManager handles network flapping.
        let wd = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.forwardWatchdogTick() }
        }
        wd.tolerance = 5
        watchdogTimer = wd
    }

    /// Use reserved documentation IPs only; never called without SCREENSHOT_DEMO.
    private static func screenshotDemoHosts() -> [Host] {
        let items: [(String, String, String, String, String)] = [
            ("Production API", "192.0.2.10", "Production", "deploy", "#10B981"),
            ("Web Server", "192.0.2.20", "Production", "deploy", "#3B82F6"),
            ("Staging", "198.51.100.12", "Development", "dev", "#F59E0B"),
            ("Build Runner", "198.51.100.24", "Development", "builder", "#8B5CF6"),
            ("Database", "203.0.113.30", "Infrastructure", "admin", "#EC4899"),
            ("Backup", "203.0.113.40", "Infrastructure", "backup", "#06B6D4"),
        ]
        return items.enumerated().map { index, item in
            let (name, ip, group, user, color) = item
            var ssh = SSHConnection()
            ssh.user = user
            ssh.host = ip
            ssh.authMethod = .ask
            return Host(id: "screenshot-demo-\(index)", name: name, addr: "\(user)@\(ip)",
                        group: group, status: .unknown, os: "Linux", ssh: ssh, colorHex: color)
        }
    }

    private func forwardWatchdogTick() {
        for (_, fm) in forwardManagers where fm.hasIntended { fm.watchdogTick() }
    }

    // ---------- Quit/background cleanup ----------

    /// Readable active-task list for quit confirmation: running forwarding, running/queued transfers, and active extraction.
    var runningBackgroundSummaries: [String] {
        var out: [String] = []
        for rule in forwards where forwardManagers[rule.hostId]?.status(rule.id).isRunning == true {
            let host = hosts.first(where: { $0.id == rule.hostId })?.name ?? String(localized: "Host")
            out.append(String(localized: "Port Forwarding · \(host) · \(rule.summary)"))
        }
        for t in transfers where t.phase == .running || t.phase == .queued || t.phase == .paused {
            let verb = t.direction == .upload ? String(localized: "Upload") : String(localized: "Download")
            out.append(String(localized: "\(verb) · \(t.hostName) · \(t.items.count) items"))
        }
        if let e = extractTask, e.phase == .running {
            out.append(String(localized: "Extract · \(e.hostName) · \(e.archive.name)"))
        }
        return out
    }

    /// Whether any background tasks are ongoing.
    var hasRunningBackground: Bool { !runningBackgroundSummaries.isEmpty }

    /// Stop all forwarding, transfers, and extraction before quitting.
    func stopAllBackground() {
        for (_, fm) in forwardManagers { fm.stopAll() }
        for t in transfers where t.phase == .running || t.phase == .queued || t.phase == .paused { t.cancel() }
        transfers.removeAll()
        extractTask = nil
    }

    var activeHostId: String? {
        guard let id = activeTabId else { return nil }
        return tabs.first(where: { $0.id == id })?.hostId
    }

    /// Right-panel tree, stable identifier, and owning host; nil unless an SSH server is connected.
    /// Terminal/file tabs use independent cwd-following trees; editor tabs use the host-shared explorer with current-file highlighting.
    /// Overview/AI reuse the terminal tree only if a connected host tab exists, avoiding premature SFTP connections.
    var activeFileTree: (state: FileTreeState, id: String, host: Host)? {
        guard let id = activeTabId,
              let tab = tabs.first(where: { $0.id == id }),
              let host = host(tab.hostId), host.ssh != nil else { return nil }
        switch tab.kind {
        case .terminal, .files:
            return (fileTreeState(forTab: id, host: host), "tab-\(id)", host)
        case .editor, .tail, .diskUsage, .docker, .web, .services, .processes, .netTools, .keyManager, .script:
            return (explorerTree(for: host), "host-\(host.id)", host)
        case .overview, .aiChat:
            if let term = tabsModel.terminalTab(inGroup: tab.groupKey) {
                return (fileTreeState(forTab: term.id, host: host), "tab-\(term.id)", host)
            }
            if tabs.contains(where: { $0.groupKey == tab.groupKey && ($0.kind == .files || $0.kind == .editor) }) {
                return (explorerTree(for: host), "host-\(host.id)", host)
            }
            return nil
        case .rdp, .site, .portForwards:
            return nil
        }
    }

    func host(_ id: String?) -> Host? {
        guard let id else { return nil }
        return hosts.first(where: { $0.id == id })
    }

    // ---------- Terminals ----------
    func terminalView(for tabId: Int) -> LocalProcessTerminalView {
        if let tv = terminals[tabId] { return tv }
        let hostId = tabs.first(where: { $0.id == tabId })?.hostId
        let host = hostId.flatMap { hid in hosts.first(where: { $0.id == hid }) }
        let conn = (host?.isLocal ?? false) ? nil : host?.ssh   // .ask session passwords already live in host.ssh; local hosts run a local shell without SSH.
        let tv = makeTerminal(ssh: conn, hostId: hostId, tabId: tabId)
        terminals[tabId] = tv
        return tv
    }

    /// OSC 7 cwd changes reveal the matching directory in this tab's independent sidebar tree.
    private var tabCwd: [Int: String] = [:]
    /// Directory to enter immediately after login for terminals opened from the file browser.
    private var terminalInitialDirectories: [Int: String] = [:]
    private var termDelegates: [Int: TerminalSessionDelegate] = [:]
    /// Reveal the active terminal's cwd immediately when enabling Follow Terminal.
    func syncFileTreeToTerminal() {
        guard let key = tabsModel.activeGroupKey, let term = tabsModel.terminalTab(inGroup: key),
              let cwd = tabCwd[term.id] else { return }
        fileTreeStates[term.id]?.reveal(cwd)
        hostExplorerTrees[key]?.reveal(cwd)
    }

    func handleTerminalCwd(tabId: Int, path: String) {
        // OSC 7 means the post-login prompt is ready, the most reliable connected signal; restore disconnected state immediately.
        if let c = terminalConns[tabId], c.phase == .dropped { c.phase = .live; c.attempt = 0 }
        guard tabCwd[tabId] != path else { return }   // Deduplicate directory reveals because every prompt emits OSC 7.
        tabCwd[tabId] = path
        terminalConns[tabId]?.cwd = path
        if AppSettings.shared.fileTreeFollowsTerminal { fileTreeStates[tabId]?.reveal(path) }
        // Login finished; send any AI-chat text queued for the terminal.
        if let hid = tabs.first(where: { $0.id == tabId })?.hostId, let text = terminalPendingHostText.removeValue(forKey: hid) {
            sendTerminalText(tabId, text)
        }
        // The host sidebar tree follows the active terminal's cwd.
        if AppSettings.shared.fileTreeFollowsTerminal, tabId == activeTabId,
           let hid = tabs.first(where: { $0.id == tabId })?.hostId {
            hostExplorerTrees[hid]?.reveal(path)
        }
    }

    /// Post-login OSC 7 hook makes bash/zsh report cwd on every prompt.
    private static let osc7Hook =
        "__t7(){ printf '\\033]7;file://%s%s\\033\\\\' \"${HOSTNAME:-h}\" \"$PWD\"; }; " +
        "if [ -n \"$ZSH_VERSION\" ]; then precmd_functions+=(__t7); " +
        "else PROMPT_COMMAND=\"__t7;${PROMPT_COMMAND}\"; fi; __t7"

    /// Terminal font from settings; empty/unavailable names fall back to the preset monospace font.
    private func currentTerminalFont() -> NSFont {
        let size = CGFloat(AppSettings.shared.termFontSize)
        let name = AppSettings.shared.termFont
        if !name.isEmpty, let f = NSFont(name: name, size: size) { return f }
        for n in ["JetBrainsMono Nerd Font", "MesloLGM Nerd Font", "MesloLGS Nerd Font",
                  "Hack Nerd Font", "FiraCode Nerd Font", "FiraCode Nerd Font Mono"] {
            if let f = NSFont(name: n, size: size) { return f }
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Resolve SwiftTerm cursor shape/blink from settings.
    private func currentCursorStyle() -> CursorStyle {
        let blink = AppSettings.shared.termCursorBlink
        switch AppSettings.shared.termCursorStyle {
        case "bar": return blink ? .blinkBar : .steadyBar
        case "underline": return blink ? .blinkUnderline : .steadyUnderline
        default: return blink ? .blinkBlock : .steadyBlock
        }
    }

    /// Apply cursor style and scrollback to one terminal.
    private func applyTerminalConfig(to tv: LocalProcessTerminalView) {
        let term = tv.getTerminal()
        term.setCursorStyle(currentCursorStyle())
        term.changeScrollback(AppSettings.shared.termScrollback)
    }

    /// Refresh every terminal's font/cursor/scrollback when settings change.
    private func applyTerminalSettings() {
        let font = currentTerminalFont()
        for tv in terminals.values {
            tv.font = font
            applyTerminalConfig(to: tv)
            tv.setNeedsDisplay(tv.bounds)
        }
    }

    private static func c(_ r: UInt16, _ g: UInt16, _ b: UInt16) -> SwiftTerm.Color {
        SwiftTerm.Color(red: r * 257, green: g * 257, blue: b * 257)
    }

    // Default terminal ANSI palette.
    private static let darkPalette: [SwiftTerm.Color] = [
        c(0x00, 0x00, 0x00), c(0xcd, 0x31, 0x31), c(0x0d, 0xbc, 0x79), c(0xe5, 0xe5, 0x10),
        c(0x24, 0x72, 0xc8), c(0xbc, 0x3f, 0xbc), c(0x11, 0xa8, 0xcd), c(0xe5, 0xe5, 0xe5),
        c(0x66, 0x66, 0x66), c(0xf1, 0x4c, 0x4c), c(0x23, 0xd1, 0x8b), c(0xf5, 0xf5, 0x43),
        c(0x3b, 0x8e, 0xea), c(0xd6, 0x70, 0xd6), c(0x29, 0xb8, 0xdb), c(0xe5, 0xe5, 0xe5),
    ]

    private static let lightPalette: [SwiftTerm.Color] = [
        c(0x00, 0x00, 0x00), c(0xcd, 0x31, 0x31), c(0x00, 0xbc, 0x00), c(0x94, 0x95, 0x00),
        c(0x00, 0x06, 0xc8), c(0xbc, 0x05, 0xbc), c(0x00, 0x98, 0xa8), c(0x55, 0x55, 0x55),
        c(0x66, 0x66, 0x66), c(0xcd, 0x31, 0x31), c(0x14, 0xce, 0x14), c(0xb5, 0xba, 0x00),
        c(0x04, 0x51, 0xa5), c(0xbc, 0x05, 0xbc), c(0x00, 0x98, 0xa8), c(0xa5, 0xa5, 0xa5),
    ]

    private func applyTheme(to tv: LocalProcessTerminalView) {
        let t = ThemeManager.shared.colors
        tv.installColors(ThemeManager.shared.isDark ? Self.darkPalette : Self.lightPalette)
        tv.nativeBackgroundColor = NSColor(hex: t.termBg)
        tv.nativeForegroundColor = NSColor(hex: t.termFg)
        tv.selectedTextBackgroundColor = NSColor(hex: t.termSelection)
        tv.caretColor = NSColor(hex: t.termCaret)
        tv.caretTextColor = NSColor(hex: t.termBg)
    }

    private func applyThemeToTerminals() {
        for tv in terminals.values {
            applyTheme(to: tv)
            // Force a full redraw to remove old opaque pixels.
            tv.getTerminal().updateFullScreen()
            tv.setNeedsDisplay(tv.bounds)
        }
    }

    private func makeTerminal(ssh: SSHConnection? = nil, hostId: String? = nil, tabId: Int) -> LocalProcessTerminalView {
        // PacedTerminalView overrides paste with throttled chunks and bracketed-paste wrapping to prevent remote tty overflow/truncated lines.
        let tv = PacedTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        tv.font = currentTerminalFont()
        applyTheme(to: tv)
        applyTerminalConfig(to: tv)

        if let ssh {
            // SSH libssh2 driver handles input/output/cwd/exit in startTerminalProcess without a local subprocess.
            startTerminalProcess(tv: tv, ssh: ssh, tabId: tabId, hostId: hostId)
            terminalConns[tabId] = TerminalConn()   // Only SSH terminals support reconnecting.
        } else {
            // Local terminals retain LocalProcessTerminalView's shell subprocess, enabled only in Developer ID builds.
            let d = TerminalSessionDelegate()
            d.onTerminated = { [weak self] code in
                Task { @MainActor in self?.handleTerminalExit(tabId: tabId, hostId: nil, exitCode: code) }
            }
            tv.processDelegate = d
            termDelegates[tabId] = d
            if hostId == Host.localId {
                // Track local-host connection state and OSC 7 cwd just like remote hosts.
                terminalConns[tabId] = TerminalConn()
                d.onCwd = { [weak self] path in
                    Task { @MainActor in self?.handleTerminalCwd(tabId: tabId, path: path) }
                }
            }
            var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
            if hostId == Host.localId {
                // Use macOS shell integration (/etc/zshrc_Apple_Terminal, bashrc_Apple_Terminal) to emit OSC 7 on each prompt.
                env.removeAll { $0.hasPrefix("TERM_PROGRAM=") }
                env.append("TERM_PROGRAM=Apple_Terminal")
                env.append("SHELL_SESSIONS_DISABLE=1")   // Prevent ~/.zsh_sessions restoration files.
            }
            let lang = ProcessInfo.processInfo.environment["LANG"] ?? ""
            if !lang.uppercased().contains("UTF-8") { env.append("LANG=en_US.UTF-8") }
            // Start in the user's home directory rather than inheriting the app's working directory,
            // which is Build/Products/Debug under Xcode and / in packaged execution.
            let startDir = terminalInitialDirectories.removeValue(forKey: tabId)
                ?? FileManager.default.homeDirectoryForCurrentUser.path
            tv.startProcess(executable: AppSettings.shared.resolvedShell, args: ["-l"], environment: env,
                            currentDirectory: startDir)
        }
        return tv
    }

    /// Start/restart SSH on a terminal view through libssh2, handling input/output/cwd/exit and injecting OSC 7/initial commands.
    /// Reuse the same view on reconnect to preserve scrollback; first stop the old pump and free channel/session, then create a driver.
    private func startTerminalProcess(tv: LocalProcessTerminalView, ssh: SSHConnection, tabId: Int, hostId: String?) {
        termDrivers[tabId]?.onTerminated = nil      // Invalidate the old exit callback so teardown cannot accidentally trigger reconnect.
        termDrivers[tabId]?.close()
        let term = tv.getTerminal()
        // Default to system ssh through the shell, honoring ~/.ssh/config like iTerm; built-in mode takes the libssh2 path below.
        // MAS sandbox builds cannot spawn external processes, so always use built-in connections.
        if !ssh.useBuiltinSSH && !AppEnv.isMAS {
            termDrivers[tabId] = nil
            let d = TerminalSessionDelegate()
            d.onCwd = { [weak self] path in
                Task { @MainActor in self?.handleTerminalCwd(tabId: tabId, path: path) }
            }
            d.onTerminated = { [weak self] code in
                Task { @MainActor in self?.handleTerminalExit(tabId: tabId, hostId: hostId, exitCode: code) }
            }
            tv.processDelegate = d
            termDelegates[tabId] = d
            tv.terminalDelegate = tv               // Return input/resize handling intercepted by the driver to the terminal view itself.
            var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
            let lang = ProcessInfo.processInfo.environment["LANG"] ?? ""
            if !lang.uppercased().contains("UTF-8") { env.append("LANG=en_US.UTF-8") }
            let initialDirectory = terminalInitialDirectories.removeValue(forKey: tabId)
            (tv as? PacedTerminalView)?.armSystemSSH(
                injectLine: initialCommandLine(ssh, initialDirectory: initialDirectory, hostId: hostId),
                password: ssh.needsAskpass ? ssh.password : nil)
            var home = FileManager.default.homeDirectoryForCurrentUser.path
            let custom = (ssh.localStartDir as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            if !ssh.localStartDir.isEmpty, FileManager.default.fileExists(atPath: custom, isDirectory: &isDir), isDir.boolValue { home = custom }
            if !ssh.sshCommand.isEmpty {
                // OS SSH executes the user's command unchanged through a login shell with normal PATH/aliases.
                tv.startProcess(executable: AppSettings.shared.resolvedShell, args: ["-l", "-c", ssh.sshCommand],
                                environment: env, currentDirectory: home)
            } else {
                tv.startProcess(executable: "/usr/bin/ssh", args: ssh.systemSSHArguments(), environment: env,
                                currentDirectory: home)
            }
            return
        }
        let driver = SSHTerminalDriver(tv: tv, ssh: ssh)
        driver.onCwd = { [weak self] path in
            Task { @MainActor in self?.handleTerminalCwd(tabId: tabId, path: path) }
        }
        driver.onTerminated = { [weak self] code in
            Task { @MainActor in self?.handleTerminalExit(tabId: tabId, hostId: hostId, exitCode: code) }
        }
        tv.terminalDelegate = driver                // Take over input/resize/cwd from LocalProcessTerminalView.
        termDrivers[tabId] = driver
        let initialDirectory = terminalInitialDirectories.removeValue(forKey: tabId)
        driver.connect(cols: term.cols, rows: term.rows,
                       initialLine: initialCommandLine(ssh, initialDirectory: initialDirectory, hostId: hostId))
    }

    // ---------- Terminal reconnection ----------
    // Only SSH exit 255 retains the tab and reconnects; explicit exit/local-terminal termination closes normally.
    private var terminalConns: [Int: TerminalConn] = [:]
    private var terminalReconnectWork: [Int: DispatchWorkItem] = [:]   // At most one pending reconnect per tab to prevent storms.

    /// Expose terminal connection state observed by the disconnect overlay.
    func terminalConn(for tabId: Int) -> TerminalConn? { terminalConns[tabId] }

    func handleTerminalExit(tabId: Int, hostId: String?, exitCode: Int32?) {
        guard tabs.contains(where: { $0.id == tabId }) else { return }
        // Retain/reconnect only SSH exit 255. Close on other exit codes, including explicit exit/signals,
        // regardless of offline state; otherwise intentional offline exit looks like a drop. Local terminals lack TerminalConn and close normally.
        if let hostId, let conn = terminalConns[tabId], exitCode == 255,
           hosts.contains(where: { $0.id == hostId }) {
            conn.dropGen += 1
            conn.phase = .dropped
            scheduleTerminalReconnect(tabId: tabId, hostId: hostId)
            return
        }
        performCloseTab(tabId)
        if let hostId, let host = hosts.first(where: { $0.id == hostId }) {
            let stillUsed = tabs.contains { ($0.kind == .terminal || $0.kind == .files) && $0.hostId == hostId }
            // Ask-mode passwords remain in host.ssh for the app run until cold start, not cleared when tabs close.
            // Do not close a master during active transfers sharing it; closeMaster would interrupt them (review R20).
            if !stillUsed, !hostHasRunningTransfer(hostId) { RemoteFS(host.ssh ?? SSHConnection()).closeMaster() }
        }
    }

    /// Reconnect online with increasing failure-based backoff capped at 15s; offline waits for network recovery.
    /// Cancel the tab's pending reconnect before scheduling another, preventing overlapping attempts after repeated drops.
    private func scheduleTerminalReconnect(tabId: Int, hostId: String) {
        guard NetworkMonitor.shared.isOnline, let conn = terminalConns[tabId] else { return }
        terminalReconnectWork[tabId]?.cancel()
        let delay = min(15.0, 2.0 * Double(conn.attempt + 1))
        let work = DispatchWorkItem { [weak self] in
            self?.terminalReconnectWork[tabId] = nil
            self?.reconnectTerminal(tabId: tabId, hostId: hostId)
        }
        terminalReconnectWork[tabId] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Reconnect on the original terminal view. OSC 7 onCwd marks live immediately; without OSC 7 the watchdog
    /// treats an unchanged dropGen during the attempt as connected.
    private func reconnectTerminal(tabId: Int, hostId: String) {
        terminalReconnectWork[tabId]?.cancel()   // Immediate manual/network recovery reconnect cancels pending backoff attempts.
        terminalReconnectWork[tabId] = nil
        guard let conn = terminalConns[tabId], conn.phase == .dropped,
              tabs.contains(where: { $0.id == tabId }),
              let tv = terminals[tabId],
              let host = hosts.first(where: { $0.id == hostId }), let ssh = host.ssh,
              NetworkMonitor.shared.isOnline else { return }
        conn.attempt += 1
        let gen = conn.dropGen
        startTerminalProcess(tv: tv, ssh: ssh, tabId: tabId, hostId: hostId)   // Reuse the .ask password cached in host.ssh for this run.
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self, let c = self.terminalConns[tabId],
                  c.phase == .dropped, c.dropGen == gen else { return }
            c.phase = .live
            c.attempt = 0
        }
    }

    /// On network recovery, snapshot disconnected terminals before reconnecting all immediately with reset backoff, avoiding dictionary mutation during iteration.
    private func reconnectDroppedTerminals() {
        let dropped = terminalConns.filter { $0.value.phase == .dropped }
        for (tabId, conn) in dropped {
            conn.attempt = 0
            if let hostId = tabs.first(where: { $0.id == tabId })?.hostId {
                reconnectTerminal(tabId: tabId, hostId: hostId)
            }
        }
    }

    /// Disconnect-overlay Reconnect Now action.
    func manualReconnectTerminal(_ tabId: Int) {
        guard let conn = terminalConns[tabId], conn.phase == .dropped,
              let hostId = tabs.first(where: { $0.id == tabId })?.hostId else { return }
        conn.attempt = 0
        reconnectTerminal(tabId: tabId, hostId: hostId)
    }

    // ---------- Startup behavior ----------
    private var didApplyStartup = false
    func applyStartupIfNeeded() {
        guard !didApplyStartup else { return }
        didApplyStartup = true
        switch AppSettings.shared.startupBehavior {
        case .overview:
            if let h = localHost { openHost(h) }   // Start with the local-host overview, or Welcome in the MAS sandbox.
        case .terminal:
            openLocalTerminal()   // MAS has no local terminal; fall back to Welcome.
        case .host:
            if let selected = hosts.first(where: { $0.id == AppSettings.shared.startupHostId && !$0.isLocal }) {
                openHost(selected)
            } else {
                AppSettings.shared.startupHostId = ""
                AppSettings.shared.startupBehavior = .welcome
            }
        case .welcome:
            // Welcome is the default when no tabs exist.
            break
        }
    }

    /// Build post-login injected commands: OSC 7 cwd hook plus a ready marker so SSHTerminalDriver discards injection echo
    /// without clearing the login banner/MOTD, followed by optional cd/initial commands. The driver sends after a login delay.
    private func initialCommandLine(_ ssh: SSHConnection, initialDirectory: String? = nil, hostId: String? = nil) -> String {
        let path = (initialDirectory ?? ssh.defaultPath).trimmingCharacters(in: .whitespaces)
        let cmd = ssh.initialCommand.trimmingCharacters(in: .whitespaces)
        var tail = ""
        if !path.isEmpty && path != "~" { tail += "cd -- \(Self.shellQuote(path))" }
        if !cmd.isEmpty { tail += (tail.isEmpty ? "" : " && ") + cmd }
        if let hostId, let tmux = tmuxAuto[hostId], !tmux.isEmpty { tail += (tail.isEmpty ? "" : "; ") + MuxCommands.autoAttach(tmux) }   // Automatically attach a tmux session.
        var line = Self.osc7Hook + "; printf '\\001\\002SD\\002\\001'"
        if !tail.isEmpty { line += "; " + tail }
        line += "\n"
        return line
    }

    /// Quote one POSIX-shell word safely, preserving paths with spaces/apostrophes.
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    // ---------- Tab operations ----------
    /// Create a terminal for a server group through panel +, or panel toggle when no terminal exists yet.
    func openTerminal(inGroup key: String) {
        if let host = host(key) { openHostTerminal(host, forceNew: true) }
    }

    /// Command-W targets the focused terminal/editor, otherwise the current server's main-area tab, otherwise the active tab.
    func focusedTabId(firstResponder: NSResponder?) -> Int? {
        if let v = firstResponder as? NSView {
            if let (id, _) = terminals.first(where: { v == $0.value || v.isDescendant(of: $0.value) }) { return id }
            if let (id, _) = editorStates.first(where: { st in
                guard let f = st.value.focusView else { return false }
                return v == f || v.isDescendant(of: f)
            }) { return id }
        }
        if let key = tabsModel.activeGroupKey, let main = tabsModel.mainTab(inGroup: key) { return main.id }
        return activeTabId
    }

    /// Activate whichever terminal/editor was clicked, switching focus between simultaneously visible main and terminal panels.
    func noteClick(in view: NSView) {
        if let (id, _) = terminals.first(where: { view == $0.value || view.isDescendant(of: $0.value) }) {
            if activeTabId != id { activeTabId = id }
            return
        }
        if let (id, _) = editorStates.first(where: { st in
            guard let v = st.value.focusView else { return false }
            return view == v || view.isDescendant(of: v)
        }) {
            if activeTabId != id { activeTabId = id }
        }
    }

    /// This Mac's local host; nil in MAS sandbox builds.
    var localHost: Host? { host(Host.localId) }

    /// Create a local terminal from toolbar/Welcome actions, treating local as a regular host.
    func openLocalTerminal() {
        guard let h = localHost else { return }
        openHostTerminal(h, forceNew: true)
    }

    func openHost(_ host: Host) {
        if let existing = tabs.first(where: { $0.kind == .overview && $0.hostId == host.id }) {
            activeTabId = existing.id
            return
        }
        addTab(.overview, title: host.name, hostId: host.id)
    }

    /// Opening AI chat needs no SSH authentication/connection gate because it accesses the provider API directly.
    func openHostAIChat(_ host: Host) {
        if let existing = tabs.first(where: { $0.kind == .aiChat && $0.hostId == host.id }) {
            activeTabId = existing.id
            return
        }
        addTab(.aiChat, title: String(localized: "AI Assistant"), hostId: host.id)
    }

    /// Reuse the host's terminal by default; forceNew=true creates another for explicit New Terminal actions.
    func openHostTerminal(_ host: Host, forceNew: Bool = false) {
        if !forceNew, let existing = tabs.first(where: { $0.kind == .terminal && $0.hostId == host.id }) {
            activeTabId = existing.id
            return
        }
        requireAuth(host) { [weak self] in
            self?.connectThen(host.id, hint: String(localized: "Opening terminal…")) { self?.openTerminalTab(host.id) }
        }
    }

    /// Navigate the terminal to the remote directory selected in the file browser.
    func openHostTerminal(_ host: Host, at directory: String) {
        guard !directory.isEmpty else { return }
        if let existing = tabs.first(where: { $0.kind == .terminal && $0.hostId == host.id }) {
            activeTabId = existing.id
            if termDrivers[existing.id] != nil || terminals[existing.id] != nil {   // Send cd to an existing SSH/local terminal.
                sendTerminalText(existing.id, "cd -- \(Self.shellQuote(directory))\n")
            } else {
                terminalInitialDirectories[existing.id] = directory
                _ = terminalView(for: existing.id)
            }
            return
        }
        requireAuth(host) { [weak self] in
            self?.connectThen(host.id, hint: String(localized: "Opening terminal…")) {
                self?.openTerminalTab(host.id, initialDirectory: directory)
            }
        }
    }

    /// Copy a remote-tree path to the system clipboard.
    func copyRemotePath(_ path: String) {
        guard !path.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    /// Overview Connect opens a terminal and closes overview so the terminal fills the workspace alongside the file panel.
    /// Reopen overview through the terminal toolbar gauge or New menu when needed.
    func connectToHostWorkspace(_ host: Host) {
        guard !host.isRDP, host.ssh != nil, connectingHost?.id != host.id else { return }
        if tabs.contains(where: { $0.kind == .terminal && $0.hostId == host.id }) {
            showConnectedHost(host.id)
            return
        }
        requireAuth(host) { [weak self] in
            self?.connectThen(host.id, hint: String(localized: "Connecting…")) {
                self?.showConnectedHost(host.id)
            }
        }
    }

    private func showConnectedHost(_ hostId: String) {
        guard hosts.contains(where: { $0.id == hostId }) else { return }
        if let terminal = tabs.first(where: { $0.kind == .terminal && $0.hostId == hostId }) {
            activeTabId = terminal.id
        } else {
            openTerminalTab(hostId)
        }
        // Activate the terminal before closing overview, leaving it to fill the server workspace.
        if let overview = tabs.first(where: { $0.kind == .overview && $0.hostId == hostId }) {
            performCloseTab(overview.id)
        }
    }

    /// Validate a connection for monitoring without opening a tab: ask-mode password then verification dialog;
    /// success enables live overview monitoring, failure clears the password. Used by the monitor placeholder Connect button.
    func verifyConnect(_ host: Host) {
        requireAuth(host) { [weak self] in self?.connectThen(host.id, hint: String(localized: "Starting monitoring…")) { } }
    }

    /// If noninteractive monitoring authentication fails, clear ask-mode credentials and request them again.
    private func requestMonitorPassword(hostId: String) {
        guard pendingAskAuth == nil,
              let host = hosts.first(where: { $0.id == hostId }),
              host.ssh?.authMethod == .ask else { return }
        clearAskPassword(hostId)
        guard let current = hosts.first(where: { $0.id == hostId }) else { return }
        pendingAskAuth = current
        pendingAskContinuation = { [weak self] in
            self?.connectThen(hostId, hint: String(localized: "Starting monitoring…")) { }
        }
    }

    /// Credential gate: prompt ask-mode hosts lacking a session password, then execute action; otherwise execute immediately.
    /// Shared by terminal/files/forwarding and every entry requiring SSH credentials.
    /// Always resolve the current host by ID; caller snapshots may lack cached passwords and would cause repeated prompts.
    private func requireAuth(_ host: Host, _ action: @escaping () -> Void) {
        let live = hosts.first(where: { $0.id == host.id }) ?? host
        if live.isLocal { action(); return }   // Local hosts need no authentication.
        if live.ssh?.authMethod == .ask, (live.ssh?.password ?? "").isEmpty {
            pendingAskAuth = live
            pendingAskContinuation = action
            return
        }
        action()
    }

    /// On ask-mode confirmation, store the password only in the host's in-memory ssh configuration; saveHosts never persists .ask passwords.
    /// All terminal/files/forwarding/monitoring operations then reuse it through host.ssh. Cold startup requires reentry.
    func submitAskAuth(_ password: String) {
        guard let host = pendingAskAuth, let idx = hosts.firstIndex(where: { $0.id == host.id }) else {
            pendingAskAuth = nil; pendingAskContinuation = nil; return
        }
        pendingAskAuth = nil
        hosts[idx].ssh?.password = password
        let cont = pendingAskContinuation
        pendingAskContinuation = nil
        cont?()
    }

    func cancelAskAuth() { pendingAskAuth = nil; pendingAskContinuation = nil }

    /// Show a connection-verification dialog with real askpass authentication/live logs; run then on success.
    /// Every ask-mode entry uses verification after password entry; password/key terminal connections also use this dialog.
    private func connectThen(_ hostId: String, hint: String = String(localized: "Opening terminal…"), _ then: @escaping () -> Void) {
        guard let host = hosts.first(where: { $0.id == hostId }) else { return }
        if host.isLocal { then(); return }   // Local hosts bypass fingerprint/authentication verification.
        connectingActionHint = hint
        connectingContinuation = then
        connectingHost = host   // Perform fingerprint verification/probing in visible dialog stages for immediate feedback even on distant/high-latency hosts.
    }

    /// Open the terminal tab after successful verification.
    private func openTerminalTab(_ hostId: String, initialDirectory: String? = nil) {
        guard let host = hosts.first(where: { $0.id == hostId }) else { return }
        let title = uniqueTabTitle(host.name) { $0.kind == .terminal && $0.hostId == host.id }
        let id = addTab(.terminal, title: title, hostId: host.id)
        if let initialDirectory { terminalInitialDirectories[id] = initialDirectory }
        recordSession(hostId: host.id, kind: .terminal, detail: String(localized: "Terminal Session"))
        prewarmExplorer(for: host)
    }

    /// Clear an ask-mode session password after failure/cancel so the next action asks again; stop monitoring with invalid credentials.
    private func clearAskPassword(_ hostId: String) {
        guard let i = hosts.firstIndex(where: { $0.id == hostId }), hosts[i].ssh?.authMethod == .ask else { return }
        hosts[i].ssh?.password = ""
        askVerifiedHosts.remove(hostId)   // Clear verification state too so the next connection verifies again.
        hostMonitors[hostId]?.stop()
    }

    /// After verification, mark the ask-mode host verified for this run and execute the original terminal/files/forwarding action.
    func finishConnecting() {
        guard let host = connectingHost else { return }
        if host.ssh?.authMethod == .ask { askVerifiedHosts.insert(host.id) }
        connectingHost = nil
        let cont = connectingContinuation
        connectingContinuation = nil
        (cont ?? {})()
    }

    /// Prebuild the host's explorer tree in the background after SSH connection for fast subsequent file access.
    func prewarmExplorer(for host: Host) {
        guard host.ssh != nil else { return }
        explorerTree(for: host).startIfNeeded()
    }

    func cancelConnecting() {
        // On ask-mode failure/cancel, clear the session password so incorrect passwords can be entered again.
        if let host = connectingHost, host.ssh?.authMethod == .ask { clearAskPassword(host.id) }
        connectingHost = nil
        connectingContinuation = nil
    }

    // ---------- RDP remote desktop ----------
    /// Open or select an RDP host's desktop tab.
    func openHostRDP(_ host: Host) {
        guard host.isRDP else { return }
        // Allow one RDP connection per host; concurrent sessions would displace each other. Restore an existing connection instead.
        if let existing = tabs.first(where: { $0.kind == .rdp && $0.hostId == host.id }) {
            activeTabId = existing.id
            return
        }
        if let w = rdpWindowController(for: host.id) {
            w.focus()
            return
        }
        // Ignore duplicate starts while connecting or choosing the opening mode.
        if connectingRDP?.host.id == host.id || pendingRDPOpen?.host.id == host.id { return }
        // Show connection progress over the current overview/list; open the tab only after success instead of entering a black tab.
        let session = RDPSession(host: host)
        connectingRDP = session
        session.connect(canvas: estimatedRDPCanvas())
    }

    /// Existing separate-window RDP connection for a host, if any.
    private func rdpWindowController(for hostId: String) -> RDPWindowController? {
        rdpWindowControllers.first { $0.hostId == hostId }
    }

    /// Recompute connected-host IDs across inline tabs/windows to drive overview Running state.
    private func refreshRDPHosts() {
        var s = Set<String>()
        for t in tabs where t.kind == .rdp { if let h = t.hostId { s.insert(h) } }
        for w in rdpWindowControllers { s.insert(w.hostId) }
        if rdpHosts != s { rdpHosts = s }
    }

    /// On RDP success, dismiss progress and follow the inline/new-window/ask setting.
    func finishRDPConnecting() {
        guard let session = connectingRDP else { return }
        connectingRDP = nil
        switch AppSettings.shared.rdpOpenMode {
        case .embedded: openRDPEmbedded(session)
        case .window:   openRDPWindow(session)
        case .ask:      pendingRDPOpen = session
        }
    }

    /// Cancel/dismiss connection progress by disconnecting/freeing the session before it enters a tab.
    func cancelRDPConnecting() {
        connectingRDP?.disconnect()
        connectingRDP = nil
    }

    /// Pass the already connected session to a new inline RDP tab without reconnecting.
    func openRDPEmbedded(_ session: RDPSession) {
        let host = session.host
        let id = addTab(.rdp, title: host.name, hostId: host.id)
        rdpSessions[id] = session
        recordSession(hostId: host.id, kind: .rdp, detail: String(localized: "Remote Desktop"))
        refreshRDPHosts()
    }

    /// Host the session in a separate controller-owned window; fullscreen follows settings. Closing disconnects the retained session.
    func openRDPWindow(_ session: RDPSession) {
        let c = RDPWindowController(session: session)
        c.onClose = { [weak self, weak c] in
            Task { @MainActor in
                guard let self, let c else { return }
                self.rdpWindowControllers.removeAll { $0 === c }
                self.refreshRDPHosts()
            }
        }
        rdpWindowControllers.append(c)
        recordSession(hostId: session.host.id, kind: .rdp, detail: String(localized: "Remote Desktop (Window)"))
        refreshRDPHosts()
        c.present(fullscreen: AppSettings.shared.rdpWindowFullscreen)
    }

    /// Ask-mode choice: window=true creates a settings-controlled fullscreen/new window; otherwise inline. remember saves the default.
    func resolveRDPOpen(_ session: RDPSession, window: Bool, remember: Bool) {
        pendingRDPOpen = nil
        if remember { AppSettings.shared.rdpOpenMode = window ? .window : .embedded }
        if window { openRDPWindow(session) } else { openRDPEmbedded(session) }
    }

    /// Cancel the open-mode choice by disconnecting/freeing the unassigned session.
    func cancelRDPOpen() {
        pendingRDPOpen?.disconnect()
        pendingRDPOpen = nil
    }

    /// Before exit, synchronously close every inline/window/connecting/pending RDP session and join worker threads.
    /// Otherwise FreeRDP threads remain active during process teardown, causing errors/stalls/contention. First abort every session so workers
    /// clean up in parallel, then join individually; total time is roughly one cleanup rather than linear in connection count. Do not run when merely hiding.
    func shutdownAllRDP() {
        let sessions = Array(rdpSessions.values) + rdpWindowControllers.map { $0.session }
            + [connectingRDP, pendingRDPOpen].compactMap { $0 }
        guard !sessions.isEmpty else { return }
        for s in sessions { s.disconnect() }   // First pass: abort all and unblock certificate waits without blocking.
        for s in sessions { s.shutdown() }      // Second pass: join workers already cleaning up concurrently.
        rdpSessions.removeAll()
        rdpWindowControllers.removeAll()        // Release window controllers/sessions; termination later removes windows.
        connectingRDP = nil
        pendingRDPOpen = nil
        rdpHosts = []
    }

    /// Use an estimated workspace-sized canvas before the tab opens; RDPSessionView corrects actual dimensions through requestResize afterward.
    private func estimatedRDPCanvas() -> CGSize {
        if let s = NSApp.keyWindow?.contentView?.bounds.size, s.width > 400, s.height > 300 {
            return CGSize(width: max(640, s.width - 320), height: max(480, s.height - 8))
        }
        return CGSize(width: 1280, height: 800)
    }

    /// Get/create an RDP tab's state so its view always receives a session.
    func rdpSession(for tabId: Int, host: Host) -> RDPSession {
        if let s = rdpSessions[tabId] { return s }
        let s = RDPSession(host: host)
        rdpSessions[tabId] = s
        return s
    }

    // Host ID opening Files (SFTP); show loading on the overview SFTP card during slow fingerprint/connection preflight.
    @Published var openingFilesHostId: String? = nil

    /// Open the browser at path from the terminal toolbar, selecting/navigating an existing file tab when available.
    private var pendingFilesPath: [String: String] = [:]
    func openHostFiles(_ host: Host, at path: String?) {
        guard let path, !path.isEmpty else { openHostFiles(host); return }
        if let existing = tabs.first(where: { $0.kind == .files && $0.hostId == host.id }) {
            activeTabId = existing.id
            browserStates[existing.id]?.open(path)
            return
        }
        pendingFilesPath[host.id] = path
        openHostFiles(host)
    }

    func openHostFiles(_ host: Host) {
        // Select this host's existing file tab if present.
        if let existing = tabs.first(where: { $0.kind == .files && $0.hostId == host.id }) {
            activeTabId = existing.id
            return
        }
        requireAuth(host) { [weak self] in self?.proceedFiles(host.id) }
    }

    /// Unverified ask-mode hosts verify before opening files; verified/password/key hosts open directly.
    private func proceedFiles(_ hostId: String) {
        guard let host = hosts.first(where: { $0.id == hostId }) else { return }
        if host.ssh?.authMethod == .ask, !askVerifiedHosts.contains(hostId) {
            connectThen(hostId, hint: String(localized: "Opening file…")) { [weak self] in self?.startOpenHostFiles(hostId) }
        } else {
            startOpenHostFiles(hostId)
        }
    }

    private func startOpenHostFiles(_ hostId: String) {
        guard let host = hosts.first(where: { $0.id == hostId }) else { return }
        guard openingFilesHostId != host.id else { return }   // Prevent duplicate rapid-click requests.
        openingFilesHostId = host.id
        Task {
            defer { openingFilesHostId = nil }   // Clear loading after opening the tab, cancellation, or failure.
            guard await verifyHostKey(host) else { return }
            addTab(.files, title: host.name, hostId: host.id)
            recordSession(hostId: host.id, kind: .files, detail: String(localized: "Browse Files"))
            prewarmExplorer(for: host)
        }
    }

    /// First-connection fingerprint check: accept known hosts immediately; ask the user to compare unknown keys. Return whether to continue.
    func verifyHostKey(_ host: Host) async -> Bool {
        guard let ssh = host.ssh, !ssh.host.isEmpty else { return true }
        if ssh.hasJumpHost || (!ssh.useBuiltinSSH && !AppEnv.isMAS) { return true }   // Direct scanning cannot traverse a jump host; delegate to ssh accept-new.
        return await verifyFingerprint(host: ssh.host, port: ssh.port)
    }

    /// Compare address/port host keys with known_hosts and confirm unknown/changed keys; shared with SFTP sites.
    func verifyFingerprint(host h: String, port p: Int) async -> Bool {
        let pf = await Task.detached { HostKeyVerifier.preflight(host: h, port: p) }.value
        switch pf {
        case .known, .scanFailed:
            return true   // Accept known keys; let the real connection report scanning failures.
        case .prompt(let info), .changed(let info):
            // Ask the user to verify unknown/changed keys, with a prominent warning for info.changed=true.
            let decision: HostKeyDecision = await withCheckedContinuation { cont in
                pendingHostKey = PendingHostKey(info: info) { cont.resume(returning: $0) }
            }
            pendingHostKey = nil
            switch decision {
            case .cancel: return false
            case .once: HostKeyVerifier.trust(info, persist: false); return true
            case .save: HostKeyVerifier.trust(info, persist: true); return true
            }
        }
    }

    // ---------- File-browser state ----------
    private var browserStates: [Int: BrowserState] = [:]

    func browserState(for tabId: Int, host: Host) -> BrowserState {
        if let s = browserStates[tabId] { return s }
        let s = BrowserState(fs: RemoteFS(host.ssh ?? SSHConnection()))
        s.initialPath = pendingFilesPath.removeValue(forKey: host.id)   // When opened from the terminal toolbar, navigate directly to its cwd.
        browserStates[tabId] = s
        return s
    }

    /// Host-cached sidebar file-tree state for the Files section.
    // Separate tree state per tab/session even for the same host; underlying SSH still shares the host ControlMaster.
    private var fileTreeStates: [Int: FileTreeState] = [:]
    func fileTreeState(forTab tabId: Int, host: Host) -> FileTreeState {
        if let s = fileTreeStates[tabId] { return s }
        let s = FileTreeState(fs: RemoteFS(host.ssh ?? SSHConnection()), revealOnLoad: tabCwd[tabId])
        fileTreeStates[tabId] = s
        return s
    }

    /// One host-level explorer tree shared by all editors; highlight the current file without reloading for each file.
    private var hostExplorerTrees: [String: FileTreeState] = [:]
    func explorerTree(for host: Host) -> FileTreeState {
        if let s = hostExplorerTrees[host.id] { return s }
        // Initialize at the host's active terminal cwd, falling back to home.
        let activeTerm = tabs.first { $0.id == activeTabId && $0.hostId == host.id && $0.kind == .terminal }
        let s = FileTreeState(fs: RemoteFS(host.ssh ?? SSHConnection()), revealOnLoad: activeTerm.flatMap { tabCwd[$0.id] })
        hostExplorerTrees[host.id] = s
        return s
    }

    /// After network recovery, reset all file-view connections so SFTP reconnects on the next action instead of remaining downgraded to shell.
    /// Deduplicate stale ControlMaster closure per host, then reset/reload each view's SFTP session.
    private func reconnectFileViewsAfterNetworkChange() {
        var done = Set<String>()
        for tab in tabs {
            guard let hid = tab.hostId, !done.contains(hid),
                  let ssh = hosts.first(where: { $0.id == hid })?.ssh else { continue }
            done.insert(hid)
            RemoteFS(ssh).closeMaster()
        }
        for (_, b) in browserStates { b.reconnect() }
        for (_, t) in fileTreeStates { t.reconnect() }
        for (_, t) in hostExplorerTrees { t.reconnect() }
    }

    /// Breadcrumb click opens the right panel and reveals its directory/file in the tree.
    func jumpToExplorer(path: String, host: Host) {
        filePanelVisible = true
        revealInExplorer(path, host: host)
    }

    // ---------- Recent-file history ----------
    /// Host ID to recent files, newest first, capped at maxRecentFiles; shown in the file panel.
    @Published var recentFiles: [String: [RecentFile]] = [:]
    private let maxRecentFiles = 20

    private func recordRecentFile(_ file: RemoteFile, hostId: String) {
        var list = recentFiles[hostId] ?? []
        if list.first?.path == file.path { return }
        list.removeAll { $0.path == file.path }
        list.insert(RecentFile(path: file.path, name: file.name), at: 0)
        if list.count > maxRecentFiles { list.removeLast(list.count - maxRecentFiles) }
        recentFiles[hostId] = list
        HostStore.saveRecents(recentFiles)
    }

    func removeRecentFile(_ path: String, hostId: String) {
        guard var list = recentFiles[hostId] else { return }
        list.removeAll { $0.path == path }
        recentFiles[hostId] = list.isEmpty ? nil : list
        HostStore.saveRecents(recentFiles)
    }

    func clearRecentFiles(hostId: String) {
        guard recentFiles.removeValue(forKey: hostId) != nil else { return }
        HostStore.saveRecents(recentFiles)
    }

    // ---------- Favorite paths/files ----------
    /// Per-host favorites shown at the top of the right file panel.
    /// User-selected per-host log paths for overview cards, persisted in UserDefaults.
    /// Per-host saved HTTP-check URL and last runtime result; results are not persisted.
    @Published var httpChecks: [String: [HTTPCheckItem]] = AppModel.loadHTTPChecks()
    @Published var httpResults: [String: HTTPCheckResult] = [:]
    @Published var httpRunning = Set<String>()
    @Published var httpCheckPrefill: String? = nil   // URL to prefill when opening the details sheet.

    @Published var hostLogs: [String: [String]] = (UserDefaults.standard.dictionary(forKey: "hostLogs") as? [String: [String]]) ?? [:]

    func addLog(_ path: String, hostId: String) {
        let p = path.trimmingCharacters(in: .whitespaces)
        guard p.hasPrefix("/"), !(hostLogs[hostId] ?? []).contains(p) else { return }
        hostLogs[hostId, default: []].append(p)
        saveHostLogs()
    }

    func removeLog(_ path: String, hostId: String) {
        hostLogs[hostId]?.removeAll { $0 == path }
        if hostLogs[hostId]?.isEmpty == true { hostLogs[hostId] = nil }
        saveHostLogs()
    }

    private func saveHostLogs() {
        guard !AppEnv.isScreenshotDemo else { return }
        UserDefaults.standard.set(hostLogs, forKey: "hostLogs")
    }

    @Published var favorites: [String: [FavoritePath]] = [:]

    private static func normalizedFavoritePath(_ path: String) -> String {
        var p = path.trimmingCharacters(in: .whitespaces)
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }

    func isFavorite(_ path: String, hostId: String) -> Bool {
        let p = Self.normalizedFavoritePath(path)
        return favorites[hostId]?.contains { $0.path == p } ?? false
    }

    /// Add if absent, otherwise remove.
    func toggleFavorite(path: String, isDir: Bool, hostId: String) {
        let p = Self.normalizedFavoritePath(path)
        guard !p.isEmpty else { return }
        var list = favorites[hostId] ?? []
        if let i = list.firstIndex(where: { $0.path == p }) {
            list.remove(at: i)
        } else {
            list.append(FavoritePath(path: p, isDir: isDir))
        }
        favorites[hostId] = list.isEmpty ? nil : list
        HostStore.saveFavorites(favorites)
    }

    func removeFavorite(_ id: UUID, hostId: String) {
        guard var list = favorites[hostId] else { return }
        list.removeAll { $0.id == id }
        favorites[hostId] = list.isEmpty ? nil : list
        HostStore.saveFavorites(favorites)
    }

    func openFavorite(_ fav: FavoritePath, host: Host, tree: FileTreeState?) {
        if fav.isDir {
            tree?.reveal(fav.path)
        } else {
            openFile(RemoteFile(name: (fav.path as NSString).lastPathComponent, path: fav.path,
                                kind: .file, size: 0, modified: nil), host: host)
        }
    }

    // ---------- Right file panel ----------
    /// Persist panel visibility across launches; visible by default so connection opens terminal/files together.
    @Published var filePanelVisible: Bool = UserDefaults.standard.object(forKey: "filePanelVisible") as? Bool ?? true {
        didSet { UserDefaults.standard.set(filePanelVisible, forKey: "filePanelVisible") }
    }

    /// Reveal/select a file in the host explorer, or initialize the tree at its path if absent.
    private func revealInExplorer(_ path: String, host: Host) {
        if let tree = hostExplorerTrees[host.id] {
            tree.reveal(path)
        } else {
            hostExplorerTrees[host.id] = FileTreeState(
                fs: RemoteFS(host.ssh ?? SSHConnection()), revealOnLoad: path)
        }
    }

    @discardableResult
    private func addTab(_ kind: TabKind, title: String, hostId: String?, filePath: String? = nil) -> Int {
        let id = nextTabId
        nextTabId += 1
        tabs.append(TabItem(id: id, kind: kind, title: title, hostId: hostId, filePath: filePath))
        activeTabId = id
        return id
    }

    // ---------- File editing / preview ----------
    private var editorStates: [Int: EditorState] = [:]
    /// Non-@Published per-editor NSHostingView cache, populated by CachedEditorHost on first makeNSView
    /// and cleared on tab close, keeping editors alive independently of SwiftUI reconstruction for the entire tab lifetime.
    var editorHosts: [Int: NSView] = [:]

    func editorState(for tabId: Int) -> EditorState? { editorStates[tabId] }

    // MARK: Web tabs (internal services through SSH tunnels)
    private var webSessions: [Int: WebSession] = [:]

    func webSession(for tabId: Int) -> WebSession? { webSessions[tabId] }

    /// Tunnel destHost:destPort to a local port and open it in an in-app web tab.
    /// Reuse matching local-forward rules, or create one on a free local port; expose it in forwarding management for later stopping.
    func openWebService(host: Host, destHost: String, destPort: Int, https: Bool, openTab: Bool = true) {
        forwardPanelHost = nil
        requireAuth(host) { [weak self] in
            Task { @MainActor in
                guard let self, await self.verifyHostKey(host) else { return }
                let dest = destHost.trimmingCharacters(in: .whitespaces).isEmpty ? "localhost" : destHost.trimmingCharacters(in: .whitespaces)
                var rule = self.forwards.first {
                    $0.hostId == host.id && $0.kind == .local && $0.destHost == dest && $0.destPort == destPort
                        && ["127.0.0.1", "localhost", ""].contains($0.bindAddress)
                }
                if rule == nil {
                    guard let port = LocalPort.free() else { self.keyOpError = String(localized: "No free local port was found."); return }
                    let r = ForwardRule(hostId: host.id, name: "Web \(dest):\(destPort)", kind: .local, bindAddress: "127.0.0.1",
                                        listenPort: port, destHost: dest, destPort: destPort)
                    self.saveForwardRule(r)
                    rule = r
                }
                guard let rule else { return }
                let m = self.forwardManager(for: host)
                if !m.status(rule.id).isRunning { self.toggleForward(rule) }
                // Wait up to 20 seconds for the tunnel.
                for _ in 0..<80 {
                    switch m.status(rule.id) {
                    case .active:
                        if openTab { self.openWebTab(host: host, rule: rule, https: https) } else { self.forwardPanelHost = host }   // When no tab can be created, direct the user to forwarding management.
                        return
                    case .failed(let why):
                        self.keyOpError = String(localized: "The tunnel couldn't start: \(why)"); return
                    default: try? await Task.sleep(nanoseconds: 250_000_000)
                    }
                }
                self.keyOpError = String(localized: "The tunnel didn't connect in time.")
            }
        }
    }

    /// Open an already-running local forward in an in-app web tab.
    func openForwardInApp(_ rule: ForwardRule, https: Bool) {
        guard let host = host(rule.hostId) else { return }
        forwardPanelHost = nil
        openWebTab(host: host, rule: rule, https: https)
    }

    private func openWebTab(host: Host, rule: ForwardRule, https: Bool) {
        let bind = (rule.bindAddress.isEmpty || rule.bindAddress == "0.0.0.0") ? "127.0.0.1" : rule.bindAddress
        guard let url = URL(string: "\(https ? "https" : "http")://\(bind):\(rule.listenPort)/") else { return }
        let id = addTab(.web, title: rule.name.isEmpty ? "\(rule.destHost):\(rule.destPort)" : rule.name, hostId: host.id)
        webSessions[id] = WebSession(host: host, url: url, tunnelSummary: rule.summary)
    }

    // MARK: Docker management
    /// Per-host capability results; absent keys hide tiles/menus until checked. Recheck on each overview opening.
    @Published private(set) var dockerAvailability: [String: Bool] = [:]
    @Published private(set) var systemdAvailability: [String: Bool] = [:]
    @Published private(set) var containerEngines: [String: [String]] = [:]   // Installed container engines: docker/podman.
    @Published private(set) var osKind: [String: String] = [:]     // uname -s result: Linux / Darwin / etc.
    private var dockerProbing = Set<String>()

    func hasDocker(_ host: Host) -> Bool { dockerAvailability[host.id] == true }
    /// Use Podman in tile/tab titles if it is the only installed engine.
    func engineTitle(_ host: Host) -> String { (containerEngines[host.id] ?? []) == ["podman"] ? "Podman" : "Docker" }
    func hasSystemd(_ host: Host) -> Bool { systemdAvailability[host.id] == true }

    /// Check Docker, systemd, and OS with one lightweight command.
    /// Keep previous values if ask-mode credentials are missing or connection fails.
    func probeDocker(_ host: Host) {
        let live = hosts.first(where: { $0.id == host.id }) ?? host
        guard !live.isRDP, let ssh = live.ssh, ssh.hasUsableCredentials, live.isLocal || !ssh.host.isEmpty,
              dockerProbing.insert(host.id).inserted else { return }
        Task { @MainActor in
            defer { dockerProbing.remove(host.id) }
            let script = DockerCommands.pathPrefix
                + "d=no; command -v docker >/dev/null 2>&1 && d=yes; p=no; command -v podman >/dev/null 2>&1 && p=yes; s=no; command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ] && s=yes; "
                + "echo \"docker=$d podman=$p systemd=$s os=$(uname -s 2>/dev/null)\""
            let r = await RemoteFS(ssh).run(script, timeout: 15)
            guard r.code == 0 else { return }   // Defer judgment for connection errors such as -1.
            let out = String(decoding: r.data, as: UTF8.self)
            let hasDockerCLI = out.contains("docker=yes"), hasPodman = out.contains("podman=yes"), systemd = out.contains("systemd=yes")
            let docker = hasDockerCLI || hasPodman
            let engines = (hasDockerCLI ? ["docker"] : []) + (hasPodman ? ["podman"] : [])
            if containerEngines[host.id] != engines { containerEngines[host.id] = engines }
            if dockerAvailability[host.id] != docker { dockerAvailability[host.id] = docker }
            if systemdAvailability[host.id] != systemd { systemdAvailability[host.id] = systemd }
            if let m = out.range(of: "os=") { osKind[host.id] = out[m.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines) }
        }
    }

    // MARK: Process management
    private var processSessions: [Int: ProcessSession] = [:]

    func processSession(for tabId: Int) -> ProcessSession? { processSessions[tabId] }

    func openProcesses(_ host: Host) {
        if let existing = tabs.first(where: { $0.kind == .processes && $0.hostId == host.id }) {
            activeTabId = existing.id
            return
        }
        requireAuth(host) { [weak self] in
            Task { @MainActor in
                guard let self, await self.verifyHostKey(host) else { return }
                if let existing = self.tabs.first(where: { $0.kind == .processes && $0.hostId == host.id }) {
                    self.activeTabId = existing.id; return
                }
                let id = self.addTab(.processes, title: String(localized: "Processes"), hostId: host.id)
                let s = ProcessSession(host: host)
                self.processSessions[id] = s
                s.refresh()
            }
        }
    }

    // MARK: Network tools (one app-wide tab in a separate group)
    static let netToolsKey = "__nettools__"
    private var netToolsSessions: [Int: NetToolsSession] = [:]

    func netToolsSession(for tabId: Int) -> NetToolsSession? { netToolsSessions[tabId] }

    /// One tab per tool; select existing tabs and update only server/target values.
    func openNetTools(_ request: NetToolsRequest = NetToolsRequest()) {
        if let t = tabs.first(where: { $0.kind == .netTools && $0.title == request.tool.title }), let s = netToolsSessions[t.id] {
            s.apply(request); activeTabId = t.id; return
        }
        let id = addTab(.netTools, title: request.tool.title, hostId: Self.netToolsKey)
        let s = NetToolsSession(tool: request.tool)
        s.serverId = hosts.first(where: { !$0.isLocal && $0.ssh != nil })?.id ?? ""
        s.apply(request)
        netToolsSessions[id] = s
    }

    /// One SSH Key Manager tab under Tools for real ~/.ssh files.
    let sshKeyManagerModel = SSHKeyManagerModel()
    func openKeyManager() {
        if let t = tabs.first(where: { $0.kind == .keyManager }) { activeTabId = t.id; return }
        addTab(.keyManager, title: String(localized: "SSH Key Manager"), hostId: Self.netToolsKey)
    }

    var isKeyManagerActive: Bool {
        guard let id = activeTabId else { return false }
        return tabs.first(where: { $0.id == id })?.kind == .keyManager
    }

    func isNetToolActive(_ tool: NetTool) -> Bool {
        guard let id = activeTabId, let t = tabs.first(where: { $0.id == id }) else { return false }
        return t.kind == .netTools && t.title == tool.title
    }

    // MARK: systemd service management
    private var serviceSessions: [Int: ServiceSession] = [:]

    func serviceSession(for tabId: Int) -> ServiceSession? { serviceSessions[tabId] }

    func openServices(_ host: Host) {
        if let existing = tabs.first(where: { $0.kind == .services && $0.hostId == host.id }) {
            activeTabId = existing.id
            return
        }
        requireAuth(host) { [weak self] in
            Task { @MainActor in
                guard let self, await self.verifyHostKey(host) else { return }
                if let existing = self.tabs.first(where: { $0.kind == .services && $0.hostId == host.id }) {
                    self.activeTabId = existing.id; return
                }
                let id = self.addTab(.services, title: String(localized: "Services"), hostId: host.id)
                let s = ServiceSession(host: host)
                self.serviceSessions[id] = s
                s.refresh()
            }
        }
    }

    /// Follow service logs through journalctl -f in the shared tail view.
    func openServiceLogs(_ service: SystemdService, host: Host, sudo: Bool) {
        let key = "service:" + service.name
        if let existing = tabs.first(where: { $0.kind == .tail && $0.hostId == host.id && $0.filePath == key }) {
            activeTabId = existing.id
            return
        }
        let id = addTab(.tail, title: "logs " + service.shortName, hostId: host.id, filePath: key)
        let s = TailSession(host: host, path: "journalctl -u " + service.name, script: ServiceCommands.logsScript(name: service.name, sudo: sudo))
        tailSessions[id] = s
        s.start()
    }

    private var dockerSessions: [Int: DockerSession] = [:]

    func dockerSession(for tabId: Int) -> DockerSession? { dockerSessions[tabId] }

    /// Open/select one Docker-management tab per host.
    func openDocker(_ host: Host) {
        if let existing = tabs.first(where: { $0.kind == .docker && $0.hostId == host.id }) {
            activeTabId = existing.id
            return
        }
        requireAuth(host) { [weak self] in
            Task { @MainActor in
                guard let self, await self.verifyHostKey(host) else { return }
                if let existing = self.tabs.first(where: { $0.kind == .docker && $0.hostId == host.id }) {
                    self.activeTabId = existing.id; return
                }
                let id = self.addTab(.docker, title: self.engineTitle(host), hostId: host.id)
                let s = DockerSession(host: host, engines: self.containerEngines[host.id] ?? ["docker"])
                self.dockerSessions[id] = s
                s.refresh()
            }
        }
    }

    /// Follow container logs using the shared tail view.
    func openDockerLogs(container: DockerContainer, host: Host, sudo: Bool, engine: String = "docker") {
        let key = "docker:" + container.id
        if let existing = tabs.first(where: { $0.kind == .tail && $0.hostId == host.id && $0.filePath == key }) {
            activeTabId = existing.id
            return
        }
        let id = addTab(.tail, title: "logs " + container.name, hostId: host.id, filePath: key)
        let s = TailSession(host: host, path: "docker logs " + container.name,
                            script: DockerCommands.logsScript(id: container.id, sudo: sudo, engine: engine))
        tailSessions[id] = s
        s.start()
    }

    /// Send a container-shell command to that server's terminal.
    func openDockerShell(container: DockerContainer, host: Host, sudo: Bool, engine: String = "docker") {
        sendCommandToTerminal(hostId: host.id, command: DockerCommands.execShell(name: container.name, sudo: sudo, engine: engine))
    }

    // MARK: tail (live logs)
    private var tailSessions: [Int: TailSession] = [:]

    func tailSession(for tabId: Int) -> TailSession? { tailSessions[tabId] }

    // MARK: Folder disk usage (du)
    private var diskUsageSessions: [Int: DiskUsageSession] = [:]

    func diskUsageSession(for tabId: Int) -> DiskUsageSession? { diskUsageSessions[tabId] }

    /// Show disk analysis in the editor area, reusing one per-host analysis view when another directory is selected.
    /// Also reveal the right panel/folded folder file list and select the analyzed directory.
    func openDiskUsage(path: String, host: Host) {
        filePanelVisible = true
        NotificationCenter.default.post(name: .revealFolderFileList, object: nil)
        if let existing = tabs.first(where: { $0.kind == .diskUsage && $0.hostId == host.id }),
           let s = diskUsageSessions[existing.id] {
            s.navigate(to: path)
            activeTabId = existing.id
        } else {
            let id = addTab(.diskUsage, title: String(localized: "Space Analyzer"), hostId: host.id, filePath: path)
            let s = DiskUsageSession(host: host, path: path)
            diskUsageSessions[id] = s
            s.refresh()
        }
        jumpToExplorer(path: path, host: host)
    }

    /// Follow a text file with tail -F, selecting an existing same-host/path tab when available.
    func openTail(path: String, host: Host) {
        if let existing = tabs.first(where: { $0.kind == .tail && $0.hostId == host.id && $0.filePath == path }) {
            activeTabId = existing.id
            return
        }
        let name = (path as NSString).lastPathComponent
        let id = addTab(.tail, title: "tail " + name, hostId: host.id, filePath: path)
        let s = TailSession(host: host, path: path)
        tailSessions[id] = s
        s.start()
    }

    /// Open a remote editor/preview tab, selecting an existing same-host/path tab instead of duplicating.
    func openFile(_ file: RemoteFile, host: Host) {
        guard !file.isDir else { return }
        let limit: Int64 = EditorState.isImageName(file.name) ? 16_000_000 : 100_000
        if file.size > limit {
            let alert = NSAlert()
            alert.messageText = String(localized: "File exceeds editor limit")
            alert.informativeText = String(localized: "File size: \(humanSize(file.size)). Editor limit: \(humanSize(limit)). Download it to open with another app.")
            alert.addButton(withTitle: String(localized: "Download and Open"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            if alert.runModal() == .alertFirstButtonReturn { downloadFiles([file], host: host, thenOpen: true) }
            return
        }
        recordRecentFile(file, hostId: host.id)
        revealInExplorer(file.path, host: host)   // Highlight the file in the left explorer.
        if let existing = tabs.first(where: {
            $0.kind == .editor && $0.hostId == host.id && $0.filePath == file.path
        }) {
            activeTabId = existing.id
            return
        }
        let id = addTab(.editor, title: file.name, hostId: host.id, filePath: file.path)
        let st = EditorState(file: file, host: host, fs: RemoteFS(host.ssh ?? SSHConnection()))
        editorStates[id] = st
        st.loadIfNeeded()   // Start loading on click immediately instead of waiting for view appearance.
    }

    /// Find an editor by path for refresh/rename checks, including open/dirty state.
    func openEditor(forPath path: String, host: Host) -> EditorState? {
        guard let tab = tabs.first(where: { $0.kind == .editor && $0.hostId == host.id && $0.filePath == path }) else {
            return nil
        }
        return editorStates[tab.id]
    }

    // MARK: - File context actions

    /// Refresh directories by listing again, or warn/navigate upward if removed. For open editor files, reload after confirming dirty changes;
    /// otherwise refresh the parent directory. Other editors remain untouched and rely on their own save-conflict protection.
    func fileMenuRefresh(_ file: RemoteFile, host: Host, tree: FileTreeState) {
        Task { @MainActor in
            if file.isDir {
                handleRefreshOutcome(await tree.refreshDir(file.path), name: file.name, isDir: true, tree: tree, path: file.path)
            } else if let ed = openEditor(forPath: file.path, host: host) {
                if ed.isDirty {
                    pendingFileRefresh = RefreshConflictContext(editorState: ed, fileName: file.name)
                } else {
                    ed.reload()
                }
            } else {
                handleRefreshOutcome(await tree.refreshParent(of: file.path), name: file.name, isDir: false, tree: tree, path: file.path)
            }
        }
    }

    func confirmFileRefreshReload() {
        let ed = pendingFileRefresh?.editorState
        pendingFileRefresh = nil
        ed?.reload()
    }

    private func handleRefreshOutcome(_ outcome: FileTreeState.RefreshOutcome, name: String, isDir: Bool, tree: FileTreeState, path: String) {
        switch outcome {
        case .ok:
            break
        case .gone:
            if isDir {
                tree.removeAndSelectParent(path)
                pendingFileInfo = FileInfoContext(title: String(localized: "Directory has been deleted"),
                    message: String(localized: "\"\(name)\" no longer exists on the remote. It has been removed and you've been taken to the parent directory."))
            } else {
                pendingFileInfo = FileInfoContext(title: String(localized: "Directory doesn't exist"), message: String(localized: "The directory containing this file no longer exists on the remote."))
            }
        case .failed(let msg):
            pendingFileInfo = FileInfoContext(title: String(localized: "Refresh failed"), message: msg)
        }
    }

    // ---------- Transfer queue ----------
    // Upload/download share the settings concurrency pool; queue excess tasks and fill slots when tasks finish.
    private var maxConcurrentTransfers: Int { max(1, AppSettings.shared.maxConcurrentTransfers) }

    /// Whether the host has active transfers, guarding closeMaster against interrupting shared-master transfers (review R20).
    func hostHasRunningTransfer(_ hostId: String) -> Bool {
        transfers.contains { $0.hostId == hostId && $0.phase == .running }
    }

    /// Enqueue a transfer, present its dialog, and try starting within the concurrency limit.
    private func enqueueTransfer(_ task: UploadTask) {
        task.onFinished = { [weak self] in self?.transferDidFinish() }
        task.onPauseStateChanged = { [weak self] in self?.pumpTransferQueue() }
        // Per-file locks serialize only actual same-destination writes, avoiding whole-task conflicts and unused capacity.
        task.acquirePathLock = { [weak self] key in
            guard let self else { return }
            await self.acquireTransferPath(key)
        }
        task.releasePathLock = { [weak self] key in
            guard let self else { return }
            self.releaseTransferPath(key)
        }
        transfers.append(task)
        // Dialog-free downloads use a fly-in arc toward the bottom-left button; other tasks open their dialog normally.
        if task.direction == .download && !AppSettings.shared.showDownloadDialog {
            triggerDownloadFly(for: task)
        } else {
            focusedTransferId = task.id   // Automatically show the new task's dialog, preserving the single-task experience.
        }
        pumpTransferQueue()
    }

    /// Trigger one download fly-in arc toward Background Tasks.
    /// Start at the first selected file row, otherwise pointer/default offset; end at the background button center.
    /// Keep coordinates in SwiftUI global space and convert to overlay origin at rendering, matching different window sizes; see ContentView.
    /// Clear the one-shot event after animation, leaving no permanent animation work.
    private func triggerDownloadFly(for task: UploadTask) {
        guard backgroundButtonCenter != .zero else { return }
        let from: CGPoint
        if let p = task.items.first?.remotePath, let r = fileRowGlobalFrames[p] {
            from = CGPoint(x: r.midX, y: r.midY)            // Selected file-row center.
        } else if let m = Self.currentMouseGlobal() {
            from = m                                        // For context-menu downloads, the pointer is already over the file.
        } else {
            from = CGPoint(x: backgroundButtonCenter.x + 220, y: backgroundButtonCenter.y - 220)
        }
        flyTransfer = FlyEvent(id: UUID(), from: from)
    }

    /// Convert current pointer location to top-left-origin SwiftUI global coordinates for animation start.
    private static func currentMouseGlobal() -> CGPoint? {
        guard let win = NSApp.keyWindow ?? NSApp.mainWindow, let cv = win.contentView else { return nil }
        let p = cv.convert(win.mouseLocationOutsideOfEventStream, from: nil)   // contentView coordinates use a bottom-left origin.
        return CGPoint(x: p.x, y: cv.bounds.height - p.y)                      // Flip to a top-left origin.
    }

    // Per-destination-file mutex on MainActor, so Set/dictionary access has no data races.
    // Old whole-task conflict scheduling skipped queued tasks sharing any filename with a long transfer, leaving capacity idle.
    // Lock one destination at runtime instead: start queued tasks concurrently and wait only for genuine simultaneous writes to the same file.
    private var lockedTransferPaths: Set<String> = []
    private var transferPathWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    /// Acquire a destination write lock, suspending if held; release wakes all waiters to compete/check again.
    func acquireTransferPath(_ key: String) async {
        while lockedTransferPaths.contains(key) {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                transferPathWaiters[key, default: []].append(c)
            }
        }
        lockedTransferPaths.insert(key)
    }
    /// Release the write lock and wake all waiters; one acquires it and the rest suspend again.
    func releaseTransferPath(_ key: String) {
        lockedTransferPaths.remove(key)
        let waiters = transferPathWaiters.removeValue(forKey: key) ?? []
        for w in waiters { w.resume() }
    }

    /// Pause; pausedReleasesSlot controls capacity retention, and onPauseStateChanged pumps the queue when capacity changes.
    func pauseTransfer(_ task: UploadTask) { task.pause() }

    /// Resume immediately if capacity allows, otherwise wait for pump admission after a slot frees.
    func resumeTransfer(_ task: UploadTask) {
        guard task.phase == .paused else { return }
        if !AppSettings.shared.pausedReleasesSlot {
            // With slot reservation, the task already owns capacity and can resume without exceeding the limit.
            task.requestResume(slotFree: true)
        } else {
            task.requestResume(slotFree: transferSlotsOccupied() < maxConcurrentTransfers)
        }
        pumpTransferQueue()
    }

    /// Occupied slots always include running tasks, and paused tasks only when capacity is reserved.
    private func transferSlotsOccupied() -> Int {
        let running = transfers.filter { $0.phase == .running }.count
        if AppSettings.shared.pausedReleasesSlot { return running }
        return running + transfers.filter { $0.phase == .paused }.count
    }

    /// Pump within the concurrency limit, admitting waiting resume requests before new queued tasks.
    /// acquireTransferPath serializes same-file writes at runtime; scheduling checks only slots, not whole-task filename conflicts,
    /// so a long transfer holding a matching file cannot leave queued tasks waiting on otherwise empty capacity.
    private func pumpTransferQueue() {
        let cap = maxConcurrentTransfers
        // Prioritize already-started tasks whose resume requests await free capacity over new tasks.
        if AppSettings.shared.pausedReleasesSlot {
            for task in transfers where task.phase == .paused && task.awaitingSlot {
                guard transferSlotsOccupied() < cap else { break }
                task.admitResume()   // Set .running synchronously so transferSlotsOccupied() reflects it immediately.
            }
        }
        for task in transfers where task.phase == .queued {
            guard transferSlotsOccupied() < cap else { break }
            task.start()   // start() synchronously sets .running so later tasks in this pump iteration see its occupied slot.
        }
    }

    /// On terminal phase, admit the next task and refresh active counts/badges; phase changes do not mutate the transfers array.
    private func transferDidFinish() {
        pumpTransferQueue()
        objectWillChange.send()
    }

    /// Select multiple local files for upload to a directory, supporting resume/compression/name-conflict prompts.
    func beginUpload(into folder: RemoteFile, host: Host) {
        guard folder.isDir else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Upload")
        panel.message = String(localized: "Choose files to upload to \"\(folder.name)\"")
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        startUpload(files: panel.urls, destDir: folder.path, host: host)
    }

    // ---------- Terminal toolbar ----------
    /// Choose local files for upload to this terminal's cwd, falling back to remote home.
    func presentUploadToTerminal(_ tabId: Int) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Upload")
        if let cwd = tabCwd[tabId] { panel.message = String(localized: "Choose files to upload to \"\(cwd)\"") }
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        uploadDroppedFiles(panel.urls, toTabId: tabId)
    }

    /// Open this terminal's cwd in the file browser.
    func openFilesAtTerminalCwd(_ tabId: Int) {
        guard let tab = tabs.first(where: { $0.id == tabId }), let host = host(tab.hostId) else { return }
        openHostFiles(host, at: tabCwd[tabId])
    }

    /// Create a file in terminal cwd or remote home, then open it directly in the editor.
    func requestNewFileAtTerminalCwd(_ tabId: Int) {
        guard let tab = tabs.first(where: { $0.id == tabId }), let host = host(tab.hostId),
              let ssh = host.ssh, !ssh.host.isEmpty else { return }
        let target = fileTreeState(forTab: tabId, host: host)   // Refresh the tab's cwd-following sidebar tree after creation too.
        Task { @MainActor in
            let dir: String
            if let known = tabCwd[tabId] { dir = known } else { dir = await RemoteFS(ssh).home() }
            fileMenuRequestCreate(isDir: false, inDir: dir, host: host, target: target)
        }
    }

    /// Write to a terminal through its libssh2 SSH driver or the local terminal view.
    func sendTerminalText(_ tabId: Int, _ text: String) {
        if let driver = termDrivers[tabId] { driver.sendText(text) } else { terminals[tabId]?.send(txt: text) }
    }

    /// AI Send to Terminal uses an existing terminal immediately, or opens one and
    /// waits for login's first OSC 7 signal through [[handleTerminalCwd]] before sending.
    private var terminalPendingHostText: [String: String] = [:]
    func sendCommandToTerminal(hostId: String, command: String) {
        guard let host = host(hostId), !host.isRDP else { return }
        let text = command.hasSuffix("\n") ? command : command + "\r"
        if let existing = tabs.first(where: { $0.kind == .terminal && $0.hostId == hostId }) {
            activeTabId = existing.id
            sendTerminalText(existing.id, text)
            return
        }
        terminalPendingHostText[hostId] = text
        openHostTerminal(host, forceNew: false)
    }

    /// AI command input panel for the current SSH terminal.
    func presentAIPrompt(forTerminal tabId: Int) {
        guard let tab = tabs.first(where: { $0.id == tabId }),
              tab.kind == .terminal,
              let host = host(tab.hostId), !host.isRDP else { return }
        aiPromptContext = AIPromptContext(tabId: tabId, hostName: host.name, directory: tabCwd[tabId])
    }

    /// Run the AI CLI through the remote shell; if absent, show installation commands in the terminal instead of executing the prompt.
    func runAIPrompt(_ request: AIPromptRequest) {
        let prompt = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }

        let executable = request.provider.executable
        let command: String
        switch request.provider {
        case .codex:
            // Explicitly bypass Codex repository-trust checks so commands work directly from remote home too.
            let resume = request.continueSession ? " resume --last" : ""
            command = "codex exec" + resume + " --skip-git-repo-check" + request.modelArgument + " " + Self.shellQuote(prompt)
        case .claude:
            let resume = request.continueSession ? " --continue" : ""
            command = "claude -p" + resume + request.modelArgument + " " + Self.shellQuote(prompt)
        }
        let installHint = request.provider.installCommand
        // Send CR like SwiftTerm Return; LF alone may not execute the input line on some remote PTYs.
        let script = "if command -v \(executable) >/dev/null 2>&1; then \(command); else printf '\\n\(request.provider.displayName) CLI is required on this server. Install it with:\\n  \(installHint)\\n\\n'; fi\r"
        sendTerminalText(request.tabId, script)
        aiPromptContext = nil
    }

    /// SSH-only external file drop uploads to OSC7 cwd, falling back to remote home.
    func uploadDroppedFiles(_ urls: [URL], toTabId tabId: Int) {
        guard let tab = tabs.first(where: { $0.id == tabId }),
              let host = host(tab.hostId), let ssh = host.ssh, !ssh.host.isEmpty else { return }
        // Upload files only; skip directories.
        let files = urls.filter { !((try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false) }
        guard !files.isEmpty else {
            pendingFileInfo = FileInfoContext(title: String(localized: "Couldn't Upload"), message: String(localized: "Dragging folders isn't supported yet. Please drop files instead."))
            return
        }
        Task { @MainActor in
            let cwd: String
            if let known = tabCwd[tabId] { cwd = known } else { cwd = await RemoteFS(ssh).home() }
            startUpload(files: files, destDir: cwd, host: host)
        }
    }

    /// File-browser drag/drop uploads external files to the specified remote directory, skipping folders.
    func uploadFiles(_ urls: [URL], toDir dir: String, host: Host) {
        guard let ssh = host.ssh, !ssh.host.isEmpty, !dir.isEmpty else { return }
        let files = urls.filter { !((try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false) }
        guard !files.isEmpty else {
            pendingFileInfo = FileInfoContext(title: String(localized: "Couldn't Upload"), message: String(localized: "Dragging folders isn't supported yet. Please drop files instead."))
            return
        }
        startUpload(files: files, destDir: dir, host: host)
    }

    /// Core upload startup: enqueue within concurrency limits, then refresh affected cached tree directories after completion.
    private func startUpload(files: [URL], destDir: String, host: Host) {
        guard !files.isEmpty else { return }
        let task = UploadTask(files: files, destDir: destDir,
                              fs: RemoteFS(host.ssh ?? SSHConnection())) { [weak self] in
            self?.refreshTrees(host: host, dir: destDir)
        }
        task.hostId = host.id
        task.hostName = host.name
        enqueueTransfer(task)
    }

    /// After upload/extraction, refresh only the affected directory level in each cached host tree/browser,
    /// preserving other expanded nodes instead of full reload. Skip trees without that directory to avoid network work.
    private func refreshTrees(host: Host, dir: String) {
        Task { @MainActor in
            if let t = hostExplorerTrees[host.id] { _ = await t.refreshDir(dir) }   // Host-level tree shared by editor sidebars.
            for (tabId, t) in fileTreeStates where tabHostId(tabId) == host.id {     // Per-session tab trees.
                _ = await t.refreshDir(dir)
            }
            for (tabId, b) in browserStates where tabHostId(tabId) == host.id && b.path == dir {  // SFTP browser currently showing that directory.
                b.reload()
            }
        }
    }

    private func tabHostId(_ tabId: Int) -> String? {
        tabs.first(where: { $0.id == tabId })?.hostId
    }

    func fileMenuRequestDelete(_ file: RemoteFile, host: Host, target: any FileOpsTarget) {
        Task { @MainActor in await showDeleteCommand(for: [file], host: host, target: target) }
    }

    /// Do not execute deletion in-app; copy a command for user review in the terminal.
    private func showDeleteCommand(for files: [RemoteFile], host: Host, target: any FileOpsTarget) async {
        let account = host.isLocal ? NSUserName() : (host.ssh?.user ?? "")
        var details: [String] = []
        var commands: [String] = []
        for file in files {
            let parent = (file.path as NSString).deletingLastPathComponent
            let parentPath = parent.isEmpty ? "/" : parent
            let parentFile = RemoteFile(name: (parentPath as NSString).lastPathComponent,
                                        path: parentPath, kind: .directory, size: 0, modified: nil)
            let filePerms = await target.currentPerms(file)
            let parentPerms = await target.currentPerms(parentFile)
            let mode: (Int?) -> String = { $0.map { String(format: "%03o", $0 & 0o777) } ?? String(localized: "Unknown") }
            details.append("\(file.path) — \(String(localized: "Target permissions")): \(mode(filePerms)), \(String(localized: "Parent permissions")): \(mode(parentPerms))")
            let requiresSudo: Bool
            if host.isLocal {
                requiresSudo = !FileManager.default.isWritableFile(atPath: parentPath)
            } else {
                requiresSudo = parentPerms.map { ($0 & 0o222) == 0 || ($0 & 0o111) == 0 } ?? false
            }
            commands.append("\(requiresSudo ? "sudo " : "")rm\(file.isDir ? " -r" : "") -- \(Self.shellQuote(file.path))")
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "Copy delete command")
        alert.informativeText = "\(String(localized: "Account")): \(account)\n\(details.joined(separator: "\n"))\n\n\(String(localized: "Permanent deletion; files will not go to Trash."))\n\n\(commands.joined(separator: "\n"))"
        alert.addButton(withTitle: String(localized: "Copy Delete Command"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(commands.joined(separator: "\n"), forType: .string)
        }
    }

    /// Keep delete confirmation visible with a spinner; cancelFileDelete can interrupt processing.
    /// Large-directory rm -rf can be slow. Close only after success, report errors, and refresh actual state after cancellation.
    func confirmFileDelete() {
        guard let ctx = pendingFileDelete, !fileDeleteBusy else { return }
        fileDeleteBusy = true
        let handle = CommandHandle()
        deleteHandle = handle
        let host = ctx.host
        let parent = (ctx.file.path as NSString).deletingLastPathComponent
        let dir = parent.isEmpty ? "/" : parent
        Task { @MainActor in
            let r = await ctx.target.performDelete(ctx.file, handle: handle)
            deleteHandle = nil
            fileDeleteBusy = false
            if handle.isCancelled {
                refreshTrees(host: host, dir: dir)   // Cancellation may leave partial deletion; refresh to reflect reality.
                return
            }
            pendingFileDelete = nil
            if case .failure(let e) = r {
                pendingFileInfo = FileInfoContext(title: String(localized: "Delete failed"), message: e.message)
            }
        }
    }

    /// Cancel active deletion by stopping the remote command, let completion handle cleanup/refresh, then close the dialog.
    func cancelFileDelete() {
        if fileDeleteBusy { deleteHandle?.cancel() }
        pendingFileDelete = nil
    }

    // MARK: - Batch deletion

    func requestBatchDelete(_ files: [RemoteFile], host: Host, target: any FileOpsTarget) {
        guard !files.isEmpty else { return }
        Task { @MainActor in await showDeleteCommand(for: files, host: host, target: target) }
    }

    /// Delete items sequentially with the dialog/spinner visible; close afterward or show any failure.
    func confirmBatchDelete() {
        guard let ctx = pendingBatchDelete, !batchDeleteBusy else { return }
        batchDeleteBusy = true
        Task { @MainActor in
            var failed: [String] = []
            for f in ctx.files {
                if case .failure = await ctx.target.performDelete(f, handle: nil) { failed.append(f.name) }
            }
            batchDeleteBusy = false
            pendingBatchDelete = nil
            if !failed.isEmpty {
                let shown = failed.prefix(8).joined(separator: "、")
                pendingFileInfo = FileInfoContext(title: String(localized: "Some Deletions Failed"),
                                                  message: String(localized: "Couldn't delete: \(shown)\(failed.count > 8 ? String(localized: " and more") : "")"))
            }
        }
    }

    func cancelBatchDelete() { if !batchDeleteBusy { pendingBatchDelete = nil } }

    func fileMenuRequestRename(_ file: RemoteFile, host: Host, target: any FileOpsTarget) {
        pendingFileRename = FileOpContext(file: file, host: host, target: target)
    }

    func confirmFileRename(newName: String) {
        guard let ctx = pendingFileRename else { return }
        pendingFileRename = nil
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/") else {
            pendingFileInfo = FileInfoContext(title: String(localized: "Invalid name"), message: String(localized: "Name cannot be empty or contain “/”."))
            return
        }
        if trimmed == ctx.file.name { return }
        let oldPath = ctx.file.path
        Task { @MainActor in
            switch await ctx.target.performRename(ctx.file, newName: trimmed) {
            case .success(let newPath):
                syncRenamedEditorTab(oldPath: oldPath, newName: trimmed, newPath: newPath,
                                     kind: ctx.file.kind, size: ctx.file.size, modified: ctx.file.modified,
                                     host: ctx.host)
            case .failure(let e):
                pendingFileInfo = FileInfoContext(title: String(localized: "Rename Failed"), message: e.message)
            }
        }
    }

    /// After rename, synchronize open editor tabs unless dirty; warn without modifying dirty editors, otherwise update title/path/save destination.
    private func syncRenamedEditorTab(oldPath: String, newName: String, newPath: String,
                                      kind: RemoteFile.Kind, size: Int64, modified: Date?, host: Host) {
        guard let idx = tabs.firstIndex(where: {
            $0.kind == .editor && $0.hostId == host.id && $0.filePath == oldPath
        }) else { return }   // If not open in an editor, the refreshed tree is sufficient.
        let tabId = tabs[idx].id
        if editorStates[tabId]?.isDirty == true {
            pendingFileInfo = FileInfoContext(title: String(localized: "Renamed"),
                message: String(localized: "This file has unsaved changes in the editor and the tab is out of sync. Saving will still write to the original filename, so save or close it before renaming."))
            return
        }
        let newFile = RemoteFile(name: newName, path: newPath, kind: kind, size: size, modified: modified)
        tabs[idx].title = newName
        tabs[idx].filePath = newPath
        editorStates[tabId]?.rebind(to: newFile)
    }

    func fileMenuRequestChmod(_ file: RemoteFile, host: Host, target: any FileOpsTarget) {
        Task { @MainActor in
            let perms = await target.currentPerms(file) ?? (file.isDir ? 0o755 : 0o644)
            pendingFileChmod = ChmodContext(file: file, host: host, target: target, mode: perms)
        }
    }

    func confirmFileChmod(mode: Int) {
        guard let ctx = pendingFileChmod else { return }
        pendingFileChmod = nil
        Task { @MainActor in
            if case .failure(let e) = await ctx.target.performChmod(ctx.file, mode: String(mode, radix: 8)) {
                pendingFileInfo = FileInfoContext(title: String(localized: "Failed to change permissions"), message: e.message)
            }
        }
    }

    // MARK: - New file / folder

    func fileMenuRequestCreate(isDir: Bool, inDir dir: String, host: Host, target: any FileOpsTarget) {
        pendingFileCreate = CreateContext(dir: dir, isDir: isDir, host: host, target: target)
    }

    func confirmFileCreate(name: String) {
        guard let ctx = pendingFileCreate else { return }
        pendingFileCreate = nil
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/") else {
            pendingFileInfo = FileInfoContext(title: String(localized: "Invalid name"), message: String(localized: "Name cannot be empty or contain “/”."))
            return
        }
        Task { @MainActor in
            switch await ctx.target.performCreate(trimmed, isDir: ctx.isDir, inDir: ctx.dir) {
            case .failure(let e):
                pendingFileInfo = FileInfoContext(title: ctx.isDir ? String(localized: "Couldn't Create Folder") : String(localized: "Couldn't Create File"), message: e.message)
            case .success where !ctx.isDir:
                // Open a new file directly in the editor; Command-S writes it back.
                let path = (ctx.dir == "/" ? "" : ctx.dir) + "/" + trimmed
                openFile(RemoteFile(name: trimmed, path: path, kind: .file, size: 0, modified: nil), host: ctx.host)
            case .success:
                break
            }
        }
    }

    // MARK: - Download

    /// Download to the configured/chosen directory, reusing transfer progress/background UI; reveal the result in Finder after completion.
    /// Share the upload concurrency queue. Support files only, not directories yet.
    func downloadFiles(_ files: [RemoteFile], host: Host, thenOpen: Bool = false) {
        let downloadable = files.filter { !$0.isDir }
        guard !downloadable.isEmpty else { return }
        if host.isLocal {
            if thenOpen { showOpenWithApps(for: URL(fileURLWithPath: downloadable[0].path)) }
            return
        }
        guard let ssh = host.ssh, !ssh.host.isEmpty else { return }
        let dir: URL
        if AppSettings.shared.downloadAskEachTime {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = String(localized: "Download here")
            panel.message = String(localized: "Choose a folder to download to")
            panel.directoryURL = AppSettings.shared.resolvedDownloadDir
            guard panel.runModal() == .OK, let u = panel.url else { return }
            dir = u
        } else {
            dir = AppSettings.shared.resolvedDownloadDir
        }
        // Do not automatically open Finder and interrupt the user; system notifications report completion.
        // Deduplicate local names against existing files and active downloads so same-name files from different hosts/sources can transfer concurrently.
        let localURLs = resolveDownloadURLs(downloadable, dir: dir)
        let task = UploadTask(download: downloadable, toLocalURLs: localURLs, inDir: dir, fs: RemoteFS(ssh)) { [weak self] in
            guard thenOpen, NSApp.isActive, let url = localURLs.first,
                  FileManager.default.fileExists(atPath: url.path) else { return }
            Task { @MainActor [weak self] in self?.showOpenWithApps(for: url) }
        }
        task.hostId = host.id
        task.hostName = host.name
        enqueueTransfer(task)
    }

    /// Compute nonconflicting batch download paths without overwriting existing local files.
    /// If on-disk or running/queued/paused downloads occupy a name, add " (n)" before the extension, matching Finder/browser conventions.
    /// Same-name downloads from different sources can finish independently; repeated downloads do not overwrite earlier files.
    private func resolveDownloadURLs(_ files: [RemoteFile], dir: URL) -> [URL] {
        var taken = Set<String>()
        for t in transfers where t.direction == .download {
            switch t.phase { case .done, .cancelled: break
            default: for it in t.items { taken.insert(it.url.path) } }
        }
        let fm = FileManager.default
        var result: [URL] = []
        for f in files {
            var candidate = dir.appendingPathComponent(f.name)
            if fm.fileExists(atPath: candidate.path) || taken.contains(candidate.path) {
                let base = (f.name as NSString).deletingPathExtension
                let ext = (f.name as NSString).pathExtension
                var n = 1
                repeat {
                    let newName = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
                    candidate = dir.appendingPathComponent(newName)
                    n += 1
                } while fm.fileExists(atPath: candidate.path) || taken.contains(candidate.path)
            }
            taken.insert(candidate.path)   // Deduplicate within the batch too.
            result.append(candidate)
        }
        return result
    }

    // MARK: - Extraction

    /// Request destination selection in the extraction dialog; afterward refresh the archive directory and send a system notification.
    /// Extraction runs independently of transfers, but only one extraction task is allowed to avoid compact-status/destination conflicts.
    func requestExtract(_ file: RemoteFile, host: Host) {
        guard !file.isDir, let kind = ArchiveKind.detect(file.name),
              let ssh = host.ssh, !ssh.host.isEmpty else { return }
        if let t = extractTask, t.phase == .running {
            pendingFileInfo = FileInfoContext(title: String(localized: "An extraction is already in progress"),
                                              message: String(localized: "Wait for the current extraction to finish before starting a new one."))
            return
        }
        let parent = (file.path as NSString).deletingLastPathComponent
        let dir = parent.isEmpty ? "/" : parent
        let task = ExtractTask(archive: file, kind: kind, parentDir: dir,
                               fs: RemoteFS(ssh)) { [weak self] in
            self?.refreshTrees(host: host, dir: dir)
        }
        task.hostId = host.id
        task.hostName = host.name
        extractTask = task
        showExtractDialog = true
    }

    func selectTab(_ id: Int) {
        activeTabId = id
        // Selecting an editor tab updates the explorer highlight to its file.
        if let tab = tabs.first(where: { $0.id == id }), tab.kind == .editor,
           let path = tab.filePath, let host = host(tab.hostId) {
            revealInExplorer(path, host: host)
        }
    }

    /// Keeping views alive in Workspace's ZStack means tab changes no longer rebuild views or take focus through makeNSView.
    /// Explicitly focus activeTabId and remove focus from hidden terminal/editor sessions to prevent typing into hidden views.
    func focusActiveTab() {
        guard let id = activeTabId, let tab = tabs.first(where: { $0.id == id }) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first
            switch tab.kind {
            case .terminal:
                if let tv = self.terminals[id] { (tv.window ?? window)?.makeFirstResponder(tv) }
            case .editor:
                if let v = self.editorStates[id]?.focusView {
                    (v.window ?? window)?.makeFirstResponder(v)
                } else {
                    self.resignTabResponderIfNeeded(window)
                }
            default:
                self.resignTabResponderIfNeeded(window)
            }
        }
    }

    /// Reclaim focus only if first responder is inside a tab's terminal/editor,
    /// leaving unrelated focus such as sidebar search alone.
    private func resignTabResponderIfNeeded(_ window: NSWindow?) {
        guard let window, let fr = window.firstResponder as? NSView else { return }
        let inTerminal = terminals.values.contains { fr == $0 || fr.isDescendant(of: $0) }
        let inEditor = editorStates.values.contains {
            guard let v = $0.focusView else { return false }
            return fr == v || fr.isDescendant(of: v)
        }
        if inTerminal || inEditor { window.makeFirstResponder(nil) }
    }

    @Published var pendingCloseTabId: Int? = nil
    @Published var pendingTabRename: TabRenameContext? = nil      // Rename-tab input dialog.
    @Published var pendingMultiClose: MultiCloseContext? = nil    // Aggregated batch-close confirmation.

    func closeTab(_ id: Int) {
        if shouldConfirmClose(id) {
            pendingCloseTabId = id
        } else {
            performCloseTab(id)
        }
    }

    func confirmPendingClose() {
        if let id = pendingCloseTabId {
            performCloseTab(id)
        }
        pendingCloseTabId = nil
    }

    func cancelPendingClose() {
        pendingCloseTabId = nil
    }

    /// Choose a unique eligible tab title: base first, then append " 2", " 3", etc.
    private func uniqueTabTitle(_ base: String, among predicate: (TabItem) -> Bool) -> String {
        let taken = Set(tabs.filter(predicate).map(\.title))
        if !taken.contains(base) { return base }
        var n = 2
        while taken.contains("\(base) (\(n))") { n += 1 }
        return "\(base) (\(n))"
    }

    /// Request tab rename through an input dialog.
    func requestRenameTab(_ id: Int) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        pendingTabRename = TabRenameContext(id: id, currentTitle: tab.title)
    }

    /// Reject names already used by another tab; otherwise rename in place.
    func renameTab(_ id: Int, to newName: String) {
        pendingTabRename = nil
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        if tabs.contains(where: { $0.id != id && $0.title == trimmed }) {
            pendingFileInfo = FileInfoContext(title: String(localized: "Name already in use"),
                message: String(localized: "A tag already uses \"\(trimmed)\". Choose a different name to keep them distinct."))
            return
        }
        tabs[idx].title = trimmed
    }

    /// Close Others/All uses performCloseTab cleanup per tab after one aggregated running-session/unsaved-change confirmation.
    func closeOtherTabs(keep id: Int) { requestMultiClose(tabs.filter { $0.id != id }.map(\.id)) }
    func closeAllTabs() { requestMultiClose(tabs.map(\.id)) }
    /// Close a specified tab set, such as one server's tabs, after aggregated active/dirty confirmation if needed.
    func closeTabs(_ ids: [Int]) { requestMultiClose(ids) }

    private func requestMultiClose(_ ids: [Int]) {
        guard !ids.isEmpty else { return }
        if ids.contains(where: { shouldConfirmClose($0) }) {
            pendingMultiClose = MultiCloseContext(ids: ids)
        } else {
            ids.forEach { performCloseTab($0) }
        }
    }

    func confirmMultiClose() {
        pendingMultiClose?.ids.forEach { performCloseTab($0) }
        pendingMultiClose = nil
    }
    func cancelMultiClose() { pendingMultiClose = nil }

    private func performCloseTab(_ id: Int) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        let closedHostId = tabs[idx].hostId
        let closedKind = tabs[idx].kind
        tabs.remove(at: idx)
        // Clear delegate callbacks before teardown to prevent reentrancy or unintended reconnect from exit callbacks.
        if let d = termDelegates[id] { d.onTerminated = nil; d.onCwd = nil }
        if let drv = termDrivers[id] { drv.onTerminated = nil; drv.onCwd = nil; drv.close() }   // SSH driver: stop pump and close connection.
        // SIGTERM the local child and close its PTY fd. SSH has no local child, so terminate is a harmless no-op.
        if let tv = terminals[id] {
            tv.process.terminate()
        }
        terminals.removeValue(forKey: id)
        termDelegates.removeValue(forKey: id)
        termDrivers.removeValue(forKey: id)
        // Cancel pending tab file operations and release independent browser/tree state on close.
        browserStates[id]?.cancel()
        browserStates.removeValue(forKey: id)
        fileTreeStates.removeValue(forKey: id)
        terminalConns.removeValue(forKey: id)   // Discard connection state when its tab closes.
        terminalReconnectWork[id]?.cancel()      // Cancel pending reconnect so it cannot wake after tab closure.
        terminalReconnectWork.removeValue(forKey: id)
        editorStates[id]?.cancel()
        editorStates.removeValue(forKey: id)
        tailSessions[id]?.stop()
        tailSessions.removeValue(forKey: id)
        diskUsageSessions[id]?.cancel()
        diskUsageSessions.removeValue(forKey: id)
        scriptSessions.removeValue(forKey: id)
        netToolsSessions[id]?.stop()
        netToolsSessions.removeValue(forKey: id)
        processSessions[id]?.stop()
        processSessions.removeValue(forKey: id)
        serviceSessions[id]?.stop()
        serviceSessions.removeValue(forKey: id)
        webSessions[id]?.close()
        webSessions.removeValue(forKey: id)
        dockerSessions[id]?.stop()
        dockerSessions.removeValue(forKey: id)
        siteSessions[id]?.close()   // Cancel transfers and unmount SMB.
        siteSessions.removeValue(forKey: id)
        editorHosts.removeValue(forKey: id)   // Release the hosted editor instance.
        rdpSessions[id]?.disconnect()
        rdpSessions.removeValue(forKey: id)
        refreshRDPHosts()   // Update RDP Running state after closing its tab.
        tabCwd.removeValue(forKey: id)
        if activeTabId == id {
            // Prefer another same-server/same-area tab, then any tab in the group, then an adjacent list tab.
            let key = closedHostId ?? TabItem.localGroupKey
            let wasTerminal = closedKind == .terminal
            let sameGroup = tabs.filter { $0.groupKey == key }
            let next = (wasTerminal ? tabsModel.terminalTab(inGroup: key) : tabsModel.mainTab(inGroup: key))
                ?? sameGroup.last
            activeTabId = next?.id ?? (tabs.isEmpty ? nil : tabs[min(idx, tabs.count - 1)].id)
        }
        if let hid = closedHostId { stopMonitorIfUnused(hid) }   // Stop monitoring when the last host tab closes.
    }

    /// Whether the terminal has an active process requiring close confirmation.
    private func shouldConfirmClose(_ id: Int) -> Bool {
        // Always confirm unsaved editor changes regardless of the general close-confirmation preference.
        if let tab = tabs.first(where: { $0.id == id }), tab.kind == .editor {
            return editorStates[id]?.isDirty ?? false
        }
        guard AppSettings.shared.closeConfirm else { return false }
        // Closing site tabs cancels active transfers, so request confirmation.
        if let tab = tabs.first(where: { $0.id == id }), tab.kind == .site { return siteSessions[id]?.hasRunningTransfer ?? false }
        // Always confirm RDP closure because it disconnects the desktop.
        if let tab = tabs.first(where: { $0.id == id }), tab.kind == .rdp { return true }
        guard let tab = tabs.first(where: { $0.id == id }), tab.kind == .terminal else { return false }
        guard let tv = terminals[id] else { return false }

        // Always confirm SSH session closure because it disconnects the remote connection.
        if let hid = tab.hostId, hosts.first(where: { $0.id == hid })?.ssh != nil {
            return true
        }
        // For local terminals, compare the PTY foreground process group with the shell's group; a difference means an active foreground job.
        let fd = tv.process.childfd
        let shellPid = tv.process.shellPid
        guard fd >= 0, shellPid > 0 else { return false }
        let fg = tcgetpgrp(fd)
        return fg > 0 && fg != shellPid
    }

    /// Title of the tab being closed, for confirmation text.
    var pendingCloseTitle: String {
        guard let id = pendingCloseTabId else { return "" }
        return tabs.first(where: { $0.id == id })?.title ?? ""
    }

    /// Close-confirmation title by tab type.
    var pendingCloseDialogTitle: String {
        guard let id = pendingCloseTabId,
              let tab = tabs.first(where: { $0.id == id }) else { return String(localized: "Close this tab?") }
        switch tab.kind {
        case .editor: return String(localized: "Discard Unsaved Changes?")
        case .rdp:    return String(localized: "Disconnect Remote Desktop?")
        case .site:   return String(localized: "Cancel Transfers?")
        default:      return String(localized: "Close this terminal?")
        }
    }

    /// Close-confirmation message.
    var pendingCloseDialogMessage: String {
        guard let id = pendingCloseTabId,
              let tab = tabs.first(where: { $0.id == id }) else { return "" }
        switch tab.kind {
        case .editor: return String(localized: "\"\(tab.title)\" has unsaved changes. Closing it will discard them.")
        case .rdp:    return String(localized: "\"\(tab.title)\" is a Remote Desktop session. Closing it will disconnect.")
        case .site:   return String(localized: "\"\(tab.title)\" still has transfers in progress. Closing it will cancel them.")
        default:      return String(localized: "\"\(tab.title)\" has a running process. Closing it will terminate the process.")
        }
    }
}

// MARK: - Tab context-action dialog state

struct TabRenameContext: Identifiable {
    let id: Int            // Target tab ID.
    let currentTitle: String
}

struct MultiCloseContext: Identifiable {
    let id = UUID()
    let ids: [Int]         // Set of tab IDs to close.
}

// MARK: - File context-action dialog state

struct FileOpContext: Identifiable {
    let id = UUID()
    let file: RemoteFile
    let host: Host
    let target: any FileOpsTarget
}

struct BatchDeleteContext: Identifiable {
    let id = UUID()
    let files: [RemoteFile]
    let host: Host
    let target: any FileOpsTarget
}

struct ChmodContext: Identifiable {
    let id = UUID()
    let file: RemoteFile
    let host: Host
    let target: any FileOpsTarget
    let mode: Int   // Current octal permissions, e.g. 0o755.
}

struct CreateContext: Identifiable {
    let id = UUID()
    let dir: String          // Create inside this directory.
    let isDir: Bool          // true=folder, false=file.
    let host: Host
    let target: any FileOpsTarget
}

struct RefreshConflictContext: Identifiable {
    let id = UUID()
    let editorState: EditorState
    let fileName: String
}

struct FileInfoContext: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

import Foundation

/// ObservableObject separating open/active tabs from AppModel.
///
/// Recompute expensive TabBar/Workspace views only for tab changes,
/// not unrelated hosts/query/dialog publications; same separation as [[LayoutModel]].
///
/// AppModel forwards tabs/activeTabId through computed properties without changing internal logic;
/// only views switch observation from AppModel to TabsModel.
@MainActor
final class TabsModel: ObservableObject {
    @Published var tabs: [TabItem] = []
    @Published var activeTabId: Int? = nil {
        didSet {
            recordActive()
            HostTint.shared.update(hostId: tabs.first { $0.id == activeTabId }?.hostId)   // Refresh accents to match the server color.
        }
    }

    // Remember each server's latest main-area file/editor/overview/RDP tab and terminal separately.
    // Focus changes preserve the other area; editor and terminal panels do not replace each other.
    private var lastMain: [String: Int] = [:]
    private var lastTerminal: [String: Int] = [:]

    private func recordActive() {
        guard let id = activeTabId, let tab = tabs.first(where: { $0.id == id }) else { return }
        if tab.kind == .terminal { lastTerminal[tab.groupKey] = id } else { lastMain[tab.groupKey] = id }
    }

    var activeGroupKey: String? { tabs.first { $0.id == activeTabId }?.groupKey }

    /// Use the group's last active main tab if valid, otherwise its last nonterminal tab.
    func mainTab(inGroup key: String) -> TabItem? {
        let group = tabs.filter { $0.groupKey == key && $0.kind != .terminal }
        if let id = lastMain[key], let t = group.first(where: { $0.id == id }) { return t }
        return group.last
    }

    /// Use the group's last active terminal if valid, otherwise its last terminal.
    func terminalTab(inGroup key: String) -> TabItem? {
        let group = tabs.filter { $0.groupKey == key && $0.kind == .terminal }
        if let id = lastTerminal[key], let t = group.first(where: { $0.id == id }) { return t }
        return group.last
    }
}

extension TabItem {
    static let localGroupKey = "__local__"
    /// Owning server group; all local terminals share Local.
    var groupKey: String { hostId ?? Self.localGroupKey }
}

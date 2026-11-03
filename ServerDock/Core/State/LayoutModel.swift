import SwiftUI

/// Small sidebar-width ObservableObject, intentionally separate from [[AppModel]].
///
/// Nearly every view, including ContentView/Sidebar/TabBar/Workspace, observes AppModel.
/// Keeping sidebarWidth there would emit objectWillChange on every divider-drag frame,
/// recomputing every @ObservedObject model view's body in the same frame.
/// More tabs/tree rows amplify this cost.
///
/// Separating width limits subscribers to Sidebar's frame and SidebarDivider.
/// TabBar/Workspace model arguments stay unchanged, allowing SwiftUI to skip their bodies during dragging.
@MainActor
final class LayoutModel: ObservableObject {
    /// Sidebar width in pixels; zero means collapsed.
    @Published var sidebarWidth: CGFloat = 224

    /// Persist bottom terminal-panel visibility/height across launches.
    @Published var terminalPanelVisible: Bool = UserDefaults.standard.object(forKey: "terminalPanelVisible") as? Bool ?? false {
        didSet { UserDefaults.standard.set(terminalPanelVisible, forKey: "terminalPanelVisible") }
    }
    /// Persist right file-panel width across launches.
    @Published var filePanelWidth: CGFloat = {
        let w = UserDefaults.standard.double(forKey: "filePanelWidth")
        return w > 0 ? w : 260
    }() {
        didSet { UserDefaults.standard.set(Double(filePanelWidth), forKey: "filePanelWidth") }
    }
    /// Persist folder-content-list visibility/height below the file panel.
    @Published var filePanelListVisible: Bool = UserDefaults.standard.object(forKey: "filePanelListVisible") as? Bool ?? true {
        didSet { UserDefaults.standard.set(filePanelListVisible, forKey: "filePanelListVisible") }
    }
    @Published var filePanelListHeight: CGFloat = {
        let h = UserDefaults.standard.double(forKey: "filePanelListHeight")
        return h > 0 ? h : 220
    }() {
        didSet { UserDefaults.standard.set(Double(filePanelListHeight), forKey: "filePanelListHeight") }
    }
    @Published var terminalPanelHeight: CGFloat = {
        let h = UserDefaults.standard.double(forKey: "terminalPanelHeight")
        return h > 0 ? h : 280
    }() {
        didSet { UserDefaults.standard.set(Double(terminalPanelHeight), forKey: "terminalPanelHeight") }
    }
}

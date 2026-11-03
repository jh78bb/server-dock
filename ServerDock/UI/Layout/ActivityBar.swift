import AppKit
import SwiftUI

struct ActivityBar: View {
    @ObservedObject var model: AppModel
    // Do not observe layout: this view reads/writes width only in click closures, not body.
    // @ObservedObject would subscribe even without body reading width, needlessly recomputing while dragging.
    let layout: LayoutModel
    @ObservedObject private var theme = ThemeManager.shared
    @State private var isFullScreen = false

    private let items: [(String, Section)] = [
        ("house.fill", .hosts),   // Remote files are integrated under connected hosts in the sidebar instead of a separate Files section.
        ("display", .rdp),
        ("externaldrive.connected.to.line.below", .sites),
    ]

    /// Bottom group: tools, forwarding, and management panels.
    private let bottomItems: [(String, Section)] = [
        ("wrench.and.screwdriver", .tools),
        ("arrow.left.arrow.right", .portForwards),
        ("key", .sshKeys),
        ("chevron.left.forwardslash.chevron.right", .snippets),   // Snippet management matches the right file-panel tab.
    ]

    var body: some View {
        VStack(spacing: 10) {
            ForEach(items, id: \.1) { symbol, section in
                item(symbol, section)
            }
            Spacer()
            VStack(spacing: 4) {
                ForEach(bottomItems, id: \.1) { symbol, section in
                    item(symbol, section)
                }
                Rectangle()
                    .fill(Pal.fill(0.08))
                    .frame(width: 28, height: 1)
                    .padding(.vertical, 6)
                BackgroundCenterButton(model: model)
                    // A watcher opens any background transfer requiring a name-conflict decision, preventing silent stalls; this replaces the old mini-ring watcher.
                    // Mount in background with zero size so it adds no VStack spacing.
                    .background {
                        ForEach(model.transfers, id: \.id) { task in
                            UploadAskWatcher(task: task) { model.focusedTransferId = task.id }
                        }
                    }
                settingsButton
            }
        }
        .padding(.top, isFullScreen ? 14 : 54)
        .padding(.bottom, 14)
        .frame(width: 64)
        .frame(maxHeight: .infinity)
        .background(Pal.mantle)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { _ in
            isFullScreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { _ in
            isFullScreen = false
        }
    }

    private var settingsButton: some View {
        ActivityBarButton(symbol: "gearshape", selected: model.showSettings) {
            model.showSettings = true
        }
    }

    @ViewBuilder
    private func item(_ symbol: String, _ section: Section) -> some View {
        ActivityBarButton(symbol: symbol, selected: model.section == section) {
            if section == .portForwards {
                if layout.sidebarWidth < 10 { layout.sidebarWidth = 224 }
                model.openAllForwards()
                return
            }
            // Open/close immediately; animating width would re-layout the workspace every frame and stutter.
            if model.section == section && layout.sidebarWidth >= 10 {
                layout.sidebarWidth = 0
            } else {
                model.section = section
                if layout.sidebarWidth < 10 {
                    layout.sidebarWidth = 224
                }
            }
        }
        .help(section == .portForwards ? String(localized: "Port Forwarding") : "")
    }
}

/// Activity icons use a neutral selected background and bright foreground.
private struct ActivityBarButton: View {
    let symbol: String
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(lucideSymbol: symbol)
                .font(.system(size: 18, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Pal.textBright : (hover ? Pal.text : Pal.subtext))
                .frame(width: 46, height: 46)
                .background(
                    selected ? Pal.fill(0.11) : (hover ? Pal.fill(0.06) : Color.clear),
                    in: RoundedRectangle(cornerRadius: 13)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hover = $0 }
    }
}

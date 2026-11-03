import AppKit
import SwiftUI

/// Global custom tooltip: show a SwiftUI card in a borderless floating panel near the pointer after a hover delay.
/// A separate window avoids parent/ScrollView clipping; fully custom styling matches [[ui-component-style]].
/// Attach .tooltip("Full text") or .tooltip(text, when: isTruncated) to any View.
@MainActor
final class TooltipController {
    static let shared = TooltipController()
    private var panel: NSPanel?
    private var hosting: NSHostingView<TooltipView>?
    private var showWork: DispatchWorkItem?

    /// On pointer entry, show at the current pointer position after a delay.
    func scheduleShow(_ text: String, delay: TimeInterval = 0.45) {
        showWork?.cancel()
        guard !text.isEmpty else { return }
        let work = DispatchWorkItem { [weak self] in self?.present(text) }
        showWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func hide() {
        showWork?.cancel()
        panel?.orderOut(nil)
    }

    // Maximum text width before wrapping.
    private static let maxTextWidth: CGFloat = 440

    /// Measure the single-line NSString width first to choose a definite SwiftUI wrapping width.
    /// Let SwiftUI derive fittingSize height at that width, avoiding clipping from mismatched fixedSize/maxWidth measurement and rendering.
    private static func wrapWidth(for text: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 11.5)
        let single = (text as NSString).size(withAttributes: [.font: font]).width
        return min(ceil(single) + 2, maxTextWidth)   // Add 2pt slack to avoid wrapping at exact boundaries.
    }

    private func present(_ text: String) {
        let panel = ensurePanel()
        hosting?.rootView = TooltipView(text: text, textWidth: Self.wrapWidth(for: text))
        panel.layoutIfNeeded()
        let size = hosting?.fittingSize ?? CGSize(width: 120, height: 28)

        // Show below/right of the pointer in bottom-left-origin screen coordinates, clamped to the current screen's visible frame.
        let loc = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(loc) } ?? NSScreen.main
        let vis = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var x = loc.x + 14
        var y = loc.y - size.height - 10
        if x + size.width > vis.maxX { x = loc.x - size.width - 14 }      // If there is no room to the right, flip left.
        x = min(max(x, vis.minX + 4), vis.maxX - size.width - 4)
        if y < vis.minY { y = loc.y + 18 }                                // If there is no room below, flip above.
        y = min(max(y, vis.minY + 4), vis.maxY - size.height - 4)

        panel.setFrame(NSRect(origin: CGPoint(x: x, y: y), size: size), display: true)
        panel.orderFront(nil)
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 120, height: 28),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        p.isFloatingPanel = true
        p.level = .popUpMenu                 // Float above other windows/dialogs.
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false                  // SwiftUI draws the card shadow.
        p.ignoresMouseEvents = true          // Never take events or focus.
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let h = NSHostingView(rootView: TooltipView(text: "", textWidth: 0))
        p.contentView = h
        hosting = h
        panel = p
        return p
    }
}

/// Custom-styled tooltip card.
private struct TooltipView: View {
    let text: String
    let textWidth: CGFloat   // Definite wrapping width measured by the controller.
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(Pal.text)
            .multilineTextAlignment(.leading)
            .lineLimit(8)
            // After fixing width, use vertical fixedSize to derive actual wrapped height and avoid multiline clipping.
            .frame(width: textWidth, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(Pal.solidMantle, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Pal.fill(0.10), lineWidth: 1))
            .padding(2)                      // No shadow; leave only minimal padding to prevent border clipping.
            .environment(\.colorScheme, theme.isDark ? .dark : .light)
    }
}

extension View {
    /// Global delayed-hover tooltip; when=false omits it, e.g. for untruncated text.
    func tooltip(_ text: String, when condition: Bool = true) -> some View {
        modifier(TooltipModifier(text: condition ? text : ""))
    }
}

private struct TooltipModifier: ViewModifier {
    let text: String
    func body(content: Content) -> some View {
        content.onHover { hovering in
            if hovering && !text.isEmpty {
                TooltipController.shared.scheduleShow(text)
            } else {
                TooltipController.shared.hide()
            }
        }
    }
}

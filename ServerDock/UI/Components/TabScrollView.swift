import AppKit
import SwiftUI

final class ScrollMetrics: ObservableObject {
    @Published var offsetX: CGFloat = 0
    @Published var contentW: CGFloat = 0
    @Published var visibleW: CGFloat = 0
    var maxScroll: CGFloat { max(0, contentW - visibleW) }
    var scrollTo: ((CGFloat) -> Void)?

    /// Publish only real value changes. @Published emits objectWillChange even for identical assignments,
    /// and updateNSView writes values on every update, creating a write/redraw/write feedback loop that saturates CPU.
    /// Use threshold comparisons to ignore subpixel jitter and publish only actual changes, breaking the loop.
    func set(offsetX: CGFloat, contentW: CGFloat, visibleW: CGFloat) {
        if abs(self.offsetX - offsetX) > 0.5 { self.offsetX = offsetX }
        if abs(self.contentW - contentW) > 0.5 { self.contentW = contentW }
        if abs(self.visibleW - visibleW) > 0.5 { self.visibleW = visibleW }
    }
}

final class HScroll: NSScrollView {
    var onScroll: (() -> Void)?

    override func scrollWheel(with e: NSEvent) {
        guard let doc = documentView else { super.scrollWheel(with: e); return }
        let maxX = max(0, doc.frame.width - contentView.bounds.width)
        var d = e.scrollingDeltaX
        if abs(e.scrollingDeltaY) > abs(d) { d = e.scrollingDeltaY }
        if d == 0 { d = e.deltaX != 0 ? e.deltaX : e.deltaY }
        let speed: CGFloat = e.hasPreciseScrollingDeltas ? 1 : 12
        var x = contentView.bounds.origin.x - d * speed
        x = min(max(0, x), maxX)
        contentView.scroll(to: NSPoint(x: x, y: 0))
        reflectScrolledClipView(contentView)
    }

    override func layout() {
        super.layout()
        if let doc = documentView {
            let w = max(doc.fittingSize.width, 1)
            let h = contentView.bounds.height
            let target = NSRect(x: 0, y: 0, width: w, height: h)
            if !doc.frame.equalTo(target) { doc.frame = target }
        }
        onScroll?()
    }
}

/// NSHostingView ignoring window safe areas so title-bar insets do not push tab content downward.
final class SafeHostingView<Content: View>: NSHostingView<Content> {
    override var safeAreaInsets: NSEdgeInsets {
        .init(top: 0, left: 0, bottom: 0, right: 0)
    }
}

struct HScrollRep<Content: View>: NSViewRepresentable {
    @ObservedObject var metrics: ScrollMetrics
    var newKey: Int
    var activeKey: Int
    var activeMinX: CGFloat   // Measured active-tab left/right edges in content coordinates, supporting unequal tab widths.
    var activeMaxX: CGFloat
    @ViewBuilder var content: Content

    func makeNSView(context: Context) -> HScroll {
        let sv = HScroll()
        sv.hasHorizontalScroller = false
        sv.hasVerticalScroller = false
        sv.drawsBackground = false
        sv.backgroundColor = .clear
        sv.contentView.drawsBackground = false
        sv.verticalScrollElasticity = .none
        sv.horizontalScrollElasticity = .allowed
        sv.automaticallyAdjustsContentInsets = false
        sv.contentInsets = .init(top: 0, left: 0, bottom: 0, right: 0)

        let hosting = SafeHostingView(rootView: content)
        hosting.translatesAutoresizingMaskIntoConstraints = true
        sv.documentView = hosting
        context.coordinator.hosting = hosting

        let push: () -> Void = { [weak sv] in
            guard let sv else { return }
            let ox = sv.contentView.bounds.origin.x
            let cw = sv.documentView?.frame.width ?? 0
            let vw = sv.contentView.bounds.width
            DispatchQueue.main.async {
                metrics.set(offsetX: ox, contentW: cw, visibleW: vw)
            }
        }
        sv.onScroll = push
        sv.contentView.postsBoundsChangedNotifications = true
        context.coordinator.obs = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: sv.contentView, queue: .main
        ) { _ in push() }

        metrics.scrollTo = { [weak sv] x in
            guard let sv else { return }
            sv.contentView.scroll(to: NSPoint(x: x, y: 0))
            sv.reflectScrolledClipView(sv.contentView)
        }
        return sv
    }

    func updateNSView(_ sv: HScroll, context: Context) {
        context.coordinator.hosting?.rootView = content
        sv.needsLayout = true
        DispatchQueue.main.async {
            sv.layoutSubtreeIfNeeded()
            let co = context.coordinator
            guard let doc = sv.documentView else { return }
            let clipW = sv.contentView.bounds.width
            let docW = doc.frame.width
            let maxScrollX = max(0, docW - clipW)
            let curX = sv.contentView.bounds.origin.x
            let isNew = newKey > co.lastKey
            co.lastKey = newKey
            let switched = activeKey != co.lastActiveKey
            co.lastActiveKey = activeKey
            // Scroll smoothly to reveal newly added rightmost tabs; no scrolling if everything fits and maxScrollX=0.
            if isNew {
                smoothScroll(sv, to: maxScrollX)
            } else if switched, docW > clipW, activeMaxX > activeMinX {
                // When the selected tab touches a viewport edge, reveal it and part of its neighbor using measured frames, even for unequal widths.
                let peek: CGFloat = 48, margin: CGFloat = 24
                var targetX = curX
                if activeMaxX > curX + clipW - margin {        // At the right edge, reveal part of the following tab.
                    targetX = min(maxScrollX, activeMaxX + peek - clipW)
                } else if activeMinX < curX + margin {          // At the left edge, reveal part of the preceding tab.
                    targetX = max(0, activeMinX - peek)
                }
                if abs(targetX - curX) > 1 { smoothScroll(sv, to: targetX) }
            }
            metrics.set(offsetX: sv.contentView.bounds.origin.x, contentW: docW, visibleW: clipW)
        }
    }

    private func smoothScroll(_ sv: HScroll, to x: CGFloat) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = .init(name: .easeInEaseOut)
            sv.contentView.animator().setBoundsOrigin(NSPoint(x: x, y: 0))
        }
        sv.reflectScrolledClipView(sv.contentView)
    }

    static func dismantleNSView(_ nsView: HScroll, coordinator: Coordinator) {
        if let o = coordinator.obs { NotificationCenter.default.removeObserver(o) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator {
        var hosting: SafeHostingView<Content>?
        var obs: NSObjectProtocol?
        var lastKey = 0
        var lastActiveKey = 0
    }
}

/// Horizontal scrolling container reusing tab-bar HScroll, mapping vertical wheel input horizontally and supporting trackpad swipes.
/// Scroll overflowing content such as editor breadcrumbs; when pathKey changes, scroll to the last component/filename.
/// Unlike TabStrip, this has no tab/new-tab state coupling or visible scrollbar; it provides scrolling only.
struct HWheelScroll<Content: View>: NSViewRepresentable {
    var pathKey: String
    @ViewBuilder var content: Content

    func makeNSView(context: Context) -> HScroll {
        let sv = HScroll()
        sv.hasHorizontalScroller = false
        sv.hasVerticalScroller = false
        sv.drawsBackground = false
        sv.backgroundColor = .clear
        sv.contentView.drawsBackground = false
        sv.verticalScrollElasticity = .none
        sv.horizontalScrollElasticity = .allowed
        sv.automaticallyAdjustsContentInsets = false
        sv.contentInsets = .init(top: 0, left: 0, bottom: 0, right: 0)

        let hosting = SafeHostingView(rootView: content)
        hosting.translatesAutoresizingMaskIntoConstraints = true
        sv.documentView = hosting
        context.coordinator.hosting = hosting
        return sv
    }

    func updateNSView(_ sv: HScroll, context: Context) {
        context.coordinator.hosting?.rootView = content
        sv.needsLayout = true
        let co = context.coordinator
        let changed = co.lastPath != pathKey
        DispatchQueue.main.async {
            sv.layoutSubtreeIfNeeded()
            guard changed, let doc = sv.documentView else { return }
            let clipW = sv.contentView.bounds.width
            guard clipW > 0 else { return }   // Layout is not ready; retry on the next update without changing lastPath yet.
            co.lastPath = pathKey
            let maxX = max(0, doc.frame.width - clipW)
            sv.contentView.scroll(to: NSPoint(x: maxX, y: 0))
            sv.reflectScrolledClipView(sv.contentView)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator {
        var hosting: SafeHostingView<Content>?
        var lastPath = ""
    }
}

struct TabStrip<Content: View>: View {
    var newKey: Int
    var activeKey: Int
    var activeMinX: CGFloat
    var activeMaxX: CGFloat
    @ViewBuilder var content: Content
    @StateObject private var metrics = ScrollMetrics()
    @State private var hovering = false
    @State private var dragStart: CGFloat?

    init(newKey: Int, activeKey: Int, activeMinX: CGFloat = 0, activeMaxX: CGFloat = 0, @ViewBuilder content: () -> Content) {
        self.newKey = newKey
        self.activeKey = activeKey
        self.activeMinX = activeMinX
        self.activeMaxX = activeMaxX
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 3) {
            HScrollRep(metrics: metrics, newKey: newKey, activeKey: activeKey, activeMinX: activeMinX, activeMaxX: activeMaxX) { content }
                .frame(height: 34)
            scrollbar
                .frame(height: 5)
        }
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var scrollbar: some View {
        GeometryReader { g in
            if metrics.contentW > metrics.visibleW + 1, g.size.width > 0 {
                let track = g.size.width
                let thumbW = max(28, track * track / metrics.contentW)
                let maxX = max(0, track - thumbW)
                let x = metrics.maxScroll > 0 ? metrics.offsetX / metrics.maxScroll * maxX : 0
                Capsule()
                    .fill(Pal.fill(hovering ? 0.32 : 0.18))
                    .frame(width: thumbW, height: 4)
                    .frame(width: thumbW, height: g.size.height)
                    .contentShape(Rectangle())
                    .position(x: x + thumbW / 2, y: g.size.height / 2)
                    .animation(.easeOut(duration: 0.12), value: hovering)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { v in
                                if dragStart == nil { dragStart = metrics.offsetX }
                                if maxX > 0, let start = dragStart {
                                    let off = min(max(0, start + v.translation.width / maxX * metrics.maxScroll), metrics.maxScroll)
                                    metrics.scrollTo?(off)
                                }
                            }
                            .onEnded { _ in dragStart = nil }
                    )
            }
        }
    }
}

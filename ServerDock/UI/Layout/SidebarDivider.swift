import SwiftUI

struct SidebarDivider: View {
    @ObservedObject var layout: LayoutModel
    var maxWidth: CGFloat = 320          // Allow a larger maximum for file sidebars with deep directory trees.
    @ObservedObject private var theme = ThemeManager.shared
    @State private var isHovering = false
    @State private var isDragging = false
    @State private var dragStartWidth: CGFloat = 0
    @State private var pendingWidth: CGFloat = 0   // Target width while dragging; commit to layout only on release.

    private let collapseThreshold: CGFloat = 60
    private var active: Bool { isHovering || isDragging }

    var body: some View {
        ZStack {
            Pal.mantle

            if active {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Pal.fill(0.08))
                    .frame(width: 5, height: 48)
            }
        }
        .frame(width: 5)
        .contentShape(Rectangle())
        // Move only the guide during dragging, freezing panel/workspace sizes until release.
        // Dragging stays O(1) regardless of tab count, file size, or terminal throughput;
        // actual terminal reflow/editor layout happens only once on release.
        .overlay {
            if isDragging {
                Rectangle()
                    .fill(Pal.mauve.opacity(0.55))
                    .frame(width: 2)
                    .offset(x: pendingWidth - dragStartWidth)
                    .allowsHitTesting(false)
            }
        }
        // Reset the resize cursor on every onContinuousHover event; SwiftUI tracking areas can override push/pop
        // with an arrow on mouse movement, so repeated set calls keep the horizontal-resize cursor stable.
        .onContinuousHover { phase in
            switch phase {
            case .active:
                if !isHovering { isHovering = true }
                NSCursor.resizeLeftRight.set()
            case .ended:
                if isHovering { isHovering = false }
                NSCursor.arrow.set()
            }
        }
        .onTapGesture(count: 2) {
            // Open/close immediately; width animations would re-layout the workspace every frame and stutter.
            layout.sidebarWidth = layout.sidebarWidth < 10 ? 224 : 0
        }
        .gesture(
            DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .onChanged { value in
                    if !isDragging {
                        isDragging = true
                        dragStartWidth = layout.sidebarWidth
                        pendingWidth = dragStartWidth
                    }
                    // Update only local target width while dragging, not layout, to avoid re-layout.
                    pendingWidth = min(max(dragStartWidth + value.translation.width, 0), maxWidth)
                    // Keep asserting the resize cursor during dragging even after leaving the narrow hit area.
                    NSCursor.resizeLeftRight.set()
                }
                .onEnded { _ in
                    isDragging = false
                    var w = pendingWidth
                    if w < collapseThreshold { w = 0 }
                    else if w < 140 { w = 140 }
                    // On release, animate briefly from the frozen starting width to w to avoid a hard panel jump.
                    // Tradeoff: animation changes width and reflows terminals each frame; non-terminal tabs remain smooth.
                    // If this still stutters, replace this line with layout.sidebarWidth = w for immediate resizing.
                    withAnimation(.easeOut(duration: 0.12)) { layout.sidebarWidth = w }
                }
        )
    }
}

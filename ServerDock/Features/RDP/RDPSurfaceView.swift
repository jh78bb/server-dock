import AppKit
import SwiftUI

/// Transparent NSView input layer over the remote desktop, converting local pointer/keyboard events to remote coordinates/scan codes.
/// SwiftUI Image handles rendering; this layer handles only input. Pointer mapping matches centered proportional scaledToFit layout.
struct RDPMouseLayer: NSViewRepresentable {
    let remoteW: Int
    let remoteH: Int
    let onMove: (Int, Int) -> Void
    let onButton: (Int, Bool, Int, Int) -> Void
    let onWheel: (Int, Int, Int) -> Void
    let onKey: (Int, Bool) -> Void      // (macOS virtual keycode, pressed).
    var onKeyEvent: ((NSEvent, Bool) -> Void)? = nil
    let onFlags: (Int) -> Void          // Modifier mask; see RDPMouseView.modMask.

    func makeNSView(context: Context) -> RDPMouseView { RDPMouseView() }

    func updateNSView(_ v: RDPMouseView, context: Context) {
        v.remoteW = remoteW
        v.remoteH = remoteH
        v.onMove = onMove
        v.onButton = onButton
        v.onWheel = onWheel
        v.onKey = onKey
        v.onKeyEvent = onKeyEvent
        v.onFlags = onFlags
    }
}

final class RDPMouseView: NSView {
    var remoteW = 0
    var remoteH = 0
    var onMove: ((Int, Int) -> Void)?
    var onButton: ((Int, Bool, Int, Int) -> Void)?
    var onWheel: ((Int, Int, Int) -> Void)?
    var onKey: ((Int, Bool) -> Void)?
    var onKeyEvent: ((NSEvent, Bool) -> Void)?
    var onFlags: ((Int) -> Void)?

    override var isFlipped: Bool { true }   // Top-left origin, matching RDP coordinates and the image layout.

    // Become first responder for keyboard input when the desktop is clicked or the pointer enters, allowing typing immediately on opening a tab/window.
    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { DispatchQueue.main.async { [weak self] in self?.window?.makeFirstResponder(self) } }
    }

    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    /// Centered proportional image rectangle inside this view, matching SwiftUI scaledToFit.
    private var imageRect: CGRect {
        guard remoteW > 0, remoteH > 0 else { return bounds }
        let iw = CGFloat(remoteW), ih = CGFloat(remoteH)
        let scale = min(bounds.width / iw, bounds.height / ih)
        let w = iw * scale, h = ih * scale
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }

    private func remotePoint(_ e: NSEvent) -> (Int, Int)? {
        guard remoteW > 0, remoteH > 0 else { return nil }
        let p = convert(e.locationInWindow, from: nil)   // isFlipped gives a top-left origin.
        let r = imageRect
        guard r.width > 0, r.height > 0 else { return nil }
        let fx = min(max((p.x - r.minX) / r.width, 0), 1)
        let fy = min(max((p.y - r.minY) / r.height, 0), 1)
        return (Int(fx * CGFloat(remoteW)), Int(fy * CGFloat(remoteH)))
    }

    private func move(_ e: NSEvent) { if let (x, y) = remotePoint(e) { onMove?(x, y) } }
    private func button(_ e: NSEvent, _ b: Int, _ down: Bool) { if let (x, y) = remotePoint(e) { onButton?(b, down, x, y) } }

    override func mouseMoved(with e: NSEvent) { move(e) }
    override func mouseDragged(with e: NSEvent) { move(e) }
    override func rightMouseDragged(with e: NSEvent) { move(e) }
    override func otherMouseDragged(with e: NSEvent) { move(e) }
    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)   // Clicking the desktop takes keyboard focus.
        button(e, 0, true)
    }
    override func mouseUp(with e: NSEvent) { button(e, 0, false) }
    override func rightMouseDown(with e: NSEvent) { button(e, 1, true) }
    override func rightMouseUp(with e: NSEvent) { button(e, 1, false) }
    override func otherMouseDown(with e: NSEvent) { button(e, 2, true) }
    override func otherMouseUp(with e: NSEvent) { button(e, 2, false) }

    override func scrollWheel(with e: NSEvent) {
        // Option-scroll pans the zoomed local scroll view instead of sending remote wheel input.
        if e.modifierFlags.contains(.option) { nextResponder?.scrollWheel(with: e); return }
        guard let (x, y) = remotePoint(e) else { return }
        let dy = e.scrollingDeltaY
        if dy != 0 { onWheel?(Int((dy * 10).rounded()), x, y) }   // Scale to the RDP wheel-delta range.
    }

    // MARK: - Keyboard
    // Modifier bits must match C ServerDockRDPModMask: Shift=1, Control=2, Alt=4, Command=8, CapsLock=16.
    private func modMask(_ f: NSEvent.ModifierFlags) -> Int {
        var m = 0
        if f.contains(.shift)    { m |= 1 }
        if f.contains(.control)  { m |= 2 }
        if f.contains(.option)   { m |= 4 }
        if f.contains(.command)  { m |= 8 }
        if f.contains(.capsLock) { m |= 16 }
        return m
    }

    // Synchronize modifiers before sending the key; skip super to avoid system beeps for unhandled events.
    override func keyDown(with e: NSEvent) {
        onFlags?(modMask(e.modifierFlags))
        if let onKeyEvent { onKeyEvent(e, true); return }
        onKey?(Int(e.keyCode), true)
    }
    override func keyUp(with e: NSEvent) {
        onFlags?(modMask(e.modifierFlags))
        if let onKeyEvent { onKeyEvent(e, false); return }
        onKey?(Int(e.keyCode), false)
    }
    override func flagsChanged(with e: NSEvent) {
        onFlags?(modMask(e.modifierFlags))
    }
}

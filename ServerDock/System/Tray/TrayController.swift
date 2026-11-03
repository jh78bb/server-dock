import AppKit
import Combine

/// Persistent menu-bar controller providing Show Window, background-task overview, and Quit.
/// Keep persistent forwarding/background tasks visible/manageable after hiding the main window; see AppDelegate.
@MainActor
final class TrayController: NSObject, NSMenuDelegate {
    /// Weak singleton reference for access outside AppDelegate, which already owns the controller strongly.
    static weak var shared: TrayController?

    private var statusItem: NSStatusItem?
    private let onShow: () -> Void
    private let onQuit: () -> Void
    private var bgCancellable: AnyCancellable?
    /// Status priority: failure with red pulse > running with blue/green pulse > idle static blue.
    private enum LightMode { case idle, running, failure }
    private var lastMode: LightMode = .idle   // Deduplicate state to avoid unnecessary redraws.
    private var animTimer: Timer?
    private var animPhase: Double = 0

    // Status-dot pulse endpoints stay bright, using hue changes instead of dark/muddy brightness shifts.
    // Running alternates brand blue/green; failure alternates bright red/warm orange-red for a warning pulse.
    private static let barBlue   = NSColor(srgbRed: 0.25, green: 0.62, blue: 1.00, alpha: 1)
    private static let barGreen  = NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1)
    private static let barRed    = NSColor(srgbRed: 1.00, green: 0.27, blue: 0.24, alpha: 1)
    private static let barRedAlt = NSColor(srgbRed: 1.00, green: 0.55, blue: 0.32, alpha: 1)

    init(onShow: @escaping () -> Void, onQuit: @escaping () -> Void) {
        self.onShow = onShow
        self.onQuit = onQuit
        super.init()
        install()
        Self.shared = self
        // Refresh status color when AppModel publishes task starts/ends/failures. Per-frame progress bypasses AppModel to avoid redraw storms.
        bgCancellable = AppModel.shared.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.refreshIfNeeded() }
        }
    }

    /// Create the status icon once for the app lifetime; never remove/recreate/hide it.
    /// Decouple the status item from activation policy (.regular/.accessory) and window lifetime. Hiding to the menu bar
    /// only orders out content windows, leaving NSStatusBarWindow visible; see AppDelegate.hideToTray.
    /// Never call removeStatusItem, which clears autosaveName's position slot and causes drift, so the user's dragged position is preserved.
    /// autosaveName preserves position across restarts.
    private func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "ServerDockBackgroundStatusItem"   // Restore the user's dragged status-item position after recreation/restart.
        item.button?.toolTip = "ServerDock"
        item.isVisible = true
        let menu = NSMenu()
        menu.delegate = self   // Refresh from current background tasks whenever the menu opens.
        item.menu = menu
        statusItem = item
        updateImage()
    }

    /// Status priority: red failure > blue/green running > static-blue idle.
    private func currentMode() -> LightMode {
        if AppModel.shared.hasBackgroundFailure { return .failure }
        if AppModel.shared.activeBackgroundCount > 0 { return .running }
        return .idle
    }

    /// Refresh the status dot after background-state changes, redrawing only on a mode transition.
    private func refreshIfNeeded() {
        if currentMode() != lastMode { updateImage() }
    }

    /// Pulse for running/failure modes; show static brand blue while idle.
    private func updateImage() {
        let mode = currentMode()
        lastMode = mode
        switch mode {
        case .idle:
            stopAnimating()
            statusItem?.button?.image = Self.logoImage(barColor: Self.barBlue)
        case .running, .failure:
            startAnimating()
        }
    }

    /// Start status-dot pulsing idempotently at about 20fps with a ~1.8s period, only while tasks/failures exist.
    private func startAnimating() {
        guard animTimer == nil else { return }
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.animTick() }
        }
        RunLoop.main.add(t, forMode: .common)   // .common keeps animation running during menu tracking/dragging.
        animTimer = t
        animTick()   // Draw immediately to avoid first-frame delay; assign animTimer first so animTick's guard allows it.
    }

    private func stopAnimating() {
        animTimer?.invalidate()
        animTimer = nil
    }

    private func animTick() {
        // Race prevention: invalidating the timer in stopAnimating does not cancel an already enqueued Task.
        // Without this guard, it could overwrite updateImage's restored idle blue with an intermediate color. animTimer=nil marks the stopped state.
        guard animTimer != nil else { return }
        // Missed-publication prevention: task completion/failure clearing may change a child phase without publishing through AppModel,
        // leaving animation running. Check authoritative state each frame: stop/reset blue when idle, or switch colors between failure/running.
        let mode = currentMode()
        if mode == .idle { updateImage(); return }
        if mode != lastMode { lastMode = mode }    // Smoothly change running/failure colors while synchronizing deduplication state.
        animPhase += 0.18                          // Phase step gives period approximately 2*pi/0.18*0.05s = 1.75s.
        let f = CGFloat((sin(animPhase) + 1) / 2)  // Smoothly oscillate between 0 and 1.
        let color = mode == .failure
            ? Self.lerp(Self.barRed, Self.barRedAlt, f)    // Failure: bright-red/warm-orange-red warning pulse.
            : Self.lerp(Self.barBlue, Self.barGreen, f)    // Running: brand blue/green.
        statusItem?.button?.image = Self.logoImage(barColor: color)
    }

    /// Linearly interpolate sRGB components between two colors.
    private static func lerp(_ a: NSColor, _ b: NSColor, _ f: CGFloat) -> NSColor {
        NSColor(srgbRed: a.redComponent   + (b.redComponent   - a.redComponent)   * f,
                green:   a.greenComponent + (b.greenComponent - a.greenComponent) * f,
                blue:    a.blueComponent  + (b.blueComponent  - a.blueComponent)  * f,
                alpha: 1)
    }

    // Rebuild the menu before opening with current background tasks and actions.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let show = NSMenuItem(title: String(localized: "Show ServerDock"), action: #selector(showTapped), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        let checkUpdate = NSMenuItem(title: String(localized: "Checking for Updates…"), action: #selector(checkUpdateTapped), keyEquivalent: "")
        checkUpdate.target = self
        menu.addItem(checkUpdate)
        menu.addItem(.separator())

        let tasks = AppModel.shared.runningBackgroundSummaries
        let header = NSMenuItem(title: tasks.isEmpty ? String(localized: "No Background Tasks") : String(localized: "Background Tasks (\(tasks.count))"),
                                action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        // Show at most six task summaries; direct additional tasks to the in-app center so the menu does not grow excessively tall.
        let maxRows = 6
        for line in tasks.prefix(maxRows) {
            let it = NSMenuItem(title: "  " + line, action: nil, keyEquivalent: "")
            it.isEnabled = false
            menu.addItem(it)
        }
        if tasks.count > maxRows {
            let more = NSMenuItem(title: String(localized: "  \(tasks.count - maxRows) more — open the app to view"),
                                  action: #selector(showTapped), keyEquivalent: "")
            more.target = self
            menu.addItem(more)
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: String(localized: "Quit ServerDock"), action: #selector(quitTapped), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func showTapped() { onShow() }
    @objc private func quitTapped() { onQuit() }
    @objc private func checkUpdateTapped() { UpdateController.shared.checkForUpdates() }

    /// Selected ServerDock mark with the existing background-task status dot.
    static func logoImage(barColor: NSColor) -> NSImage {
        let size = NSSize(width: 20, height: 18)
        let img = NSImage(size: size, flipped: false) { _ in
            if let symbol = NSImage(named: "ServerDockMark") {
                let scale = min(15 / symbol.size.width, 16 / symbol.size.height)
                let width = symbol.size.width * scale
                let height = symbol.size.height * scale
                let rect = NSRect(x: (16 - width) / 2, y: (18 - height) / 2,
                                  width: width, height: height)
                symbol.draw(in: rect)
                NSColor.labelColor.setFill()
                rect.fill(using: .sourceIn)
            }
            NSColor.windowBackgroundColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: 13, y: 1, width: 7, height: 7)).fill()
            barColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: 14, y: 2, width: 5, height: 5)).fill()
            return true
        }
        img.isTemplate = false
        return img
    }
}

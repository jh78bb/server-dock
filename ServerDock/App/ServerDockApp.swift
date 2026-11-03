import AppKit
import Carbon.HIToolbox
import SwiftUI

/// If an input method supplies composing characters for shortcuts, interpret them using the last Latin keyboard layout.
/// Retain existing menu/SwiftUI-button shortcut routing.
enum KeyboardShortcuts {
    static func normalized(_ event: NSEvent, forTerminal: Bool, optionAsMetaKey: Bool = false) -> NSEvent {
        let flags = event.modifierFlags
        let terminalShortcut = forTerminal && (flags.contains(.control) || (optionAsMetaKey && flags.contains(.option)))
        let panelShortcut = event.keyCode == kVK_ANSI_Grave &&
            flags.intersection([.command, .control, .option, .shift]) == .control
        guard event.type == .keyDown || event.type == .keyUp,
              flags.contains(.command) || terminalShortcut || panelShortcut,
              let original = event.charactersIgnoringModifiers,
              original.unicodeScalars.contains(where: { !$0.isASCII }),
              let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return event }

        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return event }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        func translate(_ modifiers: UInt32) -> String? {
            var deadKeyState: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 8)
            let status = UCKeyTranslate(layout, event.keyCode, UInt16(kUCKeyActionDown), modifiers >> 8,
                                        UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask),
                                        &deadKeyState, characters.count, &length, &characters)
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: characters, count: length)
        }
        var textModifiers: UInt32 = 0
        if flags.contains(.shift) { textModifiers |= UInt32(shiftKey) }
        if flags.contains(.capsLock) { textModifiers |= UInt32(alphaLock) }
        guard let ignoringModifiers = translate(textModifiers),
              ignoringModifiers.unicodeScalars.allSatisfy({ $0.isASCII }) else { return event }
        if flags.contains(.command) { textModifiers |= UInt32(cmdKey) }
        if flags.contains(.control) { textModifiers |= UInt32(controlKey) }
        if flags.contains(.option) { textModifiers |= UInt32(optionKey) }
        guard let characters = translate(textModifiers) else { return event }
        return NSEvent.keyEvent(with: event.type, location: event.locationInWindow, modifierFlags: flags,
                               timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
                               characters: characters, charactersIgnoringModifiers: ignoringModifiers,
                               isARepeat: event.isARepeat, keyCode: event.keyCode) ?? event
    }
}

/// Resolve the language before NSApplication starts. System file panels use a separate service
/// whose language is fixed at process startup, so App.init is too late. Use English by default,
/// retain an explicit choice, and normalize the override to a localization available in the bundle.
@main
enum AppBootstrap {
    static func main() {
        // Copy data/preferences from the former ServerDesk location to ServerDock once.
        LegacyMigration.runIfNeeded()
        // Apply the saved choice or English on the first launch, before loading application UI.
        let saved = AppLanguage.resolve(storedValue: UserDefaults.standard.string(forKey: "appLanguage"))
        AppSettings.applyLanguageOverride(saved)
        let langs = Bundle.main.preferredLocalizations
        if !langs.isEmpty { UserDefaults.standard.set(langs, forKey: "AppleLanguages") }
        ServerDockApp.main()
    }
}

struct ServerDockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Use one Window rather than WindowGroup to prevent duplicate windows when reopening from Launchpad/menu bar/Command-N,
        // and remove the New Window menu item.
        Window("ServerDock", id: "main") {
            ContentView()
                // Minimum width accommodates activity bar, host sidebar, workspace, and approximately 720pt settings/add-host sheets.
                .frame(minWidth: 860, minHeight: 560)
        }
        .windowStyle(.hiddenTitleBar)
        // Initial window size fits the three-column workspace; retain minimums while the system remembers subsequent sizes.
        .defaultSize(width: 1200, height: 800)
        .commands { AppCommands(delegate: appDelegate) }
    }
}

/// Declare the app menu with SwiftUI Commands, because SwiftUI replaces an AppKit-created main menu during startup.
/// The former NSMenu approach lost Edit, making Command-V/C/Z beep instead of working in the editor.
/// Send standard editing actions through the first-responder chain to editors, terminals, and fields.
struct AppCommands: Commands {
    let delegate: AppDelegate

    private func send(_ action: Selector) { NSApp.sendAction(action, to: nil, from: nil) }

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button(String(localized: "About ServerDock")) { delegate.showAbout() }
            Button(String(localized: "Checking for Updates…")) { delegate.checkForUpdates() }
        }
        CommandGroup(replacing: .appTermination) {
            Button(String(localized: "Quit ServerDock")) { delegate.requestQuit() }.keyboardShortcut("q")   // Quit through background-task confirmation.
        }
        CommandGroup(replacing: .newItem) {
            Button(String(localized: "Command Palette…")) { delegate.showPalette() }.keyboardShortcut("k")
            Button(String(localized: "Network Tools…")) { MainActor.assumeIsolated { AppModel.shared.openNetTools(NetToolsRequest()) } }.keyboardShortcut("t", modifiers: [.command, .option])
            Button(String(localized: "Run Command on Multiple Servers…")) { delegate.showMultiRun() }.keyboardShortcut("r", modifiers: [.command, .shift])
        }
        CommandGroup(after: .newItem) {
            Button(String(localized: "Import Servers…")) { MainActor.assumeIsolated { AppModel.shared.presentImportHosts() } }
            Button(String(localized: "Export Servers…")) { MainActor.assumeIsolated { AppModel.shared.presentExportHosts() } }
            Divider()
            Button(String(localized: "Lock ServerDock")) { Task { @MainActor in AppLock.shared.lock() } }.keyboardShortcut("l", modifiers: [.control, .command])
        }
        CommandGroup(replacing: .saveItem) {
            // Command-W closes the current terminal/editor/files/overview child tab; closing the last child removes its server tab too.
            Button(String(localized: "Close Tab")) { delegate.closeTabOrWindow() }.keyboardShortcut("w")
        }
        CommandGroup(replacing: .undoRedo) {
            Button(String(localized: "Undo")) { send(Selector(("undo:"))) }.keyboardShortcut("z")
            Button(String(localized: "Redo")) { send(Selector(("redo:"))) }.keyboardShortcut("z", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .pasteboard) {
            Button(String(localized: "Cut")) { send(#selector(NSText.cut(_:))) }.keyboardShortcut("x")
            Button(String(localized: "Copy")) { send(#selector(NSText.copy(_:))) }.keyboardShortcut("c")
            Button(String(localized: "Paste")) { send(#selector(NSText.paste(_:))) }.keyboardShortcut("v")
            Button(String(localized: "Select All")) { send(#selector(NSText.selectAll(_:))) }.keyboardShortcut("a")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var aboutWindow: NSWindow?
    private var tray: TrayController?
    private weak var mainWindow: NSWindow?
    private var keyboardShortcutMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        keyboardShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            let responder = (event.window ?? NSApp.keyWindow)?.firstResponder
            let terminal = responder as? PacedTerminalView
            return KeyboardShortcuts.normalized(event, forTerminal: terminal != nil,
                                                 optionAsMetaKey: terminal?.optionAsMetaKey ?? false)
        }
        // Set AppKit appearance before the first frame to prevent a flash of the system's default light background.
        NSApp.appearance = NSAppearance(named: ThemeManager.shared.isDark ? .darkAqua : .aqua)
        NSApp.setActivationPolicy(.regular)
        applyAppIcon()
        _ = OSLogo.fontName   // Pre-register the bundled distribution logo font (Font Logos).
        _ = AppModel.shared   // Initialize the singleton early so menu bar and quit handlers can access background tasks without a window.
        Notifier.requestAuthIfNeeded()   // Request system notification permission for completed uploads/downloads.
        tray = TrayController(onShow: { [weak self] in self?.showMainWindow() },
                              onQuit: { [weak self] in self?.forceQuit() })
        UpdateController.shared.startup()   // Start automatic update scheduling (Sparkle for Developer ID builds; no-op for MAS).
        NSApp.activate(ignoringOtherApps: true)
        // Lock on reactivation if the configured idle time elapsed.
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppLock.shared.appDidResignActive() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppLock.shared.appDidBecomeActive() }
        }
        // Record the main window and install hide-to-menu-bar close handling one frame after window creation.
        DispatchQueue.main.async { [weak self] in self?.attachMainWindow() }
    }

    private func attachMainWindow() {
        guard mainWindow == nil else { return }
        // Identify a main-capable content window; canBecomeMain excludes NSStatusBarWindow/panels,
        // avoiding mistaking the status icon for the main window before About/Tooltip windows exist.
        if let w = NSApp.windows.first(where: { $0.canBecomeMain && $0.contentView != nil }) {
            mainWindow = w
            w.delegate = self
        }
    }

    /// Restore from the menu bar using regular activation, recovering Dock/menu and activating the main window.
    /// orderOut keeps windows in NSApp.windows; find the current main window instead of trusting a stale mainWindow reference.
    /// The status icon is never ordered out and needs no restoration; see hideToTray filtering.
    private func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        let w = mainWindow ?? NSApp.windows.first { $0.canBecomeMain && $0.contentView != nil }
        if mainWindow == nil, let w { mainWindow = w; w.delegate = self }
        w?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        applyAppIcon()   // Switching from .accessory to .regular rebuilds the Dock icon; reapply it to avoid the generic executable placeholder.
    }

    /// On Dock/Launchpad reopen, an ordered-out window still exists but WindowGroup might create another because none is visible.
    /// Reuse it and return false to prevent two windows in one process.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if flag { return true }   // Let the system bring an existing visible window forward instead of creating one.
        // Reuse a hidden main window when none is visible; allow default creation only if none exists.
        if NSApp.windows.contains(where: { $0.canBecomeMain && $0.contentView != nil }) {
            showMainWindow()
            return false
        }
        return true
    }

    /// Main-window close handling:
    /// With Hide to Menu Bar enabled, hide and switch to accessory mode without terminating.
    /// Otherwise start quit confirmation, including background tasks, but always return false to prevent immediate window closure.
    /// Cancel must preserve the window instead of leaving a running app without a window.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender == mainWindow else { return true }
        if AppSettings.shared.closeToTray {
            hideToTray()
        } else {
            requestQuit()   // Run the quit flow, including background-task confirmation. Returning false preserves the window if canceled.
        }
        return false
    }

    /// Hide visible content windows and switch to accessory mode, preserving background work/status icon.
    /// Order out only canBecomeMain windows (main/About); exclude the icon-hosting NSStatusBarWindow,
    /// which the former non-NSPanel/contentView filter hid permanently on macOS 15.
    /// Never hide the icon window/recreate its status item, preserving position and visibility without special recovery.
    @MainActor private func hideToTray() {
        AppLock.shared.lock()   // Require unlocking after reopening from the menu bar.
        // Close all sheets and end attached ones; their host windows can remain isVisible in NSApp.windows after Settings closes.
        // The old canBecomeMain filter missed those hosts, leaving visible windows and preventing Dock removal after .accessory activation.
        // Order out all visible windows except the persistent NSStatusBarWindow icon.
        AppModel.shared.dismissAllSheets()
        for w in NSApp.windows { if let s = w.attachedSheet { w.endSheet(s) } }
        for w in NSApp.windows where w.isVisible && !w.className.contains("NSStatusBar") {
            w.orderOut(nil)
        }
        NSApp.setActivationPolicy(.accessory)
    }

    /// Close/Command-Q entry point; custom methods do not inherit @MainActor from a protocol.
    /// Explicitly enter the main actor to access AppModel; AppKit already calls on the main thread, so this is immediate.
    /// With Hide to Menu Bar enabled, hide without prompting while tasks run; quit if none remain.
    /// Otherwise offer hide/quit confirmation, prioritizing active-task warnings and their list.
    /// Explicit menu-bar Quit ServerDock (forceQuit) always terminates regardless of this preference.
    @objc func requestQuit() {
        Task { @MainActor in
            AppModel.shared.dismissAllSheets()   // Dismiss open sheets first so they cannot cover or block the quit confirmation.
            if AppSettings.shared.closeToTray {
                if AppModel.shared.hasRunningBackground {
                    self.hideToTray()        // Keep background tasks alive by hiding the window without interruption or a dialog.
                } else {
                    NSApp.terminate(nil)     // Quit immediately when no tasks remain.
                }
            } else {
                self.showMainWindow()
                AppModel.shared.pendingQuitForce = false   // Standard close-window/Command-Q confirmation, with an option to hide to the menu bar.
                AppModel.shared.pendingQuitConfirm = true
            }
        }
    }

    /// Menu-bar Quit ServerDock always fully exits, ignoring the close-to-menu-bar setting.
    /// Confirm stopping active tasks, then terminate rather than hide; quit immediately without tasks.
    @objc func forceQuit() {
        Task { @MainActor in
            AppModel.shared.dismissAllSheets()   // Dismiss sheets so they cannot cover the quit confirmation.
            if AppModel.shared.hasRunningBackground {
                self.showMainWindow()
                AppModel.shared.pendingQuitForce = true    // In full-quit mode, confirmation terminates the app.
                AppModel.shared.pendingQuitConfirm = true
            } else {
                NSApp.terminate(nil)
            }
        }
    }


    // Custom confirmation already checks background tasks; see requestQuit/QuitConfirmDialog.
    // System logout/shutdown enters here directly; permit termination and clean remaining tunnels through willTerminate's registry.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Clean every exit path: dismiss sheets, reset bindings, close/join RDP, and gracefully stop forwarding.
        for w in NSApp.windows { if let sheet = w.attachedSheet { w.endSheet(sheet) } }
        AppModel.shared.dismissAllSheets()
        AppModel.shared.shutdownAllRDP()
        ForwardProcessRegistry.shared.terminateAll()
        UserDefaults.standard.synchronize()
        // After RemoteViewService use, e.g. Settings, exit()'s atexit can block on
        // CoreAnalytics sendExitBarrierWithTimeoutSync/XPC flush, leaving the process alive until SIGTERM,
        // causing Dock quit failures. Cleanup/persistence is complete, so bypass that barrier with _exit.
        _exit(0)
    }

    /// Command-W closes separate About/RDP windows; sheets use their own Cancel actions.
    /// In the main window, close the active child tab with dirty/running confirmation; without tabs, close/hide according to settings.
    @objc func closeTabOrWindow() {
        MainActor.assumeIsolated {
            guard let key = NSApp.keyWindow else { return }
            if key.sheetParent != nil { return }
            if mainWindow == nil { attachMainWindow() }
            let model = AppModel.shared
            if key != mainWindow {
                key.performClose(nil)
            } else if let id = model.focusedTabId(firstResponder: key.firstResponder) {
                model.closeTab(id)
            } else {
                key.performClose(nil)
            }
        }
    }

    @objc func showPalette() {
        MainActor.assumeIsolated {
            if mainWindow == nil { attachMainWindow() }
            let m = AppModel.shared
            m.showPalette.toggle()
        }
    }

    @objc func showMultiRun() {
        MainActor.assumeIsolated { AppModel.shared.showMultiRun = true }
    }

    @objc func checkForUpdates() {
        MainActor.assumeIsolated { UpdateController.shared.checkForUpdates() }   // Menu actions always arrive on the main thread.
    }

    @objc func showAbout() {
        if aboutWindow == nil {
            let hosting = NSHostingView(rootView: AboutWindow())
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 260),
                styleMask: [.titled, .closable],
                backing: .buffered, defer: false)
            w.title = String(localized: "About ServerDock")
            w.isReleasedWhenClosed = false
            w.contentView = hosting
            w.setContentSize(NSSize(width: 460, height: hosting.fittingSize.height))
            w.center()
            aboutWindow = w
        }
        aboutWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func applyAppIcon() {
        let url = Bundle.app.url(forResource: "AppIcon", withExtension: "icns")
            ?? Bundle.app.url(forResource: "AppIcon", withExtension: "png")
        if let url, let img = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = img
        }
    }

    // windowShouldClose owns hiding/quitting, so prevent automatic system termination on window closure.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

struct ContentView: View {
    // Use ObservedObject for the externally owned AppModel.shared singleton, whose lifetime is not view-managed.
    @ObservedObject private var model = AppModel.shared
    // Independent LayoutModel width prevents resizing from recomputing TabBar/Workspace.
    @StateObject private var layout = LayoutModel()
    @ObservedObject private var theme = ThemeManager.shared
    @ObservedObject private var appLock = AppLock.shared

    var body: some View {
        HStack(spacing: 0) {
            ActivityBar(model: model, layout: layout)
            Sidebar(model: model, tabs: model.tabsModel, layout: layout)
            // File panels allow extra width for deep trees; other sections cap at 320.
            // zIndex(1) keeps the divider's drag guide above workspace content.
            SidebarDivider(layout: layout, maxWidth: (model.section == .files || model.section == .hosts) ? 600 : 320)
                .zIndex(1)
            VStack(spacing: 0) {
                TabBar(model: model, tabs: model.tabsModel, layout: layout)
                HStack(spacing: 0) {
                    Workspace(model: model, tabs: model.tabsModel, layout: layout)
                    FilePanel(model: model, tabs: model.tabsModel, layout: layout)
                }
                .padding([.leading, .top], 3)
                .padding(.trailing, 6)
                .padding(.bottom, model.showsStatusBar ? 0 : 6)   // Preserve bottom padding even without a status bar.
                StatusBar(model: model, tabs: model.tabsModel)
            }
            .background(Pal.mantle)
        }
        .onReceive(model.tabsModel.$activeTabId) { id in
            // Select the left section for the active tab: VNC/RDP -> desktop, network tools -> tools, storage -> storage, otherwise hosts.
            // Preserve explicitly opened file/key/script management panels.
            guard let id, let tab = model.tabs.first(where: { $0.id == id }),
                  [.hosts, .rdp, .sites, .tools, .portForwards].contains(model.section) || tab.kind == .script || tab.kind == .portForwards else { return }
            let target: Section
            switch tab.kind {
            case .netTools, .keyManager: target = .tools
            case .script: target = .snippets
            case .portForwards: target = .portForwards
            case .site: target = .sites
            case .rdp: target = .rdp
            default: target = (model.host(tab.hostId)?.isRDP ?? false) ? .rdp : .hosts
            }
            if target != model.section { model.section = target }
        }
        .onChange(of: model.section) { sec in
            // Clamp excess width when leaving Files; additional width is allowed only there.
            // Resize immediately; width animation would relayout the workspace every frame and stutter.
            if sec != .files, sec != .hosts, layout.sidebarWidth > 320 {
                layout.sidebarWidth = 320
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Pal.base)
        .background(WindowConfigurator())
        .ignoresSafeArea()
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .overlay { if appLock.isLocked { LockOverlay(lock: appLock) } }
        // Limit animations to each overlay ZStack, not the outer modifier chain.
        // Otherwise animations propagate into sheets, incorrectly animating connection-test presentation.
        .overlay {
            ZStack {
                if model.showPalette {
                    CommandPaletteView(model: model).transition(.opacity)
                }
                if model.pendingCloseTabId != nil {
                    ConfirmDialog(
                        verbatimTitle: model.pendingCloseDialogTitle,
                        verbatimMessage: model.pendingCloseDialogMessage,
                        confirmTitle: "Close",
                        destructive: true,
                        onConfirm: { model.confirmPendingClose() },
                        onCancel: { model.cancelPendingClose() }
                    )
                    .transition(.opacity)
                }
                if let ctx = model.pendingMultiClose {
                    ConfirmDialog(
                        title: "Close \(ctx.ids.count) tabs?",
                        message: "It contains active sessions or unsaved changes; closing will interrupt or discard them.",
                        confirmTitle: "Close All",
                        destructive: true,
                        onConfirm: { model.confirmMultiClose() },
                        onCancel: { model.cancelMultiClose() }
                    )
                    .transition(.opacity)
                }
                if let ctx = model.pendingTabRename {
                    RenameDialog(
                        originalName: ctx.currentTitle, title: String(localized: "Rename Tab"),
                        onConfirm: { model.renameTab(ctx.id, to: $0) },
                        onCancel: { model.pendingTabRename = nil }
                    )
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: model.pendingCloseTabId)
            .animation(.easeOut(duration: 0.15), value: model.pendingMultiClose?.id)
            .animation(.easeOut(duration: 0.15), value: model.pendingTabRename?.id)
            // Disable overlay hit testing without a dialog; lingering transition hit areas must not block content.
            // Known SwiftUI overlay/transition/ignoresSafeArea issue; apply the same rule below.
            .allowsHitTesting(model.pendingCloseTabId != nil || model.pendingMultiClose != nil || model.pendingTabRename != nil)
        }
        // Group connection, fingerprint, password, and snippet-variable dialogs in one ViewModifier.
        // Avoid compiler type-check timeouts from long body overlay chains, as with AppSheets.
        .modifier(ConnectionDialogs(model: model))
        .overlay { fileOpOverlays }
        .overlay {
            // Dialog-free download arc covers the window without intercepting clicks; remove on completion and use IDs against stale animation cleanup.
            // Endpoints use SwiftUI global coordinates; subtract the overlay's global origin
            // to align regardless of window size, position, or safe areas.
            GeometryReader { proxy in
                if let fly = model.flyTransfer {
                    let o = proxy.frame(in: .global).origin
                    FlyToCornerView(
                        from: CGPoint(x: fly.from.x - o.x, y: fly.from.y - o.y),
                        to: CGPoint(x: model.backgroundButtonCenter.x - o.x,
                                    y: model.backgroundButtonCenter.y - o.y)
                    ) {
                        if model.flyTransfer?.id == fly.id { model.flyTransfer = nil }
                    }
                    .id(fly.id)
                }
            }
            .allowsHitTesting(false)
        }
        .overlay {
            ZStack {
                if model.pendingQuitConfirm {
                    QuitConfirmDialog(
                        model: model,
                        forceMode: model.pendingQuitForce,
                        onCancel: { model.pendingQuitConfirm = false; model.pendingQuitForce = false },
                        onHideToTray: {
                            model.pendingQuitConfirm = false
                            model.pendingQuitForce = false
                            AppSettings.shared.closeToTray = true
                            // Hide only main-capable content windows, excluding NSStatusBarWindow with canBecomeMain=false.
                            // Otherwise the status icon may disappear on macOS 15; see AppDelegate.hideToTray.
                            for w in NSApp.windows where w.isVisible && w.canBecomeMain {
                                w.orderOut(nil)
                            }
                            NSApp.setActivationPolicy(.accessory)
                        },
                        onConfirm: {
                            model.pendingQuitConfirm = false
                            model.pendingQuitForce = false
                            model.stopAllBackground()
                            ForwardProcessRegistry.shared.terminateAll()
                            NSApp.terminate(nil)
                        }
                    ).transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: model.pendingQuitConfirm)
            .allowsHitTesting(model.pendingQuitConfirm)
        }
        .modifier(AppSheets(model: model))
        .onAppear { model.applyStartupIfNeeded() }
    }

    /// Combine file context dialogs into one overlay to avoid body type-check timeouts.
    @ViewBuilder
    private var fileOpOverlays: some View {
        ZStack {
            if let ctx = model.pendingFileDelete {
                ConfirmDialog(
                    title: "Delete “\(ctx.file.name)”?",
                    message: ctx.file.isDir ? "This directory and all its contents will be deleted permanently." : "This file will be deleted permanently.",
                    confirmTitle: "Delete", destructive: true,
                    busy: model.fileDeleteBusy,
                    onConfirm: { model.confirmFileDelete() },
                    onCancel: { model.cancelFileDelete() }
                ).transition(.opacity)
            }
            if let h = model.pendingHostDelete {
                ConfirmDialog(
                    title: "Delete host “\(h.name)”?",
                    message: "This host's configuration (including saved passwords, session history, and port forwarding rules) will be deleted permanently.",
                    confirmTitle: "Delete", destructive: true,
                    onConfirm: { model.confirmHostDelete() },
                    onCancel: { model.cancelHostDelete() }
                ).transition(.opacity)
            }
            if let ctx = model.pendingBatchDelete {
                ConfirmDialog(
                    title: "Delete \(ctx.files.count) items?",
                    message: "The selected items (including any folders and their contents) will be permanently deleted and cannot be recovered.",
                    confirmTitle: "Delete", destructive: true,
                    busy: model.batchDeleteBusy,
                    onConfirm: { model.confirmBatchDelete() },
                    onCancel: { model.cancelBatchDelete() }
                ).transition(.opacity)
            }
            if let ctx = model.pendingFileRefresh {
                ConfirmDialog(
                    title: "The file has unsaved changes",
                    message: "\"\(ctx.fileName)\" has unsaved changes in the editor. Reloading will discard them.",
                    confirmTitle: "Reload", destructive: true,
                    onConfirm: { model.confirmFileRefreshReload() },
                    onCancel: { model.pendingFileRefresh = nil }
                ).transition(.opacity)
            }
            if let ctx = model.pendingFileRename {
                RenameDialog(
                    originalName: ctx.file.name,
                    onConfirm: { model.confirmFileRename(newName: $0) },
                    onCancel: { model.pendingFileRename = nil }
                ).transition(.opacity)
            }
            if let ctx = model.pendingFileChmod {
                ChmodDialog(
                    fileName: ctx.file.name, initialMode: ctx.mode,
                    onConfirm: { model.confirmFileChmod(mode: $0) },
                    onCancel: { model.pendingFileChmod = nil }
                ).transition(.opacity)
            }
            if let ctx = model.pendingFileCreate {
                RenameDialog(
                    originalName: "", title: ctx.isDir ? String(localized: "New Folder") : String(localized: "New File"),
                    onConfirm: { model.confirmFileCreate(name: $0) },
                    onCancel: { model.pendingFileCreate = nil }
                ).transition(.opacity)
            }
            if let info = model.pendingFileInfo {
                ConfirmDialog(
                    verbatimTitle: info.title, verbatimMessage: info.message,
                    confirmTitle: "OK", showCancel: false,
                    onConfirm: { model.pendingFileInfo = nil },
                    onCancel: { model.pendingFileInfo = nil }
                ).transition(.opacity)
            }
            if let id = model.focusedTransferId, let task = model.transfers.first(where: { $0.id == id }) {
                UploadDialog(task: task,
                             onHide: { model.focusedTransferId = nil },
                             onClose: { model.removeTransfer(id) })
                    .transition(.opacity)
            }
            if let task = model.extractTask, model.showExtractDialog {
                ExtractDialog(task: task,
                              onHide: { model.showExtractDialog = false },
                              onClose: { model.extractTask = nil; model.showExtractDialog = false })
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: model.focusedTransferId)
        .animation(.easeOut(duration: 0.18), value: model.extractTask?.id)
        .animation(.easeOut(duration: 0.18), value: model.showExtractDialog)
        .animation(.easeOut(duration: 0.15), value: model.pendingFileDelete?.id)
        .animation(.easeOut(duration: 0.15), value: model.pendingBatchDelete?.id)
        .animation(.easeOut(duration: 0.15), value: model.pendingHostDelete?.id)
        .animation(.easeOut(duration: 0.15), value: model.pendingFileRename?.id)
        .animation(.easeOut(duration: 0.15), value: model.pendingFileChmod?.id)
        .animation(.easeOut(duration: 0.15), value: model.pendingFileCreate?.id)
        .animation(.easeOut(duration: 0.15), value: model.pendingFileRefresh?.id)
        .animation(.easeOut(duration: 0.15), value: model.pendingFileInfo?.id)
        // Disable hit testing without a file dialog to prevent lingering transition layers blocking the screen.
        .allowsHitTesting(anyFileOverlayActive)
    }

    /// Whether a file-action dialog is shown, including upload/download dialogs.
    private var anyFileOverlayActive: Bool {
        model.pendingFileDelete != nil || model.pendingBatchDelete != nil || model.pendingHostDelete != nil || model.pendingFileRefresh != nil ||
        model.pendingFileRename != nil || model.pendingFileChmod != nil ||
        model.pendingFileCreate != nil || model.pendingFileInfo != nil ||
        model.focusedTransferId != nil ||
        (model.extractTask != nil && model.showExtractDialog)
    }
}

/// Group sheets/alerts in one ViewModifier to keep ContentView.body short
/// and avoid compiler expression type-check timeouts.
/// Separate connection dialogs from ContentView.body to shorten its overlay chain.
/// Modifier order sets stacking: progress, fingerprint, password, then snippet variables on top.
private struct ConnectionDialogs: ViewModifier {
    @ObservedObject var model: AppModel

    func body(content: Content) -> some View {
        content
            // RDP progress/certificate dialogs cover overview/list; open the desktop tab only after success.
            .overlay {
                ZStack {
                    if let s = model.connectingRDP {
                        RDPConnectingDialog(session: s,
                                            onConnected: { model.finishRDPConnecting() },
                                            onCancel: { model.cancelRDPConnecting() })
                            .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.2), value: model.connectingRDP != nil)
                .allowsHitTesting(model.connectingRDP != nil)
            }
            // Choose inline/new-window RDP presentation only when the preference is Ask.
            .overlay {
                ZStack {
                    if let s = model.pendingRDPOpen {
                        RDPOpenDialog(hostName: s.host.name,
                                      onChoose: { model.resolveRDPOpen(s, window: $0, remember: $1) },
                                      onCancel: { model.cancelRDPOpen() })
                            .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.15), value: model.pendingRDPOpen != nil)
                .allowsHitTesting(model.pendingRDPOpen != nil)
            }
            .overlay {
                ZStack {
                    if let h = model.connectingHost {
                        ConnectingDialog(host: h,
                                         successHint: model.connectingActionHint,
                                         verify: { await model.verifyHostKey(h) },
                                         onConnected: { model.finishConnecting() },
                                         onCancel: { model.cancelConnecting() })
                            .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.25), value: model.connectingHost?.id)
                .allowsHitTesting(model.connectingHost != nil)
            }
            // Place unknown-host fingerprint verification above connection progress.
            .overlay {
                ZStack {
                    if let pending = model.pendingHostKey {
                        HostKeyDialog(pending: pending).transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.15), value: model.pendingHostKey?.id)
                .allowsHitTesting(model.pendingHostKey != nil)
            }
            // Ask-mode one-time password prompt appears before connection progress.
            .overlay {
                ZStack {
                    if let h = model.pendingAskAuth {
                        AskPasswordDialog(host: h,
                                          onConfirm: { model.submitAskAuth($0) },
                                          onCancel: { model.cancelAskAuth() })
                            .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.15), value: model.pendingAskAuth?.id)
                .allowsHitTesting(model.pendingAskAuth != nil)
            }
            // Ask for Insert/Run when the snippet default action is Ask.
            .overlay {
                ZStack {
                    if let s = model.pendingSnippetAction {
                        SnippetActionDialog(snippet: s,
                                            onChoose: { model.resolveSnippetAction(s, run: $0, remember: $1) },
                                            onCancel: { model.cancelSnippetAction() })
                            .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.15), value: model.pendingSnippetAction?.id)
                .allowsHitTesting(model.pendingSnippetAction != nil)
            }
            // Fill {{variables}} before inserting/running snippets.
            .overlay {
                ZStack {
                    if let req = model.pendingSnippetRun {
                        SnippetRunDialog(request: req,
                                         onConfirm: { model.submitSnippetRun($0) },
                                         onCancel: { model.cancelSnippetRun() })
                            .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.15), value: model.pendingSnippetRun?.id)
                .allowsHitTesting(model.pendingSnippetRun != nil)
            }
    }
}

private struct AppSheets: ViewModifier {
    @ObservedObject var model: AppModel

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $model.showSettings) { SettingsView(model: model) }
            .sheet(isPresented: $model.showHostManager) { HostManagerView(model: model) }
            .sheet(isPresented: $model.showAddHost) { AddHostView(model: model) }
            .sheet(item: $model.editingHost) { host in AddHostView(model: model, editing: host) }
            .sheet(isPresented: $model.showAddRDPHost) { AddRDPHostView(model: model) }
            .sheet(item: $model.editingRDPHost) { host in AddRDPHostView(model: model, editing: host) }
            .sheet(item: $model.forwardPanelHost) { host in PortForwardView(model: model, host: host) }
            .sheet(isPresented: $model.showGenerateKey) { GenerateKeyView(model: model) }
            .sheet(item: $model.detailKey) { key in KeyDetailView(model: model, key: key) }
            .alert("Done", isPresented: Binding(get: { model.infoNotice != nil }, set: { if !$0 { model.infoNotice = nil } })) {
                Button("OK", role: .cancel) { model.infoNotice = nil }
            } message: { Text(model.infoNotice ?? "") }
            .confirmationDialog(model.pendingPower.map { $0.action == .reboot ? String(localized: "Reboot \($0.host.name)?") : String(localized: "Shut down \($0.host.name)?") } ?? "",
                                isPresented: Binding(get: { model.pendingPower != nil }, set: { if !$0 { model.pendingPower = nil } }), titleVisibility: .visible) {
                if let p = model.pendingPower {
                    Button(p.action == .reboot ? String(localized: "Reboot") : String(localized: "Shut Down"), role: .destructive) { let x = p; model.pendingPower = nil; model.performPower(x.host, x.action) }
                    Button("Cancel", role: .cancel) { model.pendingPower = nil }
                }
            } message: {
                if let p = model.pendingPower {
                    Text(p.action == .reboot
                         ? String(localized: "Every session and service on this server is interrupted while it restarts. Terminals, transfers and tunnels to it will disconnect.")
                         : String(localized: "The server powers off and can only be started again with Wake-on-LAN or its power button. Everything running on it stops, and connections drop."))
                }
            }
            .sheet(item: $model.firewallRequest) { req in FirewallView(model: model, request: req) }
            .sheet(item: $model.portsHost) { host in PortsView(model: model, host: host) }
            .sheet(isPresented: $model.showMultiRun) { MultiRunSheet(model: model) }
            .sheet(item: $model.httpCheckHost) { host in HTTPCheckSheet(host: host, prefill: model.httpCheckPrefill) }
            .sheet(isPresented: $model.showAddSite) { SiteEditView(model: model) }
            .sheet(item: $model.editingSite) { site in SiteEditView(model: model, editing: site) }
            .alert("Delete Storage?", isPresented: Binding(
                get: { model.siteBeingDeleted != nil },
                set: { if !$0 { model.siteBeingDeleted = nil } }
            )) {
                Button("Delete", role: .destructive) {
                    if let s = model.siteBeingDeleted { model.deleteSite(s) }
                    model.siteBeingDeleted = nil
                }
                Button("Cancel", role: .cancel) { model.siteBeingDeleted = nil }
            } message: {
                Text("\"\(model.siteBeingDeleted?.name ?? "")\" and its saved password will be removed from this Mac. Files on the server are not affected.")
            }
            .sheet(isPresented: $model.showCreateSnippet) { SnippetEditView(model: model) }
            .sheet(item: $model.editingSnippet) { snip in SnippetEditView(model: model, editing: snip) }
            .sheet(item: $model.aiProfileEdit) { req in
                AIProfileEditor(
                    profile: req.target.profile, isNew: req.target.isNew,
                    connection: model.host(req.hostId)?.ssh,
                    onSave: { p in
                        if req.target.isNew { AIChatModel.shared.addProfile(p, selectFor: req.hostId) } else { AIChatModel.shared.updateProfile(p) }
                        model.aiProfileEdit = nil
                    },
                    onDelete: { AIChatModel.shared.deleteProfile(id: req.target.profile.id); model.aiProfileEdit = nil },
                    onCancel: { model.aiProfileEdit = nil })
            }
            .sheet(item: $model.aiPromptContext) { context in AIPromptSheet(model: model, context: context) }
            .alert("Operation Failed", isPresented: Binding(
                get: { model.keyOpError != nil },
                set: { if !$0 { model.keyOpError = nil } }
            )) {
                Button("OK", role: .cancel) { model.keyOpError = nil }
            } message: {
                Text(model.keyOpError ?? "")
            }
            .alert("Notice", isPresented: Binding(
                get: { model.snippetNotice != nil },
                set: { if !$0 { model.snippetNotice = nil } }
            )) {
                Button("OK", role: .cancel) { model.snippetNotice = nil }
            } message: {
                Text(model.snippetNotice ?? "")
            }
    }
}

/// Extend content through the title bar with fullSizeContentView/transparency; move traffic lights down
/// to align with tabs without a separate header row, controlled by lightsDownOffset.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        context.coordinator.attach(to: v)
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject {
        weak var window: NSWindow?
        private var originalY: [ObjectIdentifier: CGFloat] = [:]
        private let lightsDownOffset: CGFloat = 9 // Vertical offset of the window control buttons.

        func attach(to v: NSView, attempt: Int = 0) {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard let w = v.window else {
                    if attempt < 20 { self.attach(to: v, attempt: attempt + 1) }
                    return
                }
                self.window = w
                // Set the window's brand base background before the first frame to prevent startup white flashes.
                w.backgroundColor = ThemeManager.shared.windowBackground
                w.isOpaque = true
                w.titlebarAppearsTransparent = true
                w.titleVisibility = .hidden
                w.styleMask.insert(.fullSizeContentView)
                // Avoid initial search autofocus, which can briefly display macOS autocomplete/input-method
                // candidate cards. Clear initial first responder; user clicks still focus normally.
                w.initialFirstResponder = nil
                w.makeFirstResponder(nil)
                // Leave title-bar container height intact to preserve native traffic-light appearance/behavior.
                NotificationCenter.default.addObserver(self, selector: #selector(self.reposition), name: NSWindow.didResizeNotification, object: w)
                NotificationCenter.default.addObserver(self, selector: #selector(self.reposition), name: NSWindow.didBecomeKeyNotification, object: w)
                self.reposition()
            }
        }

        @objc func reposition() {
            guard let w = window else { return }
            let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
                .compactMap { w.standardWindowButton($0) }
            for b in buttons {
                let id = ObjectIdentifier(b)
                if originalY[id] == nil { originalY[id] = b.frame.origin.y }
                b.setFrameOrigin(NSPoint(x: b.frame.origin.x, y: originalY[id]! - lightsDownOffset))
            }
        }
    }
}

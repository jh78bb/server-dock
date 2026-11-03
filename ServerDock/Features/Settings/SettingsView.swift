import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var theme = ThemeManager.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var certStore = RDPCertTrustStore.shared
    @ObservedObject private var appLock = AppLock.shared
    @ObservedObject private var aiChat = AIChatModel.shared
    @State private var showLanguageRestart = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().overlay(Pal.fill(0.06))
            content
        }
        .frame(width: 720, height: 480)
        .background(Pal.solidBase)
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .onChange(of: settings.appLanguage) { showLanguageRestart = true }
        .overlay {
            if showLanguageRestart {
                ConfirmDialog(
                    title: "Restart to Apply Language",
                    message: "Language changes take effect after you restart ServerDock.",
                    confirmTitle: "Restart Now",
                    cancelTitle: "Later",
                    onConfirm: { showLanguageRestart = false; Self.relaunch() },
                    onCancel: { showLanguageRestart = false })
            }
        }
    }

    /// Dismiss modal sheets before relaunch because SwiftUI .sheet can intercept NSApp.terminate,
    /// leaving old/new instances running together. Wait one frame before launching/replacing the process.
    static func relaunch() {
        AppModel.shared.dismissAllSheets()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: cfg) { _, _ in
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
        }
    }

    // MARK: - Left navigation

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Pal.text)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 16)
            .padding(.bottom, 12)

            VStack(spacing: 2) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    navItem(tab)
                }
            }
            .padding(.horizontal, 8)

            Spacer()
        }
        .frame(width: 176)
        .frame(maxHeight: .infinity)
        .background(Pal.solidMantle)
    }

    private func navItem(_ tab: SettingsTab) -> some View {
        let selected = model.settingsTab == tab
        return Button {
            model.settingsTab = tab
        } label: {
            HStack(spacing: 9) {
                Image(lucideSymbol: tab.icon)
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? Pal.mauve : Pal.overlay)
                    .frame(width: 18)
                Text(tab.label)
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? Pal.text : Pal.subtext)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(
                selected ? Pal.mauve.opacity(0.14) : Color.clear,
                in: RoundedRectangle(cornerRadius: 7)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: - Right content

    private var content: some View {
        VStack(spacing: 0) {
            // Top close area.
            HStack {
                Spacer()
                Button {
                    model.showSettings = false
                } label: {
                    Image(lucideSymbol: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Pal.overlay)
                        .frame(width: 26, height: 26)
                        .background(Pal.fill(0.05), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch model.settingsTab {
                    case .general: generalSettings
                    case .terminal: terminalSettings
                    case .transfer: transferSettings
                    case .monitor: monitorSettings
                    case .security: securitySettings
                    case .aiChat: aiChatSettings
                    case .keys: keysSettings
                    case .about: aboutSettings
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 4)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Pal.solidBase)
    }

    // MARK: - General

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 24) {
            sectionHeader(String(localized: "General"))

            settingRow(String(localized: "Appearance"), description: String(localized: "Switch between Dark, Light, or System")) {
                SegmentedControl(
                    options: AppearanceMode.allCases.map { (value: $0, verbatim: $0.label) },
                    selection: $theme.mode
                )
                .frame(width: 240)
            }

            settingRow(String(localized: "Language"), description: String(localized: "Interface language; changes take effect after restarting ServerDock")) {
                ThemedDropdown(
                    options: AppLanguage.allCases.map { (value: $0, verbatim: $0.label) },
                    selection: $settings.appLanguage
                )
                .frame(width: 160)
            }

            settingRow(String(localized: "Startup Behavior"), description: String(localized: "Default action on app launch")) {
                ThemedDropdown(
                    options: [(StartupBehavior.welcome, String(localized: "Welcome Page")),
                              (.overview, String(localized: "Local Overview")),
                              (.terminal, String(localized: "New Terminal"))] +
                             (settings.startupBehavior == .host ? [(.host,
                                 model.hosts.first(where: { $0.id == settings.startupHostId })?.name
                                     ?? String(localized: "Welcome Page"))] : []),
                    selection: $settings.startupBehavior
                )
                .frame(width: 160)
            }

            settingRow(String(localized: "Hide to menu bar when window closes"), description: String(localized: "Closing the main window doesn't quit; background tasks (such as port forwarding) keep running. Restore from the menu bar icon")) {
                ThemedToggle(isOn: $settings.closeToTray)
            }

            settingRow(String(localized: "Confirm before deleting a host"), description: String(localized: "Show a confirmation dialog when deleting a host to prevent accidental deletion")) {
                ThemedToggle(isOn: $settings.confirmHostDelete)
            }

            settingRow(String(localized: "Open Remote Desktop In"), description: String(localized: "Whether a successful RDP connection opens as an embedded tab or in a new window. \"Always Ask\" prompts you to choose and can remember your choice.")) {
                ThemedDropdown(
                    options: RDPOpenMode.allCases.map { ($0, $0.label) },
                    selection: $settings.rdpOpenMode
                )
                .frame(width: 160)
            }

            if settings.rdpOpenMode == .window {
                settingRow(String(localized: "New Window Behavior"), description: String(localized: "When opening in a new window, whether new Remote Desktop windows enter full screen by default.")) {
                    ThemedDropdown(
                        options: [(true, String(localized: "Full Screen by Default")), (false, String(localized: "Exit Full Screen"))],
                        selection: $settings.rdpWindowFullscreen
                    )
                    .frame(width: 160)
                }
            }

            settingRow(String(localized: "Remote Desktop Clipboard Sync"), description: String(localized: "Sync plain text between the local and remote clipboards in both directions for RDP connections (copy and paste across both). When off, the two clipboards stay independent.")) {
                ThemedToggle(isOn: $settings.rdpClipboardSync)
            }
        }
    }

    // MARK: - Transfers

    private var transferSettings: some View {
        VStack(alignment: .leading, spacing: 24) {
            sectionHeader(String(localized: "Transfer"))

            settingRow(String(localized: "Ask Where to Save Downloads"), description: String(localized: "Ask where to save on every download")) {
                ThemedToggle(isOn: $settings.downloadAskEachTime)
            }

            if !settings.downloadAskEachTime {
                settingRow(String(localized: "Default Download Folder"), description: String(localized: "Downloaded files are saved here")) {
                    HStack(spacing: 8) {
                        Text(settings.resolvedDownloadDir.path)
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(Pal.subtext)
                            .lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: 220, alignment: .trailing)
                            .tooltip(settings.resolvedDownloadDir.path)
                        SecondaryButton(title: "Choose…", action: chooseDownloadDir)
                    }
                }
            }

            settingRow(String(localized: "Show a dialog when downloading"), description: String(localized: "When off, downloads don't show a progress window—they arc into Background Tasks in the bottom-left corner; progress remains visible in Background Tasks")) {
                ThemedToggle(isOn: $settings.showDownloadDialog)
            }

            settingRow(String(localized: "Concurrent Transfers"), description: String(localized: "Number of concurrent uploads/downloads (sharing one pool); anything beyond is queued automatically")) {
                ThemedDropdown(
                    options: [(1, String(localized: "1")), (2, String(localized: "2")), (3, String(localized: "3")), (4, String(localized: "4")), (5, String(localized: "5"))],
                    selection: $settings.maxConcurrentTransfers
                )
                .frame(width: 120)
            }

            settingRow(String(localized: "Yield Slot When Paused"), description: String(localized: "On: a paused task frees its slot so queued tasks can run first. Off: a paused task keeps its slot, preserving the original order.")) {
                ThemedToggle(isOn: $settings.pausedReleasesSlot)
            }
        }
    }

    // MARK: - Monitoring

    private var monitorSettings: some View {
        VStack(alignment: .leading, spacing: 24) {
            sectionHeader(String(localized: "Monitoring"))

            settingRow(String(localized: "Resource Alert"), description: String(localized: "Send a system notification when host CPU, memory, or disk stays under sustained high load")) {
                ThemedToggle(isOn: $settings.resourceAlerts)
            }

            settingRow(String(localized: "Hide Monitoring Tips"), description: String(localized: "Don't show the data collection notice at the top of the monitoring panel")) {
                ThemedToggle(isOn: $settings.monitorNoticeHidden)
            }
        }
    }

    // MARK: - Security

    private var securitySettings: some View {
        VStack(alignment: .leading, spacing: 24) {
            sectionHeader(String(localized: "Security"))

            settingRow(String(localized: "App Lock"), description: String(localized: "Require Touch ID or your Mac password to open ServerDock. Sessions, transfers and tunnels keep running while it is locked.")) {
                ThemedToggle(isOn: Binding(get: { appLock.enabled }, set: { appLock.setEnabled($0) }))
            }
            if appLock.enabled {
                settingRow(String(localized: "Lock After"), description: String(localized: "How long ServerDock can stay in the background before it locks. Also locks when hidden to the menu bar and with ⌃⌘L.")) {
                    ThemedDropdown(options: [(value: 0, verbatim: String(localized: "Immediately")), (value: 1, verbatim: String(localized: "1 minute")), (value: 5, verbatim: String(localized: "5 minutes")),
                                             (value: 15, verbatim: String(localized: "15 minutes")), (value: 60, verbatim: String(localized: "1 hour"))], selection: $appLock.delayMinutes)
                        .frame(width: 160)
                }
                HStack { Spacer(); SecondaryButton(title: "Lock Now") { appLock.lock() } }
            }
            if let e = appLock.lastError { Text(e).font(.system(size: 11)).foregroundStyle(Pal.red) }

            VStack(alignment: .leading, spacing: 10) {
                Text("Trusted Remote Desktop Certificates")
                    .font(.system(size: 13)).foregroundStyle(Pal.text)
                Text("Recorded here when you select \"Always trust this computer\" while connecting to an RDP host. Revoke it to be asked again on the next connection.")
                    .font(.system(size: 11)).foregroundStyle(Pal.overlay)
                    .fixedSize(horizontal: false, vertical: true)

                if certStore.entries.isEmpty {
                    Text("No Trusted Certificates")
                        .font(.system(size: 12)).foregroundStyle(Pal.overlay)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 28)
                        .background(Pal.fill(0.04), in: RoundedRectangle(cornerRadius: 10))
                } else {
                    VStack(spacing: 0) {
                        ForEach(certStore.entries) { cert in
                            trustedCertRow(cert)
                            if cert.id != certStore.entries.last?.id {
                                Divider().overlay(Pal.fill(0.06))
                            }
                        }
                    }
                    .background(Pal.fill(0.04), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Pal.fill(0.06), lineWidth: 1))
                }
            }
        }
    }

    // MARK: - AI assistant

    private var aiChatSettings: some View {
        VStack(alignment: .leading, spacing: 24) {
            sectionHeader(String(localized: "AI Assistant"))
            Text(AppEnv.localTerminalEnabled
                 ? String(localized: "Choose Mac → SSH or On server in each host's chat. Install and sign in to the selected CLI where it runs.")
                 : String(localized: "Chat runs the selected CLI on the SSH server. Install and sign in there first."))
                .font(.system(size: 12))
                .foregroundStyle(Pal.subtext)

            settingRow(String(localized: "Default Provider"), description: String(localized: "Used for new hosts' AI chat panels")) {
                ThemedDropdown(
                    options: AIAPIProvider.allCases.map { (value: $0, verbatim: $0.displayName) },
                    selection: $aiChat.defaultProvider
                )
                .frame(width: 200)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("ChatGPT (Codex CLI)").font(.system(size: 13, weight: .medium)).foregroundStyle(Pal.text)
                settingRow(String(localized: "Model"), description: String(localized: "Leave empty to use the CLI default")) {
                    ThemedTextField(verbatim: "CLI default", text: $aiChat.openAIModel)
                        .frame(width: 200)
                }
            }
            .padding(14)
            .background(Pal.fill(0.04), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 10) {
                Text("Claude CLI").font(.system(size: 13, weight: .medium)).foregroundStyle(Pal.text)
                settingRow(String(localized: "Model"), description: String(localized: "Leave empty to use the CLI default")) {
                    ThemedTextField(verbatim: "CLI default", text: $aiChat.anthropicModel)
                        .frame(width: 200)
                }
            }
            .padding(14)
            .background(Pal.fill(0.04), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func trustedCertRow(_ cert: RDPTrustedCert) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(lucideSymbol: "lock.shield")
                .font(.system(size: 14)).foregroundStyle(Pal.mauve)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: "\(cert.host):\(cert.port)")
                    .font(.system(size: 13, design: .monospaced)).foregroundStyle(Pal.text)
                Text(cert.fingerprint.isEmpty ? String(localized: "(No fingerprint)") : cert.fingerprint)
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Pal.overlay)
                    .lineLimit(1).truncationMode(.middle)
                    .tooltip(cert.fingerprint)
            }
            Spacer()
            SecondaryButton(title: "Undo") { certStore.revoke(cert.id) }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private func chooseDownloadDir() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Select")
        panel.directoryURL = settings.resolvedDownloadDir
        if panel.runModal() == .OK, let url = panel.url { settings.downloadDir = url.path }
    }

    // MARK: - Terminal

    private var terminalSettings: some View {
        VStack(alignment: .leading, spacing: 24) {
            sectionHeader(String(localized: "Terminal"))

            settingRow(String(localized: "Default Shell"), description: String(localized: "Shell program for new terminals")) {
                ThemedDropdown(
                    options: [(DefaultShell.auto, String(localized: "Auto-Detect")), (.zsh, "/bin/zsh"), (.bash, "/bin/bash")],
                    selection: $settings.defaultShell
                )
                .frame(width: 160)
            }

            settingRow(String(localized: "Close Confirmation"), description: String(localized: "Confirm before closing a terminal with active processes")) {
                ThemedToggle(isOn: $settings.closeConfirm)
            }

            settingRow(String(localized: "Terminal Toolbar"), description: String(localized: "Show a toolbar above SSH terminals with the current path and quick actions (upload, files, scripts, and more)")) {
                ThemedToggle(isOn: $settings.terminalToolbar)
            }

            settingRow(String(localized: "Git Info in Status Bar"), description: String(localized: "Show the branch and change count of the terminal's current folder when it is a Git repository. Runs read-only git commands on the server every 30 seconds while a repository folder is open.")) {
                ThemedToggle(isOn: $settings.statusBarGit)
            }

            settingRow(String(localized: "How Scripts Run"), description: String(localized: "Default action when a script is clicked; \"Ask every time\" shows an Insert/Run choice you can remember")) {
                ThemedDropdown(
                    options: SnippetAction.allCases.map { ($0, $0.label) },
                    selection: $settings.snippetAction
                )
                .frame(width: 160)
            }

            settingRow(String(localized: "Font"), description: String(localized: "Font used by the terminal")) {
                ThemedDropdown(
                    options: [
                        ("", String(localized: "Automatic (Recommended)")),
                        ("SF Mono", "SF Mono"), ("Menlo", "Menlo"), ("Monaco", "Monaco"),
                        ("JetBrainsMono Nerd Font", "JetBrains Mono"),
                        ("FiraCode Nerd Font", "Fira Code"),
                        ("MesloLGM Nerd Font", "Meslo LGM"),
                    ],
                    selection: $settings.termFont
                )
                .frame(width: 220)
            }

            settingRow(String(localized: "Font Size"), description: String(localized: "Terminal Font Size")) {
                ThemedStepper(value: $settings.termFontSize, range: 10...24, suffix: " pt")
            }

            settingRow(String(localized: "Cursor Style"), description: String(localized: "Shape of the terminal cursor")) {
                SegmentedControl(
                    options: [(value: "block", label: "Block"), (value: "bar", label: "Bar"), (value: "underline", label: "Underline")],
                    selection: $settings.termCursorStyle
                )
                .frame(width: 220)
            }

            settingRow(String(localized: "Cursor Blink"), description: String(localized: "Whether the cursor blinks")) {
                ThemedToggle(isOn: $settings.termCursorBlink)
            }

            settingRow(String(localized: "Scrollback Buffer"), description: String(localized: "Maximum number of lines the terminal keeps")) {
                ThemedDropdown(
                    options: [(500, String(localized: "500 lines")), (1000, String(localized: "1,000 lines")), (5000, String(localized: "5,000 lines")), (10000, String(localized: "10,000 lines")), (50000, String(localized: "50,000 lines"))],
                    selection: $settings.termScrollback
                )
                .frame(width: 140)
            }
        }
    }

    // MARK: - Shortcuts

    private var keysSettings: some View {
        VStack(alignment: .leading, spacing: 24) {
            sectionHeader(String(localized: "Shortcuts"))

            shortcutRow(String(localized: "New Terminal"), shortcut: "⌘ T")
            shortcutRow(String(localized: "Close Tab"), shortcut: "⌘ W")
            shortcutRow(String(localized: "Copy"), shortcut: "⌘ C")
            shortcutRow(String(localized: "Paste"), shortcut: "⌘ V")
            shortcutRow(String(localized: "Clear Screen"), shortcut: "⌘ K")
            shortcutRow(String(localized: "Search"), shortcut: "⌘ F")
            shortcutRow(String(localized: "Toggle Sidebar"), shortcut: "⌘ B")
            shortcutRow(String(localized: "Toggle Terminal Panel (⌘J)"), shortcut: "⌘ J")
            shortcutRow(String(localized: "Next Tab"), shortcut: "⌃ Tab")
            shortcutRow(String(localized: "Previous Tab"), shortcut: "⌃ ⇧ Tab")
            shortcutRow(String(localized: "Increase Font Size"), shortcut: "⌘ +")
            shortcutRow(String(localized: "Decrease Font Size"), shortcut: "⌘ -")
        }
    }

    // MARK: - About

    private var aboutSettings: some View {
        VStack(alignment: .leading, spacing: 24) {
            sectionHeader(String(localized: "About"))
            AboutContent()   // Reuse the standalone About window's content.
        }
    }

    // MARK: - Components

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(Pal.text)
            .padding(.bottom, 4)
    }

    private func settingRow<C: View>(_ title: String, description: String, @ViewBuilder control: () -> C) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13)).foregroundStyle(Pal.text)
                Text(description).font(.system(size: 11)).foregroundStyle(Pal.overlay)
            }
            Spacer()
            control()
        }
        .padding(.vertical, 4)
    }

    private func shortcutRow(_ action: String, shortcut: String) -> some View {
        HStack {
            Text(action).font(.system(size: 13)).foregroundStyle(Pal.text)
            Spacer()
            Text(shortcut)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Pal.subtext)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Pal.fill(0.06), in: RoundedRectangle(cornerRadius: 5))
        }
        .padding(.vertical, 2)
    }
}

import Foundation

enum StartupBehavior: String, CaseIterable, Hashable {
    case welcome, overview, terminal, host
}

enum DefaultShell: String, CaseIterable, Hashable {
    case auto, zsh, bash
}

/// Snippet execution preference: ask, insert into command line only, or run immediately.
enum SnippetAction: String, CaseIterable, Hashable {
    case ask, insert, run
    var label: String {
        switch self {
        case .ask: return String(localized: "Ask every time")
        case .insert: return String(localized: "Insert into Command Line Only")
        case .run: return String(localized: "Run Directly")
        }
    }
}

/// After RDP connection: ask, inline tab, or separate full-screen window.
enum RDPOpenMode: String, CaseIterable, Hashable {
    case ask, embedded, window
    var label: String {
        switch self {
        case .ask: return String(localized: "Ask every time")
        case .embedded: return String(localized: "Inline Tabs")
        case .window: return String(localized: "New Window")
        }
    }
}

/// Display language: system, English, Korean, Japanese, Spanish, or Brazilian Portuguese. Defaults to English.
enum AppLanguage: String, CaseIterable, Hashable {
    case en, ko, system, ja
    case es
    case ptBR = "pt-BR"

    static let defaultLanguage: Self = .en

    /// Use English for new installs and unknown legacy values; retain explicit language choices.
    static func resolve(storedValue: String?) -> Self {
        storedValue.flatMap(Self.init(rawValue:)) ?? defaultLanguage
    }
    /// Show each language's native name so it is recognizable in any interface language.
    var label: String {
        switch self {
        case .system: return String(localized: "System")
        case .en: return "English"
        case .ko: return "한국어"
        case .ja: return "日本語"
        case .es: return "Español"
        case .ptBR: return "Português (Brasil)"
        }
    }
    /// AppleLanguages override; nil explicitly follows the system language.
    var appleCode: String? {
        switch self {
        case .system: return nil
        default: return rawValue
        }
    }
}

/// Global app preferences stored in UserDefaults.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    @Published var startupBehavior: StartupBehavior {
        didSet { d.set(startupBehavior.rawValue, forKey: "startupBehavior") }
    }
    /// App Store builds have no local host, so its visibility setting does not apply.
    @Published var showLocalHost: Bool {
        didSet { d.set(showLocalHost, forKey: "showLocalHost") }
    }
    @Published var startupHostId: String {
        didSet { d.set(startupHostId, forKey: "startupHostId") }
    }
    // Localization loads at process startup, so language changes take effect after relaunch.
    @Published var appLanguage: AppLanguage {
        didSet { d.set(appLanguage.rawValue, forKey: "appLanguage"); Self.applyLanguageOverride(appLanguage) }
    }
    @Published var defaultShell: DefaultShell {
        didSet { d.set(defaultShell.rawValue, forKey: "defaultShell") }
    }
    @Published var closeConfirm: Bool {
        didSet { d.set(closeConfirm, forKey: "closeConfirm") }
    }
    /// SSH quick toolbar for cwd, uploads, files, snippets, and related actions.
    @Published var terminalToolbar: Bool {
        didSet { d.set(terminalToolbar, forKey: "terminalToolbar") }
    }
    /// Code-editor minimap on the right.
    @Published var editorMinimap: Bool {
        didSet { d.set(editorMinimap, forKey: "editorMinimap") }
    }

    /// Live status-bar CPU/memory metrics add one server-monitor connection; disabled by default.
    @Published var statusBarLiveStats: Bool {
        didSet { d.set(statusBarLiveStats, forKey: "statusBarLiveStats") }
    }
    /// Status-bar Git branch/change/ahead-behind data uses read-only remote git commands when cwd is a repository.
    @Published var statusBarGit: Bool {
        didSet { d.set(statusBarGit, forKey: "statusBarGit") }
    }
    /// Whether the file tree follows terminal cd; disable for stable manual browsing.
    @Published var fileTreeFollowsTerminal: Bool {
        didSet { d.set(fileTreeFollowsTerminal, forKey: "fileTreeFollowsTerminal") }
    }
    /// Editor wrapping, disabled by default so long lines scroll horizontally.
    @Published var editorWrapLines: Bool {
        didSet { d.set(editorWrapLines, forKey: "editorWrapLines") }
    }
    /// Editor point size.
    @Published var editorFontSize: Int {
        didSet { d.set(editorFontSize, forKey: "editorFontSize") }
    }

    // ---------- Terminal ----------
    /// Terminal font name; empty uses the default monospaced font.
    @Published var termFont: String {
        didSet { d.set(termFont, forKey: "termFont") }
    }
    @Published var termFontSize: Int {
        didSet { d.set(termFontSize, forKey: "termFontSize") }
    }
    /// Cursor shape: block / bar / underline.
    @Published var termCursorStyle: String {
        didSet { d.set(termCursorStyle, forKey: "termCursorStyle") }
    }
    @Published var termCursorBlink: Bool {
        didSet { d.set(termCursorBlink, forKey: "termCursorBlink") }
    }
    /// Scrollback line count.
    @Published var termScrollback: Int {
        didSet { d.set(termScrollback, forKey: "termScrollback") }
    }

    /// Default download directory; empty uses system Downloads.
    @Published var downloadDir: String {
        didSet { d.set(downloadDir, forKey: "downloadDir") }
    }
    /// Ask for a destination on each download.
    @Published var downloadAskEachTime: Bool {
        didSet { d.set(downloadAskEachTime, forKey: "downloadAskEachTime") }
    }
    /// Shared upload/download concurrency limit; queue excess tasks.
    @Published var maxConcurrentTransfers: Int {
        didSet { d.set(maxConcurrentTransfers, forKey: "maxConcurrentTransfers") }
    }
    /// Pausing releases capacity by default so queued work can use the slot.
    /// Disable to reserve the paused task's slot until it resumes or is canceled.
    @Published var pausedReleasesSlot: Bool {
        didSet { d.set(pausedReleasesSlot, forKey: "pausedReleasesSlot") }
    }
    /// Show download progress dialogs by default; disabling uses a fly-in animation to bottom-left Background Tasks instead.
    @Published var showDownloadDialog: Bool {
        didSet { d.set(showDownloadDialog, forKey: "showDownloadDialog") }
    }

    /// Send system notifications for sustained high CPU/memory/disk usage.
    @Published var resourceAlerts: Bool {
        didSet { d.set(resourceAlerts, forKey: "resourceAlerts") }
    }

    /// Closing the main window hides to the menu bar instead of quitting, keeping background work alive.
    @Published var closeToTray: Bool {
        didSet { d.set(closeToTray, forKey: "closeToTray") }
    }

    /// Confirm host deletion to prevent accidental removal.
    @Published var confirmHostDelete: Bool {
        didSet { d.set(confirmHostDelete, forKey: "confirmHostDelete") }
    }

    /// Permanently hide the monitor data-collection notice through Settings > General; persisted.
    @Published var monitorNoticeHidden: Bool {
        didSet { d.set(monitorNoticeHidden, forKey: "monitorNoticeHidden") }
    }
    /// Temporary acknowledgment hides the collection notice for this run only; it returns after restart.
    @Published var monitorNoticeAckedThisSession = false

    // Snippet action defaults to Ask and offers Insert/Run, with an option to remember the choice.
    @Published var snippetAction: SnippetAction {
        didSet { d.set(snippetAction.rawValue, forKey: "snippetAction") }
    }

    // RDP opening defaults to Ask, offering Tab/New Window with an option to remember.
    @Published var rdpOpenMode: RDPOpenMode {
        didSet { d.set(rdpOpenMode.rawValue, forKey: "rdpOpenMode") }
    }

    // Bidirectional plain-text RDP clipboard sync defaults on; disabling prevents sending/receiving clipboard text.
    @Published var rdpClipboardSync: Bool {
        didSet { d.set(rdpClipboardSync, forKey: "rdpClipboardSync") }
    }

    // Default fullscreen for separate RDP windows; enabled by default and applies only when rdpOpenMode == .window.
    @Published var rdpWindowFullscreen: Bool {
        didSet { d.set(rdpWindowFullscreen, forKey: "rdpWindowFullscreen") }
    }

    private init() {
        startupBehavior = StartupBehavior(rawValue: d.string(forKey: "startupBehavior") ?? "") ?? .overview   // Default startup opens the local-host overview.
        showLocalHost = d.object(forKey: "showLocalHost") as? Bool ?? true
        startupHostId = d.string(forKey: "startupHostId") ?? ""
        defaultShell = DefaultShell(rawValue: d.string(forKey: "defaultShell") ?? "") ?? .auto
        closeConfirm = d.object(forKey: "closeConfirm") as? Bool ?? true
        terminalToolbar = d.object(forKey: "terminalToolbar") as? Bool ?? true
        editorMinimap = d.object(forKey: "editorMinimap") as? Bool ?? true
        fileTreeFollowsTerminal = d.object(forKey: "fileTreeFollowsTerminal") as? Bool ?? true
        statusBarGit = d.object(forKey: "statusBarGit") as? Bool ?? true
        statusBarLiveStats = d.object(forKey: "statusBarLiveStats") as? Bool ?? false
        editorWrapLines = d.object(forKey: "editorWrapLines") as? Bool ?? false
        editorFontSize = min(max(d.object(forKey: "editorFontSize") as? Int ?? 12, 9), 28)
        termFont = d.string(forKey: "termFont") ?? ""
        termFontSize = d.object(forKey: "termFontSize") as? Int ?? 13
        termCursorStyle = d.string(forKey: "termCursorStyle") ?? "bar"
        termCursorBlink = d.object(forKey: "termCursorBlink") as? Bool ?? true
        termScrollback = d.object(forKey: "termScrollback") as? Int ?? 1000
        downloadDir = d.string(forKey: "downloadDir") ?? ""
        downloadAskEachTime = d.object(forKey: "downloadAskEachTime") as? Bool ?? false
        maxConcurrentTransfers = d.object(forKey: "maxConcurrentTransfers") as? Int ?? 2
        pausedReleasesSlot = d.object(forKey: "pausedReleasesSlot") as? Bool ?? true
        showDownloadDialog = d.object(forKey: "showDownloadDialog") as? Bool ?? true
        resourceAlerts = d.object(forKey: "resourceAlerts") as? Bool ?? true
        closeToTray = d.object(forKey: "closeToTray") as? Bool ?? false
        confirmHostDelete = d.object(forKey: "confirmHostDelete") as? Bool ?? true
        monitorNoticeHidden = d.object(forKey: "monitorNoticeHidden") as? Bool ?? false
        snippetAction = SnippetAction(rawValue: d.string(forKey: "snippetAction") ?? "") ?? .ask
        rdpOpenMode = RDPOpenMode(rawValue: d.string(forKey: "rdpOpenMode") ?? "") ?? .ask
        rdpClipboardSync = d.object(forKey: "rdpClipboardSync") as? Bool ?? true
        rdpWindowFullscreen = d.object(forKey: "rdpWindowFullscreen") as? Bool ?? false   // Do not enter full screen by default; forcing it on every connection is disruptive.
        appLanguage = AppLanguage.resolve(storedValue: d.string(forKey: "appLanguage"))
        Self.applyLanguageOverride(appLanguage)
    }

    /// Persist the language override for the next launch; System clears it to follow macOS.
    static func applyLanguageOverride(_ lang: AppLanguage) {
        let d = UserDefaults.standard
        if let code = lang.appleCode {
            d.set([code], forKey: "AppleLanguages")
        } else {
            d.removeObject(forKey: "AppleLanguages")
        }
    }

    /// Resolve the download directory, using system Downloads when unset.
    var resolvedDownloadDir: URL {
        if !downloadDir.isEmpty {
            return URL(fileURLWithPath: (downloadDir as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    /// Resolve the actual shell executable path.
    var resolvedShell: String {
        switch defaultShell {
        case .auto: return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        case .zsh: return "/bin/zsh"
        case .bash: return "/bin/bash"
        }
    }
}

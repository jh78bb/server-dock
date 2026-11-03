import AppKit
import Combine
import Foundation

// MARK: - Channel-independent state model

/// High-level update UI state; progress/version/release-note data lives in separate UpdateController @Published properties,
/// allowing incremental asynchronous updates without replacing all enum associated values.
enum UpdatePhase: Equatable {
    case idle            // Idle, with no panel.
    case checking        // Checking.
    case upToDate        // Up to date.
    case found           // New version found; awaiting a decision.
    case downloading     // Downloading.
    case extracting      // Extracting.
    case readyToInstall  // Downloaded; awaiting installation/restart.
    case installing      // Installing; restart imminent.
    case error(String)   // Error.
}

/// New-version details from the appcast item.
struct UpdateInfo: Equatable {
    var displayVersion: String   // Display version, e.g. "0.9.2".
    var build: String            // CFBundleVersion, e.g. "28".
    var dateString: String?      // Release-date text.
    var isCritical: Bool         // Critical update.
}

/// User choice in new-version/ready-to-install panels.
enum UpdateUserChoice { case install, skip, later }

// MARK: - Channel backend protocol

/// Developer ID updates through in-app Sparkle; Mac App Store builds use the system store.
/// The backend weakly references UpdateController to publish state; UI observes only the controller.
@MainActor
protocol UpdateBackend: AnyObject {
    /// Whether in-app automatic updating is supported: true for Developer ID; MAS can only open the App Store.
    var supportsInApp: Bool { get }
    /// Background-check setting maps to Sparkle automaticallyChecksForUpdates; not applicable to MAS.
    var automaticChecks: Bool { get set }
    /// Last-check time persisted by Sparkle; nil for MAS.
    var lastCheckDate: Date? { get }

    /// Called once after app startup to schedule Developer ID updates.
    func startup()
    /// Check for updates; userInitiated=true displays checking/up-to-date UI.
    func check(userInitiated: Bool)
    /// User choice after finding a version or preparing installation/restart.
    func respond(_ choice: UpdateUserChoice)
    /// Cancel an active check/download.
    func cancel()
    /// Acknowledge and dismiss up-to-date/error notices.
    func acknowledge()
    /// Silently end an inline up-to-date check even without a dialog; the Sparkle session must still finish,
    /// or sessionInProgress stays true and the next check reports "called but .sessionInProgress == YES".
    func concludeSilently()
}

// MARK: - Controller (the UI's only observed source)

/// Own the channel backend, publish UI state, forward user actions, and show/hide update panels.
/// About, menu-bar, and settings entry points all use this controller without knowing the distribution channel.
@MainActor
final class UpdateController: ObservableObject {
    static let shared = UpdateController()

    // Observed state.
    @Published private(set) var phase: UpdatePhase = .idle
    @Published private(set) var info: UpdateInfo?            // Valid while an update is found/downloading/installing.
    @Published private(set) var releaseNotesHTML: String?    // Release notes, possibly populated asynchronously.
    @Published private(set) var downloadReceived: UInt64 = 0
    @Published private(set) var downloadTotal: UInt64 = 0
    @Published private(set) var extractFraction: Double = 0
    @Published private(set) var lastCheckDate: Date?

    /// UI-bound automatic-check setting; forward changes to the backend and refresh display state.
    @Published var automaticChecks: Bool = false {
        didSet {
            guard !syncingAuto, backend.automaticChecks != automaticChecks else { return }
            backend.automaticChecks = automaticChecks
        }
    }
    private var syncingAuto = false   // Prevent didSet and backend updates triggering each other recursively.

    var supportsInApp: Bool { backend.supportsInApp }

    private let backend: UpdateBackend

    private init() {
        #if SERVERDOCK_MAS
        backend = AppStoreUpdateBackend()
        #else
        backend = SparkleUpdateBackend()
        #endif
        // Backend-to-controller state binding; initialized by the Sparkle backend.
        (backend as? ControllerBindable)?.bind(self)
        refreshFromBackend()
    }

    /// Start updater scheduling after app launch.
    func startup() {
        backend.startup()
        refreshFromBackend()
    }

    // User actions.

    // Whether checking/upToDate appear in a separate window. Inline About/settings controls already show progress/status,
    // so only found/download/install/error require a full panel there. Menu/menu-bar entry points use true.
    private var surfaceTransient = true

    /// Manual check; surfaceTransient=false leaves checking/up-to-date presentation to inline controls.
    func checkForUpdates(surfaceTransient: Bool = true) {
        self.surfaceTransient = surfaceTransient
        backend.check(userInitiated: true)
    }

    func install() { backend.respond(.install) }
    func skip()    { backend.respond(.skip) }
    func later()   { backend.respond(.later); dismissPanel() }
    func cancel()  { backend.cancel() }
    func acknowledge() { backend.acknowledge() }

    /// Dismiss on close/Later by hiding the window only; later()/acknowledge() handles any pending backend reply.
    func dismissPanel() { UpdateWindowPresenter.shared.dismiss() }

    /// Close-button action depends on phase: cancel active work, defer, or acknowledge the notice.
    func userClosedPanel() {
        switch phase {
        case .checking, .downloading:   cancel()        // Cancel the active check/download.
        case .found, .readyToInstall:   later()         // Treat as Later, retaining the update for a future reminder.
        case .upToDate, .error:         acknowledge()   // Acknowledge and close the notice.
        case .extracting, .installing:  dismissPanel()  // Noninterruptible phase: hide the window only.
        case .idle:                     dismissPanel()
        }
    }

    // Backend state updates, main thread only.

    func apply(_ newPhase: UpdatePhase) {
        phase = newPhase
        switch newPhase {
        case .idle:
            UpdateWindowPresenter.shared.dismiss()
        case .checking:
            // Inline checking uses its own spinner without a separate window; other entry points present normally.
            if surfaceTransient { UpdateWindowPresenter.shared.present() }
            else { UpdateWindowPresenter.shared.dismiss() }
        case .upToDate:
            if surfaceTransient {
                UpdateWindowPresenter.shared.present()
            } else {
                // Inline entry does not show a dialog, but must finish the Sparkle session or later checks fail on sessionInProgress.
                UpdateWindowPresenter.shared.dismiss()
                backend.concludeSilently()
            }
        case .found, .downloading, .extracting, .readyToInstall, .installing, .error:
            UpdateWindowPresenter.shared.present()
        }
        refreshFromBackend()
    }

    func setInfo(_ i: UpdateInfo?) { info = i }
    func setReleaseNotes(_ html: String?) { releaseNotesHTML = html }
    func setDownload(received: UInt64, total: UInt64) {
        downloadReceived = received; downloadTotal = total
    }
    func setExtract(_ f: Double) { extractFraction = f }

    /// Update automatic-check/last-check state from the backend without triggering setters back into it.
    func refreshFromBackend() {
        syncingAuto = true
        automaticChecks = backend.automaticChecks
        syncingAuto = false
        lastCheckDate = backend.lastCheckDate
    }

    // Display helpers.

    /// Progress 0..1: byte ratio for downloads, extractFraction for extraction.
    var progressFraction: Double {
        switch phase {
        case .downloading:
            guard downloadTotal > 0 else { return 0 }
            return min(1, Double(downloadReceived) / Double(downloadTotal))
        case .extracting: return extractFraction
        default: return 0
        }
    }

    /// Progress text, e.g. "3.2 MB / 12 MB".
    var progressLabel: String {
        guard downloadTotal > 0 else { return "" }
        let f = ByteCountFormatter()
        f.countStyle = .file
        return "\(f.string(fromByteCount: Int64(downloadReceived))) / \(f.string(fromByteCount: Int64(downloadTotal)))"
    }
}

/// Backends such as Sparkle implement this when they need a controller reference.
@MainActor
protocol ControllerBindable: AnyObject {
    func bind(_ controller: UpdateController)
}

// MARK: - Mac App Store backend

/// MAS builds cannot self-update in-app due to sandbox/review restrictions; Check for Updates opens the App Store updates page.
@MainActor
final class AppStoreUpdateBackend: UpdateBackend {
    var supportsInApp: Bool { false }
    var automaticChecks: Bool {
        get { true }      // App Store automatic updates are system-managed; always enabled here.
        set {}
    }
    var lastCheckDate: Date? { nil }

    func startup() {}

    func check(userInitiated: Bool) {
        // Use the Updates page for now; after publication use macappstore://apps.apple.com/app/id<APPID>.
        if let url = URL(string: "macappstore://showUpdatesPage") {
            NSWorkspace.shared.open(url)
        }
    }

    func respond(_ choice: UpdateUserChoice) {}
    func cancel() {}
    func acknowledge() {}
    func concludeSilently() {}
}

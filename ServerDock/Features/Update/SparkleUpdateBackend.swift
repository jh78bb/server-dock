#if !SERVERDOCK_MAS
import AppKit
import Foundation
import Sparkle

/// Developer ID update backend wrapping SPUUpdater and implementing SPUUserDriver to control all update UI.
/// Translate Sparkle callbacks into UpdateController state instead of using its standard NSAlert-style UI,
/// then render through ThemedXxx panels (plan B: no native modals, consistent appearance).
///
/// Sparkle dispatches user-driver callbacks on the main thread, so this class is @MainActor; reply blocks are stored/called there too.
@MainActor
final class SparkleUpdateBackend: NSObject, UpdateBackend, ControllerBindable, SPUUserDriver {

    private var updater: SPUUpdater!
    private weak var controller: UpdateController?
    private var started = false

    // Pending Sparkle reply blocks; at most one category is active at a time.
    private var foundReply: ((SPUUserUpdateChoice) -> Void)?     // New version found: install/skip/dismiss.
    private var cancellation: (() -> Void)?                      // Checking/downloading can be canceled.
    private var acknowledgement: (() -> Void)?                   // Acknowledge up-to-date/error status.
    private var readyContinuation: CheckedContinuation<SPUUserUpdateChoice, Never>?  // Waiting for installation/restart.
    private var didStartDownload = false                        // Used only to reset progress text.

    override init() {
        super.init()
        // hostBundle/applicationBundle are the main bundle; userDriver=self. Info.plist supplies feedURL/public key.
        updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: nil)
    }

    func bind(_ controller: UpdateController) { self.controller = controller }

    // MARK: UpdateBackend

    var supportsInApp: Bool { true }

    var automaticChecks: Bool {
        get { updater?.automaticallyChecksForUpdates ?? false }
        set { updater?.automaticallyChecksForUpdates = newValue }
    }

    var lastCheckDate: Date? { updater?.lastUpdateCheckDate }

    func startup() {
        guard !started else { return }
        do {
            try updater.start()
            started = true
        } catch {
            NSLog("[Update] Failed to start Sparkle: \(error.localizedDescription)")
        }
    }

    func check(userInitiated: Bool) {
        startup()   // Idempotently ensure startup.
        if userInitiated {
            updater.checkForUpdates()
        } else {
            updater.checkForUpdatesInBackground()
        }
    }

    func respond(_ choice: UpdateUserChoice) {
        let mapped: SPUUserUpdateChoice
        switch choice {
        case .install: mapped = .install
        case .skip:    mapped = .skip
        case .later:   mapped = .dismiss
        }
        if let reply = foundReply {
            foundReply = nil
            reply(mapped)
        } else if let cont = readyContinuation {
            readyContinuation = nil
            // Skipping makes no sense after download; treat skip as Later while awaiting installation.
            guard choice == .install else { cont.resume(returning: .dismiss); return }
            // Installation restarts the app. Close all settings/About sheets first so window-level modal state cannot block NSApp termination
            // and suppress restarting; wait one run-loop turn for dismissal before Sparkle takes over.
            DispatchQueue.main.async {
                AppModel.shared.dismissAllSheets()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    cont.resume(returning: .install)
                }
            }
        }
    }

    func cancel() {
        if let c = cancellation {
            cancellation = nil
            c()
        }
        controller?.apply(.idle)
    }

    func acknowledge() {
        if let a = acknowledgement {
            acknowledgement = nil
            a()
        }
        controller?.apply(.idle)
    }

    /// Silently finish an inline up-to-date session by acknowledging Sparkle to reset sessionInProgress.
    /// Do not apply(.idle) directly; Sparkle later calls dismissUpdateInstallation to finish naturally.
    func concludeSilently() {
        if let a = acknowledgement {
            acknowledgement = nil
            a()
        }
        cancellation = nil
    }

    // MARK: - SPUUserDriver

    /// First-run permission: omit the native dialog, default to automatic checks without system profiling, and let settings disable checks later.
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
        controller?.refreshFromBackend()
    }

    /// Manual check: show checking state with cancellation.
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
        controller?.apply(.checking)
    }

    /// New version: populate version information and inline release notes when available, then await a choice.
    func showUpdateFound(with appcastItem: SUAppcastItem,
                         state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        foundReply = reply
        controller?.setInfo(UpdateInfo(
            displayVersion: appcastItem.displayVersionString,
            build: appcastItem.versionString,
            dateString: appcastItem.dateString,
            isCritical: appcastItem.isCriticalUpdate))
        // Inline HTML notes from appcast description; releaseNotesLink notes are populated asynchronously later.
        if let desc = appcastItem.itemDescription, !desc.isEmpty {
            controller?.setReleaseNotes(desc)
        } else {
            controller?.setReleaseNotes(nil)
        }
        controller?.apply(.found)
    }

    /// Asynchronously downloaded notes from sparkle:releaseNotesLink.
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        let enc = encoding(from: downloadData.textEncodingName)
        if let html = String(data: downloadData.data, encoding: enc)
            ?? String(data: downloadData.data, encoding: .utf8) {
            controller?.setReleaseNotes(html)
        }
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {
        // Release-note fetch failure does not block updating; show the no-release-notes fallback.
        controller?.setReleaseNotes(nil)
    }

    /// A manual check found no update.
    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        self.acknowledgement = acknowledgement
        controller?.apply(.upToDate)
    }

    /// Updater failure, e.g. network/verification errors.
    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        self.acknowledgement = acknowledgement
        controller?.apply(.error(error.localizedDescription))
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
        didStartDownload = true
        controller?.setDownload(received: 0, total: 0)
        controller?.apply(.downloading)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        controller?.setDownload(received: 0, total: expectedContentLength)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        let c = controller
        let received = (c?.downloadReceived ?? 0) + length
        c?.setDownload(received: received, total: c?.downloadTotal ?? 0)
    }

    func showDownloadDidStartExtractingUpdate() {
        cancellation = nil     // Extraction cannot be canceled.
        controller?.setExtract(0)
        controller?.apply(.extracting)
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        controller?.setExtract(progress)
        controller?.apply(.extracting)
    }

    /// Download/extraction finished; await restart/install confirmation using an async continuation bridged to panel buttons.
    func showReadyToInstallAndRelaunch() async -> SPUUserUpdateChoice {
        await withCheckedContinuation { (cont: CheckedContinuation<SPUUserUpdateChoice, Never>) in
            self.readyContinuation = cont
            self.controller?.apply(.readyToInstall)
        }
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                              retryTerminatingApplication: @escaping () -> Void) {
        controller?.apply(.installing)
    }

    /// Installation/restart completed, usually in the new process; immediately acknowledge and reset the panel.
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
        controller?.apply(.idle)
    }

    /// Sparkle requests dismissal of all update UI after completion/cancellation.
    func dismissUpdateInstallation() {
        foundReply = nil
        cancellation = nil
        acknowledgement = nil
        if let cont = readyContinuation {   // Resume any remaining continuation on exceptional paths to prevent leaks.
            readyContinuation = nil
            cont.resume(returning: .dismiss)
        }
        controller?.apply(.idle)
    }

    /// Optionally bring the update window forward.
    func showUpdateInFocus() {
        UpdateWindowPresenter.shared.present()
    }

    // MARK: - Utilities

    private func encoding(from name: String?) -> String.Encoding {
        guard let name else { return .utf8 }
        let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cf != kCFStringEncodingInvalidId else { return .utf8 }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }
}
#endif

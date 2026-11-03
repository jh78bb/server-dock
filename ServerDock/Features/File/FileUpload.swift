import SwiftUI

// MARK: - State

enum ItemState: Equatable {
    case waiting          // Queued for transfer.
    case checking         // Probe the remote target for name conflicts/resumable data.
    case asking           // Name conflict detected; await the user's decision.
    case uploading        // Transferring, including compression into a temporary file.
    case done             // Completed.
    case skipped          // Skipped by the user.
    case failed(String)   // Failed; preserve the message. Uncompressed transfers can resume.
    case cancelled        // Canceled.
}

enum SessionPhase: Equatable { case queued, running, paused, done, cancelled }
enum TransferDirection { case upload, download }

enum OverwriteDecision { case overwrite, skip, cancel }
enum AskAction { case overwrite, skip, overwriteAll, skipAll, cancel }
enum BulkPolicy { case ask, overwriteAll, skipAll }

/// One pending upload file. Reference semantics allow individual rows to subscribe without refreshing the whole list.
@MainActor
final class UploadItem: ObservableObject, Identifiable {
    nonisolated let id = UUID()
    let url: URL
    let name: String
    let localSize: Int64
    let remotePath: String

    @Published var state: ItemState = .waiting
    @Published var sent: Int64 = 0          // Confirmed bytes for progress and total calculations.
    var interrupted = false                 // A partial file remains after failure and can be resumed.

    /// Upload item: url is the local source and remotePath the remote destination.
    init(url: URL, destDir: String) {
        self.url = url
        self.name = url.lastPathComponent
        self.localSize = UploadItem.fileSize(url)
        self.remotePath = destDir.hasSuffix("/") ? destDir + name : destDir + "/" + name
    }

    /// Download item: remotePath is the remote source; url is the local destination, deduplicated against existing files and other downloads.
    /// name is the final local filename, possibly with a " (n)" suffix; localSize is the remote size used as the progress denominator.
    init(download file: RemoteFile, toLocalURL url: URL) {
        self.url = url
        self.name = url.lastPathComponent
        self.localSize = file.size
        self.remotePath = file.path
    }

    var fraction: Double {
        localSize > 0 ? min(1, Double(sent) / Double(localSize)) : (state == .done ? 1 : 0)
    }
    static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }
}

struct AskContext: Identifiable {
    let id = UUID()
    let name: String
    let remoteSize: Int64
    let localSize: Int64
}

// MARK: - Upload task

@MainActor
final class UploadTask: ObservableObject {
    nonisolated let id = UUID()
    let direction: TransferDirection
    let destDir: String
    let totalBytes: Int64
    // Owning host for background-task grouping; set at creation and used only for display.
    var hostId: String? = nil
    var hostName: String = ""
    private let fs: RemoteFS
    private let onAllDone: () -> Void

    @Published var items: [UploadItem]
    @Published var phase: SessionPhase = .queued    // Initially queued; the coordinator calls start() to dequeue and transition to .running.
    /// Called once when the task completes/is canceled so the coordinator can advance the transfer queue.
    var onFinished: (() -> Void)? = nil
    /// Called after pause/resume requests so the coordinator can admit queued tasks and waiting resume requests.
    var onPauseStateChanged: (() -> Void)? = nil
    /// The user requested resume but no slot is free; phase remains .paused while waiting for coordinator admission.
    @Published private(set) var awaitingSlot = false

    /// Whether this task has failed files, used by failure indicators such as the red menu-bar status light.
    var hasFailure: Bool {
        items.contains { if case .failed = $0.state { return true } else { return false } }
    }

    /// Per-destination-file mutex injected by AppModel; acquire/release around each file transfer.
    /// Serialize only tasks writing the same destination to prevent .part collisions; other files still transfer concurrently.
    var acquirePathLock: ((String) async -> Void)? = nil
    var releasePathLock: ((String) -> Void)? = nil

    /// Lock key: host plus remote path for uploads (shared .part name), local path for downloads.
    private func lockKey(_ item: UploadItem) -> String {
        switch direction {
        case .upload:   return "up:\(hostId ?? ""):\(item.remotePath)"
        case .download: return "down:\(item.url.path)"
        }
    }
    @Published var index = 0
    @Published var overallSent: Int64 = 0
    @Published var speed: Double = 0
    @Published var pendingAsk: AskContext? = nil

    private let control = UploadControl()
    private var bulkPolicy: BulkPolicy = .ask
    private var askCont: CheckedContinuation<OverwriteDecision, Never>?
    private var resumeCont: CheckedContinuation<Void, Never>?   // Suspend the main loop when paused and wake it on resume.
    private var lastSampledOverall: Int64 = 0
    private var pendingBaselineReset = true
    private var started = false
    private var heldLockKey: String? = nil   // Current per-file write lock; keep it while paused and release it when finished.

    /// Switch to the destination `key` write lock: release the previous completed file's lock, then acquire the new lock.
    /// Reentering the same file after a pause does not acquire the lock twice.
    private func switchLock(to key: String) async {
        if heldLockKey == key { return }
        if let h = heldLockKey { releasePathLock?(h); heldLockKey = nil }
        await acquirePathLock?(key)
        heldLockKey = key
    }
    /// Release the current write lock during task completion or cancellation.
    private func releaseHeldLock() {
        if let h = heldLockKey { releasePathLock?(h); heldLockKey = nil }
    }

    init(files: [URL], destDir: String, fs: RemoteFS, onAllDone: @escaping () -> Void) {
        self.direction = .upload
        self.destDir = destDir
        self.fs = fs
        self.onAllDone = onAllDone
        let mapped = files.map { UploadItem(url: $0, destDir: destDir) }
        self.items = mapped
        self.totalBytes = mapped.reduce(0) { $0 + $1.localSize }
    }

    /// Download remote files locally. `localURLs` corresponds one-to-one with `files` and is deduplicated by the caller.
    /// Avoid existing files and active downloads, adding a " (n)" suffix if necessary. `dir` is only for displaying the save location.
    init(download files: [RemoteFile], toLocalURLs localURLs: [URL], inDir dir: URL,
         fs: RemoteFS, onAllDone: @escaping () -> Void) {
        self.direction = .download
        self.destDir = dir.path
        self.fs = fs
        self.onAllDone = onAllDone
        let mapped = zip(files, localURLs).map { UploadItem(download: $0, toLocalURL: $1) }
        self.items = mapped
        self.totalBytes = mapped.reduce(0) { $0 + $1.localSize }
    }

    func start() {
        guard !started else { return }
        started = true
        phase = .running            // Dequeue and start; the initial phase is .queued.
        pendingBaselineReset = true
        Task { await sampleLoop() }
        Task { await run() }
    }

    private func run() async {
        if direction == .download { await runDownload() } else { await runFrom() }
    }

    func cancel() {
        if phase == .queued {           // Cancel a not-yet-started task immediately and let the coordinator start the next one.
            phase = .cancelled
            onFinished?()
            return
        }
        guard phase == .running || phase == .paused else { return }
        control.set(.cancel)
        // Wake a pending name-conflict prompt; otherwise runFrom stays suspended on await and cancellation cannot finish.
        if let cont = askCont { askCont = nil; pendingAsk = nil; cont.resume(returning: .cancel) }
        wakeFromPause()   // Wake a paused main loop so it sees .cancel and cleans up.
    }

    /// Pause the current transfer while preserving the remote .part/local partial file; suspend the main loop until resume.
    func pause() {
        guard phase == .running else { return }
        phase = .paused
        awaitingSlot = false
        control.set(.pause)
        onPauseStateChanged?()   // A slot may be freed, allowing the coordinator to admit a queued task.
    }

    /// User resume request, called by the coordinator. `slotFree` indicates whether capacity is available.
    /// Resume immediately if a slot is free; otherwise set awaitingSlot until the coordinator calls admitResume.
    func requestResume(slotFree: Bool) {
        guard phase == .paused else { return }
        if slotFree {
            actuallyResume()
        } else {
            awaitingSlot = true
            onPauseStateChanged?()   // Show the waiting state in the UI.
        }
    }

    /// Admit a resume request waiting for a slot, after confirming capacity is available.
    func admitResume() {
        guard phase == .paused, awaitingSlot else { return }
        actuallyResume()
    }

    /// Actually resume the current file at its saved offset and continue the main loop.
    private func actuallyResume() {
        awaitingSlot = false
        phase = .running
        control.set(.run)
        pendingBaselineReset = true
        Task { await sampleLoop() }   // Restart the sampling loop, which exited while paused.
        wakeFromPause()
    }

    /// The main loop suspends while paused; wakeFromPause resumes it for resume/cancel.
    /// Cancellation must also break the wait: phase is still .paused, so checking only phase would suspend again and make cancellation ineffective.
    private func waitIfPaused() async {
        while phase == .paused, control.signal != .cancel {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in resumeCont = c }
        }
    }
    private func wakeFromPause() {
        if let c = resumeCont { resumeCont = nil; c.resume() }
    }

    /// Retry/resume failed items after the main run finishes.
    func retryFailed(resume: Bool) {
        guard phase == .done else { return }
        for it in items {
            if case .failed = it.state {
                if !resume { it.interrupted = false }   // Retry starts at zero; resume preserves the partial file.
                it.state = .waiting
            }
        }
        index = 0
        phase = .running
        control.set(.run)
        pendingBaselineReset = true
        Task { await sampleLoop() }
        Task { await run() }
    }

    func resolveAsk(_ a: AskAction) {
        pendingAsk = nil
        let cont = askCont; askCont = nil
        switch a {
        case .overwrite:    cont?.resume(returning: .overwrite)
        case .skip:         cont?.resume(returning: .skip)
        case .overwriteAll: bulkPolicy = .overwriteAll; cont?.resume(returning: .overwrite)
        case .skipAll:      bulkPolicy = .skipAll;      cont?.resume(returning: .skip)
        case .cancel:       cont?.resume(returning: .cancel)
        }
    }

    // MARK: Main loop

    private func runFrom() async {
        while index < items.count {
            if control.signal == .cancel { break }
            let item = items[index]
            if item.state == .done || item.state == .skipped || item.state == .cancelled {
                index += 1; continue
            }
            await switchLock(to: lockKey(item))   // Acquire this file's destination write lock; do not reacquire it when resuming the same file.
            if control.signal == .cancel { break } // Cancellation may occur while waiting for the lock.
            item.state = .checking
            pendingBaselineReset = true
            let probe = await fs.probeUpload(remotePath: item.remotePath)
            // Resume interrupted data from this session, or a remote .part preserved by a previous cancellation/failure.
            // If an incomplete remote .part exists without the final file, continue from its previous offset.
            let resuming = item.interrupted
                || (probe.partSize > 0 && probe.partSize < item.localSize && !probe.finalExists)

            if !resuming, probe.finalExists {
                switch await resolveOverwrite(item: item, finalSize: probe.finalSize) {
                case .skip:      item.state = .skipped; index += 1; continue
                case .cancel:    control.set(.cancel)
                case .overwrite: break   // cat> truncates .part; finalize overwrites the final file.
                }
            }
            if control.signal == .cancel { break }

            // For uncompressed resume, use the actual remote .part size as the offset (review R1).
            var startOffset: Int64 = 0
            if resuming {
                startOffset = min(probe.partSize, item.localSize)
                if startOffset >= item.localSize, item.localSize > 0 {   // If .part is complete, finalize it immediately.
                    item.sent = item.localSize
                    item.state = (try? await fs.finalizeUpload(remotePath: item.remotePath).get()) != nil
                        ? .done : .failed(String(localized: "Write Failed"))
                    index += 1; continue
                }
            }

            item.state = .uploading
            control.set(.run)
            control.setSent(startOffset)

            let outcome = await fs.upload(localURL: item.url, toRemote: item.remotePath,
                                          startOffset: startOffset, control: control)

            switch outcome {
            case .completed:
                item.sent = item.localSize
                item.interrupted = false
                item.state = (try? await fs.finalizeUpload(remotePath: item.remotePath).get()) != nil
                    ? .done : .failed(String(localized: "Write Failed"))
                index += 1
            case .cancelled:
                control.set(.cancel)
            case .paused:
                item.interrupted = true             // Keep the remote .part and current index so resume continues from the saved offset.
            case .failed(let msg):
                item.interrupted = true             // Preserve the partial .part; probe the offset again when resuming.
                item.state = .failed(msg)
                index += 1                          // One file's failure does not interrupt the queue.
            }
            if control.signal == .cancel { break }
            await waitIfPaused()                     // Suspend while paused; on resume retry the current item, keeping its write lock.
        }
        finish()   // finish() releases write locks and returns the SFTP session in one place.
    }

    /// Download files sequentially by streaming remote data locally, with progress/cancellation; no name-conflict prompt or resume handling here.
    private func runDownload() async {
        while index < items.count {
            if control.signal == .cancel { break }
            let item = items[index]
            if item.state == .done { index += 1; continue }
            await switchLock(to: lockKey(item))   // Lock identical local destinations to prevent concurrent writes to the same file.
            if control.signal == .cancel { break }
            item.state = .uploading        // Reuse the transferring phase.
            control.set(.run)
            // After pause, resume from the existing local file size and read the remote source at that offset.
            let startOffset: Int64 = item.interrupted ? UploadItem.fileSize(item.url) : 0
            control.setSent(startOffset)
            pendingBaselineReset = true
            let outcome = await fs.download(item.remotePath, to: item.url, startOffset: startOffset, control: control)
            switch outcome {
            case .completed:
                item.sent = item.localSize
                item.interrupted = false
                item.state = .done
                index += 1
            case .cancelled:
                control.set(.cancel)
            case .paused:
                item.interrupted = true             // Preserve the local partial file and current index for resume.
            case .failed(let msg):
                try? FileManager.default.removeItem(at: item.url)   // Delete the incomplete local download.
                item.interrupted = false
                item.state = .failed(msg)
                index += 1
            }
            if control.signal == .cancel { break }
            await waitIfPaused()
        }
        finish()   // finish() releases write locks and returns the SFTP session in one place.
    }

    private func resolveOverwrite(item: UploadItem, finalSize: Int64) async -> OverwriteDecision {
        if control.signal == .cancel { return .cancel }
        switch bulkPolicy {
        case .overwriteAll: return .overwrite
        case .skipAll:      return .skip
        case .ask:          break
        }
        item.state = .asking
        let ctx = AskContext(name: item.name, remoteSize: finalSize, localSize: item.localSize)
        return await withCheckedContinuation { cont in
            askCont = cont
            pendingAsk = ctx
        }
    }

    private func finish() {
        let landedAny = items.contains { $0.state == .done }
        if control.signal == .cancel {
            for it in items {
                switch it.state {
                case .done, .skipped, .failed: break
                default:
                    it.state = .cancelled
                    if direction == .download { try? FileManager.default.removeItem(at: it.url) }   // Delete the local partial file.
                }
            }
            phase = .cancelled
        } else {
            phase = .done
            postCompletionNotification()
        }
        if landedAny { onAllDone() }
        releaseHeldLock()       // Release the current per-file write lock.
        fs.closeSession()       // Release the SFTP subprocess, reader thread, and buffers immediately on completion; retained history rows must not retain their memory.
        onFinished?()           // Terminal phase: advance the transfer queue.
    }

    private func postCompletionNotification() {
        let verb = String(localized: direction == .upload ? "Upload" : "Download")
        let done = items.filter { $0.state == .done }.count
        if hasFailures {
            Notifier.notify(title: String(localized: "\(verb) partially failed"), body: String(localized: "\(done) of \(items.count) files succeeded"))
        } else {
            Notifier.notify(title: String(localized: "\(verb) complete"), body: String(localized: "\(done) files · \(humanSize(totalBytes))"))
        }
    }

    // MARK: Speed sampling (0.1s + EMA smoothing; map compressed bytes sent back to original-byte space).

    private func sampleLoop() async {
        let dt = 0.1
        while phase == .running {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if index < items.count, items[index].state == .uploading {
                let it = items[index]
                it.sent = max(it.sent, min(it.localSize, control.sent))
            }
            let overall = items.reduce(0) { $0 + $1.sent }
            overallSent = overall
            if pendingBaselineReset {
                lastSampledOverall = overall
                pendingBaselineReset = false
            } else {
                let instant = max(0, Double(overall - lastSampledOverall) / dt)
                lastSampledOverall = overall
                speed = speed * 0.7 + instant * 0.3   // EMA smoothing.
            }
        }
    }

    // MARK: Derived values

    /// Exclude skipped/canceled items from the denominator (review R14).
    var effectiveTotal: Int64 {
        items.reduce(0) { (it: Int64, x) in
            (x.state == .skipped || x.state == .cancelled) ? it : it + x.localSize
        }
    }
    var eta: Double {
        guard speed > 1, phase == .running else { return 0 }
        return Double(effectiveTotal - overallSent) / speed
    }
    var hasFailures: Bool { items.contains { if case .failed = $0.state { return true }; return false } }

    /// Whether a remote partial .part remains after cancellation/failure; uploads only. It can be kept for resume or deleted.
    var hasPartials: Bool { direction == .upload && items.contains { partialRemotePath($0) != nil } }

    /// Best-effort deletion of all remaining .part files when requested on cancel. A later probe handles deletion failures.
    func cleanupPartials() {
        let paths = items.compactMap(partialRemotePath)
        guard !paths.isEmpty else { return }
        let fs = self.fs
        Task { for p in paths { await fs.cleanupPart(remotePath: p) }; fs.closeSession() }   // Close immediately after deletion; do not retain the session.
    }

    private func partialRemotePath(_ it: UploadItem) -> String? {
        guard it.sent > 0, it.sent < it.localSize else { return nil }
        switch it.state { case .cancelled, .failed: return it.remotePath; default: return nil }
    }
}

// MARK: - Upload dialog

struct UploadDialog: View {
    @ObservedObject var task: UploadTask
    let onHide: () -> Void
    let onClose: () -> Void
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        ZStack {
            Color.black.opacity(theme.isDark ? 0.42 : 0.20).ignoresSafeArea()
            card
        }
        .preferredColorScheme(theme.isDark ? .dark : .light)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            fileList
            infoRow
            if let ask = task.pendingAsk { askPanel(ask) }
            if task.phase == .cancelled, task.hasPartials {
                Text("Canceled. A partial file remains on the remote. Keep it to resume later, or delete the leftover to remove it.")
                    .font(.system(size: 11)).foregroundStyle(Pal.subtext)
                    .fixedSize(horizontal: false, vertical: true)
            }
            buttons
        }
        .padding(18)
        .frame(width: 480)
        .background(Pal.solidMantle, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Pal.fill(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(theme.isDark ? 0.40 : 0.14), radius: 24, y: 8)
    }

    private var header: some View {
        let isUp = task.direction == .upload
        return HStack(spacing: 10) {
            Image(lucideSymbol: isUp ? "square.and.arrow.up" : "square.and.arrow.down")
                .font(.system(size: 15, weight: .medium)).foregroundStyle(Pal.tint)
                .frame(width: 30, height: 30)
                .background(Pal.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(isUp ? "Upload File" : "Download File").font(.system(size: 14, weight: .semibold)).foregroundStyle(Pal.text)
                Text("to \(task.destDir)")
                    .font(.system(size: 11)).foregroundStyle(Pal.overlay)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            statusBadge
            Button(action: onHide) {
                Image(lucideSymbol: "chevron.down")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Pal.overlay)
                    .frame(width: 24, height: 24)
                    .background(Pal.fill(0.06), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help(String(localized: "Run in background (progress stays in the lower-left)"))
        }
    }

    @ViewBuilder private var statusBadge: some View {
        let (label, fg): (String, Color) = {
            switch task.phase {
            case .queued:    return (String(localized: "Queued"), Pal.overlay)
            case .running:   return ("\(min(task.index + 1, task.items.count))/\(task.items.count)", Pal.tint)
            case .paused:    return (String(localized: "Paused"), Pal.yellow)
            case .done:      return task.hasFailures ? (String(localized: "Partially Failed"), Pal.yellow) : (String(localized: "Done"), Pal.green)
            case .cancelled: return (String(localized: "Canceled"), Pal.overlay)
            }
        }()
        Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(fg)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(fg.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
    }

    private var fileList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(task.items) { item in UploadRow(item: item, direction: task.direction) }
            }
        }
        .frame(maxHeight: 176)
        .background(Pal.fill(0.03), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Pal.fill(0.06), lineWidth: 1))
    }

    // Show rate, transferred/total, and remaining time on one line. Each file already has a progress bar, so omit an overall bottom bar.
    private var infoRow: some View {
        HStack(spacing: 12) {
            Label(fmtSpeed(task.speed), lucideSymbol: "speedometer")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(Pal.tint)
            Text("\(humanSize(task.overallSent)) / \(humanSize(task.totalBytes))")
                .font(.system(size: 11)).foregroundStyle(Pal.overlay)
            Spacer()
            if task.phase == .running {
                Text("\(fmtETA(task.eta)) remaining").font(.system(size: 11)).foregroundStyle(Pal.overlay)
            }
        }
    }

    @ViewBuilder private func askPanel(_ ask: AskContext) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\"\(ask.name)\" already exists on the remote")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.text)
            Text("Remote \(humanSize(ask.remoteSize)) · Local \(humanSize(ask.localSize))")
                .font(.system(size: 11)).foregroundStyle(Pal.subtext)
            HStack(spacing: 8) {
                pill(String(localized: "Overwrite"), fg: Pal.tint, base: Pal.tint.opacity(0.14)) { task.resolveAsk(.overwrite) }
                pill(String(localized: "Skip"), fg: Pal.subtext, base: Pal.fill(0.07)) { task.resolveAsk(.skip) }
                Spacer()
                pill(String(localized: "Overwrite All"), fg: Pal.overlay, base: Pal.fill(0.07)) { task.resolveAsk(.overwriteAll) }
                pill(String(localized: "Skip All"), fg: Pal.overlay, base: Pal.fill(0.07)) { task.resolveAsk(.skipAll) }
            }
        }
        .padding(10)
        .background(Pal.yellow.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Pal.yellow.opacity(0.20), lineWidth: 1))
    }

    private var buttons: some View {
        HStack {
            Spacer()
            switch task.phase {
            case .queued:
                pill(String(localized: "Cancel"), fg: Pal.subtext, base: Pal.fill(0.07)) { task.cancel() }
            case .running:
                pill(String(localized: "Pause"), fg: Pal.tint, base: Pal.tint.opacity(0.14)) { AppModel.shared.pauseTransfer(task) }
                pill(String(localized: "Cancel"), fg: Pal.subtext, base: Pal.fill(0.07)) { task.cancel() }
            case .paused:
                pill(task.awaitingSlot ? String(localized: "Waiting for a slot…") : String(localized: "Continue"), fg: Pal.tint, base: Pal.tint.opacity(0.14)) {
                    AppModel.shared.resumeTransfer(task)
                }
                pill(String(localized: "Cancel"), fg: Pal.subtext, base: Pal.fill(0.07)) { task.cancel() }
            case .done where task.hasFailures:
                if task.direction == .upload {   // Resume is supported only for uploads through remote .part files.
                    pill(String(localized: "Resume Failed Items"), fg: Pal.tint, base: Pal.tint.opacity(0.14)) { task.retryFailed(resume: true) }
                }
                pill(String(localized: "Retry"), fg: Pal.subtext, base: Pal.fill(0.07)) { task.retryFailed(resume: false) }
                pill(String(localized: "Close"), fg: Pal.overlay, base: Pal.fill(0.07), action: onClose)
            case .cancelled where task.hasPartials:
                pill(String(localized: "Keep Partial File (Resume Later)"), fg: Pal.tint, base: Pal.tint.opacity(0.14), action: onClose)
                pill(String(localized: "Remove Leftovers"), fg: Pal.subtext, base: Pal.fill(0.07)) { task.cleanupPartials(); onClose() }
            case .done, .cancelled:
                pill(task.phase == .done ? String(localized: "Done") : String(localized: "Close"),
                     fg: Pal.tint, base: Pal.tint.opacity(0.14), action: onClose)
            }
        }
    }

    private func pill(_ title: String, fg: Color, base: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(fg)
                .padding(.horizontal, 14).padding(.vertical, 6.5)
                .background(base, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private func fmtSpeed(_ bps: Double) -> String { bps < 1 ? "—" : humanSize(Int64(bps)) + "/s" }
    private func fmtETA(_ sec: Double) -> String {
        guard sec.isFinite, sec > 0 else { return "—" }
        let s = Int(sec.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// File-list row, subscribing to its item individually.
struct UploadRow: View {
    @ObservedObject var item: UploadItem
    var direction: TransferDirection = .upload

    var body: some View {
        HStack(spacing: 8) {
            Image(lucideSymbol: icon).font(.system(size: 11)).foregroundStyle(color).frame(width: 14)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(item.name).font(.system(size: 11.5)).foregroundStyle(Pal.subtext)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(label).font(.system(size: 10)).foregroundStyle(color)
                }
                if showBar {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Pal.fill(0.06))
                            Capsule().fill(color).frame(width: max(0, g.size.width * item.fraction))
                                .animation(.linear(duration: 0.1), value: item.fraction)
                        }
                    }
                    .frame(height: 4)
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
    }

    private var showBar: Bool {
        switch item.state { case .uploading, .done: return true; default: return false }
    }
    private var icon: String {
        switch item.state {
        case .waiting:   return "clock"
        case .checking:  return "magnifyingglass"
        case .asking:    return "questionmark.circle"
        case .uploading: return direction == .upload ? "arrow.up.circle" : "arrow.down.circle"
        case .done:      return "checkmark.circle.fill"
        case .skipped:   return "forward.circle"
        case .failed:    return "xmark.circle.fill"
        case .cancelled: return "slash.circle"
        }
    }
    private var color: Color {
        switch item.state {
        case .uploading: return Pal.tint
        case .asking:    return Pal.yellow
        case .done:      return Pal.green
        case .failed:    return Pal.red
        default:         return Pal.overlay
        }
    }
    private var label: String {
        switch item.state {
        case .waiting:   return String(localized: "Pending")
        case .checking:  return String(localized: "Detecting…")
        case .asking:    return String(localized: "Awaiting Decision")
        case .uploading: return "\(Int(item.fraction * 100))%"
        case .done:      return String(localized: "Done")
        case .skipped:   return String(localized: "Skipped")
        case .failed(let m): return m.isEmpty ? String(localized: "Failed") : m
        case .cancelled: return String(localized: "Canceled")
        }
    }
}

// Background transfer progress is integrated into the bottom-left Background Tasks center (see BackgroundCenterView).

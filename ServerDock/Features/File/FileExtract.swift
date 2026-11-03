import SwiftUI

// MARK: - Archive formats

/// Multi-file archives default to a same-name folder; single-file compression extracts into cwd.
enum ArchiveKind: Equatable {
    case tarGz, tarBz2, tarXz, tarZst, tar, zip, sevenZip, rar   // Multi-file archive.
    case gz, bz2, xz, zst                                        // Single-file compression.

    /// Check compound extensions such as .tar.gz before .gz; nil hides Extract for unsupported files.
    static func detect(_ name: String) -> ArchiveKind? {
        let n = name.lowercased()
        func ends(_ s: String) -> Bool { n.hasSuffix(s) }
        if ends(".tar.gz")  || ends(".tgz")  { return .tarGz }
        if ends(".tar.bz2") || ends(".tbz2") || ends(".tbz") { return .tarBz2 }
        if ends(".tar.xz")  || ends(".txz")  { return .tarXz }
        if ends(".tar.zst") || ends(".tzst") { return .tarZst }
        if ends(".tar")  { return .tar }
        if ends(".zip")  { return .zip }
        if ends(".7z")   { return .sevenZip }
        if ends(".rar")  { return .rar }
        if ends(".gz")   { return .gz }
        if ends(".bz2")  { return .bz2 }
        if ends(".xz")   { return .xz }
        if ends(".zst")  { return .zst }
        return nil
    }

    /// Whether multiple-file content should default to a new folder.
    var isMultiFile: Bool {
        switch self {
        case .gz, .bz2, .xz, .zst: return false
        default: return true
        }
    }

    /// Required remote extraction command; show a clear notice if missing.
    var tool: String {
        switch self {
        case .tarGz, .tarBz2, .tarXz, .tarZst, .tar: return "tar"
        case .zip: return "unzip"
        case .sevenZip: return "7z"
        case .rar: return "unrar"
        case .gz: return "gzip"
        case .bz2: return "bzip2"
        case .xz: return "xz"
        case .zst: return "zstd"
        }
    }

    /// Strip archive suffix to derive destination folder/single-file name.
    func baseName(_ name: String) -> String {
        let suffixes = [".tar.gz", ".tgz", ".tar.bz2", ".tbz2", ".tbz", ".tar.xz", ".txz",
                        ".tar.zst", ".tzst", ".tar", ".zip", ".7z", ".rar", ".gz", ".bz2", ".xz", ".zst"]
        let lower = name.lowercased()
        for s in suffixes where lower.hasSuffix(s) { return String(name.dropLast(s.count)) }
        return name
    }
}

// MARK: - Extraction task

enum ExtractPhase: Equatable { case ready, running, done, failed(String) }

/// Run tar/unzip over multiplexed SSH, then refresh affected entries and notify.
/// Use spinner/completed/failed states because byte progress is unavailable; support background execution.
@MainActor
final class ExtractTask: ObservableObject {
    nonisolated let id = UUID()
    let archive: RemoteFile
    let kind: ArchiveKind
    let parentDir: String          // Archive parent directory; extract into this directory.
    let folderName: String         // New folder with the same name, or the extracted single-file name.
    // Owning host for background grouping, assigned at creation for display only.
    var hostId: String? = nil
    var hostName: String = ""

    @Published var phase: ExtractPhase = .ready
    @Published var toSubfolder: Bool   // Extract into a new same-name folder; otherwise use the current directory.

    private let fs: RemoteFS
    private let onDone: () -> Void

    init(archive: RemoteFile, kind: ArchiveKind, parentDir: String,
         fs: RemoteFS, onDone: @escaping () -> Void) {
        self.archive = archive
        self.kind = kind
        self.parentDir = parentDir
        self.folderName = kind.baseName(archive.name)
        self.fs = fs
        self.onDone = onDone
        self.toSubfolder = kind.isMultiFile
    }

    /// Actual extraction destination directory.
    var destDir: String {
        toSubfolder ? childPath(parentDir, folderName) : parentDir
    }

    func begin() {
        guard phase == .ready else { return }
        phase = .running
        let cmd = remoteCommand()
        let fs = self.fs
        Task { @MainActor in
            let r = await fs.run(cmd, timeout: 1800)
            if r.code == 0 {
                phase = .done
                Notifier.notify(title: String(localized: "Extraction complete"), body: "\(archive.name) → \(destDir)")
                onDone()
            } else {
                let err = String(data: r.stderr, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                phase = .failed(err.isEmpty ? String(localized: "Extraction failed (exit code \(r.code))") : err)
                Notifier.notify(title: String(localized: "Extraction Failed"), body: archive.name)
            }
        }
    }

    func retry() {
        guard case .failed = phase else { return }
        phase = .ready
        begin()
    }

    private func childPath(_ dir: String, _ name: String) -> String {
        (dir == "/" ? "" : dir) + "/" + name
    }

    /// Decode paths from base64 and double-quote them to preserve spaces/special characters and prevent injection.
    /// Check required commands, mkdir -p the destination, then extract according to type.
    private func remoteCommand() -> String {
        let aB64 = Data(archive.path.utf8).base64EncodedString()
        let dB64 = Data(destDir.utf8).base64EncodedString()
        let head = "A=$(printf %s '\(aB64)'|base64 -d); D=$(printf %s '\(dB64)'|base64 -d); "
        let check = "command -v \(kind.tool) >/dev/null 2>&1 || { echo 'Remote host is missing the \(kind.tool) command' >&2; exit 127; }; "
        let mk = "mkdir -p -- \"$D\" && "

        switch kind {
        case .tarGz:    return head + check + mk + "tar -xzf \"$A\" -C \"$D\""
        case .tarBz2:   return head + check + mk + "tar -xjf \"$A\" -C \"$D\""
        case .tarXz:    return head + check + mk + "tar -xJf \"$A\" -C \"$D\""
        case .tarZst:   return head + check + mk + "tar --use-compress-program=unzstd -xf \"$A\" -C \"$D\""
        case .tar:      return head + check + mk + "tar -xf \"$A\" -C \"$D\""
        case .zip:      return head + check + mk + "unzip -o \"$A\" -d \"$D\""
        case .sevenZip: return head + check + mk + "7z x -y -o\"$D\" \"$A\""
        case .rar:      return head + check + mk + "unrar x -o+ \"$A\" \"$D/\""
        case .gz, .bz2, .xz, .zst:
            let sB64 = Data(folderName.utf8).base64EncodedString()
            let s = "S=$(printf %s '\(sB64)'|base64 -d); "
            let dec: String
            switch kind {
            case .gz:  dec = "gzip -dc -- \"$A\""
            case .bz2: dec = "bzip2 -dc -- \"$A\""
            case .xz:  dec = "xz -dc -- \"$A\""
            default:   dec = "zstd -dc -- \"$A\""
            }
            return head + s + check + mk + "\(dec) > \"$D/$S\""
        }
    }
}

// MARK: - Extraction dialog

/// Choose same-name/current destination, then show running/completed/failed, matching upload styling and supporting background work.
struct ExtractDialog: View {
    @ObservedObject var task: ExtractTask
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
            archiveRow
            stageView(task.phase)
            buttons
        }
        .padding(18)
        .frame(width: 420)
        .background(Pal.solidMantle, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Pal.fill(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(theme.isDark ? 0.40 : 0.14), radius: 24, y: 8)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(lucideSymbol: "doc.zipper")
                .font(.system(size: 15, weight: .medium)).foregroundStyle(Pal.tint)
                .frame(width: 30, height: 30)
                .background(Pal.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text("Extract").font(.system(size: 14, weight: .semibold)).foregroundStyle(Pal.text)
                Text("at \(task.parentDir)")
                    .font(.system(size: 11)).foregroundStyle(Pal.overlay)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            statusBadge
            if task.phase == .running {
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
    }

    @ViewBuilder private var statusBadge: some View {
        let (label, fg): (String, Color) = {
            switch task.phase {
            case .ready:     return (String(localized: "Pending Extraction"), Pal.overlay)
            case .running:   return (String(localized: "Extracting"), Pal.tint)
            case .done:      return (String(localized: "Done"), Pal.green)
            case .failed:    return (String(localized: "Failed"), Pal.red)
            }
        }()
        Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(fg)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(fg.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
    }

    private var archiveRow: some View {
        HStack(spacing: 8) {
            Image(lucideSymbol: "doc.zipper").font(.system(size: 11)).foregroundStyle(Pal.subtext).frame(width: 14)
            Text(task.archive.name)
                .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Pal.subtext)
                .lineLimit(1).truncationMode(.middle)
            Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Pal.fill(0.03), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Pal.fill(0.06), lineWidth: 1))
    }

    @ViewBuilder private func stageView(_ phase: ExtractPhase) -> some View {
        switch phase {
        case .ready:          destinationPicker
        case .running:        statusLine(icon: nil, String(localized: "Extracting…"), color: Pal.tint)
        case .done:           statusLine(icon: "checkmark.circle.fill", String(localized: "Extracted to \(task.destDir)"), color: Pal.green)
        case .failed(let m):  failed(m)
        }
    }

    private var destinationPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Extract To").font(.system(size: 11)).foregroundStyle(Pal.overlay)
            HStack(spacing: 8) {
                destOption(String(localized: "New Folder \"\(task.folderName)\""), selected: task.toSubfolder) { task.toSubfolder = true }
                destOption(String(localized: "Current Directory"), selected: !task.toSubfolder) { task.toSubfolder = false }
                Spacer(minLength: 0)
            }
            Text(task.destDir)
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(Pal.subtext)
                .lineLimit(1).truncationMode(.middle)
        }
    }

    private func destOption(_ title: String, selected: Bool, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(selected ? Pal.tint : Pal.subtext)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(selected ? Pal.tint.opacity(0.14) : Pal.fill(0.06), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .stroke(selected ? Pal.tint.opacity(0.4) : Color.clear, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private func statusLine(icon: String?, _ text: String, color: Color) -> some View {
        HStack(spacing: 8) {
            if let icon {
                Image(lucideSymbol: icon).font(.system(size: 12)).foregroundStyle(color)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(text).font(.system(size: 12)).foregroundStyle(Pal.subtext)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }

    private func failed(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(lucideSymbol: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(Pal.red)
                Text("Extraction Failed").font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.text)
                Spacer(minLength: 0)
            }
            Text(message)
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(Pal.subtext)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
        .padding(10)
        .background(Pal.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Pal.red.opacity(0.18), lineWidth: 1))
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            Spacer()
            switch task.phase {
            case .ready:
                SecondaryButton(title: "Cancel", action: onClose)
                PrimaryButton(title: "Extract") { task.begin() }
            case .running:
                SecondaryButton(title: "Run in Background", action: onHide)
            case .done:
                PrimaryButton(title: "Done", action: onClose)
            case .failed:
                SecondaryButton(title: "Close", action: onClose)
                PrimaryButton(title: "Retry") { task.retry() }
            }
        }
    }
}

// Extraction background status is integrated into bottom-left Background Tasks; see BackgroundCenterView.

import AppKit
import SwiftUI

/// One tail -F text-following session per tab.
/// SSH uses a dedicated exec stream; local hosts run the same script with /bin/sh.
/// Check text type first; binaries show a notice without starting the stream.
@MainActor
final class TailSession: ObservableObject {
    enum Phase: Equatable {
        case connecting, running, ended(String?), binary, failed(String)
    }

    let host: Host
    let path: String
    @Published private(set) var phase: Phase = .connecting
    @Published private(set) var lineCount = 0
    @Published var paused = false
    @Published var autoScroll = true
    @Published var wrap = true
    @Published var filter = ""

    /// Bound retained lines, dropping oldest to protect memory.
    static let maxLines = 5000
    /// Initial number of trailing lines.
    static let initialLines = 200

    /// lines[i] absolute index is dropped+i; views track rendered absolute positions.
    private(set) var lines: [String] = []
    private(set) var dropped = 0
    /// Notify new-line arrival; the view reads during rendering.
    @Published private(set) var revision = 0

    private var partial = ""
    private var session: SSHSession?
    private var process: Process?
    private var gen = 0

    /// Optional arbitrary stream such as docker logs -f bypasses file checks.
    private let customScript: String?

    init(host: Host, path: String, script: String? = nil) {
        self.host = host
        self.path = path
        self.customScript = script
    }

    // MARK: Start / stop

    /// Run tail -F only for text; NUL in the first 4KB exits with code 3.
    private var script: String {
        if let customScript { return customScript }
        let f = AppModel.shellQuote(path)
        return "f=\(f); "
            + "if [ ! -r \"$f\" ]; then echo \"cannot read: $f\"; exit 2; fi; "
            + "a=$(head -c 4096 \"$f\" | wc -c); b=$(head -c 4096 \"$f\" | tr -d '\\000' | wc -c); "
            + "if [ \"$a\" != \"$b\" ]; then exit 3; fi; "
            + "exec tail -n \(Self.initialLines) -F \"$f\" 2>&1"
    }

    func start() {
        stop()
        lines.removeAll(); dropped = 0; partial = ""; lineCount = 0; revision &+= 1
        phase = .connecting
        gen &+= 1
        let gen = gen
        if host.ssh?.isLocal == true || host.isLocal { startLocal(gen: gen) } else { startRemote(gen: gen) }
    }

    func stop() {
        gen &+= 1
        session?.cancel()
        session = nil
        if let p = process, p.isRunning { p.terminate() }
        process = nil
    }

    private func startLocal(gen: Int) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in guard gen == self?.gen else { return }; self?.ingest(data) }
        }
        p.terminationHandler = { [weak self] proc in
            let code = Int(proc.terminationStatus)
            out.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in self?.finished(gen: gen, code: code, error: nil) }
        }
        do {
            try p.run()
            process = p
            phase = .running
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func startRemote(gen: Int) {
        guard let conn = host.ssh else { phase = .failed(String(localized: "No SSH connection")); return }
        let cmd = script
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let a = conn.libssh2Auth
            let s: SSHSession
            do {
                s = try SSHSession.connect(host: conn.host, port: conn.port, user: conn.user,
                                           password: a.password, keyPath: a.keyPath, keyPassphrase: a.keyPassphrase,
                                           jump: conn.jumpHost)
            } catch {
                let msg = (error as? SSHSession.SSHError)?.message ?? error.localizedDescription
                Task { @MainActor in
                    if gen == self?.gen { self?.phase = .failed(String(localized: "Connection failed: \(msg)")) }
                }
                return
            }
            Task { @MainActor in
                guard let self, gen == self.gen else { s.cancel(); return }
                self.session = s
                self.phase = .running
            }
            let r = s.execStream(cmd) { data in
                Task { @MainActor in guard gen == self?.gen else { return }; self?.ingest(data) }
            }
            s.close()
            Task { @MainActor in self?.finished(gen: gen, code: r.exitCode, error: r.error) }
        }
    }

    private func finished(gen: Int, code: Int, error: String?) {
        guard gen == self.gen else { return }
        session = nil; process = nil
        if code == 3 { phase = .binary; return }
        flushPartial()
        phase = .ended(error ?? (code > 0 ? "exit \(code)" : nil))
    }

    // MARK: Receiving

    private static let ansi = try! NSRegularExpression(pattern: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]|\u{1B}\\][^\u{07}]*\u{07}")

    private func ingest(_ data: Data) {
        var text = partial + String(decoding: data, as: UTF8.self)
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        let range = NSRange(text.startIndex..., in: text)
        text = Self.ansi.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        var parts = text.components(separatedBy: "\n")
        partial = parts.removeLast()   // Combine incomplete lines with the next chunk.
        guard !parts.isEmpty else { return }
        append(parts)
    }

    private func flushPartial() {
        guard !partial.isEmpty else { return }
        let rest = partial
        partial = ""
        append([rest])
    }

    private func append(_ new: [String]) {
        lines.append(contentsOf: new)
        if lines.count > Self.maxLines {
            let over = lines.count - Self.maxLines
            lines.removeFirst(over)
            dropped += over
        }
        lineCount = lines.count
        revision &+= 1
    }

    func clear() {
        dropped += lines.count
        lines.removeAll()
        lineCount = 0
        revision &+= 1
    }

    /// Full displayed text for copying.
    var allText: String { lines.joined(separator: "\n") }
}

// MARK: - View

struct TailView: View {
    @ObservedObject var session: TailSession
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(Pal.fill(0.08)).frame(height: 1)
            ZStack {
                TailTextView(session: session)
                overlayMessage
            }
        }
        .background(Pal.base)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(lucideSymbol: "text.append").font(.system(size: 12)).foregroundStyle(session.host.accent)
            Text(session.path).font(.system(size: 12, design: .monospaced)).foregroundStyle(Pal.text)
                .lineLimit(1).truncationMode(.head).layoutPriority(-1)
            statusPill
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Image(lucideSymbol: "line.3.horizontal.decrease").font(.system(size: 10)).foregroundStyle(Pal.overlay)
                TextField(String(localized: "Filter"), text: $session.filter)
                    .textFieldStyle(.plain).font(.system(size: 12))
                    .frame(minWidth: 60, idealWidth: 130, maxWidth: 130)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Pal.fill(0.06), in: RoundedRectangle(cornerRadius: 7))
            Text("\(session.lineCount) lines").font(.system(size: 11)).foregroundStyle(Pal.overlay).lineLimit(1).fixedSize()
            toolButton(session.paused ? "play.fill" : "pause.fill",
                       help: session.paused ? String(localized: "Resume") : String(localized: "Pause"),
                       on: session.paused) { session.paused.toggle() }
            toolButton("arrow.down.to.line", help: String(localized: "Auto-scroll"), on: session.autoScroll) {
                session.autoScroll.toggle()
            }
            toolButton("text.word.spacing", help: String(localized: "Word Wrap"), on: session.wrap) { session.wrap.toggle() }
            toolButton("doc.on.doc", help: String(localized: "Copy All")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.allText, forType: .string)
            }
            toolButton("trash", help: String(localized: "Clear")) { session.clear() }
            switch session.phase {
            case .ended, .failed:
                toolButton("arrow.clockwise", help: String(localized: "Restart")) { session.start() }
            default:
                EmptyView()
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private var statusPill: some View {
        let (label, color): (String, Color) = {
            switch session.phase {
            case .connecting: return (String(localized: "Connecting…"), Pal.yellow)
            case .running: return (session.paused ? String(localized: "Paused") : String(localized: "Following"),
                                   session.paused ? Pal.yellow : session.host.accent)
            case .ended: return (String(localized: "Stopped"), Pal.overlay)
            case .binary: return (String(localized: "Not a text file"), Pal.red)
            case .failed: return (String(localized: "Failed"), Pal.red)
            }
        }()
        return HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(.system(size: 11)).foregroundStyle(Pal.subtext).lineLimit(1)
        }
        .fixedSize()   // Prevent toolbar text wrapping vertically and increasing its height.
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Pal.fill(0.05), in: Capsule())
    }

    private func toolButton(_ symbol: String, help: String, on: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(lucideSymbol: symbol).font(.system(size: 11))
                .foregroundStyle(on ? session.host.accent : Pal.subtext)
                .frame(width: 26, height: 24)
                .background(on ? session.host.accent.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor()
        .help(help)
    }

    @ViewBuilder
    private var overlayMessage: some View {
        switch session.phase {
        case .binary:
            message("doc.zipper", String(localized: "Tail only supports text files."),
                    String(localized: "This file looks binary, so it can't be followed."))
        case .failed(let msg):
            message("exclamationmark.triangle", String(localized: "Couldn't start tail"), msg)
        case .ended(let reason) where session.lineCount == 0:
            message("stop.circle", String(localized: "Tail stopped"), reason ?? "")
        default:
            EmptyView()
        }
    }

    private func message(_ symbol: String, _ title: String, _ detail: String) -> some View {
        VStack(spacing: 8) {
            Image(lucideSymbol: symbol).font(.system(size: 26)).foregroundStyle(Pal.overlay)
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Pal.subtext)
            if !detail.isEmpty {
                Text(detail).font(.system(size: 11)).foregroundStyle(Pal.overlay)
                    .multilineTextAlignment(.center).textSelection(.enabled)
            }
        }
        .padding(24)
    }
}

/// NSTextView appends only new lines and follows if already at the bottom, without resetting all text.
private struct TailTextView: NSViewRepresentable {
    @ObservedObject var session: TailSession
    @ObservedObject private var theme = ThemeManager.shared

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 12, height: 10)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        context.coordinator.textView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = context.coordinator.textView else { return }
        _ = session.revision   // Retain dependency for new-line updates.
        context.coordinator.apply(session: session, to: tv, scroll: scroll, isDark: theme.isDark)
    }

    @MainActor
    final class Coordinator {
        weak var textView: NSTextView?
        private var applied = 0          // Absolute line rendered through this point.
        private var lastFilter = ""
        private var lastWrap = true
        private var lastDark: Bool?
        private var started = false

        private let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        func apply(session: TailSession, to tv: NSTextView, scroll: NSScrollView, isDark: Bool) {
            let filter = session.filter.trimmingCharacters(in: .whitespaces)
            let full = !started || filter != lastFilter || isDark != lastDark || applied < session.dropped
            if session.wrap != lastWrap {
                lastWrap = session.wrap
                setWrap(session.wrap, tv: tv, scroll: scroll)
            }
            if session.paused && !full { return }   // Paused rendering keeps buffering without changing the screen.
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor(Pal.text),
            ]
            if full {
                started = true
                lastFilter = filter
                lastDark = isDark
                let all = session.lines.filter { filter.isEmpty || $0.localizedCaseInsensitiveContains(filter) }
                tv.textStorage?.setAttributedString(
                    NSAttributedString(string: all.isEmpty ? "" : all.joined(separator: "\n") + "\n", attributes: attrs))
                applied = session.dropped + session.lines.count
            } else {
                let from = applied - session.dropped
                guard from < session.lines.count else { return }
                let new = session.lines[from...].filter { filter.isEmpty || $0.localizedCaseInsensitiveContains(filter) }
                applied = session.dropped + session.lines.count
                guard !new.isEmpty else { return }
                tv.textStorage?.append(NSAttributedString(string: new.joined(separator: "\n") + "\n", attributes: attrs))
                trimIfNeeded(tv)
            }
            if session.autoScroll { tv.scrollToEndOfDocument(nil) }
        }

        /// Trim oldest displayed text when oversized, bounding it even when filtering changes line counts.
        private func trimIfNeeded(_ tv: NSTextView) {
            guard let storage = tv.textStorage else { return }
            let limit = TailSession.maxLines * 240
            guard storage.length > limit else { return }
            let cut = storage.length - limit
            let ns = storage.string as NSString
            let nl = ns.range(of: "\n", range: NSRange(location: cut, length: ns.length - cut))
            storage.deleteCharacters(in: NSRange(location: 0, length: nl.location == NSNotFound ? cut : nl.location + 1))
        }

        private func setWrap(_ wrap: Bool, tv: NSTextView, scroll: NSScrollView) {
            scroll.hasHorizontalScroller = !wrap
            tv.isHorizontallyResizable = !wrap
            tv.textContainer?.widthTracksTextView = wrap
            tv.textContainer?.containerSize = NSSize(width: wrap ? scroll.contentSize.width : CGFloat.greatestFiniteMagnitude,
                                                     height: CGFloat.greatestFiniteMagnitude)
            tv.sizeToFit()
        }
    }
}

/// Hide Tail for obvious binary extensions such as images/archives/executables.
/// Execution confirms through NUL detection in the remote file's first 4KB.
enum TailSupport {
    private static let binaryExts: Set<String> = [
        "png", "jpg", "jpeg", "gif", "bmp", "webp", "ico", "tiff", "tif", "heic", "heif", "svgz",
        "zip", "gz", "tgz", "bz2", "xz", "zst", "7z", "rar", "tar", "jar", "war", "iso", "dmg", "img",
        "pdf", "exe", "dll", "so", "dylib", "o", "a", "bin", "class", "pyc", "wasm",
        "mp3", "mp4", "mov", "avi", "mkv", "flac", "wav", "ogg", "webm",
        "db", "sqlite", "sqlite3", "woff", "woff2", "ttf", "otf",
    ]

    static func isLikelyText(_ name: String) -> Bool {
        let ext = (name.lowercased() as NSString).pathExtension
        return !binaryExts.contains(ext)
    }
}

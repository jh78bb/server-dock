import SwiftTerm
import SwiftUI
import UniformTypeIdentifiers

/// Terminal file-drop area: upload external files to the terminal's OSC7-tracked working directory.
/// Show a blue-border transparent-fill drag overlay for SSH uploads; leave local-terminal drag/drop handling alone.
struct TerminalDropArea: View {
    let terminal: LocalProcessTerminalView
    let isActive: Bool
    let model: AppModel
    let tabId: Int
    let canUpload: Bool
    @State private var targeted = false

    private static let dropBlue = Color(hex: 0x1E90FF)   // Use the editor change-bar blue.

    var body: some View {
        TerminalSurface(terminal: terminal, isActive: isActive)
            .overlay { if targeted { dropOverlay } }
            .animation(.easeOut(duration: 0.12), value: targeted)
            .onDrop(of: [.fileURL], isTargeted: canUpload ? $targeted : nil) { providers in
                guard canUpload else { return false }
                loadURLs(providers) { urls in
                    if !urls.isEmpty { model.uploadDroppedFiles(urls, toTabId: tabId) }
                }
                return true
            }
    }

    private var dropOverlay: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Self.dropBlue.opacity(0.07))   // Transparent fill keeps the terminal visible.
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Self.dropBlue, lineWidth: 2))
            .overlay {
                VStack(spacing: 8) {
                    Image(lucideSymbol: "square.and.arrow.up").font(.system(size: 22, weight: .medium))
                    Text("Release to upload to the current directory").font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(Self.dropBlue)
                .padding(.horizontal, 18).padding(.vertical, 14)
                .background(Pal.solidMantle.opacity(0.92), in: RoundedRectangle(cornerRadius: 10))
            }
            .allowsHitTesting(false)
            .transition(.opacity)
    }

    private func loadURLs(_ providers: [NSItemProvider], _ completion: @escaping ([URL]) -> Void) {
        var urls: [URL] = []
        let group = DispatchGroup()
        for p in providers {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL { urls.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(urls) }
    }
}

struct TerminalSurface: NSViewRepresentable {
    let terminal: LocalProcessTerminalView
    /// Whether this tab has keyboard focus; controls focus stealing only on initial creation.
    /// Do not use focus to determine visibility; the bottom panel mounts only the displayed terminal, which stays visible while the editor has focus.
    var isActive: Bool = true

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        terminal.menu = Self.buildContextMenu()
        terminal.isHidden = false   // This same view may previously have been hidden as an inactive terminal.
        // Take focus on initial mount only for the active terminal; switching servers while editing must not steal keyboard focus.
        if isActive {
            DispatchQueue.main.async { terminal.window?.makeFirstResponder(terminal) }
        }
        return terminal
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        // AppModel.focusActiveTab explicitly handles terminal focus. Do not call makeFirstResponder here:
        // updateNSView frequently runs for theme/settings/hover redraws and would steal focus from sidebar search.
        if nsView.isHidden { nsView.isHidden = false }
    }

    private static func buildContextMenu() -> NSMenu {
        let menu = NSMenu()

        let copy = NSMenuItem(title: String(localized: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        copy.keyEquivalentModifierMask = .command
        menu.addItem(copy)

        let paste = NSMenuItem(title: String(localized: "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        paste.keyEquivalentModifierMask = .command
        menu.addItem(paste)

        let selectAll = NSMenuItem(title: String(localized: "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        selectAll.keyEquivalentModifierMask = .command
        menu.addItem(selectAll)

        menu.addItem(.separator())

        let clear = NSMenuItem(title: String(localized: "Clear Screen"), action: #selector(TerminalActions.clearTerminal(_:)), keyEquivalent: "k")
        clear.keyEquivalentModifierMask = .command
        menu.addItem(clear)

        menu.addItem(.separator())

        let search = NSMenuItem(title: String(localized: "Search"), action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f")
        search.keyEquivalentModifierMask = .command
        search.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        menu.addItem(search)

        return menu
    }
}

/// Connection state for an SSH tab, retained on disconnect to show a reconnect overlay; not created for local terminals.
@MainActor
final class TerminalConn: ObservableObject {
    enum Phase { case live, dropped }
    @Published var phase: Phase = .live
    @Published var cwd: String?   // Remote working directory reported by OSC 7, used by toolbar display/upload/open-file actions.
    var attempt = 0    // Consecutive reconnect-failure backoff generation; reset on connection.
    var dropGen = 0    // Disconnection generation lets the watchdog detect another drop during a reconnect attempt.
}

/// Overlay disconnected terminals with reconnect status and Reconnect Now; render nothing while connected.
struct TerminalReconnectOverlay: View {
    @ObservedObject var conn: TerminalConn
    let onReconnect: () -> Void

    var body: some View {
        if conn.phase == .dropped {
            ZStack {
                Pal.base.opacity(0.55)
                VStack(spacing: 12) {
                    Image(lucideSymbol: "wifi.exclamationmark").font(.system(size: 28)).foregroundStyle(Pal.yellow)
                    Text("Disconnected").font(.system(size: 14, weight: .semibold)).foregroundStyle(Pal.text)
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text("Reconnecting…").font(.system(size: 12)).foregroundStyle(Pal.subtext)
                    }
                    Button(action: onReconnect) {
                        Text("Reconnect Now").font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.mauve)
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(Pal.mauve.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).pointerCursor()
                }
                .padding(24)
                .background(Pal.solidMantle, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Pal.fill(0.08), lineWidth: 1))
            }
            .transition(.opacity)
        }
    }
}

/// Observe terminal OSC 7 directory changes and report remote cwd to AppModel for sidebar-tree navigation.
final class TerminalSessionDelegate: NSObject, LocalProcessTerminalViewDelegate {
    var onCwd: ((String) -> Void)?
    var onTerminated: ((Int32?) -> Void)?

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) { onTerminated?(exitCode) }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let p = Self.parsePath(directory) else { return }
        onCwd?(p)
    }

    /// Parse an OSC 7 file://host/path URL into an absolute path.
    static func parsePath(_ dir: String?) -> String? {
        guard let dir else { return nil }
        if dir.hasPrefix("file://") {
            let after = dir.dropFirst("file://".count)   // "host/path" or "/path".
            if let slash = after.firstIndex(of: "/") {
                let raw = String(after[slash...])
                return raw.removingPercentEncoding ?? raw   // macOS shell integration percent-encodes paths.
            }
            return nil
        }
        return dir.hasPrefix("/") ? dir : nil
    }
}

@objc protocol TerminalActions {
    func clearTerminal(_ sender: Any?)
}

extension LocalProcessTerminalView: TerminalActions {
    func clearTerminal(_ sender: Any?) {
        let terminal = getTerminal()
        terminal.feed(text: "\u{0C}")
        terminal.resetToInitialState()
    }
}

/// Terminal subclass overriding paste to prevent long commands/scripts being truncated or losing line boundaries.
/// SwiftTerm normally writes the entire paste at once; remote tty MAX_INPUT/MAX_CANON buffers (about 1-4KB)
/// can overflow before the shell consumes incoming lines, dropping bytes and collapsing lines.
/// Normalize newlines, wrap bracketed paste when remote mode 2004 is enabled, and throttle chunks so the remote tty can keep up.
final class PacedTerminalView: LocalProcessTerminalView {
    private static let chunkSize = 1024          // Keep each chunk safely below common tty input-buffer limits.
    private static let interChunkDelay = 0.012   // Inter-chunk delay: about 1KB/12ms, or 85KB/s, fast without flooding the buffer.

    // MARK: System SSH post-login OSC 7 injection / automatic password input
    private var pendingInject: String?
    private var autoPassword: String?
    private var swallowing = false
    private var swallowBuf: [UInt8] = []
    private var recentTail: [UInt8] = []
    private var quietWork: DispatchWorkItem?
    private static let readyMarker: [UInt8] = [0x01, 0x02, 0x53, 0x44, 0x02, 0x01]

    /// After launching system ssh, inject line once login settles and a prompt appears;
    /// hide its echo. Supply password/passphrase automatically once when prompted.
    func armSystemSSH(injectLine line: String, password: String?) {
        pendingInject = line
        autoPassword = (password?.isEmpty ?? true) ? nil : password
        swallowing = false; swallowBuf.removeAll(); recentTail.removeAll()
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in self?.pendingInject = nil }
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        if swallowing {
            swallowBuf.append(contentsOf: slice)
            let m = Self.readyMarker
            guard swallowBuf.count >= m.count,
                  let at = (0...(swallowBuf.count - m.count)).first(where: { Array(swallowBuf[$0..<$0 + m.count]) == m }) else { return }
            let rest = Array(swallowBuf[(at + m.count)...])
            swallowing = false; swallowBuf.removeAll()
            feed(byteArray: Array("\r\u{1B}[K".utf8)[...])   // Clear the old prompt line and redraw the new prompt in place.
            if !rest.isEmpty { feed(byteArray: rest[...]) }
            return
        }
        super.dataReceived(slice: slice)
        guard pendingInject != nil || autoPassword != nil else { return }
        recentTail.append(contentsOf: slice)
        if recentTail.count > 256 { recentTail.removeFirst(recentTail.count - 256) }
        let text = String(decoding: recentTail, as: UTF8.self).lowercased()
        if let pw = autoPassword, text.hasSuffix(": "), text.contains("password") || text.contains("passphrase") {
            autoPassword = nil
            recentTail.removeAll()
            terminalDelegate?.send(source: self, data: Array((pw + "\n").utf8)[...])
            return
        }
        quietWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.injectIfLoggedIn() }
        quietWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: w)
    }

    private func injectIfLoggedIn() {
        guard let line = pendingInject else { return }
        let text = String(decoding: recentTail, as: UTF8.self).lowercased()
        // Do not inject while password/host-key prompts indicate login is incomplete.
        if text.contains("password") || text.contains("passphrase") || text.contains("(yes/no") { return }
        let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last
        if last == ":" || last == "?" { return }
        pendingInject = nil
        swallowing = true; swallowBuf.removeAll()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in   // Release buffered output for shells that never emit the marker.
            guard let self, self.swallowing else { return }
            self.swallowing = false
            if !self.swallowBuf.isEmpty { self.feed(byteArray: self.swallowBuf[...]) }
            self.swallowBuf.removeAll()
        }
        terminalDelegate?.send(source: self, data: Array(line.utf8)[...])
    }

    override func paste(_ sender: Any) {
        guard let raw = NSPasteboard.general.string(forType: .string), !raw.isEmpty else { return }
        // Normalize CRLF/lone CR to LF; otherwise cooked-mode ICRNL turns CR+LF into two submissions, adding an empty command.
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let content = Array(text.utf8)

        // Attach bracketed-paste start/end markers directly to the first/last chunks.
        // Send markers with adjacent content, never separately or split across chunks, preserving order and preventing visible ESC[201~ remnants.
        var chunks: [[UInt8]] = []
        var i = 0
        while i < content.count {
            let end = min(i + Self.chunkSize, content.count)
            chunks.append(Array(content[i..<end]))
            i = end
        }
        if chunks.isEmpty { chunks.append([]) }   // Content should be nonempty; defensive fallback.

        if getTerminal().bracketedPasteMode {
            chunks[0].insert(contentsOf: EscapeSequences.bracketedPasteStart, at: 0)
            chunks[chunks.count - 1].append(contentsOf: EscapeSequences.bracketedPasteEnd)
        }
        sendChunks(chunks, from: 0)
    }

    /// Send chunkSize bytes every interChunkDelay, chaining scheduling on the main thread to preserve order without blocking UI.
    /// Send small single-chunk pastes immediately; throttle only larger blocks.
    private func sendChunks(_ chunks: [[UInt8]], from i: Int) {
        guard i < chunks.count else { return }
        // Send through terminalDelegate: local terminals route through self to the process; SSH terminals route through the driver to libssh2.
        terminalDelegate?.send(source: self, data: chunks[i][...])
        guard i + 1 < chunks.count else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.interChunkDelay) { [weak self] in
            self?.sendChunks(chunks, from: i + 1)
        }
    }
}

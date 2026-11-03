import AppKit
import SwiftTerm

/// Drive a SwiftTerm TerminalView with a libssh2 interactive shell as its terminalDelegate,
/// forwarding input/resizes to the remote PTY and feeding output back into the view. Replace LocalProcessTerminalView's
/// /usr/bin/ssh subprocess without changing terminal types elsewhere; only the SSH transport changes.
///
/// Each driver owns one dedicated SSHSession and one nonblocking C shell-pump thread for all reads/writes/resizes,
/// preventing libssh2 concurrency. Return the remote shell status, or 255 on disconnect to trigger ssh-compatible reconnection.
final class SSHTerminalDriver: NSObject, TerminalViewDelegate, @unchecked Sendable {
    private weak var tv: LocalProcessTerminalView?
    private let ssh: SSHConnection
    private var session: SSHSession?
    private var shell: OpaquePointer?            // ServerDockSSHShell*
    private var closed = false
    private var terminatedReported = false

    var onCwd: ((String) -> Void)?
    var onTerminated: ((Int32?) -> Void)?

    init(tv: LocalProcessTerminalView, ssh: SSHConnection) {
        self.tv = tv
        self.ssh = ssh
        super.init()
    }

    // MARK: Connection / close

    /// Connect/open shell/start pump in the background; report setup failures as disconnect 255 to trigger reconnection.
    /// Inject initialLine after login, including OSC7 hooks and optional cd/initial commands.
    func connect(cols: Int, rows: Int, initialLine: String) {
        let conn = ssh
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            let a = conn.libssh2Auth
            guard let session = try? SSHSession.connect(host: conn.host, port: conn.port, user: conn.user,
                                                        password: a.password, keyPath: a.keyPath,
                                                        keyPassphrase: a.keyPassphrase,
                                                        jump: conn.jumpHost),
                  let raw = session.rawHandle else {
                DispatchQueue.main.async { self.reportClosed(255) }   // Treat connection failure as a disconnect requiring reconnection.
                return
            }
            let box = Unmanaged.passRetained(self).toOpaque()         // The pump retains the context until on_closed releases it.
            var err = [CChar](repeating: 0, count: 256)
            guard let sh = serverdock_ssh_shell_open(raw, Int32(cols), Int32(rows),
                                                Self.onData, Self.onClosed, box, &err, 256) else {
                Unmanaged<SSHTerminalDriver>.fromOpaque(box).release()
                session.close()
                DispatchQueue.main.async { self.reportClosed(255) }
                return
            }
            DispatchQueue.main.async {
                if self.closed {                 // If closed during connection setup, tear down the newly created session.
                    serverdock_ssh_shell_close(sh)
                    session.close()
                    return
                }
                self.session = session
                self.shell = sh
                if !initialLine.isEmpty {
                    // Wait for shell rc files before injecting OSC7 hooks so .bashrc cannot overwrite them.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                        self?.beginSwallowing()
                        self?.sendText(initialLine)
                    }
                }
            }
        }
    }

    /// Stop the pump, free the channel, and close the session idempotently.
    func close() {
        guard !closed else { return }
        closed = true
        let sh = shell; shell = nil
        let sess = session; session = nil
        if let sh { serverdock_ssh_shell_close(sh) }     // Stopping/joining the pump triggers on_closed to release the box.
        sess?.close()
    }

    /// Write text for initial-command injection.
    func sendText(_ text: String) {
        let bytes = Array(text.utf8)
        guard let shell, !bytes.isEmpty else { return }
        bytes.withUnsafeBufferPointer { bp in
            bp.baseAddress!.withMemoryRebound(to: CChar.self, capacity: bp.count) {
                _ = serverdock_ssh_shell_write(shell, $0, Int32(bp.count))
            }
        }
    }

    private func reportClosed(_ code: Int32) {
        guard !terminatedReported else { return }
        terminatedReported = true
        onTerminated?(code)
    }

    // MARK: C callbacks (pump thread)

    private static let onData: ServerDockSSHDataCallback = { ud, bytes, len in
        guard let ud, let bytes, len > 0 else { return }
        let driver = Unmanaged<SSHTerminalDriver>.fromOpaque(ud).takeUnretainedValue()
        let slice = bytes.withMemoryRebound(to: UInt8.self, capacity: Int(len)) {
            Array(UnsafeBufferPointer(start: $0, count: Int(len)))
        }
        DispatchQueue.main.async { driver.receive(slice) }
    }

    // MARK: Injected-command echo filtering

    /// Ready marker emitted after injected commands (\001\002SD\002\001). Echo contains only escaped spelling, not actual control bytes, preventing false matches.
    private static let readyMarker: [UInt8] = [0x01, 0x02, 0x53, 0x44, 0x02, 0x01]

    /// Buffer incoming data during injection until the ready marker appears; discard command echo without clearing the screen/banner.
    private var swallowing = false
    private var swallowed: [UInt8] = []

    private func beginSwallowing() {
        swallowing = true
        swallowed.removeAll()
        // If a non-POSIX remote shell never emits the marker, pass buffered data through after 3 seconds to avoid a permanently blank terminal.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.endSwallowing(flush: true) }
    }

    private func endSwallowing(flush: Bool) {
        guard swallowing else { return }
        swallowing = false
        if flush, !swallowed.isEmpty { tv?.feed(byteArray: swallowed[...]) }
        swallowed.removeAll()
    }

    /// Handle remote data on the main thread.
    private func receive(_ bytes: [UInt8]) {
        guard swallowing else { tv?.feed(byteArray: bytes[...]); return }
        swallowed.append(contentsOf: bytes)
        let m = Self.readyMarker
        guard swallowed.count >= m.count,
              let at = (0...(swallowed.count - m.count)).first(where: { Array(swallowed[$0..<$0 + m.count]) == m }) else { return }
        let rest = Array(swallowed[(at + m.count)...])
        swallowing = false
        swallowed.removeAll()
        // Clear the old pre-injection prompt from the current line so the new prompt redraws in place instead of appearing twice.
        tv?.feed(byteArray: Array("\r\u{1B}[K".utf8)[...])
        if !rest.isEmpty { tv?.feed(byteArray: rest[...]) }
    }

    private static let onClosed: ServerDockSSHClosedCallback = { ud, code in
        guard let ud else { return }
        let driver = Unmanaged<SSHTerminalDriver>.fromOpaque(ud).takeRetainedValue()   // Balance connect's passRetained.
        DispatchQueue.main.async { driver.reportClosed(code) }
    }

    // MARK: TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard let shell, !data.isEmpty else { return }
        data.withUnsafeBufferPointer { bp in
            guard let base = bp.baseAddress else { return }
            _ = base.withMemoryRebound(to: CChar.self, capacity: bp.count) {
                serverdock_ssh_shell_write(shell, $0, Int32(bp.count))
            }
        }
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard let shell else { return }
        _ = serverdock_ssh_shell_resize(shell, Int32(newCols), Int32(newRows))
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        if let p = TerminalSessionDelegate.parsePath(directory) { onCwd?(p) }
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        guard let s = String(data: content, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }

    func setTerminalTitle(source: TerminalView, title: String) {}
    func scrolled(source: TerminalView, position: Double) {}
    func bell(source: TerminalView) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
}

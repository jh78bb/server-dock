import AppKit
import CoreGraphics
import SwiftUI
import RoyalVNCKit

/// Certificate decision: reject, accept once, or always trust this computer.
enum RDPCertDecision { case reject, once, trust }

/// Pending first-seen/changed-certificate trust request; respond returns the user's decision.
struct RDPCertPrompt: Identifiable {
    let id = UUID()
    let host: String
    let port: Int
    let fingerprint: String
    let subject: String?
    let issuer: String?
    let changed: Bool            // true means a trusted-fingerprint mismatch and shows a stronger warning.
    let oldFingerprint: String?
    let respond: (RDPCertDecision) -> Void
}

struct VNCCredentialPrompt: Identifiable {
    let id = UUID()
    let requiresUsername: Bool
    let message: String?
    var prefillUsername: String = ""
}

/// Live connection-log line; level 0=info, 1=warning, 2=error.
struct RDPLogLine: Identifiable {
    let id = UUID()
    let time: String
    let message: String
    let level: Int
}

/// Connection-progress steps derive from phase instead of brittle log-string parsing.
struct RDPConnectStep: Identifiable {
    enum State { case pending, running, success, failure }
    let id = UUID()
    let title: String
    var state: State
}

/// Host state for one RDP remote-desktop session.
///
/// The ObjC ServerDockRDPSession bridge drives FreeRDP through pure C ServerDockRDPCore. Its background event-loop thread runs
/// freerdp_connect; BGRA frames return through the main-thread delegate and become CGImage objects for RDPSessionView.
final class RDPSession: NSObject, ObservableObject, ServerDockRDPSessionDelegate, VNCConnectionDelegate {
    enum Phase: Equatable {
        case pending          // Connection has not started.
        case connecting
        case connected
        case failed(String)
        case disconnected
    }

    let host: Host
    private(set) var config: RDPConnection
    @Published private(set) var phase: Phase = .pending {
        didSet {
            if phase == .connected, oldValue != .connected { connectedAt = Date() }
            if phase == .connecting { connectedAt = nil }
        }
    }
    @Published var viewOnly = false                        // View-only mode sends no remote mouse/keyboard input.
    @Published var zoom: Double? = nil                    // nil fits the window; other values are zoom factors, with 1=actual size.
    @Published private(set) var connectedAt: Date?       // Connection time for elapsed status-bar duration.
    @Published private(set) var image: CGImage? = nil   // Latest frame, updated on the main thread.
    @Published var certPrompt: RDPCertPrompt? = nil      // Non-nil overlays a certificate trust dialog.
    @Published var vncCredentialPrompt: VNCCredentialPrompt? = nil
    @Published private(set) var logs: [RDPLogLine] = []  // Connection logs shown in the panel.
    @Published private(set) var ready: Bool = false      // Set after the first frame settles so the dialog can enter without flashing a partially rendered desktop.
    private var lastCanvas: CGSize? = nil                // Last connection canvas size, reused on retry.
    private var firstFrameScheduled = false              // Whether first-frame settling is already scheduled; prevents duplicate scheduling.

    private var session: ServerDockRDPSession?
    private var vncConnection: VNCConnection?
    private var vncLogger: VNCCustomLogger?
    private var vncConnectTimeoutWork: DispatchWorkItem?
    private var vncModifierMask = 0
    private var vncPassword: String
    private var vncRequiresUsername = false
    private var pendingVNCCredentialCompletion: ((VNCCredential?) -> Void)?
    private var canceledVNCPasswordPrompt = false
    private var pendingSaveCredentials: (user: String, password: String)?   // Credentials entered with Save checked; persist only after successful connection.

    init(host: Host) {
        self.host = host
        self.config = host.rdp ?? RDPConnection()
        self.vncPassword = self.config.password
        super.init()
    }

    /// Connect idempotently, ignoring already connecting/connected sessions. Convert the canvas/window content size in points to remote pixels
    /// for a sharp 1:1 fill without black bars.
    func connect(canvas: CGSize) {
        guard session == nil, vncConnection == nil else { return }
        guard let t = Self.targetPixelSize(canvas) else { return }
        lastCanvas = canvas
        ready = false
        firstFrameScheduled = false
        phase = .connecting
        if config.protocolType == .vnc {
            appendLog(String(localized: "Connecting to VNC server…"))
            let settings = VNCConnection.Settings(
                isDebugLoggingEnabled: false,
                hostname: config.host,
                port: UInt16(clamping: config.port),
                isShared: true,
                isScalingEnabled: true,
                useDisplayLink: true,
                inputMode: .forwardKeyboardShortcutsIfNotInUseLocally,
                isClipboardRedirectionEnabled: false,
                colorDepth: .depth24Bit,
                frameEncodings: .default
            )
            let logger = VNCCustomLogger(
                logDebugHandler: { [weak self] message in
                    // RoyalVNCKit otherwise keeps the entire handshake opaque in the
                    // connecting panel. Keep only protocol/authentication milestones.
                    let relevant = ["Protocol Version", "Security Type", "Security Types",
                                    "Authentication", "Client Init", "Server Init"]
                    guard relevant.contains(where: { message.localizedCaseInsensitiveContains($0) }) else { return }
                    DispatchQueue.main.async { [weak self] in
                        self?.appendLog("VNC: \(message)")
                    }
                },
                logInfoHandler: { _ in },
                logWarningHandler: { [weak self] message in
                    DispatchQueue.main.async { [weak self] in self?.appendLog("VNC: \(message)", level: 1) }
                },
                logErrorHandler: { [weak self] message in
                    DispatchQueue.main.async { [weak self] in self?.appendLog("VNC: \(message)", level: 2) }
                }
            )
            logger.isDebugLoggingEnabled = true
            vncLogger = logger
            let connection = VNCConnection(settings: settings, logger: logger)
            connection.delegate = self
            vncConnection = connection
            connection.connect()
            armVNCConnectTimeout(for: connection)
            return
        }
        let s = ServerDockRDPSession(host: config.host, port: Int32(config.port),
                                username: config.user, password: config.password,
                                domain: config.domain,
                                width: Int32(t.w), height: Int32(t.h))
        s.delegate = self
        session = s
        lastSent = t
        s.connect()
    }

    /// Convert canvas points to remote desktop pixels:
    /// use Retina backing scale for sharp pixels, then proportionally scale down into [640x480, 2560x1600], never up.
    /// Preserve the canvas aspect ratio so scaledToFit fills without black bars; round dimensions down to multiples of 8.
    static func targetPixelSize(_ canvas: CGSize) -> (w: Int, h: Int)? {
        guard canvas.width >= 100, canvas.height >= 100 else { return nil }
        let scale = Double(NSScreen.main?.backingScaleFactor ?? 2)
        var w = Double(canvas.width) * scale
        var h = Double(canvas.height) * scale
        let r = min(1.0, 2560.0 / w, 1600.0 / h)   // Scale the whole image down proportionally if it exceeds limits.
        w *= r; h *= r
        let wi = max(640, Int(w.rounded(.down))) / 8 * 8
        let hi = max(480, Int(h.rounded(.down))) / 8 * 8
        return (wi, hi)
    }

    /// Request disconnect; didChangeState(.disconnected) cleans up when the worker exits. Free the native session when this object is released.
    func disconnect() {
        stopClipboardSync()
        vncConnectTimeoutWork?.cancel()
        vncConnectTimeoutWork = nil
        vncCredentialPrompt = nil
        let pendingCredential = pendingVNCCredentialCompletion
        pendingVNCCredentialCompletion = nil
        pendingCredential?(nil)
        session?.disconnect()
        vncConnection?.disconnect()
    }

    /// Close synchronously and join the background thread before app exit; no native worker remains after return.
    func shutdown() {
        stopClipboardSync()
        vncConnectTimeoutWork?.cancel()
        vncConnectTimeoutWork = nil
        vncCredentialPrompt = nil
        let pendingCredential = pendingVNCCredentialCompletion
        pendingVNCCredentialCompletion = nil
        pendingCredential?(nil)
        session?.shutdown()
        session = nil
        vncConnection?.disconnect()
    }

    // MARK: - Mouse input (remote desktop pixel coordinates)
    // Send only while connected; otherwise FreeRDP repeatedly logs "input functions called after the session terminated".
    private var isConnected: Bool { if case .connected = phase { return !viewOnly }; return false }
    var isLive: Bool { if case .connected = phase { return true }; return false }
    func sendMouseMove(_ x: Int, _ y: Int) {
        guard isConnected else { return }
        if let vncConnection {
            vncConnection.mouseMove(x: UInt16(clamping: x), y: UInt16(clamping: y))
            return
        }
        session?.sendMouseMoveX(Int32(x), y: Int32(y))
    }
    func sendMouseButton(_ button: Int, down: Bool, x: Int, y: Int) {
        guard isConnected else { return }
        if let vncConnection {
            let b: VNCMouseButton = button == 0 ? .left : (button == 1 ? .right : .middle)
            if down { vncConnection.mouseButtonDown(b, x: UInt16(clamping: x), y: UInt16(clamping: y)) }
            else { vncConnection.mouseButtonUp(b, x: UInt16(clamping: x), y: UInt16(clamping: y)) }
            return
        }
        session?.sendMouseButton(Int32(button), down: down, x: Int32(x), y: Int32(y))
    }
    func sendMouseWheel(_ delta: Int, x: Int, y: Int) {
        guard isConnected else { return }
        if let vncConnection {
            let wheel: VNCMouseWheel = delta >= 0 ? .up : .down
            vncConnection.mouseWheel(wheel, x: UInt16(clamping: x), y: UInt16(clamping: y),
                                     steps: UInt32(max(1, abs(delta) / 10)))
            return
        }
        session?.sendMouseWheel(Int32(delta), x: Int32(x), y: Int32(y))
    }

    // MARK: - Keyboard input (macOS virtual keyCode, ServerDockRDPModMask modifiers)
    func sendKey(_ keyCode: Int, down: Bool) {
        guard isConnected else { return }
        session?.sendKey(Int32(keyCode), down: down)
    }
    func sendModifiers(_ mask: Int) {
        guard isConnected else { return }
        if let vncConnection {
            let mapping: [(Int, VNCKeyCode)] = [(1, .shift), (2, .control), (4, .option), (8, .command)]
            for (bit, key) in mapping where (mask & bit != 0) != (vncModifierMask & bit != 0) {
                if mask & bit != 0 { vncConnection.keyDown(key) } else { vncConnection.keyUp(key) }
            }
            vncModifierMask = mask
            return
        }
        session?.sendModifiers(Int32(mask))
    }

    func sendVNCKey(_ event: NSEvent, down: Bool) {
        guard isConnected, let vncConnection else { return }
        let keys = VNCKeyCode.keyCodesFrom(cgKeyCode: CGKeyCode(event.keyCode), characters: event.charactersIgnoringModifiers)
        for key in keys { down ? vncConnection.keyDown(key) : vncConnection.keyUp(key) }
    }

    // MARK: Viewer key combinations
    enum Shortcut: CaseIterable, Identifiable {
        case ctrlAltDel, altTab, esc, tab, windowsKey
        var id: Self { self }
        var title: String {
            switch self {
            case .ctrlAltDel: return "Ctrl-Alt-Del"
            case .altTab: return "Alt-Tab"
            case .esc: return "Esc"
            case .tab: return "Tab"
            case .windowsKey: return String(localized: "Windows / Command Key")
            }
        }
    }

    /// Press/release modifiers and one key sequentially; masks match sendModifiers: Shift=1, Control=2, Alt=4, Command=8.
    func send(_ shortcut: Shortcut) {
        guard case .connected = phase else { return }
        let mask: Int, key: Int?
        switch shortcut {
        case .ctrlAltDel: mask = 2 | 4; key = 117        // Forward Delete
        case .altTab: mask = 4; key = 48
        case .esc: mask = 0; key = 53
        case .tab: mask = 0; key = 48
        case .windowsKey: mask = 8; key = nil
        }
        let wasViewOnly = viewOnly; viewOnly = false; defer { viewOnly = wasViewOnly }
        sendModifiers(mask)
        if let key {
            pressKey(key, down: true)
            pressKey(key, down: false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self else { return }
            let saved = self.viewOnly; self.viewOnly = false
            self.sendModifiers(0)
            self.viewOnly = saved
        }
    }

    private func pressKey(_ code: Int, down: Bool) {
        if let vncConnection {
            for k in VNCKeyCode.keyCodesFrom(cgKeyCode: CGKeyCode(code), characters: nil) { down ? vncConnection.keyDown(k) : vncConnection.keyUp(k) }
        } else { session?.sendKey(Int32(code), down: down) }
    }

    /// Current frame as PNG for screenshot save/copy.
    func screenshotPNG() -> Data? {
        guard let image else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    // MARK: - VNCConnectionDelegate
    func connection(_ connection: VNCConnection, stateDidChange connectionState: VNCConnection.ConnectionState) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.vncConnection === connection else { return }
            switch connectionState.status {
            case .connecting: self.phase = .connecting
            case .connected:
                self.vncConnectTimeoutWork?.cancel()
                self.vncConnectTimeoutWork = nil
                self.vncLogger = nil
                self.phase = .connected
                self.appendLog(String(localized: "VNC connection established."))
                if let save = self.pendingSaveCredentials {   // Persist only after login succeeds.
                    self.pendingSaveCredentials = nil
                    AppModel.shared.saveVNCCredentials(hostId: self.host.id, user: save.user, password: save.password)
                }
            case .disconnected, .disconnecting:
                self.vncConnectTimeoutWork?.cancel()
                self.vncConnectTimeoutWork = nil
                self.pendingSaveCredentials = nil
                if let error = connectionState.error {
                    self.phase = .failed(error.localizedDescription)
                    self.appendLog(error.localizedDescription, level: 2)
                    if error.localizedDescription.localizedCaseInsensitiveContains("authentication failed") {
                        if self.canceledVNCPasswordPrompt {
                            self.canceledVNCPasswordPrompt = false
                        } else {
                            self.vncPassword = ""
                            self.showVNCCredentialPrompt(message: String(localized: "VNC authentication failed. Enter the password again."))
                        }
                    }
                } else if case .failed = self.phase {
                    break
                } else {
                    self.phase = .disconnected
                }
            }
        }
    }

    func connection(_ connection: VNCConnection, credentialFor authenticationType: VNCAuthenticationType,
                    completion: @escaping (VNCCredential?) -> Void) {
        guard authenticationType.requiresPassword else { completion(nil); return }
        vncRequiresUsername = authenticationType.requiresUsername
        // Prompt for a missing required username, e.g. macOS Screen Sharing, even if a password is saved.
        if !vncPassword.isEmpty, !(authenticationType.requiresUsername && config.user.trimmingCharacters(in: .whitespaces).isEmpty) {
            let credential: VNCCredential = authenticationType.requiresUsername
                ? VNCUsernamePasswordCredential(username: config.user, password: vncPassword)
                : VNCPasswordCredential(password: vncPassword)
            completion(credential)
            return
        }

        pendingVNCCredentialCompletion = completion
        DispatchQueue.main.async { [weak self] in
            guard let self, self.vncConnection === connection else { completion(nil); return }
            self.showVNCCredentialPrompt()
        }
    }

    func submitVNCCredentials(username: String, password: String, save: Bool = false) {
        guard !password.isEmpty else { return }
        vncCredentialPrompt = nil
        vncPassword = password
        pendingSaveCredentials = save ? (username, password) : nil
        if vncRequiresUsername { config.user = username }
        let credential: VNCCredential = vncRequiresUsername
            ? VNCUsernamePasswordCredential(username: username, password: password)
            : VNCPasswordCredential(password: password)
        if let completion = pendingVNCCredentialCompletion {
            pendingVNCCredentialCompletion = nil
            if let vncConnection { armVNCConnectTimeout(for: vncConnection) }
            completion(credential)
        } else {
            retry()
        }
    }

    func cancelVNCCredentialPrompt() {
        vncCredentialPrompt = nil
        canceledVNCPasswordPrompt = true
        let completion = pendingVNCCredentialCompletion
        pendingVNCCredentialCompletion = nil
        completion?(nil)
    }

    private func showVNCCredentialPrompt(message: String? = nil) {
        guard vncCredentialPrompt == nil else { return }
        vncConnectTimeoutWork?.cancel()
        vncConnectTimeoutWork = nil
        vncCredentialPrompt = VNCCredentialPrompt(requiresUsername: vncRequiresUsername, message: message, prefillUsername: config.user)
    }

    private func armVNCConnectTimeout(for connection: VNCConnection) {
        vncConnectTimeoutWork?.cancel()
        let work = DispatchWorkItem { [weak self, weak connection] in
            guard let self, let connection,
                  self.vncConnection === connection,
                  case .connecting = self.phase,
                  self.vncCredentialPrompt == nil else { return }
            let message = String(localized: "VNC handshake timed out. Check that the server is responding to VNC connections.")
            self.phase = .failed(message)
            self.appendLog(message, level: 2)
            connection.disconnect()
        }
        vncConnectTimeoutWork = work
        // macOS ARD requires 4096-bit Diffie-Hellman through RoyalVNCKit's pure-Swift BigInt.
        // Release takes about 1s; unoptimized Debug exceeds 30s and the 20s timeout, unrelated to networking.
        #if DEBUG
        let limit: Double = 120
        #else
        let limit: Double = 30
        #endif
        DispatchQueue.main.asyncAfter(deadline: .now() + limit, execute: work)
    }

    func connection(_ connection: VNCConnection, didCreateFramebuffer framebuffer: VNCFramebuffer) {
        updateVNCImage(framebuffer)
    }

    func connection(_ connection: VNCConnection, didResizeFramebuffer framebuffer: VNCFramebuffer) {
        updateVNCImage(framebuffer)
    }

    func connection(_ connection: VNCConnection, didUpdateFramebuffer framebuffer: VNCFramebuffer,
                    x: UInt16, y: UInt16, width: UInt16, height: UInt16) {
        updateVNCImage(framebuffer)
    }

    func connection(_ connection: VNCConnection, didUpdateCursor cursor: VNCCursor) {}

    private func updateVNCImage(_ framebuffer: VNCFramebuffer) {
        guard let image = framebuffer.cgImage else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.vncConnection != nil else { return }
            self.image = image
            if !self.firstFrameScheduled {
                self.firstFrameScheduled = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    guard let self, case .connected = self.phase, self.image != nil else { return }
                    self.ready = true
                }
            }
        }
    }

    // MARK: - Dynamic resolution (window resizing)
    private var resizeWork: DispatchWorkItem?
    private var lastSent: (w: Int, h: Int)?
    /// During window dragging, scale locally with SwiftUI scaledToFit; send one coalesced remote resize after dragging stops.
    /// Debounce for 0.5s and require a 32px change to avoid flooding DisplayControl with intermediate layout sizes.
    /// If the channel/capability is not ready, cache the desired size and resend after DisplayControlCaps arrives.
    func requestResize(canvas: CGSize) {
        guard config.protocolType == .rdp else { return }
        guard case .connected = phase, let t = Self.targetPixelSize(canvas) else { return }
        if let l = lastSent, abs(l.w - t.w) < 32, abs(l.h - t.h) < 32 { return }
        resizeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.session?.resize(toWidth: Int32(t.w), height: Int32(t.h))
            self?.lastSent = t
        }
        resizeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    // MARK: - ServerDockRDPSessionDelegate (already dispatched to the main thread)
    func rdpSession(_ session: ServerDockRDPSession, didChangeState state: Int, message: String?) {
        switch state {
        case 0: phase = .connecting
        case 1: phase = .connected; startClipboardSync()
        case 2: phase = .disconnected; stopClipboardSync()
        default: phase = .failed(message.map(Self.localizeCoreLog) ?? String(localized: "Connection Failed")); stopClipboardSync()
        }
    }

    // MARK: - Bidirectional plain-text clipboard synchronization
    private var pbTimer: Timer?
    private var pbLastCount = NSPasteboard.general.changeCount
    private var pbSuppressCount = -1   // Record changeCount after a remote clipboard write so polling does not echo it back.

    /// Clipboard synchronization setting, toggleable at runtime.
    private var clipboardSyncOn: Bool { AppSettings.shared.rdpClipboardSync }

    /// On connection, announce current local text if enabled, then poll every 0.5s because NSPasteboard has no change notification.
    /// Keep the timer running and gate each of the three action points separately for live toggling.
    private func startClipboardSync() {
        guard pbTimer == nil else { return }
        pbLastCount = NSPasteboard.general.changeCount
        if clipboardSyncOn, let s = NSPasteboard.general.string(forType: .string), !s.isEmpty {
            self.session?.offerClipboardText(s)
        }
        let t = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.pollLocalClipboard()
        }
        RunLoop.main.add(t, forMode: .common)   // Poll during tracking modes such as dragging/scrolling too.
        pbTimer = t
    }

    private func stopClipboardSync() {
        pbTimer?.invalidate()
        pbTimer = nil
    }

    private func pollLocalClipboard() {
        guard clipboardSyncOn else { return }
        let pb = NSPasteboard.general
        let count = pb.changeCount
        guard count != pbLastCount else { return }
        pbLastCount = count
        if count == pbSuppressCount { return }   // This change came from the remote clipboard; do not broadcast it back.
        session?.offerClipboardText(pb.string(forType: .string))
    }

    /// Remote text arrives on the main thread; record changeCount after writing locally so polling skips the echo.
    func rdpSession(_ session: ServerDockRDPSession, didReceiveClipboardText text: String) {
        guard clipboardSyncOn else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        pbSuppressCount = pb.changeCount
        pbLastCount = pb.changeCount
    }

    func rdpSession(_ session: ServerDockRDPSession, didReceiveFrame pixels: Data,
                    width: Int32, height: Int32, stride: Int32, bpp: Int32) {
        image = Self.makeImage(pixels, Int(width), Int(height), Int(stride), Int(bpp))
        // Briefly let the first frame settle while the server paints all desktop tiles before allowing entry, avoiding black/partial frames.
        if !firstFrameScheduled {
            firstFrameScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, case .connected = self.phase, self.image != nil else { return }
                self.ready = true
            }
        }
    }

    /// Main-thread certificate check: silently accept permanently trusted matching fingerprints; otherwise request a user decision.
    /// completion: 0=reject, 1=permanent trust, 2=accept once. This project stores trust locally rather than FreeRDP known_hosts, so permanent trust still returns 2.
    /// Use an explicit selector: inference for this long @objc signature is unreliable, and a mismatch makes respondsToSelector fail,
    /// silently taking the unimplemented/accept fallback without showing a dialog. Fix the selector so the bridge reaches this method.
    @objc(rdpSession:verifyCertificateForHost:port:commonName:subject:issuer:fingerprint:changed:oldSubject:oldIssuer:oldFingerprint:completion:)
    func rdpSession(_ session: ServerDockRDPSession, verifyCertificateForHost host: String, port: Int32,
                    commonName: String?, subject: String?, issuer: String?, fingerprint: String?,
                    changed: Bool, oldSubject: String?, oldIssuer: String?, oldFingerprint: String?,
                    completion: @escaping (Int) -> Void) {
        let fp = fingerprint ?? ""
        let p = Int(port)
        if RDPCertTrustStore.shared.isTrusted(host: host, port: p, fingerprint: fp) {
            appendLog(String(localized: "Server certificate trusted. Continuing connection…"))
            completion(2); return   // Already trusted; do not interrupt the user.
        }
        appendLog(changed ? String(localized: "Server certificate changed — awaiting confirmation…") : String(localized: "Untrusted server certificate — awaiting confirmation…"), level: 1)
        certPrompt = RDPCertPrompt(host: host, port: p, fingerprint: fp,
                                   subject: subject, issuer: issuer,
                                   changed: changed, oldFingerprint: oldFingerprint) { [weak self] decision in
            self?.certPrompt = nil
            switch decision {
            case .reject:
                self?.appendLog(String(localized: "Certificate rejected by user; connection canceled"), level: 2)
                completion(0)
            case .once:
                self?.appendLog(String(localized: "Certificate accepted for this session; continuing to connect"))
                completion(2)
            case .trust:
                self?.appendLog(String(localized: "Set to always trust this computer; continuing to connect"))
                RDPCertTrustStore.shared.trust(host: host, port: p, fingerprint: fp,
                                               subject: subject, issuer: issuer)
                completion(2)
            }
        }
    }

    /// Main-thread connection log; explicit selector avoids unreliable @objc inference for optional protocol methods.
    @objc(rdpSession:didLog:level:)
    func rdpSession(_ session: ServerDockRDPSession, didLog text: String, level: Int) {
        appendLog(Self.localizeCoreLog(text), level: level)
    }

    /// Localize known English C-bridge log/state constants for the connection panel; handle dynamic lines by prefix.
    private static func localizeCoreLog(_ text: String) -> String {
        switch text {
        case "Initializing connection parameters…":                              return String(localized: "Initializing connection parameters…")
        case "Graphics subsystem ready, connected":                              return String(localized: "Graphics subsystem ready — connected")
        case "Graphics pipeline enabled (full color)":                           return String(localized: "Graphics pipeline enabled (full color)")
        case "Display control channel ready (dynamic resolution)":               return String(localized: "Display control channel ready (dynamic resolution)")
        case "Negotiating security layer and connecting…":                       return String(localized: "Negotiating security layer and connecting…")
        case "Verifying server certificate…":                                    return String(localized: "Verifying server certificate…")
        case "Connection failed (authentication failed or server unreachable)":  return String(localized: "Connection failed (authentication failed or server unreachable)")
        case "Disconnected":                                                     return String(localized: "Disconnected")
        case "Connection failed":                                                return String(localized: "Connection Failed")
        default: break
        }
        if text.hasPrefix("Connecting ") {
            return String(localized: "Connecting \(String(text.dropFirst("Connecting ".count)))")
        }
        if text.hasPrefix("Failed to start connection ("), text.hasSuffix(")") {
            return String(localized: "Failed to start connection (\(String(text.dropFirst("Failed to start connection (".count).dropLast())))")
        }
        return text
    }

    private static let logTimeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    /// Append a connection-log line on the main thread.
    func appendLog(_ message: String, level: Int = 0) {
        logs.append(RDPLogLine(time: Self.logTimeFormatter.string(from: Date()), message: message, level: level))
    }

    /// Retry by freeing/joining the old session, clearing frames/logs, and reconnecting with the previous canvas size.
    func retry() {
        vncConnectTimeoutWork?.cancel()
        vncConnectTimeoutWork = nil
        vncConnection?.disconnect()
        vncConnection = nil
        session = nil
        image = nil
        logs = []
        ready = false
        firstFrameScheduled = false
        phase = .pending
        if let c = lastCanvas { connect(canvas: c) }
    }

    // MARK: - Connection panel (steps and state derived from phase)

    /// Three connection steps cover key stages; live logs supply details.
    var connectSteps: [RDPConnectStep] {
        let titles = [String(localized: "Initialize Configuration"), String(localized: "Establishing secure connection"), String(localized: "Connected")]
        let states: [RDPConnectStep.State]
        switch phase {
        case .pending:      states = [.running, .pending, .pending]
        case .connecting:   states = [.success, .running, .pending]
        case .connected:    states = [.success, .success, .success]
        case .failed:       states = [.success, .failure, .pending]
        case .disconnected: states = [.success, .failure, .pending]
        }
        return zip(titles, states).map { RDPConnectStep(title: $0, state: $1) }
    }

    var connectStatusText: String {
        switch phase {
        case .pending, .connecting: return String(localized: "Connecting…")
        case .connected:            return String(localized: "Connected")
        case .failed:               return String(localized: "Connection Failed")
        case .disconnected:         return String(localized: "Disconnected")
        }
    }

    /// Convert the GDI framebuffer to CGImage using actual bytes per pixel, matching official Mac/iOS mac_create_bitmap_context:
    /// - bpp==2（RGB16/RGB565）：bitsPerComponent=5、bitsPerPixel=16、byteOrder16Little
    /// Otherwise BGRX32 uses bitsPerComponent=8, bitsPerPixel=32, byteOrder32Little.
    /// Both use noneSkipFirst to ignore the high/alpha channel and avoid transparent frames. Use the 16bpp branch after RGB16 negotiation/resizing;
    /// reading 16bpp with a 32bpp stride splits each row into two and produces a torn/doubled desktop.
    private static func makeImage(_ data: Data, _ w: Int, _ h: Int, _ stride: Int, _ bpp: Int) -> CGImage? {
        guard w > 0, h > 0, stride > 0, data.count >= h * stride else { return nil }
        let order: CGBitmapInfo = bpp == 2 ? .byteOrder16Little : .byteOrder32Little
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | order.rawValue)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: w, height: h,
                       bitsPerComponent: bpp == 2 ? 5 : 8, bitsPerPixel: bpp == 2 ? 16 : 32,
                       bytesPerRow: stride, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info,
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

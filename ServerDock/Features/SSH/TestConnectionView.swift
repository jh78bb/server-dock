import SwiftUI

struct TestConnectionView: View {
    @ObservedObject var draft: HostDraft
    @ObservedObject var model: AppModel
    @ObservedObject private var theme = ThemeManager.shared
    @Environment(\.dismiss) private var dismiss
    @StateObject private var tester = ConnectionTester()

    var body: some View {
        VStack(spacing: 0) {
            // Header.
            HStack {
                Text("Test Connection")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Pal.text)
                Spacer()
                Button { dismiss() } label: {
                    Image(lucideSymbol: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Pal.overlay)
                        .frame(width: 24, height: 24)
                        .background(Pal.fill(0.05), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
            .padding(.horizontal, 20).padding(.vertical, 16)

            Rectangle().fill(Pal.fill(0.06)).frame(height: 1)

            ConnectionProgressView(tester: tester, targetLabel: targetLabel)

            Rectangle().fill(Pal.fill(0.06)).frame(height: 1)

            // Footer.
            HStack {
                Spacer()
                if tester.isRunning {
                    SecondaryButton(title: "Cancel") { tester.cancel(); dismiss() }
                } else {
                    SecondaryButton(title: "Close") { dismiss() }
                    PrimaryButton(title: "Test Again") { Task { await startTest() } }
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
        }
        .frame(width: 520, height: 600)
        .background(Pal.solidBase)
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .overlay {
            ZStack {
                if let pending = model.pendingHostKey {
                    HostKeyDialog(pending: pending).transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: model.pendingHostKey?.id)
            .allowsHitTesting(model.pendingHostKey != nil)
        }
        .task {
            await startTest()
        }
        .onDisappear { tester.cancel() }
    }

    @MainActor
    private func startTest() async {
        let connection = draft.buildConnection()
        // The test runs inside the app, so direct SSH targets need the same explicit
        // host-key confirmation as normal connections. Jump hosts cannot be scanned directly.
        if !connection.hasJumpHost,
           !(await model.verifyFingerprint(host: connection.host, port: connection.port)) { return }
        guard !Task.isCancelled else { return }
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) { tester.start(conn: connection) }
    }

    private var targetLabel: String {
        let u = draft.user.isEmpty ? "" : "\(draft.user)@"
        return "\(u)\(draft.address):\(draft.port)"
    }
}

/// Reusable connection progress: target status, steps, and live logs for testing/terminal connections.
struct ConnectionProgressView: View {
    @ObservedObject var tester: ConnectionTester
    let targetLabel: String
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(tester.overallColor).frame(width: 8, height: 8)
                Text(targetLabel).font(.system(size: 12, design: .monospaced)).foregroundStyle(Pal.subtext)
                Spacer()
                Text(tester.overallStatusText).font(.system(size: 12, weight: .medium)).foregroundStyle(tester.overallColor)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(tester.steps) { step in stepRow(step) }
            }
            .padding(.horizontal, 20).padding(.bottom, 12)

            Rectangle().fill(Pal.fill(0.06)).frame(height: 1)

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Live Log").font(.system(size: 11, weight: .medium)).foregroundStyle(Pal.overlay)
                    Spacer()
                }
                .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 6)

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            combinedLog
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Color.clear.frame(height: 1).id("logBottom")
                        }
                        .padding(.horizontal, 20).padding(.bottom, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: tester.logs.count) { _ in
                        // Avoid withAnimation so growing logs do not animate the entire content layout.
                        proxy.scrollTo("logBottom", anchor: .bottom)
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .background(theme.isDark ? Pal.fill(0.03) : Pal.fill(0.02))
        }
    }

    /// Combine logs into one Text preserving timestamps/colors for free multiline selection/copy.
    private var combinedLog: Text {
        tester.logs.reduce(Text(verbatim: "")) { acc, log in
            let stamp = log.time.isEmpty ? "" : log.time + "  "
            return acc
                + Text(verbatim: stamp).foregroundColor(Pal.overlay)
                + Text(verbatim: log.message + "\n").foregroundColor(log.color)
        }
    }

    private func stepRow(_ step: ConnectionStep) -> some View {
        HStack(spacing: 10) {
            stepIcon(step.state).frame(width: 18)
            Text(step.title).font(.system(size: 13))
                .foregroundStyle(step.state == .pending ? Pal.overlay : Pal.text)
            Spacer()
            if let detail = step.detail {
                Text(detail).font(.system(size: 11, design: .monospaced)).foregroundStyle(Pal.overlay)
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func stepIcon(_ state: ConnectionStep.State) -> some View {
        switch state {
        case .pending: Image(lucideSymbol: "circle").font(.system(size: 13)).foregroundStyle(Pal.overlay)
        case .running: ProgressView().controlSize(.small).scaleEffect(0.7)
        case .success: Image(lucideSymbol: "checkmark.circle.fill").font(.system(size: 14)).foregroundStyle(Pal.green)
        case .failure: Image(lucideSymbol: "xmark.circle.fill").font(.system(size: 14)).foregroundStyle(Pal.red)
        }
    }
}

/// Connection-progress dialog reusing ConnectionProgressView; on success, invoke the terminal-entry callback.
struct ConnectingDialog: View {
    let host: Host
    var successHint: String = String(localized: "Opening terminal…")   // Success text varies by action: terminal/files/forwarding/monitoring.
    let verify: () async -> Bool   // Verify the fingerprint, possibly presenting a dialog, and return whether to continue.
    let onConnected: () -> Void
    let onCancel: () -> Void
    @StateObject private var tester = ConnectionTester()
    @ObservedObject private var theme = ThemeManager.shared
    @State private var verifying = true
    
    private let dialogCornerRadius: CGFloat = 14

    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Text("Connecting").font(.system(size: 15, weight: .semibold)).foregroundStyle(Pal.text)
                    Spacer()
                }
                .padding(.horizontal, 20).padding(.vertical, 16)
                Rectangle().fill(Pal.fill(0.06)).frame(height: 1)

                if verifying {
                    verifyingPanel
                } else {
                    ConnectionProgressView(tester: tester, targetLabel: targetLabel)
                }

                Rectangle().fill(Pal.fill(0.06)).frame(height: 1)
                HStack {
                    Spacer()
                    if verifying {
                        SecondaryButton(title: "Cancel") { onCancel() }
                    } else if tester.isRunning {
                        SecondaryButton(title: "Cancel") { tester.cancel(); onCancel() }
                    } else if tester.failed {
                        SecondaryButton(title: "Cancel") { onCancel() }
                        PrimaryButton(title: "Retry") { tester.start(conn: host.ssh ?? SSHConnection()) }
                    } else {
                        Text("Connected, \(successHint)").font(.system(size: 12)).foregroundStyle(Pal.green)
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 14)
            }
            .frame(width: 520, height: 560)
            .background(Pal.solidMantle)
            .clipShape(
                RoundedRectangle(cornerRadius: dialogCornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: dialogCornerRadius, style: .continuous)
                    .strokeBorder(Pal.fill(0.08), lineWidth: 1)
            }
        }
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .task {
            tester.onFinished = { success in
                guard success else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { onConnected() }
            }
            // First verify the host fingerprint; known hosts pass immediately and unknown hosts overlay the verification dialog.
            let ok = await verify()
            guard !Task.isCancelled else { return }
            if ok {
                verifying = false
                var tx = Transaction()
                tx.disablesAnimations = true
                withTransaction(tx) { tester.start(conn: host.ssh ?? SSHConnection()) }
            } else {
                onCancel()
            }
        }
        .onDisappear { tester.cancel() }
    }

    private var verifyingPanel: some View {
        VStack(spacing: 0) {
            // Target row matching the top of ConnectionProgressView.
            HStack(spacing: 8) {
                Circle().fill(Pal.yellow).frame(width: 8, height: 8)
                Text(targetLabel)
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(Pal.subtext)
                Spacer()
                Text("Verifying…").font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.yellow)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)

            Spacer()
            VStack(spacing: 14) {
                ProgressView().controlSize(.small)
                Text("Verifying host fingerprint…")
                    .font(.system(size: 13)).foregroundStyle(Pal.subtext)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var targetLabel: String {
        guard let s = host.ssh else { return host.addr }
        let u = s.user.isEmpty ? "" : "\(s.user)@"
        return "\(u)\(s.host):\(s.port)"
    }
}

// MARK: - Connection tester (parse real ssh -v output into stages)

struct ConnectionStep: Identifiable {
    enum State { case pending, running, success, failure }
    let id = UUID()
    let title: String
    var state: State = .pending
    var detail: String? = nil
}

struct ConnectionLog: Identifiable {
    let id = UUID()
    let time: String
    let message: String
    let color: Color
}

@MainActor
final class ConnectionTester: ObservableObject {
    @Published var steps: [ConnectionStep] = []
    @Published var logs: [ConnectionLog] = []
    @Published var isRunning = false
    @Published var failed = false

    private let stepTitles = [
        String(localized: "Initialize Configuration"),
        String(localized: "Resolving host address"),
        String(localized: "Establishing TCP connection"),
        String(localized: "SSH handshake"),
        String(localized: "Authentication"),
        String(localized: "Connected"),
    ]
    private var cancelled = false
    private var concluded = false
    private var currentAuthMethod: AuthMethod = .password
    /// C callback closure context, passed through Unmanaged across the @convention(c) boundary.
    private final class StageBox {
        let cb: (Int, Bool, String?) -> Void
        init(_ cb: @escaping (Int, Bool, String?) -> Void) { self.cb = cb }
    }
    /// Called once when testing/connecting ends; true means success.
    var onFinished: ((Bool) -> Void)?

    private func conclude(_ success: Bool) {
        guard !concluded else { return }
        concluded = true
        onFinished?(success)
    }

    var overallStatusText: String {
        if isRunning { return String(localized: "Connecting…") }
        if failed { return String(localized: "Connection Failed") }
        if !steps.isEmpty && steps.allSatisfy({ $0.state == .success }) { return String(localized: "Connected") }
        return String(localized: "Waiting")
    }

    var overallColor: Color {
        if isRunning { return Pal.yellow }
        if failed { return Pal.red }
        if !steps.isEmpty && steps.allSatisfy({ $0.state == .success }) { return Pal.green }
        return Pal.overlay
    }

    func start(conn: SSHConnection) {
        cancel()
        steps = stepTitles.map { ConnectionStep(title: $0) }
        logs = []
        isRunning = true
        failed = false
        cancelled = false
        concluded = false
        currentAuthMethod = conn.authMethod

        guard !conn.host.isEmpty else {
            log(String(localized: "Host address is required"), color: Pal.red)
            failStep(0); return
        }

        markRunning(0)
        log(String(localized: "Testing connection to \(conn.host):\(String(conn.port)) (user \(conn.user))"))
        if conn.hasJumpHost { log("Jump host: \(conn.jumpHost)") }
        if conn.disableProxy { log(String(localized: "Proxy: Disabled")) }
        else if !conn.proxyURL.isEmpty { log(String(localized: "Proxy: \(conn.proxyURL)")) }
        if !conn.ciphers.isEmpty { log(String(localized: "Cipher: \(conn.ciphers)")) }
        if !conn.kexAlgos.isEmpty { log(String(localized: "KEX: \(conn.kexAlgos)")) }
        markSuccess(0)
        markRunning(1)

        // In-process libssh2 staged testing replaces spawned ssh -v. The app initiates the connection itself,
        // triggering macOS local-network permission instead of silently blocking LAN connections initiated by a subprocess.
        let (password, keyPath, keyPass) = conn.libssh2Auth
        let (h, p, u) = (conn.host, conn.port, conn.user)
        let jump = conn.jumpHost.trimmingCharacters(in: .whitespaces)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let box = Unmanaged.passRetained(StageBox { stage, ok, msg in
                Task { @MainActor in self?.onStage(stage: stage, ok: ok, message: msg) }
            }).toOpaque()
            serverdock_ssh_test(h, Int32(p), u, password, keyPath, keyPass, jump, { ud, stage, ok, msg in
                guard let ud else { return }
                let b = Unmanaged<StageBox>.fromOpaque(ud).takeUnretainedValue()
                b.cb(Int(stage), ok != 0, msg.map { String(cString: $0) })
            }, box)
            Unmanaged<StageBox>.fromOpaque(box).release()
        }
    }

    func cancel() {
        cancelled = true   // The libssh2 background test ends on timeout; stop further UI updates here.
        isRunning = false
    }

    /// Map libssh2 C stages 1..5 to UI steps 1..5.
    private func onStage(stage: Int, ok: Bool, message: String?) {
        guard isRunning, !cancelled, stage >= 1, stage < steps.count else { return }
        if let message, !message.isEmpty { log(message, color: ok ? Pal.subtext : Pal.red) }
        if !ok, let message, let hint = actionableHint(for: message) {
            log("→ " + hint, color: Pal.yellow)
        }
        if ok {
            markSuccess(stage)
            if stage == steps.count - 1 {          // Final successful-connection stage.
                log(String(localized: "Connected ✓"), color: Pal.green)
                isRunning = false
                conclude(true)
            } else {
                markRunning(stage + 1)
            }
        } else {
            failStep(stage)                        // Mark failed and finish through conclude(false).
        }
    }

    /// Keep the raw library error for diagnosis, then add the next useful thing to check.
    private func actionableHint(for message: String) -> String? {
        let lower = message.lowercased()
        if lower.contains("authentication failed") || lower.contains("username/publickey combination invalid") {
            switch currentAuthMethod {
            case .key:
                return String(localized: "Check the username and selected private key. The matching public key must be in the server's ~/.ssh/authorized_keys, and public-key login must be allowed.")
            case .agent:
                return String(localized: "Check that the SSH agent is running and unlocked, that it holds a key for this server, and that the matching public key is in the server's ~/.ssh/authorized_keys.")
            case .password, .ask:
                return String(localized: "Check the username and password. To enter a password for each session, choose Ask each time in the host's authentication settings.")
            }
        }
        if lower.contains("failed getting banner") {
            return String(localized: "The server closed the connection before sending its SSH banner. This is usually a server-side limit, not a problem with this app or your known_hosts. OpenSSH 9.8+ replies \"Not allowed at this time\" and drops an address that made many connections or failed logins in a short time (PerSourcePenalties); MaxStartups, a temporary fail2ban/firewall ban or a stopped sshd look the same. Wait a few minutes without retrying (each attempt can extend the wait), then try again, and check the server log (journalctl -u ssh).")
        }
        return nil
    }

    // MARK: - Parse real ssh -v output

    // MARK: - Step state

    private func markRunning(_ i: Int) {
        guard i < steps.count, steps[i].state == .pending else { return }
        steps[i].state = .running
    }
    private func markSuccess(_ i: Int) {
        guard i < steps.count, steps[i].state != .success else { return }
        steps[i].state = .success
    }
    private func failStep(_ i: Int) {
        guard i < steps.count else { return }
        steps[i].state = .failure
        failed = true
        isRunning = false
        cancel()
        conclude(false)
    }

    private func log(_ message: String, color: Color = Pal.subtext) {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        logs.append(ConnectionLog(time: fmt.string(from: Date()), message: message, color: color))
    }
}

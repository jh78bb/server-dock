import SwiftUI
import LocalAuthentication

/// App lock requires Touch ID/Mac password at startup, after idle reactivation, or manual locking.
/// Lock blocks screen/input only; terminal sessions, transfers, and tunnels continue.
@MainActor
final class AppLock: ObservableObject {
    static let shared = AppLock()

    @Published private(set) var isLocked: Bool
    @Published private(set) var authenticating = false
    @Published var lastError: String?

    /// Lock only when enabled; authenticate before enabling to prevent accidental lockout.
    @Published private(set) var enabled: Bool
    /// Lock on return after this many inactive minutes; zero locks immediately on app switch.
    @Published var delayMinutes: Int { didSet { UserDefaults.standard.set(delayMinutes, forKey: "appLockDelay") } }

    private var resignedAt: Date?

    private init() {
        let on = UserDefaults.standard.bool(forKey: "appLockEnabled")
        enabled = on
        isLocked = on                                   // Always begin locked on launch.
        delayMinutes = UserDefaults.standard.object(forKey: "appLockDelay") as? Int ?? 5
    }

    /// Whether biometric/password authentication is available; passwordless Macs cannot enable locking.
    var isAvailable: Bool { LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) }
    var usesTouchID: Bool {
        let c = LAContext()
        return c.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) && c.biometryType == .touchID
    }

    private func evaluate(reason: String) async -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = String(localized: "Cancel")
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            let code = (error as? LAError)?.code
            if code != .userCancel && code != .appCancel && code != .systemCancel { lastError = error.localizedDescription }
            return false
        }
    }

    /// Unlock from the lock screen.
    func unlock() {
        guard isLocked, !authenticating else { return }
        authenticating = true; lastError = nil
        Task {
            let ok = await evaluate(reason: String(localized: "Unlock ServerDock"))
            authenticating = false
            if ok { isLocked = false; resignedAt = nil }
        }
    }

    /// Authenticate when enabling or disabling from settings.
    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        guard isAvailable else { lastError = String(localized: "This Mac has no password or Touch ID set up, so the app can't be locked."); return }
        Task {
            let ok = await evaluate(reason: on ? String(localized: "Turn on the ServerDock lock") : String(localized: "Turn off the ServerDock lock"))
            if ok {
                enabled = on
                UserDefaults.standard.set(on, forKey: "appLockEnabled")
                if !on { isLocked = false }
            }
        }
    }

    func lock() {
        guard enabled, !isLocked else { return }
        AppModel.shared.dismissAllSheets()
        AppModel.shared.showPalette = false
        NSApp.keyWindow?.makeFirstResponder(nil)        // Prevent underlying terminals/editors receiving keys.
        isLocked = true
    }

    func appDidResignActive() { if enabled { resignedAt = Date() } }

    func appDidBecomeActive() {
        guard enabled, !isLocked, let t = resignedAt else { return }
        if delayMinutes == 0 || Date().timeIntervalSince(t) >= Double(delayMinutes) * 60 { lock() }
    }
}

/// Fullscreen lock overlay starts Touch ID/password authentication immediately on appearance.
struct LockOverlay: View {
    @ObservedObject var lock: AppLock
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        ZStack {
            Pal.solidBase.ignoresSafeArea()
            VStack(spacing: 16) {
                Image(lucideSymbol: lock.usesTouchID ? "touchid" : "lock.fill").font(.system(size: 44, weight: .light)).foregroundStyle(Pal.tint)
                Text("ServerDock is locked").font(.system(size: 18, weight: .semibold)).foregroundStyle(Pal.text)
                Text("Unlock with Touch ID or your Mac password. Sessions, transfers and tunnels keep running.")
                    .font(.system(size: 12)).foregroundStyle(Pal.subtext).multilineTextAlignment(.center).frame(maxWidth: 340)
                Button { lock.unlock() } label: {
                    HStack(spacing: 6) { if lock.authenticating { ProgressView().controlSize(.small) }; Text("Unlock") }
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(.white).padding(.horizontal, 26).padding(.vertical, 8)
                        .background(Pal.tint, in: RoundedRectangle(cornerRadius: 8)).contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointerCursor().keyboardShortcut(.defaultAction).disabled(lock.authenticating)
                if let e = lock.lastError { Text(e).font(.system(size: 11)).foregroundStyle(Pal.red).multilineTextAlignment(.center).frame(maxWidth: 340) }
            }
        }
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { lock.unlock() } }
    }
}

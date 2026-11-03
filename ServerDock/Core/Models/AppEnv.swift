import Foundation

/// Detect Developer ID direct distribution versus Mac App Store sandbox.
/// Channel determines local-terminal availability/key importing; see [[ssh-libssh2-migration]] for shared-source build design.
enum AppEnv {
    /// Example hosts only for promotional screenshot builds, excluded from normal builds.
    static var isScreenshotDemo: Bool {
        #if SCREENSHOT_DEMO
        return true
        #else
        return false
        #endif
    }
    /// Compile-time MAS flag from ReleaseMAS SWIFT_ACTIVE_COMPILATION_CONDITIONS=SERVERDOCK_MAS.
    static var isMAS: Bool {
        #if SERVERDOCK_MAS
        return true
        #else
        return false
        #endif
    }

    /// Runtime App Sandbox detection: always true for MAS, false for unsandboxed Developer ID builds.
    static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    /// App Store receipt detection for channel-specific behavior; reserved for future use, not current update checks.
    static var isAppStoreReceiptPresent: Bool {
        guard let url = Bundle.main.appStoreReceiptURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// SMB requires NetFS mounting and is hidden in App Sandbox/MAS.
    static var smbEnabled: Bool { !isMAS }

    /// Hide local terminals in MAS because shell processes are confined to the sandbox container.
    static var localTerminalEnabled: Bool { !isMAS && !isScreenshotDemo }
}

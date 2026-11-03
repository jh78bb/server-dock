import Foundation

/// Single accessor for app version information.
///
/// ServerDock/Info.plist CFBundleShortVersionString/CFBundleVersion is the sole version source.
/// Runtime reads the app bundle; packaging reads built Info.plist. Bump versions only in Info.plist.
enum AppInfo {
    /// Display version, e.g. "0.7.6.1".
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    /// Build number, e.g. "18".
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    }

    /// About version line, e.g. "Version 0.7.6.1 (build 18)".
    /// Use generic text if bundle values are unavailable, avoiding a misleading hardcoded version.
    static var versionLine: String {
        guard !version.isEmpty else { return String(localized: "Development Build") }
        return build.isEmpty ? String(localized: "Version \(version)") : String(localized: "Version \(version) (build \(build))")
    }
}

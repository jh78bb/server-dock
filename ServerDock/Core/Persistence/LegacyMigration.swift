import Foundation
import Security

/// ServerDesk-to-ServerDock rename changed bundle ID, data directory, and Keychain service names.
/// Copy legacy data once on first launch, leaving originals intact.
/// ~/Library/Application Support/serverdesk -> serverdock: hosts, snippets, keys, AI history, etc.
/// UserDefaults com.kavaz.serverdesk domain -> current domain.
/// Keychain com.serverdesk.* -> com.serverdock.*; first access may request macOS authorization.
/// Skip in MAS sandbox builds, which cannot read another app's container.
enum LegacyMigration {
    private static let doneKey = "migratedFromServerDesk"
    private static let oldBundleID = "com.kavaz.serverdesk"
    private static let oldSupportName = "serverdesk"
    private static let newSupportName = "serverdock"
    private static let keychainServices: [(old: String, new: String)] = [
        ("com.serverdesk.sshPrivateKeys", "com.serverdock.sshPrivateKeys"),
        ("com.serverdesk.hostPassword", "com.serverdock.hostPassword"),
        ("com.serverdesk.hostPasswords", "com.serverdock.hostPasswords"),
        ("com.serverdesk.sitePasswords", "com.serverdock.sitePasswords"),
    ]

    /// Call once at startup before reading any stores.
    static func runIfNeeded() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: doneKey) else { return }
        #if !SERVERDOCK_MAS
        copySupportDirectory()
        copyPreferences(into: d)
        copyKeychain()
        #endif
        d.set(true, forKey: doneKey)
    }

    private static func copySupportDirectory() {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let old = base.appendingPathComponent(oldSupportName, isDirectory: true)
        let new = base.appendingPathComponent(newSupportName, isDirectory: true)
        guard fm.fileExists(atPath: old.path) else { return }
        if !fm.fileExists(atPath: new.path) { try? fm.copyItem(at: old, to: new); return }
        // If the new folder exists, copy only missing files.
        if let names = try? fm.contentsOfDirectory(atPath: old.path) {
            for n in names where !fm.fileExists(atPath: new.appendingPathComponent(n).path) {
                try? fm.copyItem(at: old.appendingPathComponent(n), to: new.appendingPathComponent(n))
            }
        }
    }

    private static func copyPreferences(into d: UserDefaults) {
        guard let keys = CFPreferencesCopyKeyList(oldBundleID as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String],
              let values = CFPreferencesCopyMultiple(keys as CFArray, oldBundleID as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String: Any] else { return }
        for (k, v) in values where d.object(forKey: k) == nil {
            // Do not migrate system-managed values or Sparkle internals.
            if k.hasPrefix("Apple") || k.hasPrefix("NS") || k.hasPrefix("SU") || k.hasPrefix("com.apple") { continue }
            d.set(v, forKey: k)
        }
    }

    private static func copyKeychain() {
        for (old, new) in keychainServices {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: old,
                kSecMatchLimit as String: kSecMatchLimitAll,
                kSecReturnAttributes as String: true,
                kSecReturnData as String: true,
            ]
            var result: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let items = result as? [[String: Any]] else { continue }
            for item in items {
                guard let data = item[kSecValueData as String] as? Data else { continue }
                var attrs: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: new,
                    kSecValueData as String: data,
                ]
                if let account = item[kSecAttrAccount as String] { attrs[kSecAttrAccount as String] = account }
                if let label = item[kSecAttrLabel as String] { attrs[kSecAttrLabel as String] = label }
                let status = SecItemAdd(attrs as CFDictionary, nil)
                if status == errSecDuplicateItem { continue }   // Never overwrite an existing new item.
            }
        }
    }
}

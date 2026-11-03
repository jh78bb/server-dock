import Foundation
import Security

/// Key metadata JSON at ~/Library/Application Support/serverdock/keys.json, excluding private material; see KeyKeychain.
enum KeyStore {
    private static var dir: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("serverdock", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
    private static var url: URL { dir.appendingPathComponent("keys.json") }

    static func load() -> [SSHKey] {
        guard let data = try? Data(contentsOf: url),
              let keys = try? JSONDecoder().decode([SSHKey].self, from: data) else { return [] }
        return keys
    }

    static func save(_ keys: [SSHKey]) {
        guard !AppEnv.isScreenshotDemo else { return }
        if let data = try? JSONEncoder().encode(keys) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

/// Read/write private material in system Keychain only, never on-disk JSON.
/// Combine private keys as ID-to-PEM in one item to read/authorize once, matching HostKeychain.
enum KeyKeychain {
    private static let service = "com.serverdock.sshPrivateKeys"
    private static let account = "all"

    static func loadAll() -> [String: String] {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return map
    }

    static func saveAll(_ map: [String: String]) {
        guard !AppEnv.isScreenshotDemo else { return }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !map.isEmpty, let data = try? JSONEncoder().encode(map) else { return }
        var q = base
        q[kSecValueData as String] = data
        SecItemAdd(q as CFDictionary, nil)
    }

    static func privateKey(_ id: String) -> String? { loadAll()[id] }

    static func set(_ id: String, _ pem: String) {
        var m = loadAll(); m[id] = pem; saveAll(m)
    }

    static func remove(_ id: String) {
        var m = loadAll(); m.removeValue(forKey: id); saveAll(m)
    }
}

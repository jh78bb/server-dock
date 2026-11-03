import Foundation
import Security

/// Portable server configuration. Connection Codable implementations omit Keychain credentials.
struct HostArchive: Codable {
    var format = "ServerDock.hosts"
    var version = 1
    var hosts: [Host]
    var groups: [String]

    enum ArchiveError: LocalizedError {
        case unsupported, invalidHost
        var errorDescription: String? {
            switch self {
            case .unsupported: return String(localized: "This file is not a supported ServerDock server export.")
            case .invalidHost: return String(localized: "The file contains an invalid server configuration. Nothing was imported.")
            }
        }
    }

    static func encode(hosts: [Host], groups: [String]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(HostArchive(hosts: hosts.filter { !$0.isLocal }, groups: groups))
    }

    static func decode(_ data: Data) throws -> HostArchive {
        let decoder = JSONDecoder()
        // Also accept the app's existing hosts.json as a migration source.
        let archive: HostArchive
        if let legacy = try? decoder.decode([Host].self, from: data) {
            archive = HostArchive(hosts: legacy, groups: [])
        } else {
            archive = try decoder.decode(HostArchive.self, from: data)
        }
        guard archive.format == "ServerDock.hosts", archive.version == 1 else { throw ArchiveError.unsupported }
        for host in archive.hosts where !host.isLocal {
            guard !host.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  (host.ssh != nil) != (host.rdp != nil) else { throw ArchiveError.invalidHost }
            let address = host.ssh?.host ?? host.rdp?.host ?? ""
            let port = host.ssh?.port ?? host.rdp?.port ?? 0
            guard !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  (1...65535).contains(port) else { throw ArchiveError.invalidHost }
        }
        return archive
    }

    /// Keep existing entries intact, including their credentials; never reuse imported IDs.
    func merging(into existing: [Host], knownKeyIDs: Set<String>) -> (hosts: [Host], added: Int, skipped: Int) {
        func signature(_ host: Host) -> [String] {
            if let ssh = host.ssh {
                return [host.name, "ssh", ssh.user, ssh.host.lowercased(), String(ssh.port), ssh.sshCommand]
            }
            if let rdp = host.rdp {
                return [host.name, rdp.protocolType.rawValue, rdp.user, rdp.host.lowercased(), String(rdp.port), rdp.domain]
            }
            return [host.id]
        }
        var signatures = Set(existing.filter { !$0.isLocal }.map(signature))
        var result = existing
        var added = 0, skipped = 0
        for host in hosts where !host.isLocal {
            guard signatures.insert(signature(host)).inserted else { skipped += 1; continue }
            var ssh = host.ssh
            ssh?.password = ""
            if let keyID = ssh?.keyId, !knownKeyIDs.contains(keyID) { ssh?.keyId = "" }
            var rdp = host.rdp
            rdp?.password = ""
            result.append(Host(id: "host-\(UUID().uuidString)", name: host.name, addr: host.addr,
                               group: host.group, status: .unknown, os: host.os, port: host.port,
                               ssh: ssh, notes: host.notes, rdp: rdp, colorHex: host.colorHex))
            added += 1
        }
        return (result, added, skipped)
    }
}

/// Use OpenSSH SSH_ASKPASS without external tools such as sshpass.
/// Pass passwords through SERVERDOCK_SSH_PASSWORD, never embed them in the helper script.
/// SSH_ASKPASS_REQUIRE=force (OpenSSH 8.4+) reads the helper regardless of TTY availability.
enum SSHAskpass {
    static let passwordEnvKey = "SERVERDOCK_SSH_PASSWORD"

    /// Ensure the password-free helper exists/is executable, then return its absolute path.
    private static func ensureHelper() -> String? {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("serverdock", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let url = base.appendingPathComponent("askpass.sh")
        let script = "#!/bin/sh\nprintf '%s\\n' \"$\(passwordEnvKey)\"\n"
        do {
            let current = try? String(contentsOf: url, encoding: .utf8)
            if current != script {
                try script.write(to: url, atomically: true, encoding: .utf8)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch {
            return nil
        }
        return url.path
    }

    /// Environment additions enabling ssh askpass password delivery.
    /// nil means helper creation failed and automatic password input is unavailable.
    static func envVars(password: String) -> [String: String]? {
        guard let helper = ensureHelper() else { return nil }
        return [
            "SSH_ASKPASS": helper,
            "SSH_ASKPASS_REQUIRE": "force",
            passwordEnvKey: password,
        ]
    }
}

/// Host passwords live only in system Keychain, never disk JSON.
/// Combine all host passwords in one combined* Keychain item, reducing authorization from per-host to once overall.
/// Retain old per-host service entries only for migration/cleanup.
enum HostKeychain {
    private static let service = "com.serverdock.hostPassword"            // Legacy: one entry per host.
    private static let combinedService = "com.serverdock.hostPasswords"   // Current: one consolidated entry.
    private static let combinedAccount = "all"

    /// Read all combined passwords with at most one authorization prompt.
    static func loadAll() -> [String: String] {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: combinedService,
            kSecAttrAccount as String: combinedAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return map
    }

    /// Replace the combined entry, deleting it for an empty map.
    /// Upsert instead of delete/add: signing changes can make ACL deny deletion,
    /// then adding silently fails as a duplicate. Updating existing items is more reliable across development signatures.
    static func saveAll(_ map: [String: String]) {
        guard !AppEnv.isScreenshotDemo else { return }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: combinedService,
            kSecAttrAccount as String: combinedAccount,
        ]
        guard !map.isEmpty, let data = try? JSONEncoder().encode(map) else {
            SecItemDelete(base as CFDictionary)   // Remove the entry if all values are empty.
            return
        }
        let updateStatus = SecItemUpdate(base as CFDictionary,
                                         [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            if addStatus != errSecSuccess { NSLog("[Keychain] Failed to save password (add=\(addStatus))") }
        } else if updateStatus != errSecSuccess {
            NSLog("[Keychain] Failed to save password (update=\(updateStatus)) — the Keychain item may have been created by a differently signed build; delete the old item first")
        }
    }

    static func load(_ hostId: String) -> String {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: hostId,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }

    static func delete(_ hostId: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: hostId,
        ]
        SecItemDelete(q as CFDictionary)
    }
}

/// Hosts/session JSON under ~/Library/Application Support/serverdock/.
enum HostStore {
    private static var dir: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("serverdock", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
    private static var hostsURL: URL { dir.appendingPathComponent("hosts.json") }
    private static var hostGroupsURL: URL { dir.appendingPathComponent("host-groups.json") }
    private static var sessionsURL: URL { dir.appendingPathComponent("sessions.json") }
    private static var forwardsURL: URL { dir.appendingPathComponent("forwards.json") }
    private static var favoritesURL: URL { dir.appendingPathComponent("favorites.json") }
    private static var recentsURL: URL { dir.appendingPathComponent("recents.json") }

    static func loadHostGroups() -> [String] {
        guard let data = try? Data(contentsOf: hostGroupsURL),
              let groups = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return groups
    }

    static func saveHostGroups(_ groups: [String]) {
        guard !AppEnv.isScreenshotDemo else { return }
        if let data = try? JSONEncoder().encode(groups) {
            try? data.write(to: hostGroupsURL, options: .atomic)
        }
    }

    static func loadHosts() -> [Host] {
        guard let data = try? Data(contentsOf: hostsURL),
              var hosts = try? JSONDecoder().decode([Host].self, from: data) else { return [] }
        // Fill JSON's omitted passwords from combined Keychain, migrating old per-host items if needed.
        var combined = HostKeychain.loadAll()
        var migrated = false
        for i in hosts.indices {
            let id = hosts[i].id
            var pw = combined[id]
            if pw == nil {
                let legacy = HostKeychain.load(id)   // Fall back to legacy per-host entries.
                if !legacy.isEmpty { pw = legacy; combined[id] = legacy; migrated = true }
            }
            if let pw {
                if hosts[i].ssh != nil { hosts[i].ssh?.password = pw }
                else if hosts[i].rdp != nil { hosts[i].rdp?.password = pw }
            }
        }
        if migrated { HostKeychain.saveAll(combined) }   // Merge legacy entries into the consolidated entry so later access needs only one authorization.
        return hosts
    }

    /// Screenshot mode reads only the selected test server, never Keychain/other hosts.
    static func loadScreenshotHost() -> Host? {
        guard let data = try? Data(contentsOf: hostsURL),
              let hosts = try? JSONDecoder().decode([Host].self, from: data),
              let original = hosts.first(where: { $0.ssh?.user == "hoon" && $0.ssh?.host == "10.1.1.7" }),
              let ssh = original.ssh else { return nil }
        return Host(id: original.id, name: "Demo Workspace", addr: "hoon@10.1.1.7",
                    group: "Live Demo", status: .unknown, os: "Linux",
                    port: original.port, ssh: ssh, colorHex: "#10B981")
    }

    static func saveHosts(_ allHosts: [Host]) {
        guard !AppEnv.isScreenshotDemo else { return }
        let hosts = allHosts.filter { !$0.isLocal }   // Do not persist the synthetic local host.
        // Store combined passwords in Keychain; SSHConnection.CodingKeys excludes password from JSON.
        var pwMap: [String: String] = [:]
        for h in hosts {
            // Ask-mode passwords remain in session memory only and require reentry after restart.
            if let ssh = h.ssh, ssh.authMethod != .ask, !ssh.password.isEmpty { pwMap[h.id] = ssh.password }
            else if let rdp = h.rdp, !rdp.password.isEmpty { pwMap[h.id] = rdp.password }
        }
        HostKeychain.saveAll(pwMap)
        saveHostOrder(hosts)
    }

    /// Reordering updates only the JSON array, leaving Keychain passwords untouched.
    static func saveHostOrder(_ allHosts: [Host]) {
        guard !AppEnv.isScreenshotDemo else { return }
        let hosts = allHosts.filter { !$0.isLocal }
        if let data = try? JSONEncoder().encode(hosts) {
            try? data.write(to: hostsURL, options: .atomic)
        }
    }

    static func loadSessions() -> [SessionEvent] {
        guard let data = try? Data(contentsOf: sessionsURL),
              let s = try? JSONDecoder().decode([SessionEvent].self, from: data) else { return [] }
        return s
    }

    static func saveSessions(_ sessions: [SessionEvent]) {
        guard !AppEnv.isScreenshotDemo else { return }
        if let data = try? JSONEncoder().encode(sessions) {
            try? data.write(to: sessionsURL, options: .atomic)
        }
    }

    static func loadFavorites() -> [String: [FavoritePath]] {
        guard let data = try? Data(contentsOf: favoritesURL),
              let f = try? JSONDecoder().decode([String: [FavoritePath]].self, from: data) else { return [:] }
        return f
    }

    static func saveFavorites(_ favorites: [String: [FavoritePath]]) {
        guard !AppEnv.isScreenshotDemo else { return }
        if let data = try? JSONEncoder().encode(favorites) {
            try? data.write(to: favoritesURL, options: .atomic)
        }
    }

    static func loadRecents() -> [String: [RecentFile]] {
        guard let data = try? Data(contentsOf: recentsURL),
              let r = try? JSONDecoder().decode([String: [RecentFile]].self, from: data) else { return [:] }
        return r
    }

    static func saveRecents(_ recents: [String: [RecentFile]]) {
        guard !AppEnv.isScreenshotDemo else { return }
        if let data = try? JSONEncoder().encode(recents) {
            try? data.write(to: recentsURL, options: .atomic)
        }
    }

    static func loadForwards() -> [ForwardRule] {
        guard let data = try? Data(contentsOf: forwardsURL),
              let f = try? JSONDecoder().decode([ForwardRule].self, from: data) else { return [] }
        return f
    }

    static func saveForwards(_ forwards: [ForwardRule]) {
        guard !AppEnv.isScreenshotDemo else { return }
        if let data = try? JSONEncoder().encode(forwards) {
            try? data.write(to: forwardsURL, options: .atomic)
        }
    }
}

import Foundation
import Security

/// Storage connection separate from SSH hosts for SMB/WebDAV/S3 exploration.
/// Store passwords/secret keys in SiteKeychain, never JSON.
struct Site: Identifiable, Codable, Hashable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case smb, webdav, s3, sftp
        var id: String { rawValue }

        var label: String {
            switch self {
            case .smb: return "SMB"
            case .webdav: return "WebDAV"
            case .s3: return String(localized: "S3 Compatible")
            case .sftp: return "SFTP"
            }
        }
        var symbol: String {
            switch self {
            case .smb: return "externaldrive.connected.to.line.below"
            case .webdav: return "globe"
            case .s3: return "shippingbox"
            case .sftp: return "lock.rectangle.stack"
            }
        }
        var defaultPort: Int {
            switch self {
            case .smb: return 445
            case .webdav: return 443
            case .s3: return 443
            case .sftp: return 22
            }
        }
    }

    let id: String
    var name: String
    var kind: Kind
    /// SMB/WebDAV server host/IP; S3 endpoint such as s3.amazonaws.com/minio.example.com, empty for AWS defaults.
    var host: String
    /// Zero selects protocol/TLS default port.
    var port: Int
    var useTLS: Bool
    /// SMB/WebDAV username or nonsecret S3 Access Key ID, stored here rather than Keychain.
    var username: String
    /// SMB share, WebDAV base path, or S3 bucket; empty bucket lists available buckets.
    var path: String
    /// S3 only.
    var region: String
    /// S3 path-style endpoint/bucket/key when true, virtual bucket.endpoint/key otherwise.
    var pathStyle: Bool
    /// Allow untrusted HTTPS certificates for private NAS/WebDAV/S3 servers.
    var insecureTLS: Bool
    /// SFTP private-key path; empty selects password auth. Keychain value becomes the key passphrase.
    var keyPath: String
    var group: String
    let createdAt: Date

    init(id: String = UUID().uuidString, name: String = "", kind: Kind = .webdav, host: String = "",
         port: Int = 0, useTLS: Bool = true, username: String = "", path: String = "",
         region: String = "us-east-1", pathStyle: Bool = true, insecureTLS: Bool = false, keyPath: String = "", group: String = "", createdAt: Date = Date()) {
        self.id = id; self.name = name; self.kind = kind; self.host = host; self.port = port
        self.useTLS = useTLS; self.username = username; self.path = path; self.region = region
        self.pathStyle = pathStyle; self.insecureTLS = insecureTLS; self.keyPath = keyPath; self.group = group; self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, name, kind, host, port, useTLS, username, path, region, pathStyle, insecureTLS, keyPath, group, createdAt
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        kind = (try? c.decode(Kind.self, forKey: .kind)) ?? .webdav
        host = (try? c.decode(String.self, forKey: .host)) ?? ""
        port = (try? c.decode(Int.self, forKey: .port)) ?? 0
        useTLS = (try? c.decode(Bool.self, forKey: .useTLS)) ?? true
        username = (try? c.decode(String.self, forKey: .username)) ?? ""
        path = (try? c.decode(String.self, forKey: .path)) ?? ""
        region = (try? c.decode(String.self, forKey: .region)) ?? "us-east-1"
        pathStyle = (try? c.decode(Bool.self, forKey: .pathStyle)) ?? true
        insecureTLS = (try? c.decode(Bool.self, forKey: .insecureTLS)) ?? false
        keyPath = (try? c.decode(String.self, forKey: .keyPath)) ?? ""
        group = (try? c.decode(String.self, forKey: .group)) ?? ""
        createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date()
    }

    /// Sidebar connection-summary subtitle.
    var subtitle: String {
        switch kind {
        case .smb: return "smb://\(host)" + (path.isEmpty ? "" : "/\(path)")
        case .webdav: return "\(useTLS ? "https" : "http")://\(host)"
        case .s3: return (path.isEmpty ? "" : "\(path) · ") + (host.isEmpty ? "AWS S3" : host)
        case .sftp: return "sftp://" + (username.isEmpty ? "" : "\(username)@") + host
        }
    }

    var displayGroup: String { group.trimmingCharacters(in: .whitespaces).isEmpty ? String(localized: "Ungrouped") : group }

    /// Distinct TabItem.hostId group prefix avoids collisions with actual Host IDs.
    static let tabPrefix = "site:"
    var tabKey: String { Self.tabPrefix + id }
    static func siteId(fromTabKey key: String?) -> String? {
        guard let key, key.hasPrefix(tabPrefix) else { return nil }
        return String(key.dropFirst(tabPrefix.count))
    }

    var isValid: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch kind {
        case .smb: return !host.trimmingCharacters(in: .whitespaces).isEmpty && !path.trimmingCharacters(in: .whitespaces).isEmpty
        case .webdav: return !host.trimmingCharacters(in: .whitespaces).isEmpty
        case .s3: return !username.trimmingCharacters(in: .whitespaces).isEmpty
        case .sftp: return !host.trimmingCharacters(in: .whitespaces).isEmpty && !username.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }
}

/// Site JSON at ~/Library/Application Support/serverdock/sites.json.
enum SiteStore {
    private static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("serverdock", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("sites.json")
    }

    static func load() -> [Site] {
        guard let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([Site].self, from: data) else { return [] }
        return items
    }

    static func save(_ sites: [Site]) {
        guard !AppEnv.isScreenshotDemo else { return }
        if let data = try? JSONEncoder().encode(sites) { try? data.write(to: url, options: .atomic) }
    }
}

/// Combine site passwords/S3 secrets in one ID-to-string Keychain item for at most one authorization prompt.
enum SiteKeychain {
    private static let service = "com.serverdock.sitePasswords"
    private static let account = "all"
    private static let lock = NSLock()
    private static var cache: [String: String]?

    private static func loadAll() -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        if let cache { return cache }
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        var map: [String: String] = [:]
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data,
           let m = try? JSONDecoder().decode([String: String].self, from: data) { map = m }
        cache = map
        return map
    }

    private static func saveAll(_ map: [String: String]) {
        lock.lock(); cache = map; lock.unlock()
        guard !AppEnv.isScreenshotDemo else { return }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        guard !map.isEmpty, let data = try? JSONEncoder().encode(map) else {
            SecItemDelete(base as CFDictionary); return
        }
        let st = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if st == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let r = SecItemAdd(add as CFDictionary, nil)
            if r != errSecSuccess { NSLog("[SiteKeychain] add failed (\(r))") }
        } else if st != errSecSuccess {
            NSLog("[SiteKeychain] update failed (\(st))")
        }
    }

    static func secret(_ id: String) -> String { loadAll()[id] ?? "" }

    static func set(_ id: String, _ value: String) {
        var m = loadAll()
        if value.isEmpty { m.removeValue(forKey: id) } else { m[id] = value }
        saveAll(m)
    }

    static func remove(_ id: String) { set(id, "") }
}

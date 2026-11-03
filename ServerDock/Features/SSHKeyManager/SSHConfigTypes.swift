import CryptoKit
import Foundation

// MARK: - ~/.ssh/config Host blocks (preserve original formatting/comments)

struct SSHConfigField: Identifiable, Hashable {
    let id: String
    let name: String
    let value: String
    let normalizedName: String   // Lowercase field-name matching for HostName/Port/etc.
}

struct SSHConfigEntry: Identifiable, Hashable {
    let id: String
    let host: String
    let lineNumber: Int
    let fields: [SSHConfigField]
    let sourceFingerprint: String   // Original Host-block hash for locating the same block on writeback.

    var hostName: String { fields.first { $0.normalizedName == "hostname" }?.value ?? host }
    var user: String? { fields.first { $0.normalizedName == "user" }?.value }
    var port: String? { fields.first { $0.normalizedName == "port" }?.value }

    static func fuzzyMatches(query: String, in entry: SSHConfigEntry) -> Bool {
        guard !query.isEmpty else { return true }
        if SSHKeyItem.fuzzyMatch(query: query, in: entry.hostName) { return true }
        if SSHKeyItem.fuzzyMatch(query: query, in: entry.host) { return true }
        if let user = entry.user, SSHKeyItem.fuzzyMatch(query: query, in: user) { return true }
        return entry.fields.contains { SSHKeyItem.fuzzyMatch(query: query, in: $0.value) }
    }
}

/// Editable draft for saving/creating a Host block.
struct SSHConfigHostSaveRequest: Hashable {
    var host: String
    var properties: [SSHConfigHostPropertyValue]

    var trimmedHost: String { host.trimmingCharacters(in: .whitespacesAndNewlines) }
    var writableProperties: [SSHConfigHostPropertyValue] {
        properties.filter {
            !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

struct SSHConfigHostPropertyValue: Identifiable, Hashable {
    let id: UUID
    var name: String
    var value: String
    init(id: UUID = UUID(), name: String, value: String = "") {
        self.id = id; self.name = name; self.value = value
    }
}

/// Common field names/descriptions for Add Field; other custom names can still be entered manually.
struct SSHConfigHostPropertyDefinition: Identifiable, Hashable {
    let name: String
    let comment: String
    var id: String { name }

    static let all: [SSHConfigHostPropertyDefinition] = [
        .init(name: "HostName", comment: String(localized: "Real IP address or DNS name")),
        .init(name: "Port", comment: String(localized: "SSH port, defaults to 22")),
        .init(name: "User", comment: String(localized: "Remote user name")),
        .init(name: "IdentityFile", comment: String(localized: "Private key path")),
        .init(name: "IdentitiesOnly", comment: String(localized: "Use only configured identities")),
        .init(name: "ProxyJump", comment: String(localized: "Jump host chain")),
        .init(name: "ProxyCommand", comment: String(localized: "Command used as proxy")),
        .init(name: "ForwardAgent", comment: String(localized: "Forward ssh-agent")),
        .init(name: "LocalForward", comment: String(localized: "Local port forwarding")),
        .init(name: "RemoteForward", comment: String(localized: "Remote port forwarding")),
        .init(name: "ServerAliveInterval", comment: String(localized: "Keepalive interval in seconds")),
        .init(name: "ServerAliveCountMax", comment: String(localized: "Missed keepalive limit")),
        .init(name: "ConnectTimeout", comment: String(localized: "Connection timeout in seconds")),
        .init(name: "StrictHostKeyChecking", comment: String(localized: "Host key checking mode")),
        .init(name: "PreferredAuthentications", comment: String(localized: "Authentication method order")),
        .init(name: "Compression", comment: String(localized: "Enable compression")),
    ]
    private static let byName = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })
    static func definition(named name: String) -> SSHConfigHostPropertyDefinition {
        byName[name] ?? .init(name: name, comment: String(localized: "Custom SSH config field"))
    }
    static func isValidPropertyName(_ name: String) -> Bool {
        let n = name.lowercased()
        guard n != "host", n != "match", !name.isEmpty else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber }
    }
}

enum SSHConfigHostPropertyIndentation: Int {
    case fourSpaces = 4
    static let `default`: Self = .fourSpaces
    var value: String { String(repeating: " ", count: rawValue) }
}

enum SSHConfigBackupLimit {
    static let minimum = 0, maximum = 5, `default` = 1
    static func clamped(_ n: Int) -> Int { min(max(n, minimum), maximum) }
}

enum SSHConfigManagerError: LocalizedError {
    case emptyHost
    case invalidHost
    case invalidPropertyName(String)
    case invalidPropertyValue(String)
    case hostBlockNotFound
    case configMissing(String)

    var errorDescription: String? {
        switch self {
        case .emptyHost: return String(localized: "Host alias is required.")
        case .invalidHost: return String(localized: "Host alias cannot contain line breaks.")
        case .invalidPropertyName(let n): return String(localized: "\(n) is not a valid SSH config property name.")
        case .invalidPropertyValue(let n): return String(localized: "\(n) value cannot contain line breaks.")
        case .hostBlockNotFound: return String(localized: "The selected Host block could not be found in SSH config.")
        case .configMissing(let path): return String(localized: "SSH config file does not exist at \(path).")
        }
    }
}

// MARK: - known_hosts entries

struct KnownHostEntry: Identifiable, Hashable {
    let id: String
    let hosts: [String]
    let keyType: String
    let publicKey: String
    let comment: String
    let lineNumber: Int
    let sourceLine: String

    var primaryHost: String { hosts.first ?? String(localized: "Unknown host") }
    var displayName: String { hosts.count > 1 ? "\(primaryHost) +\(hosts.count - 1)" : primaryHost }

    /// Actual SHA256 fingerprint: base64-decode the public-key field, then hash, matching [[SSHKeyManagerStore]].
    var fingerprint: String {
        guard let data = Data(base64Encoded: publicKey) else { return "—" }
        let digest = SHA256.hash(data: data)
        let b64 = Data(digest).base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return "SHA256:\(b64)"
    }

    static func fuzzyMatches(query: String, in entry: KnownHostEntry) -> Bool {
        guard !query.isEmpty else { return true }
        return entry.hosts.contains { SSHKeyItem.fuzzyMatch(query: query, in: $0) }
            || SSHKeyItem.fuzzyMatch(query: query, in: entry.keyType)
            || SSHKeyItem.fuzzyMatch(query: query, in: entry.comment)
    }
}

struct KnownHostGroup: Identifiable {
    let id: String
    let entries: [KnownHostEntry]
    var host: String { id }
    var keyCount: Int { entries.count }

    static func group(_ entries: [KnownHostEntry]) -> [KnownHostGroup] {
        Dictionary(grouping: entries, by: \.primaryHost)
            .map { KnownHostGroup(id: $0.key, entries: $0.value.sorted { $0.lineNumber < $1.lineNumber }) }
            .sorted { $0.host.localizedStandardCompare($1.host) == .orderedAscending }
    }
}

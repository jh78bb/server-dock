import Foundation

/// Metadata for actual key files in ~/.ssh or a custom directory.
/// Unlike [[SSHKey]] in Core/Models/SSHKey.swift, which represents Keychain-managed connection credentials,
/// this refers directly to on-disk private/public files managed by SSH Key Manager.
struct SSHKeyItem: Identifiable, Hashable {
    var id: String { filePath }
    let name: String
    let publicKeyPath: String?
    let privateKeyPath: String?
    let filePath: String
    let kind: SSHKeyItemKind
    let type: String            // Display type name: ED25519 / RSA / etc.
    let fingerprint: String
    let comment: String
    let createdAt: Date
    let isPassphraseProtected: Bool

    /// Simple subsequence fuzzy match: all query characters must appear in order in text. Shared by Config/Known Hosts searches
    /// to avoid duplicating similar filtering logic three times.
    static func fuzzyMatch(query: String, in text: String) -> Bool {
        guard !query.isEmpty else { return true }
        let q = query.lowercased(), t = text.lowercased()
        var qi = q.startIndex, ti = t.startIndex
        while qi < q.endIndex, ti < t.endIndex {
            if q[qi] == t[ti] { qi = q.index(after: qi) }
            ti = t.index(after: ti)
        }
        return qi == q.endIndex
    }
}

enum SSHKeyItemKind: Hashable {
    case completePair
    case privateKey
    case publicKey

    var title: String {
        switch self {
        case .completePair: return String(localized: "Complete Pair")
        case .privateKey: return String(localized: "Private Key Only")
        case .publicKey: return String(localized: "Public Key Only")
        }
    }
}

struct SSHKeyGenerationRequest {
    var fileName: String
    var type: SSHKeyGenerationType
    var comment: String
    var passphrase: String
}

/// Generate only ed25519/RSA, matching the in-process serverdock_key_generate engine;
/// ECDSA generation is not implemented there yet.
enum SSHKeyGenerationType: String, CaseIterable, Identifiable {
    case ed25519
    case rsa

    var id: String { rawValue }
    var title: String { self == .ed25519 ? "ED25519" : "RSA 4096" }
    var defaultFileName: String { self == .ed25519 ? "id_ed25519" : "id_rsa" }
}

enum SSHKeyManagerError: LocalizedError {
    case emptyName
    case invalidName
    case nameAlreadyExists(String)
    case noFilesToActOn
    case commentRequiresPublicKey
    case invalidPublicKey
    case passphraseRequiresPrivateKey
    case readOnlyModeEnabled
    case directoryNotFound(String)

    var errorDescription: String? {
        switch self {
        case .emptyName: return String(localized: "The key name cannot be empty.")
        case .invalidName: return String(localized: "Use a file name without path separators.")
        case .nameAlreadyExists(let name): return String(localized: "A file named \(name) already exists.")
        case .noFilesToActOn: return String(localized: "There are no key files to act on.")
        case .commentRequiresPublicKey: return String(localized: "A public key file is required to edit the comment.")
        case .invalidPublicKey: return String(localized: "The public key file is invalid or unreadable.")
        case .passphraseRequiresPrivateKey: return String(localized: "A private key file is required to change the passphrase.")
        case .readOnlyModeEnabled: return String(localized: "Read-only mode is on — turn it off to make changes.")
        case .directoryNotFound(let path): return String(localized: "Directory not found: \(path)")
        }
    }
}

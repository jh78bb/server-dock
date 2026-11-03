import Foundation

/// Key types: recommend compact/fast/secure Ed25519; RSA-4096 supports older servers.
enum SSHKeyType: String, Codable, CaseIterable, Hashable {
    case ed25519
    case rsa

    var label: String { self == .ed25519 ? "Ed25519" : "RSA 4096" }
}

/// Managed SSH key metadata; private material lives in Keychain, never JSON. See KeyKeychain.
struct SSHKey: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    var type: SSHKeyType
    var publicKey: String       // Complete public-key line: ssh-ed25519 AAAA... comment.
    var fingerprint: String     // SHA256:...
    var comment: String
    var hasPassphrase: Bool
    let createdAt: Date

    init(id: String = UUID().uuidString,
         name: String,
         type: SSHKeyType,
         publicKey: String,
         fingerprint: String,
         comment: String = "",
         hasPassphrase: Bool = false,
         createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.type = type
        self.publicKey = publicKey
        self.fingerprint = fingerprint
        self.comment = comment
        self.hasPassphrase = hasPassphrase
        self.createdAt = createdAt
    }
}

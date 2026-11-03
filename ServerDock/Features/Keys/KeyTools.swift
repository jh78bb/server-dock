import Foundation

/// Materialize Keychain private keys into mode-0600 working files, like ~/.ssh/id_* security.
/// Reuse existing files idempotently rather than rewriting per connection; remove alongside deleted keys.
enum KeyMaterializer {
    private static var dir: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("serverdock/keys", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return base
    }

    /// Return the materialized private-key path for a known ID, otherwise nil.
    static func path(forKeyId id: String) -> String? {
        let url = dir.appendingPathComponent(id)
        if !FileManager.default.fileExists(atPath: url.path) {
            guard let pem = KeyKeychain.privateKey(id) else { return nil }
            do {
                try pem.write(to: url, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch { return nil }
        }
        return url.path
    }

    static func remove(_ id: String) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(id))
    }
}

enum KeyError: LocalizedError {
    case generate(String)
    case importFail(String)
    case passphraseChange(String)

    var errorDescription: String? {
        switch self {
        case .generate(let m): return String(localized: "Failed to generate key: \(m)")
        case .importFail(let m): return String(localized: "Failed to import key: \(m)")
        case .passphraseChange(let m): return String(localized: "Failed to change passphrase: \(m)")
        }
    }
}

/// Generate/import through in-process OpenSSL EVP/OpenSSH formats instead of spawning ssh-keygen.
/// Standard formats: ed25519 OpenSSH/bcrypt and RSA OpenSSL PKCS#8 PEM;
/// public keys use ssh-ed25519/ssh-rsa AAAA... comment, verified against system ssh-keygen.
enum KeyTools {
    struct Generated { let publicKey: String; let privateKey: String; let fingerprint: String }
    struct Imported { let publicKey: String; let fingerprint: String; let type: SSHKeyType; let comment: String; let hasPassphrase: Bool }

    /// Generate in-process; empty passphrase leaves keys unencrypted.
    static func generate(type: SSHKeyType, comment: String, passphrase: String) throws -> Generated {
        var priv = [CChar](repeating: 0, count: 1 << 15)
        var pub = [CChar](repeating: 0, count: 4096)
        var fp = [CChar](repeating: 0, count: 256)
        var err = [CChar](repeating: 0, count: 256)
        let t: Int32 = type == .ed25519 ? 0 : 1
        let rc = serverdock_key_generate(t, comment, passphrase, &priv, Int32(priv.count),
                                    &pub, Int32(pub.count), &fp, 256, &err, 256)
        guard rc == 0 else { throw KeyError.generate(String(cString: err)) }
        return Generated(publicKey: String(cString: pub),
                         privateKey: String(cString: priv),
                         fingerprint: String(cString: fp))
    }

    /// Import private files by deriving public key/fingerprint/type/encryption state.
    /// Prefer same-name .pub with comments even for encrypted private keys; otherwise derive from plaintext OpenSSH/unencrypted PEM.
    static func importInfo(privatePath: String) throws -> Imported {
        var pubLine = ""
        let siblingPub = privatePath + ".pub"
        if let s = try? String(contentsOfFile: siblingPub, encoding: .utf8) {
            pubLine = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var outPub = [CChar](repeating: 0, count: 4096)
        var cType: Int32 = 0
        var cEnc: Int32 = 0
        let rc = serverdock_key_pubkey_from_private(privatePath, "", &outPub, Int32(outPub.count), &cType, &cEnc)
        let encrypted = rc == 1 || cEnc != 0    // rc=1: cannot derive from encrypted PEM; cEnc: encrypted OpenSSH, whose public key can still be derived.

        if pubLine.isEmpty {
            guard rc == 0 else {
                throw KeyError.importFail(rc == 1
                    ? String(localized: "The private key is encrypted and has no matching .pub file, so the public key can't be derived. Import it together with its .pub file.")
                    : String(localized: "Couldn't read private key"))
            }
            pubLine = String(cString: outPub)
        }
        guard !pubLine.isEmpty else { throw KeyError.importFail(String(localized: "Couldn't read public key")) }

        var fp = [CChar](repeating: 0, count: 256)
        let fingerprint = serverdock_key_fingerprint(pubLine, &fp, 256) == 0 ? String(cString: fp) : ""

        let type: SSHKeyType = pubLine.hasPrefix("ssh-rsa") ? .rsa
            : (pubLine.hasPrefix("ssh-ed25519") ? .ed25519 : (cType == 1 ? .rsa : .ed25519))
        let comment = pubLine.split(separator: " ").dropFirst(2).joined(separator: " ")
        return Imported(publicKey: pubLine, fingerprint: fingerprint, type: type,
                        comment: comment, hasPassphrase: encrypted)
    }

    /// Change an on-disk passphrase in-process instead of ssh-keygen -p.
    /// Empty oldPassphrase means unencrypted; empty newPassphrase removes encryption.
    /// Support ed25519 OpenSSH and RSA PEM; return private text for caller writeback.
    static func changePassphrase(privatePath: String, oldPassphrase: String, newPassphrase: String) throws -> String {
        var out = [CChar](repeating: 0, count: 1 << 15)
        var err = [CChar](repeating: 0, count: 256)
        let rc = serverdock_key_change_passphrase(privatePath, oldPassphrase, newPassphrase,
                                              &out, Int32(out.count), &err, 256)
        guard rc == 0 else { throw KeyError.passphraseChange(String(cString: err)) }
        return String(cString: out)
    }
}

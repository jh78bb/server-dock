import CryptoKit
import Foundation

/// Direct key-file operations in ~/.ssh or another real directory: scan, edit comments, delete, rename, copy, generate, change passphrase.
/// Use FileManager and in-process [[KeyTools]] crypto without spawning system executables, compatible with App Sandbox.
enum SSHKeyManagerStore {
    static func expandedDirectoryURL(for path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    static func loadKeys(from directoryPath: String) throws -> [SSHKeyItem] {
        let directoryURL = expandedDirectoryURL(for: directoryPath)
        guard FileManager.default.fileExists(atPath: directoryURL.path) else {
            throw SSHKeyManagerError.directoryNotFound(directoryURL.path)
        }
        let fileURLs = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .creationDateKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles])
        let regularFileURLs = fileURLs.filter(isRegularFile)

        var pairedPublic = Set<String>(), pairedPrivate = Set<String>()
        let completePairs = regularFileURLs.compactMap { privateKeyURL -> SSHKeyItem? in
            guard privateKeyURL.pathExtension != "pub" else { return nil }
            let publicKeyURL = privateKeyURL.appendingPathExtension("pub")
            guard let item = completePairItem(privateKeyURL: privateKeyURL, publicKeyURL: publicKeyURL) else { return nil }
            pairedPrivate.insert(privateKeyURL.path)
            pairedPublic.insert(publicKeyURL.path)
            return item
        }
        let otherKeys = regularFileURLs.compactMap { fileURL -> SSHKeyItem? in
            guard !pairedPrivate.contains(fileURL.path), !pairedPublic.contains(fileURL.path) else { return nil }
            return standaloneKeyItem(for: fileURL)
        }
        return (completePairs + otherKeys).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func delete(_ key: SSHKeyItem) throws {
        for path in pathsToDelete(key) {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    static func updateComment(for key: SSHKeyItem, comment: String) throws {
        guard let publicKeyPath = key.publicKeyPath else { throw SSHKeyManagerError.commentRequiresPublicKey }
        let publicKeyURL = URL(fileURLWithPath: publicKeyPath)
        guard let contents = try? String(contentsOf: publicKeyURL, encoding: .utf8),
              let line = contents.split(whereSeparator: \.isNewline).first else {
            throw SSHKeyManagerError.invalidPublicKey
        }
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { throw SSHKeyManagerError.invalidPublicKey }
        let normalized = comment.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let updated = normalized.isEmpty ? "\(parts[0]) \(parts[1])" : "\(parts[0]) \(parts[1]) \(normalized)"
        try "\(updated)\n".write(to: publicKeyURL, atomically: true, encoding: .utf8)
    }

    /// Empty oldPassphrase/newPassphrase means currently unencrypted/remove encryption, respectively.
    static func changePassphrase(for key: SSHKeyItem, oldPassphrase: String, newPassphrase: String) throws {
        guard let privateKeyPath = key.privateKeyPath else { throw SSHKeyManagerError.passphraseRequiresPrivateKey }
        let newPrivateText = try KeyTools.changePassphrase(privatePath: privateKeyPath,
                                                           oldPassphrase: oldPassphrase, newPassphrase: newPassphrase)
        try newPrivateText.write(toFile: privateKeyPath, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: privateKeyPath)
    }

    static func rename(_ key: SSHKeyItem, to newName: String) throws -> String {
        try moveOrCopy(key, to: newName, copy: false)
    }

    static func duplicate(_ key: SSHKeyItem, to newName: String) throws -> String {
        try moveOrCopy(key, to: newName, copy: true)
    }

    /// Generate files <fileName> and <fileName>.pub with modes 0600/0644, returning the private-path key ID.
    static func generateKey(_ request: SSHKeyGenerationRequest, in directoryPath: String) throws -> String {
        let normalizedName = try normalizedGeneratedKeyName(request.fileName)
        let directoryURL = try preparedDirectoryURL(for: directoryPath)
        let privateKeyURL = directoryURL.appendingPathComponent(normalizedName)
        let publicKeyURL = privateKeyURL.appendingPathExtension("pub")
        guard !FileManager.default.fileExists(atPath: privateKeyURL.path) else {
            throw SSHKeyManagerError.nameAlreadyExists(privateKeyURL.lastPathComponent)
        }
        guard !FileManager.default.fileExists(atPath: publicKeyURL.path) else {
            throw SSHKeyManagerError.nameAlreadyExists(publicKeyURL.lastPathComponent)
        }

        let sshType: SSHKeyType = request.type == .ed25519 ? .ed25519 : .rsa
        let generated = try KeyTools.generate(type: sshType, comment: request.comment, passphrase: request.passphrase)
        do {
            try generated.privateKey.write(to: privateKeyURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: privateKeyURL.path)
            try (generated.publicKey + "\n").write(to: publicKeyURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: publicKeyURL.path)
        } catch {
            try? FileManager.default.removeItem(at: privateKeyURL)
            try? FileManager.default.removeItem(at: publicKeyURL)
            throw error
        }
        return privateKeyURL.path
    }

    static func availableKeyName(for baseName: String, in directoryPath: String) -> String {
        guard let normalizedBase = try? normalizedGeneratedKeyName(baseName) else { return baseName }
        let existing = (try? existingFileNames(in: directoryPath)) ?? []
        var candidate = normalizedBase, suffix = 1
        while existing.contains(candidate) || existing.contains("\(candidate).pub") {
            candidate = "\(normalizedBase)_\(suffix)"; suffix += 1
        }
        return candidate
    }

    // MARK: - Internals

    private static func existingFileNames(in directoryPath: String) throws -> Set<String> {
        let directoryURL = expandedDirectoryURL(for: directoryPath)
        let fileURLs = try FileManager.default.contentsOfDirectory(
            at: directoryURL, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        return Set(fileURLs.filter(isRegularFile).map(\.lastPathComponent))
    }

    private static func preparedDirectoryURL(for path: String) throws -> URL {
        let directoryURL = expandedDirectoryURL(for: path)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw SSHKeyManagerError.directoryNotFound(directoryURL.path) }
            return directoryURL
        }
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return directoryURL
    }

    private static func normalizedKeyName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SSHKeyManagerError.emptyName }
        guard trimmed.rangeOfCharacter(from: CharacterSet(charactersIn: "/:")) == nil,
              trimmed != ".", trimmed != ".." else { throw SSHKeyManagerError.invalidName }
        return trimmed
    }

    private static func normalizedGeneratedKeyName(_ name: String) throws -> String {
        let normalized = try normalizedKeyName(name)
        guard !normalized.hasSuffix(".pub") else { throw SSHKeyManagerError.invalidName }
        return normalized
    }

    private static func pathsToDelete(_ key: SSHKeyItem) -> [String] {
        switch key.kind {
        case .completePair: return [key.privateKeyPath, key.publicKeyPath].compactMap { $0 }
        case .privateKey, .publicKey: return [key.filePath]
        }
    }

    private static func moveOrCopy(_ key: SSHKeyItem, to newName: String, copy: Bool) throws -> String {
        let normalizedName = try normalizedKeyName(newName)
        let sourcePaths = pathsToDelete(key)   // Paths belonging to one key group that must be renamed/copied together.
        guard !sourcePaths.isEmpty else { throw SSHKeyManagerError.noFilesToActOn }

        let primaryURL = URL(fileURLWithPath: key.filePath)
        let targetDirectoryURL = primaryURL.deletingLastPathComponent()
        let primaryTargetName = (key.kind == .publicKey && !normalizedName.hasSuffix(".pub"))
            ? "\(normalizedName).pub" : normalizedName
        let targetPrimaryURL = targetDirectoryURL.appendingPathComponent(primaryTargetName)

        let sourceURLs = sourcePaths.map(URL.init(fileURLWithPath:))
        let targetURLs: [URL] = key.kind == .completePair
            ? [targetPrimaryURL, targetPrimaryURL.appendingPathExtension("pub")]
            : [targetPrimaryURL]

        guard Set(targetURLs.map(\.path)).count == targetURLs.count else { throw SSHKeyManagerError.invalidName }
        for (sourceURL, targetURL) in zip(sourceURLs, targetURLs) {
            guard FileManager.default.fileExists(atPath: sourceURL.path) else { throw SSHKeyManagerError.noFilesToActOn }
            if copy || sourceURL.path != targetURL.path {
                guard !FileManager.default.fileExists(atPath: targetURL.path) else {
                    throw SSHKeyManagerError.nameAlreadyExists(targetURL.lastPathComponent)
                }
            }
        }

        var done: [(URL, URL)] = []
        do {
            for (sourceURL, targetURL) in zip(sourceURLs, targetURLs) where sourceURL.path != targetURL.path {
                if copy {
                    try FileManager.default.copyItem(at: sourceURL, to: targetURL)
                } else {
                    try FileManager.default.moveItem(at: sourceURL, to: targetURL)
                }
                done.append((sourceURL, targetURL))
            }
            return targetPrimaryURL.path
        } catch {
            for (sourceURL, targetURL) in done.reversed() where FileManager.default.fileExists(atPath: targetURL.path) {
                if copy { try? FileManager.default.removeItem(at: targetURL) }
                else { try? FileManager.default.moveItem(at: targetURL, to: sourceURL) }
            }
            throw error
        }
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return false }
        return true
    }

    private static func completePairItem(privateKeyURL: URL, publicKeyURL: URL) -> SSHKeyItem? {
        guard let priv = readPrivateKeyMetadata(at: privateKeyURL), let pub = readPublicKey(at: publicKeyURL) else { return nil }
        return SSHKeyItem(name: privateKeyURL.lastPathComponent, publicKeyPath: publicKeyURL.path,
                          privateKeyPath: privateKeyURL.path, filePath: privateKeyURL.path, kind: .completePair,
                          type: displayName(for: pub.type), fingerprint: pub.fingerprint, comment: pub.comment,
                          createdAt: creationDate(for: privateKeyURL), isPassphraseProtected: priv.isPassphraseProtected)
    }

    private static func standaloneKeyItem(for fileURL: URL) -> SSHKeyItem? {
        if fileURL.pathExtension == "pub", let pub = readPublicKey(at: fileURL) {
            return SSHKeyItem(name: fileURL.lastPathComponent, publicKeyPath: fileURL.path, privateKeyPath: nil,
                              filePath: fileURL.path, kind: .publicKey, type: displayName(for: pub.type),
                              fingerprint: pub.fingerprint, comment: pub.comment,
                              createdAt: creationDate(for: fileURL), isPassphraseProtected: false)
        }
        guard let priv = readPrivateKeyMetadata(at: fileURL) else { return nil }
        return SSHKeyItem(name: fileURL.lastPathComponent, publicKeyPath: nil, privateKeyPath: fileURL.path,
                          filePath: fileURL.path, kind: .privateKey, type: priv.type,
                          fingerprint: String(localized: "Unavailable"), comment: String(localized: "No public key"),
                          createdAt: creationDate(for: fileURL), isPassphraseProtected: priv.isPassphraseProtected)
    }

    private struct PublicKeyInfo { let type: String; let comment: String; let fingerprint: String }
    private static func readPublicKey(at url: URL) -> PublicKeyInfo? {
        guard let contents = try? String(contentsOf: url, encoding: .utf8),
              let line = contents.split(whereSeparator: \.isNewline).first else { return nil }
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2, isSupportedPublicKeyType(String(parts[0])),
              let keyData = Data(base64Encoded: String(parts[1])) else { return nil }
        let comment = parts.dropFirst(2).joined(separator: " ")
        let digest = SHA256.hash(data: keyData)
        let b64 = Data(digest).base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return PublicKeyInfo(type: String(parts[0]), comment: comment.isEmpty ? String(localized: "No comment") : comment,
                             fingerprint: "SHA256:\(b64)")
    }

    private struct PrivateKeyMetadata { let type: String; let isPassphraseProtected: Bool }
    private static func readPrivateKeyMetadata(at url: URL) -> PrivateKeyMetadata? {
        guard let contents = try? String(contentsOf: url, encoding: .utf8),
              !contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let type: String
        if contents.contains("-----BEGIN OPENSSH PRIVATE KEY-----") { type = "OpenSSH Private Key" }
        else if contents.contains("-----BEGIN RSA PRIVATE KEY-----") { type = "RSA Private Key" }
        else if contents.contains("-----BEGIN EC PRIVATE KEY-----") { type = "EC Private Key" }
        else if contents.contains("-----BEGIN PRIVATE KEY-----") { type = "Private Key" }
        else { return nil }
        var encrypted = contents.contains("-----BEGIN ENCRYPTED PRIVATE KEY-----")
            || contents.contains("Proc-Type: 4,ENCRYPTED")
            || contents.contains("DEK-Info:")
        if contents.contains("-----BEGIN OPENSSH PRIVATE KEY-----") {
            // Read OpenSSH ciphername to detect encryption accurately; reuse the verified C parser without needing a passphrase.
            var outPub = [CChar](repeating: 0, count: 4096)
            var cType: Int32 = 0, cEnc: Int32 = 0
            _ = serverdock_key_pubkey_from_private(url.path, "", &outPub, Int32(outPub.count), &cType, &cEnc)
            encrypted = cEnc != 0
        }
        return PrivateKeyMetadata(type: type, isPassphraseProtected: encrypted)
    }

    private static func isSupportedPublicKeyType(_ type: String) -> Bool {
        type == "ssh-ed25519" || type == "ssh-rsa" || type.hasPrefix("ecdsa-") || type.hasPrefix("sk-")
    }

    private static func displayName(for type: String) -> String {
        switch type {
        case "ssh-ed25519": return "ED25519"
        case "ssh-rsa": return "RSA"
        case let v where v.hasPrefix("ecdsa-"): return "ECDSA"
        default: return type
        }
    }

    private static func creationDate(for url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey]))
            .flatMap { $0.creationDate ?? $0.contentModificationDate } ?? .now
    }
}

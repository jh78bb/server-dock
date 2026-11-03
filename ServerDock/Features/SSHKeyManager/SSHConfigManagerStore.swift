import Foundation

enum SSHConfigMutation {
    case add(SSHConfigHostSaveRequest)
    case update(entry: SSHConfigEntry, request: SSHConfigHostSaveRequest)
    case delete(entry: SSHConfigEntry)
}

/// Read/write ~/.ssh/config: locate Host blocks, render replacement blocks, and back up before writing when needed.
/// Use FileManager/string operations without system executables, ported from SSH Keys Manager's
/// SSHConfigWriter/SSHConfigDocument/SSHConfigStorage and simplified by removing actor/protocol abstractions,
/// using static functions consistently with [[SSHKeyManagerStore]].
enum SSHConfigManagerStore {
    static func configURL(for directoryPath: String) -> URL {
        SSHKeyManagerStore.expandedDirectoryURL(for: directoryPath).appendingPathComponent("config")
    }

    static func loadEntries(from directoryPath: String) throws -> [SSHConfigEntry] {
        try SSHConfigParser.loadEntries(from: directoryPath)
    }

    static func addHost(_ request: SSHConfigHostSaveRequest, inDirectory directoryPath: String,
                        backupLimit: Int = SSHConfigBackupLimit.default) throws {
        try apply(.add(request), inDirectory: directoryPath, backupLimit: backupLimit)
    }

    static func replaceHost(_ entry: SSHConfigEntry, with request: SSHConfigHostSaveRequest,
                            inDirectory directoryPath: String,
                            backupLimit: Int = SSHConfigBackupLimit.default) throws {
        try apply(.update(entry: entry, request: request), inDirectory: directoryPath, backupLimit: backupLimit)
    }

    static func deleteHost(_ entry: SSHConfigEntry, inDirectory directoryPath: String,
                           backupLimit: Int = SSHConfigBackupLimit.default) throws {
        try apply(.delete(entry: entry), inDirectory: directoryPath, backupLimit: backupLimit)
    }

    // MARK: - Internals

    private static func apply(_ mutation: SSHConfigMutation, inDirectory directoryPath: String, backupLimit: Int) throws {
        let configURL = configURL(for: directoryPath)
        let indentation = SSHConfigHostPropertyIndentation.default

        switch mutation {
        case .add:
            if !FileManager.default.fileExists(atPath: configURL.path) {
                let directoryURL = SSHKeyManagerStore.expandedDirectoryURL(for: directoryPath)
                var isDirectory: ObjCBool = false
                if !FileManager.default.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory) {
                    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true,
                                                            attributes: [.posixPermissions: 0o700])
                }
            }
        case .update, .delete:
            guard FileManager.default.fileExists(atPath: configURL.path) else {
                throw SSHConfigManagerError.configMissing(configURL.path)
            }
        }

        let existingContents = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        let lineEnding = preferredLineEnding(for: existingContents)
        let snapshot = SSHConfigParser.parseDocument(existingContents, configPath: configURL.path)
        let updatedSnapshot = try applying(mutation, to: snapshot, configPath: configURL.path,
                                           lineEnding: lineEnding, indentation: indentation)
        let updatedContents = updatedSnapshot.renderedContents(normalizingHostIndentation: true, propertyIndent: indentation.value)

        try createBackupIfNeeded(for: configURL, limit: backupLimit)
        try updatedContents.write(to: configURL, atomically: true, encoding: .utf8)
    }

    private static func applying(_ mutation: SSHConfigMutation, to snapshot: SSHConfigDocumentSnapshot,
                                 configPath: String, lineEnding: String,
                                 indentation: SSHConfigHostPropertyIndentation) throws -> SSHConfigDocumentSnapshot {
        switch mutation {
        case .add(let request):
            let rendered = try renderedEntry(for: request, lineEnding: lineEnding, indentation: indentation)
            return try appendingHost(rendered, to: snapshot, configPath: configPath, lineEnding: lineEnding)
        case .update(let entry, let request):
            let rendered = try renderedEntry(for: request, lineEnding: lineEnding, indentation: indentation)
            return try replacingHost(matching: entry, with: rendered, in: snapshot, configPath: configPath)
        case .delete(let entry):
            return try removingHost(matching: entry, from: snapshot)
        }
    }

    private static func renderedEntry(for request: SSHConfigHostSaveRequest, lineEnding: String,
                                      indentation: SSHConfigHostPropertyIndentation) throws -> String {
        let host = request.trimmedHost
        guard !host.isEmpty else { throw SSHConfigManagerError.emptyHost }
        guard !host.contains(where: \.isNewline) else { throw SSHConfigManagerError.invalidHost }

        var lines = ["Host \(host)"]
        for property in request.writableProperties {
            let name = property.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = property.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard SSHConfigHostPropertyDefinition.isValidPropertyName(name) else {
                throw SSHConfigManagerError.invalidPropertyName(name)
            }
            guard !value.contains(where: \.isNewline) else { throw SSHConfigManagerError.invalidPropertyValue(name) }
            lines.append("\(indentation.value)\(name) \(value)")
        }
        return lines.joined(separator: lineEnding) + lineEnding
    }

    private static func appendingHost(_ rendered: String, to snapshot: SSHConfigDocumentSnapshot,
                                      configPath: String, lineEnding: String) throws -> SSHConfigDocumentSnapshot {
        let block = try hostBlock(from: rendered, configPath: configPath)
        var segments = snapshot.segments
        let separator = appendSeparator(for: snapshot.renderedContents(), lineEnding: lineEnding)
        if !separator.isEmpty { segments.append(.text(separator)) }
        segments.append(.host(block))
        return SSHConfigDocumentSnapshot(segments: segments)
    }

    private static func replacingHost(matching entry: SSHConfigEntry, with rendered: String,
                                      in snapshot: SSHConfigDocumentSnapshot,
                                      configPath: String) throws -> SSHConfigDocumentSnapshot {
        let block = try hostBlock(from: rendered, configPath: configPath)
        let index = try matchingHostIndex(for: entry, in: snapshot)
        var segments = snapshot.segments
        segments[index] = .host(block)
        return SSHConfigDocumentSnapshot(segments: segments)
    }

    private static func removingHost(matching entry: SSHConfigEntry,
                                     from snapshot: SSHConfigDocumentSnapshot) throws -> SSHConfigDocumentSnapshot {
        let index = try matchingHostIndex(for: entry, in: snapshot)
        var segments = snapshot.segments
        segments.remove(at: index)
        return SSHConfigDocumentSnapshot(segments: mergeAdjacentTextSegments(segments))
    }

    private static func matchingHostIndex(for entry: SSHConfigEntry, in snapshot: SSHConfigDocumentSnapshot) throws -> Int {
        let fingerprintMatches = snapshot.segments.indices.filter {
            if case .host(let b) = snapshot.segments[$0] { return b.entry.host == entry.host && b.entry.sourceFingerprint == entry.sourceFingerprint }
            return false
        }
        switch fingerprintMatches.count {
        case 1: return fingerprintMatches[0]
        case 0: throw SSHConfigManagerError.hostBlockNotFound
        default:
            let lineMatches = fingerprintMatches.filter {
                if case .host(let b) = snapshot.segments[$0] { return b.entry.lineNumber == entry.lineNumber }
                return false
            }
            guard lineMatches.count == 1 else { throw SSHConfigManagerError.hostBlockNotFound }
            return lineMatches[0]
        }
    }

    private static func hostBlock(from rendered: String, configPath: String) throws -> SSHConfigHostBlockSnapshot {
        let snapshot = SSHConfigParser.parseDocument(rendered, configPath: configPath)
        guard snapshot.segments.count == 1, case .host(let block) = snapshot.segments[0] else {
            throw SSHConfigManagerError.hostBlockNotFound
        }
        return block
    }

    private static func mergeAdjacentTextSegments(_ segments: [SSHConfigDocumentSegment]) -> [SSHConfigDocumentSegment] {
        var merged: [SSHConfigDocumentSegment] = []
        for segment in segments {
            if case .some(.text(let prev)) = merged.last, case .text(let next) = segment {
                merged.removeLast(); merged.append(.text(prev + next))
            } else {
                merged.append(segment)
            }
        }
        return merged
    }

    private static func appendSeparator(for existingContents: String, lineEnding: String) -> String {
        guard !existingContents.isEmpty else { return "" }
        let trailing = existingContents.reversed().prefix(while: { $0 == "\n" }).count
        if trailing >= 2 { return "" }
        if trailing == 1 { return lineEnding }
        return lineEnding + lineEnding
    }

    private static func preferredLineEnding(for contents: String) -> String {
        if contents.contains("\r\n") { return "\r\n" }
        if contents.contains("\r") { return "\r" }
        return "\n"
    }

    private static func createBackupIfNeeded(for configURL: URL, limit: Int) throws {
        let clamped = SSHConfigBackupLimit.clamped(limit)
        guard clamped > 0, FileManager.default.fileExists(atPath: configURL.path) else { return }
        let fm = FileManager.default
        func backupURL(_ i: Int) -> URL { configURL.deletingLastPathComponent().appendingPathComponent("\(configURL.lastPathComponent).backup.\(i)") }
        for i in stride(from: SSHConfigBackupLimit.maximum, to: clamped, by: -1) where fm.fileExists(atPath: backupURL(i).path) {
            try fm.removeItem(at: backupURL(i))
        }
        if fm.fileExists(atPath: backupURL(clamped).path) { try fm.removeItem(at: backupURL(clamped)) }
        guard clamped > 1 else { try fm.copyItem(at: configURL, to: backupURL(1)); return }
        for i in stride(from: clamped - 1, through: 1, by: -1) where fm.fileExists(atPath: backupURL(i).path) {
            try fm.moveItem(at: backupURL(i), to: backupURL(i + 1))
        }
        try fm.copyItem(at: configURL, to: backupURL(1))
    }
}

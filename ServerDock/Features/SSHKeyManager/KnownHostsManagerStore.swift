import Foundation

/// Read/write known_hosts through FileManager: parse, append, and delete lines without system executables.
/// Ported from SSH Keys Manager KnownHostsStorage, using static functions instead of an actor to match [[SSHKeyManagerStore]].
enum KnownHostsManagerStore {
    static func fileURL(in directoryPath: String) -> URL {
        SSHKeyManagerStore.expandedDirectoryURL(for: directoryPath).appendingPathComponent("known_hosts")
    }

    static func loadEntries(from directoryPath: String) throws -> [KnownHostEntry] {
        let url = fileURL(in: directoryPath)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let contents = try String(contentsOf: url, encoding: .utf8)
        return contents.split(separator: "\n", omittingEmptySubsequences: false).enumerated().compactMap { index, line in
            parse(String(line), lineNumber: index + 1)
        }
    }

    static func delete(_ entry: KnownHostEntry, inDirectory directoryPath: String) throws {
        try delete([entry], inDirectory: directoryPath)
    }

    /// Delete all rows for a host/IP together: first mark original line indices, falling back to full-line matching if indices differ.
    /// Rewrite once after marking to avoid index shifts causing missed/incorrect deletions.
    static func delete(_ entries: [KnownHostEntry], inDirectory directoryPath: String) throws {
        guard !entries.isEmpty else { return }
        let url = fileURL(in: directoryPath)
        var lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines)
        var toRemove = Set<Int>()   // Zero-based line indices to delete.
        var remainingBySourceLine: [String: Int] = [:]   // Number of candidates matched by full text when line indices differ.

        for entry in entries {
            let index = entry.lineNumber - 1
            if index >= 0, index < lines.count, lines[index] == entry.sourceLine, !toRemove.contains(index) {
                toRemove.insert(index)
            } else {
                remainingBySourceLine[entry.sourceLine, default: 0] += 1
            }
        }
        for (sourceLine, count) in remainingBySourceLine {
            var matched = 0
            for (index, line) in lines.enumerated() where line == sourceLine && !toRemove.contains(index) {
                toRemove.insert(index)
                matched += 1
                if matched == count { break }
            }
        }

        guard !toRemove.isEmpty else { return }
        let kept = lines.enumerated().filter { !toRemove.contains($0.offset) }.map(\.element)
        try kept.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private static func parse(_ line: String, lineNumber: Int) -> KnownHostEntry? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix("@") else { return nil }
        let parts = trimmed.split(whereSeparator: { $0.isWhitespace })
        guard parts.count >= 3 else { return nil }
        let hosts = parts[0].split(separator: ",").map(String.init)
        return KnownHostEntry(id: "line:\(lineNumber)", hosts: hosts, keyType: String(parts[1]), publicKey: String(parts[2]),
                              comment: parts.dropFirst(3).joined(separator: " "), lineNumber: lineNumber, sourceLine: line)
    }
}

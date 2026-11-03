import CryptoKit
import Foundation

/// Lossless ~/.ssh/config parser splits Host blocks from intervening original text, rewriting only changed fragments
/// and preserving comments/blank lines/indentation. Ported unchanged from SSHConfigParser using Foundation only.
enum SSHConfigParser {
    static func loadEntries(from directoryPath: String) throws -> [SSHConfigEntry] {
        let configURL = SSHConfigManagerStore.configURL(for: directoryPath)
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            throw SSHConfigManagerError.configMissing(configURL.path)
        }
        let contents = try String(contentsOf: configURL, encoding: .utf8)
        return parseDocument(contents, configPath: configURL.path).entries
    }

    static func parseDocument(_ contents: String, configPath: String) -> SSHConfigDocumentSnapshot {
        let lines = SSHConfigLineRecord.split(contents)
        var segments: [SSHConfigDocumentSegment] = []
        var textBuffer = ""
        var current: PartialSSHConfigHostBlockSnapshot?

        func flushTextBuffer() {
            guard !textBuffer.isEmpty else { return }
            segments.append(.text(textBuffer)); textBuffer = ""
        }
        func appendBlock(_ block: PartialSSHConfigHostBlockSnapshot) {
            guard let snapshot = block.snapshot(configPath: configPath) else { return }
            segments.append(.host(snapshot))
        }
        func transitionOutOfBlock() {
            guard let current else { return }
            appendBlock(current); textBuffer += current.pendingTrailingTrivia
        }

        for line in lines {
            let directive = SSHConfigDirective(line.content)
            if var activeBlock = current {
                if directive?.key == "host" || directive?.key == "match" {
                    transitionOutOfBlock(); current = nil
                    if directive?.key == "host" {
                        flushTextBuffer()
                        current = PartialSSHConfigHostBlockSnapshot(host: directive?.value ?? "",
                                                                    lineNumber: line.number, firstLine: line.rawText)
                    } else {
                        textBuffer += line.rawText
                    }
                    continue
                }
                if line.isTrivia {
                    current = activeBlock.appendingPendingTrivia(line.rawText)
                    continue
                }
                activeBlock = activeBlock.confirmPendingTrivia()
                activeBlock.append(line.rawText)
                if let directive { activeBlock.apply(directive) }
                current = activeBlock
                continue
            }
            guard let directive, directive.key == "host" else { textBuffer += line.rawText; continue }
            flushTextBuffer()
            current = PartialSSHConfigHostBlockSnapshot(host: directive.value, lineNumber: line.number, firstLine: line.rawText)
        }
        if let current { appendBlock(current); textBuffer += current.pendingTrailingTrivia }
        flushTextBuffer()
        return SSHConfigDocumentSnapshot(segments: segments)
    }
}

struct SSHConfigDocumentSnapshot: Equatable {
    var segments: [SSHConfigDocumentSegment]

    var entries: [SSHConfigEntry] {
        segments.compactMap { if case .host(let b) = $0 { b.entry } else { nil } }
    }

    func renderedContents(normalizingHostIndentation: Bool = false,
                          propertyIndent: String = SSHConfigHostPropertyIndentation.default.value) -> String {
        segments.map { $0.renderedRawText(normalizingHostIndentation: normalizingHostIndentation, propertyIndent: propertyIndent) }
            .joined()
    }
}

enum SSHConfigDocumentSegment: Equatable {
    case text(String)
    case host(SSHConfigHostBlockSnapshot)

    var rawText: String {
        switch self { case .text(let t): t; case .host(let b): b.rawText }
    }
    func renderedRawText(normalizingHostIndentation: Bool, propertyIndent: String) -> String {
        switch self {
        case .text(let t): return t
        case .host(let b):
            guard normalizingHostIndentation else { return b.rawText }
            return b.normalizedRawText(propertyIndent: propertyIndent)
        }
    }
}

struct SSHConfigHostBlockSnapshot: Equatable {
    let entry: SSHConfigEntry
    let rawText: String

    func normalizedRawText(propertyIndent: String) -> String {
        SSHConfigLineRecord.split(rawText).enumerated().map { index, line in
            guard index > 0, !line.isTrivia, let directive = SSHConfigDirective(line.content),
                  directive.key != "host", directive.key != "match" else { return line.rawText }
            let contentWithoutLeadingWhitespace = String(line.content.drop(while: { $0 == " " || $0 == "\t" }))
            return propertyIndent + contentWithoutLeadingWhitespace + line.lineEnding
        }.joined()
    }
}

struct SSHConfigDirective {
    let key: String, name: String, value: String
    init?(_ rawLine: String) {
        let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        let parts = trimmed.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
        guard parts.count == 2 else { return nil }
        key = parts[0].lowercased(); name = String(parts[0]); value = String(parts[1]).trimmingCharacters(in: .whitespaces)
    }
}

private struct PartialSSHConfigHostBlockSnapshot {
    let host: String
    let lineNumber: Int
    private(set) var rawText: String
    private(set) var pendingTrailingTrivia: String
    var fields: [SSHConfigField]

    init(host: String, lineNumber: Int, firstLine: String) {
        self.host = host; self.lineNumber = lineNumber; rawText = firstLine; pendingTrailingTrivia = ""
        fields = [SSHConfigField(id: "\(lineNumber):host", name: "Host", value: host, normalizedName: "host")]
    }
    mutating func append(_ text: String) { rawText += text }
    func appendingPendingTrivia(_ text: String) -> Self { var c = self; c.pendingTrailingTrivia += text; return c }
    func confirmPendingTrivia() -> Self { var c = self; c.rawText += c.pendingTrailingTrivia; c.pendingTrailingTrivia = ""; return c }
    mutating func apply(_ directive: SSHConfigDirective) {
        fields.append(SSHConfigField(id: "\(lineNumber):\(fields.count):\(directive.key)",
                                     name: directive.name, value: directive.value, normalizedName: directive.key))
    }
    func snapshot(configPath: String) -> SSHConfigHostBlockSnapshot? {
        guard !host.isEmpty else { return nil }
        let fingerprint = SHA256Hex(rawText)
        let entry = SSHConfigEntry(id: "\(configPath):\(lineNumber):\(host)", host: host, lineNumber: lineNumber,
                                   fields: fields, sourceFingerprint: fingerprint)
        return SSHConfigHostBlockSnapshot(entry: entry, rawText: rawText)
    }
}

/// SHA256 hex digest of the original block, used only to locate it when writing back.
private func SHA256Hex(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

struct SSHConfigLineRecord: Equatable {
    let number: Int
    let content: String
    let lineEnding: String

    var rawText: String { content + lineEnding }
    var isBlank: Bool { content.trimmingCharacters(in: .whitespaces).isEmpty }
    var isComment: Bool {
        let t = content.trimmingCharacters(in: .whitespaces)
        return !t.isEmpty && t.hasPrefix("#")
    }
    var isTrivia: Bool { isBlank || isComment }

    static func split(_ contents: String) -> [SSHConfigLineRecord] {
        guard !contents.isEmpty else { return [] }
        let ns = contents as NSString
        var lines: [SSHConfigLineRecord] = []
        var lineNumber = 1, location = 0
        while location < ns.length {
            let contentStart = location
            while location < ns.length {
                let scalar = ns.character(at: location)
                if scalar == 0x0A || scalar == 0x0D { break }
                location += 1
            }
            let content = ns.substring(with: NSRange(location: contentStart, length: location - contentStart))
            var lineEnding = ""
            if location < ns.length {
                let scalar = ns.character(at: location)
                if scalar == 0x0D {
                    if location + 1 < ns.length, ns.character(at: location + 1) == 0x0A {
                        lineEnding = "\r\n"; location += 2
                    } else { lineEnding = "\r"; location += 1 }
                } else { lineEnding = "\n"; location += 1 }
            }
            lines.append(SSHConfigLineRecord(number: lineNumber, content: content, lineEnding: lineEnding))
            lineNumber += 1
        }
        return lines
    }
}

import Foundation

/// Reusable multiline commands/scripts with runtime-filled {{variables}}.
/// Host-independent snippets target the active terminal.
struct Snippet: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    var content: String        // Command body; supports multiple lines.
    var group: String          // Group name, shared with host/RDP grouping; empty means ungrouped.
    let createdAt: Date
    var updatedAt: Date

    init(id: String = UUID().uuidString,
         name: String,
         content: String,
         group: String = "",
         createdAt: Date = Date(),
         updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.content = content
        self.group = group
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Older snippets.json may lack group (formerly tags); default missing fields to avoid failing the entire list.
    enum CodingKeys: String, CodingKey { case id, name, content, group, createdAt, updatedAt }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        content = try c.decode(String.self, forKey: .content)
        group = (try? c.decode(String.self, forKey: .group)) ?? ""
        createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date()
        updatedAt = (try? c.decode(Date.self, forKey: .updatedAt)) ?? Date()
    }

    /// First-line preview for sidebar subtitles.
    var preview: String {
        content.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    }

    /// Display group name; empty means ungrouped.
    var displayGroup: String { group.trimmingCharacters(in: .whitespaces).isEmpty ? String(localized: "Ungrouped") : group }
}

extension Snippet {
    /// Match {{ variable name }} and trim inner whitespace for the name.
    private static let varRegex = try? NSRegularExpression(pattern: "\\{\\{\\s*([^{}]+?)\\s*\\}\\}")

    /// Variable definition supports {{name}}, {{name=default}}, and {{name=a|b|c}}, whose first choice is default.
    struct VariableSpec: Hashable {
        let name: String
        var options: [String]       // Choices, or free text when absent.
        var defaultValue: String { options.first ?? "" }
        var isChoice: Bool { options.count > 1 }
    }

    private static func parseSpec(_ raw: String) -> VariableSpec {
        guard let eq = raw.firstIndex(of: "=") else { return VariableSpec(name: raw, options: []) }
        let name = raw[..<eq].trimmingCharacters(in: .whitespaces)
        let opts = raw[raw.index(after: eq)...].split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        return VariableSpec(name: name, options: opts.filter { !$0.isEmpty })
    }

    /// Variable definitions in occurrence order, deduplicated by name and preferring definitions with defaults.
    static func variableSpecs(in content: String) -> [VariableSpec] {
        guard let re = varRegex else { return [] }
        let ns = content as NSString
        var out: [VariableSpec] = []
        for m in re.matches(in: content, range: NSRange(location: 0, length: ns.length)) {
            let spec = parseSpec(ns.substring(with: m.range(at: 1)))
            guard !spec.name.isEmpty else { continue }
            if let i = out.firstIndex(where: { $0.name == spec.name }) { if out[i].options.isEmpty { out[i] = spec } } else { out.append(spec) }
        }
        return out
    }

    /// All variable names, deduplicated in occurrence order.
    static func variableNames(in content: String) -> [String] { variableSpecs(in: content).map(\.name) }

    /// Replace {{variables}} using values, leaving missing placeholders unchanged.
    /// Replace backward so length changes do not shift subsequent match ranges.
    static func substitute(_ content: String, values: [String: String]) -> String {
        guard let re = varRegex else { return content }
        let ns = content as NSString
        let result = NSMutableString(string: content)
        for m in re.matches(in: content, range: NSRange(location: 0, length: ns.length)).reversed() {
            let name = parseSpec(ns.substring(with: m.range(at: 1))).name
            if let v = values[name] { result.replaceCharacters(in: m.range, with: v) }
        }
        return result as String
    }
}

/// Snippet run/insert request awaiting variable input before substitution and terminal delivery.
struct SnippetRunRequest: Identifiable {
    let id = UUID()
    let snippet: Snippet
    let variables: [String]    // Variable names to fill in, ordered and deduplicated.
    let run: Bool              // true runs the command by appending a newline; false inserts it at the prompt only.
}

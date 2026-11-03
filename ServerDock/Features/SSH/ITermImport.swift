import Foundation

/// Restore SSH hosts from iTerm2 profile-export JSON.
/// Support both iTerm2 export formats: Save Profile as JSON for one profile object, and
/// 「Save All Profiles as JSON」/ Dynamic Profiles（`{"Profiles": [...]}`）。
/// Only accept SSH profiles: Custom Command=SSH (Command contains ssh arguments), or Yes with an ssh command.
enum ITermImport {
    struct Candidate: Equatable {
        var name: String
        var user: String
        var host: String
        var port: Int
        var keyPath: String      // Empty means no -i was supplied.
        var sshCommand: String
        var group: String
        var initialCommand: String
    }

    enum ImportError: LocalizedError {
        case invalidJSON
        var errorDescription: String? {
            String(localized: "This file isn't an iTerm2 profile JSON export.")
        }
    }

    static func parse(_ data: Data) throws -> [Candidate] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { throw ImportError.invalidJSON }
        let profiles: [[String: Any]]
        if let dict = root as? [String: Any], let list = dict["Profiles"] as? [[String: Any]] {
            profiles = list
        } else if let dict = root as? [String: Any], dict["Name"] != nil || dict["Guid"] != nil {
            profiles = [dict]
        } else if let list = root as? [[String: Any]] {
            profiles = list
        } else {
            throw ImportError.invalidJSON
        }
        return profiles.compactMap(candidate(from:))
    }

    static func candidate(from p: [String: Any]) -> Candidate? {
        let mode = (p["Custom Command"] as? String) ?? "No"
        let command = ((p["Command"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return nil }

        let args: [String]
        let sshCommand: String
        switch mode {
        case "SSH":
            // iTerm2 3.5+ SSH profiles store only arguments in Command, e.g. user@host -p 2222.
            args = tokenize(command)
            sshCommand = "ssh \(command)"
        case "Yes":
            let tokens = tokenize(command)
            guard let i = tokens.firstIndex(where: { ($0 as NSString).lastPathComponent == "ssh" }) else { return nil }
            args = Array(tokens[(i + 1)...])
            sshCommand = command
        default:
            return nil
        }
        guard var c = parseSSHArgs(args) else { return nil }
        c.sshCommand = sshCommand

        let name = ((p["Name"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
        c.name = name.isEmpty ? c.host : name
        c.group = ((p["Tags"] as? [String])?.first { !$0.isEmpty }) ?? "iTerm2"
        c.initialCommand = ((p["Initial Text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return c
    }

    /// Parse ssh arguments without the executable, extracting destination, port, user, and identity file; ignore other options.
    static func parseSSHArgs(_ args: [String]) -> Candidate? {
        // ssh options that take arguments; see ssh(1).
        let withValue: Set<Character> = ["B", "b", "c", "D", "E", "e", "F", "I", "i", "J", "L", "l", "m", "O", "o", "p", "Q", "R", "S", "W", "w"]
        var user = "", port: Int? = nil, identity = "", dest: String? = nil, hostName: String? = nil
        var i = 0
        func applyOption(_ opt: String) {
            // -o Key=Value / -o "Key Value"
            let parts = opt.split(maxSplits: 1, whereSeparator: { $0 == "=" || $0 == " " }).map(String.init)
            guard parts.count == 2 else { return }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            switch parts[0].lowercased() {
            case "port": port = Int(value) ?? port
            case "user": user = value
            case "hostname": hostName = value
            case "identityfile": identity = value
            default: break
            }
        }
        while i < args.count {
            let a = args[i]
            if a.hasPrefix("-"), a.count >= 2, a != "--" {   // OpenSSH also accepts options after the destination, e.g. host -p 22.
                let flag = a[a.index(after: a.startIndex)]
                if withValue.contains(flag) {
                    var value = String(a.dropFirst(2))
                    if value.isEmpty, i + 1 < args.count { i += 1; value = args[i] }
                    switch flag {
                    case "p": port = Int(value) ?? port
                    case "l": user = value
                    case "i": identity = value
                    case "o": applyOption(value)
                    default: break
                    }
                }
                i += 1
                continue
            }
            if a == "--" { i += 1; continue }
            if dest == nil { dest = a; i += 1; continue }
            break   // Ignore non-option arguments after the destination because they are the remote command.
        }
        guard var target = dest, !target.isEmpty else { return nil }

        // ssh://[user@]host[:port]
        if target.hasPrefix("ssh://") {
            target = String(target.dropFirst("ssh://".count))
            if let slash = target.firstIndex(of: "/") { target = String(target[..<slash]) }
            if let colon = target.lastIndex(of: ":"), !target.hasSuffix("]"), let pnum = Int(target[target.index(after: colon)...]) {
                port = port ?? pnum
                target = String(target[..<colon])
            }
        }
        if let at = target.lastIndex(of: "@") {
            if user.isEmpty { user = String(target[..<at]) }
            target = String(target[target.index(after: at)...])
        }
        if target.hasPrefix("["), target.hasSuffix("]") { target = String(target.dropFirst().dropLast()) }
        if let hostName, !hostName.isEmpty { target = hostName }   // -o HostName overrides the alias.
        guard !target.isEmpty else { return nil }

        return Candidate(name: "", user: user, host: target, port: port ?? 22,
                         keyPath: identity, sshCommand: "", group: "", initialCommand: "")
    }

    /// Simple shell tokenizer supporting single/double quotes and backslash escapes.
    static func tokenize(_ s: String) -> [String] {
        var out: [String] = [], cur = "", inToken = false
        var quote: Character? = nil
        var it = s.makeIterator()
        while let ch = it.next() {
            if let q = quote {
                if ch == q { quote = nil }
                else if ch == "\\", q == "\"", let n = it.next() { cur.append(n) }
                else { cur.append(ch) }
            } else if ch == "'" || ch == "\"" {
                quote = ch; inToken = true
            } else if ch == "\\" {
                if let n = it.next() { cur.append(n); inToken = true }
            } else if ch.isWhitespace {
                if inToken { out.append(cur); cur = ""; inToken = false }
            } else {
                cur.append(ch); inToken = true
            }
        }
        if inToken { out.append(cur) }
        return out
    }
}

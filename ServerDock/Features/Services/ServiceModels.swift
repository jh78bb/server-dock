import Foundation

/// Merged systemctl list-units/list-unit-files service model.
struct SystemdService: Identifiable, Hashable {
    let name: String            // sshd.service
    var load: String            // loaded / not-found / masked …
    var active: String          // active / inactive / failed / activating …
    var sub: String             // running / exited / dead / failed …
    var description: String
    var enabled: String         // enabled/disabled/static/masked/indirect; empty if unknown.

    var id: String { name }
    /// Display name without .service.
    var shortName: String { name.hasSuffix(".service") ? String(name.dropLast(8)) : name }
    var isRunning: Bool { active == "active" && sub == "running" }
    var isActive: Bool { active == "active" || active == "activating" || active == "reloading" }
    var isFailed: Bool { active == "failed" }
    var isMasked: Bool { load == "masked" || enabled == "masked" }
    var isEnabled: Bool { enabled == "enabled" || enabled == "enabled-runtime" }
    /// Whether enable/disable applies; static/generated/alias states cannot change this way.
    var canToggleEnable: Bool { ["enabled", "enabled-runtime", "disabled"].contains(enabled) }

    // Table sort key.
    var stateRank: Int { isFailed ? 0 : (isRunning ? 1 : (isActive ? 2 : 3)) }

    /// Parse plain list-units service rows after removing leading status symbols.
    static func parse(unitLine line: String) -> SystemdService? {
        var l = line.trimmingCharacters(in: .whitespaces)
        while let f = l.first, "●○×*".contains(f) { l.removeFirst(); l = l.trimmingCharacters(in: .whitespaces) }
        let p = l.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true).map(String.init)
        guard p.count >= 4, p[0].hasSuffix(".service") else { return nil }
        return SystemdService(name: p[0], load: p[1], active: p[2], sub: p[3], description: p.count > 4 ? p[4].trimmingCharacters(in: .whitespaces) : "", enabled: "")
    }

    /// Parse list-unit-files into name/state.
    static func parse(fileLine line: String) -> (String, String)? {
        let p = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard p.count >= 2, p[0].hasSuffix(".service") else { return nil }
        return (p[0], p[1])
    }

    /// Merge enabled states into loaded units and append unloaded files as inactive entries.
    static func merge(units: [SystemdService], files: [String: String]) -> [SystemdService] {
        var out: [SystemdService] = []
        var seen = Set<String>()
        for var u in units where u.load != "not-found" {
            u.enabled = files[u.name] ?? ""
            out.append(u); seen.insert(u.name)
        }
        for (name, state) in files where !seen.contains(name) && !name.contains("@.") {   // Exclude templates such as foo@.service.
            out.append(SystemdService(name: name, load: "loaded", active: "inactive", sub: "dead", description: "", enabled: state))
        }
        return out.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

enum ServiceAction: String {
    case start, stop, restart, reload, enable, disable

    var title: String {
        switch self {
        case .start: return String(localized: "Start")
        case .stop: return String(localized: "Stop")
        case .restart: return String(localized: "Restart")
        case .reload: return String(localized: "Reload")
        case .enable: return String(localized: "Enable at Boot")
        case .disable: return String(localized: "Disable at Boot")
        }
    }
    /// Confirm service interruption/startup-behavior changes.
    var confirm: Bool { self == .stop || self == .restart || self == .disable }
    var symbol: String {
        switch self {
        case .start: return "play.fill"; case .stop: return "stop.fill"; case .restart: return "arrow.clockwise"
        case .reload: return "arrow.triangle.2.circlepath"; case .enable: return "power"; case .disable: return "poweroff"
        }
    }
}

/// Build systemctl/journalctl commands with shell-quoted unit names.
enum ServiceCommands {
    static func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
    private static func sc(_ sudo: Bool) -> String { sudo ? "sudo -n systemctl --no-ask-password" : "systemctl --no-ask-password" }

    static let marker = "__FILES__"

    static func listScript() -> String {
        "export LC_ALL=C; "
            + "command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ] || { echo __NOSYSTEMD__; exit 127; }; "
            + "systemctl list-units --type=service --all --no-pager --no-legend --plain 2>&1; echo \(marker); "
            + "systemctl list-unit-files --type=service --no-pager --no-legend 2>&1"
    }

    static func action(_ a: ServiceAction, names: [String], sudo: Bool) -> String {
        "export LC_ALL=C; \(sc(sudo)) \(a.rawValue) " + names.map(q).joined(separator: " ") + " 2>&1"
    }

    static func status(name: String, sudo: Bool) -> String {
        "export LC_ALL=C; \(sc(sudo)) status \(q(name)) --no-pager -l 2>&1; true"
    }

    /// TailSession log script avoids exit 3, reserved for binary-file handling.
    static func logsScript(name: String, sudo: Bool) -> String {
        "\(sudo ? "sudo -n " : "")journalctl -u \(q(name)) -n 200 -f --no-pager -o short-iso 2>&1; c=$?; [ $c -eq 3 ] && exit 4; exit $c"
    }
}

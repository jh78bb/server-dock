import Foundation

/// One docker ps -a container row, optionally including docker stats.
struct DockerContainer: Identifiable, Hashable {
    let id: String            // Short container ID.
    let name: String
    let image: String
    let state: String         // running / exited / paused / restarting / created / dead
    let status: String        // Human-readable state such as "Up 3 hours (healthy)".
    let ports: String
    let created: String
    let command: String
    var cpu: String = ""      // "0.35%"
    var memUsage: String = "" // "24.5MiB / 1.9GiB"
    var memPercent: String = ""

    var isRunning: Bool { state == "running" }
    var isPaused: Bool { state == "paused" }
    var isUnhealthy: Bool { status.contains("unhealthy") }

    // Numeric Table sort value.
    var cpuValue: Double { Double(cpu.replacingOccurrences(of: "%", with: "")) ?? -1 }
    var memValue: Double { Double(memPercent.replacingOccurrences(of: "%", with: "")) ?? -1 }
    var stateRank: Int {
        switch state { case "running": return 0; case "paused": return 1; case "restarting": return 2; default: return 3 }
    }

    /// Parse docker ps JSON and Podman's differing Id/Names/Ports array shapes.
    static func parse(psLine line: String) -> DockerContainer? {
        guard let data = line.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func s(_ k: String) -> String { (o[k] as? String) ?? "" }
        guard var id = (o["ID"] as? String) ?? (o["Id"] as? String), !id.isEmpty else { return nil }
        if id.count > 12 { id = String(id.prefix(12)) }
        let names: String
        if let arr = o["Names"] as? [String] { names = arr.first ?? id } else { names = s("Names").split(separator: ",").first.map(String.init) ?? id }
        var ports = s("Ports")
        if ports.isEmpty, let arr = o["Ports"] as? [[String: Any]] {
            ports = arr.compactMap { p -> String? in
                guard let cp = p["container_port"] as? Int else { return nil }
                let proto = (p["protocol"] as? String) ?? "tcp"
                if let hp = p["host_port"] as? Int, hp != 0 { return "\((p["host_ip"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "0.0.0.0"):\(hp)->\(cp)/\(proto)" }
                return "\(cp)/\(proto)"
            }.joined(separator: ", ")
        }
        var image = s("Image"); if image.isEmpty { image = s("ImageName") }
        return DockerContainer(id: id, name: names, image: image, state: s("State").lowercased(), status: s("Status"),
                               ports: ports, created: s("CreatedAt"), command: s("Command"))
    }

    /// Parse no-stream stats into name/CPU/memory/memory percentage, supporting Podman snake_case keys.
    static func parse(statsLine line: String) -> (name: String, cpu: String, mem: String, memPct: String)? {
        guard let data = line.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func s(_ keys: String...) -> String { for k in keys { if let v = o[k] as? String, !v.isEmpty { return v } }; return "" }
        let name = s("Name", "name")
        guard !name.isEmpty else { return nil }
        return (name, s("CPUPerc", "cpu_percent", "CPU"), s("MemUsage", "mem_usage"), s("MemPerc", "mem_percent"))
    }
}

/// Container operation; confirm=true prompts before potentially disruptive/destructive actions.
enum DockerAction: String {
    case start, stop, restart, pause, unpause, kill, remove

    var verb: String {
        switch self {
        case .start: return "start"; case .stop: return "stop"; case .restart: return "restart"
        case .pause: return "pause"; case .unpause: return "unpause"; case .kill: return "kill"; case .remove: return "rm -f"
        }
    }
    var confirm: Bool { self == .stop || self == .restart || self == .kill || self == .remove }
    var destructive: Bool { self == .kill || self == .remove }
    var title: String {
        switch self {
        case .start: return String(localized: "Start")
        case .stop: return String(localized: "Stop")
        case .restart: return String(localized: "Restart")
        case .pause: return String(localized: "Pause")
        case .unpause: return String(localized: "Resume")
        case .kill: return String(localized: "Kill")
        case .remove: return String(localized: "Remove")
        }
    }
    var symbol: String {
        switch self {
        case .start: return "play.fill"; case .stop: return "stop.fill"; case .restart: return "arrow.clockwise"
        case .pause: return "pause.fill"; case .unpause: return "playpause.fill"; case .kill: return "bolt.fill"; case .remove: return "trash"
        }
    }
}

/// Image row from images format ID|Repository|Tag|Size|CreatedSince.
struct DockerImage: Identifiable, Hashable {
    let id: String
    let repository: String
    let tag: String
    let size: String
    let created: String

    var reference: String { repository == "<none>" ? id : (tag == "<none>" || tag.isEmpty ? repository : "\(repository):\(tag)") }
    var isDangling: Bool { repository == "<none>" }
    var displayName: String { repository == "<none>" ? String(localized: "<untagged>") : repository }

    static func parse(_ line: String) -> DockerImage? {
        let f = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard f.count >= 5, !f[0].isEmpty else { return nil }
        return DockerImage(id: f[0], repository: f[1], tag: f[2], size: f[3], created: f[4])
    }
}

/// Container run -d input values.
struct RunSpec {
    var image = ""
    var name = ""
    var ports = ""          // One port mapping per line: 8080:80 or 127.0.0.1:8080:80/tcp.
    var env = ""            // One KEY=VALUE per line.
    var volumes = ""        // One /host:/container[:ro] per line.
    var restart = "no"      // no / always / unless-stopped / on-failure
    var command = ""

    static func lines(_ s: String) -> [String] {
        s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    var problem: String? {
        if image.trimmingCharacters(in: .whitespaces).isEmpty { return String(localized: "Enter an image, for example nginx:latest.") }
        let n = name.trimmingCharacters(in: .whitespaces)
        if !n.isEmpty, n.range(of: #"^[a-zA-Z0-9][a-zA-Z0-9_.-]*$"#, options: .regularExpression) == nil {
            return String(localized: "The name can only use letters, numbers, . _ - and must start with a letter or number.")
        }
        for p in Self.lines(ports) where p.range(of: #"^(\d{1,3}(\.\d{1,3}){3}:)?\d{1,5}(-\d{1,5})?:\d{1,5}(-\d{1,5})?(/(tcp|udp|sctp))?$"#, options: .regularExpression) == nil {
            return String(localized: "Port “\(p)” should look like 8080:80 or 127.0.0.1:8080:80/tcp.")
        }
        for e in Self.lines(env) where e.range(of: #"^[A-Za-z_][A-Za-z0-9_]*=.*$"#, options: .regularExpression) == nil {
            return String(localized: "Environment “\(e)” should look like KEY=value.")
        }
        for v in Self.lines(volumes) where !v.contains(":") { return String(localized: "Volume “\(v)” should look like /host/path:/container/path.") }
        return nil
    }
}

/// Build remote docker/podman commands, shell-quoting names/IDs; engine is docker or podman.
enum DockerCommands {
    /// Extend PATH with common locations for non-login shells, Docker Desktop, and Homebrew.
    static let pathPrefix = "export PATH=\"$PATH:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/Applications/Docker.app/Contents/Resources/bin\"; "

    static func bin(_ sudo: Bool, _ engine: String = "docker") -> String { sudo ? "sudo -n \(engine)" : engine }

    private static func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }

    static func psScript(sudo: Bool, engine: String = "docker") -> String {
        pathPrefix + "command -v \(engine) >/dev/null 2>&1 || { echo __NODOCKER__; exit 127; }; "
            + "\(bin(sudo, engine)) ps -a --format '{{json .}}' 2>&1"
    }

    static func statsScript(sudo: Bool, engine: String = "docker") -> String {
        pathPrefix + "\(bin(sudo, engine)) stats --no-stream --format '{{json .}}' 2>&1"
    }

    static func action(_ a: DockerAction, ids: [String], sudo: Bool, engine: String = "docker") -> String {
        pathPrefix + "\(bin(sudo, engine)) \(a.verb) " + ids.map(q).joined(separator: " ") + " 2>&1"
    }

    static func inspect(id: String, sudo: Bool, engine: String = "docker") -> String {
        pathPrefix + "\(bin(sudo, engine)) inspect \(q(id)) 2>&1"
    }

    /// Log-following script for TailSession; avoid exit 3, which the tail view treats as binary.
    static func logsScript(id: String, sudo: Bool, engine: String = "docker") -> String {
        pathPrefix + "\(bin(sudo, engine)) logs --tail 200 -f \(q(id)) 2>&1; c=$?; [ $c -eq 3 ] && exit 4; exit $c"
    }

    /// Container shell command prefers bash, falling back to sh.
    static func execShell(name: String, sudo: Bool, engine: String = "docker") -> String {
        "\(sudo ? "sudo \(engine)" : engine) exec -it \(q(name)) sh -c 'command -v bash >/dev/null 2>&1 && exec bash || exec sh'"
    }

    // MARK: Images

    static func imagesScript(sudo: Bool, engine: String = "docker") -> String {
        pathPrefix + "\(bin(sudo, engine)) images --format '{{.ID}}|{{.Repository}}|{{.Tag}}|{{.Size}}|{{.CreatedSince}}' 2>&1"
    }
    static func pull(_ ref: String, sudo: Bool, engine: String = "docker") -> String { pathPrefix + "\(bin(sudo, engine)) pull \(q(ref)) 2>&1" }
    static func removeImages(ids: [String], force: Bool, sudo: Bool, engine: String = "docker") -> String {
        pathPrefix + "\(bin(sudo, engine)) rmi \(force ? "-f " : "")" + ids.map(q).joined(separator: " ") + " 2>&1"
    }
    static func pruneImages(sudo: Bool, engine: String = "docker") -> String { pathPrefix + "\(bin(sudo, engine)) image prune -f 2>&1" }

    /// Use the same docker run -d command for preview and execution.
    static func run(_ s: RunSpec, sudo: Bool = false, engine: String = "docker") -> String {
        var c = "\(bin(sudo, engine)) run -d"
        let n = s.name.trimmingCharacters(in: .whitespaces)
        if !n.isEmpty { c += " --name \(q(n))" }
        for p in RunSpec.lines(s.ports) { c += " -p \(q(p))" }
        for e in RunSpec.lines(s.env) { c += " -e \(q(e))" }
        for v in RunSpec.lines(s.volumes) { c += " -v \(q(v))" }
        if s.restart != "no" { c += " --restart \(s.restart)" }
        c += " \(q(s.image.trimmingCharacters(in: .whitespaces)))"
        let cmd = s.command.trimmingCharacters(in: .whitespaces)
        if !cmd.isEmpty { c += " \(cmd)" }   // Leave user commands unchanged for shell tokenization.
        return c
    }
    static func runScript(_ s: RunSpec, sudo: Bool, engine: String = "docker") -> String { pathPrefix + run(s, sudo: sudo, engine: engine) + " 2>&1" }
}

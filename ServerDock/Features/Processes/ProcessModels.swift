import Foundation

/// One ps process row.
struct ProcessRow: Identifiable, Hashable {
    let pid: Int
    let ppid: Int
    let user: String
    let cpu: Double
    let mem: Double
    let rssKB: Int64
    let elapsed: String
    let state: String
    let nice: String
    let command: String

    var id: Int { pid }
    /// Executable name from the first command token's last path component.
    var name: String {
        // For spaced macOS app paths, take everything before the first " -" option boundary.
        let exe = command.components(separatedBy: " -").first ?? command
        let base = (exe as NSString).lastPathComponent
        return base.isEmpty ? exe : base
    }
    var isKernelThread: Bool { command.hasPrefix("[") && command.hasSuffix("]") }
    var isStopped: Bool { state.hasPrefix("T") }
    var isZombie: Bool { state.hasPrefix("Z") }
    var rssMB: Double { Double(rssKB) / 1024 }

    /// ps row fields: pid, ppid, user, pcpu, pmem, rss, etime, stat, nice, args.
    static func parse(_ line: String) -> ProcessRow? {
        let t = line.trimmingCharacters(in: .whitespaces)
        var f: [Substring] = []
        var rest = Substring(t)
        for _ in 0..<9 {
            rest = rest.drop { $0 == " " || $0 == "\t" }
            guard let end = rest.firstIndex(where: { $0 == " " || $0 == "\t" }) else { return nil }
            f.append(rest[..<end]); rest = rest[end...]
        }
        guard let pid = Int(f[0]), let ppid = Int(f[1]), let cpu = Double(f[3]), let mem = Double(f[4]), let rss = Int64(f[5]) else { return nil }
        return ProcessRow(pid: pid, ppid: ppid, user: String(f[2]), cpu: cpu, mem: mem, rssKB: rss, elapsed: String(f[6]), state: String(f[7]), nice: String(f[8]),
                          command: rest.trimmingCharacters(in: .whitespaces))
    }
}

/// Supported process signals.
enum ProcessSignal: String, CaseIterable, Identifiable {
    case term = "TERM", kill = "KILL", int = "INT", hup = "HUP", stop = "STOP", cont = "CONT", usr1 = "USR1", usr2 = "USR2"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .term: return String(localized: "Terminate (SIGTERM)")
        case .kill: return String(localized: "Force Kill (SIGKILL)")
        case .int: return String(localized: "Interrupt (SIGINT)")
        case .hup: return String(localized: "Reload / Hang Up (SIGHUP)")
        case .stop: return String(localized: "Pause (SIGSTOP)")
        case .cont: return String(localized: "Resume (SIGCONT)")
        case .usr1: return "SIGUSR1"
        case .usr2: return "SIGUSR2"
        }
    }
    /// Signals requiring confirmation because they terminate/suspend processes.
    var confirm: Bool { [.term, .kill, .stop, .int].contains(self) }
    var destructive: Bool { self == .kill || self == .term }
}

enum ProcessCommands {
    static let listScript = "export LC_ALL=C; ps -axo pid=,ppid=,user=,pcpu=,pmem=,rss=,etime=,stat=,nice=,args= 2>&1"

    static func kill(_ signal: ProcessSignal, pids: [Int], sudo: Bool) -> String {
        "export LC_ALL=C; \(sudo ? "sudo -n " : "")kill -s \(signal.rawValue) " + pids.map(String.init).joined(separator: " ") + " 2>&1"
    }

    /// Details include command line, cwd, executable, and lsof open files when available.
    static func details(pid: Int) -> String {
        "export LC_ALL=C; ps -p \(pid) -o pid,ppid,user,stat,nice,pcpu,pmem,rss,lstart,etime,args 2>&1; echo; "
            + "ls -l /proc/\(pid)/cwd /proc/\(pid)/exe 2>&1 | sed 's/^/  /'; echo; "
            + "(lsof -nP -p \(pid) 2>/dev/null | head -60) || true"
    }
}

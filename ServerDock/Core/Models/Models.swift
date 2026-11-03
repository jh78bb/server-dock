import SwiftUI

enum Section: Hashable {
    case hosts, files, sshKeys, rdp, snippets, sites, tools, portForwards, settings
}

enum SettingsTab: String, CaseIterable, Hashable {
    case general, terminal, transfer, monitor, security, aiChat, keys, about

    var label: String {
        switch self {
        case .general: return String(localized: "General")
        case .terminal: return String(localized: "Terminal")
        case .transfer: return String(localized: "Transfer")
        case .monitor: return String(localized: "Monitoring")
        case .security: return String(localized: "Security")
        case .aiChat: return String(localized: "AI Assistant")
        case .keys: return String(localized: "Shortcuts")
        case .about: return String(localized: "About")
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .terminal: return "terminal"
        case .transfer: return "arrow.up.arrow.down"
        case .monitor: return "speedometer"
        case .security: return "lock.shield"
        case .aiChat: return "bubble.left.and.bubble.right"
        case .keys: return "command"
        case .about: return "info.circle"
        }
    }
}

enum TabKind {
    case overview, terminal, files, editor, rdp, aiChat, tail, diskUsage, site, docker, web, services, processes, netTools, keyManager, script, portForwards
}

struct TabItem: Identifiable {
    let id: Int
    let kind: TabKind
    var title: String
    var hostId: String?
    var filePath: String? = nil
}

enum HostStatus: String, Codable {
    case online, offline, unknown
}

/// A host session/action record (terminal, upload, or port forwarding) for recent sessions.
enum SessionKind: String, Codable {
    case terminal, files, upload, portForward, rdp

    var icon: String {
        switch self {
        case .terminal: return "terminal"
        case .files: return "folder"
        case .upload: return "arrow.up.circle"
        case .portForward: return "arrow.left.arrow.right"
        case .rdp: return "display"
        }
    }
}

struct SessionEvent: Codable, Identifiable {
    var id = UUID()
    let hostId: String
    let kind: SessionKind
    let detail: String
    let timestamp: Date
}

/// SSH connection settings for a host, used to construct the actual ssh command.
struct SSHConnection: Codable, Equatable {
    // Passwords live in Keychain, not JSON; persist all other fields.
    enum CodingKeys: String, CodingKey {
        case user, host, port, authMethod, keyPath, keyId, agentSocket, encoding, hostKeyAlgos, ciphers, kexAlgos
        case sshCommand, localStartDir, useBuiltinSSH, jumpHost, proxyURL, disableProxy, timeoutMs, heartbeatMs, initialCommand, defaultPath
    }

    var user: String = "root"
    var host: String = ""
    var port: Int = 22
    var authMethod: AuthMethod = .password
    var password: String = ""
    var keyPath: String = ""
    /// Agent socket for authentication; empty uses SSH_AUTH_SOCK.
    var agentSocket: String = ""
    var keyId: String = ""   // Linked key-library ID; materialize its private key as a mode-0600 working file, taking precedence over keyPath.
    var encoding: String = ""
    var hostKeyAlgos: String = ""
    var ciphers: String = ""
    var kexAlgos: String = ""
    /// OS SSH (useBuiltinSSH=false) executes this command unchanged, e.g. ssh user@host or ssh myalias; empty derives from fields.
    var sshCommand: String = ""
    /// Local OS SSH working directory, like iTerm Initial directory; empty means home.
    var localStartDir: String = ""
    /// true uses built-in libssh2 terminals; false defaults to system ssh honoring ~/.ssh/config like iTerm.
    var useBuiltinSSH: Bool = false
    /// Jump hosts for ssh -J/ProxyJump, e.g. user@bastion:22 with comma-separated hops; empty connects directly.
    var jumpHost: String = ""
    var proxyURL: String = ""
    var disableProxy: Bool = false
    var timeoutMs: Int = 10000
    var heartbeatMs: Int = 5000
    var initialCommand: String = ""
    var defaultPath: String = "~"
    /// Synthetic local Mac host uses filesystem/process operations instead of SSH and is excluded from JSON.
    var isLocal: Bool = false

    var usesPassword: Bool {
        authMethod == .password && !password.isEmpty
    }

    /// Whether askpass must supply a login password, private-key passphrase, or the one-time password entered in a dialog.
    var needsAskpass: Bool {
        !password.isEmpty && (authMethod == .password || authMethod == .key || authMethod == .ask)
    }

    /// Whether automatic connection credentials are ready: ask mode requires this session's password; other modes return true.
    /// Gate background monitoring/spec discovery on credentials. Show placeholders without repeated password prompts until credentials are available.
    var hasUsableCredentials: Bool {
        authMethod == .ask ? !password.isEmpty : true
    }

    /// Map terminal display encoding to a remote locale and forward it with SetEnv (best effort; the server must provide the locale).
    fileprivate var remoteLocale: String? {
        switch encoding {
        case "", "UTF-8": return encoding == "UTF-8" ? "en_US.UTF-8" : nil
        case "GBK": return "zh_CN.GBK"
        case "GB2312": return "zh_CN.GB2312"
        case "GB18030": return "zh_CN.GB18030"
        case "Big5": return "zh_TW.Big5"
        case "Shift_JIS": return "ja_JP.SJIS"
        case "EUC-JP": return "ja_JP.eucJP"
        case "EUC-KR": return "ko_KR.eucKR"
        case "KOI8-R": return "ru_RU.KOI8-R"
        case "ISO-8859-1": return "en_US.ISO8859-1"
        case "ISO-8859-15": return "en_US.ISO8859-15"
        case "Windows-1251": return "ru_RU.CP1251"
        case "Windows-1252": return "en_US.CP1252"
        case "ASCII": return "C"
        default: return nil
        }
    }

    /// Absolute, tilde-expanded agent socket; empty returns nil to retain system SSH_AUTH_SOCK.
    var resolvedAgentSocket: String? {
        let p = agentSocket.trimmingCharacters(in: .whitespaces)
        return p.isEmpty ? nil : (p as NSString).expandingTildeInPath
    }

    var hasJumpHost: Bool { !jumpHost.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Construct ssh arguments, excluding the executable. verbose enables connection-test stage parsing.
    func sshArguments(verbose: Bool = false, multiplex: Bool = false, ephemeralKnownHosts: Bool = false) -> [String] {
        var a: [String] = []
        if verbose { a.append("-v") }
        // Reuse a master connection for frequent file operations so authentication occurs only once. %C is a fixed-length hash to keep socket paths short.
        if multiplex {
            a += ["-o", "ControlMaster=auto",
                  "-o", "ControlPath=\(NSHomeDirectory())/.serverdock/cm/%C",
                  "-o", "ControlPersist=120"]
        }
        // The app's fingerprint dialog adds unknown hosts to known_hosts beforehand; use strict yes verification here.
        // Connection tests use temporary known_hosts behavior (accept-new + /dev/null) without silently modifying the user's known_hosts.
        if ephemeralKnownHosts {
            a += ["-o", "StrictHostKeyChecking=accept-new", "-o", "UserKnownHostsFile=/dev/null"]
        } else if hasJumpHost {
            // Jump connections cannot run direct fingerprint preflight; use trust-on-first-use initially.
            // Still reject changes to already recorded host keys.
            a += ["-o", "StrictHostKeyChecking=accept-new", "-o", "UserKnownHostsFile=\(HostKeyVerifier.userKnownHostsArg())"]
        } else {
            a += ["-o", "StrictHostKeyChecking=yes", "-o", "UserKnownHostsFile=\(HostKeyVerifier.userKnownHostsArg())"]
        }
        // Ask mode supplies the one-time password through askpass; allow only one password-authentication attempt.
        a += ["-o", "NumberOfPasswordPrompts=1"]
        if authMethod == .ask { a += ["-o", "PreferredAuthentications=password"] }
        if authMethod == .agent {
            a += ["-o", "PreferredAuthentications=publickey"]
            if let sock = resolvedAgentSocket { a += ["-o", "IdentityAgent=\(sock)"] }
        }
        a += ["-p", String(port)]
        if timeoutMs > 0 { a += ["-o", "ConnectTimeout=\(max(1, timeoutMs / 1000))"] }
        if heartbeatMs > 0 { a += ["-o", "ServerAliveInterval=\(max(1, heartbeatMs / 1000))"] }
        // Use only the specified private key; do not try agent or default keys.
        // For a linked keyId, write the library key to a mode-0600 working file instead of using the manually entered keyPath.
        if authMethod == .key {
            let path = keyId.isEmpty ? keyPath : (KeyMaterializer.path(forKeyId: keyId) ?? keyPath)
            if !path.isEmpty { a += ["-i", path, "-o", "IdentitiesOnly=yes"] }
        }
        // Forward the terminal encoding's locale to the server (requires AcceptEnv LC_*).
        if let loc = remoteLocale { a += ["-o", "SetEnv=LC_ALL=\(loc)"] }
        if !ciphers.isEmpty { a += ["-c", ciphers] }
        if !kexAlgos.isEmpty { a += ["-o", "KexAlgorithms=\(kexAlgos)"] }
        if !hostKeyAlgos.isEmpty { a += ["-o", "HostKeyAlgorithms=\(hostKeyAlgos)"] }
        if hasJumpHost {
            a += ["-J", jumpHost.trimmingCharacters(in: .whitespaces)]
        } else if !disableProxy, !proxyURL.isEmpty, let pc = proxyCommand() {
            a += ["-o", "ProxyCommand=\(pc)"]
        }
        a += ["\(user)@\(host)"]
        return a
    }

    /// Convert a SOCKS/HTTP proxy URL to an nc-based ssh ProxyCommand.
    /// ssh executes the result through /bin/sh -c, so strictly validate the host and port.
    /// Otherwise a proxy URL such as `socks5://h$(touch /tmp/x):1080` could inject a local command.
    fileprivate func proxyCommand() -> String? {
        guard let comps = URLComponents(string: proxyURL),
              let scheme = comps.scheme?.lowercased(),
              let phost = comps.host, let pport = comps.port else { return nil }
        // Allow only hostname/IPv4 characters and a valid port range; reject all shell metacharacters.
        let hostOK = phost.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil
        guard hostOK, (1...65535).contains(pport) else { return nil }
        switch scheme {
        case "socks5", "socks5h": return "nc -X 5 -x \(phost):\(pport) %h %p"
        case "socks4": return "nc -X 4 -x \(phost):\(pport) %h %p"
        case "http", "https": return "nc -X connect -x \(phost):\(pport) %h %p"
        default: return nil
        }
    }
}

extension SSHConnection {
    // Decode older hosts.json tolerantly when newer jumpHost/useBuiltinSSH fields are absent.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SSHConnection()
        user = try c.decodeIfPresent(String.self, forKey: .user) ?? d.user
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? d.host
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? d.port
        authMethod = try c.decodeIfPresent(AuthMethod.self, forKey: .authMethod) ?? d.authMethod
        keyPath = try c.decodeIfPresent(String.self, forKey: .keyPath) ?? ""
        keyId = try c.decodeIfPresent(String.self, forKey: .keyId) ?? ""
        agentSocket = try c.decodeIfPresent(String.self, forKey: .agentSocket) ?? ""
        encoding = try c.decodeIfPresent(String.self, forKey: .encoding) ?? ""
        hostKeyAlgos = try c.decodeIfPresent(String.self, forKey: .hostKeyAlgos) ?? ""
        ciphers = try c.decodeIfPresent(String.self, forKey: .ciphers) ?? ""
        kexAlgos = try c.decodeIfPresent(String.self, forKey: .kexAlgos) ?? ""
        useBuiltinSSH = try c.decodeIfPresent(Bool.self, forKey: .useBuiltinSSH) ?? false
        sshCommand = try c.decodeIfPresent(String.self, forKey: .sshCommand) ?? ""
        localStartDir = try c.decodeIfPresent(String.self, forKey: .localStartDir) ?? ""
        jumpHost = try c.decodeIfPresent(String.self, forKey: .jumpHost) ?? ""
        proxyURL = try c.decodeIfPresent(String.self, forKey: .proxyURL) ?? ""
        disableProxy = try c.decodeIfPresent(Bool.self, forKey: .disableProxy) ?? false
        timeoutMs = try c.decodeIfPresent(Int.self, forKey: .timeoutMs) ?? d.timeoutMs
        heartbeatMs = try c.decodeIfPresent(Int.self, forKey: .heartbeatMs) ?? d.heartbeatMs
        initialCommand = try c.decodeIfPresent(String.self, forKey: .initialCommand) ?? ""
        defaultPath = try c.decodeIfPresent(String.self, forKey: .defaultPath) ?? d.defaultPath
    }

    /// Arguments for system ssh terminals, honoring ~/.ssh/config like iTerm
    /// and appending only explicitly specified nondefault port/key/jump values.
    func systemSSHArguments() -> [String] {
        var a: [String] = ["-o", "StrictHostKeyChecking=ask"]
        if port != 22 { a += ["-p", String(port)] }
        if authMethod == .key {
            let path = keyId.isEmpty ? keyPath : (KeyMaterializer.path(forKeyId: keyId) ?? keyPath)
            if !path.isEmpty { a += ["-i", path] }
        }
        if authMethod == .ask { a += ["-o", "PreferredAuthentications=password,keyboard-interactive"] }
        if authMethod == .agent, let sock = resolvedAgentSocket { a += ["-o", "IdentityAgent=\(sock)"] }
        if timeoutMs > 0 { a += ["-o", "ConnectTimeout=\(max(1, timeoutMs / 1000))"] }
        if heartbeatMs > 0 { a += ["-o", "ServerAliveInterval=\(max(1, heartbeatMs / 1000))"] }
        if let loc = remoteLocale { a += ["-o", "SetEnv=LC_ALL=\(loc)"] }
        if hasJumpHost { a += ["-J", jumpHost.trimmingCharacters(in: .whitespaces)] }
        else if !disableProxy, !proxyURL.isEmpty, let pc = proxyCommand() { a += ["-o", "ProxyCommand=\(pc)"] }
        a += ["\(user)@\(host)"]
        return a
    }
}

/// Parse OS SSH commands such as ssh user@host -p 2222 or ssh alias; terminals execute them unchanged,
/// while built-in files/monitoring/forwarding resolve host/user/port/key/jump through ssh -G and ~/.ssh/config.
enum SSHCommandResolver {
    struct Resolved {
        var host = "", user = "", port = 22, keyPath = "", jump = ""
    }

    /// Split shell words respecting quotes.
    static func tokenize(_ s: String) -> [String] {
        var out: [String] = [], cur = "", quote: Character? = nil, has = false
        for ch in s {
            if let q = quote { if ch == q { quote = nil } else { cur.append(ch) } }
            else if ch == "'" || ch == "\"" { quote = ch; has = true }
            else if ch == " " || ch == "\t" || ch == "\n" { if has || !cur.isEmpty { out.append(cur); cur = ""; has = false } }
            else { cur.append(ch) }
        }
        if has || !cur.isEmpty { out.append(cur) }
        return out
    }

    static func resolve(_ command: String) -> Resolved? {
        var t = tokenize(command.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !t.isEmpty else { return nil }
        if t[0] == "ssh" || t[0].hasSuffix("/ssh") { t.removeFirst() }
        guard !t.isEmpty else { return nil }
        var r = Resolved()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = ["-G"] + t
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let v = parts[1]
            switch parts[0] {
            case "hostname": r.host = v
            case "user": r.user = v
            case "port": r.port = Int(v) ?? 22
            case "proxyjump":
                // ssh -G also brackets IPv4/hostnames; strip brackets unless the value contains an IPv6 colon.
                if v != "none" { r.jump = v.contains(":") && !v.contains("]:") && v.filter({ $0 == ":" }).count > 1 ? v : v.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "") }
            case "identityfile":
                if r.keyPath.isEmpty {
                    let path = (v as NSString).expandingTildeInPath
                    if FileManager.default.fileExists(atPath: path) { r.keyPath = path }
                }
            default: break
            }
        }
        return r.host.isEmpty ? nil : r
    }
}

/// RDP security/authentication level.
enum RDPSecurity: String, Codable, CaseIterable {
    case auto, nla, tls, rdp

    var label: String {
        switch self {
        case .auto: return String(localized: "Auto-Negotiate")
        case .nla:  return String(localized: "NLA (Network Level Authentication)")
        case .tls:  return "TLS"
        case .rdp:  return String(localized: "Standard RDP")
        }
    }
}

/// RDP (Windows Remote Desktop) connection settings for one host.
enum RemoteDesktopProtocol: String, Codable, CaseIterable {
    case vnc, rdp

    var label: String {
        switch self {
        case .rdp: return "RDP"
        case .vnc: return "VNC"
        }
    }
}

struct RDPConnection: Codable {
    // Passwords live in Keychain, not JSON; persist all other fields.
    enum CodingKeys: String, CodingKey {
        case user, host, port, domain, width, height, colorDepth, security, protocolType
    }

    var protocolType: RemoteDesktopProtocol = .vnc
    var user: String = "Administrator"
    var host: String = ""
    var port: Int = 3389
    var password: String = ""
    var domain: String = ""
    var width: Int = 1920
    var height: Int = 1080
    var colorDepth: Int = 32
    var security: RDPSecurity = .auto

    init(protocolType: RemoteDesktopProtocol = .vnc, user: String = "Administrator", host: String = "",
         port: Int? = nil, password: String = "", domain: String = "", width: Int = 1920,
         height: Int = 1080, colorDepth: Int = 32, security: RDPSecurity = .auto) {
        self.protocolType = protocolType
        self.user = user
        self.host = host
        self.port = port ?? (protocolType == .vnc ? 5900 : 3389)
        self.password = password
        self.domain = domain
        self.width = width
        self.height = height
        self.colorDepth = colorDepth
        self.security = security
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        protocolType = try values.decodeIfPresent(RemoteDesktopProtocol.self, forKey: .protocolType) ?? .rdp
        user = try values.decodeIfPresent(String.self, forKey: .user) ?? "Administrator"
        host = try values.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try values.decodeIfPresent(Int.self, forKey: .port) ?? (protocolType == .vnc ? 5900 : 3389)
        password = "" // Credentials are restored from Keychain by host id.
        domain = try values.decodeIfPresent(String.self, forKey: .domain) ?? ""
        width = try values.decodeIfPresent(Int.self, forKey: .width) ?? 1920
        height = try values.decodeIfPresent(Int.self, forKey: .height) ?? 1080
        colorDepth = try values.decodeIfPresent(Int.self, forKey: .colorDepth) ?? 32
        security = try values.decodeIfPresent(RDPSecurity.self, forKey: .security) ?? .auto
    }
}

/// Host specifications discovered over SSH, populated after a successful connection.
struct HostSpecs: Codable {
    enum CodingKeys: String, CodingKey {
        case os, cores, memory, disk, vram, gpu, model, chip, probedAt
        case warnProbed, pwExpireDays, accExpireDays, rebootRequired, failedUnits, diskHighPct, diskHighMount
    }

    // Linux probe warning fields; nil/zero/false means not applicable.
    var warnProbed: Bool = false          // Whether warnings were probed; older caches require reprobe.
    var pwExpireDays: Int? = nil          // Days until login-password expiry; negative means expired.
    var accExpireDays: Int? = nil         // Days until account expiry.
    var rebootRequired: Bool = false
    var failedUnits: Int = 0              // Failed systemd unit count.
    var diskHighPct: Int = 0              // Usage percentage of the fullest mount.
    var diskHighMount: String = ""

    var os: String = ""
    var cores: String = ""
    var memory: String = ""
    var disk: String = ""
    var vram: String = ""   // VRAM, populated for detected NVIDIA GPUs; empty if no dedicated GPU is detected or detection fails.
    var gpu: String = ""    // Optional GPU model.
    var model: String = ""  // Local Mac model identifier.
    var chip: String = ""   // Local Apple chip or Intel processor.
    var probedAt: Date? = nil   // Time of the last successful probe for TTL caching; system information changes slowly and need not be fetched on every overview visit.

    var isEmpty: Bool {
        os.isEmpty && cores.isEmpty && memory.isEmpty && disk.isEmpty && vram.isEmpty && gpu.isEmpty && model.isEmpty && chip.isEmpty
    }
}

extension HostSpecs {
    // Decode missing fields such as vram/gpu in older hosts.json files as empty strings.
    // Otherwise synthesized decoding throws keyNotFound and prevents the entire host from loading.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        os = try c.decodeIfPresent(String.self, forKey: .os) ?? ""
        cores = try c.decodeIfPresent(String.self, forKey: .cores) ?? ""
        memory = try c.decodeIfPresent(String.self, forKey: .memory) ?? ""
        disk = try c.decodeIfPresent(String.self, forKey: .disk) ?? ""
        vram = try c.decodeIfPresent(String.self, forKey: .vram) ?? ""
        gpu = try c.decodeIfPresent(String.self, forKey: .gpu) ?? ""
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        chip = try c.decodeIfPresent(String.self, forKey: .chip) ?? ""
        probedAt = try c.decodeIfPresent(Date.self, forKey: .probedAt)
        warnProbed = try c.decodeIfPresent(Bool.self, forKey: .warnProbed) ?? false
        pwExpireDays = try c.decodeIfPresent(Int.self, forKey: .pwExpireDays)
        accExpireDays = try c.decodeIfPresent(Int.self, forKey: .accExpireDays)
        rebootRequired = try c.decodeIfPresent(Bool.self, forKey: .rebootRequired) ?? false
        failedUnits = try c.decodeIfPresent(Int.self, forKey: .failedUnits) ?? 0
        diskHighPct = try c.decodeIfPresent(Int.self, forKey: .diskHighPct) ?? 0
        diskHighMount = try c.decodeIfPresent(String.self, forKey: .diskHighMount) ?? ""
    }
}

/// One important host-summary warning.
struct HostWarning: Identifiable {
    enum Level { case critical, warning, info }
    let id: String
    let level: Level
    let title: String
    let detail: String
}

extension HostSpecs {
    /// Build severity-ordered warnings: password <=14 days, critical <=3/expired, disk 90%/95%, and reboot required.
    var warnings: [HostWarning] {
        var w: [HostWarning] = []
        if let d = pwExpireDays {
            if d < 0 {
                w.append(.init(id: "pw", level: .critical, title: String(localized: "Password expired"),
                               detail: String(localized: "The login account's password expired \(-d) days ago. Change it with `passwd`.")))
            } else if d <= 3 {
                w.append(.init(id: "pw", level: .critical, title: String(localized: "Password expires soon"),
                               detail: String(localized: "The login account's password expires in \(d) days. Change it with `passwd`.")))
            } else if d <= 14 {
                w.append(.init(id: "pw", level: .warning, title: String(localized: "Password expiring"),
                               detail: String(localized: "The login account's password expires in \(d) days.")))
            }
        }
        if let d = accExpireDays, d <= 14 {
            w.append(.init(id: "acc", level: d <= 3 ? .critical : .warning,
                           title: d < 0 ? String(localized: "Account expired") : String(localized: "Account expiring"),
                           detail: d < 0 ? String(localized: "The login account expired \(-d) days ago.")
                                         : String(localized: "The login account expires in \(d) days.")))
        }
        if diskHighPct >= 90 {
            w.append(.init(id: "disk", level: diskHighPct >= 95 ? .critical : .warning,
                           title: String(localized: "Disk almost full"),
                           detail: String(localized: "\(diskHighMount) is \(diskHighPct)% full.")))
        }
        if rebootRequired {
            w.append(.init(id: "reboot", level: .info, title: String(localized: "Reboot required"),
                           detail: String(localized: "Updates are installed that need a reboot to take effect.")))
        }
        return w.sorted { a, b in
            func rank(_ l: HostWarning.Level) -> Int { l == .critical ? 0 : l == .warning ? 1 : 2 }
            return rank(a.level) < rank(b.level)
        }
    }
}

/// Disk usage for one mount point, in 1K blocks.
struct DiskUsage: Identifiable {
    var id: String { mount }
    let mount: String
    let usedKB: Int64
    let totalKB: Int64
    var percent: Double { totalKB > 0 ? Double(usedKB) / Double(totalKB) * 100 : 0 }
}

/// Live state of one GPU from nvidia-smi; VRAM is measured in MiB.
struct GPUInfo: Identifiable {
    var id: Int { index }
    let index: Int
    let name: String
    let utilPercent: Double
    let memUsedMB: Int64
    let memTotalMB: Int64
    let tempC: Int
    var memPercent: Double { memTotalMB > 0 ? Double(memUsedMB) / Double(memTotalMB) * 100 : 0 }
}

/// One network-rate sample (bytes/second) for the traffic chart.
struct NetSample {
    let rx: Double
    let tx: Double
}

/// One live host-monitor sample, streamed by HostMonitor from /proc and nvidia-smi; not persisted.
/// Rates/utilization require differences between consecutive samples and are nil initially. Memory is in kB (1K blocks).
/// Linux network interface state/traffic.
struct NetInterface: Identifiable {
    let name: String
    let state: String            // up / down / unknown
    let speedMbps: Int?          // Link speed; nil if unknown.
    let addresses: String        // Comma-separated IPv4 addresses.
    let rxTotal: Double          // Received bytes since boot.
    let txTotal: Double
    var rxRate: Double? = nil    // Bytes per second.
    var txRate: Double? = nil
    var id: String { name }
    var isUp: Bool { state == "up" }
}

struct HostMetrics {
    var cpuTempC: Double? = nil                // CPU temperature in Celsius from Linux sysfs.
    var iowaitPercent: Double? = nil           // CPU proportion waiting for disk I/O.
    var diskReadBps: Double? = nil             // Physical-disk read/write bytes per second.
    var diskWriteBps: Double? = nil
    var diskReadIOPS: Double? = nil
    var diskWriteIOPS: Double? = nil
    var netRxTotal: Double? = nil              // Cumulative traffic since boot, excluding lo.
    var netTxTotal: Double? = nil
    var interfaces: [NetInterface] = []
    var cpuPercent: Double? = nil      // Overall CPU utilization, 0-100.
    var perCore: [Double] = []          // Per-core CPU utilization, 0-100, ordered by core index.
    var load1: Double = 0
    var load5: Double = 0
    var load15: Double = 0
    var memUsedKB: Int64 = 0
    var memTotalKB: Int64 = 0
    var swapUsedKB: Int64 = 0
    var swapTotalKB: Int64 = 0
    var disks: [DiskUsage] = []
    var gpus: [GPUInfo] = []
    var netRxBytesPerSec: Double? = nil
    var netTxBytesPerSec: Double? = nil
    var uptimeSecs: Double = 0

    var memPercent: Double { memTotalKB > 0 ? Double(memUsedKB) / Double(memTotalKB) * 100 : 0 }
    var hasSwap: Bool { swapTotalKB > 0 }
    var swapPercent: Double { swapTotalKB > 0 ? Double(swapUsedKB) / Double(swapTotalKB) * 100 : 0 }
}

struct Host: Identifiable, Codable {
    // latencyMs is a runtime probe result and is not written to JSON.
    enum CodingKeys: String, CodingKey {
        case id, name, addr, group, status, os, port, ssh, notes, specs, rdp, colorHex
    }

    let id: String
    let name: String
    let addr: String
    var group: String
    var status: HostStatus
    let os: String
    var port: Int = 22
    var ssh: SSHConnection? = nil
    var notes: String = ""
    var specs: HostSpecs? = nil
    var latencyMs: Int? = nil
    // RDP connection settings; nil denotes an SSH host.
    // Optional for backward compatibility with hosts.json files that lack this key.
    var rdp: RDPConnection? = nil
    // Optional #RRGGBB host color, automatically assigned and user-editable; optional preserves older hosts.json decoding.
    var colorHex: String? = nil

    /// Host color falls back to an ID-hashed palette for unassigned legacy data.
    /// Local Mac uses terminal-icon blue (#1976D2).
    var accent: Color { isLocal ? (HostPalette.color(hex: "#1976D2") ?? Pal.mauve) : (HostPalette.color(hex: colorHex) ?? HostPalette.fallback(forId: id)) }

    /// Fixed ID of the synthetic local host.
    static let localId = "local"
    /// Local Mac follows the same overview/connect/terminal/files/status flow as remote hosts.
    var isLocal: Bool { id == Self.localId }

    /// Whether this is an RDP remote-desktop host.
    var isRDP: Bool { rdp != nil }

    /// Hostname/IP only, without the login user.
    var ipOrHost: String {
        if let h = ssh?.host, !h.isEmpty { return h }
        if let h = rdp?.host, !h.isEmpty { return h }
        return addr.contains("@") ? String(addr.split(separator: "@").last ?? "") : addr
    }
}


/// Host-color palette and automatic assignment.
enum HostPalette {
    static let presets: [String] = [
        "#3B82F6", "#10B981", "#F59E0B", "#EF4444", "#8B5CF6",
        "#EC4899", "#06B6D4", "#84CC16", "#F97316", "#14B8A6",
    ]

    static func color(hex: String?) -> Color? {
        guard let hex, let v = value(hex) else { return nil }
        return Color(hex: v)
    }

    static func value(_ hex: String) -> UInt32? {
        var h = hex.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6 else { return nil }
        return UInt32(h, radix: 16)
    }

    static func hex(from color: Color) -> String {
        let c = NSColor(color).usingColorSpace(.sRGB) ?? .gray
        return String(format: "#%02X%02X%02X",
                      Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()),
                      Int((c.blueComponent * 255).rounded()))
    }

    /// Choose the least-used color, resolving ties by palette order to minimize duplicates.
    static func autoAssign(existing: [Host]) -> String {
        let used = Dictionary(grouping: existing.compactMap { $0.colorHex?.uppercased() }, by: { $0 }).mapValues(\.count)
        return presets.min { (used[$0] ?? 0) < (used[$1] ?? 0) } ?? presets[0]
    }

    static func fallback(forId id: String) -> Color {
        let sum = id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff }
        return Color(hex: value(presets[sum % presets.count]) ?? 0x3B82F6)
    }
}


/// Per-host favorite paths/files pinned atop the file panel for quick navigation/opening.
struct FavoritePath: Identifiable, Codable, Equatable {
    var id = UUID()
    let path: String
    let isDir: Bool
    var name: String

    init(path: String, isDir: Bool) {
        self.path = path
        self.isDir = isDir
        self.name = path == "/" ? "/" : (path as NSString).lastPathComponent
    }
}

/// Per-host recent files, newest first, shown in the file panel.
struct RecentFile: Identifiable, Codable, Equatable {
    let path: String
    let name: String
    var id: String { path }
}

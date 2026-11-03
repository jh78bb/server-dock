import SwiftUI

/// OpenSSH algorithm/encoding options; empty selects default negotiation.
enum SSHOptions {
    static let encodings: [(value: String, label: String)] = [
        ("", String(localized: "Default (UTF-8)")),
        ("UTF-8", "UTF-8"), ("GBK", "GBK"), ("GB2312", "GB2312"), ("GB18030", "GB18030"),
        ("Big5", String(localized: "Big5 (Traditional Chinese)")), ("Shift_JIS", String(localized: "Shift_JIS (Japanese)")), ("EUC-JP", String(localized: "EUC-JP (Japanese)")),
        ("EUC-KR", String(localized: "EUC-KR (Korean)")), ("KOI8-R", String(localized: "KOI8-R (Russian)")),
        ("ISO-8859-1", String(localized: "ISO-8859-1 (Western European)")), ("ISO-8859-15", "ISO-8859-15"),
        ("Windows-1251", String(localized: "Windows-1251 (Cyrillic)")), ("Windows-1252", "Windows-1252"),
        ("ASCII", "US-ASCII"),
    ]

    static let hostKeyAlgos: [(value: String, label: String)] = [
        ("", String(localized: "Default (Auto-Negotiate)")),
        ("ssh-ed25519", "ssh-ed25519"),
        ("rsa-sha2-512", "rsa-sha2-512"),
        ("rsa-sha2-256", "rsa-sha2-256"),
        ("ecdsa-sha2-nistp256", "ecdsa-sha2-nistp256"),
        ("ecdsa-sha2-nistp384", "ecdsa-sha2-nistp384"),
        ("ecdsa-sha2-nistp521", "ecdsa-sha2-nistp521"),
        ("ssh-rsa", String(localized: "ssh-rsa (legacy)")),
        ("ssh-dss", String(localized: "ssh-dss (legacy)")),
    ]

    static let ciphers: [(value: String, label: String)] = [
        ("", String(localized: "Default (Auto-Negotiate)")),
        ("chacha20-poly1305@openssh.com", "chacha20-poly1305"),
        ("aes256-gcm@openssh.com", "aes256-gcm"),
        ("aes128-gcm@openssh.com", "aes128-gcm"),
        ("aes256-ctr", "aes256-ctr"),
        ("aes192-ctr", "aes192-ctr"),
        ("aes128-ctr", "aes128-ctr"),
        ("aes256-cbc", String(localized: "aes256-cbc (legacy)")),
        ("aes128-cbc", String(localized: "aes128-cbc (legacy)")),
        ("3des-cbc", String(localized: "3des-cbc (legacy)")),
    ]

    static let kexAlgos: [(value: String, label: String)] = [
        ("", String(localized: "Default (Auto-Negotiate)")),
        ("curve25519-sha256", "curve25519-sha256"),
        ("curve25519-sha256@libssh.org", "curve25519-sha256@libssh.org"),
        ("ecdh-sha2-nistp256", "ecdh-sha2-nistp256"),
        ("ecdh-sha2-nistp384", "ecdh-sha2-nistp384"),
        ("ecdh-sha2-nistp521", "ecdh-sha2-nistp521"),
        ("diffie-hellman-group-exchange-sha256", "dh-group-exchange-sha256"),
        ("diffie-hellman-group16-sha512", "dh-group16-sha512"),
        ("diffie-hellman-group14-sha256", "dh-group14-sha256"),
        ("diffie-hellman-group14-sha1", String(localized: "dh-group14-sha1 (legacy)")),
    ]
}

enum AuthMethod: String, CaseIterable, Hashable, Codable {
    case password
    case key
    case ask           // Ask for a password on every connection without storing credentials.
    case agent         // SSH Agent (1Password, Secretive, system ssh-agent) keeps private keys outside the app.

    /// Decode legacy Chinese rawValue strings, but always encode current English values.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "\u{5bc6}\u{7801}": self = .password
        case "\u{5bc6}\u{94a5}": self = .key
        case "\u{6bcf}\u{6b21}\u{8be2}\u{95ee}": self = .ask
        default:
            guard let v = AuthMethod(rawValue: raw) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                        debugDescription: "Unknown AuthMethod \(raw)"))
            }
            self = v
        }
    }

    // Localized display label.
    var label: String {
        switch self {
        case .password: return String(localized: "Password")
        case .key: return String(localized: "Key")
        case .ask: return String(localized: "Ask every time")
        case .agent: return String(localized: "SSH Agent")
        }
    }
}

/// Detected local SSH Agent sockets: system, 1Password, Secretive.
enum SSHAgentCatalog {
    struct Agent: Hashable {
        let name: String
        let socket: String   // Empty uses system SSH_AUTH_SOCK.
        let installed: Bool
    }

    static func detect() -> [Agent] {
        let home = NSHomeDirectory()
        let fm = FileManager.default
        let sys = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] ?? ""
        let onePassword = "\(home)/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
        let secretive = "\(home)/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh"
        return [
            Agent(name: String(localized: "System ssh-agent"), socket: "", installed: !sys.isEmpty),
            Agent(name: "1Password", socket: onePassword, installed: fm.fileExists(atPath: onePassword)),
            Agent(name: "Secretive", socket: secretive, installed: fm.fileExists(atPath: secretive)),
        ]
    }
}

enum HostFormSection: String, CaseIterable, Hashable {
    case basic, connection, initial, proxy, advanced

    var label: String {
        switch self {
        case .basic: return String(localized: "General")
        case .connection: return String(localized: "Connection Settings")
        case .initial: return String(localized: "Initial Options")
        case .proxy: return String(localized: "Proxy Settings")
        case .advanced: return String(localized: "Advanced Settings")
        }
    }

    var icon: String {
        switch self {
        case .basic: return "server.rack"
        case .connection: return "network"
        case .initial: return "terminal"
        case .proxy: return "arrow.triangle.swap"
        case .advanced: return "slider.horizontal.3"
        }
    }
}

/// Add/edit host form state.
@MainActor
final class HostDraft: ObservableObject {
    // General information.
    @Published var group = ""
    @Published var name = ""
    @Published var address = ""
    @Published var authMethod: AuthMethod = .ask   // New hosts default to asking for a password on connection without storing it.
    @Published var user = "root"
    @Published var password = ""
    @Published var keyPath = ""        // Private-key file path, used for key authentication.
    @Published var agentSocket = ""    // SSH Agent socket path; empty uses system agent.
    @Published var keyId = ""          // Linked SSH key-library ID; when set, takes precedence over keyPath.
    @Published var notes = ""
    @Published var colorHex = HostPalette.presets[0]   // AddHostView replaces new hosts' colors with automatic assignments.

    // Connection settings.
    @Published var timeout = "10000"
    @Published var heartbeat = "5000"

    // Startup options.
    @Published var defaultPath = "~"
    @Published var initialCommand = ""

    // Proxy settings.
    @Published var disableProxy = false
    @Published var proxyURL = ""
    @Published var jumpHost = ""
    @Published var useBuiltinSSH = false
    @Published var localStartDir = ""   // Local directory for OS SSH; empty means home.
    @Published var sshCommand = ""      // Command executed in OS SSH mode.

    // Advanced settings.
    @Published var encoding = ""
    @Published var hostKeyAlgos = ""
    @Published var ciphers = ""
    @Published var kexAlgos = ""

    // Ports.
    @Published var port = "22"

    var canSave: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if useBuiltinSSH { return !address.trimmingCharacters(in: .whitespaces).isEmpty }
        return !sshCommand.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var resolvedGroup: String {
        let g = group.trimmingCharacters(in: .whitespaces)
        return g.isEmpty ? String(localized: "Ungrouped") : g
    }

    /// Populate the form from an existing host in edit mode.
    func load(from host: Host) {
        name = host.name
        group = host.group
        notes = host.notes
        colorHex = host.colorHex ?? HostPalette.hex(from: host.accent)
        guard let s = host.ssh else { return }
        user = s.user
        address = s.host
        port = String(s.port)
        authMethod = s.authMethod
        password = s.password
        keyPath = s.keyPath
        keyId = s.keyId
        agentSocket = s.agentSocket
        encoding = s.encoding
        hostKeyAlgos = s.hostKeyAlgos
        ciphers = s.ciphers
        kexAlgos = s.kexAlgos
        proxyURL = s.proxyURL
        jumpHost = s.jumpHost
        useBuiltinSSH = s.useBuiltinSSH
        localStartDir = s.localStartDir
        // For older hosts without a command, derive an equivalent from saved fields.
        sshCommand = s.sshCommand.isEmpty
            ? "ssh " + (s.port != 22 ? "-p \(s.port) " : "") + "\(s.user)@\(s.host)"
            : s.sshCommand
        disableProxy = s.disableProxy
        timeout = String(s.timeoutMs)
        heartbeat = String(s.heartbeatMs)
        initialCommand = s.initialCommand
        defaultPath = s.defaultPath
    }

    func buildConnection() -> SSHConnection {
        var c = buildRawConnection()
        // Resolve OS SSH host/user/port/key/jump settings for built-in file/monitoring features.
        let cmd = sshCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        if !useBuiltinSSH, !cmd.isEmpty {
            c.sshCommand = cmd
            c.localStartDir = localStartDir.trimmingCharacters(in: .whitespaces)
            if let r = SSHCommandResolver.resolve(cmd) {
                c.host = r.host
                if !r.user.isEmpty { c.user = r.user }
                c.port = r.port
                c.jumpHost = r.jump
                if !r.keyPath.isEmpty { c.authMethod = .key; c.keyPath = r.keyPath; c.keyId = "" }
                else { c.authMethod = password.isEmpty ? .ask : .password }
            }
        }
        return c
    }

    private func buildRawConnection() -> SSHConnection {
        SSHConnection(
            user: user.trimmingCharacters(in: .whitespaces).isEmpty ? "root" : user.trimmingCharacters(in: .whitespaces),
            host: address.trimmingCharacters(in: .whitespaces),
            port: Int(port) ?? 22,
            authMethod: authMethod,
            password: password,
            keyPath: keyPath.trimmingCharacters(in: .whitespaces),
            agentSocket: agentSocket.trimmingCharacters(in: .whitespaces),
            keyId: keyId,
            encoding: encoding,
            hostKeyAlgos: hostKeyAlgos,
            ciphers: ciphers,
            kexAlgos: kexAlgos,
            sshCommand: "",
            localStartDir: "",
            useBuiltinSSH: useBuiltinSSH,
            jumpHost: jumpHost.trimmingCharacters(in: .whitespaces),
            proxyURL: proxyURL.trimmingCharacters(in: .whitespaces),
            disableProxy: disableProxy,
            timeoutMs: Int(timeout) ?? 10000,
            heartbeatMs: Int(heartbeat) ?? 5000,
            initialCommand: initialCommand,
            defaultPath: defaultPath
        )
    }
}

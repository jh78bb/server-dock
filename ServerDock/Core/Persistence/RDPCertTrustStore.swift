import Foundation

/// Trusted RDP certificate identified by host:port; update fingerprint when its certificate changes.
struct RDPTrustedCert: Codable, Identifiable, Hashable {
    let host: String
    let port: Int
    var fingerprint: String
    var subject: String?
    var issuer: String?
    var trustedAt: Date

    var id: String { "\(host):\(port)" }
}

/// RDP trust store is the sole trust authority, populated by Always trust this computer on first connection.
/// Do not rely on FreeRDP known_hosts; native checks always delegate here to decide whether to prompt.
/// Store public certificate fingerprints as plaintext JSON at ~/Library/Application Support/serverdock/rdp_trusted_certs.json.
/// Read/write on the main thread, matching first-connection delegates and settings.
final class RDPCertTrustStore: ObservableObject {
    static let shared = RDPCertTrustStore()

    @Published private(set) var entries: [RDPTrustedCert]

    private init() { entries = Self.load() }

    /// Require permanent host:port trust plus matching fingerprint; mismatches prompt certificate-change verification.
    func isTrusted(host: String, port: Int, fingerprint: String) -> Bool {
        guard !fingerprint.isEmpty else { return false }
        return entries.contains { $0.host == host && $0.port == port && $0.fingerprint == fingerprint }
    }

    /// Persist/update host:port trust, refreshing fingerprint/time when the certificate changes.
    func trust(host: String, port: Int, fingerprint: String, subject: String?, issuer: String?) {
        let cert = RDPTrustedCert(host: host, port: port, fingerprint: fingerprint,
                                  subject: subject, issuer: issuer, trustedAt: Date())
        if let i = entries.firstIndex(where: { $0.host == host && $0.port == port }) {
            entries[i] = cert
        } else {
            entries.append(cert)
        }
        persist()
    }

    /// Settings Trusted Hosts revocation makes the next connection prompt again.
    func revoke(_ id: String) {
        entries.removeAll { $0.id == id }
        persist()
    }

    // MARK: - Persistence

    private static var url: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("serverdock", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("rdp_trusted_certs.json")
    }

    private static func load() -> [RDPTrustedCert] {
        guard let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([RDPTrustedCert].self, from: data) else { return [] }
        return items
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: Self.url, options: .atomic)
        }
    }
}

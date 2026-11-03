import Foundation

/// Per-host AI conversations persisted to ~/Library/Application Support/serverdock/aichat.json.
enum AIChatStore {
    private static var url: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("serverdock", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("aichat.json")
    }

    static func loadAll() -> [String: AIChatSessionData] {
        guard let data = try? Data(contentsOf: url),
              let map = try? JSONDecoder().decode([String: AIChatSessionData].self, from: data) else { return [:] }
        return map
    }

    private static var profilesURL: URL { url.deletingLastPathComponent().appendingPathComponent("aiprofiles.json") }

    /// Global AI profiles at ~/Library/Application Support/serverdock/aiprofiles.json.
    static func loadProfiles() -> [AIProfile] {
        guard let data = try? Data(contentsOf: profilesURL),
              let list = try? JSONDecoder().decode([AIProfile].self, from: data) else { return [] }
        return list
    }

    static func saveProfiles(_ list: [AIProfile]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? data.write(to: profilesURL, options: .atomic)
    }

    static func saveAll(_ map: [String: AIChatSessionData]) {
        guard let data = try? JSONEncoder().encode(map) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

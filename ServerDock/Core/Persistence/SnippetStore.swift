import Foundation

/// Snippet JSON at ~/Library/Application Support/serverdock/snippets.json.
/// Store nonsecret content as plaintext alongside KeyStore using the same approach.
enum SnippetStore {
    private static var dir: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("serverdock", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
    private static var url: URL { dir.appendingPathComponent("snippets.json") }

    static func load() -> [Snippet] {
        guard let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([Snippet].self, from: data) else { return [] }
        return items
    }

    static func save(_ snippets: [Snippet]) {
        guard !AppEnv.isScreenshotDemo else { return }
        if let data = try? JSONEncoder().encode(snippets) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

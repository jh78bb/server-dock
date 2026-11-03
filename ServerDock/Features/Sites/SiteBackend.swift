import Foundation

/// Site-root absolute entry path starts with /; directories have no trailing slash.
struct SiteEntry: Identifiable, Hashable {
    let name: String
    let path: String
    let isDir: Bool
    let size: Int64
    let modified: Date?
    var id: String { path }

    // Separate Comparable table-sort value because Optional is not Comparable.
    var sortSize: Int64 { isDir ? -1 : size }
    var sortModified: TimeInterval { modified?.timeIntervalSince1970 ?? 0 }
}

struct SiteError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

/// Shared SMB/WebDAV/S3 backend API honors Task.cancel throughout.
protocol SiteBackend: AnyObject {
    /// Connection test mounts SMB or lists the root for others.
    func connect() async throws
    func list(_ path: String) async throws -> [SiteEntry]
    func download(_ entry: SiteEntry, to local: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws
    func upload(_ local: URL, to path: String, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws
    func makeDirectory(_ path: String) async throws
    func delete(_ entry: SiteEntry) async throws
    func rename(_ entry: SiteEntry, to newPath: String) async throws
    func disconnect() async
    /// Whether folder move/rename operations are supported.
    var supportsRename: Bool { get }
    /// Initial tab path, e.g. SFTP home; defaults to root.
    func initialPath() async -> String
}

extension SiteBackend {
    var supportsRename: Bool { true }
    func initialPath() async -> String { "/" }
}

enum SiteBackendFactory {
    static func make(_ site: Site, secret: String) -> SiteBackend {
        switch site.kind {
        case .smb: return SMBBackend(site: site, password: secret)
        case .webdav: return WebDAVBackend(site: site, password: secret)
        case .s3: return S3Backend(site: site, secretKey: secret)
        case .sftp: return SFTPBackend(site: site, secret: secret)
        }
    }
}

// MARK: - Path utilities

enum SitePath {
    static func normalize(_ p: String) -> String {
        var parts: [String] = []
        for c in p.split(separator: "/", omittingEmptySubsequences: true) {
            if c == "." { continue }
            if c == ".." { _ = parts.popLast(); continue }
            parts.append(String(c))
        }
        return "/" + parts.joined(separator: "/")
    }
    static func join(_ dir: String, _ name: String) -> String { normalize(dir + "/" + name) }
    static func parent(_ p: String) -> String {
        let n = normalize(p)
        guard n != "/" else { return "/" }
        return normalize(String(n.dropLast(n.split(separator: "/").last?.count ?? 0)))
    }
    static func name(_ p: String) -> String { normalize(p).split(separator: "/").last.map(String.init) ?? "" }
    static func components(_ p: String) -> [String] { normalize(p).split(separator: "/").map(String.init) }
}

// MARK: - Shared SMB/local chunked copy with progress/cancellation

enum ChunkedCopy {
    static func copy(from src: URL, to dst: URL, progress: @Sendable (Int64, Int64) -> Void) async throws {
        let fm = FileManager.default
        let total = (try? fm.attributesOfItem(atPath: src.path)[.size] as? Int64) ?? 0
        try? fm.removeItem(at: dst)
        guard fm.createFile(atPath: dst.path, contents: nil) else { throw SiteError(String(localized: "Couldn't create the destination file.")) }
        let input = try FileHandle(forReadingFrom: src)
        let output = try FileHandle(forWritingTo: dst)
        defer { try? input.close(); try? output.close() }
        var done: Int64 = 0
        do {
            while true {
                try Task.checkCancellation()
                let chunk = try input.read(upToCount: 1 << 20) ?? Data()
                if chunk.isEmpty { break }
                try output.write(contentsOf: chunk)
                done += Int64(chunk.count)
                progress(done, total)
                await Task.yield()
            }
        } catch {
            try? output.close()
            try? fm.removeItem(at: dst)   // Remove partial files on cancel/failure.
            throw error
        }
    }
}

import Foundation

/// WebDAV uses URLSession PROPFIND/MKCOL/MOVE/DELETE, preemptive Basic and delegated Digest/NTLM.
final class WebDAVBackend: SiteBackend {
    private let site: Site
    private let password: String
    private let baseComponents: [String]     // Site base-path components, e.g. remote.php/dav/files/me.
    private let hostName: String

    init(site: Site, password: String) {
        self.site = site
        self.password = password
        // Handle pasted schemes/paths in the host field too.
        var h = site.host.trimmingCharacters(in: .whitespaces)
        var extraPath = ""
        if let r = h.range(of: "://") { h = String(h[r.upperBound...]) }
        if let slash = h.firstIndex(of: "/") { extraPath = String(h[slash...]); h = String(h[..<slash]) }
        if let colon = h.lastIndex(of: ":"), Int(h[h.index(after: colon)...]) != nil { h = String(h[..<colon]) }
        hostName = h
        baseComponents = SitePath.components(extraPath + "/" + site.path)
    }

    private var credential: URLCredential? {
        site.username.isEmpty ? nil : URLCredential(user: site.username, password: password, persistence: .none)
    }

    private func delegate(_ progress: (@Sendable (Int64, Int64) -> Void)? = nil) -> HTTPTransferDelegate {
        HTTPTransferDelegate(host: hostName, insecureTLS: site.insecureTLS, credential: credential, onProgress: progress)
    }

    private func url(_ path: String, trailingSlash: Bool = false) throws -> URL {
        var s = (site.useTLS ? "https" : "http") + "://" + (hostName.contains(":") ? "[\(hostName)]" : hostName)
        if site.port > 0 { s += ":\(site.port)" }
        let enc = HTTPSupport.encodePath(baseComponents + SitePath.components(path))
        s += "/" + enc
        if trailingSlash && !s.hasSuffix("/") { s += "/" }
        guard let u = URL(string: s) else { throw SiteError(String(localized: "Invalid server address.")) }
        return u
    }

    private func request(_ method: String, _ path: String, trailingSlash: Bool = false, headers: [String: String] = [:], body: Data? = nil) throws -> URLRequest {
        var r = URLRequest(url: try url(path, trailingSlash: trailingSlash))
        r.httpMethod = method
        r.httpBody = body
        if !site.username.isEmpty {
            let token = Data("\(site.username):\(password)".utf8).base64EncodedString()
            r.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")   // Preemptive Basic avoids round trips and PUT retries.
        }
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        return r
    }

    private func send(_ r: URLRequest, ok: Set<Int> = Set(200..<300)) async throws -> Data {
        let (data, resp) = try await HTTPSupport.wrap { try await HTTPSupport.session.data(for: r, delegate: delegate()) }
        try HTTPSupport.check(resp, data: data, ok: ok)
        return data
    }

    func connect() async throws { _ = try await list("/") }

    func list(_ path: String) async throws -> [SiteEntry] {
        let dir = SitePath.normalize(path)
        let body = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/><d:getlastmodified/></d:prop></d:propfind>
        """.utf8)
        let req = try request("PROPFIND", dir, trailingSlash: true,
                              headers: ["Depth": "1", "Content-Type": "application/xml; charset=utf-8"], body: body)
        let data = try await send(req, ok: [207, 200])
        guard let root = XMLNode.parse(data) else { throw SiteError(String(localized: "Couldn't read the server's response.")) }

        var out: [SiteEntry] = []
        for resp in root.all("response") {
            guard let href = resp.child("href")?.trimmed, !href.isEmpty else { continue }
            let full = resolve(href: href)
            guard let rel = relative(full), rel != dir else { continue }   // Exclude self and entries outside the base path.
            // Merge prop values from successful 200 OK propstat blocks.
            var isDir = false, size: Int64 = 0, mod: Date?
            for ps in resp.all("propstat") {
                if let st = ps.child("status")?.trimmed, !st.contains(" 200") { continue }
                guard let prop = ps.child("prop") else { continue }
                if prop.child("resourcetype")?.child("collection") != nil { isDir = true }
                if let l = prop.child("getcontentlength")?.trimmed, let n = Int64(l) { size = n }
                if let m = prop.child("getlastmodified")?.trimmed { mod = Self.parseDate(m) }
            }
            if href.hasSuffix("/") { isDir = true }
            out.append(SiteEntry(name: SitePath.name(rel), path: rel, isDir: isDir, size: isDir ? 0 : size, modified: mod))
        }
        return out
    }

    /// Convert an absolute href URL/path to a percent-decoded absolute path.
    private func resolve(href: String) -> String {
        var p = href
        if let r = href.range(of: "://"), let slash = href[r.upperBound...].firstIndex(of: "/") { p = String(href[slash...]) }
        return SitePath.normalize(p.removingPercentEncoding ?? p)
    }

    /// Convert server-absolute paths to site-root paths; nil outside the base.
    private func relative(_ full: String) -> String? {
        let comps = SitePath.components(full)
        guard comps.count >= baseComponents.count, Array(comps.prefix(baseComponents.count)) == baseComponents else { return nil }
        return "/" + comps.dropFirst(baseComponents.count).joined(separator: "/")
    }

    func download(_ entry: SiteEntry, to local: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let req = try request("GET", entry.path)
        try await HTTPSupport.download(req, to: local, delegate: delegate(progress))
    }

    func upload(_ local: URL, to path: String, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let req = try request("PUT", path)
        let (data, resp) = try await HTTPSupport.wrap { try await HTTPSupport.session.upload(for: req, fromFile: local, delegate: delegate(progress)) }
        try HTTPSupport.check(resp, data: data)
    }

    func makeDirectory(_ path: String) async throws {
        _ = try await send(try request("MKCOL", path, trailingSlash: true), ok: [200, 201, 204])
    }

    func delete(_ entry: SiteEntry) async throws {
        _ = try await send(try request("DELETE", entry.path, trailingSlash: entry.isDir), ok: [200, 202, 204])
    }

    func rename(_ entry: SiteEntry, to newPath: String) async throws {
        let dest = try url(newPath, trailingSlash: entry.isDir).absoluteString
        _ = try await send(try request("MOVE", entry.path, trailingSlash: entry.isDir,
                                       headers: ["Destination": dest, "Overwrite": "F"]), ok: [200, 201, 204])
    }

    func disconnect() async {}

    private static func parseDate(_ s: String) -> Date? {
        rfc1123.date(from: s) ?? iso8601.date(from: s)
    }
    private static let rfc1123: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()
    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

import Foundation
import CryptoKit

/// S3-compatible backend signs AWS Signature V4 for AWS/MinIO/R2/Wasabi/B2/Ceph/etc.
/// With a configured bucket, / is its root; otherwise / lists buckets and the first component names one.
/// Uploads use single PUT up to 5GB; folders use prefix/ keys.
final class S3Backend: SiteBackend {
    private let site: Site
    private let secretKey: String
    private let endpointHost: String
    private let fixedBucket: String

    init(site: Site, secretKey: String) {
        self.site = site
        self.secretKey = secretKey
        var h = site.host.trimmingCharacters(in: .whitespaces)
        if let r = h.range(of: "://") { h = String(h[r.upperBound...]) }
        if let slash = h.firstIndex(of: "/") { h = String(h[..<slash]) }
        if let colon = h.lastIndex(of: ":"), Int(h[h.index(after: colon)...]) != nil { h = String(h[..<colon]) }
        let region = site.region.isEmpty ? "us-east-1" : site.region
        endpointHost = h.isEmpty ? (region == "us-east-1" ? "s3.amazonaws.com" : "s3.\(region).amazonaws.com") : h
        fixedBucket = site.path.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
    }

    private var region: String { site.region.isEmpty ? "us-east-1" : site.region }

    private func delegate(_ progress: (@Sendable (Int64, Int64) -> Void)? = nil) -> HTTPTransferDelegate {
        HTTPTransferDelegate(host: endpointHost, insecureTLS: site.insecureTLS, credential: nil, onProgress: progress)
    }

    // MARK: Path resolution

    /// Map site path to bucket/key; bucketless / returns nil/empty.
    private func resolve(_ path: String) -> (bucket: String?, key: String) {
        let comps = SitePath.components(path)
        if !fixedBucket.isEmpty { return (fixedBucket, comps.joined(separator: "/")) }
        guard let first = comps.first else { return (nil, "") }
        return (first, comps.dropFirst().joined(separator: "/"))
    }

    /// Request host header/canonical URI for URL construction/signing.
    private func target(bucket: String?, key: String, query: [(String, String)]) throws -> (url: URL, host: String, canonicalURI: String) {
        let virtual = !site.pathStyle && bucket != nil && !fixedBucket.isEmpty && !bucket!.contains(".")
        var host = endpointHost
        var comps: [String] = []
        if let bucket {
            if virtual { host = "\(bucket).\(endpointHost)" } else { comps.append(bucket) }
        }
        if !key.isEmpty { comps.append(contentsOf: key.split(separator: "/", omittingEmptySubsequences: false).map(String.init)) }
        let uri = "/" + HTTPSupport.encodePath(comps)
        let hostHeader = site.port > 0 ? "\(host):\(site.port)" : host
        let q = Self.canonicalQuery(query)
        let scheme = site.useTLS ? "https" : "http"
        guard let url = URL(string: "\(scheme)://\(hostHeader)\(uri)" + (q.isEmpty ? "" : "?\(q)")) else {
            throw SiteError(String(localized: "Invalid server address."))
        }
        return (url, hostHeader, uri)
    }

    private static func canonicalQuery(_ q: [(String, String)]) -> String {
        var pairs: [(String, String)] = []
        for (k, v) in q { pairs.append((HTTPSupport.encodeSegment(k), HTTPSupport.encodeSegment(v))) }
        pairs.sort { a, b in a.0 == b.0 ? a.1 < b.1 : a.0 < b.0 }
        return pairs.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
    }

    // MARK: SigV4

    private func signedRequest(_ method: String, bucket: String?, key: String = "", query: [(String, String)] = [],
                               extraHeaders: [String: String] = [:], payloadHash: String) throws -> URLRequest {
        let t = try target(bucket: bucket, key: key, query: query)
        let now = Date()
        let amzDate = Self.amzDateFormatter.string(from: now)
        let dateStamp = String(amzDate.prefix(8))

        var headers: [String: String] = ["host": t.host, "x-amz-content-sha256": payloadHash, "x-amz-date": amzDate]
        for (k, v) in extraHeaders { headers[k.lowercased()] = v }
        let signedNames = headers.keys.sorted()
        let canonicalHeaders = signedNames.map { "\($0):\(headers[$0]!.trimmingCharacters(in: .whitespaces))\n" }.joined()
        let signedHeaders = signedNames.joined(separator: ";")
        let canonicalRequest = [method, t.canonicalURI, Self.canonicalQuery(query), canonicalHeaders, signedHeaders, payloadHash].joined(separator: "\n")

        let scope = "\(dateStamp)/\(region)/s3/aws4_request"
        let stringToSign = ["AWS4-HMAC-SHA256", amzDate, scope, HTTPSupport.sha256Hex(Data(canonicalRequest.utf8))].joined(separator: "\n")
        func hmac(_ key: Data, _ msg: String) -> Data {
            Data(HMAC<SHA256>.authenticationCode(for: Data(msg.utf8), using: SymmetricKey(data: key)))
        }
        let kDate = hmac(Data("AWS4\(secretKey)".utf8), dateStamp)
        let kSigning = hmac(hmac(hmac(kDate, region), "s3"), "aws4_request")
        let signature = hmac(kSigning, stringToSign).map { String(format: "%02x", $0) }.joined()

        var r = URLRequest(url: t.url)
        r.httpMethod = method
        for (k, v) in headers where k != "host" { r.setValue(v, forHTTPHeaderField: k) }   // URLSession supplies host.
        r.setValue("AWS4-HMAC-SHA256 Credential=\(site.username)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
                   forHTTPHeaderField: "Authorization")
        return r
    }

    private static let emptyHash = HTTPSupport.sha256Hex(Data())
    private static let amzDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f
    }()

    private func send(_ r: URLRequest, ok: Set<Int> = Set(200..<300)) async throws -> Data {
        let (data, resp) = try await HTTPSupport.wrap { try await HTTPSupport.session.data(for: r, delegate: delegate()) }
        try HTTPSupport.check(resp, data: data, ok: ok)
        return data
    }

    // MARK: SiteBackend

    func connect() async throws { _ = try await list("/") }

    func list(_ path: String) async throws -> [SiteEntry] {
        let dir = SitePath.normalize(path)
        let (bucket, key) = resolve(dir)

        // Bucket list.
        guard let bucket else {
            let data = try await send(try signedRequest("GET", bucket: nil, payloadHash: Self.emptyHash))
            guard let root = XMLNode.parse(data) else { throw SiteError(String(localized: "Couldn't read the server's response.")) }
            return (root.child("Buckets")?.all("Bucket") ?? []).compactMap { b in
                guard let n = b.child("Name")?.trimmed, !n.isEmpty else { return nil }
                return SiteEntry(name: n, path: "/" + n, isDir: true, size: 0, modified: b.child("CreationDate").flatMap { Self.parseDate($0.trimmed) })
            }
        }

        let prefix = key.isEmpty ? "" : key + "/"
        var out: [SiteEntry] = []
        var token: String?
        repeat {
            try Task.checkCancellation()
            var q: [(String, String)] = [("list-type", "2"), ("delimiter", "/"), ("prefix", prefix)]
            if let token { q.append(("continuation-token", token)) }
            let data = try await send(try signedRequest("GET", bucket: bucket, query: q, payloadHash: Self.emptyHash))
            guard let root = XMLNode.parse(data) else { throw SiteError(String(localized: "Couldn't read the server's response.")) }
            for cp in root.all("CommonPrefixes") {
                guard let p = cp.child("Prefix")?.trimmed, p.count > prefix.count else { continue }
                let name = String(p.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if name.isEmpty { continue }
                out.append(SiteEntry(name: name, path: SitePath.join(dir, name), isDir: true, size: 0, modified: nil))
            }
            for c in root.all("Contents") {
                guard let k = c.child("Key")?.trimmed, k != prefix, k.hasPrefix(prefix) else { continue }   // Exclude folder placeholders.
                let name = String(k.dropFirst(prefix.count))
                if name.isEmpty || name.contains("/") { continue }
                out.append(SiteEntry(name: name, path: SitePath.join(dir, name), isDir: false,
                                     size: Int64(c.child("Size")?.trimmed ?? "") ?? 0,
                                     modified: c.child("LastModified").flatMap { Self.parseDate($0.trimmed) }))
            }
            token = root.child("IsTruncated")?.trimmed == "true" ? root.child("NextContinuationToken")?.trimmed : nil
        } while token != nil
        return out
    }

    func download(_ entry: SiteEntry, to local: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let (bucket, key) = resolve(entry.path)
        guard let bucket, !key.isEmpty else { throw SiteError(String(localized: "Can't download this item.")) }
        let req = try signedRequest("GET", bucket: bucket, key: key, payloadHash: Self.emptyHash)
        try await HTTPSupport.download(req, to: local, delegate: delegate(progress))
    }

    func upload(_ local: URL, to path: String, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let (bucket, key) = resolve(path)
        guard let bucket, !key.isEmpty else { throw SiteError(String(localized: "Choose a bucket first: open a bucket before uploading.")) }
        // HTTPS uses UNSIGNED-PAYLOAD to avoid rereading large files; HTTP hashes/signs the body.
        let hash = try site.useTLS ? "UNSIGNED-PAYLOAD" : HTTPSupport.sha256Hex(file: local)
        let req = try signedRequest("PUT", bucket: bucket, key: key, payloadHash: hash)
        let (data, resp) = try await HTTPSupport.wrap { try await HTTPSupport.session.upload(for: req, fromFile: local, delegate: delegate(progress)) }
        try HTTPSupport.check(resp, data: data)
    }

    func makeDirectory(_ path: String) async throws {
        let (bucket, key) = resolve(path)
        guard let bucket else { throw SiteError(String(localized: "Invalid folder name.")) }
        if key.isEmpty {   // Create bucket.
            var body = Data()
            if region != "us-east-1" {
                body = Data("<CreateBucketConfiguration xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"><LocationConstraint>\(region)</LocationConstraint></CreateBucketConfiguration>".utf8)
            }
            var req = try signedRequest("PUT", bucket: bucket, payloadHash: HTTPSupport.sha256Hex(body))
            req.httpBody = body
            _ = try await send(req)
            return
        }
        var req = try signedRequest("PUT", bucket: bucket, key: key + "/", payloadHash: Self.emptyHash)
        req.httpBody = Data()
        _ = try await send(req)
    }

    func delete(_ entry: SiteEntry) async throws {
        let (bucket, key) = resolve(entry.path)
        guard let bucket else { return }
        if key.isEmpty {   // Delete empty bucket; report server rejection.
            _ = try await send(try signedRequest("DELETE", bucket: bucket, payloadHash: Self.emptyHash))
            return
        }
        if entry.isDir {
            for k in try await allKeys(bucket: bucket, prefix: key + "/") {
                try Task.checkCancellation()
                _ = try await send(try signedRequest("DELETE", bucket: bucket, key: k, payloadHash: Self.emptyHash))
            }
        } else {
            _ = try await send(try signedRequest("DELETE", bucket: bucket, key: key, payloadHash: Self.emptyHash))
        }
    }

    func rename(_ entry: SiteEntry, to newPath: String) async throws {
        let (bucket, key) = resolve(entry.path)
        let (newBucket, newKey) = resolve(newPath)
        guard let bucket, let newBucket, !key.isEmpty, !newKey.isEmpty else {
            throw SiteError(String(localized: "Buckets can't be renamed."))
        }
        let pairs: [(String, String)] = entry.isDir
            ? try await allKeys(bucket: bucket, prefix: key + "/").map { ($0, newKey + "/" + $0.dropFirst(key.count + 1)) }
            : [(key, newKey)]
        for (from, to) in pairs {
            try Task.checkCancellation()
            let source = "/" + HTTPSupport.encodePath([bucket] + from.split(separator: "/", omittingEmptySubsequences: false).map(String.init))
            var req = try signedRequest("PUT", bucket: newBucket, key: to, extraHeaders: ["x-amz-copy-source": source], payloadHash: Self.emptyHash)
            req.httpBody = Data()
            _ = try await send(req)
            _ = try await send(try signedRequest("DELETE", bucket: bucket, key: from, payloadHash: Self.emptyHash))
        }
    }

    func disconnect() async {}

    /// List every key under prefix recursively without a delimiter.
    private func allKeys(bucket: String, prefix: String) async throws -> [String] {
        var keys: [String] = []
        var token: String?
        repeat {
            try Task.checkCancellation()
            var q: [(String, String)] = [("list-type", "2"), ("prefix", prefix)]
            if let token { q.append(("continuation-token", token)) }
            let data = try await send(try signedRequest("GET", bucket: bucket, query: q, payloadHash: Self.emptyHash))
            guard let root = XMLNode.parse(data) else { throw SiteError(String(localized: "Couldn't read the server's response.")) }
            keys += root.all("Contents").compactMap { $0.child("Key")?.trimmed }
            token = root.child("IsTruncated")?.trimmed == "true" ? root.child("NextContinuationToken")?.trimmed : nil
        } while token != nil
        return keys
    }

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let iso: ISO8601DateFormatter = ISO8601DateFormatter()
    private static func parseDate(_ s: String) -> Date? { isoFrac.date(from: s) ?? iso.date(from: s) }
}

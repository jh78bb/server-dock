import Foundation
import CryptoKit

/// Shared WebDAV/S3 HTTP delegate handles self-signed trust, Digest/NTLM auth, and progress.
final class HTTPTransferDelegate: NSObject, URLSessionTaskDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
    let host: String
    let insecureTLS: Bool
    let credential: URLCredential?
    var onProgress: (@Sendable (Int64, Int64) -> Void)?
    private var authTried = false

    init(host: String, insecureTLS: Bool, credential: URLCredential?, onProgress: (@Sendable (Int64, Int64) -> Void)? = nil) {
        self.host = host; self.insecureTLS = insecureTLS; self.credential = credential; self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handle(challenge, completionHandler)
    }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handle(challenge, completionHandler)
    }

    private func handle(_ ch: URLAuthenticationChallenge,
                        _ done: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = ch.protectionSpace
        if space.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            if insecureTLS, space.host == host, let trust = space.serverTrust {
                done(.useCredential, URLCredential(trust: trust))
            } else {
                done(.performDefaultHandling, nil)
            }
            return
        }
        // Present Basic/Digest/NTLM credentials once; fail incorrect credentials with 401 instead of retrying forever.
        if let credential, !authTried {
            authTried = true
            done(.useCredential, credential)
        } else {
            done(.cancelAuthenticationChallenge, nil)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        onProgress?(totalBytesSent, totalBytesExpectedToSend)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        onProgress?(totalBytesWritten, totalBytesExpectedToWrite)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

enum HTTPSupport {
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 60
        c.timeoutIntervalForResource = 60 * 60 * 24
        c.httpCookieStorage = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    static func check(_ response: URLResponse, data: Data? = nil, ok: Set<Int> = Set(200..<300)) throws {
        guard let http = response as? HTTPURLResponse else { throw SiteError(String(localized: "Invalid server response.")) }
        guard ok.contains(http.statusCode) else { throw error(status: http.statusCode, data: data) }
    }

    static func error(status: Int, data: Data?) -> SiteError {
        switch status {
        case 401: return SiteError(String(localized: "Authentication failed (401). Check the username and password."))
        case 403: return SiteError(String(localized: "Access denied (403)."))
        case 404: return SiteError(String(localized: "Not found (404)."))
        case 405: return SiteError(String(localized: "The server doesn't allow this operation (405)."))
        case 409: return SiteError(String(localized: "Conflict (409): the parent folder may not exist."))
        case 423: return SiteError(String(localized: "The resource is locked (423)."))
        case 507: return SiteError(String(localized: "The server has insufficient storage (507)."))
        default:
            if let data, let msg = S3Errors.message(from: data) { return SiteError("HTTP \(status): \(msg)") }
            return SiteError("HTTP \(status)")
        }
    }

    /// Encode path segments using RFC 3986 unreserved characters, matching S3 SigV4.
    static func encodeSegment(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    static func encodePath(_ components: [String]) -> String {
        components.map(encodeSegment).joined(separator: "/")
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Hex(file: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: file)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Map URLSession cancellation to CancellationError and rejected auth challenges to authentication failures.
    static func wrap<T>(_ op: () async throws -> T) async throws -> T {
        do { return try await op() } catch let e as URLError {
            if Task.isCancelled { throw CancellationError() }
            if e.code == .cancelled || e.code == .userCancelledAuthentication {
                throw error(status: 401, data: nil)
            }
            if e.code == .serverCertificateUntrusted || e.code == .serverCertificateHasBadDate || e.code == .serverCertificateHasUnknownRoot
                || e.code == .secureConnectionFailed {
                throw SiteError(String(localized: "The server's certificate isn't trusted. Enable \"Allow untrusted certificate\" in the storage settings if you trust this server."))
            }
            throw SiteError(e.localizedDescription)
        }
    }

    /// Cancellation-aware download uses a temporary file before moving to destination.
    static func download(_ request: URLRequest, to local: URL, delegate: HTTPTransferDelegate) async throws {
        let (tmp, response) = try await wrap { try await session.download(for: request, delegate: delegate) }
        do {
            try check(response)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
        let fm = FileManager.default
        try? fm.removeItem(at: local)
        try fm.moveItem(at: tmp, to: local)
    }
}

enum S3Errors {
    /// Extract Message from S3/general XML error bodies.
    static func message(from data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8), text.contains("<Message>") else { return nil }
        let code = text.range(of: "<Code>").flatMap { r1 in text.range(of: "</Code>").map { String(text[r1.upperBound..<$0.lowerBound]) } }
        let msg = text.range(of: "<Message>").flatMap { r1 in text.range(of: "</Message>").map { String(text[r1.upperBound..<$0.lowerBound]) } }
        return [code, msg].compactMap { $0 }.joined(separator: ": ")
    }
}

// MARK: - Minimal XML element-tree parser

/// Namespace-independent XML node for PROPFIND/S3 responses.
final class XMLNode {
    let name: String            // Local name without prefix.
    var text = ""
    var children: [XMLNode] = []
    init(_ name: String) { self.name = name }

    func child(_ n: String) -> XMLNode? { children.first { $0.name == n } }
    func all(_ n: String) -> [XMLNode] { children.filter { $0.name == n } }
    func find(_ n: String) -> XMLNode? {
        if name == n { return self }
        for c in children { if let f = c.find(n) { return f } }
        return nil
    }
    var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    static func parse(_ data: Data) -> XMLNode? {
        let builder = XMLTreeBuilder()
        let p = XMLParser(data: data)
        p.shouldProcessNamespaces = true
        p.delegate = builder
        guard p.parse() else { return nil }
        return builder.root
    }
}

private final class XMLTreeBuilder: NSObject, XMLParserDelegate {
    var root: XMLNode?
    private var stack: [XMLNode] = []
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let n = XMLNode(elementName.split(separator: ":").last.map(String.init) ?? elementName)   // Strip any remaining namespace prefix.
        stack.last?.children.append(n)
        if root == nil { root = n }
        stack.append(n)
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        _ = stack.popLast()
    }
}

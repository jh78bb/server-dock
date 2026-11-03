import SwiftUI
import Foundation

struct HTTPCheckResult {
    var statusCode: Int?
    var totalMs: Double?
    var connectMs: Double?
    var firstByteMs: Double?
    var bytes: Int64?
    var remoteIP = ""
    var redirect = ""
    var finalURL = ""
    var headers: [(String, String)] = []
    var error: String?
    var ranAt = Date()

    var isSuccess: Bool { (statusCode ?? 0) >= 200 && (statusCode ?? 0) < 400 && error == nil }
}

struct HTTPCheckOptions {
    var url: String
    var head = false
    var follow = false
    var insecure = false
    var timeout: Double = 15
}

/// Check URL status/latency/headers through server curl or directly on this Mac.
enum HTTPChecker {
    static func normalizedURL(_ text: String) -> URL? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "http://" + s }
        guard let u = URL(string: s), let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https", u.host != nil else { return nil }
        return u
    }

    // MARK: Server curl

    private static func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }

    static func serverCommand(_ url: URL, _ o: HTTPCheckOptions) -> String {
        let flags = (o.insecure ? " -k" : "") + (o.follow ? " -L" : "") + (o.head ? " -I" : "")
        let fmt = "\\n__CURL__%{http_code}|%{time_connect}|%{time_starttransfer}|%{time_total}|%{size_download}|%{redirect_url}|%{remote_ip}|%{url_effective}\\n"
        return "command -v curl >/dev/null 2>&1 || { echo __NOCURL__; exit 127; }; "
            + "curl -sS -m \(Int(o.timeout))\(flags) -o /dev/null -D - -w '\(fmt)' \(q(url.absoluteString)) 2>&1"
    }

    static func runOnServer(_ url: URL, _ o: HTTPCheckOptions, fs: RemoteFS) async -> HTTPCheckResult {
        let r = await fs.run(serverCommand(url, o), timeout: o.timeout + 10)
        let out = String(decoding: r.data, as: UTF8.self)
        let err = String(decoding: r.stderr, as: UTF8.self)
        return parseCurl(out: out, err: err, code: r.code)
    }

    static func parseCurl(out: String, err: String, code: Int32) -> HTTPCheckResult {
        var res = HTTPCheckResult()
        if out.contains("__NOCURL__") { res.error = String(localized: "curl isn't installed on this server."); return res }
        guard let marker = out.range(of: "__CURL__") else {
            let msg = (out + err).trimmingCharacters(in: .whitespacesAndNewlines)
            res.error = msg.isEmpty ? String(localized: "No response.") : msg
            return res
        }
        let headerPart = String(out[..<marker.lowerBound])
        let stats = out[marker.upperBound...].split(separator: "\n").first.map(String.init) ?? ""
        let f = stats.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        if f.count >= 8 {
            let code = Int(f[0]) ?? 0
            res.statusCode = code == 0 ? nil : code
            res.connectMs = Double(f[1]).map { $0 * 1000 }
            res.firstByteMs = Double(f[2]).map { $0 * 1000 }
            res.totalMs = Double(f[3]).map { $0 * 1000 }
            res.bytes = Int64(f[4])
            res.redirect = f[5]; res.remoteIP = f[6]; res.finalURL = f[7]
        }
        // With -L use only the final response-header block; report curl error lines as failures.
        let lines = headerPart.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n")
        if let e = lines.last(where: { $0.hasPrefix("curl:") }) { res.error = e }
        var block: [String] = []
        for l in lines {
            if l.hasPrefix("HTTP/") { block = [] }
            if !l.hasPrefix("curl:") && !l.isEmpty { block.append(l) }
        }
        res.headers = block.filter { !$0.hasPrefix("HTTP/") }.compactMap {
            guard let i = $0.firstIndex(of: ":") else { return nil }
            return (String($0[..<i]), $0[$0.index(after: i)...].trimmingCharacters(in: .whitespaces))
        }
        if res.statusCode == nil && res.error == nil { res.error = String(localized: "No response.") }
        return res
    }

    // MARK: This Mac

    private final class Delegate: NSObject, URLSessionTaskDelegate {
        let follow: Bool, insecure: Bool
        var metrics: URLSessionTaskMetrics?
        init(follow: Bool, insecure: Bool) { self.follow = follow; self.insecure = insecure }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(follow ? request : nil)
        }
        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            if insecure, challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
               let t = challenge.protectionSpace.serverTrust { completionHandler(.useCredential, URLCredential(trust: t)) }
            else { completionHandler(.performDefaultHandling, nil) }
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) { self.metrics = metrics }
    }

    static func runLocally(_ url: URL, _ o: HTTPCheckOptions) async -> HTTPCheckResult {
        var res = HTTPCheckResult()
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: o.timeout)
        req.httpMethod = o.head ? "HEAD" : "GET"
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieStorage = nil
        let session = URLSession(configuration: cfg)
        let d = Delegate(follow: o.follow, insecure: o.insecure)
        let start = Date()
        do {
            let (data, resp) = try await session.data(for: req, delegate: d)
            res.totalMs = Date().timeIntervalSince(start) * 1000
            if let http = resp as? HTTPURLResponse {
                res.statusCode = http.statusCode
                res.headers = http.allHeaderFields.compactMap { k, v in (k as? String).map { ($0, "\(v)") } }.sorted { $0.0.lowercased() < $1.0.lowercased() }
                res.redirect = (http.value(forHTTPHeaderField: "Location")).map { URL(string: $0, relativeTo: url)?.absoluteString ?? $0 } ?? ""
                res.finalURL = http.url?.absoluteString ?? url.absoluteString
            }
            res.bytes = Int64(data.count)
            if let t = d.metrics?.transactionMetrics.last {
                if let a = t.connectStartDate, let b = t.connectEndDate { res.connectMs = b.timeIntervalSince(a) * 1000 }
                if let a = t.requestStartDate ?? t.connectEndDate, let b = t.responseStartDate { res.firstByteMs = b.timeIntervalSince(start) * 1000; _ = a }
                res.remoteIP = t.remoteAddress ?? ""
            }
        } catch {
            res.totalMs = Date().timeIntervalSince(start) * 1000
            res.error = (error as? URLError)?.localizedDescription ?? error.localizedDescription
        }
        return res
    }
}

/// Per-host HTTP-check sheet with results and recent URL.
struct HTTPCheckSheet: View {
    let host: Host
    var prefill: String? = nil
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var theme = ThemeManager.shared

    @State private var urlText = ""
    @State private var fromServer = true
    @State private var head = false
    @State private var follow = false
    @State private var insecure = false
    @State private var running = false
    @State private var result: HTTPCheckResult?
    @State private var recents: [String] = []
    @State private var showHeaders = false

    private var recentKey: String { "httpCheckRecents." + host.id }
    private var canRemote: Bool { !host.isLocal }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(lucideSymbol: "waveform.badge.magnifyingglass").foregroundStyle(host.accent)
                Text("HTTP Check").font(.system(size: 15, weight: .semibold)).foregroundStyle(Pal.text)
                Text(host.name).font(.system(size: 11)).foregroundStyle(Pal.overlay)
                Spacer()
                Button { dismiss() } label: { Image(lucideSymbol: "xmark").font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.overlay) }
                    .buttonStyle(.plain).pointerCursor()
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            Divider().overlay(Pal.fill(0.06))

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        ThemedTextField(verbatim: "https://example.com/health", text: $urlText, autofocus: true, onSubmit: run)
                        if !recents.isEmpty {
                            Menu {
                                ForEach(recents, id: \.self) { r in Button(r) { urlText = r } }
                                Divider()
                                Button("Clear History") { recents = []; UserDefaults.standard.removeObject(forKey: recentKey) }
                            } label: { Image(lucideSymbol: "clock.arrow.circlepath") }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                            .help(String(localized: "Recent URLs"))
                        }
                    }
                    HStack(spacing: 14) {
                        if canRemote {
                            SegmentedControl(options: [(value: true, label: LocalizedStringKey("From Server")),
                                                       (value: false, label: LocalizedStringKey("From This Mac"))], selection: $fromServer)
                                .frame(width: 250)
                        }
                        SegmentedControl(options: [(value: false, verbatim: "GET"), (value: true, verbatim: "HEAD")], selection: $head)
                            .frame(width: 120)
                        Spacer()
                    }
                    HStack(spacing: 16) {
                        Toggle("Follow redirects", isOn: $follow).toggleStyle(.checkbox)
                        Toggle("Ignore certificate errors", isOn: $insecure).toggleStyle(.checkbox)
                        Spacer()
                        Button(action: run) {
                            HStack(spacing: 6) { if running { ProgressView().controlSize(.small) }; Text("Check") }
                                .font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                                .padding(.horizontal, 18).padding(.vertical, 7)
                                .background(Pal.tint, in: RoundedRectangle(cornerRadius: 7)).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).pointerCursor().disabled(running || HTTPChecker.normalizedURL(urlText) == nil)
                    }
                    .font(.system(size: 12))
                    if canRemote && fromServer {
                        Text("Runs curl on the server, so it shows whether the service answers from the server's own point of view (for example http://localhost:8080).")
                            .font(.system(size: 11)).foregroundStyle(Pal.overlay)
                    }
                    if let r = result { resultCard(r) }
                }
                .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 560, height: 520)
        .background(Pal.solidBase)
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .onAppear {
            recents = UserDefaults.standard.stringArray(forKey: recentKey) ?? []
            fromServer = canRemote
            if urlText.isEmpty { urlText = prefill ?? recents.first ?? "" }
        }
    }

    private func resultCard(_ r: HTTPCheckResult) -> some View {
        let color: Color = r.error != nil ? Pal.red : ((r.statusCode ?? 0) >= 400 ? Pal.red : ((r.statusCode ?? 0) >= 300 ? Pal.yellow : Pal.green))
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(r.statusCode.map { "\($0) \(HTTPURLResponse.localizedString(forStatusCode: $0).capitalized)" } ?? String(localized: "No response"))
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(color)
                Spacer()
                Text(r.ranAt, style: .time).font(.system(size: 11)).foregroundStyle(Pal.overlay)
            }
            if let e = r.error {
                Text(e).font(.system(size: 12, design: .monospaced)).foregroundStyle(Pal.red).textSelection(.enabled)
            }
            HStack(spacing: 18) {
                stat(String(localized: "Total"), r.totalMs.map(ms))
                stat(String(localized: "Connect"), r.connectMs.map(ms))
                stat(String(localized: "First byte"), r.firstByteMs.map(ms))
                stat(String(localized: "Size"), r.bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) })
                stat(String(localized: "Address"), r.remoteIP.isEmpty ? nil : r.remoteIP)
            }
            if !r.redirect.isEmpty {
                Text("→ \(r.redirect)").font(.system(size: 12, design: .monospaced)).foregroundStyle(Pal.subtext).textSelection(.enabled)
            }
            if !r.headers.isEmpty {
                DisclosureGroup(isExpanded: $showHeaders) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(r.headers.enumerated()), id: \.offset) { _, h in
                            HStack(alignment: .top, spacing: 6) {
                                Text(h.0).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(Pal.subtext)
                                Text(h.1).font(.system(size: 11, design: .monospaced)).foregroundStyle(Pal.text).textSelection(.enabled)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                } label: { Text("Response headers (\(r.headers.count))").font(.system(size: 12)).foregroundStyle(Pal.subtext) }
            }
        }
        .padding(14)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(0.35), lineWidth: 1))
    }

    private func stat(_ label: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 10)).foregroundStyle(Pal.overlay)
            Text(value ?? "—").font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(Pal.text)
        }
    }

    private func ms(_ v: Double) -> String { v < 1000 ? String(format: "%.0f ms", v) : String(format: "%.2f s", v / 1000) }

    private func run() {
        guard !running, let url = HTTPChecker.normalizedURL(urlText) else { return }
        running = true; result = nil
        let opts = HTTPCheckOptions(url: url.absoluteString, head: head, follow: follow, insecure: insecure)
        let remote = canRemote && fromServer
        let ssh = host.ssh ?? SSHConnection()
        Task {
            let r = remote ? await HTTPChecker.runOnServer(url, opts, fs: RemoteFS(ssh)) : await HTTPChecker.runLocally(url, opts)
            result = r; running = false
            var list = recents.filter { $0 != url.absoluteString }
            list.insert(url.absoluteString, at: 0)
            recents = Array(list.prefix(8))
            UserDefaults.standard.set(recents, forKey: recentKey)
        }
    }
}

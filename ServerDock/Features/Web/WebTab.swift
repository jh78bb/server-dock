import SwiftUI
import WebKit
import Darwin

/// In-app web session owns WKWebView so page state survives tab changes.
@MainActor
final class WebSession: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    let host: Host
    /// Optional tunnel shown in toolbar; it continues in background after closing the tab.
    let tunnelSummary: String?

    @Published var urlText: String
    @Published private(set) var title: String = ""
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var isLoading = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var failure: String?

    private var observers: [NSKeyValueObservation] = []
    private let initialURL: URL

    init(host: Host, url: URL, tunnelSummary: String?) {
        self.host = host
        self.initialURL = url
        self.tunnelSummary = tunnelSummary
        self.urlText = url.absoluteString
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()      // Do not persist server login data outside the app.
        webView = WKWebView(frame: .zero, configuration: cfg)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        observers = [
            webView.observe(\.canGoBack) { [weak self] v, _ in Task { @MainActor in self?.canGoBack = v.canGoBack } },
            webView.observe(\.canGoForward) { [weak self] v, _ in Task { @MainActor in self?.canGoForward = v.canGoForward } },
            webView.observe(\.isLoading) { [weak self] v, _ in Task { @MainActor in self?.isLoading = v.isLoading } },
            webView.observe(\.estimatedProgress) { [weak self] v, _ in Task { @MainActor in self?.progress = v.estimatedProgress } },
            webView.observe(\.title) { [weak self] v, _ in Task { @MainActor in self?.title = v.title ?? "" } },
            webView.observe(\.url) { [weak self] v, _ in Task { @MainActor in if let u = v.url { self?.urlText = u.absoluteString } } },
        ]
        load(url)
    }

    func load(_ url: URL) { failure = nil; webView.load(URLRequest(url: url)) }
    func goHome() { load(initialURL) }
    func reload() { failure = nil; webView.reload() }
    func stop() { webView.stopLoading() }
    func close() { webView.stopLoading(); observers.removeAll() }

    /// Normalize schemeless addresses to the tunnel's HTTP scheme.
    func submitAddress() {
        var s = urlText.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return }
        if !s.contains("://") { s = "http://" + s }
        if let u = URL(string: s) { load(u) }
    }

    // MARK: WKNavigationDelegate

    /// Allow self-signed certificates only for tunnel-local 127.0.0.1/localhost management pages.
    /// Traffic is SSH-encrypted and certificates are not issued to localhost, so restrict this exception to that local port.
    nonisolated func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                             completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        if space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           ["127.0.0.1", "localhost", "::1"].contains(space.host), let trust = space.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { report(error) }
    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { report(error) }

    nonisolated private func report(_ error: Error) {
        let e = error as NSError
        if e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled { return }
        let msg = e.code == NSURLErrorCannotConnectToHost || e.code == NSURLErrorNetworkConnectionLost
            ? String(localized: "Couldn't reach the service through the tunnel. Check that the tunnel is running and the service is listening on the server.")
            : e.localizedDescription
        Task { @MainActor in self.failure = msg }
    }

    /// Open target=_blank links in the same tab.
    nonisolated func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                             for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }
}

private struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct WebTabView: View {
    @ObservedObject var session: WebSession
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if session.isLoading {
                ProgressView(value: session.progress).progressViewStyle(.linear).controlSize(.mini).tint(session.host.accent)
            } else {
                Divider().overlay(Pal.fill(0.06))
            }
            ZStack {
                WebViewHost(webView: session.webView)
                if let f = session.failure {
                    VStack(spacing: 10) {
                        Image(lucideSymbol: "exclamationmark.triangle").font(.system(size: 28)).foregroundStyle(Pal.red)
                        Text(f).font(.system(size: 12)).foregroundStyle(Pal.subtext).multilineTextAlignment(.center).frame(maxWidth: 380)
                        Button { session.reload() } label: {
                            Text("Retry").font(.system(size: 12)).foregroundStyle(Pal.tint)
                                .padding(.horizontal, 14).padding(.vertical, 6)
                                .background(Pal.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 7)).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).pointerCursor()
                    }
                    .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity).background(Pal.base)
                }
            }
        }
        .background(Pal.base)
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            button("chevron.left", help: String(localized: "Back"), disabled: !session.canGoBack) { session.webView.goBack() }
            button("chevron.right", help: String(localized: "Forward"), disabled: !session.canGoForward) { session.webView.goForward() }
            button(session.isLoading ? "xmark" : "arrow.clockwise", help: session.isLoading ? String(localized: "Stop") : String(localized: "Reload")) {
                session.isLoading ? session.stop() : session.reload()
            }
            button("house", help: String(localized: "Back to the tunnel's start page")) { session.goHome() }
            TextField("", text: $session.urlText)
                .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced)).foregroundStyle(Pal.text)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Pal.fill(0.06), in: RoundedRectangle(cornerRadius: 7))
                .onSubmit { session.submitAddress() }
            if let t = session.tunnelSummary {
                HStack(spacing: 4) {
                    Image(lucideSymbol: "arrow.left.arrow.right").font(.system(size: 9))
                    Text(t).font(.system(size: 10, design: .monospaced)).lineLimit(1)
                }
                .foregroundStyle(Pal.subtext).padding(.horizontal, 7).padding(.vertical, 4)
                .background(Pal.fill(0.06), in: Capsule())
                .help(String(localized: "SSH tunnel used by this tab. It keeps running after the tab is closed; stop it from Port Forwarding."))
            }
            button("safari", help: String(localized: "Open in Default Browser")) {
                if let u = session.webView.url ?? URL(string: session.urlText) { NSWorkspace.shared.open(u) }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
    }

    private func button(_ symbol: String, help: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(lucideSymbol: symbol).font(.system(size: 12))
                .foregroundStyle(disabled ? Pal.overlay.opacity(0.5) : Pal.subtext)
                .frame(width: 26, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor().disabled(disabled).help(help)
    }
}

/// Find a free local TCP listener port.
enum LocalPort {
    static func free() -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { return nil }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let got = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        return got == 0 ? Int(UInt16(bigEndian: addr.sin_port)) : nil
    }
}

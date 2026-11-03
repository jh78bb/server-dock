import AppKit
import SwiftUI
import WebKit

// MARK: - Themed release-note WebView (external links)

/// Render appcast HTML notes with theme-matching CSS and a transparent background supplied by the outer card.
/// Open links in the system browser instead of navigating the embedded view.
struct ReleaseNotesWebView: NSViewRepresentable {
    let html: String
    @ObservedObject private var theme = ThemeManager.shared

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.navigationDelegate = context.coordinator
        web.setValue(false, forKey: "drawsBackground")   // Transparency reveals the card background and prevents white flashes.
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        web.loadHTMLString(themedDocument(html), baseURL: nil)
    }

    private func themedDocument(_ body: String) -> String {
        let text = cssHex(Pal.text), sub = cssHex(Pal.subtext)
        let bright = cssHex(Pal.textBright), link = cssHex(Pal.mauve)
        let code = cssHex(Pal.surface0)
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          :root { color-scheme: \(theme.isDark ? "dark" : "light"); }
          html,body { background: transparent; margin: 0; padding: 0; }
          body { color: \(text); font: 13px/1.55 -apple-system, "PingFang SC", sans-serif; padding: 2px 4px 8px; }
          h1,h2,h3,h4 { color: \(bright); margin: 0.6em 0 0.35em; font-weight: 600; }
          h1 { font-size: 16px; } h2 { font-size: 15px; } h3 { font-size: 14px; }
          p,li { color: \(text); margin: 0.35em 0; }
          ul,ol { padding-left: 1.3em; margin: 0.35em 0; }
          a { color: \(link); text-decoration: none; }
          a:hover { text-decoration: underline; }
          small, .muted { color: \(sub); }
          code,pre { background: \(code); border-radius: 5px; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
          code { padding: 1px 4px; font-size: 12px; }
          pre { padding: 8px 10px; overflow-x: auto; } pre code { background: transparent; padding: 0; }
          hr { border: 0; border-top: 1px solid \(code); margin: 0.8em 0; }
        </style></head><body>\(body)</body></html>
        """
    }

    private func cssHex(_ color: Color) -> String {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .gray
        return String(format: "#%02X%02X%02X",
                      Int(round(ns.redComponent * 255)),
                      Int(round(ns.greenComponent * 255)),
                      Int(round(ns.blueComponent * 255)))
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}

// MARK: - Update panel (plan B: unified ThemedXxx components driven by state)

/// Update panel hosted by UpdateWindowPresenter, observing UpdateController phase:
/// checking, up to date, found with notes, downloading, extracting, ready, installing, or error.
struct UpdatePanel: View {
    @ObservedObject var controller: UpdateController
    @ObservedObject private var theme = ThemeManager.shared

    // Use the native Software Update title bar and traffic-light controls; the panel renders content only.
    // System-fixed title-bar height prevents jumps between states, unlike the old custom-header/fullSizeContentView approach.
    var body: some View {
        content
            .padding(.horizontal, 20).padding(.vertical, 18)
            .frame(width: 440, alignment: .leading)
            .background(Pal.solidBase)
            .preferredColorScheme(theme.isDark ? .dark : .light)
    }

    @ViewBuilder
    private var content: some View {
        switch controller.phase {
        case .idle:        EmptyView()
        case .checking:    checking
        case .upToDate:    upToDate
        case .found:       found
        case .downloading: progressBlock(title: String(localized: "Downloading update…"), label: controller.progressLabel, fraction: controller.progressFraction, cancellable: true)
        case .extracting:  progressBlock(title: String(localized: "Extracting update…"), label: "", fraction: controller.progressFraction, cancellable: false)
        case .readyToInstall: ready
        case .installing:  installing
        case .error(let msg): errorBlock(msg)
        }
    }

    // State-specific content.

    private var checking: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text("Checking for updates…").font(.system(size: 13)).foregroundStyle(Pal.text)
            Spacer()
            SecondaryButton(title: "Cancel", action: { controller.cancel() })
        }
    }

    private var upToDate: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(lucideSymbol: "checkmark.circle.fill")
                    .font(.system(size: 18)).foregroundStyle(Pal.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("You're up to date").font(.system(size: 14, weight: .semibold)).foregroundStyle(Pal.text)
                    Text("Current \(AppInfo.versionLine)").font(.system(size: 12)).foregroundStyle(Pal.subtext)
                }
            }
            HStack { Spacer(); PrimaryButton(title: "OK", action: { controller.acknowledge() }) }
        }
    }

    private var found: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("New Version Available").font(.system(size: 15, weight: .semibold)).foregroundStyle(Pal.text)
                    if let i = controller.info, i.isCritical {
                        Text("Important").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Pal.red, in: Capsule())
                    }
                }
                if let i = controller.info {
                    Text("ServerDock \(i.displayVersion)（build \(i.build)）"
                         + (i.dateString.map { " · \($0)" } ?? ""))
                        .font(.system(size: 12)).foregroundStyle(Pal.subtext)
                    Text("Current \(AppInfo.version) (build \(AppInfo.build)) → New \(i.displayVersion)")
                        .font(.system(size: 11)).foregroundStyle(Pal.overlay)
                }
            }
            releaseNotes
            HStack(spacing: 10) {
                Button(action: { controller.skip() }) {
                    Text("Skip This Version").font(.system(size: 12)).foregroundStyle(Pal.overlay)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointerCursor()
                Spacer()
                SecondaryButton(title: "Later", action: { controller.later() })
                PrimaryButton(title: "Update Now", action: { controller.install() })
            }
        }
    }

    @ViewBuilder
    private var releaseNotes: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What's New").font(.system(size: 11, weight: .medium)).foregroundStyle(Pal.subtext)
            Group {
                if let html = controller.releaseNotesHTML, !html.isEmpty {
                    ReleaseNotesWebView(html: html)
                } else {
                    Text("No release notes for this update.")
                        .font(.system(size: 12)).foregroundStyle(Pal.overlay)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
            }
            .frame(height: 200)
            .background(Pal.fill(0.04), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Pal.fill(0.07), lineWidth: 1))
        }
    }

    private func progressBlock(title: String, label: String, fraction: Double, cancellable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Pal.text)
            ProgressView(value: fraction).tint(Pal.mauve)
            HStack {
                Text(label).font(.system(size: 11)).foregroundStyle(Pal.subtext)
                Spacer()
                if cancellable { SecondaryButton(title: "Cancel", action: { controller.cancel() }) }
            }
        }
    }

    private var ready: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(lucideSymbol: "arrow.down.circle.fill")
                    .font(.system(size: 18)).foregroundStyle(Pal.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Update Ready").font(.system(size: 14, weight: .semibold)).foregroundStyle(Pal.text)
                    Text("ServerDock will restart to finish installing").font(.system(size: 12)).foregroundStyle(Pal.subtext)
                }
            }
            HStack(spacing: 10) {
                Spacer()
                SecondaryButton(title: "Later", action: { controller.later() })
                PrimaryButton(title: "Restart and Install Now", action: { controller.install() })
            }
        }
    }

    private var installing: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text("Installing — restarting shortly…").font(.system(size: 13)).foregroundStyle(Pal.text)
            Spacer()
        }
    }

    private func errorBlock(_ msg: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(lucideSymbol: "exclamationmark.triangle.fill")
                    .font(.system(size: 18)).foregroundStyle(Pal.red)
                Text("Update Failed").font(.system(size: 14, weight: .semibold)).foregroundStyle(Pal.text)
            }
            Text(msg).font(.system(size: 12)).foregroundStyle(Pal.subtext)
                .fixedSize(horizontal: false, vertical: true)
            HStack { Spacer(); PrimaryButton(title: "OK", action: { controller.acknowledge() }) }
        }
    }
}

// MARK: - Window host

/// Host updates in a separate window so they can appear while the app is hidden to the menu bar; hide native close/title elements,
/// and use a custom panel header/close button consistent with ConfirmDialog/AboutWindow.
@MainActor
final class UpdateWindowPresenter {
    static let shared = UpdateWindowPresenter()
    private var window: NSWindow?

    /// Show/refresh on every apply state change, adapting window height to content.
    func present() {
        let w = ensureWindow()
        if let host = w.contentView as? NSHostingView<UpdatePanel> {
            w.setContentSize(NSSize(width: 440, height: host.fittingSize.height))
        }
        if !w.isVisible { w.center() }
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func dismiss() {
        window?.orderOut(nil)
    }

    private func ensureWindow() -> NSWindow {
        if let w = window { return w }
        let host = NSHostingView(rootView: UpdatePanel(controller: .shared))
        // Use a native title bar with traffic lights and content beneath it, keeping header height stable while content height changes,
        // matching About and replacing the state-dependent old custom header plus fullSizeContentView.
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 200),
                         styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = String(localized: "Software Update")
        w.isReleasedWhenClosed = false
        w.backgroundColor = NSColor(Pal.solidBase)
        w.contentView = host
        w.setContentSize(NSSize(width: 440, height: host.fittingSize.height))
        // Red close/Command-W performs the old custom-close action: notify the controller to cancel checking and return idle.
        // orderOut/dismiss does not post this notification, so programmatic hiding does not accidentally trigger it.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated { UpdateController.shared.userClosedPanel() }
        }
        window = w
        return w
    }
}

import AppKit
import SwiftUI

/// About content shared by Settings and the standalone menu-opened window.
struct AboutContent: View {
    var showUpdateStatus: Bool = true   // Set false in the standalone About dialog to omit status text such as last-check time.
    @ObservedObject private var theme = ThemeManager.shared
    @State private var showPrivacy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 14) {
                Image("ServerDockBrandMark", bundle: .app)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 52, height: 52)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("ServerDock").font(.system(size: 18, weight: .semibold)).foregroundStyle(Pal.text)
                    Text(AppInfo.versionLine)
                        .font(.system(size: 12)).foregroundStyle(Pal.subtext)
                }
                Spacer()
                UpdateInlineControls(showStatus: showUpdateStatus)   // Automatic-update toggle and Check for Updates button at the header's right edge.
            }
            Divider().background(Pal.fill(0.06)).padding(.vertical, 6)
            linkLine("GitHub", "github.com/jh78bb/server-dock", url: "https://github.com/jh78bb/server-dock")
            infoLine(String(localized: "Terminal Engine"), value: "SwiftTerm 1.13")
            infoLine(String(localized: "Render"), value: "CoreText / AppKit")
            infoLine(String(localized: "Platform"), value: "macOS 14+")
            infoLine(String(localized: "Architecture"), value: "Apple Silicon")
            privacyLine
        }
        .padding(20)
        .background(Pal.fill(0.03), in: RoundedRectangle(cornerRadius: 10))
        .sheet(isPresented: $showPrivacy) { PrivacyPolicyView() }
    }

    private var privacyLine: some View {
        Button { showPrivacy = true } label: {
            HStack {
                Text(String(localized: "Privacy Policy")).font(.system(size: 12)).foregroundStyle(Pal.overlay)
                Spacer()
                Image(lucideSymbol: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Pal.subtext)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private func infoLine(_ label: String, value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 12)).foregroundStyle(Pal.overlay)
            Spacer()
            Text(value).font(.system(size: 12)).foregroundStyle(Pal.subtext)
        }
    }

    @ViewBuilder
    private func linkLine(_ label: String, _ text: String, url: String) -> some View {
        HStack {
            Text(label).font(.system(size: 12)).foregroundStyle(Pal.overlay)
            Spacer()
            if let u = URL(string: url) {
                Link(text, destination: u)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(hex: 0x89b4fa))
                    .pointerCursor()
            } else {
                Text(text).font(.system(size: 12)).foregroundStyle(Pal.subtext)
            }
        }
    }
}

/// Standalone About ServerDock window root.
struct AboutWindow: View {
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        AboutContent(showUpdateStatus: false)   // Omit last-check status text in the standalone dialog.
            .padding(24)
            .frame(width: 460)
            .background(Pal.solidBase)
            .preferredColorScheme(theme.isDark ? .dark : .light)
    }
}

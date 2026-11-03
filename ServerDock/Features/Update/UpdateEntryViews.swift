import SwiftUI

/// Shared About/settings inline update controls follow the distribution channel.
/// Developer ID uses Sparkle checks/preferences; MAS directs to the App Store.
struct UpdateInlineControls: View {
    var showStatus: Bool = true   // Status text such as last-check time; set false in the standalone About dialog for compactness.
    @ObservedObject private var u = UpdateController.shared
    @ObservedObject private var theme = ThemeManager.shared

    // Align beside ServerDock in the About header, without a separate Software Update subsection.
    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if u.supportsInApp {
                HStack(spacing: 6) {
                    Text("Automatically Check for Updates").font(.system(size: 11)).foregroundStyle(Pal.subtext)
                    ThemedToggle(isOn: $u.automaticChecks)
                        .scaleEffect(0.78).frame(width: 30, height: 17)
                }
            }
            HStack(spacing: 6) {
                if showStatus {
                    Text(statusText).font(.system(size: 10)).foregroundStyle(Pal.overlay).lineLimit(1)
                }
                trailingControl
            }
        }
    }

    @ViewBuilder
    private var trailingControl: some View {
        if u.supportsInApp {
            switch u.phase {
            case .checking, .downloading, .extracting, .installing:
                HStack(spacing: 5) {
                    ProgressView().controlSize(.small).scaleEffect(0.8)
                    miniButton(String(localized: "View")) { UpdateWindowPresenter.shared.present() }
                }
            case .found, .readyToInstall:
                miniButton(String(localized: "Check for Updates"), primary: true) { UpdateWindowPresenter.shared.present() }
            default:
                miniButton(String(localized: "Check for Updates")) { u.checkForUpdates(surfaceTransient: false) }
            }
        } else {
            miniButton(String(localized: "Check in the App Store")) { u.checkForUpdates() }
        }
    }

    /// Compact header action, smaller than standard Primary/SecondaryButton.
    private func miniButton(_ title: String, primary: Bool = false, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Text(title)
                .font(.system(size: 11, weight: primary ? .medium : .regular))
                .foregroundStyle(primary ? .white : Pal.subtext)
                .lineLimit(1).fixedSize()   // Keep button text on one line without wrapping and increasing height.
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(primary ? Pal.mauve : Pal.fill(0.08), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor()
    }

    private var statusText: String {
        if !u.supportsInApp { return String(localized: "Receive updates via the App Store") }
        switch u.phase {
        case .checking:      return String(localized: "Checking for updates…")
        case .found:         return String(localized: "New Version Available") + (u.info.map { " \($0.displayVersion)" } ?? "")
        case .downloading, .extracting: return String(localized: "Updating…")
        case .readyToInstall: return String(localized: "Update ready — restart to install")
        case .installing:    return String(localized: "Installing…")
        case .upToDate:      return String(localized: "You're up to date")
        case .error:         return String(localized: "Last check failed")
        case .idle:
            guard let d = u.lastCheckDate else { return String(localized: "Not checked yet") }
            if Date().timeIntervalSince(d) < 60 { return String(localized: "Last checked: just now") }   // Avoid rounding a future time into a misleading zero-seconds message.
            return String(localized: "Last checked:") + Self.relative.localizedString(for: d, relativeTo: Date())
        }
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        f.unitsStyle = .short
        return f
    }()
}

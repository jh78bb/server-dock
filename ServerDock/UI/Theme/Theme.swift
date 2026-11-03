import AppKit
import SwiftUI

enum AppearanceMode: String, CaseIterable {
    case system, dark, light

    /// Read legacy appearance values stored as Chinese rawValue strings for compatibility.
    init?(stored: String) {
        switch stored {
        case "\u{8ddf}\u{968f}\u{7cfb}\u{7edf}": self = .system
        case "\u{6df1}\u{8272}": self = .dark
        case "\u{6d45}\u{8272}": self = .light
        default: self.init(rawValue: stored)
        }
    }

    var label: String {
        switch self {
        case .system: return String(localized: "System")
        case .dark: return String(localized: "Dark")
        case .light: return String(localized: "Light")
        }
    }
}

struct ThemeColors {
    let crust: Color
    let mantle: Color
    let base: Color
    let surface0: Color
    let text: Color
    let textBright: Color
    let subtext: Color
    let overlay: Color
    let mauve: Color
    let green: Color
    let yellow: Color
    let red: Color

    // Terminal colors.
    let termBg: UInt32
    let termFg: UInt32
    let termCaret: UInt32
    let termSelection: UInt32

    // Workspace base hex value, used as an NSColor window background to prevent cold-start white flashes.
    let baseHex: UInt32
}

extension ThemeColors {
    // Neutral-gray dark theme with the sidebar slightly brighter than the editor.
    static let dark = ThemeColors(
        crust: Color(hex: 0x333333),    // Activity bar.
        mantle: Color(hex: 0x252526),   // Sidebar / tab bar.
        base: Color(hex: 0x1e1e1e),     // Workspace / editor.
        surface0: Color(hex: 0x37373d),
        text: Color(hex: 0xcccccc),
        textBright: Color(hex: 0xffffff),
        subtext: Color(hex: 0x9d9d9d),
        overlay: Color(hex: 0x7a7a7a),
        mauve: Color(hex: 0x569cd6),    // Blue accent.
        green: Color(hex: 0x4ec9b0),
        yellow: Color(hex: 0xd7ba7d),
        red: Color(hex: 0xf14c4c),
        termBg: 0x1e1e1e, termFg: 0xcccccc,
        termCaret: 0xaeafad, termSelection: 0x264f78,
        baseHex: 0x1e1e1e
    )

    // Light theme slightly below pure white to reduce glare while preserving base>mantle>crust>surface0 layering.
    static let light = ThemeColors(
        crust: Color(hex: 0xe6e8ed),    // Activity bar, the darkest layer.
        mantle: Color(hex: 0xedeef2),   // Sidebar / tab bar.
        base: Color(hex: 0xf5f6f9),     // Workspace / editor, no longer pure white.
        surface0: Color(hex: 0xdfe2e9),
        text: Color(hex: 0x2e3440),
        textBright: Color(hex: 0x1a1d24),
        subtext: Color(hex: 0x6b7280),
        overlay: Color(hex: 0x9aa0ac),
        mauve: Color(hex: 0x3b82f6),    // Fresh bright-blue accent.
        green: Color(hex: 0x10b981),
        yellow: Color(hex: 0xf59e0b),
        red: Color(hex: 0xef4444),
        termBg: 0xf5f6f9, termFg: 0x2e3440,   // Dim terminal/editor backgrounds together to remove pure-white glare.
        termCaret: 0x3b82f6, termSelection: 0xbfdbfe,
        baseHex: 0xf5f6f9
    )
}

final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()

    @Published var mode: AppearanceMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: "appearanceMode")
            update()
        }
    }

    @Published private(set) var colors: ThemeColors = .dark
    @Published private(set) var isDark: Bool = true

    /// Current-theme NSColor window background, applied before the first frame to prevent cold-start white flashes.
    var windowBackground: NSColor { NSColor(hex: colors.baseHex) }

    private var systemObserver: NSObjectProtocol?

    private init() {
        let saved = UserDefaults.standard.string(forKey: "appearanceMode") ?? ""
        self.mode = AppearanceMode(stored: saved) ?? .system
        update()

        systemObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in
            if self?.mode == .system { self?.update() }
        }
    }

    private func update() {
        switch mode {
        case .dark:
            isDark = true
            NSApp?.appearance = NSAppearance(named: .darkAqua)
        case .light:
            isDark = false
            NSApp?.appearance = NSAppearance(named: .aqua)
        case .system:
            // Clear forced appearance first; otherwise effectiveAppearance remains pinned to the previous override
            // and switching back to System reads the old value instead of global settings.
            NSApp?.appearance = nil
            isDark = Self.systemIsDark
        }
        // Synchronize AppKit appearance so default window/control colors are correct from the first frame, together with NSWindow.backgroundColor,
        // preventing cold-start white flashes and light title/menu mismatches under forced dark mode.
        colors = isDark ? .dark : .light
    }

    /// Read global system appearance independently of NSApp.appearance overrides.
    private static var systemIsDark: Bool {
        let style = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleInterfaceStyle"] as? String
        return style?.lowercased().contains("dark") ?? false
    }
}

/// Active server color supplies file/editor/toolbar/status workspace accents.
/// TabsModel updates accents on selection; nongrouped storage/local tabs use the default app accent.
final class HostTint {
    static let shared = HostTint()
    var lookup: ((String?) -> Color?)?
    private(set) var color: Color?
    func update(hostId: String?) { color = hostId.flatMap { lookup?($0) } }
}

// Compatibility layer: Pal reads the current theme.
enum Pal {
    private static var c: ThemeColors { ThemeManager.shared.colors }

    /// Workspace accent is active server color, falling back to mauve.
    static var tint: Color { HostTint.shared.color ?? c.mauve }

    // Window surface color, always opaque.
    static var crust: Color { c.crust }
    static var mantle: Color { c.mantle }
    static var base: Color { c.base }
    // Keep solid* aliases for existing call sites.
    static var solidCrust: Color { c.crust }
    static var solidMantle: Color { c.mantle }
    static var solidBase: Color { c.base }
    static var surface0: Color { c.surface0 }
    static var text: Color { c.text }
    static var textBright: Color { c.textBright }
    static var subtext: Color { c.subtext }
    static var overlay: Color { c.overlay }
    static var mauve: Color { c.mauve }
    static var green: Color { c.green }
    static var yellow: Color { c.yellow }
    static var red: Color { c.red }

    /// Adaptive overlay color: white in dark themes, black in light themes.
    /// Keep translucent hover/selection/card/border layers visible in both themes.
    static func fill(_ opacity: Double) -> Color {
        ThemeManager.shared.isDark
            ? Color.white.opacity(opacity)
            : Color.black.opacity(opacity * 1.4)
    }
}

/// Semantic latency tiers map round-trip milliseconds to shared colors/labels for host lists and overview.
enum LatencyLevel {
    case unknown   // Unprobed, failed, or timed out.
    case good      // Below 80ms: responsive interaction.
    case warning   // 80-499ms: usable with noticeable latency.
    case poor      // At least 500ms: significantly affects interaction.

    /// Classify one latency value; nil/negative means unprobed.
    init(ms: Int?) {
        guard let ms, ms >= 0 else { self = .unknown; return }
        switch ms {
        case ..<80:  self = .good
        case ..<500: self = .warning
        default:     self = .poor
        }
    }

    var color: Color {
        switch self {
        case .unknown: return Pal.overlay
        case .good:    return Pal.green
        case .warning: return Pal.yellow
        case .poor:    return Pal.red
        }
    }

    var title: String {
        switch self {
        case .unknown: return String(localized: "Not Probed")
        case .good:    return String(localized: "Smooth")
        case .warning: return String(localized: "High latency")
        case .poor:    return String(localized: "Very high latency")
        }
    }
}

extension View {
    /// Privacy mode uses Gaussian blur rather than replacement text for natural-looking redaction.
    /// Hide list/overview IPs and hostnames for screenshots/screen sharing.
    @ViewBuilder
    func privacyBlur(_ on: Bool, radius: CGFloat = 3.5) -> some View {
        if on { blur(radius: radius) } else { self }
    }

    /// Use a pointing-hand cursor on interactive buttons/rows; active=false, e.g. disabled controls, leaves the cursor unchanged.
    /// Follow SidebarDivider's reliable onContinuousHover set approach to override AppKit tracking areas
    /// resetting the cursor to an arrow during movement; onHover plus push/pop alone can reset or become unbalanced.
    @ViewBuilder
    func pointerCursor(_ active: Bool = true) -> some View {
        if active {
            onContinuousHover { phase in
                switch phase {
                case .active: NSCursor.pointingHand.set()
                case .ended:  NSCursor.arrow.set()
                }
            }
        } else {
            self
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255,
            opacity: 1
        )
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: 1
        )
    }
}

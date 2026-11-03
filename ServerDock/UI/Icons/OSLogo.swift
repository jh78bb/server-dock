import AppKit
import CoreText
import SwiftUI

/// Render distribution logos using bundled OFL-licensed Font Logos, registered for this process at runtime,
/// so users need no system font installation.
/// Use probed specs.os, e.g. Ubuntu 22.04.3 LTS; when absent/unrecognized,
/// [[HostLeadingIcon]] falls back to a latency-colored dot.
enum OSLogo {
    /// Register the bundled font and return its PostScript name for .custom; missing/failed registration returns nil and falls back to a dot.
    /// static let registers only once, prewarmed at [[ServerDockApp]] startup for first-frame availability.
    static let fontName: String? = {
        guard let url = Bundle.app.url(forResource: "font-logos", withExtension: "ttf"),
              let provider = CGDataProvider(url: url as CFURL),
              let cgFont = CGFont(provider) else { return nil }
        CTFontManagerRegisterGraphicsFont(cgFont, nil)   // .process scope makes the font visible only within this process.
        return (cgFont.postScriptName as String?) ?? "Font Logos"
    }()

    /// Map OS description to Font Logos glyph/brand color; return nil for unknown systems.
    /// Codepoint is U+F300 plus the font-logos offset; see its icons.tsv.
    static func info(for os: String) -> (glyph: String, color: Color)? {
        let s = os.lowercased()
        if s.contains("ubuntu")   { return ("\u{F31B}", Color(hex: 0xE95420)) }
        if s.contains("debian")   { return ("\u{F306}", Color(hex: 0xA80030)) }
        if s.contains("centos")   { return ("\u{F304}", Color(hex: 0x9CCD2A)) }
        if s.contains("fedora")   { return ("\u{F30A}", Color(hex: 0x3C6EB4)) }
        if s.contains("rocky")    { return ("\u{F32B}", Color(hex: 0x10B981)) }
        if s.contains("alma")     { return ("\u{F31D}", Color(hex: 0x0D7DBC)) }
        if s.contains("red hat") || s.contains("redhat") || s.contains("rhel") {
            return ("\u{F316}", Color(hex: 0xEE0000))
        }
        if s.contains("kali")     { return ("\u{F327}", Color(hex: 0x367BF0)) }
        if s.contains("manjaro")  { return ("\u{F312}", Color(hex: 0x35BF5C)) }
        if s.contains("arch")     { return ("\u{F303}", Color(hex: 0x1793D1)) }
        if s.contains("alpine")   { return ("\u{F300}", Color(hex: 0x0D597F)) }
        if s.contains("suse") || s.contains("sles") { return ("\u{F314}", Color(hex: 0x30BA78)) }
        if s.contains("mint")     { return ("\u{F30E}", Color(hex: 0x87CF3E)) }
        if s.contains("gentoo")   { return ("\u{F30D}", Color(hex: 0x54487A)) }
        if s.contains("nixos")    { return ("\u{F313}", Color(hex: 0x5277C3)) }
        if s.contains("void")     { return ("\u{F32E}", Color(hex: 0x478061)) }
        if s.contains("raspbian") || s.contains("raspberry") { return ("\u{F315}", Color(hex: 0xC51A4A)) }
        if s.contains("darwin") || s.contains("macos") || s.contains("mac os") {
            return ("\u{F302}", Color(hex: 0xA2AAAD))   // Apple
        }
        // Known Linux with an unknown distribution uses generic Tux (F31A).
        // Windows is absent from the open-source logo font for trademark reasons; RDP/Windows hosts fall back to a dot.
        if s.contains("linux") || s.contains("gnu") { return ("\u{F31A}", Color(hex: 0x9CA3AF)) }
        return nil
    }
}

/// Host-row leading icon: solid rounded OS-brand tile with white logo, or plain fallback for Windows/unknown systems,
/// plus a bottom-right latency dot. Fixed 28pt width keeps host names aligned.
struct HostLeadingIcon: View {
    let host: Host
    @ObservedObject private var theme = ThemeManager.shared

    private static let side: CGFloat = 28
    private static let radius: CGFloat = 7

    var body: some View {
        // SSH uses probed specs.os, falling back to stored os; treat RDP as Windows.
        let osStr = host.rdp?.protocolType == .rdp ? "windows" : (host.specs?.os ?? host.os)
        let dotColor = LatencyLevel(ms: host.latencyMs).color   // Latency colors: fast green, slower yellow/red, unprobed/unreachable gray.
        ZStack(alignment: .bottomTrailing) {
            iconTile(osStr)
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
                .overlay(Circle().stroke(Pal.mantle, lineWidth: 2))   // A sidebar-colored border separates the status dot from the solid tile.
                .offset(x: 1, y: 1)
        }
        .frame(width: Self.side, height: Self.side)
    }

    @ViewBuilder
    private func iconTile(_ osStr: String) -> some View {
        if let name = OSLogo.fontName, let logo = OSLogo.info(for: osStr) {
            RoundedRectangle(cornerRadius: Self.radius)
                .fill(logo.color)
                .overlay(Text(logo.glyph).font(.custom(name, size: 16)).foregroundStyle(.white))
                .frame(width: Self.side, height: Self.side)
        } else {
            // No logo for Windows/RDP/unknown OS: use a solid tile with a fallback symbol for consistency.
            let bg: Color = host.rdp?.protocolType == .rdp ? Color(hex: 0x0078D4) : Pal.fill(0.14)
            let fg: Color = host.isRDP ? .white : Pal.subtext
            RoundedRectangle(cornerRadius: Self.radius)
                .fill(bg)
                .overlay(Image(lucideSymbol: host.isRDP ? "display" : "server.rack")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(fg))
                .frame(width: Self.side, height: Self.side)
        }
    }
}

import AppKit
import CoreText
import SwiftUI

/// Detect Nerd Fonts for programming-language brand glyphs such as Devicon.
/// Prefer Nerd Font language logos, which Lucide does not supply; fall back to Lucide when the font is unavailable.
///
/// First register a bundled Resources font, then try an available system-installed Nerd Font.
/// Tint monochrome glyphs using FileIcon brand colors.
enum NerdFont {
    // Common Nerd Font names with matching Devicon codepoints; prefer the minimal Symbols variants.
    private static let candidates = [
        "Symbols Nerd Font Mono", "Symbols Nerd Font",
        "JetBrainsMono Nerd Font", "JetBrainsMonoNL Nerd Font",
        "FiraCode Nerd Font", "MesloLGM Nerd Font", "MesloLGS Nerd Font",
        "Hack Nerd Font", "CaskaydiaCove Nerd Font", "SauceCodePro Nerd Font",
        "Iosevka Nerd Font", "UbuntuMono Nerd Font",
    ]

    private static var didSetup = false
    private static var resolvedName: String?

    /// Available Nerd Font name, initialized lazily; nil means no bundled/installed font and selects the Lucide fallback.
    static var name: String? {
        if !didSetup { setup() }
        return resolvedName
    }
    static var isAvailable: Bool { name != nil }

    /// Resolve once, first registering bundled Resources fonts as OSLogo does, without requiring installation.
    /// Otherwise find an installed Nerd Font. Trigger lazily on the main thread when the first icon renders.
    static func setup() {
        didSetup = true
        if let bundled = registerBundledNerdFont() { resolvedName = bundled; return }

        // Enumerate fonts whose names contain Nerd Font rather than relying only on fixed candidates,
        // covering JetBrainsMono, FiraCode, Symbols, and other installed variants.
        let mgr = NSFontManager.shared
        if let fam = mgr.availableFontFamilies.first(where: {
            $0.range(of: "Nerd Font", options: .caseInsensitive) != nil
        }), NSFont(name: fam, size: 12) != nil {
            resolvedName = fam; return
        }
        if let ps = mgr.availableFonts.first(where: {
            $0.range(of: "NerdFont", options: .caseInsensitive) != nil
            || $0.range(of: "Nerd Font", options: .caseInsensitive) != nil
        }) {
            resolvedName = ps; return
        }
        // Fallback to fixed names if enumeration misses a font.
        resolvedName = candidates.first { NSFont(name: $0, size: 12) != nil }
    }

    // Cache fitted sizes per glyph because Nerd Font designs occupy different proportions of their em boxes.
    private static var fitCache: [String: CGFloat] = [:]

    /// Return a cached, bounded font size making the glyph's longest visual bounding-box edge approximately `box` points.
    static func fittedSize(glyph: String, box: CGFloat) -> CGFloat {
        guard let fontName = name, let scalar = glyph.unicodeScalars.first else { return box }
        let key = "\(scalar.value)@\(Int(box * 10))"
        if let c = fitCache[key] { return c }

        let probe: CGFloat = 100
        guard let font = NSFont(name: fontName, size: probe) else { fitCache[key] = box; return box }
        var chars = Array(String(scalar).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: chars.count)
        guard CTFontGetGlyphsForCharacters(font, &chars, &glyphs, chars.count),
              let g = glyphs.first, g != 0 else { fitCache[key] = box; return box }
        var gid = g
        let rect = CTFontGetBoundingRectsForGlyphs(font, .horizontal, &gid, nil, 1)
        let dim = max(rect.width, rect.height)
        // Fit the longest edge to box, clamping to 0.75-1.9 times box so outliers do not become too large/small.
        let fitted = dim > 0 ? min(max(box * probe / dim, box * 0.75), box * 1.9) : box
        fitCache[key] = fitted
        return fitted
    }

    /// Register Resources fonts with nerd in the filename and return the PostScript name for .custom, or nil.
    private static func registerBundledNerdFont() -> String? {
        for ext in ["ttf", "otf"] {
            let urls = Bundle.app.urls(forResourcesWithExtension: ext, subdirectory: nil) ?? []
            for u in urls where u.lastPathComponent.lowercased().contains("nerd") {
                guard let provider = CGDataProvider(url: u as CFURL), let cg = CGFont(provider) else { continue }
                CTFontManagerRegisterGraphicsFont(cg, nil)
                if let ps = cg.postScriptName as String? { return ps }
            }
        }
        return nil
    }
}

/// Shared file-type icon: use available Nerd Font language glyphs, otherwise Lucide.
/// Use FileIcon colors consistently across the sidebar tree, file browser, and editor breadcrumbs/header.
struct FileTypeIcon: View {
    let file: RemoteFile
    var size: CGFloat = 13

    var body: some View {
        let ic = FileIcon.info(for: file)
        if file.kind == .file, let fontName = NerdFont.name, let glyph = FileIcon.nerdGlyph(for: file.name) {
            // Use a box slightly larger than the point size, fitting each glyph for a consistent centered visual size.
            let box = size * 1.08
            Text(glyph)
                .font(.custom(fontName, size: NerdFont.fittedSize(glyph: glyph, box: box)))
                .foregroundStyle(ic.color)
                .frame(width: box, height: box)
        } else {
            Image(lucideSymbol: ic.symbol)
                .font(.system(size: size))
                .foregroundStyle(ic.color)
        }
    }
}

// Render DMG backgrounds at 1x/2x offscreen through CoreGraphics/CoreText without a display.
// Keep transparency and draw only logo/arrow/instructions over Finder's light background.
// Reuse rounded >_ outlines with blue underscore.
// Match create-dmg's 660x400 window including title bar; background covers
// 660x368 content, roughly minus the title bar, so bottom instructions remain visible.
// App/Applications centers are (170,198)/(490,198), size 128; image row y=368-198=170.
// Usage: swift make-dmg-background.swift <output-directory> creates background.png/background@2x.png.
import Foundation
import AppKit
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

/// Resolve SF Pro Rounded through NSFont's .rounded design instead of unstable PostScript names.
/// NSFont/CTFont are toll-free bridged for CoreText use.
func roundedFont(_ size: CGFloat, _ weight: NSFont.Weight) -> CTFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    if let d = base.fontDescriptor.withDesign(.rounded) { return NSFont(descriptor: d, size: size) ?? base }
    return base
}

let W: CGFloat = 660, H: CGFloat = 368
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

func c(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(r)/255, green: CGFloat(g)/255, blue: CGFloat(b)/255, alpha: a)
}
// Light-window palette: dark text and brand-blue logo underscore.
let ink = c(60, 63, 76)          // Wordmark / instructions.
let blue = c(51, 133, 255)       // Underscore and arrowhead, using brand blue.
let gray = c(140, 143, 160)      // Subtitle / arrow shaft.
let subtle = c(120, 124, 143)

func attr(_ s: String, _ font: CTFont, _ color: CGColor) -> NSAttributedString {
    NSAttributedString(string: s, attributes: [
        kCTFontAttributeName as NSAttributedString.Key: font,
        kCTForegroundColorAttributeName as NSAttributedString.Key: color,
    ])
}
func measure(_ line: CTLine) -> CGFloat {
    var a: CGFloat = 0, d: CGFloat = 0, l: CGFloat = 0
    return CGFloat(CTLineGetTypographicBounds(line, &a, &d, &l))
}
func drawCentered(_ s: NSAttributedString, centerX: CGFloat, baselineY: CGFloat, in ctx: CGContext) {
    let line = CTLineCreateWithAttributedString(s as CFAttributedString)
    ctx.textPosition = CGPoint(x: centerX - measure(line)/2, y: baselineY)
    CTLineDraw(line, ctx)
}

// Menu-bar >_ logo path: 18-unit bottom-left-origin design, y=4.4 baseline, scaled by s at origin ox/by.
func drawPrompt(ox: CGFloat, baselineY: CGFloat, s: CGFloat, in ctx: CGContext) {
    func P(_ dx: CGFloat, _ dy: CGFloat) -> CGPoint { CGPoint(x: ox + dx*s, y: baselineY + (dy-4.4)*s) }
    ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.setStrokeColor(ink); ctx.setLineWidth(2.3*s)              // chevron ">"
    ctx.beginPath(); ctx.move(to: P(4.3,13.6)); ctx.addLine(to: P(9.4,9)); ctx.addLine(to: P(4.3,4.4)); ctx.strokePath()
    ctx.setStrokeColor(blue); ctx.setLineWidth(2.3*s)            // Underscore "_".
    ctx.beginPath(); ctx.move(to: P(12.3,4.4)); ctx.addLine(to: P(16.0,4.4)); ctx.strokePath()
}
let promptGlyphWidth: CGFloat = (16.0 - 4.3)  // Width in design units.

func render(scale: CGFloat) -> CGImage? {
    let pw = Int(W*scale), ph = Int(H*scale)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8,
                              bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.scaleBy(x: scale, y: scale)
    // Do not paint the background; context starts transparent.

    // Center rounded >_ logo and rounded ServerDock wordmark.
    let s: CGFloat = 3.2
    let gW = promptGlyphWidth * s
    let gap: CGFloat = 16
    let serverdockFont = roundedFont(40, .semibold)
    let serverdockLine = CTLineCreateWithAttributedString(attr("ServerDock", serverdockFont, ink) as CFAttributedString)
    let tW = measure(serverdockLine)
    let total = gW + gap + tW
    let startX = (W - total) / 2
    let baseY: CGFloat = H - 60
    drawPrompt(ox: startX - 4.3*s, baselineY: baseY, s: s, in: ctx)
    ctx.textPosition = CGPoint(x: startX + gW + gap, y: baseY)
    CTLineDraw(serverdockLine, ctx)

    // Subtitle.
    let subFont = CTFontCreateWithName("PingFangSC-Regular" as CFString, 14, nil)
    drawCentered(attr("Remote Server Workspace", subFont, subtle), centerX: W/2, baselineY: H-88, in: ctx)

    // Drag arrow between icons, centered at image y=H-198=170.
    let ay: CGFloat = 170, ax0: CGFloat = 268, ax1: CGFloat = 392
    ctx.setStrokeColor(gray); ctx.setLineWidth(3); ctx.setLineCap(.round)
    ctx.beginPath(); ctx.move(to: CGPoint(x: ax0, y: ay)); ctx.addLine(to: CGPoint(x: ax1, y: ay)); ctx.strokePath()
    ctx.setFillColor(blue)
    ctx.beginPath(); ctx.move(to: CGPoint(x: ax1+12, y: ay))
    ctx.addLine(to: CGPoint(x: ax1-6, y: ay+8)); ctx.addLine(to: CGPoint(x: ax1-6, y: ay-8))
    ctx.closePath(); ctx.fillPath()

    // Bottom instructions.
    let hintFont = CTFontCreateWithName("PingFangSC-Medium" as CFString, 15, nil)
    drawCentered(attr("Drag ServerDock to Applications to install", hintFont, ink), centerX: W/2, baselineY: 40, in: ctx)

    return ctx.makeImage()
}

func write(_ img: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
    print("✓ \(path)")
}

if let a = render(scale: 1) { write(a, to: "\(outDir)/background.png") }
if let b = render(scale: 2) { write(b, to: "\(outDir)/background@2x.png") }

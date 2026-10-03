// Renders the DMG window background (640×400 pt) at 1x and 2x:
//   swift scripts/dmg/make-background.swift scripts/dmg
// then: tiffutil -cathidpicheck background.png background@2x.png -out background.tiff
import AppKit
import CoreText

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
for font in ["Inter.ttf", "JetBrainsMono.ttf"] {
    CTFontManagerRegisterFontsForURL(root.appendingPathComponent("Orbit/Resources/Fonts/\(font)") as CFURL, .process, nil)
}

let W: CGFloat = 640, H: CGFloat = 400
let appCenter = CGPoint(x: 170, y: 180), appsCenter = CGPoint(x: 470, y: 180)   // keep in sync with settings.py

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
let accent = color(0xC8F169)

func render(scale: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H) // 144 dpi for the 2x variant
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext
    // Top-left origin, like the Finder coordinates in settings.py.
    cg.translateBy(x: 0, y: H)
    cg.scaleBy(x: 1, y: -1)

    // Background: Orbit's lime, light at the top and full accent at the bottom. Finder draws icon
    // labels in dark text and that cannot be changed, so the image has to stay light.
    let bg = NSGradient(starting: color(0xC8F169), ending: color(0xEAF9C4))!
    bg.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: 90)
    let glow = NSGradient(colors: [NSColor.white.withAlphaComponent(0.45), NSColor.white.withAlphaComponent(0)])!
    glow.draw(fromCenter: NSPoint(x: W / 2, y: 150), radius: 0, toCenter: NSPoint(x: W / 2, y: 150), radius: 300, options: [])

    // Orbits: soft white rings around the middle, with a small dark moon on one of them.
    let center = CGPoint(x: W / 2, y: 180)
    for (r, a) in [(110.0, 0.55), (190.0, 0.42), (280.0, 0.3)] as [(CGFloat, CGFloat)] {
        cg.setStrokeColor(NSColor.white.withAlphaComponent(a).cgColor)
        cg.setLineWidth(1.5)
        cg.strokeEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
    }
    let moonAngle: CGFloat = -.pi / 3.2
    let moon = CGPoint(x: center.x + 190 * cos(moonAngle), y: center.y + 190 * sin(moonAngle))
    cg.setFillColor(color(0x15171A).cgColor)
    cg.fillEllipse(in: CGRect(x: moon.x - 5, y: moon.y - 5, width: 10, height: 10))

    // Arrow: a gentle arc from the app to the Applications folder.
    let start = CGPoint(x: appCenter.x + 88, y: appCenter.y - 6)
    let end = CGPoint(x: appsCenter.x - 92, y: appsCenter.y - 6)
    let control = CGPoint(x: W / 2, y: appCenter.y - 74)
    let arc = CGMutablePath()
    arc.move(to: start)
    arc.addQuadCurve(to: end, control: control)
    // White arrow with a soft shadow, like the classic drag-to-install windows.
    cg.setShadow(offset: CGSize(width: 0, height: 2), blur: 6, color: color(0x15171A, 0.18).cgColor)
    cg.setStrokeColor(NSColor.white.cgColor)
    cg.setLineWidth(9)
    cg.setLineCap(.round)
    cg.addPath(arc)
    cg.strokePath()
    // Arrow head along the curve's end tangent.
    let angle = atan2(end.y - control.y, end.x - control.x)
    let head: CGFloat = 24
    let left = CGPoint(x: end.x - head * cos(angle - .pi / 6), y: end.y - head * sin(angle - .pi / 6))
    let right = CGPoint(x: end.x - head * cos(angle + .pi / 6), y: end.y - head * sin(angle + .pi / 6))
    cg.setLineJoin(.round)
    cg.move(to: left); cg.addLine(to: end); cg.addLine(to: right)
    cg.strokePath()
    cg.setShadow(offset: .zero, blur: 0, color: nil)

    // Captions (drawn upright: AppKit text in a flipped context).
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
    func text(_ s: String, font: NSFont, color: NSColor, y: CGFloat, tracking: CGFloat = 0) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .kern: tracking]
        let str = NSAttributedString(string: s, attributes: attrs)
        let size = str.size()
        str.draw(at: NSPoint(x: (W - size.width) / 2, y: y))
    }
    // Inter ships as a variable font: ask for the weight through the descriptor.
    let interDescriptor = NSFontDescriptor(name: "Inter", size: 15)
        .addingAttributes([.traits: [NSFontDescriptor.TraitKey.weight: NSFont.Weight.semibold]])
    let inter = NSFont(descriptor: interDescriptor, size: 15) ?? .boldSystemFont(ofSize: 15)
    let mono = NSFont(name: "JetBrains Mono", size: 11.5) ?? .monospacedSystemFont(ofSize: 11.5, weight: .regular)
    text("Перетащите Orbit в «Программы»", font: inter, color: color(0x15171A), y: 318)
    text("— от вайбкодера к вайбкодерам —", font: mono, color: color(0x15171A, 0.55), y: 346)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for (scale, name) in [(1.0, "background.png"), (2.0, "background@2x.png")] as [(CGFloat, String)] {
    let data = render(scale: scale).representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: out).appendingPathComponent(name))
}
print("rendered \(out)/background.png and background@2x.png")

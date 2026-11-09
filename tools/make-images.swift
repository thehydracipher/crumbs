// Makes the website/README images: a framed screenshot and a social preview card.
// Usage: swift tools/make-images.swift <window-screenshot.png> <cropX> <cropY> <cropW> <cropH>
import AppKit
import CoreGraphics

let args = CommandLine.arguments
let shot = NSImage(contentsOfFile: args[1])!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
let crop = shot.cropping(to: CGRect(x: Int(args[2])!, y: Int(args[3])!, width: Int(args[4])!, height: Int(args[5])!))!
let icon = NSImage(contentsOfFile: "Icon/icon-1024.png")!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
let cs = CGColorSpace(name: CGColorSpace.displayP3)!
func rgb(_ h: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [CGFloat((h >> 16) & 255) / 255, CGFloat((h >> 8) & 255) / 255, CGFloat(h & 255) / 255, a])!
}
func canvas(_ w: Int, _ h: Int) -> CGContext {
    let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let g = CGGradient(colorsSpace: cs, colors: [rgb(0x4338CA), rgb(0x6D28D9), rgb(0x0891B2)] as CFArray, locations: [0, 0.5, 1])!
    c.drawLinearGradient(g, start: CGPoint(x: 0, y: CGFloat(h)), end: CGPoint(x: CGFloat(w), y: 0), options: [])
    let glow = CGGradient(colorsSpace: cs, colors: [rgb(0xFFFFFF, 0.18), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    c.drawRadialGradient(glow, startCenter: CGPoint(x: CGFloat(w) * 0.8, y: CGFloat(h) * 0.85), startRadius: 0,
                         endCenter: CGPoint(x: CGFloat(w) * 0.8, y: CGFloat(h) * 0.85), endRadius: CGFloat(w) * 0.6, options: [])
    return c
}
func save(_ c: CGContext, _ path: String) {
    try! NSBitmapImageRep(cgImage: c.makeImage()!).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    print("wrote", path)
}
func rounded(_ c: CGContext, _ img: CGImage, _ r: CGRect, radius: CGFloat) {
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -24), blur: 60, color: rgb(0x000000, 0.45))
    c.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)); c.setFillColor(rgb(0xFFFFFF)); c.fillPath()
    c.restoreGState()
    c.saveGState(); c.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)); c.clip()
    c.draw(img, in: r); c.restoreGState()
}
func text(_ c: CGContext, _ s: String, _ size: CGFloat, _ weight: NSFont.Weight, _ at: CGPoint, alpha: CGFloat = 1) {
    let ns = NSGraphicsContext(cgContext: c, flipped: false)
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ns
    NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                               .foregroundColor: NSColor.white.withAlphaComponent(alpha)]).draw(at: at)
    NSGraphicsContext.restoreGraphicsState()
}

// 1. Hero: screenshot on the brand background
let W = 1600, H = 1160
let hero = canvas(W, H)
let sw = CGFloat(crop.width) * 1.0, sh = CGFloat(crop.height) * 1.0
let scale = min(1360 / sw, 980 / sh)
let r = CGRect(x: (CGFloat(W) - sw * scale) / 2, y: (CGFloat(H) - sh * scale) / 2, width: sw * scale, height: sh * scale)
rounded(hero, crop, r, radius: 28)
save(hero, args.count > 6 ? args[6] : "docs/images/screenshot.png")
if args.count > 6 { exit(0) }      // only the screenshot was asked for

// 2. Social preview card (1280x640): icon, name, tagline
let card = canvas(1280, 640)
card.draw(icon, in: CGRect(x: 70, y: 150, width: 340, height: 340))
text(card, "Crumbs", 104, .bold, CGPoint(x: 450, y: 350))
text(card, "Uninstall Mac apps. Completely.", 46, .semibold, CGPoint(x: 456, y: 278), alpha: 0.95)
text(card, "Free  ·  Open source  ·  Safe  ·  Undo anytime", 32, .regular, CGPoint(x: 458, y: 214), alpha: 0.8)
save(card, "docs/images/social-preview.png")

// 3. Small icon for the website
let ic = CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ic.interpolationQuality = .high; ic.draw(icon, in: CGRect(x: 0, y: 0, width: 256, height: 256))
save(ic, "docs/images/icon-256.png")

// Draws the Crumbs app icon: an app tile breaking into pieces that drift away.
// Run:  swift Icon/render-icon.swift out.png   (makes a 1024x1024 PNG)
// Part of Crumbs. MIT License.

import AppKit
import CoreGraphics

let S: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

let cs = CGColorSpace(name: CGColorSpace.displayP3)!
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// Use top-left origin so the maths reads naturally.
ctx.translateBy(x: 0, y: S); ctx.scaleBy(x: 1, y: -1)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [CGFloat((hex >> 16) & 255) / 255, CGFloat((hex >> 8) & 255) / 255,
                                          CGFloat(hex & 255) / 255, a])!
}

// ---- Background: macOS icon shape (824pt on a 1024 canvas, continuous corners) ----
let bg = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: bg, xRadius: 186, yRadius: 186)
func cgPath(_ p: NSBezierPath) -> CGPath { p.cgPath }

ctx.saveGState()
// soft drop shadow under the whole icon
ctx.setShadow(offset: CGSize(width: 0, height: 14), blur: 28, color: rgb(0x000000, 0.35))
ctx.addPath(cgPath(shape)); ctx.setFillColor(rgb(0x312E81)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(cgPath(shape)); ctx.clip()
let bgGrad = CGGradient(colorsSpace: cs, colors: [rgb(0x4338CA), rgb(0x6D28D9), rgb(0x0891B2)] as CFArray,
                        locations: [0, 0.48, 1])!
ctx.drawLinearGradient(bgGrad, start: CGPoint(x: 160, y: 100), end: CGPoint(x: 880, y: 924), options: [])
// glow in the top-right where the pieces fly to
let glow = CGGradient(colorsSpace: cs, colors: [rgb(0x67E8F9, 0.55), rgb(0x67E8F9, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 760, y: 250), startRadius: 0,
                       endCenter: CGPoint(x: 760, y: 250), endRadius: 420, options: [])
// subtle top sheen
let sheen = CGGradient(colorsSpace: cs, colors: [rgb(0xFFFFFF, 0.18), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 470), options: [])
ctx.restoreGState()

// Everything below stays inside the icon shape.
ctx.saveGState()
ctx.addPath(cgPath(shape)); ctx.clip()

// ---- The app tile, made of an 8x8 grid of cells ----
let n = 8
let tile = CGRect(x: 236, y: 330, width: 424, height: 424)
let cell = tile.width / CGFloat(n)
let tilt: CGFloat = -0.10   // radians, a slight lean

// Repeatable "random" jitter so the icon is the same every time.
var seed: UInt64 = 42
func rnd() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(seed >> 33) / CGFloat(1 << 31) }

struct Piece { var rect: CGRect; var t: CGFloat; var angle: CGFloat }
var solid: [CGRect] = []
var pieces: [Piece] = []
for row in 0..<n {
    for col in 0..<n {
        let r = CGRect(x: tile.minX + CGFloat(col) * cell, y: tile.minY + CGFloat(row) * cell, width: cell, height: cell)
        let k = CGFloat(col + (n - 1 - row))          // 0 at bottom-left, 14 at top-right
        let threshold: CGFloat = 8.5 + (rnd() - 0.5) * 1.6
        if k < threshold { solid.append(r); continue }
        let t = min(1, (k - threshold + 0.6) / 6)     // 0..1, further = more broken
        pieces.append(Piece(rect: r, t: t, angle: (rnd() - 0.5) * 0.9 * t))
    }
}

let tileCenter = CGPoint(x: tile.midX, y: tile.midY)
func withTilt(_ body: () -> Void) {
    ctx.saveGState()
    ctx.translateBy(x: tileCenter.x, y: tileCenter.y); ctx.rotate(by: tilt); ctx.translateBy(x: -tileCenter.x, y: -tileCenter.y)
    body()
    ctx.restoreGState()
}

let white = CGGradient(colorsSpace: cs, colors: [rgb(0xFFFFFF), rgb(0xE0E7FF)] as CFArray, locations: [0, 1])!

// Solid part of the tile (rounded outer corners, shadow underneath)
withTilt {
    let outline = CGPath(roundedRect: tile, cornerWidth: 96, cornerHeight: 96, transform: nil)
    let solidPath = CGMutablePath()
    for r in solid { solidPath.addRect(r.insetBy(dx: -0.6, dy: -0.6)) }

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 22), blur: 40, color: rgb(0x1E1B4B, 0.55))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.addPath(outline); ctx.clip()
    ctx.addPath(solidPath); ctx.clip()
    ctx.drawLinearGradient(white, start: CGPoint(x: tile.minX, y: tile.minY), end: CGPoint(x: tile.maxX, y: tile.maxY), options: [])
    ctx.endTransparencyLayer()
    ctx.restoreGState()
}

// Broken pieces drifting up and to the right, getting smaller and fainter
withTilt {
    for p in pieces.sorted(by: { $0.t < $1.t }) {
        let push = p.t * p.t * 300 + p.t * 40
        let dx = push * 0.95 + (rnd() - 0.5) * 30 * p.t
        let dy = -push * 0.80 + (rnd() - 0.5) * 30 * p.t
        let scale = 1 - 0.55 * p.t
        let size = cell * scale * 0.86
        let c = CGPoint(x: p.rect.midX + dx, y: p.rect.midY + dy)
        let r = CGRect(x: c.x - size / 2, y: c.y - size / 2, width: size, height: size)

        ctx.saveGState()
        ctx.translateBy(x: c.x, y: c.y); ctx.rotate(by: p.angle); ctx.translateBy(x: -c.x, y: -c.y)
        ctx.setShadow(offset: CGSize(width: 0, height: 6), blur: 12, color: rgb(0x1E1B4B, 0.35 * (1 - p.t)))
        ctx.setAlpha(1 - 0.55 * p.t)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: size * 0.22, cornerHeight: size * 0.22, transform: nil))
        ctx.setFillColor(p.t > 0.55 ? rgb(0xA5F3FC) : rgb(0xF1F5FF))
        ctx.fillPath()
        ctx.restoreGState()
    }
}

// ---- A small sparkle ----
func sparkle(_ c: CGPoint, _ r: CGFloat, _ color: CGColor) {
    let p = CGMutablePath()
    let k: CGFloat = 0.18
    p.move(to: CGPoint(x: c.x, y: c.y - r))
    p.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: CGPoint(x: c.x + r * k, y: c.y - r * k))
    p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: CGPoint(x: c.x + r * k, y: c.y + r * k))
    p.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: CGPoint(x: c.x - r * k, y: c.y + r * k))
    p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: CGPoint(x: c.x - r * k, y: c.y - r * k))
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 24, color: rgb(0xFFFFFF, 0.8))
    ctx.addPath(p); ctx.setFillColor(color); ctx.fillPath()
    ctx.restoreGState()
}
sparkle(CGPoint(x: 790, y: 205), 46, rgb(0xFFFFFF))
sparkle(CGPoint(x: 845, y: 330), 20, rgb(0xCFFAFE, 0.9))

ctx.restoreGState()

// ---- Save ----
let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")

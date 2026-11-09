// Draws the Headroom app icon and writes Resources/AppIcon.icns.
//
//   swift tools/make-icon.swift            (from the repo root)
//
// The picture: a tank that is part full, with clear space and an upward
// chevron above the fill line. That space is the headroom, for RAM and for quota.
// Drawn in code so it stays editable and needs no design tool.

import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("Resources/AppIcon.iconset")
let icns = root.appendingPathComponent("Resources/AppIcon.icns")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

func draw(_ ctx: CGContext, size: CGFloat) {
    let k = size / 1024
    ctx.scaleBy(x: k, y: k)

    // Body: the macOS icon grid (824 pt plate on a 1024 canvas) with a soft shadow.
    let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
    let platePath = CGPath(roundedRect: plate, cornerWidth: 186, cornerHeight: 186, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.32))
    ctx.addPath(platePath); ctx.setFillColor(rgb(0x1B4FD1)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(platePath); ctx.clip()
    let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                        colors: [rgb(0x5AA2FF), rgb(0x2563EB), rgb(0x1736A8)] as CFArray,
                        locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 300, y: 924), end: CGPoint(x: 724, y: 100),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    // A faint sheen across the top third.
    let sheen = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [rgb(0xFFFFFF, 0.18), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 600), options: [])
    ctx.restoreGState()

    // The tank.
    let stroke: CGFloat = 36
    let tank = CGRect(x: 512 - 215, y: 232, width: 430, height: 560)
    let tankPath = CGPath(roundedRect: tank, cornerWidth: 84, cornerHeight: 84, transform: nil)

    // Fill: bottom 46% of the inside, white, with a gentle top-to-bottom tint.
    let inner = tank.insetBy(dx: stroke / 2 + 22, dy: stroke / 2 + 22)
    let innerPath = CGPath(roundedRect: inner, cornerWidth: 52, cornerHeight: 52, transform: nil)
    let level = inner.minY + inner.height * 0.46
    ctx.saveGState()
    ctx.addPath(innerPath); ctx.clip()
    ctx.clip(to: CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: level - inner.minY))
    let fill = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [rgb(0xFFFFFF, 0.98), rgb(0xD6E6FF, 0.95)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(fill, start: CGPoint(x: 512, y: level), end: CGPoint(x: 512, y: inner.minY), options: [])
    ctx.restoreGState()

    ctx.addPath(tankPath)
    ctx.setStrokeColor(rgb(0xFFFFFF))
    ctx.setLineWidth(stroke)
    ctx.strokePath()

    // The headroom: an upward chevron in the clear space.
    let mid = (level + inner.maxY) / 2 + 6
    ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.setLineWidth(34)
    ctx.move(to: CGPoint(x: 512 - 78, y: mid - 38))
    ctx.addLine(to: CGPoint(x: 512, y: mid + 40))
    ctx.addLine(to: CGPoint(x: 512 + 78, y: mid - 38))
    ctx.strokePath()
}

func png(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let g = NSGraphicsContext(bitmapImageRep: rep)!
    draw(g.cgContext, size: CGFloat(px))
    g.flushGraphics()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try png(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try png(1024).write(to: root.appendingPathComponent("Resources/AppIcon-1024.png"))

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try p.run(); p.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(p.terminationStatus == 0 ? "wrote \(icns.path)" : "iconutil failed")

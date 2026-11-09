import Cocoa

// ─────────────────────────────────────────────────────────────────────────────
// The cartoon Mac on the setup window and in the README.
//
// Two moods, drawn in code so they need no design tool and stay crisp at any
// size: `.sluggish` (dusty, sweating, half asleep) and `.fast` (sunglasses,
// cape, speed lines, sparkles). Drawn in a 600 x 400 space, then scaled.
// ─────────────────────────────────────────────────────────────────────────────

enum Mascot {
    enum Mood { case sluggish, fast }

    static let canvas = NSSize(width: 600, height: 400)

    static func draw(_ mood: Mood, in rect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        let k = min(rect.width / canvas.width, rect.height / canvas.height)
        ctx.translateBy(x: rect.midX - canvas.width * k / 2, y: rect.midY - canvas.height * k / 2)
        ctx.scaleBy(x: k, y: k)
        switch mood {
        case .fast:     drawFast(ctx)
        case .sluggish: drawSluggish(ctx)
        }
        ctx.restoreGState()
    }

    static func image(_ mood: Mood, size: NSSize) -> NSImage {
        NSImage(size: size, flipped: false) { r in draw(mood, in: r); return true }
    }

    // MARK: Palette

    private static func c(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
        CGColor(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: a)
    }
    private static let ink = c(0x1D2433)
    private static let shell = c(0xF4F5F8)
    private static let shellShade = c(0xD9DCE4)
    private static let screenBlue = c(0x2563EB)
    private static let screenDim = c(0x5B6478)

    // MARK: Shared body

    /// The computer itself: a rounded monitor on a stand, leaning by `tilt`
    /// radians, with the face drawn by `face` in screen coordinates.
    private static func body(_ ctx: CGContext, at center: CGPoint, tilt: CGFloat, screen: CGColor,
                             face: (CGContext, CGRect) -> Void) {
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: tilt)

        // Stand and foot.
        ctx.setFillColor(shellShade)
        ctx.addPath(CGPath(roundedRect: CGRect(x: -26, y: -118, width: 52, height: 50),
                           cornerWidth: 8, cornerHeight: 8, transform: nil))
        ctx.fillPath()
        ctx.addPath(CGPath(roundedRect: CGRect(x: -78, y: -128, width: 156, height: 20),
                           cornerWidth: 10, cornerHeight: 10, transform: nil))
        ctx.fillPath()

        // Monitor shell with an outline.
        let shellRect = CGRect(x: -130, y: -78, width: 260, height: 186)
        let shellPath = CGPath(roundedRect: shellRect, cornerWidth: 26, cornerHeight: 26, transform: nil)
        ctx.setFillColor(shell); ctx.addPath(shellPath); ctx.fillPath()
        ctx.setStrokeColor(ink); ctx.setLineWidth(6); ctx.addPath(shellPath); ctx.strokePath()

        // Chin with a small dot (no logo).
        ctx.setFillColor(shellShade)
        ctx.fillEllipse(in: CGRect(x: -6, y: -66, width: 12, height: 12))

        // Screen.
        let screenRect = CGRect(x: -110, y: -42, width: 220, height: 132)
        let screenPath = CGPath(roundedRect: screenRect, cornerWidth: 12, cornerHeight: 12, transform: nil)
        ctx.setFillColor(screen); ctx.addPath(screenPath); ctx.fillPath()
        ctx.saveGState()
        ctx.addPath(screenPath); ctx.clip()
        // A soft glare across the top-left.
        ctx.setFillColor(c(0xFFFFFF, 0.10))
        ctx.move(to: CGPoint(x: -110, y: 90)); ctx.addLine(to: CGPoint(x: -20, y: 90))
        ctx.addLine(to: CGPoint(x: -110, y: 0)); ctx.closePath(); ctx.fillPath()
        face(ctx, screenRect)
        ctx.restoreGState()
        ctx.restoreGState()
    }

    // MARK: Fast

    private static func drawFast(_ ctx: CGContext) {
        let center = CGPoint(x: 330, y: 205)

        // Speed lines streaming out behind (to the left).
        ctx.setLineCap(.round)
        let lines: [(y: CGFloat, x0: CGFloat, len: CGFloat, w: CGFloat)] = [
            (300, 40, 110, 8), (262, 10, 150, 10), (222, 30, 120, 8),
            (182, 0, 150, 10), (142, 45, 105, 8), (104, 70, 80, 6),
        ]
        for l in lines {
            ctx.setStrokeColor(c(0x5AA2FF, 0.55)); ctx.setLineWidth(l.w)
            ctx.move(to: CGPoint(x: l.x0, y: l.y)); ctx.addLine(to: CGPoint(x: l.x0 + l.len, y: l.y))
            ctx.strokePath()
        }

        // Cape, flowing back from the shoulders.
        ctx.saveGState()
        let cape = CGMutablePath()
        cape.move(to: CGPoint(x: 230, y: 300))
        cape.addCurve(to: CGPoint(x: 70, y: 250), control1: CGPoint(x: 170, y: 320), control2: CGPoint(x: 110, y: 300))
        cape.addCurve(to: CGPoint(x: 120, y: 205), control1: CGPoint(x: 95, y: 235), control2: CGPoint(x: 100, y: 215))
        cape.addCurve(to: CGPoint(x: 80, y: 150), control1: CGPoint(x: 95, y: 190), control2: CGPoint(x: 75, y: 170))
        cape.addCurve(to: CGPoint(x: 236, y: 150), control1: CGPoint(x: 140, y: 150), control2: CGPoint(x: 200, y: 140))
        cape.closeSubpath()
        ctx.setFillColor(c(0xEF4444)); ctx.addPath(cape); ctx.fillPath()
        ctx.setStrokeColor(ink); ctx.setLineWidth(6); ctx.setLineJoin(.round); ctx.addPath(cape); ctx.strokePath()
        ctx.restoreGState()

        body(ctx, at: center, tilt: -0.10, screen: screenBlue) { ctx, s in
            // Sunglasses.
            ctx.setFillColor(ink)
            let lensY = s.midY + 4
            for x in [s.midX - 52, s.midX + 10] {
                let lens = CGMutablePath()
                lens.move(to: CGPoint(x: x, y: lensY + 22))
                lens.addLine(to: CGPoint(x: x + 44, y: lensY + 22))
                lens.addCurve(to: CGPoint(x: x + 4, y: lensY + 6), control1: CGPoint(x: x + 46, y: lensY - 6),
                              control2: CGPoint(x: x + 10, y: lensY - 4))
                lens.closeSubpath()
                ctx.addPath(lens); ctx.fillPath()
            }
            ctx.setStrokeColor(ink); ctx.setLineWidth(6)
            ctx.move(to: CGPoint(x: s.midX - 10, y: lensY + 19)); ctx.addLine(to: CGPoint(x: s.midX + 12, y: lensY + 19))
            ctx.strokePath()
            // Glint on the lenses.
            ctx.setStrokeColor(c(0xFFFFFF, 0.8)); ctx.setLineWidth(3.5)
            ctx.move(to: CGPoint(x: s.midX - 40, y: lensY + 16)); ctx.addLine(to: CGPoint(x: s.midX - 30, y: lensY + 16))
            ctx.strokePath()
            ctx.move(to: CGPoint(x: s.midX + 22, y: lensY + 16)); ctx.addLine(to: CGPoint(x: s.midX + 32, y: lensY + 16))
            ctx.strokePath()

            // A big lopsided grin.
            ctx.setStrokeColor(c(0xFFFFFF)); ctx.setLineWidth(7); ctx.setLineCap(.round)
            ctx.move(to: CGPoint(x: s.midX - 36, y: s.midY - 26))
            ctx.addCurve(to: CGPoint(x: s.midX + 44, y: s.midY - 18),
                         control1: CGPoint(x: s.midX - 16, y: s.midY - 50), control2: CGPoint(x: s.midX + 26, y: s.midY - 46))
            ctx.strokePath()
        }

        // Sparkles in front.
        for (p, r) in [(CGPoint(x: 520, y: 330), 22.0), (CGPoint(x: 555, y: 255), 13.0),
                       (CGPoint(x: 490, y: 95), 16.0), (CGPoint(x: 205, y: 345), 12.0)] as [(CGPoint, CGFloat)] {
            sparkle(ctx, at: p, r: r, color: c(0xFBBF24))
        }
        // Little dust puffs left behind at the foot.
        ctx.setFillColor(c(0x94A3B8, 0.45))
        for (x, y, r) in [(150.0, 70.0, 16.0), (120.0, 60.0, 11.0), (95.0, 72.0, 7.0)] as [(CGFloat, CGFloat, CGFloat)] {
            ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
        }
    }

    // MARK: Sluggish

    private static func drawSluggish(_ ctx: CGContext) {
        let center = CGPoint(x: 300, y: 195)

        body(ctx, at: center, tilt: 0.06, screen: screenDim) { ctx, s in
            // Heavy half-closed eyelids.
            ctx.setStrokeColor(c(0xFFFFFF)); ctx.setLineWidth(6); ctx.setLineCap(.round)
            for x in [s.midX - 40, s.midX + 40] {
                ctx.move(to: CGPoint(x: x - 20, y: s.midY + 18)); ctx.addLine(to: CGPoint(x: x + 20, y: s.midY + 18))
                ctx.strokePath()
                ctx.setFillColor(c(0xFFFFFF))
                ctx.addArc(center: CGPoint(x: x, y: s.midY + 18), radius: 14, startAngle: .pi, endAngle: 2 * .pi, clockwise: false)
                ctx.fillPath()
                ctx.setFillColor(ink)
                ctx.fillEllipse(in: CGRect(x: x - 6, y: s.midY + 6, width: 12, height: 10))
            }
            // Wobbly mouth.
            ctx.setStrokeColor(c(0xFFFFFF)); ctx.setLineWidth(6)
            ctx.move(to: CGPoint(x: s.midX - 30, y: s.midY - 30))
            ctx.addCurve(to: CGPoint(x: s.midX + 30, y: s.midY - 30),
                         control1: CGPoint(x: s.midX - 10, y: s.midY - 18), control2: CGPoint(x: s.midX + 10, y: s.midY - 42))
            ctx.strokePath()
            // Too many windows open: a stack in the corner.
            for i in 0..<3 {
                let r = CGRect(x: s.maxX - 70 + CGFloat(i) * 8, y: s.maxY - 38 - CGFloat(i) * 8, width: 46, height: 30)
                ctx.setFillColor(c(0xE2E8F0)); ctx.fill(r)
                ctx.setStrokeColor(ink); ctx.setLineWidth(2.5); ctx.stroke(r)
            }
        }

        // Sweat drop.
        let drop = CGMutablePath()
        drop.move(to: CGPoint(x: 455, y: 330))
        drop.addCurve(to: CGPoint(x: 455, y: 280), control1: CGPoint(x: 480, y: 300), control2: CGPoint(x: 475, y: 280))
        drop.addCurve(to: CGPoint(x: 455, y: 330), control1: CGPoint(x: 435, y: 280), control2: CGPoint(x: 430, y: 300))
        ctx.setFillColor(c(0x7DD3FC)); ctx.addPath(drop); ctx.fillPath()
        ctx.setStrokeColor(ink); ctx.setLineWidth(4); ctx.addPath(drop); ctx.strokePath()

        // Zzz.
        for (p, size) in [(CGPoint(x: 150, y: 290), 44.0), (CGPoint(x: 112, y: 330), 32.0), (CGPoint(x: 86, y: 362), 22.0)] as [(CGPoint, CGFloat)] {
            NSAttributedString(string: "z", attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: .heavy),
                .foregroundColor: NSColor.labelColor]).draw(at: p)   // readable on a dark window too
        }

        // Dust gathering at the foot.
        ctx.setFillColor(c(0x94A3B8, 0.4))
        for (x, y, r) in [(220.0, 60.0, 18.0), (380.0, 58.0, 14.0), (410.0, 70.0, 9.0)] as [(CGFloat, CGFloat, CGFloat)] {
            ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
        }
    }

    private static func sparkle(_ ctx: CGContext, at p: CGPoint, r: CGFloat, color: CGColor) {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: p.x, y: p.y + r))
        path.addQuadCurve(to: CGPoint(x: p.x + r, y: p.y), control: p)
        path.addQuadCurve(to: CGPoint(x: p.x, y: p.y - r), control: p)
        path.addQuadCurve(to: CGPoint(x: p.x - r, y: p.y), control: p)
        path.addQuadCurve(to: CGPoint(x: p.x, y: p.y + r), control: p)
        ctx.setFillColor(color); ctx.addPath(path); ctx.fillPath()
    }
}

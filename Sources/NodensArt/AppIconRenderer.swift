import CoreGraphics
import Foundation

/// The app icon: two interlocking rings on a dark squircle.
/// The pale ring is the tailnet, the teal ring is the VPN, and the lit overlap
/// is the shared space Nodens keeps working.
///
/// Drawn on a 1024 × 1024 canvas, origin bottom-left, inside Apple's
/// 824 × 824 icon grid.
public enum AppIconRenderer {
    public static func cgImage(pixels: Int) -> CGImage? {
        guard let ctx = Bitmap.context(width: pixels, height: pixels) else { return nil }
        let scale = CGFloat(pixels) / 1024
        ctx.scaleBy(x: scale, y: scale)
        draw(in: ctx)
        return ctx.makeImage()
    }

    // Ring geometry.
    static let ringRadius: CGFloat = 205
    static let ringWidth: CGFloat = 46
    static let offset: CGFloat = 118
    static let gap: CGFloat = 14
    static let leftCenter = CGPoint(x: 512 - offset, y: 512)
    static let rightCenter = CGPoint(x: 512 + offset, y: 512)

    static let paleColors = [rgb(0xFF, 0xFF, 0xFF), rgb(0xAF, 0xC0, 0xF5)]
    static let tealColors = [rgb(0x86, 0xF4, 0xE3), rgb(0x10, 0xB0, 0x9E)]

    public static func draw(in ctx: CGContext) {
        let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
        let shape = squircle(in: tile)

        // Tile with a soft drop shadow.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0, 0, 0, 0.35))
        ctx.addPath(shape)
        ctx.setFillColor(rgb(0x14, 0x20, 0x40))
        ctx.fillPath()
        ctx.restoreGState()

        // Night-blue gradient with a faint glow from the top left.
        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        linearGradient(ctx, [rgb(0x32, 0x4F, 0x8E), rgb(0x0A, 0x12, 0x2C)], from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 100))
        radialGradient(ctx, [rgb(255, 255, 255, 0.13), rgb(255, 255, 255, 0)], center: CGPoint(x: 330, y: 820), radius: 560)
        ctx.restoreGState()

        drawLens(in: ctx)
        drawRings(in: ctx)

        // Top sheen and a hairline edge.
        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        linearGradient(ctx, [rgb(255, 255, 255, 0.09), rgb(255, 255, 255, 0)], from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 600))
        ctx.restoreGState()
        ctx.addPath(shape)
        ctx.setStrokeColor(rgb(255, 255, 255, 0.10))
        ctx.setLineWidth(2)
        ctx.strokePath()
    }

    /// The overlap of the two rings, lit in mint.
    private static func drawLens(in ctx: CGContext) {
        ctx.saveGState()
        ctx.addEllipse(in: circle(leftCenter, ringRadius))
        ctx.clip()
        ctx.addEllipse(in: circle(rightCenter, ringRadius))
        ctx.clip()
        linearGradient(
            ctx,
            [rgb(0x7D, 0xF0, 0xDC, 0.55), rgb(0x2D, 0xD4, 0xBF, 0.10)],
            from: CGPoint(x: 512, y: 512 + ringRadius),
            to: CGPoint(x: 512, y: 512 - ringRadius)
        )
        ctx.restoreGState()
    }

    /// Interlocked: the pale ring passes over the teal one at the top crossing,
    /// the teal ring over the pale one at the bottom crossing.
    private static func drawRings(in ctx: CGContext) {
        // Angles of the two crossings, seen from each ring's centre.
        let rise = sqrt(ringRadius * ringRadius - offset * offset)
        let paleTop = atan2(rise, offset) * 180 / .pi            // about 55°
        let tealBottom = -(180 - atan2(rise, offset) * 180 / .pi) // about -125°
        let span: CGFloat = 14

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 22, color: rgb(0, 0, 0, 0.40))
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)

        stroke(ring(rightCenter), colors: tealColors, center: rightCenter, in: ctx)
        clear(arc(leftCenter, from: paleTop - span, to: paleTop + span), in: ctx)
        stroke(ring(leftCenter), colors: paleColors, center: leftCenter, in: ctx)
        clear(arc(rightCenter, from: tealBottom - span, to: tealBottom + span), in: ctx)
        // Slightly longer than the cleared arc, so the joins are seamless.
        stroke(arc(rightCenter, from: tealBottom - span - 2, to: tealBottom + span + 2), colors: tealColors, center: rightCenter, in: ctx)

        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    private static func ring(_ center: CGPoint) -> CGPath {
        CGPath(ellipseIn: circle(center, ringRadius), transform: nil)
    }

    private static func arc(_ center: CGPoint, from start: CGFloat, to end: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.addArc(center: center, radius: ringRadius, startAngle: start * .pi / 180, endAngle: end * .pi / 180, clockwise: false)
        return path
    }

    /// Strokes `path` with a top-to-bottom gradient that spans the whole ring.
    private static func stroke(_ path: CGPath, colors: [CGColor], center: CGPoint, in ctx: CGContext) {
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setLineWidth(ringWidth)
        ctx.setLineCap(.butt)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        linearGradient(
            ctx,
            colors,
            from: CGPoint(x: center.x, y: center.y + ringRadius + ringWidth),
            to: CGPoint(x: center.x, y: center.y - ringRadius - ringWidth)
        )
        ctx.restoreGState()
    }

    /// Opens the over/under gap. Only inside the ring layer, never on the tile.
    private static func clear(_ path: CGPath, in ctx: CGContext) {
        ctx.saveGState()
        ctx.setBlendMode(.clear)
        ctx.addPath(path)
        ctx.setLineWidth(ringWidth + 2 * gap)
        ctx.setLineCap(.butt)
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// A superellipse (n = 5), close to the continuous corners of macOS icons.
    static func squircle(in rect: CGRect, exponent n: CGFloat = 5) -> CGPath {
        let path = CGMutablePath()
        let a = rect.width / 2
        let b = rect.height / 2
        let steps = 720
        for step in 0...steps {
            let t = CGFloat(step) / CGFloat(steps) * 2 * .pi
            let c = cos(t)
            let s = sin(t)
            let point = CGPoint(
                x: rect.midX + a * copysign(pow(abs(c), 2 / n), c),
                y: rect.midY + b * copysign(pow(abs(s), 2 / n), s)
            )
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

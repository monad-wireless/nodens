import AppKit
import CoreGraphics
import NodensCore

/// The menu-bar glyph: two linked rings, tailnet left, VPN right.
///
/// It is a template image, so macOS tints it for light and dark menu bars.
public enum GlyphRenderer {
    /// Size in points. 16 pt high sits inside the 22 pt menu bar like the system icons.
    public static let size = CGSize(width: 21, height: 16)

    // Geometry in points, origin bottom-left.
    static let radius: CGFloat = 5.2
    static let line: CGFloat = 1.45
    static let gap: CGFloat = 1.25
    static let dot: CGFloat = 1.75
    static let offAlpha: CGFloat = 0.5
    static let outer = radius + line / 2
    static let left = CGPoint(x: 0.6 + outer, y: size.height / 2)
    static let right = CGPoint(x: left.x + 7.6, y: size.height / 2)
    static let badge = CGPoint(x: right.x + 4.3, y: 3.0)

    public static func draw(_ spec: GlyphSpec, in ctx: CGContext, color: CGColor) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setFillColor(color)
        ctx.setStrokeColor(color)
        ctx.setLineWidth(line)

        ring(spec.tailnet, at: left, in: ctx)
        // A thin gap separates the VPN ring from the tailnet ring. When either ring is
        // filled, the VPN ring sits in front with a clean interior. When both are
        // outlines, only the crossings are cut, so the pair reads as two linked rings
        // and not as the letters "CO".
        if spec.tailnet == .on || spec.vpn == .on {
            knockOut(circle(right, outer + gap), in: ctx)
        } else {
            knockOutBand(center: right, radius: radius, width: line + 2 * gap, in: ctx)
        }
        ring(spec.vpn, at: right, in: ctx)

        if spec.attention {
            knockOut(circle(badge, 3.7), in: ctx)
            ctx.fillEllipse(in: circle(badge, 2.45))
        }
    }

    private static func ring(_ state: RingState, at center: CGPoint, in ctx: CGContext) {
        switch state {
        case .on:
            ctx.fillEllipse(in: circle(center, outer))
        case .off:
            // Faint: a template image keeps alpha, so off reads as inactive.
            ctx.saveGState()
            ctx.setAlpha(offAlpha)
            ctx.strokeEllipse(in: circle(center, radius))
            ctx.restoreGState()
        case .transition:
            ctx.strokeEllipse(in: circle(center, radius))
            ctx.fillEllipse(in: circle(center, dot))
        }
    }

    /// Clears pixels. Only used on the glyph's own transparent bitmap.
    private static func knockOut(_ rect: CGRect, in ctx: CGContext) {
        ctx.saveGState()
        ctx.setBlendMode(.clear)
        ctx.fillEllipse(in: rect)
        ctx.restoreGState()
    }

    private static func knockOutBand(center: CGPoint, radius: CGFloat, width: CGFloat, in ctx: CGContext) {
        ctx.saveGState()
        ctx.setBlendMode(.clear)
        ctx.setLineWidth(width)
        ctx.strokeEllipse(in: circle(center, radius))
        ctx.restoreGState()
    }

    /// Transparent bitmap of the glyph at `scale` pixels per point.
    public static func cgImage(_ spec: GlyphSpec, scale: CGFloat, color: CGColor = CGColor(gray: 0, alpha: 1)) -> CGImage? {
        let width = Int((size.width * scale).rounded(.up))
        let height = Int((size.height * scale).rounded(.up))
        guard let ctx = Bitmap.context(width: width, height: height) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        draw(spec, in: ctx, color: color)
        return ctx.makeImage()
    }

    @MainActor private static var cache: [GlyphSpec: NSImage] = [:]

    /// Template image with 1x, 2x and 3x bitmaps. The knock-outs need a bitmap of
    /// their own, so the glyph is never drawn straight into the menu bar.
    @MainActor public static func image(_ spec: GlyphSpec) -> NSImage {
        if let cached = cache[spec] { return cached }
        let image = NSImage(size: size)
        for scale: CGFloat in [1, 2, 3] {
            guard let bitmap = cgImage(spec, scale: scale) else { continue }
            let representation = NSBitmapImageRep(cgImage: bitmap)
            representation.size = size
            image.addRepresentation(representation)
        }
        image.isTemplate = true
        image.accessibilityDescription = StatusGlyph.describe(spec)
        cache[spec] = image
        return image
    }
}

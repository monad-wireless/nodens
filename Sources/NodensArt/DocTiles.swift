import CoreGraphics
import NodensCore

/// README images: one glyph state on a light and on a dark menu-bar strip.
public enum DocTiles {
    static let tile = CGSize(width: 36, height: 24)
    static let spacing: CGFloat = 6

    public static func statePair(_ spec: GlyphSpec, scale: CGFloat) -> CGImage? {
        let width = (tile.width * 2 + spacing) * scale
        let height = tile.height * scale
        guard let ctx = Bitmap.context(width: Int(width.rounded(.up)), height: Int(height.rounded(.up))) else { return nil }
        ctx.scaleBy(x: scale, y: scale)

        let light = CGRect(origin: .zero, size: tile)
        let dark = CGRect(origin: CGPoint(x: tile.width + spacing, y: 0), size: tile)
        draw(spec, on: light, background: rgb(0xF0, 0xF0, 0xF2), glyph: rgb(0x1D, 0x1D, 0x1F), scale: scale, in: ctx)
        draw(spec, on: dark, background: rgb(0x2B, 0x2B, 0x2E), glyph: rgb(0xF5, 0xF5, 0xF7), scale: scale, in: ctx)
        return ctx.makeImage()
    }

    private static func draw(_ spec: GlyphSpec, on rect: CGRect, background: CGColor, glyph: CGColor, scale: CGFloat, in ctx: CGContext) {
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil))
        ctx.setFillColor(background)
        ctx.fillPath()
        // The glyph gets its own bitmap first, because it clears pixels.
        guard let image = GlyphRenderer.cgImage(spec, scale: scale, color: glyph) else { return }
        let size = GlyphRenderer.size
        let origin = CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
        ctx.draw(image, in: CGRect(origin: origin, size: size))
    }
}

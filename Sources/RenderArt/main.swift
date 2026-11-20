// Renders the icon set and the README images.
// Usage: swift run RenderArt <package root>   (or: make art)
import CoreGraphics
import Foundation
import NodensArt
import NodensCore

let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
let docs = root.appendingPathComponent("docs/images")
for directory in [iconset, docs] {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
}

var failures = 0
func save(_ image: CGImage?, _ url: URL) {
    guard let image, Bitmap.writePNG(image, to: url) else {
        FileHandle.standardError.write(Data("could not write \(url.path)\n".utf8))
        failures += 1
        return
    }
    print("wrote \(url.path)")
}

// The ten sizes iconutil expects.
for base in [16, 32, 128, 256, 512] {
    for (factor, suffix) in [(1, ""), (2, "@2x")] {
        save(AppIconRenderer.cgImage(pixels: base * factor), iconset.appendingPathComponent("icon_\(base)x\(base)\(suffix).png"))
    }
}

save(AppIconRenderer.cgImage(pixels: 512), docs.appendingPathComponent("icon.png"))

// The states the README legend explains, in its order.
let states: [(String, GlyphSpec)] = [
    ("off", GlyphSpec(tailnet: .off, vpn: .off)),
    ("tailnet", GlyphSpec(tailnet: .on, vpn: .off)),
    ("vpn", GlyphSpec(tailnet: .off, vpn: .on)),
    ("both", GlyphSpec(tailnet: .on, vpn: .on)),
    ("connecting", GlyphSpec(tailnet: .on, vpn: .transition)),
    ("attention", GlyphSpec(tailnet: .on, vpn: .on, attention: true)),
]
for (name, spec) in states {
    save(DocTiles.statePair(spec, scale: 4), docs.appendingPathComponent("state-\(name).png"))
}

exit(failures == 0 ? 0 : 1)

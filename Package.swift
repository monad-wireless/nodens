// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Nodens",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Nodens", targets: ["Nodens"]),
    ],
    targets: [
        // Parsing, sanitizers, root commands, DNS planning, policies, glyph states.
        // No AppKit; everything here is unit-tested.
        .target(name: "NodensCore"),
        // CoreGraphics drawing of the app icon, the menu-bar glyph and the README images.
        .target(name: "NodensArt", dependencies: ["NodensCore"]),
        // The menu-bar app: drivers, Tailscale coexistence, Keychain, SwiftUI.
        .executableTarget(name: "Nodens", dependencies: ["NodensCore", "NodensArt"]),
        // `make art`: renders the icon set and the images in docs/images.
        .executableTarget(name: "RenderArt", dependencies: ["NodensCore", "NodensArt"]),
        .testTarget(name: "NodensCoreTests", dependencies: ["NodensCore"]),
    ]
)

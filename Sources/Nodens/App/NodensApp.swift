import AppKit
import SwiftUI

@main
struct NodensApp: App {
    @StateObject private var model = AppModel()

    init() {
        Self.exitIfAlreadyRunning()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Image(nsImage: model.statusImage)
                .accessibilityLabel(model.statusDescription)
        }
        .menuBarExtraStyle(.menu)

        Window("Nodens", id: SettingsWindow.id) {
            SettingsWindow(model: model)
        }
        .windowResizability(.contentMinSize)
    }

    /// One copy only: two copies would both act on Tailscale DNS. A copy that is
    /// shutting down (as during `make install`) gets three seconds to go.
    private static func exitIfAlreadyRunning() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return } // unbundled `swift run`
        let me = ProcessInfo.processInfo.processIdentifier
        var others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .map(\.processIdentifier)
            .filter { $0 != me }
        var waited = 0
        while !others.isEmpty, waited < 15 {
            usleep(200_000)
            waited += 1
            others = others.filter { kill($0, 0) == 0 }
        }
        if !others.isEmpty { exit(0) }
    }
}

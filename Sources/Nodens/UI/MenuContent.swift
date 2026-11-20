import AppKit
import NodensCore
import SwiftUI

/// The menu behind the menu-bar glyph.
struct MenuContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Section("VPN") {
            if model.profiles.isEmpty {
                Text("No profiles yet")
            }
            ForEach(model.profiles) { profile in
                Button { model.tapProfile(profile) } label: {
                    Label(model.title(for: profile), systemImage: model.symbol(for: profile))
                }
                .disabled(model.busy != nil)
            }
        }

        Section("Tailscale") {
            if model.tailnets.isEmpty {
                Text(model.tailscaleAvailable ? "No Tailscale profiles" : "Tailscale CLI not found")
            }
            ForEach(model.tailnets) { tailnet in
                Button { model.tapTailnet(tailnet) } label: {
                    Label(model.title(for: tailnet), systemImage: model.symbol(for: tailnet))
                }
                .disabled(model.busy != nil)
            }
        }

        if model.busy != nil || model.message != nil || model.dnsLine != nil || !model.staleTunnels.isEmpty {
            Divider()
            if let busy = model.busy {
                Label(busy, systemImage: "hourglass")
            }
            if let message = model.message {
                Label(message, systemImage: model.actionFailed ? "exclamationmark.triangle" : "info.circle")
            }
            if let dnsLine = model.dnsLine {
                Label(dnsLine, systemImage: model.dnsFailed ? "xmark.circle" : "checkmark.circle")
            }
            if !model.staleTunnels.isEmpty {
                Button { model.undoLeftovers() } label: {
                    Label("Undo leftover VPN changes…", systemImage: "arrow.uturn.backward")
                }
                .disabled(model.busy != nil)
            }
        }

        Divider()
        Button {
            openWindow(id: SettingsWindow.id)
            NSApp.activate(ignoringOtherApps: true)
        } label: {
            Label("Profiles & Settings…", systemImage: "slider.horizontal.3")
        }
        .keyboardShortcut(",")
        Button { NSApplication.shared.terminate(nil) } label: {
            Label("Quit Nodens", systemImage: "power")
        }
        .keyboardShortcut("q")
    }
}

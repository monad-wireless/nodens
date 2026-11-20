import AppKit
import NodensCore
import SwiftUI

/// Engines, the Tailscale route fix, DNS and file locations.
struct GeneralSettings: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                TextField("openvpn binary", text: $model.openvpnPath)
                    .font(.system(.body, design: .monospaced))
                if EngineLocator.isExecutable(model.openvpnPath) {
                    Label("Found.", systemImage: "checkmark.circle")
                } else {
                    Label("Not found. Install it with 'brew install openvpn', or point to Tunnelblick's copy.", systemImage: "xmark.circle")
                        .foregroundStyle(.red)
                }
                if let suggested = EngineLocator.suggestedOpenVPN(), suggested != model.openvpnPath {
                    Button("Use \(suggested)") { model.openvpnPath = suggested }
                }
                TextField("wg-quick", text: $model.wgQuickPath)
                    .font(.system(.body, design: .monospaced))
                if EngineLocator.isExecutable(model.wgQuickPath), EngineLocator.wireGuardToolsReady {
                    Label("Found, with Homebrew bash and wireguard-go.", systemImage: "checkmark.circle")
                } else {
                    Label("Install it with 'brew install wireguard-tools wireguard-go bash'.", systemImage: "xmark.circle")
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Engines")
            }

            Section {
                Picker("Route fix", selection: $model.routeStrategy) {
                    ForEach(RouteStrategy.allCases) { strategy in
                        Text(strategy.title).tag(strategy)
                    }
                }
                .pickerStyle(.radioGroup)
                Text("A full-tunnel VPN (all traffic through the VPN) can leave Tailscale's own traffic without a route. The fix adds routes for it while such a VPN is up. Which variant works best can differ per Mac; see docs/TAILSCALE.md.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Tailscale under a full-tunnel VPN")
            }

            Section {
                Toggle("Keep tailnet names working while a VPN is on", isOn: $model.keepTailnetNames)
                Text("Writes /etc/resolver files for the tailnet's domains and takes Tailscale out of the default DNS slot while a VPN is connected.")
                    .font(.caption).foregroundStyle(.secondary)
                if !model.tailnetDomains.isEmpty {
                    LabeledContent("Tailnet DNS files", value: model.tailnetDomains.joined(separator: ", "))
                    Button("Remove tailnet DNS files…") { model.removeTailnetResolverFiles() }
                        .disabled(model.busy != nil)
                }
            } header: {
                Text("DNS")
            }

            Section("Files") {
                LabeledContent("Profiles", value: ProfileStore.file.path)
                LabeledContent("Logs", value: HookPaths.logs)
                Button("Open logs in Finder") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: HookPaths.logs))
                }
            }
        }
        .formStyle(.grouped)
    }
}

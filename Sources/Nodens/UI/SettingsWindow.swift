import NodensCore
import SwiftUI

/// Profiles & Settings: a list on the left, a paste-in editor on the right.
struct SettingsWindow: View {
    static let id = "settings"

    private enum Item: Hashable {
        case general
        case profile(UUID)
    }

    @ObservedObject var model: AppModel
    @State private var selection: Item? = .general
    @State private var importNote: String?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("General", systemImage: "gearshape").tag(Item.general)
                Section("VPN profiles") {
                    ForEach(model.profiles) { profile in
                        HStack {
                            Label(profile.name, systemImage: model.symbol(for: profile))
                            Spacer()
                            Text(profile.kind.title).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(Item.profile(profile.id))
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 240)
            .safeAreaInset(edge: .bottom) { sidebarFooter }
        } detail: {
            switch selection {
            case .profile(let id)?:
                if let profile = model.profile(id) {
                    ProfileEditor(model: model, profile: profile) { selection = .general }
                        .id(id)
                } else {
                    GeneralSettings(model: model)
                }
            default:
                GeneralSettings(model: model)
            }
        }
        .frame(minWidth: 780, minHeight: 540)
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Menu {
                    ForEach(DriverKind.allCases, id: \.self) { kind in
                        Button("\(kind.title) profile") { selection = .profile(model.addProfile(kind)) }
                    }
                } label: {
                    Label("New profile", systemImage: "plus")
                }
                .fixedSize()
                Spacer()
                Button("Import from Tunnelblick") {
                    let added = model.importFromTunnelblick()
                    importNote = added == 0 ? "Nothing new to import." : "Imported \(added) profile\(added == 1 ? "" : "s")."
                }
            }
            if let importNote {
                Text(importNote).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
    }
}

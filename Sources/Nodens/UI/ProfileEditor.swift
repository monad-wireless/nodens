import AppKit
import NodensCore
import SwiftUI

/// One profile: name, the pasted configuration, the check result, the login.
struct ProfileEditor: View {
    @ObservedObject var model: AppModel
    @State private var draft: VPNProfile
    @State private var password = ""
    @State private var feedback: String?
    let onDelete: () -> Void

    init(model: AppModel, profile: VPNProfile, onDelete: @escaping () -> Void) {
        self.model = model
        self._draft = State(initialValue: profile)
        self.onDelete = onDelete
    }

    private var hasPassword: Bool { Keychain.hasPassword(for: draft.id) }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $draft.name)
                LabeledContent("Type", value: draft.kind.title)
            }

            Section {
                TextEditor(text: $draft.config)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 220)
                HStack {
                    Button("Paste from clipboard") {
                        if let text = NSPasteboard.general.string(forType: .string) { draft.config = text }
                    }
                    Spacer()
                    Text(draft.kind == .openvpn ? "Inline keys and certificates (<ca>…</ca>) only." : "Kept in a root-only file while connected.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Configuration: paste \(draft.kind.fileHint)")
            }

            Section("Check") {
                if draft.config.trimmed.isEmpty {
                    Text("Paste a configuration above.").foregroundStyle(.secondary)
                } else {
                    switch draft.kind {
                    case .openvpn: OpenVPNCheck(report: OpenVPNConfig.check(draft.config))
                    case .wireguard: WireGuardCheck(report: WireGuardConfig.check(draft.config))
                    }
                }
            }

            if draft.kind == .openvpn, OpenVPNConfig.check(draft.config).needsCredentials {
                Section("Login (the server asks for it)") {
                    TextField("Username", text: $draft.username)
                    SecureField(hasPassword ? "Password (stored in the Keychain; type to replace)" : "Password", text: $password)
                }
            }

            Section {
                HStack {
                    Button("Delete profile", role: .destructive) {
                        if let error = model.delete(draft.id) {
                            feedback = error
                        } else {
                            onDelete()
                        }
                    }
                    Spacer()
                    if let feedback {
                        Text(feedback).font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Save") {
                        feedback = model.save(draft, password: password.isEmpty ? nil : password) ?? "Saved."
                        password = ""
                    }
                    .keyboardShortcut("s")
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// The result of `OpenVPNConfig.check`.
struct OpenVPNCheck: View {
    let report: OpenVPNConfigReport

    var body: some View {
        if report.isUsable {
            Label("Usable. Server: \(report.remotes.joined(separator: ", "))", systemImage: "checkmark.circle")
        }
        ForEach(report.problems, id: \.self) { problem in
            Label(problem, systemImage: "xmark.circle").foregroundStyle(.red)
        }
        if !report.removed.isEmpty {
            Label("Ignored (Nodens sets these itself, or they would run as root): \(report.removed.joined(separator: ", "))",
                  systemImage: "info.circle")
                .foregroundStyle(.secondary)
        }
    }
}

/// The result of `WireGuardConfig.check`.
struct WireGuardCheck: View {
    let report: WireGuardConfigReport

    private var routing: String {
        switch (report.fullTunnelIPv4, report.fullTunnelIPv6) {
        case (true, true): return "all IPv4 and IPv6 traffic"
        case (true, false): return "all IPv4 traffic (IPv6 on the uplink is turned off while connected)"
        case (false, true): return "all IPv6 traffic, IPv4 only for the listed networks"
        case (false, false): return "only the networks in AllowedIPs"
        }
    }

    var body: some View {
        if report.isUsable {
            Label("Usable. Endpoint: \(report.endpoints.isEmpty ? "none (listen only)" : report.endpoints.joined(separator: ", "))",
                  systemImage: "checkmark.circle")
            LabeledContent("Address", value: report.addresses.joined(separator: ", "))
            LabeledContent("Routes", value: routing)
            if report.dnsServers.isEmpty {
                LabeledContent("DNS", value: "unchanged")
            } else if report.dnsDomains.isEmpty {
                Label("DNS \(report.dnsServers.joined(separator: ", ")) is not used: no search domain. Add the VPN's domains to the DNS line (DNS = 10.0.0.1, corp.internal) to send those names to it.",
                      systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            } else {
                LabeledContent("DNS", value: "\(report.dnsDomains.joined(separator: ", ")) → \(report.dnsServers.joined(separator: ", "))")
            }
        }
        ForEach(report.problems, id: \.self) { problem in
            Label(problem, systemImage: "xmark.circle").foregroundStyle(.red)
        }
        if !report.ignoredDNS.isEmpty {
            Label("Ignored DNS entries (one-label domains are not routed): \(report.ignoredDNS.joined(separator: ", "))", systemImage: "info.circle")
                .foregroundStyle(.secondary)
        }
        if !report.removed.isEmpty {
            Label("Handled by Nodens instead of wg-quick: \(report.removed.joined(separator: ", "))", systemImage: "info.circle")
                .foregroundStyle(.secondary)
        }
    }
}

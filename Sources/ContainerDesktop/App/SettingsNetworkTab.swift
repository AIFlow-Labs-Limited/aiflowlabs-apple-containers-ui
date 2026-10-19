import AppCore
import DesignSystem
import SwiftUI

/// DNS domains (admin prompt happens in the backend), host.container.internal helper, VPN fake-IP warning.
struct NetworkSettingsTab: View {
    @Environment(AppModel.self) private var model
    /// Empty means the placeholder "test". Prefilling "test" made the tab open with that text selected (the field
    /// is the window's first key view), which read as a pending edit.
    @State private var domain = ""
    @State private var working = false
    @State private var pendingDelete: String?

    private var effectiveDomain: String {
        let trimmed = domain.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "test" : trimmed
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("Domain", text: $domain, prompt: Text("test"))
                        .frame(maxWidth: 200)
                    Button("Enable DNS names…") { Task { await create() } }
                        .disabled(working)
                    if working { ProgressView().controlSize(.small) }
                }
                Text(
                    "Containers become reachable as <name>.\(effectiveDomain) from your Mac. "
                        + "macOS asks for an administrator password once."
                )
                .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("DNS names for containers")
            }
            Section("Configured domains") {
                if model.system.dnsDomains.isEmpty {
                    Text("None").foregroundStyle(.secondary)
                }
                ForEach(model.system.dnsDomains) { d in
                    HStack {
                        Text(d.domain).font(.monoBody)
                        if let lh = d.localhostAddress { Text("→ \(lh)").foregroundStyle(.secondary) }
                        Spacer()
                        Button(role: .destructive) {
                            pendingDelete = d.domain
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove domain \(d.domain)")
                        .accessibilityLabel("Remove domain \(d.domain)")
                    }
                }
            }
            Section("Reaching your Mac from containers") {
                HStack {
                    Text("host.container.internal").font(.monoBody)
                    CopyButton("host.container.internal", label: "Copy host name")
                    Spacer()
                }
                Text(
                    "Use this host name inside a container to reach services listening on your Mac "
                        + "(for example a database on localhost:5432)."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Label {
                    Text(
                        "VPNs and proxies with “fake IP” DNS (addresses in 198.18.0.0/15) break container DNS and image pulls. "
                            + "Exclude the container subnet (192.168.64.0/24) or switch the VPN to real-IP mode."
                    )
                    .font(.callout)
                } icon: {
                    Image(systemName: "exclamationmark.shield").foregroundStyle(.statusWarning)
                }
            }
            if let error = model.system.lastError {
                ErrorBanner(error, dismiss: { model.system.clearError() })
            }
        }
        .formStyle(.grouped)
        .task { await model.system.refresh() }
        .confirmDestructive(
            title: "Remove DNS domain?",
            message: "Removes the “\(pendingDelete ?? "")” resolver. Requires an administrator password.",
            actionTitle: "Remove",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
        ) {
            if let d = pendingDelete { Task { await model.system.deleteDNSDomain(d) } }
        }
    }

    private func create() async {
        working = true
        let name = effectiveDomain
        if await model.system.createDNSDomain(name) { model.toasts.success("DNS domain .\(name) enabled") }
        working = false
    }
}

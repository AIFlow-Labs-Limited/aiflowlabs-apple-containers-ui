import SwiftUI
import ContainerKit
import AppCore
import DesignSystem

/// Network inspector: key facts, attached containers, DNS caveat + DNS setup state.
struct NetworkDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    let network: Network
    let attached: [Container]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.m) {
                HStack {
                    Text(network.name).font(.title3.bold()).textSelection(.enabled)
                    if network.isBuiltin { TagBadge("built-in", tint: .accentColor) }
                }
                InspectorSection("Network") {
                    KeyValueGrid([
                        ("Mode", network.configuration.mode),
                        ("IPv4 subnet", network.status?.ipv4Subnet ?? ""),
                        ("Gateway", network.status?.ipv4Gateway ?? ""),
                        ("IPv6 subnet", network.status?.ipv6Subnet ?? ""),
                        ("Plugin", network.configuration.plugin ?? ""),
                        ("Created", RelativeDate.absolute(network.configuration.creationDate)),
                    ])
                }
                let labels = network.configuration.labels.filter { $0.key != ResourceLabel.role }
                if !labels.isEmpty {
                    InspectorSection("Labels") { KeyValueGrid(labels.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }) }
                }
                InspectorSection("Attached containers (\(attached.count))") {
                    if attached.isEmpty {
                        Text("No containers are attached.").foregroundStyle(.secondary)
                    } else {
                        ContainerLinks(containers: attached)
                    }
                }
                InspectorSection("Name resolution") { dnsSection }
            }
            .padding(Spacing.l)
        }
    }

    @ViewBuilder
    private var dnsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            if !network.isBuiltin {
                Label {
                    Text("Containers on custom networks can't resolve each other by name (apple/container#1809); "
                         + "use the default network for DNS names.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.statusWarning)
                }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Containers on the default network can reach each other and get DNS names under your DNS domain.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            let domains = model.system.dnsDomains
            HStack(spacing: Spacing.s) {
                StatusDot(domains.isEmpty ? .statusWarning : .statusRunning, label: domains.isEmpty ? "No DNS domain" : "DNS configured")
                Text(domains.isEmpty ? "No DNS domain configured"
                                     : "DNS domain\(domains.count == 1 ? "" : "s"): \(domains.map(\.domain).joined(separator: ", "))")
                    .font(.callout)
                Spacer()
                Button(domains.isEmpty ? "Set up DNS…" : "DNS settings…") {
                    UserDefaults.standard.set("network", forKey: SettingsView.selectedTabKey)
                    openSettings()
                }
                .buttonStyle(.link)
                .accessibilityHint("Opens Settings, Network")
            }
            if let domain = domains.first?.domain, let name = attached.first?.id, network.isBuiltin {
                Text("Example: \(name).\(domain)").font(.monoCaption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }
}

/// Create network: validated name, optional IPv4/IPv6 CIDRs, labels.
struct CreateNetworkSheet: View {
    @Environment(AppModel.self) private var model
    let didCreate: (String) -> Void
    @State private var name = ""
    @State private var subnet = ""
    @State private var subnetV6 = ""
    @State private var labels: [String] = []

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var nameProblem: String? {
        if let p = ResourceValidator.resourceName(trimmedName) { return p }
        return model.networks.items.contains { $0.name == trimmedName } ? "A network with that name exists." : nil
    }
    private var subnetProblem: String? { subnet.isEmpty ? nil : ResourceValidator.ipv4CIDR(subnet) }
    /// Non-blocking: overlaps with the default network or another network's subnet.
    private var subnetWarning: String? {
        guard !subnet.isEmpty, subnetProblem == nil else { return nil }
        let existing = model.networks.items.compactMap { $0.status?.ipv4Subnet }.filter { !$0.isEmpty }
        return ResourceValidator.ipv4CIDRWarning(subnet.trimmingCharacters(in: .whitespaces), existing: existing)
    }
    private var subnetV6Problem: String? { subnetV6.isEmpty ? nil : ResourceValidator.ipv6CIDR(subnetV6) }
    private var canSubmit: Bool {
        nameProblem == nil && subnetProblem == nil && subnetV6Problem == nil
            && StringRowsEditor.allValid(labels) { ResourceValidator.keyValue($0) }
    }

    var body: some View {
        FormSheet(title: "Create network", actionTitle: "Create", canSubmit: canSubmit, submit: submit) {
            TextField("Name", text: $name, prompt: Text("backend"))
            if !name.isEmpty, let nameProblem { Text(nameProblem).font(.caption).foregroundStyle(.statusError) }
            TextField("IPv4 subnet", text: $subnet, prompt: Text("automatic, e.g. 192.168.70.0/24"))
            if let subnetProblem { Text(subnetProblem).font(.caption).foregroundStyle(.statusError) }
            if let subnetWarning { Label(subnetWarning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.statusWarning) }
            TextField("IPv6 subnet", text: $subnetV6, prompt: Text("optional, e.g. fd00:70::/64"))
            if let subnetV6Problem { Text(subnetV6Problem).font(.caption).foregroundStyle(.statusError) }
            LabeledContent("Labels") {
                StringRowsEditor("Label", rows: $labels, placeholder: "key=value", addTitle: "Add label") {
                    ResourceValidator.keyValue($0)
                }
            }
            Text("Containers on a separate network are isolated from the default network and can't resolve each other by name yet.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func submit() {
        let name = trimmedName
        let v4 = subnet.isEmpty ? nil : subnet.trimmingCharacters(in: .whitespaces)
        let v6 = subnetV6.isEmpty ? nil : subnetV6.trimmingCharacters(in: .whitespaces)
        let labels = ResourceValidator.labels(from: labels)
        Task {
            if await model.networks.create(name: name, subnet: v4, subnetV6: v6, labels: labels) {
                model.toasts.success("Created network \(name)")
                didCreate(name)
            }
        }
    }
}

#Preview("Create network") {
    CreateNetworkSheet { _ in }.appModelEnvironment(ResourcePreview.model())
}

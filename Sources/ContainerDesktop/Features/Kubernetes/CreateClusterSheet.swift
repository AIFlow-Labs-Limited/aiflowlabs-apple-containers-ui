import AppCore
import ContainerKit
import DesignSystem
import SwiftUI

/// "New cluster" sheet built on `ClusterForm`; preview = `ClusterSpec.cliArguments`.
struct CreateClusterSheet: View {
    let create: (ClusterSpec) -> Void

    private let host = HostResources.current
    @State private var form = ClusterForm()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack {
                Text("New Kubernetes cluster").font(.title2.bold())
                TagBadge("Experimental", tint: .statusWarning)
            }
            Form {
                Section {
                    TextField("Name", text: $form.name)
                    FieldError(message: form.name.isEmpty ? nil : form.nameError)
                    Text("Also the kubectl context name.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Resources (per node)") {
                    Stepper(value: $form.cpus, in: 1...host.cpus) {
                        LabeledContent("CPUs", value: "\(form.cpus) of \(host.cpus)")
                    }
                    VStack(alignment: .leading) {
                        LabeledContent("Memory", value: "\(form.memoryGB) GB of \(host.memoryGB) GB")
                        Slider(
                            value: Binding(get: { Double(form.memoryGB) }, set: { form.memoryGB = Int($0.rounded()) }),
                            in: 1...Double(host.memoryGB), step: 1
                        )
                        .accessibilityLabel("Memory")
                        .accessibilityValue("\(form.memoryGB) gigabytes")
                    }
                    Text(
                        "Defaults: a quarter of your Mac (\(host.clusterDefaultCPUs) CPUs, \(host.clusterDefaultMemoryGB) GB), at least 2 CPUs and 2 GB."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                    LabeledContent("Worker nodes") {
                        Stepper("0", value: .constant(0), in: 0...0).disabled(true)
                    }
                    Text(
                        "Single node only: container 1.5.0's k8s plugin has no --workers option. Extra workers will be enabled when a CLI release adds it."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
                Section("Node") {
                    TextField("Node image", text: $form.nodeImage)
                    HStack {
                        TextField("CNI manifest", text: $form.cniManifestPath, prompt: Text("kindnet (built in)"))
                        Button("Choose…") { chooseCNI() }
                        if !form.cniManifestPath.isEmpty {
                            Button("Clear", systemImage: "xmark.circle.fill") { form.cniManifestPath = "" }
                                .labelStyle(.iconOnly).buttonStyle(.borderless)
                        }
                    }
                    Text(
                        "Optional. For Cilium, render the Helm chart to plain YAML with --set ipam.mode=kubernetes and pick that file."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                    Toggle("Delete the cluster when it stops", isOn: $form.removeOnStop)
                }
                Section("Command") {
                    CommandPreview(command: form.previewCommand())
                }
            }
            .formStyle(.grouped)
            HStack {
                Label(
                    "The first cluster downloads kindest/node (about 1 GB) and takes several minutes. Progress streams into Activity.",
                    systemImage: "clock"
                )
                .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    create(form.spec); dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!form.isValid)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 600, height: 720)
    }

    private func chooseCNI() {
        if let url = FilePanels.openFile(title: "Choose a CNI manifest (YAML)", types: ["yaml", "yml", "json"]) {
            form.cniManifestPath = url.path(percentEncoded: false)
        }
    }
}

#Preview("Create cluster") {
    CreateClusterSheet { _ in }
}

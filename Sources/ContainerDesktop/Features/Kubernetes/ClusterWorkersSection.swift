import AppCore
import ContainerKit
import DesignSystem
import SwiftUI

/// The "Worker nodes" part of the create sheet: default-sized workers plus optional separately sized groups.
/// Controls the installed CLI cannot honour are disabled and say why in one line.
struct ClusterWorkersSection: View {
    @Binding var form: ClusterForm
    let host: HostResources

    private var capabilities: KubernetesCapabilities { form.capabilities }

    var body: some View {
        Section("Worker nodes") {
            Stepper(value: $form.workers, in: 0...ClusterForm.maxWorkersPerRow) {
                LabeledContent("Workers", value: capabilities.supportsWorkers ? "\(form.workers)" : "0")
            }
            .disabled(!capabilities.supportsWorkers)
            .accessibilityValue("\(form.workers) default-sized workers")
            if let reason = capabilities.workersUnavailableReason {
                caption(reason)
            } else {
                caption(
                    form.totalWorkers == 0
                        ? "None: the one node is both control plane and worker."
                        : "Pods run on the workers only; the control-plane node is reserved for Kubernetes itself. "
                            + "Workers are named \(form.name)-worker-1, -2, …")
                sizedWorkers
            }
            FieldError(message: form.workersError)
        }
    }

    @ViewBuilder
    private var sizedWorkers: some View {
        ForEach($form.sizedWorkers) { $group in
            HStack(spacing: Spacing.m) {
                Stepper(value: $group.count, in: 1...ClusterForm.maxWorkersPerRow) {
                    Text("\(group.count) ×").monospacedDigit()
                }
                .accessibilityLabel("Workers in this group")
                Stepper(value: $group.cpus, in: 1...host.cpus) {
                    Text("\(group.cpus) CPUs").monospacedDigit()
                }
                .accessibilityLabel("CPUs per worker")
                Stepper(value: $group.memoryGB, in: 1...host.memoryGB) {
                    Text("\(group.memoryGB) GB").monospacedDigit()
                }
                .accessibilityLabel("Memory per worker")
                Spacer(minLength: 0)
                Button("Remove this group", systemImage: "minus.circle.fill") {
                    form.sizedWorkers.removeAll { $0.id == group.id }
                }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
            }
        }
        Button("Add Workers with Their Own Size", systemImage: "plus") { form.addSizedWorkers() }
            .disabled(!capabilities.supportsWorkerGroups)
        caption(
            capabilities.workerGroupsUnavailableReason
                ?? "Default-sized workers get a quarter of your Mac (\(host.clusterDefaultCPUs) CPUs, "
                + "\(host.clusterDefaultMemoryGB) GB), like a single node.")
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }
}

/// The "Images" part of the create sheet: the shared image store toggle with Apple's security warning.
struct ClusterImageStoreSection: View {
    @Binding var form: ClusterForm

    var body: some View {
        Section("Local images") {
            Toggle("Let nodes use this Mac's image store", isOn: $form.sharedImageStore)
                .disabled(!form.capabilities.supportsSharedImageStore)
            Text(form.capabilities.sharedImageStoreUnavailableReason ?? SharedImageStoreNotes.summary)
                .font(.caption).foregroundStyle(.secondary)
            if form.capabilities.supportsSharedImageStore, form.sharedImageStore {
                SharedImageStoreWarning()
            }
        }
    }
}

/// Apple's documented warning for `--shared-image-store`.
struct SharedImageStoreWarning: View {
    var body: some View {
        InfoCard(title: "Sharing your image store", symbol: "exclamationmark.triangle", tint: .statusWarning) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                ForEach(SharedImageStoreNotes.warnings, id: \.self) { Bullet(LocalizedStringKey($0)) }
            }
        }
    }
}

#Preview("Workers, 1.7 CLI") {
    @Previewable @State var form = ClusterForm(capabilities: .modern)
    Form {
        ClusterWorkersSection(form: $form, host: .current)
        ClusterImageStoreSection(form: $form)
    }
    .formStyle(.grouped)
    .frame(width: 600, height: 500)
}

#Preview("Workers, 1.5 CLI") {
    @Previewable @State var form = ClusterForm(capabilities: .legacy)
    Form {
        ClusterWorkersSection(form: $form, host: .current)
        ClusterImageStoreSection(form: $form)
    }
    .formStyle(.grouped)
    .frame(width: 600, height: 400)
}

import SwiftUI
import AppCore
import DesignSystem

/// "Clean up…" — prune per resource type with sizes, behind a destructive confirmation.
struct CleanupSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var containers = true
    @State private var images = true
    @State private var allImages = false
    @State private var volumes = false
    @State private var networks = false
    @State private var confirming = false
    @State private var working = false

    private var df: DiskUsageSnapshot { DiskUsageSnapshot(model: model) }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            Text("Clean up").font(.title2.bold())
            Text("Free disk space by removing resources nothing uses.")
                .foregroundStyle(.secondary)
            Form {
                Toggle(isOn: $containers) {
                    row("Stopped containers", detail: "\(df.stoppedContainers) stopped", bytes: df.containerBytes)
                }
                Toggle(isOn: $images) {
                    row("Unused images", detail: allImages ? "All images without containers" : "Dangling (untagged) only", bytes: df.imageBytes)
                }
                if images {
                    Toggle("Include tagged images not used by any container", isOn: $allImages)
                        .padding(.leading, Spacing.xl)
                }
                Toggle(isOn: $volumes) {
                    row("Unused volumes", detail: "Data in these volumes is lost", bytes: df.volumeBytes)
                }
                Toggle(isOn: $networks) {
                    row("Unused networks", detail: "Keeps the default network", bytes: nil)
                }
            }
            .formStyle(.grouped)
            .disabled(working)
            HStack {
                if working { ProgressView().controlSize(.small); Text("Cleaning up…").foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Clean up…", role: .destructive) { confirming = true }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || !(containers || images || volumes || networks))
            }
        }
        .padding(Spacing.xl)
        .frame(width: 520)
        .confirmDestructive(title: "Remove unused resources?", message: summary, actionTitle: "Remove",
                            isPresented: $confirming) { Task { await run() } }
        .task { await model.system.refreshDiskUsage() }
    }

    private func row(_ title: String, detail: String, bytes: Int64?) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let bytes { Text(ByteCount.format(bytes)).monospacedDigit().foregroundStyle(.secondary) }
        }
    }

    private var summary: String {
        var parts: [String] = []
        if containers { parts.append("all stopped containers") }
        if images { parts.append(allImages ? "all images not used by a container" : "dangling images") }
        if volumes { parts.append("volumes not mounted by any container (their data is deleted)") }
        if networks { parts.append("networks with no containers") }
        return "This removes " + parts.joined(separator: ", ") + ". It cannot be undone."
    }

    private func run() async {
        working = true
        let before = model.system.diskUsage?.totalBytes ?? 0
        if containers { await model.containers.prune() }
        if images { await model.images.prune(all: allImages) }
        if volumes { await model.volumes.prune() }
        if networks { await model.networks.prune() }
        await model.system.refreshDiskUsage()
        working = false
        let errors = [model.containers.lastError, model.images.lastError, model.volumes.lastError, model.networks.lastError].compactMap { $0 }
        if let first = errors.first {
            model.toasts.error("Clean up finished with errors", message: first.errorDescription)
        } else {
            let freed = max(0, before - (model.system.diskUsage?.totalBytes ?? before))
            model.toasts.success("Clean up complete", message: freed > 0 ? "Reclaimed \(ByteCount.format(freed))" : nil)
        }
        dismiss()
    }
}

/// Reclaimable numbers derived from `system df` + the stores.
private struct DiskUsageSnapshot {
    var stoppedContainers: Int
    var containerBytes: Int64?
    var imageBytes: Int64?
    var volumeBytes: Int64?

    @MainActor init(model: AppModel) {
        stoppedContainers = model.containers.items.count { !$0.isRunning && !$0.isSystemManaged }
        containerBytes = model.system.diskUsage?.containers.reclaimable
        imageBytes = model.system.diskUsage?.images.reclaimable
        volumeBytes = model.system.diskUsage?.volumes.reclaimable
    }
}

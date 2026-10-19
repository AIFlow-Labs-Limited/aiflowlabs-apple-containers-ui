import AppCore
import DesignSystem
import SwiftUI

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

    private var df: DiskUsageSnapshot { DiskUsageSnapshot(model: model, allImages: allImages) }

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
                    row(
                        "Unused images",
                        detail: allImages ? "All images without containers" : "Dangling (untagged) only",
                        bytes: df.imageBytes)
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
        .confirmDestructive(
            title: "Remove unused resources?", message: summary, actionTitle: "Remove",
            isPresented: $confirming
        ) { Task { await run() } }
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

    /// Stopped containers the user owns, by id — exactly what the toggle counts and what gets deleted
    /// (builder and Kubernetes node containers are never touched).
    private var containerIDs: [String] { model.containers.prunable.map(\.id) }

    private var summary: String {
        var parts: [String] = []
        if containers {
            let ids = containerIDs
            let names = ids.prefix(8).joined(separator: ", ") + (ids.count > 8 ? " and \(ids.count - 8) more" : "")
            parts.append(
                ids.isEmpty
                    ? "no containers (none are stopped)"
                    : "\(ids.count) stopped container\(ids.count == 1 ? "" : "s") (\(names))")
        }
        if images { parts.append(allImages ? "all images not used by a container" : "dangling images") }
        if volumes { parts.append("volumes not mounted by any container (their data is deleted)") }
        if networks { parts.append("networks with no containers") }
        return "This removes " + parts.joined(separator: ", ")
            + ". Builder and Kubernetes node containers are kept. It cannot be undone."
    }

    private func run() async {
        working = true
        let before = model.system.diskUsage?.totalBytes ?? 0
        var failures: [String] = []
        if containers {
            let result = await model.containers.prune()
            if !result.allSucceeded { failures.append(result.summary(verb: "Deleted", noun: "containers")) }
        }
        // Each prune's own outcome, never a possibly stale `lastError` from elsewhere.
        if images, case .failure(let error) = await model.images.prune(all: allImages) {
            failures.append("Images: " + (error.errorDescription ?? "failed"))
        }
        if volumes, case .failure(let error) = await model.volumes.prune() {
            failures.append("Volumes: " + (error.errorDescription ?? "failed"))
        }
        if networks, case .failure(let error) = await model.networks.prune() {
            failures.append("Networks: " + (error.errorDescription ?? "failed"))
        }
        await model.system.refreshDiskUsage()
        working = false
        if !failures.isEmpty {
            model.toasts.error("Clean up finished with errors", message: failures.joined(separator: "\n"))
        } else {
            let freed = max(0, before - (model.system.diskUsage?.totalBytes ?? before))
            model.toasts.success("Clean up complete", message: freed > 0 ? "Reclaimed \(ByteCount.format(freed))" : nil)
        }
        dismiss()
    }
}

/// Reclaimable numbers derived from `system df` + the stores. Each figure must describe what the toggle removes:
/// the engine's numbers cover every stopped container (the builder too) and every unused image (tagged too).
private struct DiskUsageSnapshot {
    var stoppedContainers: Int
    var containerBytes: Int64?
    var imageBytes: Int64?
    var volumeBytes: Int64?

    @MainActor init(model: AppModel, allImages: Bool) {
        let prunable = model.containers.prunable
        stoppedContainers = prunable.count
        let stoppedSystem = model.containers.items.contains { !$0.isRunning && $0.isSystemManaged }
        // A stopped builder made "1 stopped" read 2.83 GB; the app never removes it, so drop the engine figure then.
        containerBytes = prunable.isEmpty ? 0 : (stoppedSystem ? nil : model.system.diskUsage?.containers.reclaimable)
        if allImages {
            imageBytes = model.system.diskUsage?.images.reclaimable
        } else {
            imageBytes = PruneCandidates.images(model.images.items, containers: model.containers.items, all: false)
                .reduce(0) { $0 + $1.totalSize }
        }
        volumeBytes = model.system.diskUsage?.volumes.reclaimable
    }
}

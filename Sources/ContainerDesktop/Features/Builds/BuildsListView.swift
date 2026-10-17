import SwiftUI
import ContainerKit
import AppCore
import DesignSystem

/// Phase-1 builds view: builder card + local build history (features-resources replaces this in phase 2).
struct BuildsListView: View {
    @Environment(AppModel.self) private var model
    @State private var selection = Set<BuildRecord.ID>()
    @State private var confirmReset = false

    private var store: BuildsStore { model.builds }
    private var selected: BuildRecord? { store.history.first { selection.contains($0.id) } }

    var body: some View {
        VStack(spacing: 0) {
            builderCard
                .padding(Spacing.l)
            Divider()
            Table(store.filteredHistory, selection: $selection) {
                TableColumn("Tag") { r in Text(r.tag).fontWeight(.medium) }
                    .width(min: 160, ideal: 220)
                TableColumn("Status") { r in statusLabel(r) }
                    .width(min: 90, ideal: 110)
                TableColumn("Duration") { r in Text(r.duration.map { RelativeDate.duration($0) } ?? emDash).monospacedDigit() }
                    .width(70)
                TableColumn("Started") { r in Text(RelativeDate.format(r.startedAt)).foregroundStyle(.secondary) }
                    .width(min: 90, ideal: 120)
                TableColumn("Context") { r in Text(r.contextDirectory).font(.monoCaption).foregroundStyle(.secondary) }
            }
            .contextMenu(forSelectionType: BuildRecord.ID.self) { ids in
                Button("Remove from history") { store.deleteHistory(ids) }
            }
            .overlay {
                if store.filteredHistory.isEmpty {
                    EmptyStateView(symbol: "hammer", title: "No builds yet",
                                   message: "Builds you start from Container Desktop are recorded here with their logs.")
                }
            }
        }
        .inspector(isPresented: .constant(selected != nil)) {
            if let r = selected {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        Text(r.tag).font(.title3.bold())
                        KeyValueGrid([("Status", r.status.rawValue), ("Context", r.contextDirectory),
                                      ("Platforms", r.platforms.joined(separator: ", ")), ("Error", r.errorMessage ?? "")])
                    }
                    .padding(Spacing.l)
                    Divider()
                    OutputLogView(lines: r.log.map { OutputLine($0) }, follow: false)
                }
                .inspectorColumnWidth(min: 300, ideal: 420, max: 640)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                ToolbarActionButton("Clear history", systemImage: "clear") { store.clearHistory() }
                    .disabled(store.history.isEmpty)
            }
        }
        .storeChrome(store)
        .confirmDestructive(title: "Reset the builder?", message: "Deletes the BuildKit builder container and its build cache.",
                            actionTitle: "Reset", isPresented: $confirmReset) {
            Task { await store.resetBuilder() }
        }
    }

    private var builderCard: some View {
        HStack(spacing: Spacing.m) {
            MetricTile(title: "Builder", value: store.builderRunning ? "Running" : (store.builder == nil ? "Not created" : "Stopped"),
                       subtitle: store.builder?.imageReference)
            MetricTile(title: "CPUs", value: store.builder.map { "\($0.configuration.resources.cpus)" } ?? emDash)
            MetricTile(title: "Memory", value: store.builder.map { ByteCount.format($0.configuration.resources.memoryInBytes) } ?? emDash)
            VStack(alignment: .leading, spacing: Spacing.s) {
                if store.builderRunning {
                    Button("Stop builder") { Task { await store.stopBuilder() } }
                } else {
                    Button("Start builder") { Task { await store.startBuilder() } }
                        .buttonStyle(.borderedProminent)
                }
                Button("Reset…", role: .destructive) { confirmReset = true }
                    .disabled(store.builder == nil)
            }
            .frame(width: 130)
        }
    }

    @ViewBuilder
    private func statusLabel(_ r: BuildRecord) -> some View {
        switch r.status {
        case .running: Label("Building", systemImage: "hourglass").foregroundStyle(.statusWarning)
        case .succeeded: Label("Succeeded", systemImage: "checkmark.circle.fill").foregroundStyle(.statusRunning)
        case .failed: Label("Failed", systemImage: "xmark.octagon.fill").foregroundStyle(.statusError)
        case .cancelled: Label("Cancelled", systemImage: "minus.circle").foregroundStyle(.statusStopped)
        }
    }
}

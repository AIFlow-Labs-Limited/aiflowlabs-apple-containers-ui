import AppCore
import ContainerKit
import DesignSystem
import SwiftUI

/// Builds: builder card, persisted history (rebuild / log / delete) and the Build sheet.
struct BuildsListView: View {
    /// Deep-link token: `navigation.open(.builds, select: newBuildToken)` opens the Build sheet.
    static let newBuildToken = "__new-build__"
    #if DEBUG
        /// DEBUG launch hook: prefill for the next deep-linked Build sheet (screenshots).
        static var debugPrefill: BuildDraft?
    #endif

    @Environment(AppModel.self) private var model
    @State private var selection = Set<BuildRecord.ID>()
    @State private var sortOrder = [KeyPathComparator(\BuildRecord.startedAt, order: .reverse)]
    @State private var buildDraft: BuildSheetRequest?
    @State private var pendingDelete: Set<BuildRecord.ID> = []
    @State private var deepLinkTarget = Set<String>()

    private var store: BuildsStore { model.builds }
    private var rows: [BuildRecord] { store.filteredHistory.sorted(using: sortOrder) }
    private var selected: BuildRecord? {
        selection.count == 1 ? store.history.first { selection.contains($0.id) } : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            BuilderCard().padding(Spacing.l)
            Divider()
            historyTable
        }
        .inspector(isPresented: .constant(selected != nil)) {
            if let record = selected {
                BuildRecordDetail(record: record, rebuild: { rebuild(record) })
                    .inspectorColumnWidth(min: 320, ideal: 440, max: 680)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                ToolbarActionButton("Build…", systemImage: "hammer") {
                    buildDraft = BuildSheetRequest(draft: BuildDraft())
                }
                ToolbarActionButton("Clear history", systemImage: "clear", role: .destructive) {
                    pendingDelete = Set(store.history.filter { $0.status != .running }.map(\.id))
                }
                .disabled(store.history.isEmpty)
            }
        }
        .storeChrome(store)
        .deepLinkSelection(.builds, navigation: model.navigation, selection: $deepLinkTarget) { $0 }
        .onChange(of: deepLinkTarget) { openDeepLink() }
        .onAppear(perform: openDeepLink)
        .sheet(item: $buildDraft) { request in BuildSheet(draft: request.draft) }
        .confirmDestructive(
            title: pendingDelete.count == 1
                ? "Remove this build from history?" : "Remove \(pendingDelete.count) builds from history?",
            message:
                "Removes \(historyNames(pendingDelete)) and their logs from the local history. Built images are kept.",
            actionTitle: "Remove",
            isPresented: $pendingDelete.isPresent
        ) {
            store.deleteHistory(pendingDelete)
            selection.subtract(pendingDelete)
        }
    }

    private var historyTable: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Tag", value: \.tag) { r in Text(r.tag).fontWeight(.medium).accessibilityLabel("Build \(r.tag)")
            }
            .width(min: 150, ideal: 220)
            TableColumn("Status", value: \.status.rawValue) { r in BuildStatusLabel(record: r) }
                .width(min: 90, ideal: 110)
            TableColumn("Duration", value: \.durationSort) { r in
                Text(r.duration.map { RelativeDate.duration($0) } ?? (r.status == .running ? "…" : emDash))
                    .monospacedDigit()
            }
            .width(min: 60, ideal: 70)
            TableColumn("Started", value: \.startedAt) { r in
                Text(RelativeDate.format(r.startedAt)).foregroundStyle(.secondary).help(
                    RelativeDate.absolute(r.startedAt))
            }
            .width(min: 90, ideal: 120)
            TableColumn("Context", value: \.contextDirectory) { r in
                Text(r.contextDirectory).font(.monoCaption).foregroundStyle(.secondary).lineLimit(1).truncationMode(
                    .head
                )
                .help(r.contextDirectory)
            }
        }
        .contextMenu(forSelectionType: BuildRecord.ID.self) { ids in
            let picked = store.history.filter { ids.contains($0.id) }
            if let r = picked.first, picked.count == 1 {
                Button("Rebuild…") { rebuild(r) }
                Button("Show log") { selection = [r.id] }
                Button("Show image") { model.navigation.open(.images, select: r.tag) }
                    .disabled(r.status != .succeeded)
                Button("Copy tag") { copyToPasteboard(r.tag) }
                Divider()
            }
            Button("Remove from history…", role: .destructive) { pendingDelete = ids }
                .disabled(picked.contains { $0.status == .running })
        } primaryAction: { ids in
            if let id = ids.first, let r = store.history.first(where: { $0.id == id }) { rebuild(r) }
        }
        .overlay {
            if rows.isEmpty {
                EmptyStateView(
                    symbol: "hammer", title: "No builds yet",
                    message: "Builds you start from Container Desktop are recorded here with their logs.",
                    actionTitle: "Build an image…"
                ) { buildDraft = BuildSheetRequest(draft: BuildDraft()) }
            }
        }
    }

    private func rebuild(_ record: BuildRecord) { buildDraft = BuildSheetRequest(draft: BuildDraft(record: record)) }

    private func openDeepLink() {
        guard deepLinkTarget.contains(Self.newBuildToken) else { return }
        deepLinkTarget = []
        var draft = BuildDraft()
        #if DEBUG
            if let prefill = Self.debugPrefill { draft = prefill; Self.debugPrefill = nil }
        #endif
        buildDraft = BuildSheetRequest(draft: draft)
    }

    private func historyNames(_ ids: Set<BuildRecord.ID>) -> String {
        let tags = store.history.filter { ids.contains($0.id) }.map(\.tag)
        return tags.count <= 5
            ? tags.joined(separator: ", ") : tags.prefix(5).joined(separator: ", ") + " and \(tags.count - 5) more"
    }
}

/// Identifiable wrapper so `.sheet(item:)` re-creates the sheet for each request.
struct BuildSheetRequest: Identifiable {
    let id = UUID()
    let draft: BuildDraft
}

extension BuildRecord {
    /// Sort key: unfinished builds last.
    var durationSort: Double { duration ?? .greatestFiniteMagnitude }
}

/// Status label for a history row.
struct BuildStatusLabel: View {
    let record: BuildRecord

    var body: some View {
        switch record.status {
        case .running: Label("Building", systemImage: "hourglass").foregroundStyle(.statusWarning)
        case .succeeded: Label("Succeeded", systemImage: "checkmark.circle.fill").foregroundStyle(.statusRunning)
        case .failed: Label("Failed", systemImage: "xmark.octagon.fill").foregroundStyle(.statusError)
        case .cancelled: Label("Cancelled", systemImage: "minus.circle").foregroundStyle(.statusStopped)
        }
    }
}

/// History entry inspector: facts + log.
struct BuildRecordDetail: View {
    @Environment(AppModel.self) private var model
    let record: BuildRecord
    let rebuild: () -> Void

    /// While running, the live task (its ring buffer feeds the log); afterwards the persisted log.
    private var liveTask: LongRunningTask? {
        guard record.status == .running else { return nil }
        return BuildTaskMatch.task(for: record, in: model.taskCenter.tasks)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Spacing.s) {
                Text(record.tag).font(.title3.bold()).textSelection(.enabled)
                HStack {
                    BuildStatusLabel(record: record)
                    Spacer()
                    Button("Rebuild…", systemImage: "arrow.clockwise", action: rebuild)
                    Button("Show image", systemImage: "square.stack.3d.up") {
                        model.navigation.open(.images, select: record.tag)
                    }
                    .disabled(record.status != .succeeded)
                }
                .controlSize(.small)
                KeyValueGrid([
                    ("Context", record.contextDirectory),
                    ("Platforms", record.platforms.isEmpty ? "native" : record.platforms.joined(separator: ", ")),
                    ("Started", RelativeDate.absolute(record.startedAt)),
                    ("Duration", record.duration.map { RelativeDate.duration($0) } ?? ""),
                    ("Error", record.errorMessage ?? ""),
                ])
            }
            .padding(Spacing.l)
            Divider()
            if let task = liveTask {
                OutputLogView(buffer: task.buffer, follow: true)
            } else {
                OutputLogView(lines: record.log.map { OutputLine($0) }, follow: false)
            }
        }
    }
}

/// Finds the live task of a running build record: by `taskID` (set by `BuildsStore.build`). Records saved before
/// `taskID` existed fall back to the tag + closest start time (both are created in the same main-actor turn).
enum BuildTaskMatch {
    static let tolerance: TimeInterval = 2

    @MainActor
    static func task(for record: BuildRecord, in tasks: [LongRunningTask]) -> LongRunningTask? {
        if let id = record.taskID { return tasks.first { $0.id == id } }
        return tasks.filter { $0.kind == .build && $0.title == "Build \(record.tag)" }
            .map { (task: $0, gap: abs($0.startedAt.timeIntervalSince(record.startedAt))) }
            .filter { $0.gap <= tolerance }
            .min { $0.gap < $1.gap }?.task
    }
}

#Preview("Builds") {
    NavigationStack { BuildsListView() }
        .appModelEnvironment(ResourcePreview.model())
        .frame(width: 1100, height: 600)
}

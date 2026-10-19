import AppCore
import ContainerKit
import DesignSystem
import SwiftUI

/// Images: sortable table, toolbar (Pull · Load · Build · Prune), row actions and a tabbed detail inspector.
struct ImagesListView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("images.hideUntagged") private var hideUntagged = false
    @State private var selection = Set<String>()
    @State private var sortOrder = [KeyPathComparator(\ImageRow.repository)]
    @State private var sheet: ImageSheet?
    @State private var pendingDelete: [String] = []

    private var store: ImagesStore { model.images }

    /// Rows keyed by reference (several tags can share one digest).
    private var rows: [ImageRow] {
        let containers = model.containers.items
        return store.filtered
            .filter { !hideUntagged || !ResourceUsage.isUntagged($0) }
            .map { ImageRow(image: $0, usedBy: ResourceUsage.containers(using: $0, in: containers)) }
            .sorted(using: sortOrder)
    }

    private var selectedRows: [ImageRow] { rows.filter { selection.contains($0.id) } }

    var body: some View {
        let rows = rows
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.repository) { r in
                Text(r.repository).fontWeight(.medium).help(r.image.reference)
                    .accessibilityLabel("Image \(r.image.reference)")
            }
            .width(min: 150, ideal: 230)
            TableColumn("Tag", value: \.tagText) { r in
                Text(r.tagText).font(.monoCaption).foregroundStyle(r.image.tag == nil ? .secondary : .primary)
            }
            .width(min: 60, ideal: 100)
            TableColumn("Platforms", value: \.platformCount) { r in PlatformBadges(image: r.image) }
                .width(min: 90, ideal: 140)
            TableColumn("In use", value: \.usedCount) { r in InUseCell(names: r.usedBy.map(\.id)) }
                .width(min: 50, ideal: 60)
            TableColumn("Created", value: \.created) { r in
                Text(RelativeDate.format(r.created)).foregroundStyle(.secondary).help(RelativeDate.absolute(r.created))
            }
            .width(min: 80, ideal: 110)
            TableColumn("Size", value: \.size) { r in Text(ByteCount.format(r.size)).monospacedDigit() }
                .width(min: 60, ideal: 80)
            TableColumn("Digest", value: \.digest) { r in
                Text(r.image.configuration.descriptor.shortDigest).font(.monoCaption).foregroundStyle(.secondary)
                    .help(r.image.configuration.descriptor.digest)
            }
            .width(min: 90, ideal: 110)
        }
        .contextMenu(forSelectionType: String.self) { refs in
            contextMenu(refs)
        } primaryAction: { refs in
            if let ref = refs.first, refs.count == 1 { run(ref) }
        }
        .overlay {
            if rows.isEmpty && !store.isLoading {
                EmptyStateView(
                    symbol: "square.stack.3d.up",
                    title: store.items.isEmpty ? "No images" : "No matching images",
                    message: store.items.isEmpty
                        ? "Pull an image from a registry or build one to get started."
                        : "Clear the search or show untagged images.",
                    actionTitle: "Pull image…"
                ) { sheet = .pull(nil) }
            }
        }
        .inspector(isPresented: .constant(selectedRows.count == 1)) {
            if let row = selectedRows.first {
                ImageDetailView(image: row.image, usedBy: row.usedBy, run: { run(row.image.reference) }) {
                    contextMenu([row.id])
                }
                .inspectorColumnWidth(min: 320, ideal: 420, max: 640)
            }
        }
        .toolbar { toolbar }
        .storeChrome(store)
        .deepLinkSelection(.images, navigation: model.navigation, selection: $selection) { key in
            store.items.first { ImageReferenceName.same($0.reference, key) || $0.id == key }?.reference
        }
        .sheet(item: $sheet) { sheet in sheetView(sheet) }
        .confirmDestructive(
            title: deleteTitle,
            message: "Deletes \(pendingDelete.joined(separator: ", ")). "
                + "Layers shared with other tags are kept.",
            actionTitle: "Delete",
            isPresented: $pendingDelete.isPresent
        ) {
            let refs = pendingDelete
            Task {
                await store.delete(refs); selection.subtract(refs)
            }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            ToolbarActionButton("Pull…", systemImage: "arrow.down.circle") { sheet = .pull(nil) }
            ToolbarActionButton("Load from tar…", systemImage: "square.and.arrow.down.on.square") { loadFromTar() }
            ToolbarActionButton("Build…", systemImage: "hammer") {
                model.navigation.open(.builds, select: BuildsListView.newBuildToken)
            }
            ToolbarActionButton("Prune…", systemImage: "scissors") { sheet = .prune }
            ToolbarActionButton("Delete", systemImage: "trash", role: .destructive) { requestDelete(selection) }
                .disabled(selection.isEmpty || selectedRows.contains { !$0.usedBy.isEmpty })
                .help(
                    selectedRows.contains { !$0.usedBy.isEmpty }
                        ? "An image in use by a container cannot be deleted" : "Delete")
            Menu {
                Toggle("Hide untagged images", isOn: $hideUntagged)
            } label: {
                Label("View options", systemImage: "line.3.horizontal.decrease.circle")
            }
            .help("View options")
        }
    }

    // MARK: Context menu

    @ViewBuilder
    private func contextMenu(_ refs: Set<String>) -> some View {
        let picked = rows.filter { refs.contains($0.id) }
        if let row = picked.first, picked.count == 1 {
            let ref = row.image.reference
            Button("Run…") { run(ref) }
            Button("Pull latest") { store.pull(ref) }
            Button("Push…") { sheet = .push(ref) }
            Button("Tag…") { sheet = .tag(ref) }
            Button("Save as tar…") { sheet = .save(ref) }
            Divider()
            Button("Copy reference") { copyToPasteboard(ref) }
            Button("Copy digest") { copyToPasteboard(row.image.configuration.descriptor.digest) }
            Divider()
            if row.usedBy.isEmpty {
                Button("Delete…", role: .destructive) { requestDelete(refs) }
            } else {
                Button("Delete — in use by \(row.usedBy.map(\.id).joined(separator: ", "))") {}
                    .disabled(true)
            }
        } else if !picked.isEmpty {
            Button("Pull latest") { picked.forEach { store.pull($0.image.reference) } }
            Button("Copy references") { copyToPasteboard(picked.map(\.image.reference).joined(separator: "\n")) }
            Divider()
            Button("Delete \(picked.count) images…", role: .destructive) { requestDelete(refs) }
                .disabled(picked.contains { !$0.usedBy.isEmpty })
        }
    }

    // MARK: Actions

    private var deleteTitle: String {
        pendingDelete.count == 1 ? "Delete image “\(pendingDelete[0])”?" : "Delete \(pendingDelete.count) images?"
    }

    private func requestDelete(_ refs: Set<String>) {
        let picked = rows.filter { refs.contains($0.id) }
        guard picked.allSatisfy({ $0.usedBy.isEmpty }) else { return }
        pendingDelete = picked.map(\.image.reference)
    }

    /// Hands the image to the Containers section's run sheet.
    private func run(_ reference: String) {
        model.runRequests.request(image: reference)
        model.navigation.open(.containers)
    }

    private func loadFromTar() {
        guard let url = FilePanels.openFile(title: "Load images from a tar archive", types: ["tar"]) else { return }
        let path = url.path(percentEncoded: false)
        model.toasts.info("Loading \(url.lastPathComponent)…")
        Task {
            if await store.perform({ try await model.backend.loadImages(from: path) }) {
                model.toasts.success("Loaded \(url.lastPathComponent)")
            }
        }
    }

    @ViewBuilder
    private func sheetView(_ sheet: ImageSheet) -> some View {
        switch sheet {
        case .pull(let ref): PullImageSheet(initialReference: ref ?? "")
        case .push(let ref): PushImageSheet(reference: ref)
        case .tag(let ref): TagImageSheet(source: ref) { newRef in selection = [newRef] }
        case .save(let ref): SaveImageSheet(image: store.items.first { $0.reference == ref })
        case .prune: PruneImagesSheet()
        }
    }
}

/// Which image sheet is open.
enum ImageSheet: Identifiable, Hashable {
    case pull(String?), push(String), tag(String), save(String), prune

    var id: String {
        switch self {
        case .pull(let r): return "pull:\(r ?? "")"
        case .push(let r): return "push:\(r)"
        case .tag(let r): return "tag:\(r)"
        case .save(let r): return "save:\(r)"
        case .prune: return "prune"
        }
    }
}

/// Table row: image + containers using it, with sortable keys.
struct ImageRow: Identifiable {
    let image: ContainerKit.Image
    let usedBy: [Container]
    var id: String { image.reference }
    var repository: String { image.repository }
    var tagText: String { image.tag ?? "<none>" }
    var platformCount: Int { image.platforms.count }
    var usedCount: Int { usedBy.count }
    var created: Date { image.created }
    var size: Int64 { image.totalSize }
    var digest: String { image.configuration.descriptor.digest }
}

/// Platform badges; multi-arch images get a highlighted "multi-arch" marker.
struct PlatformBadges: View {
    let image: ContainerKit.Image
    /// Badges shown before collapsing the rest into "+N" (an official image index lists 8+ platforms).
    var limit = 2

    var body: some View {
        let platforms = image.platforms
        HStack(spacing: Spacing.xs) {
            ForEach(platforms.prefix(limit), id: \.self) { PlatformBadge($0) }
            if platforms.count > limit {
                Text("+\(platforms.count - limit)")
                    .font(.caption2.monospaced()).foregroundStyle(.secondary)
                    .fixedSize()
                    .help(platforms.dropFirst(limit).map(\.slug).joined(separator: "\n"))
            }
            if image.isMultiArch {
                Image(systemName: "square.stack.3d.down.forward.fill").font(.caption2).foregroundStyle(.tint)
                    .help("Multi-arch image (\(image.platforms.count) platforms)")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Platforms: \(image.platforms.map(\.slug).joined(separator: ", "))")
    }
}

/// ✓ + count of containers using a resource, with the names as tooltip.
struct InUseCell: View {
    let names: [String]

    var body: some View {
        if names.isEmpty {
            Text(emDash).foregroundStyle(.secondary).accessibilityLabel("Not in use")
        } else {
            HStack(spacing: Spacing.xxs) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.statusRunning)
                Text("\(names.count)").monospacedDigit()
            }
            .help("Used by \(names.joined(separator: ", "))")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("In use by \(names.joined(separator: ", "))")
        }
    }
}

#Preview("Images") {
    let model = ResourcePreview.model()
    NavigationStack { ImagesListView() }
        .appModelEnvironment(model)
        .frame(width: 1100, height: 600)
}

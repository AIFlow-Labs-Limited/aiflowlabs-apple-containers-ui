import SwiftUI
import ContainerKit
import AppCore
import DesignSystem

/// Phase-1 images list (features-resources replaces this in phase 2).
struct ImagesListView: View {
    @Environment(AppModel.self) private var model
    @State private var selection = Set<String>()
    @State private var pendingDelete: [String] = []
    @State private var showPull = false
    @State private var confirmPrune = false

    private var store: ImagesStore { model.images }
    /// Rows keyed by reference: several tags can share one digest.
    private var rows: [ImageRow] { store.filtered.map(ImageRow.init) }
    private var selected: [ContainerKit.Image] { store.items.filter { selection.contains($0.reference) } }

    var body: some View {
        Table(rows, selection: $selection) {
            TableColumn("Name") { r in Text(r.image.repository).fontWeight(.medium).help(r.image.reference) }
                .width(min: 160, ideal: 240)
            TableColumn("Tag") { r in Text(r.image.tag ?? "<none>").font(.monoCaption) }
                .width(min: 60, ideal: 100)
            TableColumn("Platforms") { r in
                HStack(spacing: Spacing.xs) { ForEach(r.image.platforms, id: \.self) { PlatformBadge($0) } }
            }
            .width(min: 90, ideal: 130)
            TableColumn("In use") { r in
                if store.isInUse(r.image) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.statusRunning).accessibilityLabel("In use")
                } else {
                    Text(emDash).foregroundStyle(.secondary)
                }
            }
            .width(50)
            TableColumn("Created") { r in Text(RelativeDate.format(r.image.created)).foregroundStyle(.secondary) }
                .width(min: 80, ideal: 110)
            TableColumn("Size") { r in Text(ByteCount.format(r.image.totalSize)).monospacedDigit() }
                .width(min: 60, ideal: 80)
        }
        .contextMenu(forSelectionType: String.self) { refs in
            Button("Pull latest") { refs.forEach { store.pull($0) } }
            Button("Push") { refs.forEach { store.push($0) } }
            Button("Copy reference") { copyToPasteboard(refs.joined(separator: "\n")) }
            Divider()
            Button("Delete…", role: .destructive) { pendingDelete = Array(refs) }
        }
        .overlay {
            if rows.isEmpty && !store.isLoading {
                EmptyStateView(symbol: "square.stack.3d.up", title: "No images", message: "Pull an image from a registry to get started.",
                               actionTitle: "Pull image…") { showPull = true }
            }
        }
        .inspector(isPresented: .constant(selected.count == 1)) {
            if let image = selected.first { ImageInspector(image: image, usedBy: store.containers(using: image).map(\.id)) }
        }
        .toolbar {
            ToolbarItemGroup {
                ToolbarActionButton("Pull", systemImage: "arrow.down.circle") { showPull = true }
                ToolbarActionButton("Delete", systemImage: "trash", role: .destructive) { pendingDelete = Array(selection) }
                    .disabled(selection.isEmpty)
                ToolbarActionButton("Prune", systemImage: "scissors") { confirmPrune = true }
            }
        }
        .storeChrome(store)
        .deepLinkSelection(.images, navigation: model.navigation, selection: $selection) { key in
            store.image(id: key)?.reference
        }
        .sheet(isPresented: $showPull) { PullImageSheet { ref, platform in store.pull(ref, platform: platform) } }
        .confirmDestructive(title: "Delete \(pendingDelete.count == 1 ? "image" : "\(pendingDelete.count) images")?",
                            message: "Deletes \(pendingDelete.joined(separator: ", ")). Containers using them keep running.",
                            actionTitle: "Delete",
                            isPresented: Binding(get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = [] } })) {
            let refs = pendingDelete
            Task { await store.delete(refs); selection.subtract(refs) }
        }
        .confirmDestructive(title: "Prune dangling images?", message: "Removes untagged images not used by any container.",
                            actionTitle: "Prune", isPresented: $confirmPrune) {
            Task { await store.prune(all: false) }
        }
    }
}

private struct ImageRow: Identifiable {
    let image: ContainerKit.Image
    var id: String { image.reference }
}

private struct ImageInspector: View {
    let image: ContainerKit.Image
    let usedBy: [String]

    var body: some View {
        let config = image.variants.first?.config?.config
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.m) {
                Text(image.reference).font(.title3.bold()).textSelection(.enabled)
                InspectorSection("Overview") {
                    KeyValueGrid([
                        ("ID", image.shortID),
                        ("Digest", image.configuration.descriptor.digest),
                        ("Size", ByteCount.format(image.totalSize)),
                        ("Platforms", image.platforms.map(\.slug).joined(separator: ", ")),
                        ("Used by", usedBy.joined(separator: ", ")),
                    ])
                }
                InspectorSection("Config") {
                    KeyValueGrid([
                        ("Entrypoint", config?.entrypoint?.joined(separator: " ") ?? ""),
                        ("Cmd", config?.cmd?.joined(separator: " ") ?? ""),
                        ("Workdir", config?.workingDir ?? ""),
                        ("Ports", config?.exposedPortList.joined(separator: ", ") ?? ""),
                    ])
                }
            }
            .padding(Spacing.l)
        }
    }
}

/// Reference + platform → streamed pull in the Activity panel.
struct PullImageSheet: View {
    let pull: (String, Platform?) -> Void
    @State private var reference = ""
    @State private var platform = "default"

    var body: some View {
        FormSheet(title: "Pull image", actionTitle: "Pull", canSubmit: !reference.trimmingCharacters(in: .whitespaces).isEmpty,
                  submit: { pull(reference.trimmingCharacters(in: .whitespaces), platform == "default" ? nil : Platform(architecture: platform)) }) {
            TextField("Image", text: $reference, prompt: Text("docker.io/library/nginx:latest"))
            Picker("Platform", selection: $platform) {
                Text("Default (this Mac)").tag("default")
                Text("linux/arm64").tag("arm64")
                Text("linux/amd64 (Rosetta)").tag("amd64")
            }
            Text("Progress appears in the Activity window.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

import AppCore
import ContainerKit
import DesignSystem
import SwiftUI

/// Tag an image with a new `repo[:tag]`.
struct TagImageSheet: View {
    @Environment(AppModel.self) private var model
    let source: String
    let didTag: (String) -> Void
    @State private var newReference: String

    init(source: String, didTag: @escaping (String) -> Void = { _ in }) {
        self.source = source
        self.didTag = didTag
        _newReference = State(initialValue: source)
    }

    private var trimmed: String { newReference.trimmingCharacters(in: .whitespaces) }
    private var problem: String? {
        if let p = ResourceValidator.imageReference(trimmed) { return p }
        return model.images.items.contains { ImageReferenceName.same($0.reference, trimmed) }
            ? "That reference already exists." : nil
    }

    var body: some View {
        FormSheet(title: "Tag image", actionTitle: "Tag", canSubmit: problem == nil, submit: submit) {
            LabeledContent("Source") { Text(source).font(.monoCaption).textSelection(.enabled) }
            TextField("New reference", text: $newReference, prompt: Text("myapp:1.0 or ghcr.io/you/app:1.0"))
            if let problem, trimmed != source { Text(problem).font(.caption).foregroundStyle(.statusError) }
            Text("Format: [registry/]repository[:tag]. Without a tag, “latest” is used.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func submit() {
        let target = trimmed, source = source, backend = model.backend
        Task {
            if await model.images.perform({ try await backend.tagImage(source, newReference: target) }) {
                model.toasts.success("Tagged \(target)")
                if let ref = model.images.items.first(where: { ImageReferenceName.same($0.reference, target) })?
                    .reference
                {
                    didTag(ref)
                }
            }
        }
    }
}

/// Save an image (optionally one platform) to a tar archive chosen with NSSavePanel.
struct SaveImageSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let image: ContainerKit.Image?
    @State private var platform: String = "all"
    @State private var destination: URL?
    @State private var working = false

    private var suggestedName: String {
        let base = (image?.repository ?? "image").replacingOccurrences(of: "/", with: "_")
        return "\(base)-\(image?.tag ?? "latest").tar"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            Text("Save image as tar").font(.title2.bold())
            Form {
                LabeledContent("Image") { Text(image?.reference ?? emDash).font(.monoCaption) }
                Picker("Platform", selection: $platform) {
                    Text("All platforms").tag("all")
                    ForEach(image?.platforms ?? [], id: \.slug) { Text($0.slug).tag($0.slug) }
                }
                LabeledContent("Destination") {
                    HStack {
                        Text(destination?.path(percentEncoded: false) ?? "Not chosen").font(.monoCaption)
                            .lineLimit(1).truncationMode(.middle).foregroundStyle(
                                destination == nil ? .secondary : .primary)
                        Button("Choose…") {
                            destination = FilePanels.save(
                                title: "Save image", suggestedName: suggestedName, type: "tar")
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(working)
            HStack {
                if working { ProgressView().controlSize(.small); Text("Saving…").foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(image == nil || destination == nil || working)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 520)
    }

    private func save() async {
        guard let image, let destination else { return }
        working = true
        let chosen = image.platforms.first { $0.slug == platform }
        let backend = model.backend, refs = [image.reference], path = destination.path(percentEncoded: false)
        let saved = await model.images.perform { try await backend.saveImages(refs, to: path, platform: chosen) }
        working = false
        if saved {
            model.toasts.success("Saved \(image.reference)", message: destination.lastPathComponent)
            dismiss()
        }
    }
}

/// Prune: dangling only vs all unused, with reclaimable size and the exact list of images removed.
struct PruneImagesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var all = false
    @State private var working = false

    /// The app's estimate; the engine decides what really goes, so the toast reports the before/after diff.
    private var candidates: [ContainerKit.Image] {
        PruneCandidates.images(model.images.items, containers: model.containers.items, all: all)
    }

    var body: some View {
        let candidates = candidates
        VStack(alignment: .leading, spacing: Spacing.l) {
            Text("Prune images").font(.title2.bold())
            Picker("Remove", selection: $all) {
                Text("Dangling images only (untagged)").tag(false)
                Text("All images not used by a container").tag(true)
            }
            .pickerStyle(.radioGroup)
            // The engine's figure counts every unused image, so next to "Dangling only" it read 24.8 GB while the
            // list below removed 327 MB. Only show it for the option it describes.
            if all, let reclaimable = model.system.diskUsage?.images.reclaimable {
                LabeledContent("Reclaimable (engine estimate)") {
                    Text(ByteCount.format(reclaimable)).monospacedDigit()
                }
            }
            GroupBox {
                if candidates.isEmpty {
                    Text("Nothing to remove.").foregroundStyle(.secondary).frame(
                        maxWidth: .infinity, alignment: .leading)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: Spacing.xxs) {
                            ForEach(candidates, id: \.reference) { image in
                                HStack {
                                    Text(image.reference).font(.monoCaption)
                                    Spacer()
                                    Text(ByteCount.format(image.totalSize)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 180)
                }
            } label: {
                Text(
                    "Expected to remove \(PruneText.plural(candidates.count, "image")) "
                        + "(\(ByteCount.format(candidates.reduce(0) { $0 + $1.totalSize })))")
            }
            if candidates.contains(where: { $0.repository == "kindest/node" }) {
                Label(
                    "Includes kindest/node, the Kubernetes node image. The next cluster you create downloads it again.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(Color.statusWarning)
            }
            Text("Computed by Container Desktop from the containers it can see; the engine makes the final decision.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Prune", role: .destructive) { Task { await prune() } }
                    .disabled(candidates.isEmpty || working)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 520)
        .task { await model.system.refreshDiskUsage() }
    }

    private func prune() async {
        working = true
        let before = model.images.items.map(\.reference)
        let backend = model.backend, all = all
        let ok = await model.images.perform { try await backend.pruneImages(all: all) }
        working = false
        await model.system.refreshDiskUsage()
        if ok {
            PruneText.toast(
                model.toasts,
                removed: PruneCandidates.removed(before: before, after: model.images.items.map(\.reference)),
                noun: "image")
            dismiss()
        }
    }
}

#Preview("Prune") {
    PruneImagesSheet().appModelEnvironment(ResourcePreview.model())
}

import AppCore
import ContainerKit
import ContainerKitMock
import DesignSystem
import SwiftUI

/// "Save as Image…": `container commit` (Apple container 1.6+). The command takes only the container and the
/// new image reference, so the sheet has one field, a live command preview and the streamed result.
struct SaveAsImageSheet: View {
    let container: Container
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var reference: String
    @State private var task: LongRunningTask?
    @State private var supported: Bool?

    init(container: Container) {
        self.container = container
        let suggestion = "\(container.id.lowercased()):snapshot"
        _reference = State(initialValue: ResourceValidator.imageReference(suggestion) == nil ? suggestion : "")
    }

    private var trimmed: String { reference.trimmingCharacters(in: .whitespaces) }
    private var problem: String? { ResourceValidator.imageReference(trimmed) }
    private var replacesExisting: Bool {
        model.images.items.contains { ImageReferenceName.same($0.reference, trimmed) }
    }
    private var preview: String { CLIBackend.commitCommandPreview(container.id, reference: trimmed) }
    private var canSave: Bool { problem == nil && supported == true && task == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            Text("Save “\(container.id)” as Image").font(.title2.bold())
            Form {
                LabeledContent("Container") {
                    Text("\(container.id) (\(container.isRunning ? "running" : "stopped"))").font(.monoCaption)
                }
                TextField("Image name", text: $reference, prompt: Text("myapp:1.0 or ghcr.io/you/app:1.0"))
                    .font(.monoBody)
                    .disabled(task != nil)
                    .onSubmit { if canSave { save() } }
                    .accessibilityLabel("Image name and tag")
                if let problem, !trimmed.isEmpty {
                    Text(problem).font(.caption).foregroundStyle(.statusError)
                } else if replacesExisting, task == nil {
                    Label(
                        "An image with this name already exists. Saving points the name at the new image.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption).foregroundStyle(.statusWarning)
                }
                Text(
                    "Format: [registry/]repository[:tag]; without a tag, “latest” is used. The new image keeps the "
                        + "source image's configuration and the container's platform. `container commit` has no "
                        + "other options. A running container keeps running while its filesystem is snapshotted."
                )
                .font(.caption).foregroundStyle(.secondary)
                if supported == false {
                    Label("Requires container 1.6 or later.", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.statusError)
                }
            }
            .formStyle(.grouped)
            if let task {
                TaskProgressPanel(tasks: [task])
            } else {
                HStack(alignment: .top, spacing: Spacing.s) {
                    Text(preview)
                        .font(.monoCaption)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Spacing.s)
                        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: Radius.small))
                        .accessibilityLabel("Command preview: \(preview)")
                    CopyButton(preview, label: "Copy command")
                }
            }
            HStack {
                Spacer()
                if let task {
                    if task.state == .succeeded {
                        Button("Show in Images") {
                            model.navigation.open(.images, select: trimmed)
                            dismiss()
                        }
                    }
                    Button(task.state == .running ? "Hide" : "Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Save", action: save)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(!canSave)
                }
            }
        }
        .padding(Spacing.xl)
        .frame(width: 520)
        .task { supported = await model.backend.supportsCommit() }
    }

    private func save() {
        guard canSave else { return }
        let images = model.images
        task = model.taskCenter.run(
            title: "Save \(container.id) as \(trimmed)", kind: .other,
            stream: model.backend.commitContainer(container.id, reference: trimmed)
        ) { _ in
            await images.refresh()
        }
    }
}

#Preview("Save as image") {
    let model = AppModel(backend: MockBackend(), observeAppActivation: false)
    SaveAsImageSheet(container: MockBackend.previewContainer(id: "api", image: "docker.io/library/acdemo-api:latest"))
        .appModelEnvironment(model)
}

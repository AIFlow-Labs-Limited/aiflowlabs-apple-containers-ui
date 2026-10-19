import SwiftUI
import ContainerKit
import ContainerKitMock
import AppCore
import DesignSystem

/// "Run a new container" (Docker Desktop's Optional settings + Apple extras). Live `container run` preview
/// built from `RunSpec.cliArguments`; Run streams through `TaskCenter` and then selects the new container.
///
/// Not a `FormSheet`: it needs a wider layout, inline validation and a command-preview footer.
struct RunContainerSheet: View {
    let onLaunched: (String) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var form: RunFormValues
    @State private var suggesting = false
    @State private var suggestMessage: String?
    @State private var showAdvanced = false
    @State private var loadedLastUsedFor: String?
    /// Remembered settings for the image being typed; decoded on image change, not on every render.
    @State private var lastForImage: RunFormValues?

    init(prefill: RunSpec? = nil, onLaunched: @escaping (String) -> Void = { _ in }) {
        self.onLaunched = onLaunched
        var values = prefill.map(RunFormValues.init(spec:)) ?? RunFormValues()
        // Opened from an image with nothing else set: restore what was used last time for that image.
        if let prefill, prefill == RunSpec(image: prefill.image), let last = RunFormValues.lastUsed(for: prefill.image) {
            values = last
        }
        _form = State(initialValue: values)
        _loadedLastUsedFor = State(initialValue: prefill?.image)
    }

    private var hostCPUs: Int { model.engine.status?.host?.cpus ?? ProcessInfo.processInfo.activeProcessorCount }
    private var hostMemoryMB: Double { Double(ProcessInfo.processInfo.physicalMemory >> 20) }
    private var spec: RunSpec { form.spec }
    private var issues: [String] { form.issues }
    private var imageIsLocal: Bool { model.images.items.contains { $0.reference == spec.image || ContainerRow.shortImage($0.reference) == spec.image } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Run a New Container").font(.title2.bold())
                Spacer()
                if loadedLastUsedFor != form.image, let last = lastForImage, last.image == form.image {
                    Button("Use Last Settings for This Image") { apply(last) }
                        .controlSize(.small)
                }
            }
            .padding([.horizontal, .top], Spacing.xl)
            .padding(.bottom, Spacing.s)
            Form {
                Section("Image") {
                    TextField("Image", text: $form.image, prompt: Text("docker.io/library/alpine:latest"))
                        .textInputSuggestions {
                            ForEach(imageSuggestions, id: \.self) { Text($0).textInputCompletion($0) }
                        }
                        .font(.monoBody)
                    if !form.image.isEmpty && !imageIsLocal {
                        Label("Not available locally — it will be pulled when the container starts.", systemImage: "arrow.down.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    TextField("Container name", text: $form.name, prompt: Text("Random if empty"))
                    TextField("Command", text: $form.command, prompt: Text("Image default, e.g. sleep 300"))
                        .font(.monoBody)
                }
                RunPortsSection(form: $form, suggest: suggestPorts, isSuggesting: suggesting)
                if let suggestMessage {
                    Text(suggestMessage).font(.caption).foregroundStyle(.secondary)
                }
                RunVolumesSection(form: $form, volumeNames: model.volumes.items.map(\.name))
                RunKeyValueSection(title: "Environment variables", rows: $form.environment, allowsDotEnv: true)
                RunResourcesSection(form: $form, hostCPUs: hostCPUs, hostMemoryMB: hostMemoryMB)
                RunNetworkSection(form: $form, networks: model.networks.items.map(\.id))
                RunAdvancedSection(form: $form, expanded: $showAdvanced)
                if showAdvanced {
                    RunKeyValueSection(title: "Labels", rows: $form.labels, keyPrompt: "com.example.key")
                }
            }
            .formStyle(.grouped)
            Divider()
            footer
        }
        .frame(width: 680, height: 760)
        .onChange(of: form.image, initial: true) { lastForImage = RunFormValues.lastUsed(for: form.image) }
        .task {
            if model.images.items.isEmpty { await model.images.refresh() }
            if model.networks.items.isEmpty { await model.networks.refresh() }
            if model.volumes.items.isEmpty { await model.volumes.refresh() }
        }
    }

    private var imageSuggestions: [String] {
        let q = form.image.trimmingCharacters(in: .whitespaces)
        let refs = model.images.items.map(\.reference).sorted()
        return Array((q.isEmpty ? refs : refs.filter { $0.localizedCaseInsensitiveContains(q) && $0 != q }).prefix(12))
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            if !issues.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(issues, id: \.self) { issue in
                        Label(issue, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.statusError)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            HStack(alignment: .top, spacing: Spacing.s) {
                // Secrets are masked in the preview; Copy asks whether to include them.
                let preview = spec.commandLineString(maskSecrets: true)
                ScrollView(.vertical) {
                    Text(preview)
                        .font(.monoCaption)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 54)
                .padding(Spacing.s)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: Radius.small))
                .accessibilityLabel("Command preview: \(preview)")
                Button {
                    if let text = SecretCopyPrompt.runCommand(for: spec) { copyToPasteboard(text) }
                } label: {
                    SwiftUI.Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy command")
                .accessibilityLabel("Copy command")
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Run", action: run)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!issues.isEmpty)
            }
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.m)
    }

    private func apply(_ last: RunFormValues) {
        let name = form.name
        form = last
        form.name = name
        loadedLastUsedFor = last.image
    }

    /// Adds the image's EXPOSE ports (`8080/tcp`) that are not mapped yet.
    private func suggestPorts() {
        let reference = spec.image
        let backend = model.backend
        // EXPOSE can differ per variant: read the one that will run (Automatic = native arm64).
        let architecture = form.platform == .amd64 ? "amd64" : "arm64"
        suggesting = true
        suggestMessage = nil
        Task {
            defer { suggesting = false }
            do {
                let image = try await backend.inspectImage(reference)
                let exposed = (image.variants.first { $0.platform.architecture == architecture } ?? image.variants.first)?
                    .config?.config?.exposedPortList ?? []
                let mapped = Set(form.ports.map(\.container))
                var added = 0
                for entry in exposed {
                    let parts = entry.split(separator: "/")
                    guard let port = parts.first.map(String.init), !mapped.contains(port) else { continue }
                    form.ports.append(.init(host: port, container: port, proto: parts.count > 1 ? String(parts[1]) : "tcp"))
                    added += 1
                }
                suggestMessage = exposed.isEmpty ? "\(ContainerRow.shortImage(reference)) does not declare any EXPOSE ports."
                    : (added == 0 ? "All exposed ports are already mapped." : nil)
            } catch {
                suggestMessage = "Pull the image first to read its exposed ports (\(BackendError(wrapping: error).errorDescription ?? "not found"))."
            }
        }
    }

    private func run() {
        guard self.spec.issues.isEmpty else { return }
        // `~` expanded and the image trimmed: the CLI does neither.
        let spec = self.spec.normalizedForRun()
        form.saveAsLastUsed()
        let store = model.containers
        let task = model.taskCenter.run(title: "Run \(spec.name ?? ContainerRow.shortImage(spec.image))", kind: .run,
                                        stream: model.backend.runContainer(spec))
        let launched = onLaunched
        dismiss()
        Task { @MainActor in
            await task.wait()
            guard task.state == .succeeded else { return }
            let printed = task.lines.last { $0.stream == .stdout && !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }?
                .text.trimmingCharacters(in: .whitespaces)
            await store.refresh()
            if let id = spec.name ?? printed, store.container(id: id) != nil { launched(id) }
        }
    }
}

#Preview("Run sheet") {
    let model = AppModel(backend: MockBackend(), observeAppActivation: false)
    var spec = RunSpec(image: "docker.io/library/nginx:alpine")
    spec.name = "web"
    spec.ports = [.init(hostPort: 8080, containerPort: 80)]
    return RunContainerSheet(prefill: spec)
        .appModelEnvironment(model)
}

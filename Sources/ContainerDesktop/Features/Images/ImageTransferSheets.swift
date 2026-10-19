import SwiftUI
import ContainerKit
import AppCore
import DesignSystem

/// Platform choice for pull/push/save. `.both` pulls each architecture separately.
enum PlatformChoice: String, CaseIterable, Identifiable {
    case native, arm64, amd64, both

    var id: String { rawValue }

    var title: String {
        switch self {
        case .native: return "Default (this Mac)"
        case .arm64: return "linux/arm64"
        case .amd64: return "linux/amd64 (Rosetta)"
        case .both: return "Both (arm64 + amd64)"
        }
    }

    /// Platforms to request; `[nil]` means "let the CLI decide".
    var platforms: [Platform?] {
        switch self {
        case .native: return [nil]
        case .arm64: return [.arm64]
        case .amd64: return [.amd64]
        case .both: return [.arm64, .amd64]
        }
    }
}

/// Pull an image: reference with history/autocomplete, platform, live output (also in Activity).
struct PullImageSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var reference: String
    @State private var platform = PlatformChoice.native
    @State private var tasks: [LongRunningTask] = []
    private let recents = RecentValues.pulledImages

    init(initialReference: String = "") { _reference = State(initialValue: initialReference) }

    private var trimmed: String { reference.trimmingCharacters(in: .whitespaces) }
    private var problem: String? { trimmed.isEmpty ? nil : ResourceValidator.imageReference(trimmed) }

    /// Recent pulls first, then repositories already present locally, filtered by what was typed.
    private var suggestions: [String] {
        let local = model.images.items.map { "\($0.repository):\($0.tag ?? "latest")" }
        var seen = Set<String>()
        let all = (recents.values + local).filter { seen.insert($0).inserted }
        let q = trimmed.lowercased()
        let matches = q.isEmpty ? all : all.filter { $0.lowercased().contains(q) && $0.lowercased() != q }
        return Array(matches.prefix(6))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            Text("Pull image").font(.title2.bold())
            Form {
                TextField("Image", text: $reference, prompt: Text("docker.io/library/nginx:latest"))
                    .onSubmit(pull)
                if let problem { Text(problem).font(.caption).foregroundStyle(.statusError) }
                if tasks.isEmpty && !suggestions.isEmpty {
                    LabeledContent(trimmed.isEmpty ? "Recent" : "Suggestions") {
                        VStack(alignment: .leading, spacing: Spacing.xxs) {
                            ForEach(suggestions, id: \.self) { s in
                                Button(s) { reference = s }
                                    .buttonStyle(.link)
                                    .font(.monoCaption)
                                    .accessibilityLabel("Use \(s)")
                            }
                        }
                    }
                }
                Picker("Platform", selection: $platform) {
                    ForEach(PlatformChoice.allCases) { Text($0.title).tag($0) }
                }
                if platform == .both {
                    Text("Pulls the image twice, once per architecture.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .disabled(!tasks.isEmpty)
            if !tasks.isEmpty { TaskProgressPanel(tasks: tasks) }
            HStack {
                Spacer()
                Button(tasks.isEmpty ? "Cancel" : "Close", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if tasks.isEmpty {
                    Button("Pull", action: pull)
                        .keyboardShortcut(.defaultAction)
                        .disabled(trimmed.isEmpty || problem != nil)
                }
            }
        }
        .padding(Spacing.xl)
        .frame(width: 560)
    }

    private func pull() {
        guard tasks.isEmpty, !trimmed.isEmpty, problem == nil else { return }
        recents.add(trimmed)
        tasks = platform.platforms.map { model.images.pull(trimmed, platform: $0) }
    }
}

/// Push an image: editable target reference (tags first when it differs), platform, registry login hint.
struct PushImageSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let reference: String
    @State private var target: String
    @State private var platform = PlatformChoice.native
    @State private var tasks: [LongRunningTask] = []
    @State private var working = false

    init(reference: String) {
        self.reference = reference
        _target = State(initialValue: reference)
    }

    private var trimmed: String { target.trimmingCharacters(in: .whitespaces) }
    private var problem: String? { ResourceValidator.imageReference(trimmed) }
    private var registry: String { ImageReferenceName.registry(of: trimmed) }
    private var isLoggedIn: Bool {
        model.registries.items.contains { login in
            let server = login.server.lowercased()
            return server == registry || (registry == "docker.io" && server.contains("docker.io"))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            Text("Push image").font(.title2.bold())
            Form {
                LabeledContent("Source") { Text(reference).font(.monoCaption).textSelection(.enabled) }
                TextField("Push as", text: $target, prompt: Text("ghcr.io/you/app:1.0"))
                if let problem, !trimmed.isEmpty { Text(problem).font(.caption).foregroundStyle(.statusError) }
                if !ImageReferenceName.same(trimmed, reference) && problem == nil {
                    Text("The image is tagged as \(trimmed) first, then pushed.").font(.caption).foregroundStyle(.secondary)
                }
                Picker("Platform", selection: $platform) {
                    ForEach(PlatformChoice.allCases.filter { $0 != .both }) { Text($0 == .native ? "All platforms in the image" : $0.title).tag($0) }
                }
                LabeledContent("Registry") {
                    HStack {
                        Text(registry).font(.monoCaption)
                        if isLoggedIn {
                            Label("Signed in", systemImage: "checkmark.seal.fill").foregroundStyle(.statusRunning).font(.caption)
                        } else {
                            Label("Not signed in", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.statusWarning).font(.caption)
                            Button("Sign in…") { dismiss(); model.navigation.open(.registries, select: registry) }
                                .buttonStyle(.link)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(!tasks.isEmpty || working)
            if !tasks.isEmpty { TaskProgressPanel(tasks: tasks) }
            HStack {
                Spacer()
                Button(tasks.isEmpty ? "Cancel" : "Close", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if tasks.isEmpty {
                    Button("Push") { Task { await push() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(problem != nil || working)
                }
            }
        }
        .padding(Spacing.xl)
        .frame(width: 560)
        .task { await model.registries.refresh() }
    }

    private func push() async {
        working = true
        defer { working = false }
        if !ImageReferenceName.same(trimmed, reference) {
            await model.images.tag(reference, as: trimmed)
            if model.images.lastError != nil { return }
        }
        tasks = [model.images.push(trimmed, platform: platform.platforms.first ?? nil)]
    }
}

#Preview("Pull") {
    PullImageSheet(initialReference: "redis").appModelEnvironment(ResourcePreview.model())
}

#Preview("Push") {
    PushImageSheet(reference: "docker.io/library/alpine:3.22").appModelEnvironment(ResourcePreview.model())
}

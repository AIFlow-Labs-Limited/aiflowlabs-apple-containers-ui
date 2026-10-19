import AppCore
import ContainerKit
import DesignSystem
import SwiftUI

/// Platform choice for pull / push / k8s load-image. `.both` pulls each architecture, one after the other.
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

    /// The `--platform` for a single-platform action (`nil` for `.native`; `.both` is not offered there).
    var single: Platform? { platforms.first ?? nil }
}

extension LineStream {
    /// Runs `makeStream` for each element in order, forwarding all lines into one stream: the second pull starts
    /// only after the first finished, and cancelling the stream cancels the one in flight.
    static func sequential<T: Sendable>(
        _ items: [T], header: @escaping @Sendable (T) -> String,
        _ makeStream: @escaping @Sendable (T) -> LineStream
    ) -> LineStream {
        LineStream { continuation in
            let work = Task {
                do {
                    for item in items {
                        try Task.checkCancellation()
                        continuation.yield(OutputLine(header(item)))
                        for try await line in makeStream(item) { continuation.yield(line) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in work.cancel() }
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
                    Text("Pulls the image twice, one architecture after the other.").font(.caption).foregroundStyle(
                        .secondary)
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
        let ref = trimmed
        let platforms = platform.platforms.compactMap { $0 }
        guard platforms.count > 1 else {
            tasks = [model.images.pull(ref, platform: platform.single)]
            return
        }
        // Two concurrent pulls of one reference race on the same content store; run them back to back in one task.
        let backend = model.backend
        let stream = LineStream.sequential(platforms, header: { "==> Pulling \(ref) for \($0.slug)" }) {
            backend.pullImage(ref, platform: $0)
        }
        let images = model.images
        tasks = [
            model.taskCenter.run(
                title: "Pull \(ref) (\(platforms.map(\.slug).joined(separator: " + ")))", kind: .pull,
                stream: stream
            ) { _ in await images.refresh() }
        ]
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
    /// The tag this sheet created before pushing (it stays on this Mac if the push fails).
    @State private var createdTag: String?
    @State private var tagError: BackendError?

    init(reference: String) {
        self.reference = reference
        _target = State(initialValue: reference)
    }

    private var trimmed: String { target.trimmingCharacters(in: .whitespaces) }
    private var problem: String? { ResourceValidator.imageReference(trimmed) }
    private var registry: String { ImageReferenceName.registry(of: trimmed) }
    private var needsTag: Bool { !ImageReferenceName.same(trimmed, reference) }
    /// Another local image already carries the target tag; tagging re-points it at this image.
    private var existingTarget: String? {
        guard needsTag, problem == nil else { return nil }
        return model.images.items.first { ImageReferenceName.same($0.reference, trimmed) }?.reference
    }
    private var pushFailed: Bool {
        guard let state = tasks.first?.state else { return false }
        if case .failed = state { return true }
        return state == .cancelled
    }
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
                if let existing = existingTarget {
                    Label(
                        "\(existing) already exists on this Mac. Pushing re-tags it to point at \(reference) first; "
                            + "the image it points at now loses that tag.", systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption).foregroundStyle(.statusWarning)
                } else if needsTag && problem == nil {
                    Text("The image is tagged as \(trimmed) first, then pushed. The new tag stays on this Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Picker("Platform", selection: $platform) {
                    ForEach(PlatformChoice.allCases.filter { $0 != .both }) {
                        Text($0 == .native ? "All platforms in the image" : $0.title).tag($0)
                    }
                }
                LabeledContent("Registry") {
                    HStack {
                        Text(registry).font(.monoCaption)
                        if isLoggedIn {
                            Label("Signed in", systemImage: "checkmark.seal.fill").foregroundStyle(.statusRunning).font(
                                .caption)
                        } else {
                            Label("Not signed in", systemImage: "exclamationmark.triangle.fill").foregroundStyle(
                                .statusWarning
                            ).font(.caption)
                            Button("Sign in…") {
                                dismiss()
                                model.navigation.open(
                                    .registries, select: RegistriesListView.loginToken(server: registry))
                            }
                            .buttonStyle(.link)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(!tasks.isEmpty || working)
            if let tagError { ErrorBanner(tagError, dismiss: { self.tagError = nil }) }
            if !tasks.isEmpty { TaskProgressPanel(tasks: tasks) }
            if pushFailed, let createdTag {
                Text(
                    "The tag \(createdTag) created for this push is still on this Mac. Delete it in Images if you don't need it."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button(tasks.isEmpty ? "Cancel" : "Close", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if tasks.isEmpty {
                    Button(existingTarget == nil ? "Push" : "Re-tag and Push") { Task { await push() } }
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
        let target = trimmed
        if needsTag {
            let backend = model.backend, source = reference
            var failure: BackendError?
            let tagged = await model.images.perform {
                do { try await backend.tagImage(source, newReference: target) } catch {
                    failure = BackendError(wrapping: error); throw error
                }
            }
            guard tagged else {
                // Shown here; not also as the list banner behind the sheet.
                tagError = failure ?? .other("Couldn't tag \(source) as \(target).")
                model.images.clearError()
                return
            }
            createdTag = target
        }
        tasks = [model.images.push(target, platform: platform.single)]
    }
}

#Preview("Pull") {
    PullImageSheet(initialReference: "redis").appModelEnvironment(ResourcePreview.model())
}

#Preview("Push") {
    PushImageSheet(reference: "docker.io/library/alpine:3.22").appModelEnvironment(ResourcePreview.model())
}

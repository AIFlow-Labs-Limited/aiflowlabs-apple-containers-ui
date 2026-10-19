import SwiftUI
import ContainerKit
import AppCore
import DesignSystem

/// Build an image from a context folder. Every option maps to `BuildSpec`; the command preview is
/// `BuildSpec.cliArguments`. Output streams into the sheet and the Activity window.
struct BuildSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft: BuildDraft
    @State private var dockerfiles: [String] = []
    @State private var stages: [String] = []
    @State private var task: LongRunningTask?
    private let recents = RecentValues.buildContexts

    init(draft: BuildDraft = BuildDraft()) { _draft = State(initialValue: draft) }

    private var contextURL: URL? {
        draft.contextDirectory.isEmpty ? nil : URL(filePath: (draft.contextDirectory as NSString).expandingTildeInPath)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text("Build image").font(.title2.bold())
            if let task {
                TaskProgressPanel(tasks: [task])
                if task.state == .succeeded {
                    Label("Built \(draft.spec.tag)", systemImage: "checkmark.seal.fill").foregroundStyle(.statusRunning)
                }
            } else {
                form
            }
            commandPreview
            footer
        }
        .padding(Spacing.xl)
        .frame(width: 620)
        .onAppear(perform: inspectContext)
        .onChange(of: draft.contextDirectory) { inspectContext() }
        .onChange(of: draft.dockerfile) { loadStages() }
    }

    // MARK: Form

    private var form: some View {
        Form {
            Section("Source") {
                LabeledContent("Context folder") {
                    HStack {
                        Text(draft.contextDirectory.isEmpty ? "Not chosen" : draft.contextDirectory)
                            .font(.monoCaption).lineLimit(1).truncationMode(.head)
                            .foregroundStyle(draft.contextDirectory.isEmpty ? .secondary : .primary)
                        Spacer()
                        Menu("Recent") {
                            ForEach(recents.values, id: \.self) { path in Button(path) { draft.contextDirectory = path } }
                            if recents.values.isEmpty { Text("No recent folders") }
                        }
                        .fixedSize()
                        Button("Choose…") {
                            if let url = FilePanels.openFolder(title: "Choose the build context", startingAt: draft.contextDirectory) {
                                draft.contextDirectory = url.path(percentEncoded: false)
                            }
                        }
                    }
                }
                Picker("Dockerfile", selection: $draft.dockerfile) {
                    Text(dockerfiles.first.map { "Auto (\($0))" } ?? "Auto (Dockerfile)").tag(String?.none)
                    ForEach(dockerfiles, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                if contextURL != nil && dockerfiles.isEmpty {
                    Text("No Dockerfile or Containerfile found in this folder.").font(.caption).foregroundStyle(.statusWarning)
                }
                TextField("Tag", text: $draft.tag, prompt: Text("myapp:dev"))
                if !draft.tag.isEmpty, let p = ResourceValidator.imageReference(draft.tag) {
                    Text(p).font(.caption).foregroundStyle(.statusError)
                }
                LabeledContent("Platforms") {
                    HStack {
                        Toggle("arm64", isOn: $draft.arm64)
                        Toggle("amd64 (Rosetta)", isOn: $draft.amd64)
                    }
                    .toggleStyle(.checkbox)
                }
            }
            Section("Options") {
                if stages.isEmpty {
                    TextField("Target stage", text: $draft.target, prompt: Text("optional"))
                } else {
                    Picker("Target stage", selection: $draft.target) {
                        Text("Final stage").tag("")
                        ForEach(stages, id: \.self) { Text($0).tag($0) }
                    }
                }
                Toggle("No cache", isOn: $draft.noCache)
                Toggle("Always pull base images", isOn: $draft.pull)
                Toggle("Forward SSH agent (--ssh default)", isOn: $draft.forwardSSH)
                LabeledContent("Build args") {
                    StringRowsEditor("Build arg", rows: $draft.buildArgs, placeholder: "KEY=VALUE", addTitle: "Add build arg") {
                        ResourceValidator.keyValue($0, allowBareKey: true)
                    }
                }
                LabeledContent("Labels") {
                    StringRowsEditor("Label", rows: $draft.labels, placeholder: "key=value", addTitle: "Add label") {
                        ResourceValidator.keyValue($0)
                    }
                }
                LabeledContent("Secrets") {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        StringRowsEditor("Secret", rows: $draft.secrets, placeholder: "id=npm,env=NPM_TOKEN",
                                         addTitle: "Add secret", validate: ResourceValidator.buildSecret)
                        Text(ResourceValidator.buildSecretHint)
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 300, idealHeight: 440, maxHeight: 440)
    }

    private var commandPreview: some View {
        let command = draft.spec.commandPreview
        return HStack(alignment: .top, spacing: Spacing.s) {
            Text(command)
                .font(.monoCaption)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Command preview: \(command)")
            CopyButton(command, label: "Copy command")
        }
        .padding(Spacing.s)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.medium))
    }

    private var footer: some View {
        HStack {
            if task == nil, let problem = draft.problems.first {
                Text(problem).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(task == nil ? "Cancel" : "Close", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            if let task, task.state == .succeeded {
                Button("Show image") {
                    model.navigation.open(.images, select: draft.spec.tag)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            } else if let task, task.state.isFinished {
                Button("Edit & retry") { self.task = nil }
            } else if task == nil {
                Button("Build", action: build)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.problems.isEmpty)
            }
        }
    }

    // MARK: Actions

    private func build() {
        guard draft.problems.isEmpty else { return }
        recents.add(draft.contextDirectory)
        RecentValues.buildTags.add(draft.spec.tag)
        draft.remember()
        task = model.builds.build(draft.spec)
    }

    private func inspectContext() {
        guard let url = contextURL else { dockerfiles = []; stages = []; return }
        dockerfiles = BuildContextInspector.dockerfiles(in: url)
        if let chosen = draft.dockerfile, !dockerfiles.contains(chosen), !chosen.hasPrefix("/") { draft.dockerfile = nil }
        loadStages()
    }

    private func loadStages() {
        guard let url = contextURL, let file = draft.dockerfile ?? dockerfiles.first else { stages = []; return }
        stages = BuildContextInspector.stages(dockerfile: file, in: url)
        if !draft.target.isEmpty && !stages.isEmpty && !stages.contains(draft.target) { draft.target = "" }
    }
}

#Preview("Build sheet") {
    var draft = BuildDraft()
    draft.contextDirectory = "~/src/acdemo"
    draft.tag = "acdemo-api:dev"
    draft.buildArgs = ["PYTHON_VERSION=3.11"]
    return BuildSheet(draft: draft).appModelEnvironment(ResourcePreview.model())
}

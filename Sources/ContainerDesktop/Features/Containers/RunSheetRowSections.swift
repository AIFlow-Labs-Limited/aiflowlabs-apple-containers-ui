import AppCore
import AppKit
import ContainerKit
import DesignSystem
import SwiftUI
import UniformTypeIdentifiers

/// Ports section: host → container rows, "Suggest" fills the image's EXPOSE ports.
struct RunPortsSection: View {
    @Binding var form: RunFormValues
    let suggest: () -> Void
    let isSuggesting: Bool

    var body: some View {
        Section {
            ForEach($form.ports) { $row in
                HStack(spacing: Spacing.s) {
                    TextField("Host", text: $row.host, prompt: Text("8080"))
                        .frame(width: 130)
                        .accessibilityLabel("Host port")
                    SwiftUI.Image(systemName: "arrow.right").foregroundStyle(.secondary).accessibilityHidden(true)
                    TextField("Container", text: $row.container, prompt: Text("80"))
                        .frame(width: 80)
                        .accessibilityLabel("Container port")
                    Picker("Protocol", selection: $row.proto) {
                        Text("TCP").tag("tcp")
                        Text("UDP").tag("udp")
                    }
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                    RemoveRowButton(label: "Remove port") { form.ports.removeAll { $0.id == row.id } }
                }
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
            }
            HStack {
                Button("Add Port", systemImage: "plus") { form.ports.append(.init()) }
                Button(action: suggest) {
                    if isSuggesting {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Suggest", systemImage: "wand.and.stars")
                    }
                }
                .help("Publish the ports the image declares with EXPOSE")
                .disabled(form.image.isEmpty || isSuggesting)
            }
            .buttonStyle(.borderless)
        } header: {
            Text("Ports")
        } footer: {
            Text("Host may include an address, e.g. 127.0.0.1:8080. Leave it empty to use the container port.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Volumes section: folder (bind, NSOpenPanel), named volume, or anonymous volume rows.
struct RunVolumesSection: View {
    @Binding var form: RunFormValues
    let volumeNames: [String]

    var body: some View {
        Section("Volumes") {
            ForEach($form.volumes) { $row in
                HStack(spacing: Spacing.s) {
                    Picker("Type", selection: $row.kind) {
                        ForEach(RunFormValues.VolumeKind.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    switch row.kind {
                    case .bind:
                        TextField("Host folder", text: $row.source, prompt: Text("~/project"))
                            .accessibilityLabel("Host folder")
                        Button("Choose…") { chooseFolder(for: row.id) }
                    case .volume:
                        TextField("Volume", text: $row.source, prompt: Text("data"))
                            .textInputSuggestions {
                                ForEach(
                                    volumeNames.filter {
                                        row.source.isEmpty || $0.localizedCaseInsensitiveContains(row.source)
                                    }, id: \.self
                                ) {
                                    Text($0).textInputCompletion($0)
                                }
                            }
                            .accessibilityLabel("Volume name")
                    case .anonymous:
                        EmptyView()
                    }
                    SwiftUI.Image(systemName: "arrow.right").foregroundStyle(.secondary).accessibilityHidden(true)
                    TextField("Container path", text: $row.target, prompt: Text("/data"))
                        .frame(minWidth: 110)
                        .accessibilityLabel("Container path")
                    Toggle("RO", isOn: $row.readOnly)
                        .toggleStyle(.checkbox)
                        .help("Mount read-only")
                    RemoveRowButton(label: "Remove volume") { form.volumes.removeAll { $0.id == row.id } }
                }
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
            }
            Button("Add Volume", systemImage: "plus") { form.volumes.append(.init()) }
                .buttonStyle(.borderless)
        }
    }

    private func chooseFolder(for id: UUID) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Mount"
        guard panel.runModal() == .OK, let url = panel.url,
            let index = form.volumes.firstIndex(where: { $0.id == id })
        else { return }
        form.volumes[index].source = url.path
        if form.volumes[index].target.isEmpty { form.volumes[index].target = "/" + url.lastPathComponent }
    }
}

/// Key/value rows (environment and labels), with optional "Load .env…".
struct RunKeyValueSection: View {
    let title: String
    @Binding var rows: [RunFormValues.KeyValueRow]
    var keyPrompt = "KEY"
    var allowsDotEnv = false
    @State private var loadError: String?

    var body: some View {
        Section {
            ForEach($rows) { $row in
                HStack(spacing: Spacing.s) {
                    TextField("Key", text: $row.key, prompt: Text(keyPrompt))
                        .font(.monoBody)
                        .frame(width: 180)
                        .accessibilityLabel("\(title) key")
                    Text("=").foregroundStyle(.secondary)
                    Group {
                        if EnvironmentVariable(key: row.key, value: row.value).isSensitive {
                            SecureField("Value", text: $row.value, prompt: Text("value"))
                        } else {
                            TextField("Value", text: $row.value, prompt: Text("value"))
                        }
                    }
                    .font(.monoBody)
                    .accessibilityLabel("\(title) value")
                    RemoveRowButton(label: "Remove \(row.key.isEmpty ? "row" : row.key)") {
                        rows.removeAll { $0.id == row.id }
                    }
                }
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
            }
            HStack {
                Button("Add", systemImage: "plus") { rows.append(.init()) }
                if allowsDotEnv { Button("Load .env…", systemImage: "doc.text") { loadDotEnv() } }
                if let loadError { Text(loadError).font(.caption).foregroundStyle(.statusError) }
            }
            .buttonStyle(.borderless)
        } header: {
            Text(title)
        }
    }

    private func loadDotEnv() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.prompt = "Load"
        panel.message = "Choose a .env file (KEY=VALUE per line)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let parsed = DotEnv.parse(text)
            for v in parsed {
                if let i = rows.firstIndex(where: { $0.key == v.key }) {
                    rows[i].value = v.value ?? ""
                } else {
                    rows.append(.init(key: v.key, value: v.value ?? ""))
                }
            }
            rows.removeAll { $0.key.isEmpty && $0.value.isEmpty }
            loadError = parsed.isEmpty ? "No variables found in \(url.lastPathComponent)." : nil
        } catch {
            loadError = "Could not read \(url.lastPathComponent)."
        }
    }
}

/// Small borderless ⊖ button for form rows.
struct RemoveRowButton: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { SwiftUI.Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
            .buttonStyle(.borderless)
            .help(label)
            .accessibilityLabel(label)
    }
}

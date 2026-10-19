import SwiftUI
import ContainerKit
import AppCore
import DesignSystem

/// Environment tab: searchable key/value table of the init process environment. Values whose key looks
/// secret (PASSWORD/SECRET/TOKEN/KEY) are masked until revealed (per row, or all at once).
struct ContainerEnvironmentTab: View {
    let container: Container
    @State private var query = ""
    @State private var revealAll = false
    @State private var revealed = Set<String>()
    @State private var selection = Set<EnvironmentVariable.ID>()

    private var variables: [EnvironmentVariable] {
        let all = EnvironmentVariable.parse(container.configuration.initProcess.environment)
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return all }
        return all.filter { $0.key.localizedCaseInsensitiveContains(q) || (!$0.isSensitive && ($0.value ?? "").localizedCaseInsensitiveContains(q)) }
    }

    private func isRevealed(_ v: EnvironmentVariable) -> Bool { revealAll || revealed.contains(v.key) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Spacing.s) {
                SearchField(text: $query, prompt: "Filter variables")
                Text("\(variables.count) variables").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Toggle(isOn: $revealAll) { Label(revealAll ? "Hide Secrets" : "Reveal Secrets", systemImage: revealAll ? "eye.slash" : "eye") }
                    .toggleStyle(.button)
                Button("Copy All", systemImage: "doc.on.doc") {
                    copyToPasteboard(variables.map(\.entry).joined(separator: "\n"))
                }
            }
            .controlSize(.small)
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.xs + 2)
            Divider()
            Table(variables, selection: $selection) {
                TableColumn("Key") { v in Text(v.key).font(.monoCaption.weight(.medium)).textSelection(.enabled) }
                    .width(min: 120, ideal: 220)
                TableColumn("Value") { v in
                    HStack(spacing: Spacing.xs) {
                        Text(v.displayValue(reveal: isRevealed(v)))
                            .font(.monoCaption)
                            .foregroundStyle(v.isSensitive && !isRevealed(v) ? .secondary : .primary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Spacer(minLength: 0)
                        if v.isSensitive {
                            Button {
                                if revealed.contains(v.key) { revealed.remove(v.key) } else { revealed.insert(v.key) }
                            } label: {
                                SwiftUI.Image(systemName: isRevealed(v) ? "eye.slash" : "eye")
                            }
                            .buttonStyle(.borderless)
                            .help(isRevealed(v) ? "Hide value" : "Reveal value")
                            .accessibilityLabel(isRevealed(v) ? "Hide \(v.key)" : "Reveal \(v.key)")
                        }
                        CopyButton(v.value ?? "", label: "Copy value of \(v.key)")
                    }
                }
                .width(min: 200, ideal: 480)
            }
            .contextMenu(forSelectionType: EnvironmentVariable.ID.self) { keys in
                let picked = variables.filter { keys.contains($0.key) }
                Button("Copy as KEY=VALUE") { copyToPasteboard(picked.map(\.entry).joined(separator: "\n")) }
                Button("Copy Keys") { copyToPasteboard(picked.map(\.key).joined(separator: "\n")) }
            }
            .accessibilityLabel("Environment variables")
        }
    }
}

#Preview("Environment") {
    let c = Container(id: "db", configuration: .init(
        id: "db", image: ImageReference(reference: "postgres", descriptor: Descriptor(digest: "sha256:ab", mediaType: "x", size: 1)),
        creationDate: .now, initProcess: .init(executable: "postgres", environment: [
            "PATH=/usr/local/bin:/usr/bin", "POSTGRES_PASSWORD=hunter2", "PGDATA=/var/lib/postgresql/data", "API_TOKEN=abc123",
        ])))
    ContainerEnvironmentTab(container: c)
        .frame(width: 800, height: 300)
}

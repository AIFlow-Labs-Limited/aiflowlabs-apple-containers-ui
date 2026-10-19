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
    @State private var revealed = Set<Int>()
    @State private var selection = Set<Int>()

    /// One table row per environment entry, keyed by its position: keys can repeat (`-e A=1 -e A=2`), so
    /// `EnvironmentVariable.id` (the key) is not unique.
    private struct Row: Identifiable {
        let id: Int
        let variable: EnvironmentVariable
    }

    private var rows: [Row] {
        let all = EnvironmentVariable.parse(container.configuration.initProcess.environment)
            .enumerated().map { Row(id: $0.offset, variable: $0.element) }
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return all }
        return all.filter { r in
            r.variable.key.localizedCaseInsensitiveContains(q)
                || (!r.variable.isSensitive && (r.variable.value ?? "").localizedCaseInsensitiveContains(q))
        }
    }

    private func isRevealed(_ r: Row) -> Bool { revealAll || revealed.contains(r.id) }

    var body: some View {
        let rows = self.rows
        let variables = rows.map(\.variable)
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
            Table(rows, selection: $selection) {
                TableColumn("Key") { r in Text(r.variable.key).font(.monoCaption.weight(.medium)).textSelection(.enabled) }
                    .width(min: 120, ideal: 220)
                TableColumn("Value") { r in
                    let v = r.variable
                    HStack(spacing: Spacing.xs) {
                        Text(v.displayValue(reveal: isRevealed(r)))
                            .font(.monoCaption)
                            .foregroundStyle(v.isSensitive && !isRevealed(r) ? .secondary : .primary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Spacer(minLength: 0)
                        if v.isSensitive {
                            Button {
                                if revealed.contains(r.id) { revealed.remove(r.id) } else { revealed.insert(r.id) }
                            } label: {
                                SwiftUI.Image(systemName: isRevealed(r) ? "eye.slash" : "eye")
                            }
                            .buttonStyle(.borderless)
                            .help(isRevealed(r) ? "Hide value" : "Reveal value")
                            .accessibilityLabel(isRevealed(r) ? "Hide \(v.key)" : "Reveal \(v.key)")
                        }
                        CopyButton(v.value ?? "", label: "Copy value of \(v.key)")
                    }
                }
                .width(min: 200, ideal: 480)
            }
            .alternatingRowBackgrounds(.disabled)
            .contextMenu(forSelectionType: Int.self) { ids in
                let picked = rows.filter { ids.contains($0.id) }.map(\.variable)
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

import SwiftUI
import ContainerKit
import ContainerKitMock
import AppCore
import DesignSystem

/// Inspect tab: key facts grid on top, collapsible JSON tree of the full `Container`, Copy JSON.
struct ContainerInspectTab: View {
    let container: Container
    @State private var showJSON = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                KeyValueGrid(Self.keyFacts(container))
                    .padding(Spacing.l)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: showJSON ? 230 : .infinity)
            Divider()
            HStack {
                Button {
                    withAnimation(.snappy) { showJSON.toggle() }
                } label: {
                    Label("Raw JSON", systemImage: showJSON ? "chevron.down" : "chevron.right")
                        .font(.callout.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(showJSON ? "Hide raw JSON" : "Show raw JSON")
                Spacer()
                Button("Copy JSON", systemImage: "doc.on.doc") { copyToPasteboard(Self.json(container)) }
                    .controlSize(.small)
            }
            .padding(.horizontal, Spacing.l)
            .padding(.vertical, Spacing.xs + 2)
            if showJSON {
                Divider()
                if let tree = try? JSONValue(encoding: container) {
                    JSONTreeView(tree, rootName: container.id)
                } else {
                    EmptyStateView(symbol: "curlybraces", title: "Unavailable", message: "Could not encode this container.")
                }
            }
        }
    }

    /// Pretty JSON of the full container (ISO 8601 dates, sorted keys).
    static func json(_ container: Container) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(container)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    static func keyFacts(_ c: Container) -> [(String, String)] {
        let cfg = c.configuration
        let process = cfg.initProcess
        let net = c.status?.networks.first
        return [
            ("ID", c.id),
            ("Image", c.imageReference),
            ("Digest", cfg.image.descriptor.digest),
            ("State", c.state.displayName),
            ("Started", c.status?.startedDate.map { "\(RelativeDate.absolute($0)) (\(RelativeDate.format($0)))" } ?? ""),
            ("Created", RelativeDate.absolute(cfg.creationDate)),
            ("IP address", c.primaryIPv4 ?? ""),
            ("Hostname", c.hostname ?? cfg.networks.first?.options?.hostname ?? ""),
            ("Network", net?.network ?? cfg.networks.first?.network ?? ""),
            ("MAC", net?.macAddress ?? ""),
            ("CPUs", String(cfg.resources.cpus)),
            ("Memory", ByteCount.format(cfg.resources.memoryInBytes)),
            ("Platform", cfg.platform.slug + (cfg.rosetta ? " (Rosetta)" : "")),
            ("Command", ShellWords.join([process.executable] + process.arguments)),
            ("Working dir", process.workingDirectory ?? "/"),
            ("User", process.user?.display ?? "root"),
            ("Restart policy", "none"),
            ("Flags", [cfg.useInit ? "init" : nil, cfg.readOnly ? "read-only" : nil, cfg.ssh ? "ssh agent" : nil,
                       cfg.virtualization ? "nested virtualization" : nil].compactMap { $0 }.joined(separator: ", ")),
        ]
    }
}

#Preview("Inspect") {
    let c = (try? Fixtures.containers().first) ?? Container(
        id: "x", configuration: .init(id: "x", image: ImageReference(reference: "alpine", descriptor: Descriptor(digest: "sha256:ab", mediaType: "x", size: 1)),
                                      creationDate: .now, initProcess: .init(executable: "sh")))
    ContainerInspectTab(container: c)
        .frame(width: 900, height: 480)
}

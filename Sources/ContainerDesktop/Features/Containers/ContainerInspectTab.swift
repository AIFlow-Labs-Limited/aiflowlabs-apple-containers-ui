import AppCore
import ContainerKit
import ContainerKitMock
import DesignSystem
import SwiftUI

/// Inspect tab: key facts grid on top, collapsible JSON tree of the full `Container`, Copy JSON.
struct ContainerInspectTab: View {
    let container: Container
    @Environment(AppModel.self) private var model
    @State private var showJSON = true
    @State private var showSecrets = false

    /// The container as displayed/copied: sensitive environment values masked unless "Show Secrets" is on.
    private var shown: Container { Self.masking(container, reveal: showSecrets) }

    static func masking(_ container: Container, reveal: Bool) -> Container {
        guard !reveal else { return container }
        var c = container
        c.configuration.initProcess.environment = EnvironmentVariable.masked(c.configuration.initProcess.environment)
        return c
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                KeyValueGrid(Self.keyFacts(container) + Self.restartFacts(container, supervisor: model.restarts))
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
                if EnvironmentVariable.containsSecrets(container.configuration.initProcess.environment) {
                    Toggle(isOn: $showSecrets) {
                        Label(
                            showSecrets ? "Hide Secrets" : "Show Secrets",
                            systemImage: showSecrets ? "eye.slash" : "eye")
                    }
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .help("Environment values whose key looks secret are masked in the JSON and in Copy JSON")
                }
                Button("Copy JSON", systemImage: "doc.on.doc") { copyToPasteboard(Self.json(shown)) }
                    .controlSize(.small)
            }
            .padding(.horizontal, Spacing.l)
            .padding(.vertical, Spacing.xs + 2)
            if showJSON {
                Divider()
                if let tree = try? JSONValue(encoding: shown) {
                    JSONTreeView(tree, rootName: container.id)
                } else {
                    EmptyStateView(
                        symbol: "curlybraces", title: "Unavailable", message: "Could not encode this container.")
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

    /// The restart policy and what the app has done about it. Empty for a container without a policy.
    @MainActor
    static func restartFacts(_ c: Container, supervisor: RestartSupervisor) -> [(String, String)] {
        let policy = c.restartPolicy
        guard policy.isEnforced else {
            return [("Restart policy", "None. It can only be chosen when a container is created.")]
        }
        var facts = [
            (
                "Restart policy",
                "\(policy.rawValue) — \(policy.summary) Enforced by Container Desktop while it is running"
                    + (supervisor.isEnabled ? "" : " (switched off in Settings › General)")
                    + "; fixed when the container was created."
            )
        ]
        if supervisor.isStandingDown {
            let stopped = supervisor.isIntentionallyStopped(c.id) && !c.isRunning
            facts.append(
                (
                    "Restarts",
                    "Made by the background helper (Settings › General), which does not report a count here"
                        + (stopped ? " · stopped from the app, so it stays stopped" : "")
                ))
            return facts
        }
        let status = supervisor.status(for: c.id) ?? RestartSupervisor.Status()
        var restarts = "\(status.restartCount) since Container Desktop was opened"
        if supervisor.isIntentionallyStopped(c.id) && !c.isRunning {
            restarts += " · stopped from the app, so it stays stopped"
        } else if status.gaveUp {
            restarts += " · gave up after \(status.consecutiveAttempts) attempts in a row"
        } else if let next = status.nextAttempt {
            restarts += " · next attempt \(RelativeDate.format(next))"
        }
        facts.append(("Restarts", restarts))
        return facts
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
            (
                "Started",
                c.status?.startedDate.map { "\(RelativeDate.absolute($0)) (\(RelativeDate.format($0)))" } ?? ""
            ),
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
            (
                "Flags",
                [
                    cfg.useInit ? "init" : nil, cfg.readOnly ? "read-only" : nil, cfg.ssh ? "ssh agent" : nil,
                    cfg.virtualization ? "nested virtualization" : nil,
                ].compactMap { $0 }.joined(separator: ", ")
            ),
        ]
    }
}

#Preview("Inspect") {
    let c =
        (try? Fixtures.containers().first)
        ?? Container(
            id: "x",
            configuration: .init(
                id: "x",
                image: ImageReference(
                    reference: "alpine", descriptor: Descriptor(digest: "sha256:ab", mediaType: "x", size: 1)),
                creationDate: .now, initProcess: .init(executable: "sh")))
    ContainerInspectTab(container: c)
        .appModelEnvironment(AppModel(backend: MockBackend(), observeAppActivation: false))
        .frame(width: 900, height: 480)
}

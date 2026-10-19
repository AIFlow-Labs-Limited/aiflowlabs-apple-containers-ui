import SwiftUI
import ContainerKit
import AppCore
import DesignSystem

/// Runtime config of one variant: Cmd, Entrypoint, Env (secrets masked), WorkingDir, User, ports, volumes, labels.
struct ImageConfigSection: View {
    let config: ContainerKit.Image.OCIConfig?
    @State private var revealSecrets = false

    private var runtime: ContainerKit.Image.OCIConfig.RuntimeConfig? { config?.config }

    var body: some View {
        if let runtime {
            VStack(alignment: .leading, spacing: Spacing.m) {
                InspectorSection("Process") {
                    KeyValueGrid([
                        ("Entrypoint", runtime.entrypoint?.joined(separator: " ") ?? ""),
                        ("Cmd", runtime.cmd?.joined(separator: " ") ?? ""),
                        ("Working dir", runtime.workingDir ?? ""),
                        ("User", runtime.user ?? ""),
                        ("Exposed ports", runtime.exposedPortList.joined(separator: ", ")),
                        ("Volumes", runtime.volumes.map { $0.keys.sorted().joined(separator: ", ") } ?? ""),
                    ])
                }
                InspectorSection("Environment") { environment(runtime.env ?? []) }
                InspectorSection("Labels") {
                    let labels = (runtime.labels ?? [:]).sorted { $0.key < $1.key }
                    if labels.isEmpty { Text("None").foregroundStyle(.secondary) } else { KeyValueGrid(labels.map { ($0.key, $0.value) }) }
                }
            }
        } else {
            Text("This variant has no runtime config.").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func environment(_ env: [String]) -> some View {
        if env.isEmpty {
            Text("None").foregroundStyle(.secondary)
        } else {
            let variables = EnvironmentVariable.parse(env)
            let hasSecrets = variables.contains(where: \.isSensitive)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                ForEach(variables) { v in
                    let hidden = v.isSensitive && !revealSecrets
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text(v.key).foregroundStyle(.secondary)
                        Text("=").foregroundStyle(.tertiary)
                        Text(v.displayValue(reveal: revealSecrets))
                            .textSelection(.enabled)
                    }
                    .font(.monoCaption)
                    .lineLimit(2)
                    .accessibilityLabel(hidden ? "\(v.key), hidden value" : v.entry)
                }
                if hasSecrets {
                    Toggle("Show secret values", isOn: $revealSecrets).toggleStyle(.checkbox).font(.caption)
                }
                HStack {
                    Spacer()
                    CopyButton(EnvironmentVariable.masked(env).joined(separator: "\n"), label: "Copy environment (secrets masked)")
                }
            }
        }
    }
}

/// Build history (`created_by`, created, empty layer) + rootfs diff IDs.
struct ImageLayersSection: View {
    let config: ContainerKit.Image.OCIConfig?

    var body: some View {
        let history = config?.history ?? []
        let diffIDs = config?.rootfs?.diffIDs ?? []
        VStack(alignment: .leading, spacing: Spacing.m) {
            InspectorSection("History (\(history.count) steps, \(history.count { $0.emptyLayer != true }) layers)") {
                if history.isEmpty { Text("No history recorded.").foregroundStyle(.secondary) }
                ForEach(Array(history.enumerated()), id: \.offset) { index, step in
                    LayerRow(index: index, step: step)
                    if index < history.count - 1 { Divider() }
                }
                if !history.isEmpty {
                    HStack {
                        Spacer()
                        CopyButton(history.compactMap(\.createdBy).joined(separator: "\n"), label: "Copy history")
                    }
                }
            }
            InspectorSection("Layer diff IDs (\(diffIDs.count))") {
                ForEach(Array(diffIDs.enumerated()), id: \.offset) { index, id in
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(index + 1)").font(.caption).foregroundStyle(.tertiary).frame(width: 20, alignment: .trailing)
                        Text(id).font(.monoCaption).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    }
                }
                if !diffIDs.isEmpty {
                    HStack { Spacer(); CopyButton(diffIDs.joined(separator: "\n"), label: "Copy diff IDs") }
                }
            }
        }
    }
}

private struct LayerRow: View {
    let index: Int
    let step: ContainerKit.Image.OCIConfig.History

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            HStack(spacing: Spacing.s) {
                Text("\(index + 1)").font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                if step.emptyLayer == true { TagBadge("empty") } else { TagBadge("layer", tint: .accentColor) }
                Spacer()
                if let created = step.created {
                    Text(RelativeDate.format(created)).font(.caption).foregroundStyle(.secondary).help(RelativeDate.absolute(created))
                }
            }
            Text(LayerHistoryText.shorten(step.createdBy ?? step.comment ?? "—"))
                .font(.monoCaption)
                .textSelection(.enabled)
                .help(step.createdBy ?? "")
        }
        .padding(.vertical, Spacing.xxs)
        .accessibilityElement(children: .combine)
    }
}

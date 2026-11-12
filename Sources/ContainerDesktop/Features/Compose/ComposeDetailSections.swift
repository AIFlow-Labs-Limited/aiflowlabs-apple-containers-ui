import AppCore
import AppKit
import ContainerKit
import DesignSystem
import SwiftUI

/// Variables the file refers to: where each value comes from, and a field to override it for this import.
struct ComposeVariablesSection: View {
    let session: ComposeImport

    var body: some View {
        if !session.references.isEmpty {
            Section {
                ForEach(session.references) { reference in
                    LabeledContent {
                        field(for: reference)
                    } label: {
                        VStack(alignment: .leading, spacing: Spacing.xxs) {
                            Text(reference.name).font(.monoBody)
                            Text(origin(of: reference))
                                .font(.caption)
                                .foregroundStyle(isMissing(reference) ? Color.statusError : Color.secondary)
                        }
                    }
                }
            } header: {
                Text("Variables")
            } footer: {
                Text(
                    session.source?.hasDotEnv == true
                        ? "Values come from the .env file next to the compose file. Type a value to override it for "
                            + "this import; the file is not changed."
                        : "There is no .env file next to the compose file. Type a value to set a variable for this "
                            + "import."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func field(for reference: ComposeInterpolation.Reference) -> some View {
        let binding = Binding(
            get: { session.overrides[reference.name] ?? "" },
            set: { session.setVariable(reference.name, to: $0.isEmpty ? nil : $0) })
        let inherited = session.source?.dotEnv[reference.name] ?? reference.defaultValue ?? ""
        if EnvironmentVariable.isSensitive(key: reference.name) {
            SecureField(reference.name, text: binding, prompt: Text(EnvironmentVariable.maskedValue(inherited)))
                .labelsHidden().frame(maxWidth: 320)
        } else {
            TextField(reference.name, text: binding, prompt: Text(inherited))
                .labelsHidden().font(.monoBody).frame(maxWidth: 320)
        }
    }

    private func isMissing(_ reference: ComposeInterpolation.Reference) -> Bool {
        reference.isRequired && (session.variables[reference.name] ?? "").isEmpty
    }

    private func origin(of reference: ComposeInterpolation.Reference) -> String {
        if session.overrides[reference.name] != nil { return "set here" }
        if session.source?.dotEnv[reference.name] != nil { return "from .env" }
        if reference.isRequired { return "required, no value" }
        if reference.defaultValue != nil { return "default from the file" }
        return "not set: replaced by nothing"
    }
}

/// Everything that will differ from `docker compose up`, grouped by what it is about.
struct ComposeWarningsSection: View {
    let plan: ComposePlan

    private var groups: [(title: String, warnings: [ComposeWarning])] {
        var order: [ComposeWarning.Scope] = []
        for warning in plan.warnings where !order.contains(warning.scope) { order.append(warning.scope) }
        // The file as a whole first, then services, networks and volumes in the order they were found.
        let sorted = order.filter { $0 == .file } + order.filter { $0 != .file }
        return sorted.map { scope in (Self.title(scope), plan.warnings.filter { $0.scope == scope }) }
    }

    private static func title(_ scope: ComposeWarning.Scope) -> String {
        switch scope {
        case .file: return "Whole file"
        case .service(let name): return "Service \(name)"
        case .network(let name): return "Network \(name)"
        case .volume(let name): return "Volume \(name)"
        }
    }

    var body: some View {
        Section {
            if plan.warnings.isEmpty {
                Label("Everything in this file is supported.", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
            ForEach(groups, id: \.title) { group in
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(group.title).font(.callout.weight(.semibold))
                    ForEach(group.warnings) { warning in
                        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                            SwiftUI.Image(
                                systemName: warning.severity == .unsupported
                                    ? "exclamationmark.triangle.fill" : "info.circle"
                            )
                            .foregroundStyle(warning.severity == .unsupported ? Color.statusWarning : Color.secondary)
                            .accessibilityLabel(warning.severity == .unsupported ? "Not supported" : "Note")
                            VStack(alignment: .leading, spacing: 0) {
                                Text(warning.key).font(.monoCaption).foregroundStyle(.secondary)
                                Text(warning.message).font(.callout).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .textSelection(.enabled)
                .padding(.vertical, Spacing.xxs)
            }
        } header: {
            Text(
                plan.warnings.isEmpty
                    ? "Differences from Docker Compose" : "Differences from Docker Compose (\(plan.warnings.count))")
        }
    }
}

/// The exact commands the run will execute, in order, copyable one by one or all together.
struct ComposeCommandsSection: View {
    let plan: ComposePlan

    var body: some View {
        Section {
            ForEach(Array(plan.steps.enumerated()), id: \.element.id) { index, step in
                HStack(alignment: .top, spacing: Spacing.s) {
                    Text("\(index + 1)").font(.monoCaption).foregroundStyle(.tertiary).frame(
                        width: 18, alignment: .trailing)
                    Text(step.commandLine(maskSecrets: true))
                        .font(.monoCaption)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("Step \(index + 1): \(step.title)")
                }
            }
            if plan.steps.isEmpty {
                Text("No commands: fix the problems below first.").foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text("Commands (\(plan.steps.count))")
                Spacer()
                Button("Copy All", systemImage: "doc.on.doc") {
                    if let text = ComposeCopyPrompt.script(for: plan) { copyToPasteboard(text) }
                }
                .controlSize(.small)
                .disabled(plan.steps.isEmpty)
                .help("Copy every command, one per line")
            }
        } footer: {
            Text("Secret-looking environment values are masked here. They are passed unmasked when the project runs.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// "Include secret values?" before the plan's commands go to the clipboard (same wording as the Run sheet).
@MainActor
enum ComposeCopyPrompt {
    /// The text to copy, or `nil` when the user cancelled. Asks only when the plan carries sensitive values.
    static func script(for plan: ComposePlan) -> String? {
        guard plan.containsSecrets else { return plan.script(maskSecrets: false) }
        let alert = NSAlert()
        alert.messageText = "Include secret values?"
        alert.informativeText =
            "These commands set environment variables that look secret (password, token, key). "
            + "Masked copies replace their values with “…”."
        alert.addButton(withTitle: "Copy Masked")
        alert.addButton(withTitle: "Include Secret Values")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        switch alert.runModal() {
        case .alertFirstButtonReturn: return plan.script(maskSecrets: true)
        case .alertSecondButtonReturn: return plan.script(maskSecrets: false)
        default: return nil
        }
    }
}

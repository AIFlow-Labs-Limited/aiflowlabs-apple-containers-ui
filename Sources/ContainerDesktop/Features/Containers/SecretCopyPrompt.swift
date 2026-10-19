import AppKit
import ContainerKit
import AppCore

/// "Include secret values?" before a `container run …` command goes to the clipboard. Masked is the default.
@MainActor
enum SecretCopyPrompt {
    /// The text to copy, or `nil` if the user cancelled. Asks only when the spec carries sensitive values.
    static func runCommand(for spec: RunSpec) -> String? {
        guard EnvironmentVariable.containsSecrets(spec.environment) else { return spec.commandLineString(maskSecrets: false) }
        let alert = NSAlert()
        alert.messageText = "Include secret values?"
        alert.informativeText = "This command sets environment variables that look secret (password, token, key). "
            + "Masked copies replace their values with “…”."
        alert.addButton(withTitle: "Copy Masked")            // default (Return)
        alert.addButton(withTitle: "Include Secret Values")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        switch alert.runModal() {
        case .alertFirstButtonReturn: return spec.commandLineString(maskSecrets: true)
        case .alertSecondButtonReturn: return spec.commandLineString(maskSecrets: false)
        default: return nil
        }
    }
}

import SwiftUI
import ContainerKit
import AppCore
import DesignSystem

/// Log in to a registry. The password is handed to the backend (piped to `--password-stdin`), cleared from
/// this view right after the attempt, and never logged. Backend errors show inline; the sheet stays open.
struct RegistryLoginSheet: View {
    /// Returns `nil` on success, otherwise the error to show.
    let login: (_ server: String, _ username: String, _ password: String, _ scheme: String?) async -> BackendError?

    @State private var preset = RegistryPreset.dockerHub
    @State private var server = RegistryPreset.dockerHub.server ?? ""
    @State private var username = ""
    @State private var password = ""
    @State private var useHTTP = false
    @State private var busy = false
    @State private var error: BackendError?
    @Environment(\.dismiss) private var dismiss

    private var serverError: String? { RegistryServerRule.validate(server) }
    private var canSubmit: Bool { serverError == nil && !username.isEmpty && !password.isEmpty && !busy }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text("Log in to a registry").font(.title2.bold())
            Form {
                Picker("Registry", selection: $preset) {
                    ForEach(RegistryPreset.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: preset) { _, p in
                    server = p.server ?? ""
                    if !p.allowsHTTP { useHTTP = false }
                    error = nil
                }
                TextField("Server", text: $server, prompt: Text("registry.example.com"))
                    .disabled(preset != .custom)
                if preset == .custom, !server.isEmpty { FieldError(message: serverError) }
                TextField("Username", text: $username)
                    .textContentType(.username)
                SecureField(preset == .custom ? "Password or token" : "Access token", text: $password)
                    .textContentType(.password)
                    .onSubmit { if canSubmit { submit() } }
                Label(preset.hint, systemImage: "key").font(.caption).foregroundStyle(.secondary)
                if preset.allowsHTTP {
                    Picker("Scheme", selection: $useHTTP) {
                        Text("HTTPS").tag(false)
                        Text("HTTP (insecure)").tag(true)
                    }
                    .pickerStyle(.segmented)
                    if useHTTP {
                        Text("Only for local registries (for example localhost:5000). Credentials are sent unencrypted.")
                            .font(.caption).foregroundStyle(.statusWarning)
                    }
                }
            }
            .formStyle(.grouped)
            if let error {
                ErrorBanner(error, dismiss: { self.error = nil })
            }
            Text("The password goes straight to the container CLI and is saved in your macOS Keychain. Paste it from your password manager.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if busy { ProgressView().controlSize(.small).accessibilityLabel("Logging in") }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Log In") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 520)
    }

    private func submit() {
        let target = RegistryServerRule.normalize(server)
        let secret = password
        busy = true
        error = nil
        Task {
            let failure = await login(target, username, secret, useHTTP ? "http" : nil)
            password = ""
            busy = false
            if let failure { error = failure } else { dismiss() }
        }
    }
}

#Preview("Registry login") {
    RegistryLoginSheet { _, _, _, _ in .other("unauthorized: incorrect username or password") }
}

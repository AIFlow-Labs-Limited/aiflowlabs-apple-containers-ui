import SwiftUI
import ContainerKit
import AppCore
import DesignSystem

/// Phase-1 registry logins list (features-platform replaces this in phase 2).
struct RegistriesListView: View {
    @Environment(AppModel.self) private var model
    @State private var selection = Set<RegistryLogin.ID>()
    @State private var pendingLogout: [String] = []
    @State private var showLogin = false

    private var store: RegistriesStore { model.registries }

    var body: some View {
        Table(store.filtered, selection: $selection) {
            TableColumn("Server") { r in Text(r.server).fontWeight(.medium) }
                .width(min: 180, ideal: 260)
            TableColumn("Username") { r in Text(r.username ?? emDash) }
                .width(min: 120, ideal: 180)
            TableColumn("Scheme") { r in Text(r.scheme ?? "https").foregroundStyle(.secondary) }
        }
        .contextMenu(forSelectionType: RegistryLogin.ID.self) { ids in
            Button("Log out…", role: .destructive) { pendingLogout = Array(ids) }
        }
        .overlay {
            if store.filtered.isEmpty && !store.isLoading {
                EmptyStateView(symbol: "server.rack", title: "No registry logins",
                               message: "Log in to push images or pull private ones.", actionTitle: "Log in…") { showLogin = true }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                ToolbarActionButton("Log in", systemImage: "person.badge.key") { showLogin = true }
                ToolbarActionButton("Log out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                    pendingLogout = Array(selection)
                }
                .disabled(selection.isEmpty)
            }
        }
        .storeChrome(store)
        .sheet(isPresented: $showLogin) {
            RegistryLoginSheet { server, user, password in
                Task { if await store.login(server: server, username: user, password: password) { model.toasts.success("Logged in to \(server)") } }
            }
        }
        .confirmDestructive(title: "Log out of \(pendingLogout.joined(separator: ", "))?",
                            message: "Removes the stored credentials from the Keychain.",
                            actionTitle: "Log out",
                            isPresented: Binding(get: { !pendingLogout.isEmpty }, set: { if !$0 { pendingLogout = [] } })) {
            let servers = pendingLogout
            Task { await store.logout(servers); selection.subtract(servers) }
        }
    }
}

/// Server + username + password. The password goes to the backend (stdin to the CLI) and is not kept.
private struct RegistryLoginSheet: View {
    let login: (String, String, String) -> Void
    @State private var server = "docker.io"
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        FormSheet(title: "Log in to a registry", actionTitle: "Log in",
                  canSubmit: !server.isEmpty && !username.isEmpty && !password.isEmpty,
                  submit: { login(server, username, password) }) {
            TextField("Server", text: $server)
            TextField("Username", text: $username)
            SecureField("Password or token", text: $password)
            Text(hint).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var hint: String {
        if server.contains("ghcr.io") { return "GHCR: use a personal access token with read:packages / write:packages." }
        if server.contains("docker.io") { return "Docker Hub: use a personal access token (Account settings → Security)." }
        return "Credentials are stored in the macOS Keychain by the container CLI."
    }
}

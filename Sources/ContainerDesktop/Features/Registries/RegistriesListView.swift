import SwiftUI
import ContainerKit
import AppCore
import DesignSystem

/// Registry logins (`container registry ls`): log in / log out / copy server / push an image.
struct RegistriesListView: View {
    /// Deep-link token that opens the login sheet prefilled with `server`:
    /// `navigation.open(.registries, select: RegistriesListView.loginToken(server: "ghcr.io"))`.
    static func loginToken(server: String) -> String { loginPrefix + server }
    private static let loginPrefix = "login:"

    @Environment(AppModel.self) private var model
    @State private var selection = Set<RegistryLogin.ID>()
    @State private var sortOrder = [KeyPathComparator(\RegistryLogin.server)]
    @State private var pendingLogout: [String] = []
    /// Non-nil while the login sheet is shown; `server` prefills it (`nil` = Docker Hub default).
    @State private var login: LoginRequest?
    @State private var deepLink = Set<String>()

    private var store: RegistriesStore { model.registries }
    private var rows: [RegistryLogin] { store.filtered.sorted(using: sortOrder) }

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Server", value: \.server) { r in
                HStack(spacing: Spacing.xs) {
                    Image(systemName: symbol(for: r.server)).foregroundStyle(.secondary).accessibilityHidden(true)
                    Text(r.server).fontWeight(.medium)
                }
                .accessibilityLabel("Registry \(r.server), user \(r.username ?? "unknown")")
            }
            .width(min: 180, ideal: 280)
            TableColumn("Username", value: \.usernameSort) { r in Text(r.username ?? emDash) }
                .width(min: 120, ideal: 200)
            TableColumn("Scheme", value: \.schemeSort) { r in Text(r.schemeSort).foregroundStyle(.secondary) }
                .width(min: 60, ideal: 80)
        }
        .contextMenu(forSelectionType: RegistryLogin.ID.self) { ids in
            if ids.count == 1, let server = ids.first {
                Button("Copy Server") { copyToPasteboard(server) }
                Button("Push an Image…") { model.navigation.open(.images) }
                Divider()
            }
            Button("Log Out…", role: .destructive) { pendingLogout = Array(ids) }
        }
        .overlay { emptyState }
        .toolbar {
            ToolbarItemGroup {
                ToolbarActionButton("Log In", systemImage: "person.badge.key") { login = LoginRequest(server: nil) }
                ToolbarActionButton("Push an Image", systemImage: "arrow.up.circle") { model.navigation.open(.images) }
                    .help("Opens Images — choose an image and Push")
                ToolbarActionButton("Log Out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                    pendingLogout = Array(selection)
                }
                .disabled(selection.isEmpty)
            }
        }
        .storeChrome(store)
        .deepLinkSelection(.registries, navigation: model.navigation, selection: $deepLink) { $0 }
        .onChange(of: deepLink, initial: true) { openDeepLink() }
        .sheet(item: $login) { request in
            RegistryLoginSheet(server: request.server) { server, user, password, scheme in
                let ok = await store.login(server: server, username: user, password: password, scheme: scheme)
                if ok {
                    model.toasts.success("Logged in to \(server)")
                    return nil
                }
                // Show the error in the sheet only, not also as the list banner.
                let error = store.lastError
                store.clearError()
                return error ?? .other("Login to \(server) failed.")
            }
        }
        .confirmDestructive(title: "Log out of \(pendingLogout.joined(separator: ", "))?",
                            message: "Removes the saved credentials for \(pendingLogout.joined(separator: ", ")) from your macOS Keychain. Pushes and private pulls from \(pendingLogout.count == 1 ? "it" : "them") will fail until you log in again.",
                            actionTitle: "Log Out",
                            isPresented: $pendingLogout.isPresent) {
            let servers = pendingLogout
            Task { await store.logout(servers); selection.subtract(servers) }
        }
        #if DEBUG
        .debugHook("registry-login") { login = LoginRequest(server: nil) }
        #endif
    }

    @ViewBuilder
    private var emptyState: some View {
        if store.filtered.isEmpty && !store.isLoading {
            if store.searchText.isEmpty {
                EmptyStateView(symbol: "server.rack", title: "No registry logins",
                               message: "Log in to push your images to Docker Hub, GHCR or a private registry, and to pull private images. Credentials stay in your macOS Keychain.",
                               actionTitle: "Log In…") { login = LoginRequest(server: nil) }
            } else {
                ContentUnavailableView.search(text: store.searchText)
            }
        }
    }

    /// `login:<server>` opens the login sheet for that server; anything else selects that row.
    private func openDeepLink() {
        guard let token = deepLink.first else { return }
        deepLink = []
        if token.hasPrefix(Self.loginPrefix) {
            let server = String(token.dropFirst(Self.loginPrefix.count))
            login = LoginRequest(server: server.isEmpty ? nil : server)
        } else {
            selection = [token]
        }
    }

    private func symbol(for server: String) -> String {
        switch RegistryPreset.matching(server: server) {
        case .dockerHub: return "shippingbox"
        case .ghcr: return "chevron.left.forwardslash.chevron.right"
        case .custom: return "server.rack"
        }
    }
}

/// Identifiable wrapper so `.sheet(item:)` re-creates the login sheet with its prefilled server.
struct LoginRequest: Identifiable {
    let id = UUID()
    let server: String?
}

extension RegistryLogin {
    var usernameSort: String { username ?? "" }
    var schemeSort: String { scheme ?? "https" }
}

#Preview("Registries") {
    RegistriesListView()
        .appModelEnvironment(ResourcePreview.model())
        .frame(width: 900, height: 500)
}

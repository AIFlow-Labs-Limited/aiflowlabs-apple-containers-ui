import AppCore
import DesignSystem
import SwiftUI

// Shared scaffolding for the feature list views (shell-owned so phase-2 feature agents can reuse it).

extension View {
    /// Starts/stops the store's poller with the view's lifetime and shows its `lastError` as a top banner.
    func storeChrome<S: PollingStore>(_ store: S) -> some View {
        modifier(StoreChrome(store: store))
    }

    /// Picks up a deep-link selection (`NavigationModel.open(_:select:)`) for `section`.
    func deepLinkSelection<ID: Hashable>(
        _ section: SidebarSection, navigation: NavigationModel,
        selection: Binding<Set<ID>>, map: @escaping (String) -> ID?
    ) -> some View {
        modifier(DeepLinkSelection(section: section, navigation: navigation, selection: selection, map: map))
    }
}

private struct StoreChrome<S: PollingStore>: ViewModifier {
    let store: S

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                if let error = store.lastError {
                    ErrorBanner(error, retry: { Task { await store.refresh() } }, dismiss: { store.clearError() })
                        .padding(Spacing.s)
                }
            }
            .task { store.startPolling() }
            .onDisappear { store.stopPolling() }
    }
}

private struct DeepLinkSelection<ID: Hashable>: ViewModifier {
    let section: SidebarSection
    let navigation: NavigationModel
    @Binding var selection: Set<ID>
    let map: (String) -> ID?

    func body(content: Content) -> some View {
        content
            .onAppear(perform: consume)
            .onChange(of: navigation.peekSelection(for: section)) { consume() }
    }

    private func consume() {
        guard let raw = navigation.consumeSelection(for: section), let id = map(raw) else { return }
        selection = [id]
    }
}

/// Standard sheet layout: title, form content, Cancel + primary action.
struct FormSheet<Content: View>: View {
    let title: String
    let actionTitle: String
    let canSubmit: Bool
    let submit: () -> Void
    @ViewBuilder let content: () -> Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            Text(title).font(.title2.bold())
            Form { content() }
                .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(actionTitle) {
                    submit(); dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 460)
    }
}

/// Placeholder text for empty cells.
let emDash = "—"

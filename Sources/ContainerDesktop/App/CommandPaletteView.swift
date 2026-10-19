import AppCore
import DesignSystem
import SwiftUI

/// ⌘K sheet: fuzzy search over sections, containers, images, volumes, machines and actions.
struct CommandPaletteView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @FocusState private var focused: Bool
    @State private var highlighted = 0
    /// Asks the presenting window to confirm `container system stop` (the palette closes first).
    var requestEngineStop: () -> Void = {}

    var body: some View {
        @Bindable var palette = model.palette
        let results = palette.results(in: palette.items(for: model))
        VStack(spacing: 0) {
            HStack(spacing: Spacing.s) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Search containers, images, actions…", text: $palette.query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit { execute(results) }
                    .accessibilityLabel("Command palette search")
            }
            .padding(Spacing.m)
            Divider()
            ScrollViewReader { proxy in
                List {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                        PaletteRow(item: item, highlighted: index == highlighted)
                            .id(index)
                            .contentShape(Rectangle())
                            .onTapGesture { run(item) }
                            .listRowBackground(index == highlighted ? Color.accentColor.opacity(0.18) : Color.clear)
                    }
                }
                .listStyle(.plain)
                .onChange(of: highlighted) { proxy.scrollTo(highlighted) }
            }
            .overlay {
                if results.isEmpty {
                    Text("No matches").foregroundStyle(.secondary)
                }
            }
            Divider()
            HStack {
                Text("↑↓ to navigate · ↩ to open · esc to close").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.xs)
        }
        .frame(width: 600, height: 420)
        .onAppear {
            palette.query = ""; highlighted = 0; focused = true
        }
        .onChange(of: palette.query) { highlighted = 0 }
        .onKeyPress(.downArrow) {
            highlighted = min(highlighted + 1, max(0, results.count - 1)); return .handled
        }
        .onKeyPress(.upArrow) {
            highlighted = max(highlighted - 1, 0); return .handled
        }
        .onKeyPress(.escape) {
            dismiss(); return .handled
        }
    }

    private func execute(_ results: [PaletteItem]) {
        guard results.indices.contains(highlighted) else { return }
        run(results[highlighted])
    }

    private func run(_ item: PaletteItem) {
        model.palette.markUsed(item)
        dismiss()
        switch item.action {
        case .navigate(let section, let id): model.navigation.open(section, select: id)
        case .startEngine: Task { await model.startEngine() }
        case .stopEngine: requestEngineStop()
        case .cleanUp: model.navigation.isCleanupOpen = true
        case .openSettings: openSettings()
        case .openActivity: openWindow(id: SceneID.activity)
        case .refresh: Task { if let s = model.navigation.section { await model.refresh(s) } }
        case .toggleTerminal: model.navigation.isTerminalOpen.toggle()
        }
    }
}

private struct PaletteRow: View {
    let item: PaletteItem
    let highlighted: Bool

    var body: some View {
        HStack(spacing: Spacing.m) {
            Image(systemName: item.symbol)
                .frame(width: 20)
                .foregroundStyle(highlighted ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).lineLimit(1)
                Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(highlighted ? .isSelected : [])
    }
}

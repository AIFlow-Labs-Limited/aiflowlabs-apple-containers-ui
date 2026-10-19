import SwiftUI
import AppCore
import DesignSystem

/// Collapsible bottom panel with a login shell (`.shell` target), like Docker Desktop's integrated terminal.
/// Toggle with ⌘T or the toolbar. Drag the top edge to resize.
struct TerminalPanel: View {
    @Environment(AppModel.self) private var model
    @State private var session = UUID()
    @State private var exited: Int32??
    @AppStorage("terminalPanelHeight") private var height: Double = 260
    @State private var dragStart: Double?

    var body: some View {
        VStack(spacing: 0) {
            resizeHandle
            header
            Divider()
            ZStack {
                TerminalView(command: model.backend.terminalCommand(for: .shell)) { code in
                    exited = .some(code)
                }
                .id(session)
                if let code = exited {
                    VStack(spacing: Spacing.s) {
                        Text("Session ended\(code.map { " (exit \($0))" } ?? "")").foregroundStyle(.secondary)
                        Button("New session") { restart() }
                    }
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.medium))
                }
            }
        }
        .frame(height: height)
    }

    private var header: some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: "terminal").foregroundStyle(.secondary).accessibilityHidden(true)
            Text("Terminal").font(.callout.weight(.semibold))
            Text("PATH includes /usr/local/bin (where `container` installs)").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button { restart() } label: { Image(systemName: "plus") }
                .buttonStyle(.borderless)
                .help("New session")
                .accessibilityLabel("New terminal session")
            Button { withAnimation { model.navigation.isTerminalOpen = false } } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless)
                .help("Hide terminal (⌘T)")
                .accessibilityLabel("Hide terminal")
        }
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.xs)
        .background(.bar)
    }

    private var resizeHandle: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: 5)
            .overlay(Divider(), alignment: .top)
            .contentShape(Rectangle())
            .pointerStyle(.rowResize)   // balanced by SwiftUI, unlike NSCursor.push/pop on hover
            .gesture(DragGesture(minimumDistance: 1).onChanged { value in
                let start = dragStart ?? height
                dragStart = start
                height = min(max(start - value.translation.height, 140), 700)
            }.onEnded { _ in dragStart = nil })
            .accessibilityHidden(true)
    }

    private func restart() {
        exited = nil
        session = UUID()
    }
}

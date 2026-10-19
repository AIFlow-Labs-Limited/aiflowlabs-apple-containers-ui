import AppCore
import DesignSystem
import SwiftUI

/// Sidebar in Docker Desktop order with live counts; footer shows engine state + CLI version.
struct Sidebar: View {
    @Environment(AppModel.self) private var model

    private var sections: [SidebarSection] {
        SidebarSection.allCases.filter { $0 != .kubernetes || model.clusters.available }
    }

    var body: some View {
        @Bindable var nav = model.navigation
        List(selection: $nav.section) {
            Section("Resources") {
                ForEach(sections) { section in
                    row(section).tag(section)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
    }

    @ViewBuilder
    private func row(_ section: SidebarSection) -> some View {
        let count = model.engine.isRunning ? model.count(for: section) : 0
        HStack(spacing: Spacing.xs) {
            // The title never gives way to the marker: "Experimental" + the count squeezed it to "Kuberne…".
            Label(section.title, systemImage: section.symbol)
                .lineLimit(1)
                .layoutPriority(1)
            if section == .kubernetes {
                TagBadge("Beta", tint: .statusWarning)
                    .fixedSize()
                    .help("Experimental: Kubernetes support relies on the container k8s plugin preview")
            }
        }
        .badge(count)
        .accessibilityLabel(
            section == .kubernetes
                ? "\(section.title), experimental, \(count) items" : "\(section.title), \(count) items")
    }

    private var footer: some View {
        HStack(spacing: Spacing.s) {
            StatusDot(model.engine.color, size: 9, label: "Engine \(model.engine.label)")
            VStack(alignment: .leading, spacing: 0) {
                Text("Engine \(model.engine.label.lowercased())")
                    .font(.callout.weight(.medium))
                Text(model.engine.version.map { "container \($0)" } ?? model.backend.backendDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.m)
        .help(model.backend.backendDescription)
    }
}

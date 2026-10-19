import SwiftUI
import ContainerKit
import AppCore
import ContainerKitMock
import DesignSystem

// Small views shared by the Machines, Kubernetes and Registries features.

/// Tinted explainer / warning card used in detail panes and sheets.
struct InfoCard<Content: View>: View {
    let title: String
    let symbol: String
    var tint: Color = .accentColor
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Label(title, systemImage: symbol)
                .font(.callout.weight(.semibold))
                .foregroundStyle(tint)
                .accessibilityAddTraits(.isHeader)
            content()
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.m)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: Radius.medium))
        .overlay(RoundedRectangle(cornerRadius: Radius.medium).strokeBorder(tint.opacity(0.25)))
        .accessibilityElement(children: .combine)
    }
}

/// Bulleted line inside an `InfoCard`.
struct Bullet: View {
    let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
            Text("•")
            Text(text)
        }
    }
}

/// The exact command a sheet will run, selectable and copyable.
struct CommandPreview: View {
    let command: String

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.s) {
            Text(command)
                .font(.monoCaption)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            CopyButton(command, label: "Copy command")
        }
        .padding(Spacing.s)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.small))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command preview: \(command)")
    }
}

/// A titled, copyable command row ("List nodes  kubectl --context x get nodes  [copy]").
struct CopyableCommandRow: View {
    let title: String
    let command: String

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(command).font(.monoCaption).textSelection(.enabled).lineLimit(2)
                Spacer(minLength: Spacing.s)
                CopyButton(command, label: "Copy “\(title)”")
            }
        }
    }
}

/// Inline validation message under a form field.
struct FieldError: View {
    let message: String?

    var body: some View {
        if let message {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.statusError)
                .accessibilityLabel("Error: \(message)")
        }
    }
}

/// Header used at the top of the platform list views (title line + optional badge + trailing content).
struct SectionHeaderBar<Trailing: View>: View {
    let subtitle: String
    var badge: String?
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: Spacing.s) {
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
            if let badge { TagBadge(badge, tint: .statusWarning) }
            Spacer()
            trailing()
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.s)
        .background(.bar)
    }
}

extension AppModel {
    /// Fixture-backed model for `#Preview`s of the platform features.
    static func platformPreview() -> AppModel {
        let model = AppModel(backend: MockBackend(), observeAppActivation: false)
        Task { await model.bootstrap(); await model.refreshAll() }
        return model
    }
}

#Preview("Platform components") {
    VStack(alignment: .leading, spacing: Spacing.m) {
        InfoCard(title: "What is a container machine?", symbol: "desktopcomputer") {
            Bullet("Your home folder is mapped at the same path.")
        }
        CommandPreview(command: "container machine create --name dev ghcr.io/linuxcontainers/alpine:3.20")
        CopyableCommandRow(title: "List nodes", command: "kubectl --context k8s-dev get nodes")
        FieldError(message: "Dots aren't allowed in machine names.")
    }
    .padding()
    .frame(width: 420)
}

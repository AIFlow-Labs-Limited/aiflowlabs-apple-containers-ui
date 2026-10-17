import SwiftUI
import ContainerKit

/// A small colored dot for state columns and the status bar.
public struct StatusDot: View {
    let color: Color
    let size: CGFloat
    let label: String?

    public init(_ color: Color, size: CGFloat = 8, label: String? = nil) {
        self.color = color
        self.size = size
        self.label = label
    }

    public var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay(Circle().strokeBorder(.black.opacity(0.08), lineWidth: 0.5))
            .accessibilityElement()
            .accessibilityLabel(label ?? "")
            .accessibilityHidden(label == nil)
    }
}

/// Capsule showing a container state ("● Running").
public struct StateBadge: View {
    let state: ContainerState
    let detail: String?

    public init(_ state: ContainerState, detail: String? = nil) {
        self.state = state
        self.detail = detail
    }

    public var body: some View {
        HStack(spacing: Spacing.xs) {
            StatusDot(state.statusColor, size: 7)
            Text(detail.map { "\(state.displayName) \($0)" } ?? state.displayName)
                .font(.caption)
                .lineLimit(1)
        }
        .padding(.horizontal, Spacing.s)
        .padding(.vertical, Spacing.xxs)
        .background(state.statusColor.opacity(0.12), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

/// `arm64` / `amd64` badge. amd64 runs under Rosetta on Apple silicon, so it is tinted as a warning.
public struct PlatformBadge: View {
    let platform: Platform

    public init(_ platform: Platform) { self.platform = platform }

    private var tint: Color { platform.architecture == "amd64" ? .statusWarning : .accentColor }

    public var body: some View {
        Text(platform.variant.map { "\(platform.architecture)/\($0)" } ?? platform.architecture)
            .font(.caption2.monospaced().weight(.medium))
            .padding(.horizontal, Spacing.xs + 1)
            .padding(.vertical, 1)
            .foregroundStyle(tint)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.small))
            .help(platform.architecture == "amd64" ? "\(platform.slug) — runs under Rosetta" : platform.slug)
    }
}

/// Generic small tag ("default", "Experimental").
public struct TagBadge: View {
    let text: String
    let tint: Color

    public init(_ text: String, tint: Color = .secondary) {
        self.text = text
        self.tint = tint
    }

    public var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, Spacing.xs + 1)
            .padding(.vertical, 1)
            .foregroundStyle(tint)
            .background(tint.opacity(0.14), in: Capsule())
    }
}

#Preview("Badges") {
    VStack(alignment: .leading, spacing: Spacing.s) {
        HStack { StatusDot(.statusRunning); StatusDot(.statusStopped); StatusDot(.statusWarning); StatusDot(.statusError) }
        HStack { ForEach(ContainerState.allCases, id: \.self) { StateBadge($0) } }
        StateBadge(.running, detail: "2h")
        HStack { PlatformBadge(.arm64); PlatformBadge(.amd64); TagBadge("default"); TagBadge("Experimental", tint: .statusWarning) }
    }
    .padding()
}

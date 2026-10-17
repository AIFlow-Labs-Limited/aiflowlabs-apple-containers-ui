import SwiftUI

/// Big-number tile for dashboards (builder card, stats, cleanup sheet).
public struct MetricTile: View {
    public enum Trend: Sendable {
        case up, down, flat

        var symbol: String {
            switch self {
            case .up: return "arrow.up.right"
            case .down: return "arrow.down.right"
            case .flat: return "arrow.right"
            }
        }
    }

    let title: String
    let value: String
    let subtitle: String?
    let trend: Trend?

    public init(title: String, value: String, subtitle: String? = nil, trend: Trend? = nil) {
        self.title = title
        self.value = value
        self.subtitle = subtitle
        self.trend = trend
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                Text(value)
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let trend {
                    Image(systemName: trend.symbol)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.m)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: Radius.medium))
        .accessibilityElement(children: .combine)
    }
}

#Preview("MetricTile") {
    HStack {
        MetricTile(title: "CPU", value: "12.4%", subtitle: "4 cores", trend: .up)
        MetricTile(title: "Memory", value: "1.2 GB", subtitle: "of 8 GB")
        MetricTile(title: "Disk", value: "17 GB", subtitle: "14 GB reclaimable", trend: .down)
    }
    .padding()
    .frame(width: 560)
}

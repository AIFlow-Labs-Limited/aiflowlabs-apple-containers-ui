import SwiftUI
import Charts
import ContainerKit
import ContainerKitMock
import AppCore
import DesignSystem

/// Stats tab: current values as tiles, then CPU / memory / network / block I/O / PIDs charts over the last
/// 5 minutes. Render-only: samples come from `ContainersStore.refreshStats` (the store's gated poller appends
/// them to `ContainersStore.statsHistory`), so there is no second polling loop here.
struct ContainerStatsTab: View {
    let container: Container
    /// `model.containers.statsHistory`.
    let history: ContainerStatsHistory

    private var points: [StatsPoint] { history.points(for: container.id) }
    /// Rates need two samples; drop the priming point from rate charts.
    private var ratePoints: [StatsPoint] { Array(points.dropFirst()) }

    var body: some View {
        if !container.isRunning {
            EmptyStateView(symbol: "chart.xyaxis.line", title: "No live stats",
                           message: "Stats are sampled while the container is running.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    tiles
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: Spacing.l)], spacing: Spacing.l) {
                        chartCard("CPU", subtitle: "% of one core") { cpuChart }
                        chartCard("Memory", subtitle: "used of \(ByteCount.format(points.last?.memoryLimitBytes ?? container.configuration.resources.memoryInBytes)) limit") { memoryChart }
                        chartCard("Network", subtitle: "bytes/s") {
                            rateChart([("Received", \.networkRxPerSecond), ("Sent", \.networkTxPerSecond)])
                        }
                        chartCard("Block I/O", subtitle: "bytes/s") {
                            rateChart([("Read", \.blockReadPerSecond), ("Written", \.blockWritePerSecond)])
                        }
                        chartCard("Processes", subtitle: "PIDs") { pidsChart }
                    }
                }
                .padding(Spacing.l)
            }
        }
    }

    // MARK: Tiles

    private var tiles: some View {
        let p = history.latest(for: container.id)
        let limit = p?.memoryLimitBytes ?? container.configuration.resources.memoryInBytes
        return HStack(spacing: Spacing.m) {
            MetricTile(title: "CPU", value: p.map { Percent.format($0.cpuPercent) } ?? emDash,
                       subtitle: "\(container.configuration.resources.cpus) CPUs allotted")
            MetricTile(title: "Memory", value: p.map { ByteCount.format($0.memoryBytes) } ?? emDash,
                       subtitle: "of \(ByteCount.format(limit))" + (p.map { " · " + Percent.format(Double($0.memoryBytes) / Double(max(1, limit)) * 100, fractionDigits: 0) } ?? ""))
            MetricTile(title: "Network", value: p.map { "↓ \(Self.rate($0.networkRxPerSecond))" } ?? emDash,
                       subtitle: p.map { "↑ \(Self.rate($0.networkTxPerSecond))" })
            MetricTile(title: "Block I/O", value: p.map { "R \(Self.rate($0.blockReadPerSecond))" } ?? emDash,
                       subtitle: p.map { "W \(Self.rate($0.blockWritePerSecond))" })
            MetricTile(title: "PIDs", value: p.map { String($0.processes) } ?? emDash, subtitle: "processes")
        }
    }

    static func rate(_ bytesPerSecond: Double) -> String { bytes(bytesPerSecond) + "/s" }

    /// Like `ByteCount.format` but always numeric ("0 KB", never "Zero KB").
    static func bytes(_ value: Double) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .binary
        f.allowsNonnumericFormatting = false
        return f.string(fromByteCount: Int64(max(0, value)))
    }

    // MARK: Charts

    private func chartCard<C: View>(_ title: String, subtitle: String, @ViewBuilder chart: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            if points.count < 2 {
                ProgressView("Collecting samples…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                chart().frame(height: 150)
            }
        }
        .padding(Spacing.m)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: Radius.medium))
    }

    private var cpuChart: some View {
        Chart(ratePoints) { p in
            LineMark(x: .value("Time", p.date), y: .value("CPU %", p.cpuPercent))
                .interpolationMethod(.monotone)
            AreaMark(x: .value("Time", p.date), y: .value("CPU %", p.cpuPercent))
                .foregroundStyle(.linearGradient(colors: [Color.accentColor.opacity(0.25), .clear], startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.monotone)
        }
        .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { Text("\(v.as(Double.self) ?? 0, specifier: "%.0f")%") } } }
        .chartXAxis { timeAxis }
        .accessibilityLabel("CPU usage chart")
    }

    private var memoryChart: some View {
        Chart {
            ForEach(points) { p in
                AreaMark(x: .value("Time", p.date), y: .value("Used", p.memoryBytes))
                    .foregroundStyle(by: .value("Series", "Used"))
                    .interpolationMethod(.monotone)
            }
            // Only draw the limit when usage is close enough for it to fit without flattening the area.
            if let limit = points.last?.memoryLimitBytes, limit > 0, let peak = points.map(\.memoryBytes).max(),
               Double(peak) > Double(limit) * 0.4 {
                RuleMark(y: .value("Limit", limit))
                    .foregroundStyle(Color.statusWarning)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: .trailing) {
                        Text("limit \(ByteCount.format(limit))").font(.caption2).foregroundStyle(.secondary)
                    }
            }
        }
        .chartForegroundStyleScale(["Used": Color.accentColor.opacity(0.6)])
        .chartLegend(.hidden)
        .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { Text(Self.bytes(v.as(Double.self) ?? 0)) } } }
        .chartXAxis { timeAxis }
        .accessibilityLabel("Memory usage chart")
    }

    private func rateChart(_ series: [(String, KeyPath<StatsPoint, Double>)]) -> some View {
        Chart {
            ForEach(series, id: \.0) { name, key in
                ForEach(ratePoints) { p in
                    LineMark(x: .value("Time", p.date), y: .value("Bytes/s", p[keyPath: key]))
                        .foregroundStyle(by: .value("Series", name))
                        .interpolationMethod(.monotone)
                }
            }
        }
        .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { Text(Self.rate(v.as(Double.self) ?? 0)) } } }
        .chartXAxis { timeAxis }
        .chartLegend(position: .top, alignment: .leading)
        .accessibilityLabel("\(series.map(\.0).joined(separator: " and ")) chart")
    }

    private var pidsChart: some View {
        Chart(points) { p in
            LineMark(x: .value("Time", p.date), y: .value("PIDs", p.processes))
                .interpolationMethod(.stepEnd)
        }
        .chartXAxis { timeAxis }
        .accessibilityLabel("Process count chart")
    }

    private var timeAxis: some AxisContent {
        AxisMarks(values: .automatic(desiredCount: 4)) { _ in
            AxisGridLine()
            AxisValueLabel(format: .dateTime.hour().minute().second())
        }
    }
}

#Preview("Stats") {
    let c = Container(id: "db", configuration: .init(
        id: "db", image: ImageReference(reference: "postgres:16", descriptor: Descriptor(digest: "sha256:ab", mediaType: "x", size: 1)),
        creationDate: .now, initProcess: .init(executable: "postgres")), status: .init(state: .running, startedDate: .now))
    ContainerStatsTab(container: c, history: ContainerStatsHistory())
        .frame(width: 900, height: 600)
}

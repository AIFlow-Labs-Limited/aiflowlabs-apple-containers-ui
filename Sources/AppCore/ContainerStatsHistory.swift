import Foundation
import Observation
import ContainerKit

/// One derived stats sample: rates are per second, computed against the previous raw sample.
public struct StatsPoint: Hashable, Sendable, Identifiable {
    public var date: Date
    /// 100 = one full core.
    public var cpuPercent: Double
    public var memoryBytes: Int64
    public var memoryLimitBytes: Int64
    public var networkRxPerSecond: Double
    public var networkTxPerSecond: Double
    public var blockReadPerSecond: Double
    public var blockWritePerSecond: Double
    public var processes: Int

    public var id: Date { date }

    public init(date: Date, cpuPercent: Double, memoryBytes: Int64, memoryLimitBytes: Int64,
                networkRxPerSecond: Double = 0, networkTxPerSecond: Double = 0,
                blockReadPerSecond: Double = 0, blockWritePerSecond: Double = 0, processes: Int = 0) {
        self.date = date; self.cpuPercent = cpuPercent; self.memoryBytes = memoryBytes
        self.memoryLimitBytes = memoryLimitBytes; self.networkRxPerSecond = networkRxPerSecond
        self.networkTxPerSecond = networkTxPerSecond; self.blockReadPerSecond = blockReadPerSecond
        self.blockWritePerSecond = blockWritePerSecond; self.processes = processes
    }
}

/// Rolling per-container stats history (default 5 minutes) for the Stats charts.
///
/// Raw `ContainerStats` are cumulative counters; `append` turns consecutive samples into rates. The first
/// sample of a container only primes the counters (rates and CPU are 0 until a second sample arrives).
@MainActor
@Observable
public final class ContainerStatsHistory {
    /// How far back points are kept.
    public let window: TimeInterval
    public private(set) var series: [String: [StatsPoint]] = [:]
    @ObservationIgnored private var lastRaw: [String: (date: Date, stats: ContainerStats)] = [:]

    public init(window: TimeInterval = 300) { self.window = window }

    /// Points for `id`, oldest first.
    public func points(for id: String) -> [StatsPoint] { series[id] ?? [] }

    /// Most recent point for `id`.
    public func latest(for id: String) -> StatsPoint? { series[id]?.last }

    /// Adds a raw sample taken at `date`, derives rates from the previous one, and evicts points older than `window`.
    @discardableResult
    public func append(_ stats: ContainerStats, at date: Date = .now) -> StatsPoint {
        let point = Self.derive(previous: lastRaw[stats.id], current: stats, at: date)
        lastRaw[stats.id] = (date, stats)
        var points = series[stats.id] ?? []
        points.append(point)
        let cutoff = date.addingTimeInterval(-window)
        if let firstKept = points.firstIndex(where: { $0.date >= cutoff }), firstKept > 0 {
            points.removeFirst(firstKept)
        }
        series[stats.id] = points
        return point
    }

    /// Forgets a container (deleted, or restarted so counters reset).
    public func reset(_ id: String) {
        series[id] = nil
        lastRaw[id] = nil
    }

    /// Rate math between two raw samples. Counter resets (current < previous) yield 0, never negative rates.
    public nonisolated static func derive(previous: (date: Date, stats: ContainerStats)?, current: ContainerStats,
                                          at date: Date) -> StatsPoint {
        var point = StatsPoint(date: date, cpuPercent: 0, memoryBytes: current.memoryUsageBytes,
                               memoryLimitBytes: current.memoryLimitBytes, processes: current.numProcesses)
        guard let previous else { return point }
        let interval = date.timeIntervalSince(previous.date)
        guard interval > 0 else { return point }
        func rate(_ now: Int64, _ before: Int64) -> Double { max(0, Double(now - before)) / interval }
        point.cpuPercent = ContainerStats.cpuPercent(previous: previous.stats, current: current, interval: interval)
        point.networkRxPerSecond = rate(current.networkRxBytes, previous.stats.networkRxBytes)
        point.networkTxPerSecond = rate(current.networkTxBytes, previous.stats.networkTxBytes)
        point.blockReadPerSecond = rate(current.blockReadBytes, previous.stats.blockReadBytes)
        point.blockWritePerSecond = rate(current.blockWriteBytes, previous.stats.blockWriteBytes)
        return point
    }
}

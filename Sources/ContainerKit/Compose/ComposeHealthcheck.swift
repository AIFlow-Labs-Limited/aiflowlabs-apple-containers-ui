import Foundation

/// `healthcheck:` of a service: the command that says whether the service is ready, and how often to ask.
///
/// The runtime has no health checks, so the app runs `command` inside the container itself (exit code 0 means
/// healthy) while another service waits for this one with `condition: service_healthy`.
public struct ComposeHealthcheck: Hashable, Sendable {
    /// Compose's defaults for the keys a file leaves out.
    public enum Defaults {
        public static let interval: Duration = .seconds(30)
        public static let timeout: Duration = .seconds(30)
        public static let retries = 3
        public static let startPeriod: Duration = .zero
        public static let startInterval: Duration = .seconds(5)
    }

    /// The command to run in the container. `CMD-SHELL` and the string form become `/bin/sh -c <text>`.
    public var command: [String]
    /// Time between two probes once the start period is over.
    public var interval: Duration = Defaults.interval
    /// How long one probe may take before it counts as failed.
    public var timeout: Duration = Defaults.timeout
    /// Consecutive failures (after the start period) that make the container unhealthy.
    public var retries: Int = Defaults.retries
    /// Grace time after the start during which failed probes do not count.
    public var startPeriod: Duration = Defaults.startPeriod
    /// Time between two probes during the start period.
    public var startInterval: Duration = Defaults.startInterval

    /// A check that runs `command` with Compose's default timings.
    public init(command: [String]) { self.command = command }

    /// "every 5s, timeout 3s, 5 retries, start period 10s" — for the preview.
    public var timingSummary: String {
        var parts = [
            "every \(ComposeDuration.format(interval))", "timeout \(ComposeDuration.format(timeout))",
            "\(retries) retr\(retries == 1 ? "y" : "ies")",
        ]
        if startPeriod > .zero { parts.append("start period \(ComposeDuration.format(startPeriod))") }
        return parts.joined(separator: ", ")
    }
}

/// What a service's `healthcheck:` section amounts to.
public enum ComposeHealthcheckSetting: Hashable, Sendable {
    /// A check the app can run.
    case check(ComposeHealthcheck)
    /// `disable: true` or `test: ["NONE"]`: the service explicitly has no health check.
    case disabled
    /// Timings without a `test:`. Docker would use the image's own `HEALTHCHECK`, which this runtime does not read.
    case inheritedFromImage
}

/// Compose's duration syntax: `90s`, `1m30s`, `500ms`, `1h`, `1.5s`; a bare number is seconds.
public enum ComposeDuration {
    private static let units: [(suffix: String, nanoseconds: Double)] = [
        ("ns", 1), ("us", 1e3), ("µs", 1e3), ("ms", 1e6), ("s", 1e9), ("m", 60e9), ("h", 3600e9),
    ]

    /// Parses `text`; `nil` when it is not a duration (or is negative).
    public static func parse(_ text: String) -> Duration? {
        let value = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !value.isEmpty else { return nil }
        if let seconds = Double(value) { return seconds >= 0 ? nanoseconds(seconds * 1e9) : nil }
        var rest = Substring(value)
        var total = 0.0
        while !rest.isEmpty {
            let digits = rest.prefix { ($0.isNumber && $0.isASCII) || $0 == "." }
            guard !digits.isEmpty, let number = Double(digits) else { return nil }
            rest = rest.dropFirst(digits.count)
            // Longest suffix first, so `ms` is not read as `m` followed by `s`.
            guard let unit = units.filter({ rest.hasPrefix($0.suffix) }).max(by: { $0.suffix.count < $1.suffix.count })
            else { return nil }
            rest = rest.dropFirst(unit.suffix.count)
            total += number * unit.nanoseconds
        }
        return nanoseconds(total)
    }

    private static func nanoseconds(_ value: Double) -> Duration? {
        guard value.isFinite, value >= 0, value < 9e18 else { return nil }
        return .nanoseconds(Int64(value.rounded()))
    }

    /// Shortest Compose spelling of `duration`: `1m30s`, `500ms`, `0s`.
    public static func format(_ duration: Duration) -> String {
        let components = duration.components
        var milliseconds = components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000
        guard milliseconds > 0 else { return "0s" }
        var text = ""
        for (suffix, size) in [("h", Int64(3_600_000)), ("m", 60_000), ("s", 1000), ("ms", 1)] {
            let count = milliseconds / size
            if count > 0 { text += "\(count)\(suffix)" }
            milliseconds %= size
        }
        return text
    }
}

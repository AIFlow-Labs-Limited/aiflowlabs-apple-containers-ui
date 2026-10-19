import Foundation

/// Byte formatting shared by every table and the status bar (binary units, like the CLI).
public enum ByteCount {
    /// `1.2 GB`, `512 MB`, `0 bytes`.
    public static func format(_ bytes: Int64, style: ByteCountFormatter.CountStyle = .binary) -> String {
        // ByteCountFormatter spells zero "Zero KB" (status bar: "RAM Zero KB"); keep it numeric like every other value.
        bytes <= 0 ? "0 bytes" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: style)
    }

    public static func format(_ bytes: Int, style: ByteCountFormatter.CountStyle = .binary) -> String {
        format(Int64(bytes), style: style)
    }
}

/// Relative date / uptime formatting.
public enum RelativeDate {
    /// "2 hours ago", "yesterday".
    public static func format(_ date: Date, relativeTo now: Date = .now) -> String {
        if abs(now.timeIntervalSince(date)) < 5 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// Compact duration since `date`: `45s`, `12m`, `2h 5m`, `3d 4h`.
    public static func uptime(since date: Date, now: Date = .now) -> String {
        duration(now.timeIntervalSince(date))
    }

    /// Compact duration: `45s`, `12m`, `2h 5m`, `3d 4h`.
    public static func duration(_ interval: TimeInterval) -> String {
        let s = max(0, Int(interval))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86_400 {
            let m = (s % 3600) / 60
            return m == 0 ? "\(s / 3600)h" : "\(s / 3600)h \(m)m"
        }
        let h = (s % 86_400) / 3600
        return h == 0 ? "\(s / 86_400)d" : "\(s / 86_400)d \(h)h"
    }

    /// Absolute short date-time for tooltips.
    public static func absolute(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

/// Percent formatting (`12.3%`, localized: `12,3 %` in French). `value` is in percent (100 = 100 %).
public enum Percent {
    public static func format(_ value: Double, fractionDigits: Int = 1, locale: Locale = .current) -> String {
        (value / 100).formatted(.percent.precision(.fractionLength(fractionDigits)).locale(locale))
    }
}

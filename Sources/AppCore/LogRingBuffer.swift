import ContainerKit
import Foundation

/// Bounded log line buffer (oldest lines dropped first) with case-insensitive search.
///
/// Trimming happens in chunks so a steady stream does not pay an O(n) `removeFirst` per line.
public struct LogRingBuffer: Sendable, Equatable {
    public let capacity: Int
    private var storage: [OutputLine] = []
    /// Total lines ever appended (including dropped ones); lets views tell "new output" from "trimmed".
    public private(set) var totalAppended = 0
    /// Lines dropped because the buffer was full.
    public var droppedCount: Int { totalAppended - count }

    public init(capacity: Int = 20_000) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    public var count: Int { min(storage.count, capacity) }
    public var isEmpty: Bool { storage.isEmpty }

    public mutating func append(_ line: OutputLine) { append(contentsOf: [line]) }

    public mutating func append(contentsOf newLines: [OutputLine]) {
        guard !newLines.isEmpty else { return }
        totalAppended += newLines.count
        storage.append(contentsOf: newLines)
        // Allow ~5 % slack before trimming back to capacity; readers use `lines`.
        let slack = max(1, capacity / 20)
        if storage.count > capacity + slack { storage.removeFirst(storage.count - capacity) }
    }

    /// Lines in the buffer (oldest first), trimmed to exactly `capacity` (the slack is an implementation detail).
    public var lines: ArraySlice<OutputLine> { storage.suffix(capacity) }

    public mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        totalAppended = 0
    }

    /// Indices (into `lines`, 0-based) of lines containing `query`, case-insensitive.
    public func matches(_ query: String) -> [Int] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return lines.enumerated().compactMap { $0.element.text.localizedCaseInsensitiveContains(q) ? $0.offset : nil }
    }

    /// Plain text of all visible lines, optionally prefixed with a local timestamp.
    public func text(timestamps: Bool = false) -> String {
        lines.map { timestamps ? "\(Self.timestamp($0.timestamp)) \($0.text)" : $0.text }.joined(separator: "\n")
    }

    /// `HH:mm:ss.SSS` in the current time zone.
    public static func timestamp(_ date: Date) -> String {
        date.formatted(
            .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)
                .secondFraction(.fractional(3)))
    }
}

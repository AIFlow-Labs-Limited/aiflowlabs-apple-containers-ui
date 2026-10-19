import SwiftUI
import ContainerKit

/// Fast monospaced log viewer: lazy rows, stderr tinted, auto-scroll while following, built-in search.
///
/// Prefer `init(lines:firstLineNumber:totalAppended:…)` fed from a ring buffer (e.g. `LongRunningTask.buffer`):
/// row ids stay stable while old lines are trimmed and following keys on the total appended count, which keeps
/// growing after the buffer is full. The plain `[OutputLine]` initializer follows on the last line instead.
public struct OutputLogView: View {
    let lines: ArraySlice<OutputLine>
    /// Id of `lines.first` (lines dropped before it so far); keeps row identity stable across trimming.
    let firstLineNumber: Int
    /// Changes whenever output arrives (drives auto-follow).
    let followToken: Int
    let follow: Bool
    let showsSearchField: Bool
    let showsTimestamps: Bool
    let externalFilter: String
    @State private var query: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let bottomID = -1

    /// Ring-buffer form: `firstLineNumber` = lines dropped so far, `totalAppended` = lines ever appended.
    public init(lines: ArraySlice<OutputLine>, firstLineNumber: Int, totalAppended: Int, follow: Bool = true,
                filter: String = "", showsSearchField: Bool = true, showsTimestamps: Bool = false) {
        self.lines = lines
        self.firstLineNumber = firstLineNumber
        self.followToken = totalAppended
        self.follow = follow
        self.externalFilter = filter
        self.showsSearchField = showsSearchField
        self.showsTimestamps = showsTimestamps
        _query = State(initialValue: filter)
    }

    public init(lines: [OutputLine], follow: Bool = true, filter: String = "",
                showsSearchField: Bool = true, showsTimestamps: Bool = false) {
        self.init(lines: lines[...], firstLineNumber: 0, totalAppended: lines.count, follow: follow, filter: filter,
                  showsSearchField: showsSearchField, showsTimestamps: showsTimestamps)
        // A capped array stops growing; the last line still changes, so follow on it too.
        self.followTokenOverride = lines.count &+ (lines.last?.hashValue ?? 0)
    }

    private var followTokenOverride: Int?

    struct Row: Identifiable {
        let id: Int
        let line: OutputLine
    }

    /// Rows after the search filter. Computed once per `body`.
    private func visibleRows() -> [Row] {
        let q = query.trimmingCharacters(in: .whitespaces)
        var rows: [Row] = []
        rows.reserveCapacity(q.isEmpty ? lines.count : 64)
        let base = firstLineNumber - lines.startIndex
        for index in lines.indices {
            let line = lines[index]
            if q.isEmpty || line.text.localizedCaseInsensitiveContains(q) { rows.append(Row(id: base + index, line: line)) }
        }
        return rows
    }

    public var body: some View {
        let rows = visibleRows()
        VStack(spacing: 0) {
            if showsSearchField {
                HStack {
                    SearchField(text: $query, prompt: "Filter output")
                    Text("\(rows.count) / \(lines.count) lines")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .padding(Spacing.s)
                Divider()
            }
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { row in
                            LogRow(line: row.line, showsTimestamp: showsTimestamps)
                        }
                        Color.clear.frame(height: 1).id(Self.bottomID)
                    }
                    .padding(.horizontal, Spacing.s)
                    .padding(.vertical, Spacing.xs)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: followTokenOverride ?? followToken) {
                    guard follow, query.isEmpty else { return }
                    if reduceMotion {
                        proxy.scrollTo(Self.bottomID, anchor: .bottom)
                    } else {
                        withAnimation(.linear(duration: 0.1)) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                    }
                }
                .onAppear { if follow { proxy.scrollTo(Self.bottomID, anchor: .bottom) } }
            }
        }
        .onChange(of: externalFilter) { query = externalFilter }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Output log")
    }
}

private struct LogRow: View {
    let line: OutputLine
    let showsTimestamp: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            if showsTimestamp {
                Text(line.timestamp, format: .dateTime.hour().minute().second())
                    .foregroundStyle(.tertiary)
            }
            Text(line.text.isEmpty ? " " : line.text)
                .foregroundStyle(line.stream == .stderr ? AnyShapeStyle(.statusError) : AnyShapeStyle(.primary))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.monoCaption)
        .textSelection(.enabled)
        .padding(.vertical, 1)
    }
}

#Preview("OutputLogView") {
    OutputLogView(lines: (0..<200).map { i in
        OutputLine(i % 9 == 0 ? "warning: something odd at step \(i)" : "[\(i)/200] Fetching layer sha256:\(i)…",
                   stream: i % 9 == 0 ? .stderr : .stdout)
    }, follow: true, showsTimestamps: true)
    .frame(width: 600, height: 360)
}

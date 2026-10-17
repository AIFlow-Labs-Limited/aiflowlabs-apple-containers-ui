import SwiftUI
import ContainerKit

/// Fast monospaced log viewer: lazy rows, stderr tinted, auto-scroll while following, built-in search.
public struct OutputLogView: View {
    let lines: [OutputLine]
    let follow: Bool
    let showsSearchField: Bool
    let showsTimestamps: Bool
    let externalFilter: String
    @State private var query: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let bottomID = "output-log-bottom"

    public init(lines: [OutputLine], follow: Bool = true, filter: String = "",
                showsSearchField: Bool = true, showsTimestamps: Bool = false) {
        self.lines = lines
        self.follow = follow
        self.externalFilter = filter
        self.showsSearchField = showsSearchField
        self.showsTimestamps = showsTimestamps
        _query = State(initialValue: filter)
    }

    private var visible: [(offset: Int, element: OutputLine)] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let all = Array(lines.enumerated())
        guard !q.isEmpty else { return all }
        return all.filter { $0.element.text.localizedCaseInsensitiveContains(q) }
    }

    public var body: some View {
        VStack(spacing: 0) {
            if showsSearchField {
                HStack {
                    SearchField(text: $query, prompt: "Filter output")
                    Text("\(visible.count) / \(lines.count) lines")
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
                        ForEach(visible, id: \.offset) { row in
                            LogRow(line: row.element, showsTimestamp: showsTimestamps)
                        }
                        Color.clear.frame(height: 1).id(Self.bottomID)
                    }
                    .padding(.horizontal, Spacing.s)
                    .padding(.vertical, Spacing.xs)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: lines.count) {
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

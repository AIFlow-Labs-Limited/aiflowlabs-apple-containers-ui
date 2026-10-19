import SwiftUI
import ContainerKit

public extension JSONValue {
    /// Converts any `Encodable` (e.g. a `Container`) into a `JSONValue` tree. Dates become ISO 8601 strings.
    init<T: Encodable>(encoding value: T) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Pretty-printed, key-sorted JSON text.
    func prettyPrinted() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Short inline rendering for scalars; `{3}` / `[2]` summaries for containers.
    var inlineSummary: String {
        switch self {
        case .string(let s): return "\"\(s)\""
        case .number(let n):
            return n.rounded() == n && abs(n) < 1e15 ? String(Int64(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        case .array(let a): return a.isEmpty ? "[]" : "[\(a.count)]"
        case .object(let o): return o.isEmpty ? "{}" : "{\(o.count)}"
        }
    }

    /// Text to put on the pasteboard for "Copy value": raw string for strings, JSON for everything else.
    var copyText: String {
        switch self {
        case .string(let s): return s
        case .number, .bool, .null: return inlineSummary
        case .array, .object: return prettyPrinted()
        }
    }

    fileprivate var children: [(key: String, value: JSONValue)]? {
        switch self {
        case .object(let o): return o.keys.sorted().map { ($0, o[$0]!) }
        case .array(let a): return a.enumerated().map { ("[\($0.offset)]", $0.element) }
        default: return nil
        }
    }
}

/// Expandable, searchable JSON tree (Inspect tabs). Rows are flattened so huge documents stay lazy.
/// Click a row to expand/collapse; the context menu copies a value or its key path.
public struct JSONTreeView: View {
    let value: JSONValue
    let rootName: String
    @State private var expanded: Set<String>
    @State private var query = ""

    /// - Parameter initiallyExpandedDepth: levels expanded on first appearance (1 = root's children visible).
    public init(_ value: JSONValue, rootName: String = "root", initiallyExpandedDepth: Int = 1) {
        self.value = value
        self.rootName = rootName
        _expanded = State(initialValue: Self.paths(in: value, path: "$", maxDepth: initiallyExpandedDepth))
    }

    struct Row: Identifiable {
        let id: String          // key path, e.g. `$.configuration.mounts[0]`
        let key: String
        let value: JSONValue
        let depth: Int
        let isMatch: Bool
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Spacing.s) {
                SearchField(text: $query, prompt: "Search keys and values")
                if !trimmedQuery.isEmpty {
                    Text("\(rows.count(where: \.isMatch)) matches")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                Button("Expand All") { expanded = Self.paths(in: value, path: "$", maxDepth: .max) }
                Button("Collapse All") { expanded = ["$"] }
            }
            .controlSize(.small)
            .padding(Spacing.s)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in rowView(row) }
                }
                .padding(.vertical, Spacing.xs)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("JSON tree")
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

    private var rows: [Row] {
        var out: [Row] = []
        let q = trimmedQuery
        flatten(key: rootName, value: value, path: "$", depth: 0, query: q, into: &out)
        return out
    }

    /// Appends visible rows. While searching, only subtrees that contain a match are shown (auto-expanded).
    @discardableResult
    private func flatten(key: String, value: JSONValue, path: String, depth: Int, query: String, into out: inout [Row]) -> Bool {
        let selfMatch = !query.isEmpty && (key.localizedCaseInsensitiveContains(query)
            || (value.children == nil && value.inlineSummary.localizedCaseInsensitiveContains(query)))
        if query.isEmpty {
            out.append(Row(id: path, key: key, value: value, depth: depth, isMatch: false))
            guard expanded.contains(path), let children = value.children else { return false }
            for child in children {
                flatten(key: child.key, value: child.value, path: childPath(path, child.key), depth: depth + 1, query: query, into: &out)
            }
            return false
        }
        // Search mode: render into a scratch buffer and keep it only when something below matched.
        var sub: [Row] = []
        var childMatched = false
        for child in value.children ?? [] {
            if flatten(key: child.key, value: child.value, path: childPath(path, child.key), depth: depth + 1, query: query, into: &sub) {
                childMatched = true
            }
        }
        guard selfMatch || childMatched || depth == 0 else { return false }
        out.append(Row(id: path, key: key, value: value, depth: depth, isMatch: selfMatch))
        if childMatched { out.append(contentsOf: sub) }
        return selfMatch || childMatched
    }

    private func childPath(_ parent: String, _ key: String) -> String {
        key.hasPrefix("[") ? parent + key : parent + "." + key
    }

    @ViewBuilder
    private func rowView(_ row: Row) -> some View {
        let isContainer = row.value.children != nil && !(row.value.children?.isEmpty ?? true)
        let isOpen = !trimmedQuery.isEmpty || expanded.contains(row.id)
        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
            SwiftUI.Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .rotationEffect(.degrees(isOpen ? 90 : 0))
                .opacity(isContainer ? 1 : 0)
                .foregroundStyle(.secondary)
                .frame(width: 10)
                .accessibilityHidden(true)
            Text(row.key)
                .foregroundStyle(row.isMatch ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .fontWeight(row.isMatch ? .semibold : .regular)
            Text(":").foregroundStyle(.tertiary)
            Text(row.value.inlineSummary)
                .foregroundStyle(color(for: row.value))
                .lineLimit(isContainer ? 1 : 4)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.monoCaption)
        .padding(.leading, CGFloat(row.depth) * 14 + Spacing.s)
        .padding(.vertical, 2)
        .background(row.isMatch ? Color.accentColor.opacity(0.10) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { if isContainer && trimmedQuery.isEmpty { toggle(row.id) } }
        .contextMenu {
            Button("Copy Value") { copyToPasteboard(row.value.copyText) }
            Button("Copy Key Path") { copyToPasteboard(row.id) }
            if isContainer {
                Divider()
                Button(isOpen ? "Collapse" : "Expand") { toggle(row.id) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.key): \(row.value.inlineSummary)")
        .accessibilityAddTraits(isContainer ? .isButton : [])
        .accessibilityHint(isContainer ? (isOpen ? "Collapses" : "Expands") : "")
    }

    private func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    private func color(for value: JSONValue) -> AnyShapeStyle {
        switch value {
        case .string: return AnyShapeStyle(Color(nsColor: .systemRed).mix(with: .primary, by: 0.25))
        case .number: return AnyShapeStyle(Color(nsColor: .systemBlue))
        case .bool, .null: return AnyShapeStyle(Color(nsColor: .systemPurple))
        case .array, .object: return AnyShapeStyle(.tertiary)
        }
    }

    /// Key paths of container nodes up to `maxDepth` (root = depth 0).
    static func paths(in value: JSONValue, path: String, maxDepth: Int, depth: Int = 0) -> Set<String> {
        guard depth < maxDepth, let children = value.children else { return [] }
        var result: Set<String> = [path]
        for child in children {
            let p = child.key.hasPrefix("[") ? path + child.key : path + "." + child.key
            result.formUnion(paths(in: child.value, path: p, maxDepth: maxDepth, depth: depth + 1))
        }
        return result
    }
}

#Preview("JSONTreeView") {
    let sample: JSONValue = .object([
        "id": .string("web"),
        "configuration": .object([
            "cpus": .number(4), "readOnly": .bool(false), "labels": .object(["app": .string("demo")]),
            "ports": .array([.object(["hostPort": .number(8080), "containerPort": .number(80)])]),
            "dns": .null,
        ]),
    ])
    JSONTreeView(sample, rootName: "container")
        .frame(width: 520, height: 360)
}

import Foundation

/// A parsed fixed-width CLI table (`k8s ls`, `system version`, `system dns ls`, `registry ls`, …).
public struct TextTable: Hashable, Sendable {
    /// Column titles in order, e.g. `["CLUSTER", "NODE", …]`.
    public var headers: [String]
    /// Cell values; every row has exactly `headers.count` cells (missing cells are `""`).
    public var rows: [[String]]

    /// Creates a table.
    public init(headers: [String], rows: [[String]]) {
        self.headers = headers
        self.rows = rows
    }

    /// Rows keyed by header title.
    public var records: [[String: String]] {
        rows.map { Dictionary(zip(headers, $0), uniquingKeysWith: { first, _ in first }) }
    }

    /// All values of one column (empty when the column does not exist).
    public func column(_ header: String) -> [String] {
        guard let index = headers.firstIndex(of: header) else { return [] }
        return rows.map { $0[index] }
    }
}

/// Parses the space-aligned tables the `container` CLI prints when `--format json` is unavailable.
///
/// Column boundaries come from the header line: a column starts where a title starts after two or more
/// spaces. Cells are sliced by those offsets, so values containing single spaces
/// (`Version 26.6.2 (Build 25G83)`, `Application Support`) and empty cells survive. Rows that do not line up
/// fall back to splitting on runs of two or more spaces.
public enum TableParser {
    /// Parses `text`; the first non-blank line is the header.
    public static func parse(_ text: String) -> TextTable {
        let lines = text.split(whereSeparator: \.isNewline).map { LineSplitter.stripANSI(String($0)) }
        guard let headerIndex = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            return TextTable(headers: [], rows: [])
        }
        let header = Array(lines[headerIndex])
        let starts = columnStarts(header)
        let headers = cells(header, starts: starts)
        let rows = lines[(headerIndex + 1)...]
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { row(Array($0), starts: starts, columnCount: headers.count) }
        return TextTable(headers: headers, rows: rows)
    }

    /// Parses a two-column `FIELD VALUE` table (e.g. `system status` without `--format json`) into a dictionary.
    public static func keyValues(_ text: String) -> [String: String] {
        let table = parse(text)
        guard table.headers.count >= 2 else { return [:] }
        return Dictionary(table.rows.map { ($0[0], $0[1]) }, uniquingKeysWith: { first, _ in first })
    }

    /// Offsets where each column title begins.
    static func columnStarts(_ header: [Character]) -> [Int] {
        var starts: [Int] = []
        var spaces = 2  // the first title starts a column even without leading spaces
        for (index, char) in header.enumerated() {
            if char == " " || char == "\t" {
                spaces += 1
            } else {
                if spaces >= 2 { starts.append(index) }
                spaces = 0
            }
        }
        return starts
    }

    private static func cells(_ line: [Character], starts: [Int]) -> [String] {
        starts.enumerated().map { index, start in
            let end = index + 1 < starts.count ? starts[index + 1] : line.count
            guard start < line.count else { return "" }
            return String(line[start..<min(end, line.count)]).trimmingCharacters(in: .whitespaces)
        }
    }

    private static func row(_ line: [Character], starts: [Int], columnCount: Int) -> [String] {
        // Offsets are trustworthy when every boundary falls on a space (or past the end of the line).
        let aligned = starts.dropFirst().allSatisfy { $0 >= line.count || line[$0 - 1] == " " }
        if aligned { return cells(line, starts: starts) }
        var parts = String(line).trimmingCharacters(in: .whitespaces)
            .split(separator: /\s{2,}/).map { String($0) }
        if parts.count > columnCount {
            let overflow = parts[(columnCount - 1)...].joined(separator: "  ")
            parts = Array(parts[..<(columnCount - 1)]) + [overflow]
        }
        return parts + Array(repeating: "", count: max(0, columnCount - parts.count))
    }
}

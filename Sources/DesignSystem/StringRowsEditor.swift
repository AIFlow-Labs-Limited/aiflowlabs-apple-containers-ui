import SwiftUI

/// Editable list of single-line entries (build args, labels, secrets…) with add/remove buttons and per-row
/// validation. `validate` returns `nil` for a valid row or a short problem shown under it.
public struct StringRowsEditor: View {
    @Binding var rows: [String]
    let title: String
    let placeholder: String
    let addTitle: String
    let validate: (String) -> String?
    /// Stable identity per row so focus does not jump to a neighbour when a row above is removed.
    @State private var rowIDs: [UUID] = []

    public init(_ title: String, rows: Binding<[String]>, placeholder: String, addTitle: String = "Add",
                validate: @escaping (String) -> String? = { _ in nil }) {
        self.title = title
        _rows = rows
        self.placeholder = placeholder
        self.addTitle = addTitle
        self.validate = validate
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            ForEach(Array(zip(rows.indices, ids)), id: \.1) { index, _ in
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    HStack(spacing: Spacing.xs) {
                        TextField("\(title) \(index + 1)", text: binding(index), prompt: Text(placeholder))
                            .labelsHidden()
                            .multilineTextAlignment(.leading)
                            .font(.monoCaption)
                            .textFieldStyle(.roundedBorder)
                        Button { remove(index) } label: { Image(systemName: "minus.circle.fill") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Remove")
                            .accessibilityLabel("Remove \(title.lowercased()) \(index + 1)")
                    }
                    if let problem = validate(rows[index]) {
                        Text(problem).font(.caption).foregroundStyle(.statusError)
                    }
                }
            }
            Button { rowIDs = ids + [UUID()]; rows.append("") } label: { Label(addTitle, systemImage: "plus.circle") }
                .buttonStyle(.borderless)
                .accessibilityLabel("\(addTitle) \(title.lowercased())")
        }
        .onAppear { rowIDs = ids }
        .onChange(of: rows.count) { rowIDs = ids }
    }

    /// Whether every non-empty row passes validation.
    nonisolated public static func allValid(_ rows: [String], validate: (String) -> String?) -> Bool {
        rows.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty || validate($0) == nil }
    }

    private func binding(_ index: Int) -> Binding<String> {
        Binding(get: { index < rows.count ? rows[index] : "" },
                set: { if index < rows.count { rows[index] = $0 } })
    }

    /// `rowIDs` padded/trimmed to the current row count (rows can also change from outside).
    private var ids: [UUID] {
        if rowIDs.count == rows.count { return rowIDs }
        return Array(rowIDs.prefix(rows.count)) + (0..<max(0, rows.count - rowIDs.count)).map { _ in UUID() }
    }

    private func remove(_ index: Int) {
        guard index < rows.count else { return }
        var current = ids
        current.remove(at: index)
        rowIDs = current
        rows.remove(at: index)
    }
}

#Preview("StringRowsEditor") {
    @Previewable @State var rows = ["VERSION=1.2", "bad"]
    Form {
        LabeledContent("Build args") {
            StringRowsEditor("Build arg", rows: $rows, placeholder: "KEY=VALUE") { $0.contains("=") ? nil : "Use KEY=VALUE." }
        }
    }
    .formStyle(.grouped)
    .frame(width: 460)
}

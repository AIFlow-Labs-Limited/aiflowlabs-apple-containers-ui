import SwiftUI

/// Editable list of single-line entries (build args, labels, secrets…) with add/remove buttons and per-row
/// validation. `validate` returns `nil` for a valid row or a short problem shown under it.
public struct StringRowsEditor: View {
    @Binding var rows: [String]
    let title: String
    let placeholder: String
    let addTitle: String
    let validate: (String) -> String?

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
            ForEach(rows.indices, id: \.self) { index in
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
            Button { rows.append("") } label: { Label(addTitle, systemImage: "plus.circle") }
                .buttonStyle(.borderless)
                .accessibilityLabel("\(addTitle) \(title.lowercased())")
        }
    }

    /// Whether every non-empty row passes validation.
    nonisolated public static func allValid(_ rows: [String], validate: (String) -> String?) -> Bool {
        rows.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty || validate($0) == nil }
    }

    private func binding(_ index: Int) -> Binding<String> {
        Binding(get: { index < rows.count ? rows[index] : "" },
                set: { if index < rows.count { rows[index] = $0 } })
    }

    private func remove(_ index: Int) {
        guard index < rows.count else { return }
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

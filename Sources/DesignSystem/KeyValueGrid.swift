import SwiftUI

/// Two-column key/value list for inspectors. Clicking a value copies it.
public struct KeyValueGrid: View {
    let pairs: [(String, String)]
    @State private var copiedIndex: Int?

    public init(_ pairs: [(String, String)]) { self.pairs = pairs }

    public var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Spacing.m, verticalSpacing: Spacing.s) {
            ForEach(Array(pairs.enumerated()), id: \.offset) { index, pair in
                GridRow {
                    Text(pair.0)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    Text(copiedIndex == index ? "Copied" : (pair.1.isEmpty ? "—" : pair.1))
                        .font(.callout.monospaced())
                        .foregroundStyle(copiedIndex == index ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                        .lineLimit(3)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { copy(index: index, value: pair.1) }
                        .help("Click to copy")
                        .accessibilityLabel("\(pair.0): \(pair.1)")
                        .accessibilityHint("Copies the value")
                        .accessibilityAddTraits(.isButton)
                }
            }
        }
    }

    private func copy(index: Int, value: String) {
        guard !value.isEmpty else { return }
        copyToPasteboard(value)
        copiedIndex = index
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            if copiedIndex == index { copiedIndex = nil }
        }
    }
}

/// Icon button that copies text and briefly shows a checkmark.
public struct CopyButton: View {
    let text: String
    let label: String
    @State private var copied = false

    public init(_ text: String, label: String = "Copy") {
        self.text = text
        self.label = label
    }

    public var body: some View {
        Button {
            copyToPasteboard(text)
            copied = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.2))
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
    }
}

#Preview("KeyValueGrid") {
    VStack(alignment: .leading) {
        KeyValueGrid([("ID", "web-test"), ("Image", "docker.io/library/python:alpine"), ("IP", "192.168.64.3"), ("Empty", "")])
        HStack { Text("container run …").font(.monoCaption); CopyButton("container run python:alpine") }
    }
    .padding()
    .frame(width: 420)
}

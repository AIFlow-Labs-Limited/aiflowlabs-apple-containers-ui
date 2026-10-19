import SwiftUI

/// Rounded search field for content toolbars and log filters.
public struct SearchField: View {
    @Binding var text: String
    let prompt: String

    public init(text: Binding<String>, prompt: String = "Search") {
        _text = text
        self.prompt = prompt
    }

    public var body: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .accessibilityLabel(prompt)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Clear")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, Spacing.s)
        .padding(.vertical, Spacing.xs)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: Radius.medium))
        .frame(maxWidth: 320)
    }
}

/// Toolbar/icon button with tooltip and VoiceOver label baked in.
public struct ToolbarActionButton: View {
    let title: String
    let systemImage: String
    let role: ButtonRole?
    let action: () -> Void

    public init(_ title: String, systemImage: String, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.role = role
        self.action = action
    }

    public var body: some View {
        Button(role: role, action: action) {
            Label(title, systemImage: systemImage)
        }
        .help(title)
        .accessibilityLabel(title)
    }
}

/// Titled inspector section (uppercase caption header + content).
public struct InspectorSection<Content: View>: View {
    let title: String
    let content: Content

    public init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Spacing.s)
    }
}

public extension View {
    /// Destructive confirmation alert. The message must name exactly what gets removed.
    func confirmDestructive(
        title: String, message: String, actionTitle: String,
        isPresented: Binding<Bool>, action: @escaping () -> Void
    ) -> some View {
        alert(title, isPresented: isPresented) {
            Button(actionTitle, role: .destructive, action: action)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(message)
        }
    }
}

#Preview("Controls") {
    @Previewable @State var text = "web"
    @Previewable @State var confirm = false
    VStack(alignment: .leading) {
        SearchField(text: $text, prompt: "Search containers")
        HStack {
            ToolbarActionButton("Start", systemImage: "play.fill") {}
            ToolbarActionButton("Delete", systemImage: "trash", role: .destructive) { confirm = true }
        }
        InspectorSection("Network") { Text("192.168.64.3") }
    }
    .padding()
    .confirmDestructive(
        title: "Delete web?", message: "Deletes container “web”.", actionTitle: "Delete",
        isPresented: $confirm
    ) {}
}

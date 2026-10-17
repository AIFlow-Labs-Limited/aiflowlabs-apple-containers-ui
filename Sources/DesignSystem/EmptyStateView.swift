import SwiftUI

/// Centered empty state ("No containers yet") with an optional primary action.
public struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String
    let actionTitle: String?
    let action: (() -> Void)?

    public init(symbol: String, title: String, message: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(message)
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
    }
}

#Preview("EmptyStateView") {
    EmptyStateView(symbol: "shippingbox", title: "No containers", message: "Run an image to create your first container.",
                   actionTitle: "Run a container") {}
        .frame(width: 500, height: 320)
}

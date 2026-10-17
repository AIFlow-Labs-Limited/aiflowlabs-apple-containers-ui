import SwiftUI
import AppCore
import DesignSystem

/// Bottom-right transient toasts from `AppModel.toasts` (the ToastCenter model lives in AppCore so stores can post).
struct ToastOverlay: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .trailing, spacing: Spacing.s) {
            ForEach(model.toasts.toasts) { toast in
                ToastView(toast: toast) { model.toasts.dismiss(toast.id) }
                    .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.3), value: model.toasts.toasts)
        .frame(maxWidth: 360, alignment: .trailing)
    }
}

private struct ToastView: View {
    let toast: Toast
    let dismiss: () -> Void

    private var symbol: (String, Color) {
        switch toast.kind {
        case .success: return ("checkmark.circle.fill", .statusRunning)
        case .error: return ("xmark.octagon.fill", .statusError)
        case .info: return ("info.circle.fill", .accentColor)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.s) {
            Image(systemName: symbol.0)
                .foregroundStyle(symbol.1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title).font(.callout.weight(.semibold)).lineLimit(2)
                if let message = toast.message {
                    Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            Spacer(minLength: 0)
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Dismiss")
        }
        .padding(Spacing.m)
        .frame(width: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.large))
        .overlay(RoundedRectangle(cornerRadius: Radius.large).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        .accessibilityElement(children: .combine)
    }
}

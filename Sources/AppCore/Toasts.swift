import Foundation
import Observation

/// A transient bottom-right notification.
public struct Toast: Identifiable, Equatable, Sendable {
    public enum Kind: Sendable { case success, error, info }
    public let id = UUID()
    public var kind: Kind
    public var title: String
    public var message: String?

    public init(_ kind: Kind, _ title: String, message: String? = nil) {
        self.kind = kind
        self.title = title
        self.message = message
    }
}

/// In-app toasts (rendered by the app's `ToastOverlay`). Auto-dismiss after `lifetime`.
@MainActor
@Observable
public final class ToastCenter {
    public private(set) var toasts: [Toast] = []
    public var lifetime: Duration = .seconds(4)
    public var maxVisible = 4

    public init() {}

    public func show(_ toast: Toast) {
        toasts.append(toast)
        if toasts.count > maxVisible { toasts.removeFirst(toasts.count - maxVisible) }
        let id = toast.id
        let lifetime = toast.kind == .error ? lifetime * 2 : lifetime
        Task { [weak self] in
            try? await Task.sleep(for: lifetime)
            self?.dismiss(id)
        }
    }

    public func success(_ title: String, message: String? = nil) { show(Toast(.success, title, message: message)) }
    public func error(_ title: String, message: String? = nil) { show(Toast(.error, title, message: message)) }
    public func info(_ title: String, message: String? = nil) { show(Toast(.info, title, message: message)) }

    public func dismiss(_ id: UUID) { toasts.removeAll { $0.id == id } }
}

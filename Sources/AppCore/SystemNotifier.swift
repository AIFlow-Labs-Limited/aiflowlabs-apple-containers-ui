import Foundation
import UserNotifications

/// Posts macOS notifications for finished tasks / crashes. Permission is requested lazily on first use.
/// No-op when the process has no bundle identifier (`swift run`), where UNUserNotificationCenter would crash.
@MainActor
public final class SystemNotifier {
    private var authorizationRequested = false
    private var authorized = false

    public init() {}

    public static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    public func post(title: String, body: String) async {
        guard Self.isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        if !authorizationRequested {
            authorizationRequested = true
            authorized = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        }
        guard authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await center.add(request)
    }
}

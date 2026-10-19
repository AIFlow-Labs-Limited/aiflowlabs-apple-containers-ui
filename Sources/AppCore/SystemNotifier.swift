import Foundation
import UserNotifications

/// Posts macOS notifications for finished tasks / crashes.
///
/// Permission is requested when the user turns notifications on (`requestAuthorization()`, called from the
/// Settings toggle / first launch), not on the first event; each `post` re-checks `notificationSettings()` so a
/// change in System Settings takes effect immediately. No-op when the process has no bundle identifier
/// (`swift run`), where UNUserNotificationCenter would crash.
@MainActor
public final class SystemNotifier {
    public init() {}

    public static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    /// Asks for permission if the user has not decided yet. Returns whether posting is allowed.
    @discardableResult
    public func requestAuthorization() async -> Bool {
        guard Self.isAvailable else { return false }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        case .authorized, .provisional: return true
        case .denied: return false
        @unknown default: return false
        }
    }

    /// Whether the system currently allows our notifications.
    public func isAuthorized() async -> Bool {
        guard Self.isAvailable else { return false }
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional
    }

    public func post(title: String, body: String) async {
        guard await isAuthorized() else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}

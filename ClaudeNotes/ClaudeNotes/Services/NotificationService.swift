import Foundation
import UserNotifications

/// Handles macOS local notification permissions and delivery.
final class NotificationService {
    static let shared = NotificationService()
    private init() {}

    /// Requests notification authorization once. Safe to call multiple times.
    func requestAuthorization() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// Sends a notification with the given title and body.
    /// Silently no-ops if authorization was denied.
    func send(title: String, body: String, identifier: String = UUID().uuidString) {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.5, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        center.add(request)
    }
}

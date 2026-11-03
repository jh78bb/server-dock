import Foundation
import UserNotifications

/// Use UserNotifications for completed uploads/downloads and similar events.
///
/// Only use from an .app bundle; direct executable launches can make UNUserNotificationCenter
/// crash while locating its bundle delegate, so verify the bundle first and otherwise do nothing.
enum Notifier {
    static var available: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// Request notification permission at startup and install the foreground-delivery delegate.
    static func requestAuthIfNeeded() {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = ForegroundPresenter.shared   // Otherwise the system silently suppresses notifications while the app is foregrounded.
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Post system notifications; the system ignores them without permission.
    static func notify(title: String, body: String) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}

/// Show foreground banners/sounds too, since default suppression can hide completion notices.
private final class ForegroundPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ForegroundPresenter()
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}

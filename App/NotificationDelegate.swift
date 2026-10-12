import UIKit
import UserNotifications

/// Native notification routing for both iOS and Mac Catalyst. Scheduling lives
/// in LocalNotificationScheduler; this delegate never requests permission.
final class NotificationAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static let pendingTaskKey = "LocalChecklist.pendingNotificationTaskID"
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        guard let raw = response.notification.request.content.userInfo["taskID"] as? String, UUID(uuidString: raw) != nil else { completionHandler(); return }
        DispatchQueue.main.async {
            UserDefaults.standard.set(raw, forKey: Self.pendingTaskKey)
            NotificationCenter.default.post(name: .checklistOpenNotification, object: nil)
            completionHandler()
        }
    }
}

extension Notification.Name {
    static let checklistOpenNotification = Notification.Name("LocalChecklist.openNotification")
}

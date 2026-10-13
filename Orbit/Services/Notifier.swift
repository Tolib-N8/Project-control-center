import Foundation
import UserNotifications

/// macOS notifications for signals and the morning brief.
enum Notifier {
    /// Snapshot runs and unit tests work on made-up data: nothing from them may reach Notification Center.
    static var enabled: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return false }
        if ProcessInfo.processInfo.arguments.contains("--snapshot") { return false }
        #endif
        return true
    }

    static func requestAuthorization() {
        guard enabled else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    static func post(title: String, body: String, id: String = UUID().uuidString) {
        guard enabled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

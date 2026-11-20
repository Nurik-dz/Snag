import AppKit
import UserNotifications

/// "Downloaded" notifications with Open and Show in Finder (from Swarm).
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    private var center: UNUserNotificationCenter { UNUserNotificationCenter.current() }

    func setUp() {
        guard Bundle.main.bundleIdentifier != nil else { return }   // command-line test runs
        center.delegate = self
        let open = UNNotificationAction(identifier: "open", title: "Open")
        let show = UNNotificationAction(identifier: "show", title: "Show in Finder")
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "done", actions: [open, show], intentIdentifiers: []),
        ])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(title: String, body: String, file: URL?) {
        guard Prefs.notify, Bundle.main.bundleIdentifier != nil else { return }
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        c.categoryIdentifier = "done"
        if let file { c.userInfo = ["path": file.path] }
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        // Only when Snag is not in front: the row already says it.
        await MainActor.run { NSApp.isActive } ? [] : [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let path = response.notification.request.content.userInfo["path"] as? String
        let action = response.actionIdentifier
        await MainActor.run {
            guard let path else { NSApp.activate(); return }
            let url = URL(fileURLWithPath: path)
            if action == "open" { NSWorkspace.shared.open(url) }
            else { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }
}

import Foundation
import UserNotifications

final class NotificationManager {
    static let shared = NotificationManager()

    private init() {}

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error {
                print("Notification auth error: \(error.localizedDescription)")
            }
        }
    }

    /// Checks if this visit triggers a milestone notification.
    /// A milestone fires when the place's qualified-stay count hits one of the configured thresholds.
    func checkMilestone(for place: Place, settings: AppSettings = .shared) {
        let count = place.qualifiedStayCount(minMinutes: settings.minStayMinutes)

        guard settings.milestoneVisitCounts.contains(count) else { return }

        let content = UNMutableNotificationContent()
        content.title = "Milestone Reached!"
        content.body = "You've visited \(place.name) \(count) times."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "milestone-\(place.id)-\(count)",
            content: content,
            trigger: nil // deliver immediately
        )

        UNUserNotificationCenter.current().add(request)
    }
}

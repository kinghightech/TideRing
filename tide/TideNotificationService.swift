import Foundation
import UserNotifications

private final class TideNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

/// Local, non-AI notifications driven entirely by Tide's persisted ring data.
@MainActor
final class TideNotificationService {
    static let shared = TideNotificationService()

    private enum Key {
        static let lowBatteryLatched = "tide.notifications.lowBatteryLatched"
        static let stepGoalDate = "tide.notifications.stepGoalDate"
        static let calorieGoalDate = "tide.notifications.calorieGoalDate"
    }

    private enum Identifier {
        static let lowBattery = "tide.ring.low-battery"
    }

    private let center: UNUserNotificationCenter
    private let defaults: UserDefaults
    private let notificationDelegate = TideNotificationDelegate()
    private var calendar: Calendar

    init(
        center: UNUserNotificationCenter = .current(),
        defaults: UserDefaults = .standard,
        calendar: Calendar = .current
    ) {
        self.center = center
        self.defaults = defaults
        self.calendar = calendar
        center.delegate = notificationDelegate
    }

    func requestAuthorization() async {
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    func evaluateBattery(_ percent: Int) {
        guard (1...100).contains(percent) else { return }

        if percent >= 25 {
            defaults.set(false, forKey: Key.lowBatteryLatched)
            return
        }

        guard percent < 20, !defaults.bool(forKey: Key.lowBatteryLatched) else { return }
        defaults.set(true, forKey: Key.lowBatteryLatched)
        deliver(
            identifier: Identifier.lowBattery,
            title: "Tide ring battery low",
            body: "Your Tide ring is under 20%."
        )
    }

    func evaluateActivity(_ activity: ActivityRecord, settings: RingSettings, now: Date = Date()) {
        guard calendar.isDate(activity.timestamp, inSameDayAs: now) else { return }
        let dateKey = self.dateKey(for: now)

        if settings.stepGoal > 0,
           activity.steps >= settings.stepGoal,
           defaults.string(forKey: Key.stepGoalDate) != dateKey {
            defaults.set(dateKey, forKey: Key.stepGoalDate)
            deliver(
                identifier: "tide.goal.steps.\(dateKey)",
                title: "Step goal complete",
                body: "You hit your \(settings.stepGoal.formatted()) step goal today!"
            )
        }

        if settings.calorieGoal > 0,
           activity.calories >= Double(settings.calorieGoal),
           defaults.string(forKey: Key.calorieGoalDate) != dateKey {
            defaults.set(dateKey, forKey: Key.calorieGoalDate)
            deliver(
                identifier: "tide.goal.calories.\(dateKey)",
                title: "Calorie goal complete",
                body: "You hit your \(settings.calorieGoal) calorie goal today!"
            )
        }
    }

    private func dateKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func deliver(identifier: String, title: String, body: String) {
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content(title: title, body: body),
            trigger: nil
        )
        Task { try? await center.add(request) }
    }

    private func content(title: String, body: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        return content
    }
}

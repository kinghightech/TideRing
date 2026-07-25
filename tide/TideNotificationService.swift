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
        static let sleepGoalDate = "tide.notifications.sleepGoalDate"
        static let morningSummaryDate = "tide.notifications.morningSummaryDate"
    }

    private enum Identifier {
        static let lowBattery = "tide.ring.low-battery"
        static let morningSleep = "tide.sleep.morning-summary"
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

    func evaluateSleep(_ night: SleepNight?, settings: RingSettings, now: Date = Date()) {
        guard let night, isRecentCompletedNight(night, relativeTo: now) else { return }
        let sleepDateKey = dateKey(for: night.end)
        let hours = Double(night.asleepMinutes) / 60

        if settings.sleepGoalHours > 0,
           hours >= settings.sleepGoalHours,
           defaults.string(forKey: Key.sleepGoalDate) != sleepDateKey {
            defaults.set(sleepDateKey, forKey: Key.sleepGoalDate)
            deliver(
                identifier: "tide.goal.sleep.\(sleepDateKey)",
                title: "Sleep goal complete",
                body: "You hit your \(formatDuration(night.asleepMinutes)) sleep goal!"
            )
        }

        refreshMorningSleepSummary(using: night, now: now)
    }

    /// Schedule today's 9:30 AM summary once the just-completed night's sleep is available. If the
    /// ring does not sync until after 9:30, deliver it when that morning sync completes rather than
    /// scheduling yesterday's duration for the following day.
    func refreshMorningSleepSummary(store: RingStore, settings: RingSettings, now: Date = Date()) {
        evaluateSleep(store.latestNight, settings: settings, now: now)
    }

    private func refreshMorningSleepSummary(using night: SleepNight, now: Date) {
        let startOfToday = calendar.startOfDay(for: now)
        guard let nineThirty = calendar.date(bySettingHour: 9, minute: 30, second: 0, of: startOfToday) else { return }
        let todayKey = dateKey(for: now)
        let body = morningBody(minutes: night.asleepMinutes)

        // The fixed identifier lets later sleep packets replace the pending summary with the final total.
        if now < nineThirty {
            var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: nineThirty)
            components.timeZone = calendar.timeZone
            let content = content(title: "Your Tide sleep summary", body: body)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let request = UNNotificationRequest(identifier: Identifier.morningSleep, content: content, trigger: trigger)
            Task {
                do {
                    try await center.add(request)
                    defaults.set(todayKey, forKey: Key.morningSummaryDate)
                } catch {}
            }
            return
        }

        // A late morning sync should still produce today's summary, but never send it again.
        guard defaults.string(forKey: Key.morningSummaryDate) != todayKey,
              now < nineThirty.addingTimeInterval(6 * 3600) else { return }
        defaults.set(todayKey, forKey: Key.morningSummaryDate)
        deliver(identifier: Identifier.morningSleep, title: "Your Tide sleep summary", body: body)
    }

    private func morningBody(minutes: Int) -> String {
        let duration = formatDuration(minutes)
        let hours = Double(minutes) / 60
        if hours >= 7 {
            return "Good job—you got \(duration) of sleep. Keep it up!"
        }
        if hours >= 5 {
            return "Your sleep was okay. You only got \(duration)."
        }
        return "You got \(duration) of sleep. Your sleep was not good last night. Please try sleeping on time tonight."
    }

    private func formatDuration(_ minutes: Int) -> String {
        let hours = minutes / 60
        let remainder = minutes % 60
        if remainder == 0 { return hours == 1 ? "1 hour" : "\(hours) hours" }
        return "\(hours)h \(remainder)m"
    }

    private func isRecentCompletedNight(_ night: SleepNight, relativeTo now: Date) -> Bool {
        guard night.asleepMinutes > 0, night.end <= now.addingTimeInterval(15 * 60) else { return false }
        return night.end >= calendar.startOfDay(for: now).addingTimeInterval(-12 * 3600)
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

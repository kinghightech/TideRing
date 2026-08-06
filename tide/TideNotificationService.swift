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
        /// Minutes reported by the summary already sent today, so a later and fuller sync can
        /// correct an under-reported night instead of being silently suppressed.
        static let morningSummaryMinutes = "tide.notifications.morningSummaryMinutes"
    }

    private enum Identifier {
        static let lowBattery = "tide.ring.low-battery"
        static let morningSleep = "tide.sleep.morning-summary"
    }

    /// When the daily sleep summary goes out. Late enough to be a buffer: sleeping in past this is
    /// what makes the summary fire mid-sleep and report a short night.
    private static let summaryHour = 11
    private static let summaryMinute = 0
    /// How long after the send time a late first sync can still produce today's summary (→ 5 PM).
    /// Past that, the night is stale enough that a "your sleep summary" alert is just noise.
    private static let lateDeliveryWindow: TimeInterval = 6 * 3600

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

    /// Only call this once a night's history has finished syncing. A partially-synced night reports
    /// whatever has arrived so far, and the summary below is send-once per day.
    func evaluateSleep(_ night: SleepNight?, settings: RingSettings, now: Date = Date()) {
        guard let night, isRecentCompletedNight(night, relativeTo: now) else { return }
        let sleepDateKey = dateKey(for: night.end)
        let hours = Double(night.timeInBedMinutes) / 60

        if settings.sleepGoalHours > 0,
           hours >= settings.sleepGoalHours,
           defaults.string(forKey: Key.sleepGoalDate) != sleepDateKey {
            defaults.set(sleepDateKey, forKey: Key.sleepGoalDate)
            deliver(
                identifier: "tide.goal.sleep.\(sleepDateKey)",
                title: "Sleep goal complete",
                body: "You hit your \(formatGoal(settings.sleepGoalHours)) sleep goal — \(formatDuration(night.timeInBedMinutes)) in bed."
            )
        }

        refreshMorningSleepSummary(using: night, now: now)
    }

    /// Schedule today's morning summary once the just-completed night's sleep is available. If the
    /// ring does not sync until after the send time, deliver it when that morning sync completes
    /// rather than scheduling yesterday's duration for the following day.
    func refreshMorningSleepSummary(store: RingStore, settings: RingSettings, now: Date = Date()) {
        // `lastNight(forToday:)`, not `latestNight`: the latter is whichever session is newest, so a
        // completed afternoon nap would be summarised as "last night's sleep". This one is keyed to
        // the previous local day and must already have ended.
        evaluateSleep(store.lastNight(forToday: now), settings: settings, now: now)
    }

    private func refreshMorningSleepSummary(using night: SleepNight, now: Date) {
        let startOfToday = calendar.startOfDay(for: now)
        guard let sendTime = calendar.date(
            bySettingHour: Self.summaryHour, minute: Self.summaryMinute, second: 0, of: startOfToday
        ) else { return }
        let todayKey = dateKey(for: now)
        let body = morningBody(minutes: night.timeInBedMinutes)

        // The fixed identifier lets a later, fuller sync replace the pending summary with the final total.
        if now < sendTime {
            var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: sendTime)
            components.timeZone = calendar.timeZone
            let content = content(title: "Your Tide sleep summary", body: body)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let request = UNNotificationRequest(identifier: Identifier.morningSleep, content: content, trigger: trigger)
            Task {
                do {
                    try await center.add(request)
                    defaults.set(todayKey, forKey: Key.morningSummaryDate)
                    defaults.set(night.timeInBedMinutes, forKey: Key.morningSummaryMinutes)
                } catch {}
            }
            return
        }

        // A late morning sync should still produce today's summary. Normally it is sent once, but a
        // later sync that recovers a materially longer night replaces it (the identifier is fixed,
        // so this updates the existing notification rather than stacking a second one). Without
        // this, one under-reported sync would be the last word for the whole day.
        guard now < sendTime.addingTimeInterval(Self.lateDeliveryWindow) else { return }
        let alreadySentToday = defaults.string(forKey: Key.morningSummaryDate) == todayKey
        let sentMinutes = defaults.integer(forKey: Key.morningSummaryMinutes)
        if alreadySentToday, night.timeInBedMinutes <= sentMinutes + 15 { return }

        defaults.set(todayKey, forKey: Key.morningSummaryDate)
        defaults.set(night.timeInBedMinutes, forKey: Key.morningSummaryMinutes)
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

    private func formatGoal(_ hours: Double) -> String {
        formatDuration(Int((hours * 60).rounded()))
    }

    private func isRecentCompletedNight(_ night: SleepNight, relativeTo now: Date) -> Bool {
        guard night.timeInBedMinutes > 0, night.end <= now.addingTimeInterval(15 * 60) else { return false }
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

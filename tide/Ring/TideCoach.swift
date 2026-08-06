//
//  TideCoach.swift
//  Tide
//
//  An on-device health assistant built on Apple's Foundation Models framework. Everything here
//  runs locally on the phone: the model ships with the OS, the prompt is assembled from RingStore,
//  and nothing leaves the device. That matches Tide's existing "no backend, no network" stance —
//  the app gains a coach without gaining a server.
//
//  This is a wellness feature, not a medical one. The instructions in `systemInstructions` are the
//  guardrail: no diagnosis, no medication advice, and escalate anything alarming to a real doctor.
//

import Combine
import Foundation
import FoundationModels

// MARK: - Health snapshot

/// Renders the user's recent ring data as compact plain text for the model's instructions.
///
/// Two things matter here. First, the on-device model has a small context window, so this is
/// summary statistics rather than raw series. Second, every figure that has a goal is stated *as a
/// percentage of that goal* — a model handed a bare "3820 steps" will cheerfully call it good,
/// whereas "38% of the 10000 goal" leaves it nowhere to hide.
enum TideHealthContext {

    static func snapshot(store: RingStore, settings: RingSettings, now: Date = Date()) -> String {
        var lines: [String] = []

        lines.append("PROFILE")
        lines.append("- \(settings.age) years old, \(settings.isMale ? "male" : "female"), \(settings.heightCm) cm, \(settings.weightKg) kg")
        lines.append("- Daily goals: \(settings.stepGoal) steps, \(settings.calorieGoal) active calories, \(Fmt.number(settings.sleepGoalHours)) hours sleep")

        if let readiness = store.readinessSnapshot(forToday: now), let score = readiness.score {
            lines.append("")
            lines.append("TODAY'S READINESS: \(score)/100 (blend of last night's sleep and yesterday's activity)")
        }

        lines.append("")
        lines.append("SLEEP")
        if let night = store.lastNight(forToday: now) {
            let result = SleepScore.calculate(night)
            let hours = Double(night.timeInBedMinutes) / 60
            lines.append("- Last night: \(Fmt.duration(minutes: night.timeInBedMinutes)) in bed, \(night.start.formatted(date: .omitted, time: .shortened)) to \(night.end.formatted(date: .omitted, time: .shortened))")
            lines.append("- That is \(percent(hours, of: settings.sleepGoalHours)) of their \(Fmt.number(settings.sleepGoalHours))-hour sleep goal")
            lines.append("- Deep \(Fmt.duration(minutes: night.deepMinutes)), light \(Fmt.duration(minutes: night.lightMinutes))")
            lines.append("- Awake \(Fmt.duration(minutes: night.awakeMinutes))")
            lines.append("- Sleep quality score: \(result.score)/100 (\(result.label.rawValue))")
        } else {
            lines.append("- No sleep recorded for last night")
        }
        let recentNights = store.sleepNights.filter { $0.id >= now.addingTimeInterval(-7 * 24 * 3600) }
        if recentNights.count >= 2 {
            let average = recentNights.reduce(0) { $0 + $1.timeInBedMinutes } / recentNights.count
            lines.append("- Last 7 days: \(Fmt.duration(minutes: average)) average across \(recentNights.count) nights, \(percent(Double(average) / 60, of: settings.sleepGoalHours)) of goal")
        }

        lines.append("")
        lines.append("HEART RATE")
        if let latest = store.latestHeartRate {
            lines.append("- Latest: \(Fmt.number(latest.value)) bpm at \(latest.date.formatted(date: .omitted, time: .shortened))")
        }
        let todayHR = store.samples(store.heartRate, onDay: now).map(\.value)
        if !todayHR.isEmpty {
            let average = todayHR.reduce(0, +) / Double(todayHR.count)
            lines.append("- Today: average \(Fmt.number(average)), low \(Fmt.number(todayHR.min() ?? 0)), high \(Fmt.number(todayHR.max() ?? 0)) over \(todayHR.count) readings")
        }
        let weekHR = store.dayStats(store.heartRate, days: 7, now: now).filter { $0.count > 0 }
        if weekHR.count >= 2 {
            let average = weekHR.reduce(0.0) { $0 + $1.avg } / Double(weekHR.count)
            let lowest = weekHR.map(\.min).min() ?? 0
            lines.append("- Last 7 days: average \(Fmt.number(average)) bpm, lowest reading \(Fmt.number(lowest)) bpm")
        }
        if todayHR.isEmpty, store.latestHeartRate == nil {
            lines.append("- No heart-rate readings yet")
        }

        lines.append("")
        lines.append("ACTIVITY")
        if let today = store.todayActivityRecord(now: now) {
            lines.append("- Today: \(today.steps) steps — \(percent(Double(today.steps), of: Double(settings.stepGoal))) of the \(settings.stepGoal) goal")
            lines.append("- Today: \(Fmt.number(today.calories)) active calories — \(percent(today.calories, of: Double(settings.calorieGoal))) of the \(settings.calorieGoal) goal")
            lines.append("- Today: \(Fmt.number(today.distanceMeters / 1000)) km")
        } else {
            lines.append("- No activity recorded today")
        }
        let stepWeek = store.stepDays(7, now: now).filter { $0.count > 0 }
        if stepWeek.count >= 2 {
            let average = stepWeek.reduce(0.0) { $0 + $1.last } / Double(stepWeek.count)
            lines.append("- Last 7 days: \(Int(average)) steps per day on average — \(percent(average, of: Double(settings.stepGoal))) of goal")
        }

        var other: [String] = []
        if let spo2 = store.latestSpO2 {
            other.append("blood oxygen \(Fmt.number(spo2.value))% (\(Fmt.relativeDay(spo2.date)))")
        }
        if let bp = store.latestBloodPressure {
            other.append("blood pressure \(bp.systolic)/\(bp.diastolic) (\(Fmt.relativeDay(bp.date)))")
        }
        if let hrv = store.latestExtra(.hrv) {
            other.append("HRV \(Fmt.number(hrv.value)) ms")
        }
        if let stress = store.latestExtra(.stress) {
            other.append("stress index \(Fmt.number(stress.value))")
        }
        if !other.isEmpty {
            lines.append("")
            lines.append("OTHER READINGS")
            lines.append("- " + other.joined(separator: ", "))
        }

        lines.append("")
        lines.append("WHAT THIS RING CANNOT MEASURE")
        lines.append("- No REM sleep detection at all. Never mention REM.")
        lines.append("- Awake time during the night is often not reported; absence is not evidence they slept straight through.")
        lines.append("- Blood pressure and blood oxygen are estimates from an unregulated consumer device.")

        return lines.joined(separator: "\n")
    }

    private static func percent(_ actual: Double, of goal: Double) -> String {
        guard goal > 0 else { return "an unknown share" }
        return "\(Int((actual / goal * 100).rounded()))%"
    }
}

// MARK: - Conversation model

struct TideCoachMessage: Identifiable, Codable, Equatable {
    enum Role: String, Codable { case user, assistant }

    var id = UUID()
    let role: Role
    var text: String
    var isStreaming = false

    private enum CodingKeys: String, CodingKey { case id, role, text }
}

struct TideCoachConversation: Identifiable, Codable, Equatable {
    var id = UUID()
    var messages: [TideCoachMessage] = []
    var createdAt = Date()
    var updatedAt = Date()

    /// First thing the user asked, trimmed — used as the row title in the saved-chats list.
    var title: String {
        guard let first = messages.first(where: { $0.role == .user })?.text else { return "New chat" }
        let cleaned = first.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.count <= 42 ? cleaned : String(cleaned.prefix(42)) + "…"
    }

    var isEmpty: Bool { messages.isEmpty }
}

// MARK: - Engine

@MainActor
final class TideCoach: ObservableObject {

    @Published private(set) var conversations: [TideCoachConversation] = []
    @Published private(set) var activeID: UUID?
    @Published private(set) var isResponding = false
    @Published private(set) var errorMessage: String?

    private let model = SystemLanguageModel.default
    private var session: LanguageModelSession?
    /// Which conversation `session` belongs to, so switching chats rebuilds it.
    private var sessionConversationID: UUID?
    private let fileURL: URL

    var availability: SystemLanguageModel.Availability { model.availability }
    var isAvailable: Bool { model.isAvailable }

    var activeConversation: TideCoachConversation? {
        guard let activeID else { return nil }
        return conversations.first { $0.id == activeID }
    }

    var messages: [TideCoachMessage] { activeConversation?.messages ?? [] }

    /// Saved chats worth showing in the history list — an untouched new chat isn't one.
    var savedConversations: [TideCoachConversation] {
        conversations.filter { !$0.isEmpty }.sorted { $0.updatedAt > $1.updatedAt }
    }

    static let starters = [
        "How did I sleep last night?",
        "How can I sleep better?",
        "What does my heart rate say about me?",
        "Am I moving enough this week?"
    ]

    init(filename: String = "tide-coach-chats.json") {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        fileURL = base.appendingPathComponent(filename)
        load()
    }

    var unavailableReason: String? {
        switch availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return "This iPhone doesn't support Apple Intelligence, which Tide Coach runs on."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence in Settings to use Tide Coach."
        case .unavailable(.modelNotReady):
            return "Apple Intelligence is still downloading its model. Try again shortly."
        case .unavailable:
            return "Tide Coach isn't available on this device right now."
        }
    }

    // MARK: Conversation management

    func startNewConversation() {
        guard !isResponding else { return }
        // Don't stack up blank chats if the button is tapped twice.
        if let active = activeConversation, active.isEmpty { return }
        let conversation = TideCoachConversation()
        conversations.append(conversation)
        activeID = conversation.id
        session = nil
        sessionConversationID = nil
        errorMessage = nil
        pruneEmpties()
        save()
    }

    func select(_ id: UUID) {
        guard !isResponding, conversations.contains(where: { $0.id == id }) else { return }
        activeID = id
        session = nil
        sessionConversationID = nil
        errorMessage = nil
        pruneEmpties()
        save()
    }

    func delete(_ id: UUID) {
        guard !isResponding else { return }
        conversations.removeAll { $0.id == id }
        if activeID == id {
            activeID = nil
            session = nil
            sessionConversationID = nil
        }
        save()
    }

    func deleteAll() {
        guard !isResponding else { return }
        conversations = []
        activeID = nil
        session = nil
        sessionConversationID = nil
        errorMessage = nil
        save()
    }

    /// Drop blank chats other than the active one, so the history list stays clean.
    private func pruneEmpties() {
        conversations.removeAll { $0.isEmpty && $0.id != activeID }
    }

    // MARK: Asking

    func send(_ text: String, store: RingStore, settings: RingSettings) async {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isResponding, isAvailable else { return }

        if activeConversation == nil {
            let conversation = TideCoachConversation()
            conversations.append(conversation)
            activeID = conversation.id
        }
        guard let index = conversations.firstIndex(where: { $0.id == activeID }) else { return }

        errorMessage = nil
        conversations[index].messages.append(TideCoachMessage(role: .user, text: question))
        conversations[index].messages.append(TideCoachMessage(role: .assistant, text: "", isStreaming: true))
        conversations[index].updatedAt = Date()
        isResponding = true

        defer {
            isResponding = false
            if let i = conversations.firstIndex(where: { $0.id == activeID }),
               let last = conversations[i].messages.indices.last {
                conversations[i].messages[last].isStreaming = false
                conversations[i].updatedAt = Date()
            }
            save()
        }

        do {
            try await stream(question, store: store, settings: settings)
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize:
                // The transcript outgrew the on-device window. Rebuild the session (which keeps the
                // health snapshot and a short recap) and answer once more.
                session = nil
                sessionConversationID = nil
                do {
                    try await stream(question, store: store, settings: settings)
                } catch {
                    fail("This chat got too long. Start a new one and ask again.")
                }
            case .guardrailViolation:
                fail("I can't help with that one. Try asking about your sleep, heart rate, or activity.")
            default:
                fail("Something went wrong generating a reply. Try again.")
            }
        } catch {
            fail("Something went wrong generating a reply. Try again.")
        }
    }

    private func stream(_ question: String, store: RingStore, settings: RingSettings) async throws {
        guard let conversationID = activeID else { return }

        // A session belongs to one conversation. Switching chats — or coming back after the app was
        // swiped away — rebuilds it from fresh data plus a recap of what was already said, so the
        // numbers are always current even when the history is old.
        if session == nil || sessionConversationID != conversationID {
            session = LanguageModelSession(
                instructions: Self.systemInstructions(store: store, settings: settings, recapping: activeConversation)
            )
            sessionConversationID = conversationID
        }
        guard let active = session else { return }

        let responses = active.streamResponse(to: question)
        for try await snapshot in responses {
            guard let index = conversations.firstIndex(where: { $0.id == conversationID }),
                  let last = conversations[index].messages.indices.last else { break }
            // Snapshots are cumulative, so each one replaces the text rather than appending.
            conversations[index].messages[last].text = snapshot.content
        }
    }

    private func fail(_ message: String) {
        if let index = conversations.firstIndex(where: { $0.id == activeID }),
           let last = conversations[index].messages.indices.last,
           conversations[index].messages[last].role == .assistant,
           conversations[index].messages[last].text.isEmpty {
            conversations[index].messages.removeLast()
        }
        errorMessage = message
    }

    // MARK: Instructions

    private static func systemInstructions(
        store: RingStore,
        settings: RingSettings,
        recapping conversation: TideCoachConversation?
    ) -> String {
        let name = settings.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let addressed = name.isEmpty ? "the user" : name

        var recap = ""
        // Only the tail, and only when resuming — enough to stay coherent without eating the window.
        let prior = (conversation?.messages ?? []).filter { !$0.text.isEmpty }
        if prior.count > 1 {
            let lines = prior.suffix(6).map { message in
                let who = message.role == .user ? "They asked" : "You answered"
                let text = message.text.count <= 200 ? message.text : String(message.text.prefix(200)) + "…"
                return "\(who): \(text)"
            }
            recap = """

            EARLIER IN THIS CONVERSATION
            \(lines.joined(separator: "\n"))
            """
        }

        return """
        You are Tide Coach, a knowledgeable and honest wellness assistant living inside \
        \(addressed)'s smart-ring app. You help them understand their own body data and build \
        better habits.

        THEIR RECENT DATA
        This is everything you can see. Never invent a number that is not here.

        \(TideHealthContext.snapshot(store: store, settings: settings))
        \(recap)

        BE HONEST, NOT ENCOURAGING
        Your job is to tell them the truth about their health, not to make them feel good. This is \
        the most important thing about you.
        - Judge every number against their goal and against real health guidance, and say plainly \
        when they are falling short. If they are at 38% of their step goal, that is not "moving \
        enough" — say they are well short and by how much.
        - General adult guidance to hold them to: 7-9 hours of sleep a night, a consistent bed and \
        wake time, at least 7,000-10,000 steps a day, and 150 minutes a week of moderate activity.
        - Never open with praise you do not mean. If the data is poor, lead with that, then explain \
        what to do about it.
        - If something genuinely is going well, say so — but only when the numbers support it.

        HOW TO ANSWER
        - Answer the question fully. Take the space you need to be useful and specific; do not pad, \
        and do not cut an explanation short either.
        - Quote their actual numbers, and say what each one means in context.
        - Give concrete, ordinary advice: bedtime consistency, wind-down routine, morning daylight, \
        walking, caffeine timing, hydration. Prefer one or two changes they can actually keep.
        - If their data cannot answer the question, say so plainly rather than guessing.
        - Write plainly, in prose. No emoji. Use a short list only when giving steps.

        HARD LIMITS
        - This is a consumer wearable, not a medical device. Never diagnose, never name a condition \
        they might have, and never advise starting, stopping, or changing any medication.
        - If they mention chest pain, fainting, severe shortness of breath, or anything else \
        alarming, tell them to contact a doctor or emergency services. Do not try to troubleshoot it.
        - This ring cannot detect REM sleep and often reports no awake time. Never discuss REM, and \
        never conclude they slept undisturbed just because awake time reads zero or is missing.
        """
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let saved = try? JSONDecoder().decode([TideCoachConversation].self, from: data) else { return }
        conversations = saved
        activeID = saved.max(by: { $0.updatedAt < $1.updatedAt })?.id
    }

    private func save() {
        let snapshot = conversations.filter { !$0.isEmpty }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

//
//  TideReadiness.swift
//  Tide
//
//  Tide's intentionally simple wellness formula. This is not a medical score and must never be
//  presented as a diagnosis or used to make treatment decisions.
//

import Foundation

enum TideBloodPressureBand: String, Codable {
    case low = "Low"
    case normal = "Normal"
    case elevated = "Elevated"
    case stage1 = "Stage 1"
    case stage2 = "Stage 2"
    case severe = "Severe"

    var readinessPenalty: Int {
        switch self {
        case .normal: return 0
        case .low, .elevated: return 5
        case .stage1: return 10
        case .stage2: return 15
        case .severe: return 20
        }
    }
}

struct TideReadinessSnapshot: Identifiable, Codable, Equatable {
    var id: String { dayKey }
    let dayKey: String
    let sourceDayKey: String
    let timeZoneIdentifier: String
    let computedAt: Date
    let sleepScore: Int?
    let activityScore: Int?
    let bloodPressureBand: TideBloodPressureBand?
    let bloodPressurePenalty: Int
    let score: Int?
}

enum TideReadinessEngine {
    static func percentage(actual: Double, goal: Double) -> Double {
        guard actual.isFinite, goal.isFinite, goal > 0 else { return 0 }
        return min(100, max(0, actual / goal * 100))
    }

    static func sleepScore(actualSleepMinutes: Int, sleepGoalHours: Double) -> Int? {
        let goalMinutes = sleepGoalHours * 60
        guard actualSleepMinutes >= 0, goalMinutes > 0 else { return nil }
        return Int(percentage(actual: Double(actualSleepMinutes), goal: goalMinutes).rounded())
    }

    static func activityScore(
        steps: Int,
        activeCalories: Double,
        stepGoal: Int,
        calorieGoal: Int
    ) -> Int? {
        guard stepGoal > 0, calorieGoal > 0, steps >= 0, activeCalories >= 0 else { return nil }
        let stepPercent = percentage(actual: Double(steps), goal: Double(stepGoal))
        let caloriePercent = percentage(actual: activeCalories, goal: Double(calorieGoal))
        return Int(((stepPercent + caloriePercent) / 2).rounded())
    }

    static func readinessScore(sleepScore: Int?, activityScore: Int?, penalty: Int) -> Int? {
        guard let sleepScore, let activityScore else { return nil }
        let weighted = 0.70 * Double(sleepScore) + 0.30 * Double(activityScore)
        return min(100, max(0, Int(weighted.rounded()) - max(0, penalty)))
    }

    static func bloodPressureBand(systolic: Int, diastolic: Int) -> TideBloodPressureBand {
        if systolic >= 180 || diastolic >= 120 { return .severe }
        if systolic >= 140 || diastolic >= 90 { return .stage2 }
        if systolic >= 130 || diastolic >= 80 { return .stage1 }
        if systolic >= 120 { return .elevated }
        if systolic < 90 || diastolic < 60 { return .low }
        return .normal
    }

    static func localDayKey(for date: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

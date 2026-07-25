//
//  RingEventGate.swift
//  ringmvp
//
//  Plausibility gating for decoded ring frames. Ported from PulseLoop's `RingEventBridge`
//  (by Saksham Bhutani, CC BY 4.0), adapted to return validated `RingDecodedEvent`s instead of
//  the app-specific event type. A frame that fails its sanity check is dropped so a single
//  misframed packet can't poison stored history, peak HR, or the visible day.
//

import Foundation

enum RingEventGate {
    /// Plausible instantaneous heart rate, in bpm. Drops 0-bpm warm-up frames and noise.
    static let hrRange: ClosedRange<Int> = 30...220
    /// Plausible stress score (1–100; 0 = no sample).
    static let stressRange: ClosedRange<Int> = 1...100
    /// Plausible HRV, in milliseconds.
    static let hrvRange: ClosedRange<Int> = 1...300
    /// Plausible skin/body temperature, in °C.
    static let temperatureRange: ClosedRange<Double> = 30...45
    /// Plausible blood-pressure bounds (mmHg) — drops misframed 0x24 bytes.
    static let systolicRange: ClosedRange<Int> = 60...250
    static let diastolicRange: ClosedRange<Int> = 30...160
    /// Plausible fatigue score (1–100; 0 = no sample).
    static let fatigueRange: ClosedRange<Int> = 1...100
    /// Plausible blood sugar, in mg/dL.
    static let bloodSugarRange: ClosedRange<Double> = 40...600
    /// Sanity ceilings for one intraday activity bucket (~15 min).
    static let maxBucketSteps = 5000
    static let maxBucketDistance: Double = 6000   // metres
    /// Sanity ceilings for a full day of cumulative activity.
    static let maxDailySteps = 100_000
    static let maxDailyDistanceMeters: Double = 120_000   // metres
    static let maxDailyCalories: Double = 10_000          // kcal

    /// Return the decoded event unchanged if it passes its plausibility check, or `nil` to drop it.
    /// Events with no sanity gate (acks, bind, capabilities, status, etc.) pass through untouched.
    static func validate(_ decoded: RingDecodedEvent, now: Date = Date()) -> RingDecodedEvent? {
        switch decoded {
        case let .activityUpdate(timestamp, steps, distanceMeters, calories):
            return isPlausibleDailyActivity(steps: steps, distanceMeters: distanceMeters,
                                            calories: calories, timestamp: timestamp, now: now) ? decoded : nil

        case let .activityBucket(timestamp, steps, distanceMeters):
            guard isWithinHistoryWindow(timestamp, now: now),
                  (0...maxBucketSteps).contains(steps),
                  (0...maxBucketDistance).contains(distanceMeters) else { return nil }
            return decoded

        case let .heartRateSample(bpm, _):
            return hrRange.contains(bpm) ? decoded : nil

        case let .historyMeasurement(kind, value, timestamp):
            if kind == .heartRate, !hrRange.contains(Int(value)) { return nil }
            return isWithinHistoryWindow(timestamp, now: now) ? decoded : nil

        case let .stressSample(value, _):
            return stressRange.contains(value) ? decoded : nil

        case let .hrvSample(value, _):
            return hrvRange.contains(value) ? decoded : nil

        case let .temperatureSample(celsius, _):
            return temperatureRange.contains(celsius) ? decoded : nil

        case let .sleepTimeline(timestamp, stages):
            guard isWithinHistoryWindow(timestamp, now: now), !stages.isEmpty else { return nil }
            return decoded

        case let .battery(percent):
            return (0...100).contains(percent) ? decoded : nil

        case let .bloodPressureSample(systolic, diastolic, _):
            guard systolicRange.contains(systolic), diastolicRange.contains(diastolic) else { return nil }
            return decoded

        case let .fatigueSample(value, _):
            return fatigueRange.contains(value) ? decoded : nil

        case let .bloodSugarSample(mgdl, _):
            return bloodSugarRange.contains(mgdl) ? decoded : nil

        default:
            // spo2Result is already range-gated in the decoder; everything else has no numeric gate.
            return decoded
        }
    }

    private static func isPlausibleDailyActivity(steps: Int, distanceMeters: Double, calories: Double, timestamp: Date, now: Date) -> Bool {
        (0...maxDailySteps).contains(steps)
            && (0...maxDailyDistanceMeters).contains(distanceMeters)
            && (0...maxDailyCalories).contains(calories)
            && isWithinHistoryWindow(timestamp, now: now)
    }

    /// Within the last ~8 days (the history horizon) and no more than an hour into the future.
    static func isWithinHistoryWindow(_ date: Date, now: Date = Date()) -> Bool {
        let lower = now.addingTimeInterval(-8 * 24 * 3600)
        let upper = now.addingTimeInterval(3600)
        return date >= lower && date <= upper
    }
}

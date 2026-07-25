//
//  SleepScore.swift
//  Tide
//
//  A nightly sleep score, ported from PulseLoop's `SleepInsights.SleepScore` (itself a 1:1 port of
//  the PulseLoop web app's `sleepScore.ts`). Pure, data-honest scoring: it weights total duration,
//  deep %, light %, and awake %, each on a soft "band" curve rather than a hard cutoff.
//
//  Tide-specific notes:
//  - We compute against Tide's `SleepNight` (blocks + light/deep/rem/awake minutes).
//  - "Awake" comes from the ring's own 0x00 sleep buckets — i.e. when the finger moved / the wearer
//    was restless during the night — so awake time is measured, not assumed. When no awake signal is
//    present at all, the awake sub-score is neutral rather than penalising the night.
//
//  Protocol/logic lineage: PulseLoop by Saksham Bhutani (CC BY 4.0).
//

import Foundation

enum SleepQualityLabel: String {
    case excellent = "Excellent"
    case good = "Good"
    case fair = "Fair"
    case needsWork = "Needs work"
}

struct SleepScoreResult {
    let score: Int
    let label: SleepQualityLabel
    let deepPct: Int
    let lightPct: Int
    /// nil when there is no usable awake signal for the night.
    let awakePct: Int?
}

enum SleepScore {
    private static func clamp(_ value: Double, _ lo: Double, _ hi: Double) -> Double {
        min(hi, max(lo, value))
    }

    /// Score a value against an ideal band with soft/hard shoulders. Full points inside the ideal
    /// band; a graceful fall-off through the soft band; a floor of 65% of a proportional term outside.
    private static func bandScore(
        _ value: Double,
        idealLow: Double, idealHigh: Double,
        softLow: Double, softHigh: Double,
        hardLow: Double, hardHigh: Double,
        points: Double
    ) -> Double {
        guard value.isFinite else { return 0 }
        if value >= idealLow && value <= idealHigh { return points }
        if value < idealLow && value >= softLow {
            return points * (0.65 + 0.35 * ((value - softLow) / (idealLow - softLow)))
        }
        if value > idealHigh && value <= softHigh {
            return points * (0.65 + 0.35 * ((softHigh - value) / (softHigh - idealHigh)))
        }
        if value < softLow {
            return points * 0.65 * clamp((value - hardLow) / (softLow - hardLow), 0, 1)
        }
        return points * 0.65 * clamp((hardHigh - value) / (hardHigh - softHigh), 0, 1)
    }

    private static func awakeScore(_ awakePct: Double?, points: Double) -> Double {
        guard let awakePct, awakePct.isFinite else { return points * 0.55 }
        if awakePct <= 10 { return points }
        if awakePct <= 20 { return points * (1 - 0.65 * ((awakePct - 10) / 10)) }
        return points * 0.35 * clamp((35 - awakePct) / 15, 0, 1)
    }

    static func qualityLabel(_ score: Int) -> SleepQualityLabel {
        if score >= 85 { return .excellent }
        if score >= 70 { return .good }
        if score >= 55 { return .fair }
        return .needsWork
    }

    /// The full session length used as the score's denominator: time asleep plus measured awake time.
    static func totalMinutes(_ night: SleepNight) -> Int {
        night.asleepMinutes + night.awakeMinutes
    }

    static func calculate(_ night: SleepNight) -> SleepScoreResult {
        let total = Double(max(0, totalMinutes(night)))
        let deep = Double(max(0, night.deepMinutes))
        let light = Double(max(0, night.lightMinutes))
        let awake = Double(max(0, night.awakeMinutes))
        let coveredStageMin = night.blocks.reduce(0.0) { sum, block in
            switch block.stage {
            case .deep, .light, .rem, .awake: return sum + Double(max(0, block.minutes))
            default: return sum
            }
        }
        let hasAwakeSignal =
            night.blocks.contains { $0.stage == .awake } ||
            awake > 0 ||
            (total > 0 && coveredStageMin >= total * 0.95)

        let totalHours = total / 60
        let deepPct = total > 0 ? (deep / total) * 100 : 0
        let lightPct = total > 0 ? (light / total) * 100 : 0
        let awakePct: Double? = (total > 0 && hasAwakeSignal) ? (awake / total) * 100 : nil

        let duration = bandScore(totalHours, idealLow: 7.5, idealHigh: 8.5, softLow: 6, softHigh: 9.5, hardLow: 3, hardHigh: 12, points: 35)
        let deepScore = bandScore(deepPct, idealLow: 13, idealHigh: 23, softLow: 5, softHigh: 35, hardLow: 0, hardHigh: 45, points: 30)
        let lightScore = bandScore(lightPct, idealLow: 50, idealHigh: 60, softLow: 35, softHigh: 75, hardLow: 20, hardHigh: 90, points: 20)
        let awakeSub = awakeScore(awakePct, points: 15)
        let score = Int(clamp((duration + deepScore + lightScore + awakeSub).rounded(), 0, 100))

        return SleepScoreResult(
            score: score,
            label: qualityLabel(score),
            deepPct: Int(deepPct.rounded()),
            lightPct: Int(lightPct.rounded()),
            awakePct: awakePct.map { Int($0.rounded()) }
        )
    }
}

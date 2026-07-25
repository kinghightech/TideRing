//
//  MetricReference.swift
//  Tide
//
//  The reference-range engine and the shared detail-page building blocks. The clinical thresholds,
//  labels, and explainer copy are ported from PulseLoop's `VitalsThresholdEngine`
//  (by Saksham Bhutani, CC BY 4.0) but rendered entirely in Tide's own design language — glass cards,
//  TideFont, TideColors — not PulseLoop's chrome.
//
//  Every metric detail screen composes the same four blocks below the chart:
//    • StatTilesRow      — Latest / Average / Min / Max
//    • ReferenceZonesCard — the colored zone legend with ranges
//    • WhatThisMeansCard  — a plain-language explainer
//    • CollapsibleCard    — (HR / BP) a tucked-away "Recent readings" list
//

import SwiftUI

// MARK: - Zone model

/// One reference band for a metric, expressed as a half-open interval `[lower, upper)` in the
/// metric's canonical unit. `nil` means the band is open on that side.
struct MetricZone: Identifiable {
    let id = UUID()
    let label: String
    let lower: Double?
    let upper: Double?
    let color: Color
    let explanation: String

    func contains(_ value: Double) -> Bool {
        (lower == nil || value >= lower!) && (upper == nil || value < upper!)
    }

    /// A readable range like "60–100", "< 60", or "≥ 120".
    func rangeText(_ fmt: (Double) -> String) -> String {
        switch (lower, upper) {
        case let (lo?, hi?): return "\(fmt(lo))–\(fmt(hi))"
        case let (nil, hi?): return "< \(fmt(hi))"
        case let (lo?, nil): return "≥ \(fmt(lo))"
        default: return ""
        }
    }
}

/// The clinical reference zones + explainer copy for each metric Tide surfaces. This is Tide's single
/// source of truth for "what's normal", mirroring PulseLoop's engine.
enum MetricReference {

    static func zones(for metric: TideMetric, samples: [RingReading] = []) -> [MetricZone] {
        switch metric {
        case .heartRate: return heartRate
        case .bloodOxygen: return bloodOxygen
        case .bloodPressure: return systolic   // legend uses systolic; the card shows both axes
        case .hrv: return hrvZones(samples: samples)
        case .stress: return stress
        case .fatigue: return fatigue
        case .bloodSugar: return bloodSugar
        default: return []
        }
    }

    /// The zone that contains a value (used to color the "latest" and to caption a reading).
    static func zone(for value: Double, metric: TideMetric, samples: [RingReading] = []) -> MetricZone? {
        zones(for: metric, samples: samples).first { $0.contains(value) }
    }

    // MARK: Heart rate (resting)

    static let heartRate: [MetricZone] = [
        MetricZone(label: "Low", lower: nil, upper: 60, color: .blue,
                   explanation: "Below the typical resting range. Often fine — common with high fitness — but worth noting if you feel faint."),
        MetricZone(label: "Normal", lower: 60, upper: 100, color: .pink,
                   explanation: "A typical resting heart rate for adults is 60–100 bpm."),
        MetricZone(label: "Elevated", lower: 100, upper: 120, color: .orange,
                   explanation: "Above the typical resting range. Activity, caffeine, or stress can raise it."),
        MetricZone(label: "High", lower: 120, upper: nil, color: .red,
                   explanation: "A high resting heart rate. Talk to a clinician if it persists at rest."),
    ]

    // MARK: Blood oxygen (SpO₂)

    static let bloodOxygen: [MetricZone] = [
        MetricZone(label: "Very low", lower: nil, upper: 89, color: .red,
                   explanation: "An urgently low oxygen reading. Seek care if you also feel unwell."),
        MetricZone(label: "Low", lower: 89, upper: 93, color: .orange,
                   explanation: "Low blood oxygen. Re-measure when still; talk to a clinician if it persists."),
        MetricZone(label: "Slightly low", lower: 93, upper: 95, color: .yellow,
                   explanation: "Slightly below the typical range. Altitude and lung conditions can lower it."),
        MetricZone(label: "Normal", lower: 95, upper: nil, color: .cyan,
                   explanation: "A normal blood-oxygen level is 95–100%."),
    ]

    // MARK: Blood pressure — systolic axis (legend) + diastolic (gauge)

    static let systolic: [MetricZone] = [
        MetricZone(label: "Low", lower: nil, upper: 90, color: .blue,
                   explanation: "Low systolic pressure (below 90)."),
        MetricZone(label: "Normal", lower: 90, upper: 120, color: .mint,
                   explanation: "Normal blood pressure is below 120/80."),
        MetricZone(label: "Elevated", lower: 120, upper: 130, color: .yellow,
                   explanation: "Elevated systolic (120–129)."),
        MetricZone(label: "Stage 1", lower: 130, upper: 140, color: .orange,
                   explanation: "Stage 1 hypertension range (systolic 130–139)."),
        MetricZone(label: "Stage 2", lower: 140, upper: 180, color: .red,
                   explanation: "Stage 2 hypertension range (systolic ≥140)."),
        MetricZone(label: "Severe", lower: 180, upper: nil, color: .red,
                   explanation: "Severe range (systolic >180). Seek care if confirmed."),
    ]

    static let diastolic: [MetricZone] = [
        MetricZone(label: "Low", lower: nil, upper: 60, color: .blue, explanation: "Low diastolic (below 60)."),
        MetricZone(label: "Normal", lower: 60, upper: 80, color: .mint, explanation: "Normal diastolic is below 80."),
        MetricZone(label: "Stage 1", lower: 80, upper: 90, color: .orange, explanation: "Stage 1 (diastolic 80–89)."),
        MetricZone(label: "Stage 2", lower: 90, upper: 120, color: .red, explanation: "Stage 2 (diastolic ≥90)."),
        MetricZone(label: "Severe", lower: 120, upper: nil, color: .red, explanation: "Severe (diastolic >120)."),
    ]

    // MARK: HRV (personal baseline), stress, fatigue, and blood sugar

    /// Pulse Loop interprets HRV against the wearer's own baseline instead of fixed population
    /// cutoffs. A baseline becomes established after at least 20 readings spanning roughly a week.
    static func hrvZones(samples: [RingReading]) -> [MetricZone] {
        let ordered = samples.filter { $0.value > 0 }.sorted { $0.date < $1.date }
        guard ordered.count >= 20,
              let first = ordered.first?.date,
              let last = ordered.last?.date,
              last.timeIntervalSince(first) >= 7 * 24 * 3600 else {
            return [MetricZone(label: "Building baseline", lower: nil, upper: nil, color: .purple,
                               explanation: "HRV is personal. Wear your ring for about a week to learn your baseline.")]
        }
        let values = ordered.map(\.value)
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + pow($1 - mean, 2) } / Double(values.count)
        let deviation = sqrt(variance)
        guard deviation > 0 else {
            return [MetricZone(label: "Near baseline", lower: nil, upper: nil, color: .purple,
                               explanation: "Around your personal HRV baseline.")]
        }
        return [
            MetricZone(label: "Below baseline", lower: nil, upper: mean - deviation, color: .orange,
                       explanation: "Notably below your typical HRV — often linked to stress, poor sleep, or strain."),
            MetricZone(label: "Slightly below", lower: mean - deviation, upper: mean - 0.5 * deviation, color: .yellow,
                       explanation: "A little below your usual HRV range."),
            MetricZone(label: "Near baseline", lower: mean - 0.5 * deviation, upper: mean + 0.5 * deviation, color: .purple,
                       explanation: "Around your personal HRV baseline."),
            MetricZone(label: "Above baseline", lower: mean + 0.5 * deviation, upper: nil, color: .mint,
                       explanation: "Above your typical HRV — often a sign of good recovery."),
        ]
    }

    static let stress: [MetricZone] = [
        MetricZone(label: "Calm", lower: nil, upper: 26, color: .mint, explanation: "Low stress score — relaxed."),
        MetricZone(label: "Normal", lower: 26, upper: 51, color: .cyan, explanation: "A typical daytime stress score."),
        MetricZone(label: "Elevated", lower: 51, upper: 76, color: .orange, explanation: "Elevated stress — consider a short break."),
        MetricZone(label: "High", lower: 76, upper: nil, color: .red, explanation: "High stress score. Wellness estimate, not a diagnosis."),
    ]

    static let fatigue: [MetricZone] = [
        MetricZone(label: "Fresh", lower: nil, upper: 25, color: .mint, explanation: "Low fatigue — well recovered."),
        MetricZone(label: "Mild", lower: 25, upper: 50, color: .cyan, explanation: "Mild fatigue."),
        MetricZone(label: "Tired", lower: 50, upper: 75, color: .orange, explanation: "Tired — consider lighter activity and good sleep."),
        MetricZone(label: "High fatigue", lower: 75, upper: nil, color: .red, explanation: "High fatigue score. Wellness estimate from the ring."),
    ]

    /// Unknown/non-fasting context, matching Pulse Loop's conservative display labels.
    static let bloodSugar: [MetricZone] = [
        MetricZone(label: "Low", lower: nil, upper: 70, color: .red, explanation: "Below 70 mg/dL is low."),
        MetricZone(label: "Typical", lower: 70, upper: 140, color: .mint, explanation: "Within a typical range for a non-fasting reading."),
        MetricZone(label: "Elevated", lower: 140, upper: 200, color: .orange, explanation: "Above the typical range. Meal timing affects this."),
        MetricZone(label: "Very high", lower: 200, upper: nil, color: .red, explanation: "A high estimate regardless of context. Confirm with a meter."),
    ]

    // MARK: What this means

    static func explainer(for metric: TideMetric) -> String {
        switch metric {
        case .heartRate:
            return "Resting heart rate reflects how hard your heart works at rest. A typical adult range is 60–100 bpm; fitness, medication, caffeine, and stress all shift it."
        case .bloodOxygen:
            return "Blood oxygen (SpO₂) is the percentage of oxygen your blood carries. 95–100% is normal; altitude and lung conditions can lower it."
        case .bloodPressure:
            return "Blood pressure is systolic over diastolic (mmHg). The category is the worse of the two. A ring estimate is not a substitute for a cuff — calibrate in Settings."
        case .calories:
            return "Active calories are the energy you burn through movement, estimated from steps and your body profile. It excludes the calories you'd burn at rest."
        case .steps:
            return "Steps and walking distance come straight from the ring's motion sensor. Distance is estimated from your stride, so treat it as a close approximation."
        case .sleep:
            return "Your sleep score blends total time asleep, how much was deep and light, and how restless the night was. Trends over several nights matter more than any single score."
        case .hrv:
            return "Heart rate variability is highly personal. Tide compares it with your own rolling baseline; higher-than-usual values often align with better recovery."
        case .stress:
            return "Stress is a 0–100 wellness score estimated by the ring. Lower is calmer. Use the pattern across your day rather than one reading."
        case .fatigue:
            return "Fatigue is a 0–100 recovery estimate from the ring. Sleep, strain, and recent activity can all affect it."
        case .bloodSugar:
            return "Blood sugar is a ring-estimated wellness metric, not a glucose-meter reading. Do not use it for medication, dosing, or diagnosis."
        default:
            return ""
        }
    }
}

// MARK: - Stat tiles (Latest / Average / Min / Max)

/// The four-across summary row from PulseLoop's metric detail, in Tide glass. Pass pre-formatted
/// strings ("--" for missing) so each metric controls its own rounding.
struct StatTilesRow: View {
    let latest: String
    let average: String
    let min: String
    let max: String
    var tint: Color = TideColors.accent

    var body: some View {
        GlassCard {
            HStack(spacing: 0) {
                tile("LATEST", latest, tint: tint)
                divider
                tile("AVERAGE", average)
                divider
                tile("MIN", min)
                divider
                tile("MAX", max)
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 8)
        }
    }

    private func tile(_ title: String, _ value: String, tint: Color = .primary) -> some View {
        VStack(spacing: 7) {
            Text(title).font(.caption2).tracking(0.6).foregroundStyle(.secondary).lineLimit(1)
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(tint)
                .minimumScaleFactor(0.5).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private var divider: some View {
        Rectangle().fill(.secondary.opacity(0.22)).frame(width: 1, height: 34)
    }
}

// MARK: - Reference zones legend

struct ReferenceZonesCard: View {
    let zones: [MetricZone]
    /// Formats a bound into the metric's display units (defaults to whole numbers).
    var format: (Double) -> String = { "\(Int($0.rounded()))" }
    /// Optionally highlight the zone that the current value falls into.
    var highlight: Double? = nil

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("REFERENCE ZONES")
                    .font(.caption2.weight(.semibold)).tracking(1.0).foregroundStyle(.secondary)
                ForEach(zones) { zone in
                    let isActive = highlight.map { zone.contains($0) } ?? false
                    HStack(spacing: 10) {
                        Circle().fill(zone.color).frame(width: 9, height: 9)
                        Text(zone.label)
                            .font(.subheadline.weight(isActive ? .semibold : .regular))
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(zone.rangeText(format))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 1)
                    .opacity(highlight == nil || isActive ? 1 : 0.55)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }
}

// MARK: - What this means

struct WhatThisMeansCard: View {
    let text: String

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 6) {
                Text("WHAT THIS MEANS")
                    .font(.caption2.weight(.semibold)).tracking(1.0).foregroundStyle(.secondary)
                Text(text).font(.footnote).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }
}

// MARK: - Collapsible card (kept from Tide: "Recent readings")

/// A glass card that expands/collapses its content — used for the "Recent" readings list that Tide
/// keeps but PulseLoop doesn't have, tucked at the bottom of a detail page.
struct CollapsibleCard<Content: View>: View {
    let title: String
    var startExpanded: Bool = false
    @ViewBuilder var content: () -> Content
    @State private var expanded: Bool

    init(title: String, startExpanded: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.startExpanded = startExpanded
        self.content = content
        _expanded = State(initialValue: startExpanded)
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(.snappy(duration: 0.28)) { expanded.toggle() }
                } label: {
                    HStack {
                        Text(title).font(.headline).foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(expanded ? 0 : -90))
                    }
                    .padding(.horizontal, 16).padding(.vertical, 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if expanded {
                    content()
                        .padding(.bottom, 6)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }
}

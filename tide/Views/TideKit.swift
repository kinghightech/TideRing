//
//  TideKit.swift
//  Tide
//
//  Shared visual language: the metric catalog, glass card container, gradient background, and small
//  building blocks used across the Summary / Trends / detail screens.
//

import SwiftUI

// MARK: - Metric catalog

/// Every metric the app surfaces. Drives the Summary cards and the detail screens uniformly.
enum TideMetric: String, CaseIterable, Identifiable {
    case heartRate, bloodOxygen, bloodPressure, steps, calories, sleep
    case stress, hrv, temperature, fatigue, bloodSugar

    var id: String { rawValue }

    var title: String {
        switch self {
        case .heartRate: return "Heart Rate"
        case .bloodOxygen: return "Blood Oxygen"
        case .bloodPressure: return "Blood Pressure"
        case .steps: return "Steps"
        case .calories: return "Calories"
        case .sleep: return "Sleep"
        case .stress: return "Stress"
        case .hrv: return "Heart Rate Variability"
        case .temperature: return "Temperature"
        case .fatigue: return "Fatigue"
        case .bloodSugar: return "Blood Sugar"
        }
    }

    var shortTitle: String {
        switch self {
        case .bloodOxygen: return "Blood Oxygen"
        case .bloodPressure: return "Blood Pressure"
        case .hrv: return "HRV"
        default: return title
        }
    }

    var icon: String {
        switch self {
        case .heartRate: return "heart.fill"
        case .bloodOxygen: return "drop.fill"
        case .bloodPressure: return "waveform.path.ecg"
        case .steps: return "figure.walk"
        case .calories: return "flame.fill"
        case .sleep: return "bed.double.fill"
        case .stress: return "brain.head.profile"
        case .hrv: return "waveform.path"
        case .temperature: return "thermometer.medium"
        case .fatigue: return "battery.25"
        case .bloodSugar: return "cube.transparent"
        }
    }

    var tint: Color {
        switch self {
        case .heartRate: return .pink
        case .bloodOxygen: return .blue
        case .bloodPressure: return .purple
        case .steps: return .orange
        case .calories: return Color(red: 1.0, green: 0.45, blue: 0.3)
        case .sleep: return .indigo
        case .stress: return .mint
        case .hrv: return .teal
        case .temperature: return .red
        case .fatigue: return .yellow
        case .bloodSugar: return .green
        }
    }

    var unit: String {
        switch self {
        case .heartRate: return "bpm"
        case .bloodOxygen: return "%"
        case .bloodPressure: return "mmHg"
        case .steps: return "steps"
        case .calories: return "kcal"
        case .sleep: return ""
        case .stress: return ""
        case .hrv: return "ms"
        case .temperature: return "°C"
        case .fatigue: return ""
        case .bloodSugar: return "mg/dL"
        }
    }

    /// Maps the scalar metrics to their `MeasurementKind` for the extra-measurement store.
    var extraKind: MeasurementKind? {
        switch self {
        case .stress: return .stress
        case .hrv: return .hrv
        case .temperature: return .temperature
        case .fatigue: return .fatigue
        case .bloodSugar: return .bloodSugar
        default: return nil
        }
    }
}

// MARK: - Glass card

/// A frosted, rounded container — the app's core surface.
struct GlassCard<Content: View>: View {
    var cornerRadius: CGFloat = 22
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.06), radius: 10, y: 4)
    }
}

// MARK: - Background

/// The shared page background, used across Trends / Settings / metric detail / ring pages.
/// Adapts to the system appearance: calm deep ocean in dark mode, a light calm-blue wash over the
/// system background in light mode. Matches the Tide Ring page.
struct TideBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            if scheme == .dark {
                TideColors.deepOcean
            } else {
                ZStack {
                    Color(.systemBackground)
                    LinearGradient(
                        colors: [
                            Color(red: 0.55, green: 0.78, blue: 0.96).opacity(0.5),
                            Color(red: 0.72, green: 0.86, blue: 0.97).opacity(0.16),
                            .clear,
                        ],
                        startPoint: .top, endPoint: .center
                    )
                }
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Small building blocks

/// A big value + unit, used in card headers and detail hero rows.
struct BigValue: View {
    let value: String
    var unit: String = ""
    var tint: Color = .primary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(value)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
            if !unit.isEmpty {
                Text(unit).font(.footnote.weight(.medium)).foregroundStyle(.secondary)
            }
        }
    }
}

/// Section header with a small caption, used on detail screens.
struct StatPill: View {
    let label: String
    let value: String
    var tint: Color = .primary

    var body: some View {
        VStack(spacing: 3) {
            Text(value).font(.headline.weight(.semibold)).foregroundStyle(tint)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Active energy

/// Calorie helpers. The ring reports active calories directly in its `0x03` activity frame (the same
/// source PulseLoop uses). When the ring reports 0 on a day that clearly had movement, we fall back to
/// a simple step-based estimate scaled by body weight so an active day is never shown as 0 kcal.
enum ActiveEnergy {
    /// ~0.045 kcal per step for a 70 kg reference person, scaled linearly by weight.
    static func estimate(steps: Int, weightKg: Int) -> Double {
        guard steps > 0 else { return 0 }
        let weightFactor = Double(max(30, weightKg)) / 70.0
        return (Double(steps) * 0.045 * weightFactor).rounded()
    }

    /// The value to display: trust the ring when it reports calories, otherwise estimate from steps.
    static func resolved(ringCalories: Double, steps: Int, weightKg: Int) -> Double {
        ringCalories > 0 ? ringCalories : estimate(steps: steps, weightKg: weightKg)
    }
}

// MARK: - Formatting

enum Fmt {
    static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    static func steps(_ value: Int) -> String {
        value >= 1000 ? String(format: "%.1fk", Double(value) / 1000) : String(value)
    }

    /// Distance in the user's rough locale-free format (km, 2 significant places under 10).
    static func distanceKm(_ meters: Double) -> String {
        let km = meters / 1000
        return km >= 10 ? String(format: "%.0f km", km) : String(format: "%.1f km", km)
    }

    static func calories(_ value: Double) -> String {
        "\(Int(value.rounded()))"
    }

    static func duration(minutes: Int) -> String {
        "\(minutes / 60)h \(minutes % 60)m"
    }

    /// Sleep durations, formatted exactly as PulseLoop's `SleepFormat.duration`
    /// (SleepInsights.swift): zero hours collapses to minutes, and minutes are zero-padded, so a
    /// seven-hour night reads "7h 00m" rather than "7h 0m".
    static func sleepDuration(minutes: Int?) -> String {
        guard let minutes, minutes >= 0 else { return "—" }
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours <= 0 { return "\(remainder)m" }
        return "\(hours)h \(String(format: "%02d", remainder))m"
    }

    static func relativeDay(_ date: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
}

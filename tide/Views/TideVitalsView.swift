//
//  TideVitalsView.swift
//  Tide
//
//  Full-width vitals dashboard modeled after PulseLoop's Vitals card hierarchy and ordering,
//  rendered with Tide's existing charts and navigation. PulseLoop by Saksham Bhutani, CC BY 4.0.
//

import SwiftUI

struct TideVitalsView: View {
    @ObservedObject var manager: RingManager
    @ObservedObject var store: RingStore

    private let metrics: [TideMetric] = [
        .heartRate, .bloodOxygen, .bloodPressure, .hrv, .stress, .fatigue, .bloodSugar
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                TideBackground()
                ScrollView {
                    VStack(spacing: 14) {
                        ForEach(metrics) { metric in
                            NavigationLink {
                                MetricDetailView(metric: metric, manager: manager, store: store)
                            } label: {
                                VitalDashboardCard(metric: metric, store: store)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 40)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}

private struct VitalDashboardCard: View {
    let metric: TideMetric
    @ObservedObject var store: RingStore

    private var weekStart: Date {
        let calendar = Calendar.current
        return calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: Date())) ?? Date()
    }
    private var scalarSeries: [RingReading] {
        let all: [RingReading]
        switch metric {
        case .heartRate:
            all = store.heartRate
        case .bloodOxygen:
            all = store.spo2
        default:
            guard let kind = metric.extraKind else { return [] }
            all = store.extraMeasurements
                .filter { $0.kindRaw == kind.rawValue }
                .map { RingReading(id: $0.id, value: $0.value, date: $0.date, source: "") }
        }
        return all.filter { $0.date >= weekStart }.sorted { $0.date < $1.date }
    }

    private var allScalarSeries: [RingReading] {
        switch metric {
        case .heartRate: return store.heartRate
        case .bloodOxygen: return store.spo2
        default:
            guard let kind = metric.extraKind else { return [] }
            return store.extraMeasurements
                .filter { $0.kindRaw == kind.rawValue }
                .map { RingReading(id: $0.id, value: $0.value, date: $0.date, source: "") }
                .sorted { $0.date < $1.date }
        }
    }

    var body: some View {
        GlassCard(cornerRadius: 30) {
            VStack(alignment: .leading, spacing: 8) {
                header
                if metric == .bloodPressure {
                    bloodPressureBody
                } else {
                    scalarBody
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.vertical, 20)
        }
        .contentShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(metric.vitalsAccent)
                .frame(width: 8, height: 8)
                .shadow(color: metric.vitalsAccent.opacity(0.7), radius: 5)
            Text(metric.title.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(1)
                .foregroundStyle(.secondary)
            Spacer()
            if let date = lastUpdatedDate {
                Text(updatedText(date))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if metric == .bloodPressure || metric == .bloodSugar {
                Text("ESTIMATED")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.7)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.orange.opacity(0.14), in: Capsule())
            }
        }
    }

    @ViewBuilder
    private var scalarBody: some View {
        if let latest = scalarSeries.last {
            let zones = MetricReference.zones(for: metric, samples: allScalarSeries)
            let zone = zones.first { $0.contains(latest.value) }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(valueText)
                        .font(.system(size: 36, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    if !valueUnit.isEmpty {
                        Text(valueUnit).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 8) {
                    Text((zone?.label ?? "Latest reading").uppercased())
                        .font(.caption2.weight(.semibold))
                        .tracking(0.7)
                        .foregroundStyle(zone?.color ?? metric.vitalsAccent)
                    if let trendText { Text(trendText).font(.caption2).foregroundStyle(.secondary) }
                }
                if let subtitleText {
                    Text(subtitleText).font(.caption).foregroundStyle(.secondary)
                }
            }

            if scalarSeries.count >= 1 {
                RangeBarChart(
                    stats: store.dayStats(allScalarSeries, days: 7),
                    tint: metric.vitalsAccent,
                    height: 150,
                    preferredYDomain: metric == .bloodOxygen ? 85...100 : nil,
                    interactive: false
                )
                .padding(.top, 4)
            }
        } else {
            emptyState
        }
    }

    @ViewBuilder
    private var bloodPressureBody: some View {
        let readings = store.bloodPressure.filter { $0.date >= weekStart }.sorted { $0.date < $1.date }
        if let latest = readings.last {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(latest.systolic)/\(latest.diastolic)")
                        .font(.system(size: 36, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("mmHg").font(.footnote).foregroundStyle(.secondary)
                }
                Text(bloodPressureStatus(latest).uppercased())
                    .font(.caption2.weight(.semibold))
                    .tracking(0.7)
                    .foregroundStyle(bloodPressureColor(latest))
            }
            if !readings.isEmpty {
                RangeBarChart(
                    stats: store.dayStats(readings.map {
                        RingReading(value: Double($0.systolic), date: $0.date, source: "")
                    }, days: 7),
                    tint: metric.vitalsAccent,
                    height: 150,
                    interactive: false
                )
                    .padding(.top, 4)
            }
        } else {
            emptyState
        }
    }

    private var emptyState: some View {
        VStack(spacing: 7) {
            Image(systemName: metric.icon)
                .font(.system(size: 25))
                .foregroundStyle(metric.vitalsAccent.opacity(0.75))
            Text("No \(metric.title.lowercased()) data yet")
                .font(.subheadline.weight(.medium))
            Text("Sync your ring to start this trend.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 150)
    }

    private var valueText: String {
        let values = scalarSeries.map(\.value)
        guard let latest = values.last else { return "--" }
        switch metric {
        case .heartRate:
            guard let low = values.min(), let high = values.max(), values.count >= 2 else { return Fmt.number(latest) }
            return "\(Fmt.number(low))–\(Fmt.number(high))"
        case .bloodOxygen:
            guard !values.isEmpty else { return Fmt.number(latest) }
            return Fmt.number(values.reduce(0, +) / Double(values.count))
        default:
            return Fmt.number(latest)
        }
    }

    private var valueUnit: String {
        switch metric {
        case .heartRate: return scalarSeries.count >= 2 ? "bpm range" : "bpm"
        case .bloodOxygen: return scalarSeries.isEmpty ? "%" : "% avg"
        default: return metric.unit
        }
    }

    private var subtitleText: String? {
        switch metric {
        case .bloodOxygen:
            guard let low = scalarSeries.map(\.value).min() else { return nil }
            return "Lowest \(Fmt.number(low))% · \(scalarSeries.count) readings"
        case .hrv:
            let values = allScalarSeries.map(\.value).filter { $0 > 0 }
            guard values.count >= 20 else { return "Building personal baseline" }
            return "Baseline \(Fmt.number(values.reduce(0, +) / Double(values.count))) ms"
        case .stress: return "Lower is calmer"
        case .fatigue: return "Ring model estimate"
        case .bloodSugar: return "Estimated wellness metric · not for dosing"
        default: return nil
        }
    }

    private var trendText: String? {
        let samples = scalarSeries
        guard samples.count >= 3 else { return nil }
        let values = samples.map(\.value)
        let delta: Double
        let suffix: String
        if metric == .hrv, allScalarSeries.count >= 20 {
            let baseline = allScalarSeries.map(\.value).reduce(0, +) / Double(allScalarSeries.count)
            delta = (values.last ?? baseline) - baseline
            suffix = "vs baseline"
        } else if samples.count >= 8, let first = samples.first?.date, let last = samples.last?.date {
            let midpoint = first.addingTimeInterval(last.timeIntervalSince(first) / 2)
            let earlier = samples.filter { $0.date < midpoint }.map(\.value)
            let recent = samples.filter { $0.date >= midpoint }.map(\.value)
            guard !earlier.isEmpty, !recent.isEmpty else { return nil }
            delta = recent.reduce(0, +) / Double(recent.count) - earlier.reduce(0, +) / Double(earlier.count)
            suffix = "vs earlier"
        } else {
            delta = values[values.count - 1] - values[values.count - 2]
            suffix = "vs previous"
        }
        if abs(delta) < 0.5 { return "Stable \(suffix)" }
        return "\(delta > 0 ? "↑" : "↓") \(Fmt.number(abs(delta))) \(suffix)"
    }

    private var lastUpdatedDate: Date? {
        if metric == .bloodPressure {
            return store.bloodPressure.last(where: { $0.date >= weekStart })?.date
        }
        return scalarSeries.last?.date
    }

    private func updatedText(_ date: Date) -> String {
        let minutes = max(0, Int(Date().timeIntervalSince(date) / 60))
        if minutes < 1 { return "Just now" }
        if minutes < 60 { return "\(minutes)m ago" }
        if minutes < 1440 { return "\(minutes / 60)h ago" }
        return "\(minutes / 1440)d ago"
    }

    private func bloodPressureStatus(_ reading: BloodPressureReading) -> String {
        if reading.systolic >= 180 || reading.diastolic >= 120 { return "Severe" }
        if reading.systolic >= 140 || reading.diastolic >= 90 { return "Stage 2" }
        if reading.systolic >= 130 || reading.diastolic >= 80 { return "Stage 1" }
        if reading.systolic >= 120 { return "Elevated" }
        if reading.systolic < 90 || reading.diastolic < 60 { return "Low" }
        return "Normal"
    }

    private func bloodPressureColor(_ reading: BloodPressureReading) -> Color {
        switch bloodPressureStatus(reading) {
        case "Normal": return .mint
        case "Low": return .blue
        case "Elevated": return .yellow
        case "Stage 1": return .orange
        default: return .red
        }
    }
}

private extension TideMetric {
    var vitalsAccent: Color {
        switch self {
        case .heartRate: return Color(red: 1.00, green: 0.30, blue: 0.43)
        case .bloodOxygen: return Color(red: 0.30, green: 0.86, blue: 1.00)
        case .bloodPressure: return Color(red: 1.00, green: 0.42, blue: 0.62)
        case .hrv: return Color(red: 0.62, green: 0.49, blue: 1.00)
        case .stress: return Color(red: 1.00, green: 0.54, blue: 0.30)
        case .fatigue: return Color(red: 0.78, green: 0.49, blue: 1.00)
        case .bloodSugar: return Color(red: 1.00, green: 0.72, blue: 0.30)
        default: return tint
        }
    }
}

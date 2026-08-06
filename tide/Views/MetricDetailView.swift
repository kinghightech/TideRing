//
//  MetricDetailView.swift
//  Tide
//
//  Apple Health-style detail for one metric. The layout below each chart is ported from PulseLoop's
//  metric detail (stat tiles → reference zones → what this means), rendered in Tide's glass design.
//  Tide keeps its own charts (our graphs are cleaner) and adds a tucked-away, collapsible "Recent"
//  list at the bottom of the heart-rate and blood-pressure pages.
//
//  Range selectors: HR / SpO₂ / BP / steps / calories use Day/Week/Month; sleep uses Day/Week/Month/
//  Year with a hero score + hypnogram, mirroring PulseLoop's sleep screen.
//

import SwiftUI

enum RangeKey: String, CaseIterable, Identifiable {
    case day = "D", week = "W", month = "M"
    var id: String { rawValue }
    var days: Int { self == .day ? 1 : (self == .week ? 7 : 30) }
    var title: String { self == .day ? "Day" : (self == .week ? "Week" : "Month") }
}

struct MetricDetailView: View {
    let metric: TideMetric
    @ObservedObject var manager: RingManager
    @ObservedObject var store: RingStore

    var body: some View {
        ZStack {
            TideBackground()
            switch metric {
            case .bloodPressure: BloodPressureDetail(manager: manager, store: store)
            case .steps: StepsDetail(manager: manager, store: store)
            case .calories: CaloriesDetail(manager: manager, store: store)
            case .sleep: SleepDetail(manager: manager, store: store)
            default: ScalarDetail(metric: metric, manager: manager, store: store)
            }
        }
        .navigationTitle(metric.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Scalar metrics (HR, SpO₂, stress, HRV, temperature, fatigue, blood sugar)

private struct ScalarDetail: View {
    let metric: TideMetric
    @ObservedObject var manager: RingManager
    @ObservedObject var store: RingStore
    @State private var range: RangeKey = RangeKey(
        rawValue: ProcessInfo.processInfo.environment["TIDE_PREVIEW_RANGE"] ?? ""
    ) ?? .week

    private var series: [RingReading] {
        switch metric {
        case .heartRate: return store.heartRate
        case .bloodOxygen: return store.spo2
        default:
            guard let kind = metric.extraKind else { return [] }
            return store.extraMeasurements
                .filter { $0.kindRaw == kind.rawValue }
                .map { RingReading(id: $0.id, value: $0.value, date: $0.date, source: "") }
        }
    }

    private var canMeasure: Bool { manager.connectionState == .connected }
    private var zones: [MetricZone] { MetricReference.zones(for: metric, samples: series) }

    /// Values inside the currently-selected window.
    private var window: [RingReading] {
        let cal = Calendar.current
        let start = cal.date(byAdding: .day, value: -(range.days - 1), to: cal.startOfDay(for: Date())) ?? Date()
        return series.filter { $0.date >= start }.sorted { $0.date < $1.date }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                rangePicker
                chartCard
                statTiles
                if canMeasure { measureButton }
                if !zones.isEmpty { ReferenceZonesCard(zones: zones, highlight: window.last?.value) }
                WhatThisMeansCard(text: MetricReference.explainer(for: metric))
                recentCollapsible
            }
            .padding()
        }
    }

    private var rangePicker: some View {
        Picker("Range", selection: $range) {
            ForEach(RangeKey.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
    }

    private var chartCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                if let latest = series.max(by: { $0.date < $1.date }) {
                    HStack(alignment: .firstTextBaseline) {
                        BigValue(value: Fmt.number(latest.value), unit: metric.unit, tint: metric.tint)
                        Spacer()
                        Text(Fmt.relativeDay(latest.date) + " " + latest.date.formatted(.dateTime.hour().minute()))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if series.isEmpty {
                    emptyChart
                } else if range == .day {
                    let today = store.samples(series, onDay: Date())
                    if today.isEmpty {
                        emptyChart
                    } else {
                        DayPointChart(
                            samples: today,
                            tint: metric.tint,
                            yDomain: metric.detailChartDomain(values: today.map(\.value))
                        )
                    }
                } else {
                    let stats = store.dayStats(series, days: range.days)
                    if stats.contains(where: { $0.count > 0 }) {
                        RangeBarChart(
                            stats: stats,
                            tint: metric.tint,
                            preferredYDomain: metric == .bloodOxygen ? 85...100 : nil
                        )
                    } else {
                        emptyChart
                    }
                }
            }
            .padding()
        }
    }

    private var emptyChart: some View {
        Text("No readings in this period.")
            .font(.footnote).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 150)
    }

    private var statTiles: some View {
        let values = window.map(\.value)
        return StatTilesRow(
            latest: window.last.map { Fmt.number($0.value) } ?? "--",
            average: values.isEmpty ? "--" : Fmt.number(values.reduce(0, +) / Double(values.count)),
            min: values.min().map(Fmt.number) ?? "--",
            max: values.max().map(Fmt.number) ?? "--",
            tint: metric.tint
        )
    }

    @ViewBuilder private var measureButton: some View {
        if metric == .heartRate {
            if manager.isMeasuringHeartRate {
                Button { manager.stopHeartRate() } label: { measureLabel("Stop measuring", system: "stop.circle.fill") }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.roundedRectangle(radius: 16))
                    .tint(.red)
            } else {
                Button { manager.startHeartRate() } label: { measureLabel("Measure heart rate now", system: "heart.fill") }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.roundedRectangle(radius: 16))
                    .tint(metric.tint)
            }
        } else {
            Button { manager.measureVitals() } label: {
                measureLabel(
                    manager.isMeasuringVitals ? "Measuring…" : "Measure \(metric.title.lowercased()) now",
                    system: metric.icon
                )
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 16))
            .tint(metric.tint)
            .disabled(manager.isMeasuringVitals)
        }
    }

    private func measureLabel(_ text: String, system: String) -> some View {
        Label(text, systemImage: system)
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
    }

    @ViewBuilder private var recentCollapsible: some View {
        if !series.isEmpty {
            CollapsibleCard(title: "Recent readings") {
                VStack(spacing: 0) {
                    ForEach(Array(series.suffix(40).reversed())) { r in
                        HStack {
                            Text("\(Fmt.number(r.value)) \(metric.unit)").font(.subheadline.weight(.medium))
                            Spacer()
                            Text(r.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 7)
                        Divider().padding(.leading, 16)
                    }
                }
            }
        }
    }
}

extension TideMetric {
    func detailChartDomain(values: [Double]) -> ClosedRange<Double> {
        switch self {
        case .bloodOxygen:
            return 85...100
        case .stress, .fatigue:
            return 0...100
        case .temperature:
            return 30...42
        case .heartRate:
            return paddedDomain(values, minimumSpan: 30, fallback: 50...130, lowerBound: 30, upperBound: 220)
        case .hrv:
            return paddedDomain(values, minimumSpan: 30, fallback: 0...120, lowerBound: 0, upperBound: 300)
        case .bloodSugar:
            return paddedDomain(values, minimumSpan: 40, fallback: 60...180, lowerBound: 40, upperBound: 600)
        default:
            return paddedDomain(values, minimumSpan: 10, fallback: 0...100)
        }
    }

    private func paddedDomain(
        _ values: [Double],
        minimumSpan: Double,
        fallback: ClosedRange<Double>,
        lowerBound: Double? = nil,
        upperBound: Double? = nil
    ) -> ClosedRange<Double> {
        guard let minimum = values.min(), let maximum = values.max() else { return fallback }
        let center = (minimum + maximum) / 2
        let span = max(maximum - minimum, minimumSpan)
        var lower = center - span * 0.65
        var upper = center + span * 0.65
        if let lowerBound, lower < lowerBound {
            upper += lowerBound - lower
            lower = lowerBound
        }
        if let upperBound, upper > upperBound {
            lower -= upper - upperBound
            upper = upperBound
        }
        return lower...upper
    }
}

// MARK: - Blood pressure

private struct BloodPressureDetail: View {
    @ObservedObject var manager: RingManager
    @ObservedObject var store: RingStore
    @State private var range: RangeKey = .week

    private var window: [BloodPressureReading] {
        let cal = Calendar.current
        let start = cal.date(byAdding: .day, value: -(range.days - 1), to: cal.startOfDay(for: Date())) ?? Date()
        return store.bloodPressure.filter { $0.date >= start }.sorted { $0.date < $1.date }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Picker("Range", selection: $range) {
                    ForEach(RangeKey.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                chartCard
                statTiles

                if manager.connectionState == .connected {
                    Button { manager.measureBloodPressure() } label: {
                        Label(manager.isMeasuringVitals ? "Measuring…" : "Measure blood pressure now", systemImage: "waveform.path.ecg")
                            .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.roundedRectangle(radius: 16))
                    .tint(.purple)
                    .disabled(manager.isMeasuringVitals)
                }

                ReferenceZonesCard(zones: MetricReference.systolic,
                                   highlight: store.latestBloodPressure.map { Double($0.systolic) })
                WhatThisMeansCard(text: MetricReference.explainer(for: .bloodPressure))

                recentCollapsible
            }
            .padding()
        }
    }

    private var chartCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                if let bp = store.latestBloodPressure {
                    HStack(alignment: .firstTextBaseline) {
                        BigValue(value: "\(bp.systolic)/\(bp.diastolic)", unit: "mmHg", tint: .purple)
                        Spacer()
                        Text(categoryLabel(sys: bp.systolic, dia: bp.diastolic))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.purple)
                    }
                    Text(bp.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("No blood-pressure readings yet.").font(.footnote).foregroundStyle(.secondary)
                }
                if window.count >= 2 {
                    BloodPressureLineChart(readings: window)
                } else {
                    Text("Not enough data for this period.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 80)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }

    private var statTiles: some View {
        let sys = window.map { Double($0.systolic) }
        return VStack(spacing: 6) {
            Text("SYSTOLIC · mmHg").font(.caption2.weight(.semibold)).tracking(0.8)
                .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 4)
            StatTilesRow(
                latest: window.last.map { "\($0.systolic)" } ?? "--",
                average: sys.isEmpty ? "--" : "\(Int((sys.reduce(0, +) / Double(sys.count)).rounded()))",
                min: sys.min().map { "\(Int($0))" } ?? "--",
                max: sys.max().map { "\(Int($0))" } ?? "--",
                tint: .purple
            )
        }
    }

    @ViewBuilder private var recentCollapsible: some View {
        if !store.bloodPressure.isEmpty {
            CollapsibleCard(title: "Recent readings") {
                VStack(spacing: 0) {
                    ForEach(Array(store.bloodPressure.suffix(40).reversed())) { bp in
                        HStack {
                            Text("\(bp.systolic)/\(bp.diastolic) mmHg").font(.subheadline.weight(.medium))
                            Spacer()
                            Text(bp.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 7)
                        Divider().padding(.leading, 16)
                    }
                }
            }
        }
    }

    /// AHA "worse of the two axes" category, using the systolic/diastolic reference zones.
    private func categoryLabel(sys: Int, dia: Int) -> String {
        let sysZone = MetricReference.systolic.first { $0.contains(Double(sys)) }
        let diaZone = MetricReference.diastolic.first { $0.contains(Double(dia)) }
        func rank(_ label: String?) -> Int {
            switch label {
            case "Normal": return 0
            case "Low": return 1
            case "Elevated": return 2
            case "Stage 1": return 3
            case "Stage 2": return 4
            case "Severe": return 5
            default: return 0
            }
        }
        return (rank(sysZone?.label) >= rank(diaZone?.label) ? sysZone?.label : diaZone?.label) ?? ""
    }
}

// MARK: - Steps

private struct StepsDetail: View {
    @ObservedObject var manager: RingManager
    @ObservedObject var store: RingStore
    @State private var range: RangeKey = .week

    private var today: ActivityRecord? { store.todayActivityRecord() }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline) {
                            BigValue(value: Fmt.steps(today?.steps ?? 0), unit: "steps today", tint: .orange)
                            Spacer()
                            Text("Goal \(Fmt.steps(manager.settings.stepGoal))").font(.caption).foregroundStyle(.secondary)
                        }
                        if let a = today {
                            HStack(spacing: 18) {
                                Label(Fmt.distanceKm(a.distanceMeters), systemImage: "location.fill")
                                Label("\(Int(a.calories)) kcal", systemImage: "flame.fill")
                            }
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }

                Picker("Range", selection: $range) {
                    ForEach([RangeKey.week, .month]) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                GlassCard {
                    StepBarChart(stats: store.stepDays(range.days), goal: manager.settings.stepGoal)
                        .padding()
                }

                WhatThisMeansCard(text: MetricReference.explainer(for: .steps))
            }
            .padding()
        }
    }
}

// MARK: - Calories (active energy)

private struct CaloriesDetail: View {
    @ObservedObject var manager: RingManager
    @ObservedObject var store: RingStore
    @State private var range: RangeKey = .week

    private var weightKg: Int { manager.settings.weightKg }

    private var todayCalories: Double {
        guard let a = today else { return 0 }
        return ActiveEnergy.resolved(ringCalories: a.calories, steps: a.steps, weightKg: weightKg)
    }
    private var today: ActivityRecord? { store.todayActivityRecord() }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline) {
                            BigValue(value: Fmt.calories(todayCalories), unit: "kcal today", tint: TideMetric.calories.tint)
                            Spacer()
                            Text("Goal \(manager.settings.calorieGoal) kcal").font(.caption).foregroundStyle(.secondary)
                        }
                        if let a = today {
                            HStack(spacing: 18) {
                                Label(Fmt.steps(a.steps), systemImage: "figure.walk")
                                Label(Fmt.distanceKm(a.distanceMeters), systemImage: "location.fill")
                            }
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }

                Picker("Range", selection: $range) {
                    ForEach([RangeKey.week, .month]) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                GlassCard {
                    CalorieBarChart(stats: store.calorieDays(range.days, weightKg: weightKg),
                                    goal: manager.settings.calorieGoal,
                                    tint: TideMetric.calories.tint)
                        .padding()
                }

                WhatThisMeansCard(text: MetricReference.explainer(for: .calories))
            }
            .padding()
        }
    }
}

// MARK: - Sleep

private enum SleepRange: String, CaseIterable, Identifiable {
    case day = "D", week = "W", month = "M", year = "Y"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .day: return "Day"
        case .week: return "Week"
        case .month: return "Month"
        case .year: return "Year"
        }
    }
    var days: Int {
        switch self {
        case .day: return 1
        case .week: return 7
        case .month: return 30
        case .year: return 365
        }
    }
    var heroLabel: String {
        switch self {
        case .day: return "Last Sleep"
        case .week: return "Avg Weekly Sleep"
        case .month: return "Avg Monthly Sleep"
        case .year: return "Avg Yearly Sleep"
        }
    }
}

private struct SleepDetail: View {
    @ObservedObject var manager: RingManager
    @ObservedObject var store: RingStore
    @State private var range: SleepRange = .day

    /// Nights inside the selected window (excludes empty nights).
    private var windowNights: [SleepNight] {
        let cal = Calendar.current
        let start = cal.date(byAdding: .day, value: -(range.days - 1), to: cal.startOfDay(for: Date())) ?? Date()
        return store.sleepNights.filter { $0.id >= start && $0.timeInBedMinutes > 0 }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                rangePicker
                if range == .day {
                    dayView
                } else {
                    aggregateView
                }
                if manager.connectionState == .connected {
                    Button { manager.syncHistory() } label: {
                        Label(manager.syncProgress == nil ? "Sync sleep & history" : "Syncing…", systemImage: "arrow.triangle.2.circlepath")
                            .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .tint(.indigo)
                    .disabled(manager.syncProgress != nil)
                }
            }
            .padding()
        }
    }

    private var rangePicker: some View {
        Picker("Range", selection: $range) {
            ForEach(SleepRange.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
    }

    // MARK: Day

    @ViewBuilder private var dayView: some View {
        if let night = store.latestNight, night.timeInBedMinutes > 0 {
            let result = SleepScore.calculate(night)
            SleepHeroCard(
                label: range.heroLabel,
                // Time in bed, so the headline always matches the start–end range printed beneath it.
                duration: Fmt.duration(minutes: night.timeInBedMinutes),
                support: "\(night.start.formatted(.dateTime.hour().minute())) – \(night.end.formatted(.dateTime.hour().minute()))",
                score: result.score,
                quality: result.label.rawValue
            )
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("SLEEP ARCHITECTURE").font(.caption2.weight(.semibold)).tracking(1.0).foregroundStyle(.secondary)
                    SleepHypnogram(night: night)
                }
                .padding()
            }
            stageCards(deep: night.deepMinutes, light: night.lightMinutes, awake: night.awakeMinutes)
            WhatThisMeansCard(text: MetricReference.explainer(for: .sleep))
        } else {
            noData
        }
    }

    // MARK: Aggregate (Week / Month / Year)

    @ViewBuilder private var aggregateView: some View {
        let nights = windowNights
        if nights.count >= 2 {
            let avgDuration = nights.reduce(0) { $0 + $1.timeInBedMinutes } / nights.count
            let avgScore = Int((Double(nights.reduce(0) { $0 + SleepScore.calculate($1).score }) / Double(nights.count)).rounded())
            let deep = nights.reduce(0) { $0 + $1.deepMinutes } / nights.count
            let light = nights.reduce(0) { $0 + $1.lightMinutes } / nights.count
            let awake = nights.reduce(0) { $0 + $1.awakeMinutes } / nights.count
            SleepHeroCard(
                label: range.heroLabel,
                duration: Fmt.duration(minutes: avgDuration),
                support: "\(nights.count) nights tracked",
                score: avgScore,
                quality: SleepScore.qualityLabel(avgScore).rawValue
            )
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text(range == .year ? "MONTHLY AVERAGE" : "NIGHTLY SLEEP")
                        .font(.caption2.weight(.semibold)).tracking(1.0).foregroundStyle(.secondary)
                    SleepDurationChart(nights: nights, goalHours: manager.settings.sleepGoalHours)
                }
                .padding()
            }
            stageCards(prefix: "Avg ", deep: deep, light: light, awake: awake)
            WhatThisMeansCard(text: MetricReference.explainer(for: .sleep))
        } else {
            noData
        }
    }

    /// Deep / Light / Awake — the three stages this ring reports, matching PulseLoop's
    /// `SleepStageSummaryCardsView` (SleepView.swift:89-93). No REM (the hardware has none) and no
    /// Unmeasured (padding samples are discarded at decode now, so there is nothing to account for).
    private func stageCards(prefix: String = "", deep: Int, light: Int, awake: Int) -> some View {
        GlassCard {
            HStack(spacing: 0) {
                stage("\(prefix)Deep", Fmt.duration(minutes: deep), .indigo)
                stage("\(prefix)Light", Fmt.duration(minutes: light), .blue.opacity(0.7))
                stage("\(prefix)Awake", Fmt.duration(minutes: awake), .orange)
            }
            .padding(.vertical, 14).padding(.horizontal, 6)
        }
    }

    private func stage(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(spacing: 6) {
            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(label).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var noData: some View {
        GlassCard {
            VStack(spacing: 10) {
                Image(systemName: "bed.double.fill").font(.largeTitle).foregroundStyle(.indigo)
                Text(range == .day ? "No sleep recorded yet" : "Not enough nights yet").font(.headline)
                Text("Wear the ring overnight, then connect in the morning — it stores each night on-ring and syncs here. Awake time is captured from restlessness (finger movement) during the night.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding()
        }
    }
}

/// Sleep hero: duration on the left, a circular score badge on the right.
private struct SleepHeroCard: View {
    let label: String
    let duration: String
    let support: String
    let score: Int
    let quality: String

    var body: some View {
        GlassCard {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(label.uppercased()).font(.caption2.weight(.semibold)).tracking(1.0).foregroundStyle(.secondary)
                    Text(duration).font(.system(size: 34, weight: .bold, design: .rounded)).foregroundStyle(.indigo)
                    Text(support).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                SleepScoreBadge(score: score, quality: quality)
            }
            .padding()
        }
    }
}

private struct SleepScoreBadge: View {
    let score: Int
    let quality: String

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(.indigo.opacity(0.18), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: max(0.001, Double(score) / 100))
                    .stroke(Color.indigo, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(score)").font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(.primary)
            }
            .frame(width: 66, height: 66)
            Text(quality).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
        }
    }
}

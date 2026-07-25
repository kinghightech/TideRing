//
//  MetricCharts.swift
//  Tide
//
//  Reusable Swift Charts building blocks, styled after Apple Health: daily min–max range bars,
//  intraday point/line charts, step bars, and a sleep hypnogram.
//

import Charts
import SwiftUI

/// Daily min–max range bars (Apple Health's heart-rate style). Empty days render nothing.
struct RangeBarChart: View {
    let stats: [DayStat]
    var tint: Color = .pink
    var height: CGFloat = 180
    var preferredYDomain: ClosedRange<Double>? = nil
    var interactive = true

    @State private var selectedDate: Date?

    private var populated: [DayStat] { stats.filter { $0.count > 0 } }
    private var selectedStat: DayStat? {
        guard let selectedDate else { return nil }
        return populated.min { abs($0.day.timeIntervalSince(selectedDate)) < abs($1.day.timeIntervalSince(selectedDate)) }
    }

    @ViewBuilder
    var body: some View {
        if interactive {
            chart.chartXSelection(value: $selectedDate)
        } else {
            chart
        }
    }

    private var chart: some View {
        Chart {
            ForEach(populated) { stat in
                BarMark(
                    x: .value("Day", stat.day, unit: .day),
                    yStart: .value("Min", stat.min),
                    yEnd: .value("Max", max(stat.max, stat.min + 0.6)),
                    width: .fixed(populated.count > 20 ? 5 : 9)
                )
                .foregroundStyle(tint.gradient)
                .clipShape(Capsule())
            }
            if let selectedStat {
                RuleMark(x: .value("Selected", selectedStat.day, unit: .day))
                    .foregroundStyle(.secondary.opacity(0.7))
                    .annotation(
                        position: .top,
                        spacing: 6,
                        overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                    ) {
                        ChartCallout(
                            title: "\(Fmt.number(selectedStat.min))–\(Fmt.number(selectedStat.max))",
                            subtitle: selectedStat.day.formatted(.dateTime.month(.abbreviated).day())
                        )
                    }
            }
        }
        .chartYScale(domain: resolvedYDomain)
        .chartXAxis {
            AxisMarks(values: .stride(by: xStride)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
            }
        }
        .frame(height: height)
    }

    private var xStride: Calendar.Component { stats.count > 10 ? .weekOfYear : .day }

    private var resolvedYDomain: ClosedRange<Double> {
        if let preferredYDomain { return preferredYDomain }
        let mins = populated.map(\.min)
        let maxs = populated.map(\.max)
        guard let lo = mins.min(), let hi = maxs.max() else { return 0...1 }
        if hi == lo {
            let pad = max(abs(lo) * 0.08, 2)
            return (lo - pad)...(hi + pad)
        }
        let pad = (hi - lo) * 0.15 + 2
        return (lo - pad)...(hi + pad)
    }
}

/// Intraday scatter/line for a single day's samples.
struct DayPointChart: View {
    let samples: [RingReading]
    var tint: Color = .pink
    var height: CGFloat = 180
    var yDomain: ClosedRange<Double>

    @State private var selectedDate: Date?

    private var selectedSample: RingReading? {
        guard let selectedDate else { return nil }
        return samples.min { abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate)) }
    }

    var body: some View {
        Chart {
            ForEach(samples) { sample in
                LineMark(x: .value("Time", sample.date), y: .value("Value", sample.value))
                    .foregroundStyle(tint.opacity(0.35))
                    .interpolationMethod(.catmullRom)
                PointMark(x: .value("Time", sample.date), y: .value("Value", sample.value))
                    .foregroundStyle(tint.gradient)
                    .symbolSize(28)
            }
            if let selectedSample {
                RuleMark(x: .value("Selected", selectedSample.date))
                    .foregroundStyle(.secondary.opacity(0.7))
                PointMark(x: .value("Time", selectedSample.date), y: .value("Value", selectedSample.value))
                    .foregroundStyle(tint)
                    .symbolSize(85)
                    .annotation(
                        position: .top,
                        spacing: 6,
                        overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                    ) {
                        ChartCallout(
                            title: Fmt.number(selectedSample.value),
                            subtitle: selectedSample.date.formatted(.dateTime.hour().minute())
                        )
                    }
            }
        }
        .chartXScale(domain: dayDomain)
        .chartYScale(domain: yDomain)
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour())
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4))
        }
        .chartXSelection(value: $selectedDate)
        .frame(height: height)
    }

    private var dayDomain: ClosedRange<Date> {
        let calendar = Calendar.current
        let day = samples.first?.date ?? Date()
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start)?.addingTimeInterval(-1) ?? day
        return start...end
    }
}

/// Per-day step bars.
struct StepBarChart: View {
    let stats: [DayStat]
    var goal: Int = 10_000
    var height: CGFloat = 180
    var interactive = true

    @State private var selectedDate: Date?
    private var selectedStat: DayStat? {
        guard let selectedDate else { return nil }
        return stats.min { abs($0.day.timeIntervalSince(selectedDate)) < abs($1.day.timeIntervalSince(selectedDate)) }
    }

    @ViewBuilder
    var body: some View {
        if interactive { chart.chartXSelection(value: $selectedDate) } else { chart }
    }

    private var chart: some View {
        Chart {
            ForEach(stats) { stat in
                BarMark(
                    x: .value("Day", stat.day, unit: .day),
                    y: .value("Steps", stat.last)
                )
                .foregroundStyle(stat.last >= Double(goal) ? Color.green.gradient : Color.orange.gradient)
                .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            RuleMark(y: .value("Goal", Double(goal)))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .foregroundStyle(.secondary.opacity(0.5))
            if let selectedStat {
                RuleMark(x: .value("Selected", selectedStat.day, unit: .day))
                    .foregroundStyle(.secondary.opacity(0.75))
                    .annotation(
                        position: .top,
                        spacing: 6,
                        overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                    ) {
                        ChartCallout(
                            eyebrow: "TOTAL",
                            title: "\(Fmt.steps(Int(selectedStat.last))) steps",
                            subtitle: selectedStat.day.formatted(.dateTime.month(.abbreviated).day().year())
                        )
                    }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: stats.count > 10 ? .weekOfYear : .day)) { value in
                AxisGridLine()
                if let date = value.as(Date.self) {
                    AxisValueLabel {
                        Text(stats.count <= 7
                             ? date.formatted(.dateTime.weekday(.abbreviated))
                             : date.formatted(.dateTime.month(.abbreviated).day()))
                    }
                }
            }
        }
        .frame(height: height)
    }
}

/// Per-day active-calorie bars with a goal rule line (mirrors the step chart).
struct CalorieBarChart: View {
    let stats: [DayStat]
    var goal: Int = 500
    var tint: Color = Color(red: 1.0, green: 0.45, blue: 0.3)
    var height: CGFloat = 180
    var interactive = true

    @State private var selectedDate: Date?
    private var selectedStat: DayStat? {
        guard let selectedDate else { return nil }
        return stats.min { abs($0.day.timeIntervalSince(selectedDate)) < abs($1.day.timeIntervalSince(selectedDate)) }
    }

    @ViewBuilder
    var body: some View {
        if interactive { chart.chartXSelection(value: $selectedDate) } else { chart }
    }

    private var chart: some View {
        Chart {
            ForEach(stats) { stat in
                BarMark(
                    x: .value("Day", stat.day, unit: .day),
                    y: .value("Calories", stat.last)
                )
                .foregroundStyle(stat.last >= Double(goal) ? Color.green.gradient : tint.gradient)
                .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            if goal > 0 {
                RuleMark(y: .value("Goal", Double(goal)))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(.secondary.opacity(0.5))
            }
            if let selectedStat {
                RuleMark(x: .value("Selected", selectedStat.day, unit: .day))
                    .foregroundStyle(.secondary.opacity(0.75))
                    .annotation(
                        position: .top,
                        spacing: 6,
                        overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                    ) {
                        ChartCallout(
                            eyebrow: "ACTIVE ENERGY",
                            title: "\(Fmt.number(selectedStat.last)) kcal",
                            subtitle: selectedStat.day.formatted(.dateTime.month(.abbreviated).day().year())
                        )
                    }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: stats.count > 10 ? .weekOfYear : .day)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
            }
        }
        .frame(height: height)
    }
}

/// Two-series blood-pressure line chart (systolic + diastolic), styled after PulseLoop's BP detail.
struct BloodPressureLineChart: View {
    /// Chronological readings to plot.
    let readings: [BloodPressureReading]
    var tint: Color = .purple
    var height: CGFloat = 200

    @State private var selectedDate: Date?
    private var selectedReading: BloodPressureReading? {
        guard let selectedDate else { return nil }
        return readings.min { abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate)) }
    }

    var body: some View {
        Chart {
            ForEach(readings) { r in
                LineMark(x: .value("Time", r.date), y: .value("Systolic", r.systolic),
                         series: .value("Series", "Systolic"))
                    .foregroundStyle(tint)
                    .interpolationMethod(.monotone)
                PointMark(x: .value("Time", r.date), y: .value("Systolic", r.systolic))
                    .foregroundStyle(tint).symbolSize(20)
            }
            ForEach(readings) { r in
                LineMark(x: .value("Time", r.date), y: .value("Diastolic", r.diastolic),
                         series: .value("Series", "Diastolic"))
                    .foregroundStyle(tint.opacity(0.5))
                    .interpolationMethod(.monotone)
                PointMark(x: .value("Time", r.date), y: .value("Diastolic", r.diastolic))
                    .foregroundStyle(tint.opacity(0.5)).symbolSize(20)
            }
            if let selectedReading {
                RuleMark(x: .value("Selected", selectedReading.date))
                    .foregroundStyle(.secondary.opacity(0.75))
                    .annotation(
                        position: .top,
                        spacing: 6,
                        overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                    ) {
                        ChartCallout(
                            title: "\(selectedReading.systolic)/\(selectedReading.diastolic) mmHg",
                            subtitle: selectedReading.date.formatted(date: .abbreviated, time: .shortened)
                        )
                    }
            }
        }
        .chartYScale(domain: yDomain)
        .chartXSelection(value: $selectedDate)
        .frame(height: height)
    }

    private var yDomain: ClosedRange<Double> {
        let values = readings.flatMap { [Double($0.systolic), Double($0.diastolic)] }
        guard let lo = values.min(), let hi = values.max() else { return 40...160 }
        return (lo - 10)...(hi + 10)
    }
}

/// A sleep hypnogram: proportional colored segments for one night, plus a compact stage legend.
struct SleepHypnogram: View {
    let night: SleepNight
    @State private var selectedIndex: Int?

    private var selectedBlock: SleepBlock? {
        guard let selectedIndex, night.blocks.indices.contains(selectedIndex) else { return nil }
        return night.blocks[selectedIndex]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let selectedBlock {
                ChartCallout(
                    title: stageLabel(selectedBlock.stage),
                    subtitle: selectedBlock.start.formatted(.dateTime.hour().minute())
                )
            }

            GeometryReader { geo in
                HStack(spacing: 0) {
                    ForEach(Array(night.blocks.enumerated()), id: \.element.id) { index, block in
                        Rectangle()
                            .fill(color(for: block.stage))
                            .opacity(selectedIndex == nil || selectedIndex == index ? 1 : 0.45)
                            .frame(width: max(1, geo.size.width / CGFloat(max(night.blocks.count, 1))))
                            .overlay {
                                if selectedIndex == index {
                                    Rectangle().stroke(.white, lineWidth: 2)
                                }
                            }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard !night.blocks.isEmpty, geo.size.width > 0 else { return }
                            let fraction = min(max(value.location.x / geo.size.width, 0), 0.9999)
                            selectedIndex = min(Int(fraction * CGFloat(night.blocks.count)), night.blocks.count - 1)
                        }
                )
            }
            .frame(height: 46)

            HStack {
                Text(night.start.formatted(.dateTime.hour().minute()))
                Spacer()
                Text(night.end.formatted(.dateTime.hour().minute()))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            HStack(spacing: 14) {
                legend(.deep, "Deep")
                legend(.light, "Light")
                legend(.rem, "REM")
                legend(.awake, "Awake")
            }
        }
    }

    private func legend(_ stage: SleepStage, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color(for: stage)).frame(width: 8, height: 8)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func stageLabel(_ stage: SleepStage) -> String {
        switch stage {
        case .deep: return "Deep sleep"
        case .light: return "Light sleep"
        case .rem: return "REM sleep"
        case .awake: return "Awake"
        case .unknown: return "Unknown"
        }
    }

    static func color(for stage: SleepStage) -> Color {
        switch stage {
        case .deep: return .indigo
        case .light: return .blue.opacity(0.7)
        case .rem: return .teal
        case .awake: return .orange
        case .unknown: return .gray.opacity(0.4)
        }
    }

    private func color(for stage: SleepStage) -> Color { Self.color(for: stage) }
}

/// Nightly sleep-duration bars across recent nights, with an optional goal rule line.
struct SleepDurationChart: View {
    let nights: [SleepNight]
    var goalHours: Double? = nil
    var height: CGFloat = 180
    var interactive = true

    @State private var selectedDate: Date?
    private var selectedNight: SleepNight? {
        guard let selectedDate else { return nil }
        return nights.min { abs($0.id.timeIntervalSince(selectedDate)) < abs($1.id.timeIntervalSince(selectedDate)) }
    }

    @ViewBuilder
    var body: some View {
        if interactive { chart.chartXSelection(value: $selectedDate) } else { chart }
    }

    private var chart: some View {
        Chart {
            ForEach(nights) { night in
                BarMark(
                    x: .value("Night", night.id, unit: .day),
                    y: .value("Hours", Double(night.asleepMinutes) / 60)
                )
                .foregroundStyle(Color.indigo.gradient)
                .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            if let goalHours, goalHours > 0 {
                RuleMark(y: .value("Goal", goalHours))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(.secondary.opacity(0.5))
            }
            if let selectedNight {
                RuleMark(x: .value("Selected", selectedNight.id, unit: .day))
                    .foregroundStyle(.secondary.opacity(0.75))
                    .annotation(
                        position: .top,
                        spacing: 6,
                        overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                    ) {
                        ChartCallout(
                            title: Fmt.duration(minutes: selectedNight.asleepMinutes),
                            subtitle: selectedNight.id.formatted(.dateTime.month(.abbreviated).day())
                        )
                    }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: nights.count > 10 ? .weekOfYear : .day)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
            }
        }
        .frame(height: height)
    }
}

private struct ChartCallout: View {
    var eyebrow: String? = nil
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let eyebrow {
                Text(eyebrow).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
            Text(title).font(.subheadline.weight(.bold)).foregroundStyle(.primary)
            Text(subtitle).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }
}

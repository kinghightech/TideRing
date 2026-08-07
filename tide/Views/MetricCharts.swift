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
    /// Width of the visible window. The ring logs every ~30 min and sends history readings in pairs
    /// 60 s apart, so a whole day crammed into ~330 pt collapses into unreadable clumps. Pinching
    /// narrows this; dragging scrolls through the day.
    @State private var visibleSeconds: TimeInterval = fullDaySeconds
    @State private var scrollPosition = Date()
    /// Window width when the current pinch began, so magnification stays proportional mid-gesture.
    @State private var zoomBase: TimeInterval?

    private static let fullDaySeconds: TimeInterval = 24 * 3600
    private static let minimumWindow: TimeInterval = 3600
    /// Longest silence the line may span. Beyond this the ring simply wasn't reporting, and joining
    /// the dots would invent readings that never happened. Matches PulseLoop's 24 h rule
    /// (`ChartSample.maxGap`).
    private static let maximumLineGap: TimeInterval = 90 * 60

    private var selectedSample: RingReading? {
        guard let selectedDate else { return nil }
        return samples.min { abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate)) }
    }

    /// Samples split into runs of continuous coverage, so the line breaks across data gaps.
    private var segments: [[RingReading]] {
        var result: [[RingReading]] = []
        for sample in samples.sorted(by: { $0.date < $1.date }) {
            if let last = result.last?.last,
               sample.date.timeIntervalSince(last.date) <= Self.maximumLineGap {
                result[result.count - 1].append(sample)
            } else {
                result.append([sample])
            }
        }
        return result
    }

    private var isZoomedIn: Bool { visibleSeconds < Self.fullDaySeconds - 1 }

    var body: some View {
        Chart {
            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                ForEach(segment) { sample in
                    LineMark(
                        x: .value("Time", sample.date),
                        y: .value("Value", sample.value),
                        series: .value("Segment", index)
                    )
                    .foregroundStyle(tint.opacity(0.35))
                    // Monotone, not catmullRom: the latter overshoots between noisy readings and
                    // draws peaks and dips the ring never measured.
                    .interpolationMethod(.monotone)
                }
            }
            ForEach(samples) { sample in
                PointMark(x: .value("Time", sample.date), y: .value("Value", sample.value))
                    .foregroundStyle(tint.gradient)
                    .symbolSize(isZoomedIn ? 40 : 22)
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
            AxisMarks(values: .stride(by: .hour, count: axisStrideHours)) { _ in
                AxisGridLine()
                AxisValueLabel(
                    format: visibleSeconds <= 6 * 3600
                        ? .dateTime.hour().minute()
                        : .dateTime.hour()
                )
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4))
        }
        .chartScrollableAxes(.horizontal)
        .chartXVisibleDomain(length: visibleSeconds)
        .chartScrollPosition(x: $scrollPosition)
        .chartXSelection(value: $selectedDate)
        .frame(height: height)
        .simultaneousGesture(zoomGesture)
        .onAppear { scrollPosition = dayDomain.lowerBound }
    }

    /// Pinch to change the window between one hour and the full day, keeping whatever is currently
    /// centred under the fingers rather than snapping back to midnight.
    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let base = zoomBase ?? visibleSeconds
                if zoomBase == nil { zoomBase = visibleSeconds }
                let centre = scrollPosition.addingTimeInterval(visibleSeconds / 2)
                let updated = min(Self.fullDaySeconds, max(Self.minimumWindow, base / value.magnification))
                visibleSeconds = updated
                scrollPosition = clampedStart(centring: centre, window: updated)
            }
            .onEnded { _ in zoomBase = nil }
    }

    /// Keep the visible window inside the day, so zooming near midnight or midday can't scroll past
    /// either edge and leave the plot half empty.
    private func clampedStart(centring centre: Date, window: TimeInterval) -> Date {
        let domain = dayDomain
        let latestStart = domain.upperBound.addingTimeInterval(-window)
        guard latestStart > domain.lowerBound else { return domain.lowerBound }
        let proposed = centre.addingTimeInterval(-window / 2)
        return min(max(proposed, domain.lowerBound), latestStart)
    }

    /// Roughly four labels across the window at any zoom level.
    private var axisStrideHours: Int {
        let hours = visibleSeconds / 3600
        switch hours {
        case ..<3: return 1
        case ..<7: return 2
        case ..<13: return 3
        default: return 6
        }
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

/// A sleep hypnogram: time-proportional colored segments for one night, plus a compact stage legend.
///
/// Drawn with Swift Charts rather than a hand-laid-out `HStack`. Sleep is stored one block per
/// minute, so a full night is ~480 blocks; the previous layout gave each block a 1 pt *minimum*
/// width, which made the bar wider than the card it lived in for any night over ~5 h 29 m — it ran
/// off the trailing edge of the screen, and the drag math (which divided by the container width,
/// not the bar's real width) could only ever reach the first ~69 % of the night. Charts clips to
/// its plot area and positions marks by time, so the bar cannot overflow, segments are proportional
/// to their real duration, and minutes the ring never reported render as visible gaps.
struct SleepHypnogram: View {
    let night: SleepNight
    @State private var selectedDate: Date?

    /// Consecutive one-minute blocks of the same stage collapsed into a single run — ~30-60 marks
    /// per night instead of ~480. Mirrors PulseLoop's run-length pass (PulseEventBus.swift:429-443).
    /// A break of a minute or more starts a new run, which is what makes data gaps visible.
    private struct StageRun: Identifiable {
        let stage: SleepStage
        let start: Date
        var end: Date
        var id: Date { start }
    }

    private var runs: [StageRun] {
        var result: [StageRun] = []
        // Unknown samples are stored (they count toward the session's span) but never drawn —
        // PulseLoop's `sortedBlocks` filter, Charts.swift:451.
        let drawable = night.blocks.filter { $0.minutes > 0 && $0.stage != .unknown }
        for block in drawable.sorted(by: { $0.start < $1.start }) {
            let end = block.start.addingTimeInterval(TimeInterval(block.minutes * 60))
            if let last = result.last,
               last.stage == block.stage,
               block.start.timeIntervalSince(last.end) < 1 {
                result[result.count - 1].end = max(last.end, end)
            } else {
                result.append(StageRun(stage: block.stage, start: block.start, end: end))
            }
        }
        return result
    }

    private var selectedRun: StageRun? {
        guard let selectedDate else { return nil }
        return runs.first { selectedDate >= $0.start && selectedDate < $0.end }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let selectedRun {
                let minutes = Int(selectedRun.end.timeIntervalSince(selectedRun.start) / 60)
                ChartCallout(
                    title: stageLabel(selectedRun.stage),
                    subtitle: "\(selectedRun.start.formatted(.dateTime.hour().minute())) · \(Fmt.sleepDuration(minutes: minutes))"
                )
            }

            if runs.isEmpty || night.end <= night.start {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.secondary.opacity(0.15))
                    .frame(height: 46)
            } else {
                Chart {
                    ForEach(runs) { run in
                        RectangleMark(
                            xStart: .value("Start", run.start),
                            xEnd: .value("End", run.end),
                            yStart: .value("Bottom", 0),
                            yEnd: .value("Top", 1)
                        )
                        .foregroundStyle(Self.color(for: run.stage))
                        .opacity(selectedRun == nil || selectedRun?.id == run.id ? 1 : 0.45)
                    }
                    if let selectedRun {
                        RuleMark(x: .value("Selected", selectedRun.start))
                            .lineStyle(StrokeStyle(lineWidth: 2))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                }
                .chartXScale(domain: night.start...night.end)
                .chartYScale(domain: 0...1)
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartPlotStyle { $0.clipShape(RoundedRectangle(cornerRadius: 6)) }
                .chartXSelection(value: $selectedDate)
                .frame(height: 46)
            }

            HStack {
                Text(night.start.formatted(.dateTime.hour().minute()))
                Spacer()
                Text(night.end.formatted(.dateTime.hour().minute()))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            // No REM entry: this ring reports light/deep/awake only, so the swatch was always dead.
            HStack(spacing: 14) {
                legend(.deep, "Deep")
                legend(.light, "Light")
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
                    // Time in bed, so these bars agree with the Sleep detail headline.
                    y: .value("Hours", Double(night.timeInBedMinutes) / 60)
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
                            title: Fmt.sleepDuration(minutes: selectedNight.timeInBedMinutes),
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

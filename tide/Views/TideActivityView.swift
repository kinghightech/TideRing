//
//  TideActivityView.swift
//  Tide
//
//  Activity dashboard modeled after PulseLoop's daily summary rings, weekly goal card, and
//  combined activity trends. PulseLoop by Saksham Bhutani, CC BY 4.0.
//

import Charts
import SwiftUI

struct TideActivityView: View {
    @ObservedObject var manager: RingManager
    @ObservedObject var store: RingStore

    private var todayActivity: ActivityRecord? {
        store.todayActivityRecord()
    }

    private var todayCalories: Double? {
        guard let activity = todayActivity else { return nil }
        return ActiveEnergy.resolved(
            ringCalories: activity.calories,
            steps: activity.steps,
            weightKg: manager.settings.weightKg
        )
    }

    private var distanceGoalMeters: Double {
        // Tide currently stores a step goal, not a separate distance goal. Keep the distance ring
        // tied to that same target using the ring's standard walking-distance approximation.
        Double(manager.settings.stepGoal) * 0.75
    }

    var body: some View {
        NavigationStack {
            ZStack {
                TideBackground()
                ScrollView {
                    VStack(spacing: 16) {
                        NavigationLink {
                            TideActivityTrendsView(manager: manager, store: store)
                        } label: {
                            TideDailyActivitySummaryCard(
                                activity: todayActivity,
                                calories: todayCalories,
                                stepGoal: manager.settings.stepGoal,
                                distanceGoalMeters: distanceGoalMeters,
                                calorieGoal: manager.settings.calorieGoal
                            )
                        }
                        .buttonStyle(.plain)

                        todayCard
                        weeklyGoalCard
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 40)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var todayCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TODAY")
                .font(TideFont.sans(11, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(.secondary)

            if let activity = todayActivity {
                HStack(spacing: 0) {
                    todayMetric(
                        icon: "figure.walk",
                        value: activity.steps.formatted(),
                        label: "Steps",
                        color: ActivityPalette.steps
                    )
                    todayMetric(
                        icon: "location.fill",
                        value: Fmt.distanceKm(activity.distanceMeters),
                        label: "Distance",
                        color: ActivityPalette.distance
                    )
                    todayMetric(
                        icon: "flame.fill",
                        value: todayCalories.map { Fmt.calories($0) } ?? "—",
                        label: "Calories",
                        color: ActivityPalette.calories
                    )
                }
                .padding(.vertical, 18)
                .activityGlass()
            } else {
                VStack(spacing: 5) {
                    Text("No activity synced today")
                        .font(TideFont.sans(15, weight: .semibold))
                    Text("Your steps, distance, and calories will appear after the ring syncs.")
                        .font(TideFont.sans(12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
                .activityGlass()
            }
        }
    }

    private func todayMetric(icon: String, value: String, label: String, color: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(color)
            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            Text(label.uppercased())
                .font(TideFont.sans(9, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var weeklyGoalCard: some View {
        let days = currentWeekDays
        let completed = days.filter(\.completed).count
        let todaySteps = Double(todayActivity?.steps ?? 0)

        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                TideProgressRing(
                    progress: manager.settings.stepGoal > 0
                        ? todaySteps / Double(manager.settings.stepGoal)
                        : 0,
                    color: ActivityPalette.steps,
                    size: 72,
                    stroke: 8
                ) {
                    VStack(spacing: 0) {
                        Text(Fmt.steps(Int(todaySteps)))
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text("STEPS")
                            .font(TideFont.sans(8, weight: .semibold))
                            .tracking(0.8)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("WEEKLY GOAL")
                        .font(TideFont.sans(11, weight: .semibold))
                        .tracking(1.4)
                        .foregroundStyle(.secondary)
                    Text("\(completed) of 7 active days")
                        .font(TideFont.sans(16, weight: .medium))
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                ForEach(days) { day in
                    VStack(spacing: 7) {
                        Text(day.label)
                            .font(TideFont.sans(10, weight: .semibold))
                            .foregroundStyle(day.isToday ? .primary : .secondary)
                        Circle()
                            .fill(day.completed ? ActivityPalette.steps : Color.secondary.opacity(0.16))
                            .frame(width: 28, height: 28)
                            .overlay {
                                if day.completed {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(.black.opacity(0.72))
                                } else if day.isToday {
                                    Circle().stroke(ActivityPalette.steps, lineWidth: 1.5)
                                }
                            }
                    }
                    .frame(maxWidth: .infinity)
                }
            }

            Text("A day is complete when you reach \(manager.settings.stepGoal.formatted()) steps.")
                .font(TideFont.sans(10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .activityGlass()
    }

    private var currentWeekDays: [ActivityWeekDay] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let weekday = calendar.component(.weekday, from: today)
        let daysSinceMonday = (weekday + 5) % 7
        let monday = calendar.date(byAdding: .day, value: -daysSinceMonday, to: today) ?? today
        let byDay = Dictionary(uniqueKeysWithValues: store.dailyActivity.map {
            (calendar.startOfDay(for: $0.day), $0.steps)
        })
        let labels = ["M", "T", "W", "T", "F", "S", "S"]

        return (0..<7).compactMap { index in
            guard let day = calendar.date(byAdding: .day, value: index, to: monday) else { return nil }
            return ActivityWeekDay(
                id: day,
                label: labels[index],
                completed: (byDay[day] ?? 0) >= manager.settings.stepGoal,
                isToday: calendar.isDate(day, inSameDayAs: today)
            )
        }
    }
}

private struct TideDailyActivitySummaryCard: View {
    let activity: ActivityRecord?
    let calories: Double?
    let stepGoal: Int
    let distanceGoalMeters: Double
    let calorieGoal: Int

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 12) {
                    metric(
                        label: "Steps",
                        value: activity?.steps.formatted() ?? "—",
                        unit: nil,
                        color: ActivityPalette.steps
                    )
                    metric(
                        label: "Distance",
                        value: activity.map { distanceValue($0.distanceMeters) } ?? "—",
                        unit: activity == nil ? nil : "km",
                        color: ActivityPalette.distance
                    )
                }
                metric(
                    label: "Calories",
                    value: calories.map(Fmt.calories) ?? "—",
                    unit: calories == nil ? nil : "cal",
                    color: ActivityPalette.calories
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            TideActivityRings(
                rings: [
                    .init(value: activity.map { Double($0.steps) }, goal: Double(stepGoal), color: ActivityPalette.steps),
                    .init(value: activity?.distanceMeters, goal: distanceGoalMeters, color: ActivityPalette.distance),
                    .init(value: calories, goal: Double(calorieGoal), color: ActivityPalette.calories)
                ]
            )
            .frame(width: 112, height: 112)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .activityGlass(interactive: true)
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func metric(label: String, value: String, unit: String?, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased())
                .font(TideFont.sans(13, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(color)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.35)
                if let unit {
                    Text(unit).font(TideFont.sans(12)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func distanceValue(_ meters: Double) -> String {
        String(format: meters >= 10_000 ? "%.0f" : "%.1f", meters / 1000)
    }
}

private struct TideActivityTrendsView: View {
    @ObservedObject var manager: RingManager
    @ObservedObject var store: RingStore
    @State private var range: RangeKey = .week

    private var days: Int { range == .week ? 7 : 30 }
    private var distanceGoal: Double { Double(manager.settings.stepGoal) * 0.75 }

    var body: some View {
        ZStack {
            TideBackground()
            ScrollView {
                VStack(spacing: 14) {
                    Picker("Period", selection: $range) {
                        Text("Week").tag(RangeKey.week)
                        Text("Month").tag(RangeKey.month)
                    }
                    .pickerStyle(.segmented)

                    trendSection(
                        title: "Steps",
                        color: ActivityPalette.steps,
                        stats: store.stepDays(days),
                        goal: Double(manager.settings.stepGoal),
                        unit: "steps/day"
                    )
                    trendSection(
                        title: "Distance",
                        color: ActivityPalette.distance,
                        stats: distanceStats,
                        goal: distanceGoal,
                        unit: "m/day"
                    )
                    trendSection(
                        title: "Calories",
                        color: ActivityPalette.calories,
                        stats: store.calorieDays(days, weightKg: manager.settings.weightKg),
                        goal: Double(manager.settings.calorieGoal),
                        unit: "cal/day"
                    )
                }
                .padding(16)
                .padding(.bottom, 32)
            }
        }
        .navigationTitle("Activity Trends")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }

    private func trendSection(
        title: String,
        color: Color,
        stats: [DayStat],
        goal: Double,
        unit: String
    ) -> some View {
        let populated = stats.filter { $0.count > 0 }
        let average = populated.isEmpty
            ? nil
            : populated.map(\.last).reduce(0, +) / Double(populated.count)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(TideFont.sans(20, weight: .bold))
                    .foregroundStyle(color)
                Spacer()
                Text(average.map { "\(Fmt.number($0)) \(unit)" } ?? "— /day")
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(average == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            ActivityGoalBarChart(stats: stats, goal: goal, color: color)
                .frame(height: 112)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .activityGlass()
    }

    private var distanceStats: [DayStat] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(
            for: calendar.date(byAdding: .day, value: -(days - 1), to: Date()) ?? Date()
        )
        let byDay = Dictionary(uniqueKeysWithValues: store.dailyActivity.map {
            (calendar.startOfDay(for: $0.day), $0)
        })
        return (0..<days).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            let value = byDay[day]?.distanceMeters ?? 0
            return DayStat(
                id: day,
                day: day,
                min: 0,
                max: value,
                avg: value,
                count: byDay[day] == nil ? 0 : 1,
                last: value
            )
        }
    }
}

private struct ActivityGoalBarChart: View {
    let stats: [DayStat]
    let goal: Double
    let color: Color

    var body: some View {
        Chart {
            ForEach(stats) { stat in
                BarMark(
                    x: .value("Day", stat.day, unit: .day),
                    y: .value("Total", stat.last)
                )
                .foregroundStyle(stat.last >= goal && goal > 0 ? color : color.opacity(0.48))
                .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            if goal > 0 {
                RuleMark(y: .value("Goal", goal))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(color.opacity(0.7))
                    .annotation(position: .top, alignment: .trailing) {
                        Text("GOAL")
                            .font(TideFont.sans(8, weight: .semibold))
                            .foregroundStyle(color)
                    }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: stats.count > 10 ? .weekOfYear : .day)) { value in
                AxisGridLine().foregroundStyle(.clear)
                if let date = value.as(Date.self) {
                    AxisValueLabel {
                        Text(stats.count <= 7
                             ? date.formatted(.dateTime.weekday(.narrow))
                             : date.formatted(.dateTime.day()))
                    }
                }
            }
        }
        .chartYAxis(.hidden)
    }
}

private struct ActivityWeekDay: Identifiable {
    let id: Date
    let label: String
    let completed: Bool
    let isToday: Bool
}

private struct TideActivityRing {
    let value: Double?
    let goal: Double
    let color: Color

    var progress: Double {
        guard let value, goal > 0 else { return 0 }
        return min(1, max(0, value / goal))
    }
}

private struct TideActivityRings: View {
    let rings: [TideActivityRing]
    var size: CGFloat = 112
    var stroke: CGFloat = 10
    var spacing: CGFloat = 5

    var body: some View {
        ZStack {
            ForEach(Array(rings.enumerated()), id: \.offset) { index, ring in
                let inset = CGFloat(index) * (stroke + spacing)
                let ringSize = size - inset * 2
                ZStack {
                    Circle().stroke(Color.secondary.opacity(0.14), lineWidth: stroke)
                    Circle()
                        .trim(from: 0, to: ring.progress)
                        .stroke(ring.color, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: ringSize, height: ringSize)
            }
        }
        .frame(width: size, height: size)
    }
}

private struct TideProgressRing<Content: View>: View {
    let progress: Double
    let color: Color
    let size: CGFloat
    let stroke: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.14), lineWidth: stroke)
            Circle()
                .trim(from: 0, to: min(1, max(0, progress)))
                .stroke(color, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                .rotationEffect(.degrees(-90))
            content()
        }
        .frame(width: size, height: size)
    }
}

private enum ActivityPalette {
    static let steps = Color(red: 0.208, green: 0.878, blue: 0.631)
    static let distance = Color(red: 0.302, green: 0.639, blue: 1.0)
    static let calories = Color(red: 1.0, green: 0.541, blue: 0.298)
}

private extension View {
    func activityGlass(interactive: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        return glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.24), .white.opacity(0.04)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.6
                )
            )
    }
}

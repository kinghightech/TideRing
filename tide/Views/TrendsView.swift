//
//  TrendsView.swift
//  Tide
//
//  The analytics tab: a week-at-a-glance chart preview per metric that has data, plus a browse list
//  of every metric. Tapping anything opens the full detail screen.
//

import SwiftUI

struct TrendsView: View {
    @ObservedObject var manager: RingManager
    @ObservedObject var store: RingStore

    /// Trends surfaces a focused set: heart rate, blood pressure, sleep, and calories.
    private let featured: [TideMetric] = [.heartRate, .bloodPressure, .sleep, .calories]

    private var metricsWithData: [TideMetric] {
        featured.filter { hasData($0) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                TideBackground()
                ScrollView {
                    VStack(spacing: 16) {
                        if metricsWithData.isEmpty {
                            emptyState
                        } else {
                            ForEach(metricsWithData) { metric in
                                NavigationLink {
                                    MetricDetailView(metric: metric, manager: manager, store: store)
                                } label: {
                                    TrendCard(metric: metric, store: store, weightKg: manager.settings.weightKg,
                                              calorieGoal: manager.settings.calorieGoal, sleepGoalHours: manager.settings.sleepGoalHours)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("Trends")
        }
    }

    private var emptyState: some View {
        GlassCard {
            VStack(spacing: 10) {
                Image(systemName: "chart.xyaxis.line").font(.largeTitle).foregroundStyle(.teal)
                Text("No trends yet").font(.headline)
                Text("Measure a vital or sync your ring's history and your charts will build here.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding()
        }
    }

    private func hasData(_ metric: TideMetric) -> Bool {
        switch metric {
        case .heartRate: return !store.heartRate.isEmpty
        case .bloodOxygen: return !store.spo2.isEmpty
        case .bloodPressure: return !store.bloodPressure.isEmpty
        case .steps, .calories: return !store.dailyActivity.isEmpty
        case .sleep: return !store.sleepNights.isEmpty
        default:
            guard let kind = metric.extraKind else { return false }
            return store.latestExtra(kind) != nil
        }
    }
}

/// A week-range preview chart for one metric.
private struct TrendCard: View {
    let metric: TideMetric
    @ObservedObject var store: RingStore
    var weightKg: Int = 70
    var calorieGoal: Int = 500
    var sleepGoalHours: Double = 8

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: metric.icon).foregroundStyle(metric.tint)
                    Text(metric.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    Spacer()
                    Text("7 days").font(.caption2).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                }
                preview
            }
            .padding()
        }
    }

    @ViewBuilder private var preview: some View {
        switch metric {
        case .calories:
            CalorieBarChart(stats: store.calorieDays(7, weightKg: weightKg), goal: calorieGoal, tint: metric.tint, height: 120, interactive: false)
        case .sleep:
            SleepDurationChart(nights: Array(store.sleepNights.suffix(7)), goalHours: sleepGoalHours, height: 120, interactive: false)
        case .bloodPressure:
            RangeBarChart(stats: store.dayStats(store.bloodPressure.map {
                RingReading(value: Double($0.systolic), date: $0.date, source: "")
            }, days: 7), tint: .purple, height: 120, interactive: false)
        default:
            RangeBarChart(
                stats: store.dayStats(scalarSeries, days: 7),
                tint: metric.tint,
                height: 120,
                preferredYDomain: metric == .bloodOxygen ? 85...100 : nil,
                interactive: false
            )
        }
    }

    private var scalarSeries: [RingReading] {
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
}

//
//  ContentView.swift
//  Tide
//
//  Created by Aahish Abbani on 7/10/26.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var manager = RingManager()
    @AppStorage("tide.onboardingComplete") private var onboardingComplete = false

    var body: some View {
        // TEMP PREVIEW HARNESS — remove before shipping.
        if let raw = ProcessInfo.processInfo.environment["TIDE_PREVIEW_METRIC"],
           let metric = TideMetric(rawValue: raw) {
            MetricPreviewHarness(manager: manager, metric: metric)
        } else if onboardingComplete {
            MainTabView(manager: manager)
        } else {
            OnboardingFlow(manager: manager) { onboardingComplete = true }
        }
    }
}

/// TEMP: renders a single metric detail full-screen with seeded demo data, for screenshot QA.
private struct MetricPreviewHarness: View {
    @ObservedObject var manager: RingManager
    let metric: TideMetric

    var body: some View {
        NavigationStack {
            MetricDetailView(metric: metric, manager: manager, store: manager.store)
        }
        .onAppear { seed() }
    }

    private func seed() {
        let store = manager.store
        guard store.activity == nil else { return }
        let now = Date()
        for i in 0..<48 { store.addHeartRate(bpm: 58 + (i * 7 % 40), date: now.addingTimeInterval(Double(-i * 1800)), source: "live") }
        for i in 0..<40 { store.addSpO2(value: 94 + (i % 5), date: now.addingTimeInterval(Double(-i * 2400))) }
        for i in 0..<7 {
            let day = Calendar.current.date(byAdding: .day, value: -i, to: now) ?? now
            store.updateActivity(ActivityRecord(steps: 6000 + i * 900, distanceMeters: Double(4200 + i * 600), calories: Double(320 + i * 70), timestamp: day))
        }
        for i in 0..<8 { store.addBloodPressure(systolic: 116 + i * 3, diastolic: 74 + i, date: now.addingTimeInterval(Double(-i * 86400))) }
        for n in 0..<6 {
            guard let base = Calendar.current.date(byAdding: .day, value: -n, to: now),
                  let start = Calendar.current.date(bySettingHour: 23, minute: 0, second: 0, of: Calendar.current.date(byAdding: .day, value: -1, to: base) ?? base) else { continue }
            var stages: [SleepStage] = []
            for i in 0..<96 { let r = (i + n) % 12; stages.append(r < 2 ? .awake : (r < 8 ? .light : .deep)) }
            store.addSleepFrame(start: start, stages: stages)
        }
    }
}

/// The signed-in app: Home / Vitals / Activity / Trends / Settings. Shown once onboarding is complete.
struct MainTabView: View {
    @ObservedObject var manager: RingManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection = Self.initialTab

    /// Optional QA override for the starting tab (0 Home · 1 Vitals · 2 Activity · 3 Trends · 4 Settings), per `TIDE_TAB`.
    private static var initialTab: Int {
        Int(ProcessInfo.processInfo.environment["TIDE_TAB"] ?? "") ?? 0
    }

    var body: some View {
        TabView(selection: $selection) {
            SummaryView(
                manager: manager,
                store: manager.store,
                onSeeTrends: { selection = 3 },
                onViewVitals: { selection = 1 }
            )
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(0)

            TideVitalsView(manager: manager, store: manager.store)
                .tabItem { Label("Vitals", systemImage: "waveform.path.ecg") }
                .tag(1)

            TideActivityView(manager: manager, store: manager.store)
                .tabItem { Label("Activity", systemImage: "figure.run") }
                .tag(2)

            TrendsView(manager: manager, store: manager.store)
                .tabItem { Label("Trends", systemImage: "chart.xyaxis.line") }
                .tag(3)

            SettingsView(manager: manager)
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(4)
        }
        .tint(TideColors.accent)
        // NOTE: the home screen forces its own dark appearance (see SummaryView). We intentionally do
        // NOT force it at the TabView level, so pages pushed from Home (e.g. the Tide Ring page) still
        // follow the real system light/dark setting — same as when opened from Settings.
        .onAppear {
            if manager.connectionState != .connected { manager.connectLastKnown() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { manager.appDidBecomeActive() }
        }
        // Ask for notification permission once we're in the app (battery / goal / sleep alerts).
        .task {
            guard ProcessInfo.processInfo.environment["TIDE_SKIP_NOTIFICATIONS"] != "1" else { return }
            await TideNotificationService.shared.requestAuthorization()
        }
    }
}

#Preview {
    ContentView()
}

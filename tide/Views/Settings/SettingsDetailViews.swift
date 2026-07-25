//
//  SettingsDetailViews.swift
//  Tide
//
//  The focused Settings detail screens pushed from SettingsView. Each wraps the existing RingManager
//  actions in the redesigned Liquid Glass form language — no ring behaviour is changed.
//

import SwiftUI

// MARK: - Profile

struct SettingsProfileView: View {
    @ObservedObject var manager: RingManager

    private var isConnected: Bool { manager.connectionState == .connected }

    var body: some View {
        ZStack {
            TideBackground()
            ScrollView {
                VStack(spacing: 22) {
                    TideSettingsSection(header: "Identity") {
                        TideValueRow(title: "Name") {
                            TextField("Optional", text: $manager.settings.name)
                                .textInputAutocapitalization(.words)
                                .multilineTextAlignment(.trailing)
                        }
                    }

                    TideSettingsSection(header: "Sex", footer: "Used by the ring's on-device calorie algorithm.") {
                        TideFormField {
                            Picker("Sex", selection: $manager.settings.isMale) {
                                Text("Male").tag(true)
                                Text("Female").tag(false)
                            }
                            .pickerStyle(.segmented)
                        }
                    }

                    TideSettingsSection(header: "Body metrics") {
                        TideValueRow(title: "Age") {
                            Stepper("", value: $manager.settings.age, in: 1...120).labelsHidden().fixedSize()
                            Text("\(manager.settings.age)").foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
                        }
                        TideValueRow(title: "Height") {
                            Stepper("", value: $manager.settings.heightCm, in: 100...230).labelsHidden().fixedSize()
                            Text("\(manager.settings.heightCm) cm").foregroundStyle(.secondary).frame(width: 60, alignment: .trailing)
                        }
                        TideValueRow(title: "Weight") {
                            Stepper("", value: $manager.settings.weightKg, in: 30...200).labelsHidden().fixedSize()
                            Text("\(manager.settings.weightKg) kg").foregroundStyle(.secondary).frame(width: 56, alignment: .trailing)
                        }
                    }

                    SendToRingButton(title: "Send Profile to Ring", enabled: isConnected) {
                        manager.applyUserProfile()
                    }
                }
                .padding()
            }
        }
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Goals

struct SettingsGoalsView: View {
    @ObservedObject var manager: RingManager

    private var isConnected: Bool { manager.connectionState == .connected }

    private var stepGoal: Binding<Double> {
        Binding(get: { Double(manager.settings.stepGoal) }, set: { manager.settings.stepGoal = Int($0) })
    }
    private var calorieGoal: Binding<Double> {
        Binding(get: { Double(manager.settings.calorieGoal) }, set: { manager.settings.calorieGoal = Int($0) })
    }

    var body: some View {
        ZStack {
            TideBackground()
            ScrollView {
                VStack(spacing: 22) {
                    TideSettingsSection(header: "Daily targets") {
                        TideGoalSlider(
                            title: "Steps", icon: "shoeprints.fill", tint: Color(red: 0.4, green: 0.8, blue: 0.6),
                            value: stepGoal, range: 2_000...30_000, step: 500,
                            label: manager.settings.stepGoal.formatted()
                        )
                        TideGoalSlider(
                            title: "Calories", icon: "flame.fill", tint: Color(red: 1.0, green: 0.55, blue: 0.3),
                            value: calorieGoal, range: 100...2_000, step: 50,
                            label: "\(manager.settings.calorieGoal) cal"
                        )
                        TideGoalSlider(
                            title: "Sleep", icon: "moon.fill", tint: Color(red: 0.55, green: 0.5, blue: 0.95),
                            value: $manager.settings.sleepGoalHours, range: 5...10, step: 0.5,
                            label: String(format: "%.1f h", manager.settings.sleepGoalHours)
                        )
                    }

                    SendToRingButton(title: "Send Step Goal to Ring", enabled: isConnected) {
                        manager.applyStepGoal()
                    }
                }
                .padding()
            }
        }
        .navigationTitle("Goals")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Measurement frequency

struct SettingsMeasurementView: View {
    @ObservedObject var manager: RingManager

    private var isConnected: Bool { manager.connectionState == .connected }
    private var automaticVitals: Binding<Bool> {
        Binding(
            get: { manager.settings.isAutomaticVitalsEnabled },
            set: { manager.settings.automaticVitalsEnabled = $0 }
        )
    }

    var body: some View {
        ZStack {
            TideBackground()
            ScrollView {
                VStack(spacing: 22) {
                    TideSettingsSection(footer: "Heart rate is scheduled directly on the ring. Blood oxygen and pressure use a combined check on the same interval while Tide is connected. iOS runs an overdue check when you reopen Tide. More frequent checks use more battery.") {
                        TideValueRow(title: "All-day heart rate") {
                            Toggle("", isOn: $manager.settings.hrBackgroundEnabled)
                                .labelsHidden()
                                .tint(TideColors.accent)
                        }
                        TideValueRow(title: "Oxygen & pressure") {
                            Toggle("", isOn: automaticVitals)
                                .labelsHidden()
                                .tint(TideColors.accent)
                        }
                        TideValueRow(title: "Interval") {
                            Picker("", selection: $manager.settings.hrIntervalMinutes) {
                                ForEach([5, 10, 15, 30, 60], id: \.self) { Text("\($0) min").tag($0) }
                            }
                            .labelsHidden()
                            .tint(TideColors.accent)
                        }
                        .disabled(!manager.settings.hrBackgroundEnabled && !manager.settings.isAutomaticVitalsEnabled)
                    }

                    SendToRingButton(title: "Send Schedule to Ring", enabled: isConnected) {
                        manager.applyMeasurementInterval()
                    }
                }
                .padding()
            }
        }
        .navigationTitle("Measurement")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Blood-pressure calibration

struct SettingsCalibrationView: View {
    @ObservedObject var manager: RingManager

    private var isConnected: Bool { manager.connectionState == .connected }
    private var canSend: Bool { isConnected && manager.settings.bpCalibrationSystolic > 0 && manager.settings.bpCalibrationDiastolic > 0 }

    var body: some View {
        ZStack {
            TideBackground()
            ScrollView {
                VStack(spacing: 22) {
                    TideSettingsSection(header: "Reference reading", footer: "Optional. Push a reference cuff reading so the ring applies an on-device offset. Leave at 0 to skip.") {
                        TideValueRow(title: "Systolic") {
                            Stepper("", value: $manager.settings.bpCalibrationSystolic, in: 0...250).labelsHidden().fixedSize()
                            Text("\(manager.settings.bpCalibrationSystolic)").foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                        }
                        TideValueRow(title: "Diastolic") {
                            Stepper("", value: $manager.settings.bpCalibrationDiastolic, in: 0...160).labelsHidden().fixedSize()
                            Text("\(manager.settings.bpCalibrationDiastolic)").foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                        }
                    }

                    SendToRingButton(title: "Send Calibration to Ring", enabled: canSend) {
                        manager.applyBloodPressureCalibration()
                    }
                }
                .padding()
            }
        }
        .navigationTitle("Calibration")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - About

struct SettingsAboutView: View {
    @ObservedObject var manager: RingManager
    @Binding var path: NavigationPath
    @State private var showClearConfirm = false

    var body: some View {
        ZStack {
            TideBackground()
            ScrollView {
                VStack(spacing: 22) {
                    TideSettingsSection(header: "Resources") {
                        TideSettingsRow(icon: "text.badge.checkmark", tint: Color(red: 0.4, green: 0.75, blue: 0.95),
                                        title: "Credits & Attribution") { path.append(SettingsRoute.credits) }
                        TideSettingsRow(icon: "lock.shield", tint: Color(red: 0.4, green: 0.8, blue: 0.6),
                                        title: "Privacy") { path.append(SettingsRoute.privacy) }
                        TideSettingsRow(icon: "ladybug", tint: Color(red: 1.0, green: 0.42, blue: 0.62),
                                        title: "Diagnostics") { path.append(SettingsRoute.diagnostics) }
                    }

                    TideSettingsSection(footer: "All readings are stored only on this device. Nothing is uploaded.") {
                        TideValueRow(title: "App identifier") {
                            Text(manager.settings.appIdentifier).foregroundStyle(.secondary)
                        }
                    }

                    Button(role: .destructive) { showClearConfirm = true } label: {
                        Text("Delete All Stored Data")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                    }
                    .buttonStyle(.glass)
                }
                .padding()
            }
        }
        .navigationTitle("About Tide")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete all stored readings?", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("Delete All", role: .destructive) { manager.store.clearAll() }
            Button("Cancel", role: .cancel) {}
        }
    }
}

// MARK: - Shared

/// A prominent Liquid Glass "send to ring" action, dimmed when the ring isn't connected.
struct SendToRingButton: View {
    let title: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: "arrow.up.circle.fill")
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 52)
        }
        .buttonStyle(.glassProminent)
        .tint(TideColors.accent)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }
}

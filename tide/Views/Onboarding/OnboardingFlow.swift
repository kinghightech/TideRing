//
//  OnboardingFlow.swift
//  Tide
//
//  First-run experience: a welcome carousel, ring pairing (reusing the existing, proven scan/connect
//  path — no connectivity behaviour is changed here, only the presentation), ring naming, a profile
//  step, and goal setting. All dark Liquid Glass. Gated by `tide.onboardingComplete` in ContentView.
//

import SwiftUI

enum OnboardingStep: Int, CaseIterable {
    case welcome, connect, ringName, profile, goals
}

struct OnboardingFlow: View {
    @ObservedObject var manager: RingManager
    let onComplete: () -> Void

    @State private var step: OnboardingStep = .welcome

    var body: some View {
        ZStack {
            OnboardingBackground()

            VStack(spacing: 0) {
                if step != .welcome {
                    OnboardingTopBar(step: step, onBack: goBack)
                        .transition(.opacity)
                }

                Group {
                    switch step {
                    case .welcome:
                        WelcomeStep(getStarted: { advance(to: .connect) })
                    case .connect:
                        ConnectStep(
                            manager: manager,
                            onConnected: { advance(to: .ringName) },
                            onCancel: goBack
                        )
                    case .ringName:
                        RingNameStep(manager: manager, onContinue: { advance(to: .profile) })
                    case .profile:
                        ProfileStep(manager: manager, onContinue: { advance(to: .goals) })
                    case .goals:
                        GoalsStep(manager: manager, onFinish: finish)
                    }
                }
                .id(step)
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
            }
        }
        .animation(.snappy(duration: 0.35), value: step)
        .preferredColorScheme(.dark)
    }

    private func advance(to next: OnboardingStep) { step = next }

    private func goBack() {
        guard let previous = OnboardingStep(rawValue: step.rawValue - 1) else { return }
        step = previous
    }

    private func finish() {
        if manager.connectionState == .connected {
            manager.applyStepGoal()
        }
        onComplete()
    }
}

// MARK: - Top bar

private struct OnboardingTopBar: View {
    let step: OnboardingStep
    let onBack: () -> Void

    // Every post-welcome step maps to one progress segment.
    private var progressIndex: Int { step.rawValue - 1 }
    private var segmentCount: Int { OnboardingStep.allCases.count - 1 }

    var body: some View {
        HStack(spacing: 14) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.white.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 6) {
                ForEach(0..<segmentCount, id: \.self) { i in
                    Capsule()
                        .fill(i <= progressIndex ? TideColors.accent : Color.white.opacity(0.14))
                        .frame(height: 4)
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 8)
        .padding(.bottom, 14)
    }
}

// MARK: - Welcome

private struct WelcomeStep: View {
    let getStarted: () -> Void

    @State private var slide = 0
    @State private var showLearnMore = false

    private struct Slide { let title: String; let subtitle: String }
    private let slides = [
        Slide(title: "Meet Tide.", subtitle: "Your everyday health companion."),
        Slide(title: "A smart ring.", subtitle: "Heart rate, sleep, and steps — right from your finger."),
        Slide(title: "Private by design.", subtitle: "Your health data stays on your device. Always."),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 8)

            HeroRingArt(size: 320)

            Spacer(minLength: 4)

            // Swipeable copy — the ring stays put while the message changes.
            TabView(selection: $slide) {
                ForEach(slides.indices, id: \.self) { i in
                    VStack(spacing: 12) {
                        Text(slides[i].title)
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        Text(slides[i].subtitle)
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.6))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                    .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 120)

            // Page dots.
            HStack(spacing: 8) {
                ForEach(slides.indices, id: \.self) { i in
                    Circle()
                        .fill(i == slide ? Color.white : Color.white.opacity(0.25))
                        .frame(width: 7, height: 7)
                }
            }
            .padding(.top, 4)

            Spacer(minLength: 24)

            VStack(spacing: 14) {
                TideCTAButton(title: "Get Started", action: getStarted)
                Button("Learn More") { showLearnMore = true }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
        }
        .sheet(isPresented: $showLearnMore) { LearnMoreSheet() }
    }
}

private struct LearnMoreSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let features: [(String, String, String, Color)] = [
        ("heart.fill", "Vitals", "Heart rate, SpO₂, HRV & more", TideColors.accent),
        ("bed.double.fill", "Sleep", "Stages and nightly trends", Color(red: 0.55, green: 0.5, blue: 0.95)),
        ("figure.walk", "Activity", "Steps, distance & calories", Color(red: 0.4, green: 0.8, blue: 0.6)),
        ("lock.shield.fill", "Private", "Everything stays on device", Color(red: 0.4, green: 0.75, blue: 0.95)),
    ]

    var body: some View {
        ZStack {
            OnboardingBackground()
            VStack(alignment: .leading, spacing: 18) {
                Text("What Tide does")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.top, 8)

                ForEach(features, id: \.1) { f in
                    HStack(spacing: 14) {
                        Image(systemName: f.0)
                            .font(.title3)
                            .foregroundStyle(f.3)
                            .frame(width: 44, height: 44)
                            .background(f.3.opacity(0.15), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.1).font(.headline).foregroundStyle(.white)
                            Text(f.2).font(.subheadline).foregroundStyle(.white.opacity(0.6))
                        }
                    }
                }

                Spacer()
                TideCTAButton(title: "Got it", action: { dismiss() })
            }
            .padding(28)
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
        .presentationBackground(.clear)
    }
}

// MARK: - Connect

private struct ConnectStep: View {
    @ObservedObject var manager: RingManager
    let onConnected: () -> Void
    let onCancel: () -> Void

    private var isSearching: Bool {
        manager.connectionState == .scanning || manager.connectionState == .idle
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 10)

            ScanningRingArt(active: manager.connectionState != .connected)

            VStack(spacing: 10) {
                Text("Let's connect\nyour ring.")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Text("Make sure your ring is charged and nearby.")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
            }

            Spacer(minLength: 16)

            // Discovered rings appear as glass rows the moment they're seen. Tapping connects.
            statusAndDevices

            Spacer(minLength: 16)

            TideGlassButton(title: "Cancel", action: onCancel)
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
        }
        .onAppear {
            if manager.connectionState == .connected { onConnected() } else { startScanIfNeeded() }
        }
        .onDisappear { manager.stopScanning() }
        .onChange(of: manager.connectionState) { _, state in
            if state == .connected { onConnected() }
        }
    }

    @ViewBuilder
    private var statusAndDevices: some View {
        VStack(spacing: 12) {
            if !manager.discovered.isEmpty {
                deviceRows
            } else if !manager.isBluetoothReady {
                statusLine(text: "Bluetooth is \(manager.bluetoothStateText.lowercased())", showSpinner: false)
            } else {
                statusLine(text: "Searching…", showSpinner: true)
            }
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity)
    }

    private var deviceRows: some View {
        VStack(spacing: 10) {
            ForEach(manager.discovered.filter { $0.isLikelyRing || manager.discovered.count <= 4 }) { device in
                Button { manager.connect(to: device.id) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: device.isLikelyRing ? "circle.hexagongrid.circle.fill" : "dot.radiowaves.left.and.right")
                            .foregroundStyle(device.isLikelyRing ? TideColors.accent : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(device.name).font(.subheadline.weight(.medium)).foregroundStyle(.white)
                            Text(device.isLikelyRing ? "Smart ring" : "RSSI \(device.rssi)")
                                .font(.caption2).foregroundStyle(.white.opacity(0.5))
                        }
                        Spacer()
                        if manager.connectionState == .connecting {
                            ProgressView().controlSize(.small).tint(.white)
                        } else {
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.white.opacity(0.4))
                        }
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 56)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }

    private func statusLine(text: String, showSpinner: Bool) -> some View {
        HStack(spacing: 8) {
            if showSpinner { ProgressView().controlSize(.small).tint(.white) }
            Text(text)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white.opacity(0.7))
        }
        .padding(.vertical, 8)
    }

    private func startScanIfNeeded() {
        guard manager.connectionState != .connected, manager.connectionState != .scanning else { return }
        manager.startScanning()
    }
}

// MARK: - Ring name

private struct RingNameStep: View {
    @ObservedObject var manager: RingManager
    let onContinue: () -> Void

    @FocusState private var nameFocused: Bool

    private var ringName: Binding<String> {
        Binding(
            get: { manager.settings.ringName ?? "" },
            set: { manager.settings.ringName = $0 }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    ZStack {
                        Circle()
                            .fill(TideColors.accent.opacity(0.12))
                            .frame(width: 180, height: 180)
                            .blur(radius: 8)
                        Image("ring")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 150, height: 150)
                            .shadow(color: TideColors.glow.opacity(0.45), radius: 24, y: 8)
                    }

                    VStack(spacing: 9) {
                        Text("Name your ring.")
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        Text("Give it a name that feels like yours. You can change it later.")
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.6))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 34)
                    }

                    TextField(
                        "",
                        text: ringName,
                        prompt: Text("Aahish's Tide Ring").foregroundColor(.white.opacity(0.35))
                    )
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.continue)
                    .focused($nameFocused)
                    .onSubmit { saveAndContinue() }
                    .multilineTextAlignment(.center)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .frame(maxWidth: .infinity, minHeight: 62)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .padding(.horizontal, 28)
                    .padding(.top, 26)

                    HStack(spacing: 7) {
                        Circle().fill(.green).frame(width: 7, height: 7)
                        Text("Connected")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.65))
                    }
                    .padding(.top, 14)
                    .padding(.bottom, 18)
                }
            }
            .scrollDismissesKeyboard(.interactively)

            TideCTAButton(title: "Continue", action: saveAndContinue)
                .padding(.horizontal, 28)
                .padding(.bottom, 20)
        }
        .onAppear { nameFocused = true }
    }

    private func saveAndContinue() {
        let trimmed = ringName.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        manager.settings.ringName = trimmed.isEmpty ? nil : String(trimmed.prefix(40))
        nameFocused = false
        onContinue()
    }
}

// MARK: - Profile

private struct ProfileStep: View {
    @ObservedObject var manager: RingManager
    let onContinue: () -> Void

    private var heightBinding: Binding<Int> { $manager.settings.heightCm }
    private var weightBinding: Binding<Int> { $manager.settings.weightKg }
    private var ageBinding: Binding<Int> { $manager.settings.age }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 22) {
                    VStack(spacing: 8) {
                        Text("What's your name?")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                        Text("So Tide can make your summaries feel like yours.")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.6))
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 8)

                    TextField("", text: $manager.settings.name, prompt: Text("Your name").foregroundColor(.white.opacity(0.35)))
                        .textInputAutocapitalization(.words)
                        .multilineTextAlignment(.center)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.vertical, 18)
                        .frame(maxWidth: .infinity)
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                    TideSettingsSection(header: "Optional", footer: "Improves calorie & activity accuracy. You can skip this.") {
                        TideFormField {
                            Picker("Sex", selection: $manager.settings.isMale) {
                                Text("Male").tag(true)
                                Text("Female").tag(false)
                            }
                            .pickerStyle(.segmented)
                        }
                        TideValueRow(title: "Age") {
                            Stepper("\(manager.settings.age)", value: ageBinding, in: 1...120)
                                .labelsHidden()
                                .fixedSize()
                            Text("\(manager.settings.age)").font(.body).foregroundStyle(.secondary).frame(width: 34)
                        }
                        TideValueRow(title: "Height") {
                            Stepper("", value: heightBinding, in: 100...230).labelsHidden().fixedSize()
                            Text("\(manager.settings.heightCm) cm").font(.body).foregroundStyle(.secondary).frame(width: 60, alignment: .trailing)
                        }
                        TideValueRow(title: "Weight") {
                            Stepper("", value: weightBinding, in: 30...200).labelsHidden().fixedSize()
                            Text("\(manager.settings.weightKg) kg").font(.body).foregroundStyle(.secondary).frame(width: 56, alignment: .trailing)
                        }
                    }
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 16)
            }
            .scrollDismissesKeyboard(.interactively)

            TideCTAButton(title: "Continue", action: {
                if manager.connectionState == .connected { manager.applyUserProfile() }
                onContinue()
            })
            .padding(.horizontal, 28)
            .padding(.bottom, 20)
        }
    }
}

// MARK: - Goals

private struct GoalsStep: View {
    @ObservedObject var manager: RingManager
    let onFinish: () -> Void

    private var stepGoal: Binding<Double> {
        Binding(get: { Double(manager.settings.stepGoal) }, set: { manager.settings.stepGoal = Int($0) })
    }
    private var calorieGoal: Binding<Double> {
        Binding(get: { Double(manager.settings.calorieGoal) }, set: { manager.settings.calorieGoal = Int($0) })
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 22) {
                    VStack(spacing: 8) {
                        Text("Set your goals.")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        Text("Start with these targets — change them anytime in Settings.")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.6))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 20)
                    }
                    .padding(.top, 8)

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
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 16)
            }

            TideCTAButton(title: "Start using Tide", systemImage: "arrow.right", action: onFinish)
                .padding(.horizontal, 28)
                .padding(.bottom, 20)
        }
    }
}

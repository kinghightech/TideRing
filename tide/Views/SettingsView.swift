//
//  SettingsView.swift
//  Tide
//
//  Redesigned Settings: a Liquid Glass device hero card over iOS-Settings-style grouped glass
//  sections. Each row pushes a focused detail screen (see Settings/SettingsDetailViews.swift).
//  Every underlying action (profile/goal/measurement/calibration sends, data wipe, about links) is
//  the same as before — only the presentation changed.
//

import SwiftUI

enum SettingsRoute: Hashable {
    case device, profile, goals, measurement, calibration, camera, games, chromeDino, about, diagnostics, credits, privacy
}

struct SettingsView: View {
    @ObservedObject var manager: RingManager
    @AppStorage("tide.onboardingComplete") private var onboardingComplete = true
    @State private var path = NavigationPath()
    @State private var showSignOutConfirm = false

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                TideBackground()
                ScrollView {
                    VStack(spacing: 22) {
                        TideDeviceHeroCard(manager: manager) { path.append(SettingsRoute.device) }

                        TideSettingsSection(header: "You") {
                            TideSettingsRow(icon: "person.crop.circle", tint: TideColors.accent,
                                            title: "Profile", value: profileValue) { path.append(SettingsRoute.profile) }
                            TideSettingsRow(icon: "target", tint: Color(red: 0.85, green: 0.5, blue: 0.95),
                                            title: "Goals", value: "\(Fmt.steps(manager.settings.stepGoal)) steps") { path.append(SettingsRoute.goals) }
                        }

                        TideSettingsSection(header: "Ring") {
                            TideSettingsRow(icon: "timer", tint: Color(red: 0.3, green: 0.75, blue: 0.9),
                                            title: "Measurement Frequency",
                                            value: manager.settings.hrBackgroundEnabled || manager.settings.isAutomaticVitalsEnabled
                                                ? "\(manager.settings.hrIntervalMinutes) min" : "Off") { path.append(SettingsRoute.measurement) }
                            TideSettingsRow(icon: "slider.horizontal.3", tint: Color(red: 1.0, green: 0.42, blue: 0.62),
                                            title: "Blood-Pressure Calibration") { path.append(SettingsRoute.calibration) }
                            TideSettingsRow(icon: "camera.fill", tint: TideColors.accent,
                                            title: "Camera Remote") { path.append(SettingsRoute.camera) }
                        }

                        TideSettingsSection(header: "Games") {
                            TideSettingsRow(icon: "gamecontroller.fill", tint: Color(red: 0.95, green: 0.6, blue: 0.2),
                                            title: "Flappy Ring", value: "Play") { path.append(SettingsRoute.games) }
                            TideSettingsRow(icon: "figure.run", tint: Color(red: 0.4, green: 0.8, blue: 0.4),
                                            title: "Chrome Dino", value: "Play") { path.append(SettingsRoute.chromeDino) }
                        }

                        TideSettingsSection(footer: "All readings are stored only on this device. Nothing is uploaded.") {
                            TideSettingsRow(icon: "info.circle", tint: Color(red: 0.5, green: 0.55, blue: 0.62),
                                            title: "About Tide") { path.append(SettingsRoute.about) }
                        }

                        Button(role: .destructive) { showSignOutConfirm = true } label: {
                            Label("Sign Out", systemImage: "arrow.backward.circle")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity)
                                .frame(height: 52)
                        }
                        .buttonStyle(.glass)
                        .padding(.top, 4)
                    }
                    .padding()
                }
                .scrollEdgeEffectStyle(.soft, for: .top)
            }
            .navigationTitle("Settings")
            .confirmationDialog("Sign out of Tide?", isPresented: $showSignOutConfirm, titleVisibility: .visible) {
                Button("Sign Out", role: .destructive) { onboardingComplete = false }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You'll return to the welcome screen. Your ring and stored data stay set up.")
            }
            .navigationDestination(for: SettingsRoute.self) { route in
                switch route {
                case .device: RingConnectionView(manager: manager)
                case .profile: SettingsProfileView(manager: manager)
                case .goals: SettingsGoalsView(manager: manager)
                case .measurement: SettingsMeasurementView(manager: manager)
                case .calibration: SettingsCalibrationView(manager: manager)
                case .camera: TideCameraView(manager: manager)
                case .games: FlappyBirdGameView(manager: manager)
                case .chromeDino: ChromeDinoGameView(manager: manager)
                case .about: SettingsAboutView(manager: manager, path: $path)
                case .diagnostics: DiagnosticsView(manager: manager)
                case .credits: CreditsView()
                case .privacy: PrivacyView()
                }
            }
        }
    }

    private var profileValue: String {
        let name = manager.settings.name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "\(manager.settings.age) · \(manager.settings.isMale ? "Male" : "Female")" : name
    }
}

// MARK: - Device hero card

/// A compact ring row at the top of Settings: artwork, the user's ring name, connection
/// status, and battery. Tapping opens the full ring screen (where connect/disconnect live).
struct TideDeviceHeroCard: View {
    @ObservedObject var manager: RingManager
    let openDevice: () -> Void

    var body: some View {
        Button(action: openDevice) {
            HStack(spacing: 14) {
                Image("ring")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 44, height: 44)
                    .shadow(color: TideColors.glow.opacity(0.3), radius: 7, y: 2)

                VStack(alignment: .leading, spacing: 3) {
                    Text(manager.settings.displayRingName)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    HStack(spacing: 6) {
                        Circle().fill(statusColor).frame(width: 7, height: 7)
                        Text(statusLine).font(.caption).foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 8)

                if let b = manager.batteryPercent {
                    Label("\(b)%", systemImage: "battery.100")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(batteryColor(b))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(batteryColor(b).opacity(0.14), in: Capsule())
                }
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background { Color.clear.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous)) }
    }

    private var statusLine: String {
        switch manager.connectionState {
        case .connected: return manager.isBound ? "Connected · bound" : "Connected"
        case .connecting: return "Connecting…"
        case .reconnecting: return "Reconnecting…"
        case .scanning: return "Searching…"
        case .failed: return "Connection failed"
        default: return manager.hasLastKnownRing ? "Disconnected" : "Not paired"
        }
    }

    private var statusColor: Color {
        switch manager.connectionState {
        case .connected: return .green
        case .connecting, .reconnecting, .scanning: return .orange
        case .failed: return .red
        default: return .secondary
        }
    }

    private func batteryColor(_ p: Int) -> Color {
        p < 20 ? .red : (p < 40 ? .orange : .green)
    }
}

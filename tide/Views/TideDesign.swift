//
//  TideDesign.swift
//  Tide
//
//  The Liquid Glass design language shared by the onboarding flow and the redesigned Settings.
//  Deployment target is iOS 26, so this uses the real `glassEffect` / `.glass` APIs directly —
//  no availability fallbacks.
//

import SwiftUI
import UIKit

// MARK: - Typography

/// The Tide type system. `serif` is PP Editorial New (elegant serif) for headers/emphasis; `sans`
/// is Akkurat (clean sans) for body/data. Until those font files are added to the bundle, both fall
/// back gracefully — serif → New York, sans → SF — so the design reads correctly today and upgrades
/// automatically the moment the real fonts are dropped in.
enum TideFont {
    /// Candidate PostScript names for PP Editorial New (varies by foundry export).
    private static let serifNames = ["PPEditorialNew-Regular", "PP Editorial New", "PPEditorialNew-Ultralight", "PPEditorialNew"]
    private static let sansNames = ["Akkurat-Regular", "Akkurat", "AkkuratLLWeb-Regular", "Akkurat LL"]

    private static func firstInstalled(_ names: [String], size: CGFloat) -> String? {
        names.first { UIFont(name: $0, size: size) != nil }
    }

    static func serif(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if let name = firstInstalled(serifNames, size: size) { return .custom(name, size: size) }
        return .system(size: size, weight: weight, design: .serif)
    }

    static func sans(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if let name = firstInstalled(sansNames, size: size) { return .custom(name, size: size).weight(weight) }
        return .system(size: size, weight: weight)
    }
}

// MARK: - Palette

/// Tide's accent family — a cyan → blue glow used for the ring artwork, CTAs, and tinted controls.
enum TideColors {
    static let accent = Color(red: 0.38, green: 0.72, blue: 0.99)
    static let accentDeep = Color(red: 0.27, green: 0.55, blue: 0.97)
    static let glow = Color(red: 0.36, green: 0.70, blue: 1.0)

    /// Bright, light gradient for the hero "Get Started" pill (matches the onboarding art).
    static let ctaGradient = LinearGradient(
        colors: [Color(red: 0.82, green: 0.89, blue: 1.0), Color(red: 0.62, green: 0.74, blue: 0.99)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    /// Calm deep-ocean tone the home fades into (a blue-teal dark — not navy, not black).
    static let deepOcean = Color(red: 0.035, green: 0.078, blue: 0.105)

    /// Deep-space background used across onboarding.
    static let onboardingBackground = LinearGradient(
        colors: [Color(red: 0.015, green: 0.03, blue: 0.06), Color(red: 0.04, green: 0.06, blue: 0.11)],
        startPoint: .top, endPoint: .bottom
    )
}

// MARK: - Onboarding background

/// A calm, deep-space wash: a dark gradient, a faint drifting star field, and two softly
/// breathing accent orbs. Reused behind every onboarding page so transitions feel continuous.
struct OnboardingBackground: View {
    @State private var breathe = false

    // Deterministic star field — computed once so it never reshuffles between redraws.
    private let stars: [Star] = {
        var generator = SeededGenerator(seed: 9_137)
        return (0..<70).map { _ in
            Star(
                x: Double.random(in: 0...1, using: &generator),
                y: Double.random(in: 0...1, using: &generator),
                size: Double.random(in: 0.6...2.2, using: &generator),
                opacity: Double.random(in: 0.05...0.45, using: &generator)
            )
        }
    }()

    var body: some View {
        ZStack {
            TideColors.onboardingBackground.ignoresSafeArea()

            GeometryReader { proxy in
                ZStack {
                    ForEach(stars.indices, id: \.self) { i in
                        let star = stars[i]
                        Circle()
                            .fill(.white)
                            .frame(width: star.size, height: star.size)
                            .opacity(star.opacity)
                            .position(x: star.x * proxy.size.width, y: star.y * proxy.size.height)
                    }
                }
            }
            .ignoresSafeArea()

            // Two slow "breathing" accent orbs.
            Circle()
                .fill(TideColors.accent.opacity(0.22))
                .frame(width: 360, height: 360)
                .blur(radius: 120)
                .offset(x: breathe ? -110 : -80, y: breathe ? -220 : -180)
            Circle()
                .fill(TideColors.accentDeep.opacity(0.20))
                .frame(width: 320, height: 320)
                .blur(radius: 130)
                .offset(x: breathe ? 130 : 100, y: breathe ? 260 : 300)
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeInOut(duration: 7).repeatForever(autoreverses: true)) {
                breathe = true
            }
        }
    }

    private struct Star { let x, y, size, opacity: Double }
}

/// Tiny deterministic RNG so the star field is stable across launches and redraws.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0xdead_beef : seed }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

// MARK: - Ambient ring artwork (welcome)

/// The hero ring with softly moving concentric halos behind it — the "calmly moving circles".
struct HeroRingArt: View {
    var size: CGFloat = 240
    @State private var animate = false

    var body: some View {
        ZStack {
            // Concentric halos that slowly expand and fade.
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .stroke(TideColors.glow.opacity(0.18), lineWidth: 1.2)
                    .frame(width: size * 0.8, height: size * 0.8)
                    .scaleEffect(animate ? 1.55 + Double(i) * 0.18 : 0.9 + Double(i) * 0.18)
                    .opacity(animate ? 0 : 0.6)
                    .animation(
                        .easeOut(duration: 4.5).repeatForever(autoreverses: false).delay(Double(i) * 1.5),
                        value: animate
                    )
            }

            // Ambient glow pool under the ring.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [TideColors.glow.opacity(0.35), .clear],
                        center: .center, startRadius: 0, endRadius: size * 0.55
                    )
                )
                .frame(width: size * 1.3, height: size * 1.3)
                .blur(radius: 30)

            Image("ring")
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .shadow(color: TideColors.glow.opacity(0.35), radius: 30, y: 8)
                .rotationEffect(.degrees(animate ? 3 : -3))
                .animation(.easeInOut(duration: 6).repeatForever(autoreverses: true), value: animate)
        }
        .frame(width: size * 1.4, height: size * 1.4)
        .onAppear { animate = true }
    }
}

/// The sonar-style glowing ring used on the "connect your ring" scanning page.
struct ScanningRingArt: View {
    var active: Bool
    var size: CGFloat = 180
    @State private var animate = false

    var body: some View {
        ZStack {
            // Radar pulses that only run while searching.
            if active {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .stroke(TideColors.glow.opacity(0.35), lineWidth: 1.5)
                        .frame(width: size, height: size)
                        .scaleEffect(animate ? 1.7 : 0.8)
                        .opacity(animate ? 0 : 0.7)
                        .animation(
                            .easeOut(duration: 2.6).repeatForever(autoreverses: false).delay(Double(i) * 0.85),
                            value: animate
                        )
                }
            }

            Circle()
                .fill(
                    RadialGradient(
                        colors: [TideColors.glow.opacity(0.30), .clear],
                        center: .center, startRadius: 0, endRadius: size * 0.6
                    )
                )
                .frame(width: size * 1.4, height: size * 1.4)
                .blur(radius: 24)

            Circle()
                .stroke(
                    AngularGradient(
                        colors: [TideColors.accent, TideColors.accentDeep, TideColors.accent.opacity(0.3), TideColors.accent],
                        center: .center
                    ),
                    lineWidth: 3
                )
                .frame(width: size, height: size)
                .shadow(color: TideColors.glow.opacity(0.6), radius: 14)
        }
        .frame(width: size * 1.9, height: size * 1.9)
        .onAppear { animate = active }
        .onChange(of: active) { _, now in animate = now }
    }
}

// MARK: - Buttons

/// The bright hero CTA ("Get Started" / "Continue"): a light gradient pill wrapped in
/// interactive Liquid Glass, with an accent glow.
struct TideCTAButton: View {
    let title: String
    var systemImage: String? = nil
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                if let systemImage {
                    Image(systemName: systemImage)
                }
            }
            .font(.headline)
            .foregroundStyle(Color(red: 0.06, green: 0.10, blue: 0.20))
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(TideColors.ctaGradient, in: Capsule())
            .overlay(
                Capsule().stroke(.white.opacity(0.35), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .shadow(color: TideColors.glow.opacity(enabled ? 0.35 : 0), radius: 20, y: 6)
        .opacity(enabled ? 1 : 0.5)
        .disabled(!enabled)
    }
}

/// A neutral glass pill (Cancel / Learn More / secondary actions) on the dark onboarding canvas.
struct TideGlassButton: View {
    let title: String
    var systemImage: String? = nil
    var tint: Color = .white
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
        }
        .buttonStyle(.glass)
    }
}

// MARK: - Settings surfaces

/// An uppercase section header wrapping rows in a single grouped glass card with hairline dividers.
struct TideSettingsSection<Content: View>: View {
    var header: String? = nil
    var footer: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let header {
                Text(header.uppercased())
                    .font(.caption.weight(.semibold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 16)
            }
            _VariadicView.Tree(TideGroupedLayout()) { content }
                .background { Color.clear.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous)) }
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            }
        }
    }
}

/// Inserts hairline dividers between a section's rows.
private struct TideGroupedLayout: _VariadicView.MultiViewRoot {
    @ViewBuilder func body(children: _VariadicView.Children) -> some View {
        let last = children.last?.id
        VStack(spacing: 0) {
            ForEach(children) { child in
                child
                if child.id != last {
                    Divider().overlay(Color.white.opacity(0.08)).padding(.leading, 60)
                }
            }
        }
    }
}

/// A tappable settings category row: tinted glyph tile, title, optional trailing value, chevron.
struct TideSettingsRow: View {
    let icon: String
    var tint: Color = TideColors.accent
    let title: String
    var value: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(tint.gradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                if let value {
                    Text(value)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A flat title + trailing-control row for the inside of a `TideSettingsSection`.
struct TideValueRow<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack {
            Text(title).font(.body).foregroundStyle(.primary)
            Spacer()
            trailing
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 50)
    }
}

/// A flat container for arbitrary field content (sliders, steppers) inside a section.
struct TideFormField<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding)
    }
}

/// A labelled slider used for goal setting — icon tile, title, live value, tinted track.
struct TideGoalSlider: View {
    let title: String
    let icon: String
    var tint: Color = TideColors.accent
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let label: String

    var body: some View {
        TideFormField {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(tint)
                        .frame(width: 30, height: 30)
                        .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    Text(title).font(.callout).foregroundStyle(.primary)
                    Spacer()
                    Text(label)
                        .font(.body.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(tint)
                }
                Slider(value: $value, in: range, step: step)
                    .tint(tint)
                    .accessibilityLabel(title)
                    .accessibilityValue(label)
            }
        }
    }
}

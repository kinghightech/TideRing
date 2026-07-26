//
//  FlappyBirdGameView.swift
//  Tide
//
//  A distance-controlled flying game driven by the same ring gesture stream as Camera.
//

import Combine
import SwiftUI

// MARK: - Game tuning

private enum FlightTuning {
    static let gravity: CGFloat = 280
    static let flapImpulse: CGFloat = -270
    static let maximumBurstVelocity: CGFloat = -420
    static let burstBoost: CGFloat = 75
    static let birdSize: CGFloat = 34
    static let pipeWidth: CGFloat = 60
    static let basePipeGap: CGFloat = 290
    static let pipeVisualOverscan: CGFloat = 120
    static let floorCollisionInset: CGFloat = 8
    static let groundHeight: CGFloat = 65
    static let basePipeSpeed: CGFloat = 62
    static let spawnInterval: Double = 3.8
}

// MARK: - Models

private struct FlightGate: Identifiable {
    let id = UUID()
    var x: CGFloat
    let gapY: CGFloat
    let gapHeight: CGFloat
    var scored = false
}

// MARK: - Engine

@MainActor
private final class FlappyEngine: ObservableObject {
    enum Phase: Equatable { case idle, playing, dead }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var birdY: CGFloat = 300
    @Published private(set) var birdAngle: Double = 0
    @Published private(set) var gates: [FlightGate] = []
    @Published private(set) var score = 0
    @Published private(set) var best = 0
    @Published private(set) var flapSequence: UInt64 = 0

    private var velocityY: CGFloat = 0
    private var fieldSize = CGSize(width: 390, height: 700)
    private var spawnAccumulator: Double = 0
    private var gameTask: Task<Void, Never>?

    private let bestKey = "tide.flappy.best"

    init() {
        best = UserDefaults.standard.integer(forKey: bestKey)
    }

    var birdX: CGFloat {
        min(max(fieldSize.width * 0.23, 78), 104)
    }

    func setFieldSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        fieldSize = size
        if phase == .idle {
            birdY = size.height * 0.44
        }
    }

    func receiveFlap() {
        switch phase {
        case .idle:
            start()
        case .playing:
            applyFlap()
        case .dead:
            break
        }
    }

    func start() {
        gameTask?.cancel()
        gates.removeAll(keepingCapacity: true)
        score = 0
        velocityY = 0
        birdAngle = -18
        birdY = fieldSize.height * 0.44
        spawnAccumulator = 0
        phase = .playing

        applyFlap()

        gameTask = Task { @MainActor [weak self] in
            let clock = ContinuousClock()
            var previousTick = clock.now

            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                guard let self, self.phase == .playing else { break }

                let now = clock.now
                let elapsed = previousTick.duration(to: now)
                previousTick = now
                let dt = min(max(Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18, 0.001), 0.034)
                self.tick(dt: dt)
            }
        }
    }

    func stop() {
        gameTask?.cancel()
        gameTask = nil
    }

    private func tick(dt: Double) {
        velocityY += FlightTuning.gravity * dt
        birdY += velocityY * dt

        let targetAngle = Double(velocityY / 7.2).clamped(-27, 72)
        birdAngle += (targetAngle - birdAngle) * min(1, dt * 10)

        for index in gates.indices {
            gates[index].x -= FlightTuning.basePipeSpeed * dt
        }

        for index in gates.indices where !gates[index].scored && gates[index].x + FlightTuning.pipeWidth / 2 < birdX {
            gates[index].scored = true
            score += 1
        }
        gates.removeAll { $0.x < -FlightTuning.pipeWidth }

        spawnAccumulator += dt
        if spawnAccumulator >= FlightTuning.spawnInterval {
            spawnAccumulator -= FlightTuning.spawnInterval
            spawnGate()
        }

        if collided() {
            die()
        }
    }

    private func applyFlap() {
        // A normal tap keeps the original game feel. Rapid taps boost immediately rather than
        // being delayed in a queue, so every accepted ring gesture has an instant effect.
        velocityY = max(
            FlightTuning.maximumBurstVelocity,
            min(FlightTuning.flapImpulse, velocityY - FlightTuning.burstBoost)
        )
        birdAngle = -24
        flapSequence &+= 1
    }

    private func spawnGate() {
        let playableHeight = fieldSize.height - FlightTuning.groundHeight
        let gapHeight = min(FlightTuning.basePipeGap, max(228, playableHeight * 0.38))
        let safeMargin: CGFloat = 78
        let upperCenter = gapHeight / 2 + safeMargin
        let lowerCenter = playableHeight - gapHeight / 2 - safeMargin
        guard lowerCenter > upperCenter else { return }

        gates.append(FlightGate(
            x: fieldSize.width + FlightTuning.pipeWidth,
            gapY: CGFloat.random(in: upperCenter...lowerCenter),
            gapHeight: gapHeight
        ))
    }

    private func collided() -> Bool {
        let radius = FlightTuning.birdSize / 2 - 5
        // The ground draws into the bottom safe area. Use the actual field bottom for collision
        // so the bird does not die in the empty space visibly above the ground.
        let floorY = fieldSize.height - FlightTuning.floorCollisionInset

        if birdY - radius < 0 || birdY + radius > floorY {
            return true
        }

        for gate in gates {
            let left = gate.x - FlightTuning.pipeWidth / 2
            let right = gate.x + FlightTuning.pipeWidth / 2
            guard birdX + radius > left, birdX - radius < right else { continue }

            let gapTop = gate.gapY - gate.gapHeight / 2
            let gapBottom = gate.gapY + gate.gapHeight / 2
            if birdY - radius < gapTop || birdY + radius > gapBottom {
                return true
            }
        }
        return false
    }

    private func die() {
        phase = .dead
        stop()

        if score > best {
            best = score
            UserDefaults.standard.set(score, forKey: bestKey)
        }
    }

    deinit {
        gameTask?.cancel()
    }
}

private extension Double {
    func clamped(_ lower: Double, _ upper: Double) -> Double {
        Swift.min(Swift.max(self, lower), upper)
    }
}

// MARK: - View

struct FlappyBirdGameView: View {
    private enum InputSource { case screen, ring }

    @ObservedObject var manager: RingManager
    @StateObject private var engine = FlappyEngine()
    @State private var isVisible = false
    @State private var ringPulse: UInt64 = 0

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size

            ZStack {
                flightBackground(size: size)

                ForEach(engine.gates) { gate in
                    gateView(gate, fieldHeight: size.height)
                }

                horizon(size: size)
                bird
                hud(size: size)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                handleFlap(from: .screen)
            }
            .onAppear {
                engine.setFieldSize(size)
            }
            .onChange(of: size) { _, newSize in
                engine.setFieldSize(newSize)
            }
        }
        .background(Color.black)
        .navigationTitle("Flappy Ring")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .onAppear {
            isVisible = true
            armRingGestureIfPossible()
        }
        .onDisappear {
            isVisible = false
            manager.setCameraMode(enabled: false)
        }
        .onChange(of: manager.connectionState) { _, state in
            if isVisible, state == .connected {
                manager.setCameraMode(enabled: true)
            }
        }
        // Listen to every published ring event, but skip the publisher's initial value so
        // opening the game never causes a phantom flap.
        .onReceive(manager.$cameraShutterSequence.dropFirst()) { _ in
            guard isVisible else { return }
            handleFlap(from: .ring)
        }
        .sensoryFeedback(.impact(weight: .light), trigger: engine.flapSequence)
        .sensoryFeedback(.success, trigger: engine.score)
    }

    // MARK: - Input

    private func armRingGestureIfPossible() {
        guard manager.connectionState == .connected else { return }
        manager.setCameraMode(enabled: true)
    }

    private func handleFlap(from source: InputSource) {
        if engine.phase == .dead {
            engine.start()
        } else {
            engine.receiveFlap()
        }

        if source == .ring { ringPulse &+= 1 }
    }

    // MARK: - Background

    private func flightBackground(size: CGSize) -> some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.015, green: 0.025, blue: 0.075),
                    Color(red: 0.018, green: 0.10, blue: 0.17),
                    Color(red: 0.02, green: 0.055, blue: 0.11)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(TideColors.glow.opacity(0.12))
                .frame(width: min(size.width * 0.78, 340))
                .blur(radius: 48)
                .offset(x: size.width * 0.29, y: -size.height * 0.31)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [.white.opacity(0.9), TideColors.accent.opacity(0.35), .clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: 44
                    )
                )
                .frame(width: 88, height: 88)
                .offset(x: size.width * 0.30, y: -size.height * 0.32)

            stars
            distantCity(size: size)

            LinearGradient(
                colors: [.clear, Color.black.opacity(0.24)],
                startPoint: .center,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var stars: some View {
        Canvas { context, size in
            var random = FlappyRNG(seed: 77)
            for _ in 0..<58 {
                let x = CGFloat.random(in: 0...size.width, using: &random)
                let y = CGFloat.random(in: 0...size.height * 0.69, using: &random)
                let radius = CGFloat.random(in: 0.45...1.55, using: &random)
                let opacity = Double.random(in: 0.10...0.62, using: &random)
                let rect = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
                context.fill(Circle().path(in: rect), with: .color(.white.opacity(opacity)))
            }
        }
    }

    private func distantCity(size: CGSize) -> some View {
        Canvas { context, canvasSize in
            var random = FlappyRNG(seed: 311)
            var x: CGFloat = -8
            let baseY = canvasSize.height - FlightTuning.groundHeight

            while x < canvasSize.width + 10 {
                let width = CGFloat.random(in: 17...42, using: &random)
                let height = CGFloat.random(in: 30...104, using: &random)
                let building = CGRect(x: x, y: baseY - height, width: width, height: height)
                context.fill(Rectangle().path(in: building), with: .color(Color(red: 0.025, green: 0.065, blue: 0.105).opacity(0.82)))

                var windowY = building.minY + 10
                while windowY < building.maxY - 8 {
                    let window = CGRect(x: building.minX + 7, y: windowY, width: 2, height: 3)
                    context.fill(Rectangle().path(in: window), with: .color(TideColors.accent.opacity(0.13)))
                    windowY += 13
                }
                x += width + 5
            }
        }
        .frame(height: min(size.height * 0.25, 160))
        .frame(maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, FlightTuning.groundHeight)
    }

    // MARK: - Bird

    private var bird: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(TideColors.glow.opacity(0.13 - Double(index) * 0.03))
                    .frame(width: 22 - CGFloat(index) * 4)
                    .offset(x: -CGFloat(index + 1) * 15)
            }

            Circle()
                .fill(TideColors.glow.opacity(0.24))
                .frame(width: FlightTuning.birdSize * 1.95)
                .blur(radius: 12)

            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.64, green: 0.93, blue: 1), TideColors.accentDeep],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: FlightTuning.birdSize, height: FlightTuning.birdSize)
                    .overlay {
                        Circle().stroke(.white.opacity(0.34), lineWidth: 1)
                    }
                    .shadow(color: TideColors.glow.opacity(0.65), radius: 9)

                Capsule()
                    .fill(Color(red: 0.17, green: 0.52, blue: 0.73))
                    .frame(width: 20, height: 11)
                    .rotationEffect(.degrees(-24))
                    .offset(x: -10, y: 5)

                Circle()
                    .fill(.white)
                    .frame(width: 10, height: 10)
                    .overlay {
                        Circle().fill(Color(red: 0.02, green: 0.06, blue: 0.12)).frame(width: 4.5)
                    }
                    .offset(x: 7, y: -5)

                FlappyTriangle()
                    .fill(Color(red: 1, green: 0.72, blue: 0.2))
                    .frame(width: 13, height: 8)
                    .offset(x: 21, y: 1)
            }
            .rotationEffect(.degrees(engine.birdAngle))
        }
        .position(x: engine.birdX, y: engine.birdY)
        .allowsHitTesting(false)
    }

    // MARK: - Gates

    @ViewBuilder
    private func gateView(_ gate: FlightGate, fieldHeight: CGFloat) -> some View {
        let topHeight = gate.gapY - gate.gapHeight / 2
        let bottomHeight = fieldHeight - FlightTuning.groundHeight - (gate.gapY + gate.gapHeight / 2)
        let overscan = FlightTuning.pipeVisualOverscan

        if topHeight > 0 {
            gateColumn(height: topHeight + overscan, capAtBottom: true)
                .position(x: gate.x, y: (topHeight - overscan) / 2)
        }
        if bottomHeight > 0 {
            gateColumn(height: bottomHeight + overscan, capAtBottom: false)
                .position(x: gate.x, y: gate.gapY + gate.gapHeight / 2 + (bottomHeight + overscan) / 2)
        }

        Circle()
            .fill(TideColors.glow.opacity(0.32))
            .frame(width: 7, height: 7)
            .blur(radius: 1)
            .position(x: gate.x, y: gate.gapY)
            .allowsHitTesting(false)

    }

    private func gateColumn(height: CGFloat, capAtBottom: Bool) -> some View {
        ZStack(alignment: capAtBottom ? .bottom : .top) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.03, green: 0.16, blue: 0.22),
                            TideColors.accentDeep.opacity(0.62),
                            Color(red: 0.02, green: 0.08, blue: 0.14)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: FlightTuning.pipeWidth, height: height)
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(TideColors.glow.opacity(0.42), lineWidth: 1)
                }

            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [TideColors.accent.opacity(0.82), TideColors.accentDeep.opacity(0.52)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: FlightTuning.pipeWidth + 16, height: 22)
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(.white.opacity(0.28), lineWidth: 1)
                }
                .shadow(color: TideColors.glow.opacity(0.42), radius: 8)
        }
        .allowsHitTesting(false)
    }

    // MARK: - Horizon

    private func horizon(size: CGSize) -> some View {
        VStack(spacing: 0) {
            Spacer()

            Rectangle()
                .fill(TideColors.glow.opacity(0.75))
                .frame(height: 1)
                .shadow(color: TideColors.glow, radius: 8)

            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.035, green: 0.115, blue: 0.16), Color(red: 0.012, green: 0.035, blue: 0.065)],
                    startPoint: .top,
                    endPoint: .bottom
                )

                Canvas { context, canvasSize in
                    var path = Path()
                    let spacing: CGFloat = 36
                    var x: CGFloat = -canvasSize.height
                    while x < canvasSize.width + canvasSize.height {
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x + canvasSize.height, y: canvasSize.height))
                        x += spacing
                    }
                    context.stroke(path, with: .color(TideColors.accent.opacity(0.09)), lineWidth: 1)
                }
            }
            .frame(height: FlightTuning.groundHeight)
        }
        .ignoresSafeArea(edges: .bottom)
        .allowsHitTesting(false)
    }

    // MARK: - HUD

    private func hud(size: CGSize) -> some View {
        ZStack {
            VStack(spacing: 0) {
                HStack(alignment: .center) {
                    connectionPill
                    Spacer()
                    bestPill
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Spacer()
            }

            if engine.phase == .playing {
                scoreView
                    .position(x: size.width / 2, y: 72)
            }

            if engine.phase == .idle {
                idleCard
                    .frame(maxWidth: 310)
                    .position(x: size.width / 2, y: size.height * 0.39)
            }

            if engine.phase == .dead {
                gameOverCard
                    .frame(maxWidth: 306)
                    .position(x: size.width / 2, y: size.height * 0.38)
            }
        }
        .allowsHitTesting(false)
    }

    private var connectionPill: some View {
        HStack(spacing: 8) {
            Image(systemName: manager.connectionState == .connected ? "dot.radiowaves.left.and.right" : "iphone")
                .font(.caption.weight(.bold))
                .foregroundStyle(manager.connectionState == .connected ? TideColors.accent : .orange)
                .symbolEffect(.pulse, value: ringPulse)

            Text(manager.connectionState == .connected ? "RING READY" : "SCREEN CONTROL")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(1.1)
                .foregroundStyle(.white.opacity(0.9))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.black.opacity(0.42), in: Capsule())
        .overlay {
            Capsule().stroke(.white.opacity(0.12), lineWidth: 1)
        }
    }

    private var bestPill: some View {
        HStack(spacing: 6) {
            Image(systemName: "crown.fill")
                .foregroundStyle(Color(red: 1, green: 0.78, blue: 0.3))
            Text("\(engine.best)")
                .contentTransition(.numericText())
        }
        .font(.system(size: 12, weight: .bold, design: .rounded))
        .foregroundStyle(.white.opacity(0.88))
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(.black.opacity(0.42), in: Capsule())
        .overlay {
            Capsule().stroke(.white.opacity(0.12), lineWidth: 1)
        }
    }

    private var scoreView: some View {
        Text("\(engine.score)")
            .font(.system(size: 54, weight: .black, design: .rounded))
            .monospacedDigit()
            .contentTransition(.numericText())
            .foregroundStyle(.white)
            .shadow(color: TideColors.glow.opacity(0.5), radius: 12)
            .shadow(color: .black.opacity(0.65), radius: 2, y: 2)
    }

    private var idleCard: some View {
        VStack(spacing: 19) {
            ZStack {
                Circle()
                    .fill(TideColors.glow.opacity(0.13))
                    .frame(width: 82, height: 82)
                    .blur(radius: 12)

                Image(systemName: "bird.fill")
                    .font(.system(size: 42, weight: .bold))
                    .foregroundStyle(
                        LinearGradient(colors: [.white, TideColors.accent], startPoint: .top, endPoint: .bottom)
                    )
                    .shadow(color: TideColors.glow.opacity(0.6), radius: 13)
            }

            VStack(spacing: 7) {
                Text("FLAPPY RING")
                    .font(.system(size: 31, weight: .black, design: .rounded))
                    .tracking(-0.8)
                    .foregroundStyle(.white)

                Text("Fly it from across the room.")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.58))
            }

            HStack(spacing: 10) {
                controlChip(icon: "hand.tap.fill", label: "Tap ring")
                controlChip(icon: "hand.point.up.fill", label: "Tap screen")
            }

            VStack(spacing: 7) {
                Text("TAP TO LAUNCH")
                    .font(.system(size: 12, weight: .black, design: .rounded))
                    .tracking(2)
                    .foregroundStyle(TideColors.accent)

                Text("Every tap counts — bursts are queued")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.38))
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 25)
        .background {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.black.opacity(0.37))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(
                            LinearGradient(colors: [.white.opacity(0.24), TideColors.accent.opacity(0.16), .clear], startPoint: .topLeading, endPoint: .bottomTrailing),
                            lineWidth: 1
                        )
                }
                .shadow(color: .black.opacity(0.44), radius: 30, y: 18)
        }
    }

    private func controlChip(icon: String, label: String) -> some View {
        Label(label, systemImage: icon)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.78))
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(.white.opacity(0.07), in: Capsule())
    }

    private var gameOverCard: some View {
        VStack(spacing: 20) {
            VStack(spacing: 5) {
                Text(engine.score == engine.best && engine.score > 0 ? "NEW FLIGHT RECORD" : "FLIGHT ENDED")
                    .font(.system(size: 11, weight: .black, design: .rounded))
                    .tracking(1.7)
                    .foregroundStyle(engine.score == engine.best && engine.score > 0 ? Color.yellow : TideColors.accent)

                Text("\(engine.score)")
                    .font(.system(size: 62, weight: .black, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)

                Text("GATES CLEARED")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(1.4)
                    .foregroundStyle(.white.opacity(0.38))
            }

            Divider().overlay(.white.opacity(0.12))

            HStack {
                Label("BEST", systemImage: "crown.fill")
                    .foregroundStyle(.white.opacity(0.48))
                Spacer()
                Text("\(engine.best)")
                    .foregroundStyle(.white)
            }
            .font(.system(size: 13, weight: .bold, design: .rounded))

            Text("TAP TO FLY AGAIN")
                .font(.system(size: 12, weight: .black, design: .rounded))
                .tracking(1.6)
                .foregroundStyle(TideColors.accent)
                .padding(.top, 2)
        }
        .padding(25)
        .background {
            RoundedRectangle(cornerRadius: 27, style: .continuous)
                .fill(.black.opacity(0.52))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 27, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 27, style: .continuous)
                        .stroke(.white.opacity(0.18), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
        }
    }
}

// MARK: - Shapes

private struct FlappyTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct FlappyRNG: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0xDEAD : seed
    }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
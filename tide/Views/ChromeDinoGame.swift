//
//  ChromeDinoGameView.swift
//  Tide
//
//   A one-tap endless runner controlled by the same ring gesture stream as Camera.
//

import Combine
import Foundation
import SwiftUI

// MARK: - Game tuning

private enum DinoTuning {
    static let gravity: CGFloat = 1_720
    static let jumpVelocity: CGFloat = 650

    static let dinoWidth: CGFloat = 56
    static let dinoHeight: CGFloat = 62
    static let groundHeight: CGFloat = 102

    static let baseSpeed: CGFloat = 238
    static let maximumSpeed: CGFloat = 470
    static let speedIncreasePerSecond: CGFloat = 5.5

    static let minimumSpawnDelay: Double = 0.88
    static let maximumSpawnDelay: Double = 1.52
    static let scoreDistance: CGFloat = 17
}

// MARK: - Models

private struct DinoObstacle: Identifiable {
    enum Kind: CaseIterable {
        case shortCactus
        case tallCactus
        case cactusPair

        var size: CGSize {
            switch self {
            case .shortCactus:
                return CGSize(width: 31, height: 48)
            case .tallCactus:
                return CGSize(width: 35, height: 67)
            case .cactusPair:
                return CGSize(width: 58, height: 53)
            }
        }
    }

    let id = UUID()
    let kind: Kind
    var x: CGFloat

    var width: CGFloat { kind.size.width }
    var height: CGFloat { kind.size.height }
}

// MARK: - Engine

@MainActor
private final class DinoEngine: ObservableObject {
    enum Phase: Equatable { case idle, playing, dead }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var jumpHeight: CGFloat = 0
    @Published private(set) var obstacles: [DinoObstacle] = []
    @Published private(set) var score = 0
    @Published private(set) var best = 0
    @Published private(set) var didSetNewBest = false
    @Published private(set) var speed: CGFloat = DinoTuning.baseSpeed
    @Published private(set) var groundOffset: CGFloat = 0
    @Published private(set) var runFrame = false
    @Published private(set) var jumpSequence: UInt64 = 0
    @Published private(set) var crashSequence: UInt64 = 0
    @Published private(set) var milestoneSequence: UInt64 = 0

    private var velocityY: CGFloat = 0
    private var fieldSize = CGSize(width: 390, height: 700)
    private var distance: CGFloat = 0
    private var spawnAccumulator: Double = 0
    private var nextSpawnDelay: Double = 1.25
    private var runAnimationAccumulator: Double = 0
    private var lastMilestone = 0
    private var gameTask: Task<Void, Never>?

    private let bestKey = "tide.dino.best"

    init() {
        best = UserDefaults.standard.integer(forKey: bestKey)
    }

    var dinoX: CGFloat {
        min(max(fieldSize.width * 0.22, 76), 102)
    }

    var groundY: CGFloat {
        fieldSize.height - DinoTuning.groundHeight
    }

    var dinoCenterY: CGFloat {
        groundY - DinoTuning.dinoHeight / 2 - jumpHeight
    }

    var isJumping: Bool {
        jumpHeight > 0.5 || velocityY > 0
    }

    func setFieldSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        fieldSize = size
    }

    func receiveJump() {
        switch phase {
        case .idle:
            start()
        case .playing:
            jump()
        case .dead:
            break
        }
    }

    func start() {
        gameTask?.cancel()

        obstacles.removeAll(keepingCapacity: true)
        score = 0
        didSetNewBest = false
        speed = DinoTuning.baseSpeed
        jumpHeight = 0
        velocityY = 0
        distance = 0
        groundOffset = 0
        spawnAccumulator = 0
        runAnimationAccumulator = 0
        lastMilestone = 0
        nextSpawnDelay = 1.18
        runFrame = false
        phase = .playing

        jump()

        gameTask = Task { @MainActor [weak self] in
            let clock = ContinuousClock()
            var previousTick = clock.now

            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                guard let self, self.phase == .playing else { break }

                let now = clock.now
                let elapsed = previousTick.duration(to: now)
                previousTick = now

                let seconds = Double(elapsed.components.seconds)
                    + Double(elapsed.components.attoseconds) / 1e18
                let dt = min(max(seconds, 0.001), 0.034)
                self.tick(dt: dt)
            }
        }
    }

    func resetToIdle() {
        stop()
        phase = .idle
        obstacles.removeAll(keepingCapacity: true)
        jumpHeight = 0
        velocityY = 0
        score = 0
        didSetNewBest = false
        speed = DinoTuning.baseSpeed
        groundOffset = 0
    }

    func stop() {
        gameTask?.cancel()
        gameTask = nil
    }

    private func tick(dt: Double) {
        let frameDistance = speed * dt

        speed = min(
            DinoTuning.maximumSpeed,
            speed + DinoTuning.speedIncreasePerSecond * dt
        )

        distance += frameDistance
        let newScore = Int(distance / DinoTuning.scoreDistance)
        if newScore != score {
            score = newScore

            let milestone = score / 100
            if milestone > lastMilestone {
                lastMilestone = milestone
                milestoneSequence &+= 1
            }
        }

        groundOffset = (groundOffset + frameDistance).truncatingRemainder(dividingBy: 48)

        updateJump(dt: dt)
        updateRunningAnimation(dt: dt)

        for index in obstacles.indices {
            obstacles[index].x -= frameDistance
        }
        obstacles.removeAll { $0.x + $0.width < -20 }

        spawnAccumulator += dt
        if spawnAccumulator >= nextSpawnDelay {
            spawnAccumulator = 0
            spawnObstacle()
            chooseNextSpawnDelay()
        }

        if collided() {
            die()
        }
    }

    private func updateJump(dt: Double) {
        guard jumpHeight > 0 || velocityY > 0 else {
            jumpHeight = 0
            velocityY = 0
            return
        }

        velocityY -= DinoTuning.gravity * dt
        jumpHeight += velocityY * dt

        if jumpHeight <= 0 {
            jumpHeight = 0
            velocityY = 0
        }
    }

    private func updateRunningAnimation(dt: Double) {
        guard !isJumping else { return }

        runAnimationAccumulator += dt
        if runAnimationAccumulator >= 0.105 {
            runAnimationAccumulator = 0
            runFrame.toggle()
        }
    }

    private func jump() {
        // Ring gestures arrive after the hardware recognizes the tap. Never discard one just
        // because the dino is still slightly airborne: every accepted event refreshes the upward
        // velocity immediately, matching Flappy Ring's responsive one-event/one-action behavior.
        jumpHeight = max(0, jumpHeight)
        velocityY = DinoTuning.jumpVelocity
        jumpSequence &+= 1
    }

    private func spawnObstacle() {
        let availableKinds: [DinoObstacle.Kind]

        // Keep the first few seconds beginner-friendly, then allow wider cactus pairs.
        if score < 60 {
            availableKinds = [.shortCactus, .tallCactus]
        } else {
            availableKinds = DinoObstacle.Kind.allCases
        }

        guard let kind = availableKinds.randomElement() else { return }
        obstacles.append(
            DinoObstacle(
                kind: kind,
                x: fieldSize.width + 28
            )
        )
    }

    private func chooseNextSpawnDelay() {
        let speedRatio = Double(speed / DinoTuning.baseSpeed)
        let base = Double.random(
            in: DinoTuning.minimumSpawnDelay...DinoTuning.maximumSpawnDelay
        )

        // Faster runs shorten the time gap slightly without creating impossible spacing.
        nextSpawnDelay = max(0.72, base / min(speedRatio, 1.55))
    }

    private func collided() -> Bool {
        let dinoRect = CGRect(
            x: dinoX - DinoTuning.dinoWidth / 2 + 9,
            y: groundY - DinoTuning.dinoHeight - jumpHeight + 7,
            width: DinoTuning.dinoWidth - 18,
            height: DinoTuning.dinoHeight - 12
        )

        for obstacle in obstacles {
            let obstacleRect = CGRect(
                x: obstacle.x + 4,
                y: groundY - obstacle.height + 4,
                width: max(4, obstacle.width - 8),
                height: max(4, obstacle.height - 5)
            )

            if dinoRect.intersects(obstacleRect) {
                return true
            }
        }

        return false
    }

    private func die() {
        phase = .dead
        crashSequence &+= 1
        stop()

        if score > best {
            didSetNewBest = true
            best = score
            UserDefaults.standard.set(score, forKey: bestKey)
        }
    }

    deinit {
        gameTask?.cancel()
    }
}

// MARK: - View

struct ChromeDinoGameView: View {
    private enum InputSource { case screen, ring }

    @ObservedObject var manager: RingManager
    @StateObject private var engine = DinoEngine()
    @State private var isVisible = false
    @State private var ringPulse: UInt64 = 0

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size

            ZStack {
                dinoBackground(size: size)
                horizonGlow(size: size)
                movingGround(size: size)

                ForEach(engine.obstacles) { obstacle in
                    obstacleView(obstacle)
                }

                dino
                hud(size: size)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                handleJump(from: .screen)
            }
            .onAppear {
                engine.setFieldSize(size)
            }
            .onChange(of: size) { _, newSize in
                engine.setFieldSize(newSize)
            }
        }
        .background(Color.black)
        .navigationTitle("Dino Ring")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .onAppear {
            isVisible = true
            armRingGestureIfPossible()
        }
        .onDisappear {
            isVisible = false
            engine.resetToIdle()
            manager.setCameraMode(enabled: false)
        }
        .onChange(of: manager.connectionState) { _, state in
            if isVisible, state == .connected {
                manager.setCameraMode(enabled: true)
            }
        }
        // Skip the publisher's initial value so opening the game never creates a phantom jump.
        .onReceive(manager.$cameraShutterSequence.dropFirst()) { _ in
            guard isVisible else { return }
            handleJump(from: .ring)
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: engine.jumpSequence)
        .sensoryFeedback(.error, trigger: engine.crashSequence)
        .sensoryFeedback(.success, trigger: engine.milestoneSequence)
    }

    // MARK: - Input

    private func armRingGestureIfPossible() {
        guard manager.connectionState == .connected else { return }
        manager.setCameraMode(enabled: true)
    }

    private func handleJump(from source: InputSource) {
        if engine.phase == .dead {
            engine.start()
        } else {
            engine.receiveJump()
        }

        if source == .ring {
            ringPulse &+= 1
        }
    }

    // MARK: - Background

    private func dinoBackground(size: CGSize) -> some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.012, green: 0.022, blue: 0.060),
                    Color(red: 0.018, green: 0.085, blue: 0.135),
                    Color(red: 0.025, green: 0.045, blue: 0.075)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(TideColors.glow.opacity(0.11))
                .frame(width: min(size.width * 0.86, 370))
                .blur(radius: 60)
                .offset(x: size.width * 0.30, y: -size.height * 0.28)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            .white.opacity(0.95),
                            TideColors.accent.opacity(0.35),
                            .clear
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: 50
                    )
                )
                .frame(width: 100, height: 100)
                .offset(x: size.width * 0.30, y: -size.height * 0.30)

            dinoStars
            distantDunes(size: size)

            LinearGradient(
                colors: [.clear, .black.opacity(0.28)],
                startPoint: .center,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var dinoStars: some View {
        Canvas { context, size in
            var random = DinoRNG(seed: 809)

            for _ in 0..<56 {
                let x = CGFloat.random(in: 0...size.width, using: &random)
                let y = CGFloat.random(in: 0...size.height * 0.63, using: &random)
                let radius = CGFloat.random(in: 0.45...1.45, using: &random)
                let opacity = Double.random(in: 0.10...0.56, using: &random)
                let rect = CGRect(
                    x: x - radius,
                    y: y - radius,
                    width: radius * 2,
                    height: radius * 2
                )
                context.fill(
                    Circle().path(in: rect),
                    with: .color(.white.opacity(opacity))
                )
            }
        }
    }

    private func distantDunes(size: CGSize) -> some View {
        Canvas { context, canvasSize in
            let groundY = canvasSize.height - DinoTuning.groundHeight

            var farPath = Path()
            farPath.move(to: CGPoint(x: 0, y: groundY))
            farPath.addCurve(
                to: CGPoint(x: canvasSize.width * 0.46, y: groundY - 74),
                control1: CGPoint(x: canvasSize.width * 0.12, y: groundY - 18),
                control2: CGPoint(x: canvasSize.width * 0.30, y: groundY - 90)
            )
            farPath.addCurve(
                to: CGPoint(x: canvasSize.width, y: groundY - 18),
                control1: CGPoint(x: canvasSize.width * 0.68, y: groundY - 38),
                control2: CGPoint(x: canvasSize.width * 0.80, y: groundY - 82)
            )
            farPath.addLine(to: CGPoint(x: canvasSize.width, y: groundY))
            farPath.closeSubpath()
            context.fill(
                farPath,
                with: .color(Color(red: 0.026, green: 0.082, blue: 0.12).opacity(0.82))
            )

            var nearPath = Path()
            nearPath.move(to: CGPoint(x: 0, y: groundY))
            nearPath.addCurve(
                to: CGPoint(x: canvasSize.width * 0.58, y: groundY - 38),
                control1: CGPoint(x: canvasSize.width * 0.18, y: groundY - 58),
                control2: CGPoint(x: canvasSize.width * 0.38, y: groundY - 4)
            )
            nearPath.addCurve(
                to: CGPoint(x: canvasSize.width, y: groundY - 9),
                control1: CGPoint(x: canvasSize.width * 0.74, y: groundY - 74),
                control2: CGPoint(x: canvasSize.width * 0.88, y: groundY - 25)
            )
            nearPath.addLine(to: CGPoint(x: canvasSize.width, y: groundY))
            nearPath.closeSubpath()
            context.fill(
                nearPath,
                with: .color(Color(red: 0.020, green: 0.057, blue: 0.088).opacity(0.94))
            )
        }
        .allowsHitTesting(false)
    }

    // MARK: - Dino

    private var dino: some View {
        ZStack {
            Circle()
                .fill(TideColors.glow.opacity(0.20))
                .frame(width: DinoTuning.dinoWidth * 1.65)
                .blur(radius: 15)

            DinoSprite(
                isJumping: engine.isJumping,
                alternateLeg: engine.runFrame,
                isDead: engine.phase == .dead
            )
            .frame(
                width: DinoTuning.dinoWidth,
                height: DinoTuning.dinoHeight
            )
            .shadow(color: TideColors.glow.opacity(0.44), radius: 10)
        }
        .position(x: engine.dinoX, y: engine.dinoCenterY)
        .allowsHitTesting(false)
    }

    // MARK: - Obstacles

    private func obstacleView(_ obstacle: DinoObstacle) -> some View {
        CactusSprite(kind: obstacle.kind)
            .frame(width: obstacle.width, height: obstacle.height)
            .position(
                x: obstacle.x + obstacle.width / 2,
                y: engine.groundY - obstacle.height / 2
            )
            .allowsHitTesting(false)
    }

    // MARK: - Ground

    private func horizonGlow(size: CGSize) -> some View {
        Rectangle()
            .fill(TideColors.glow.opacity(0.75))
            .frame(height: 1)
            .shadow(color: TideColors.glow.opacity(0.9), radius: 7)
            .position(x: size.width / 2, y: size.height - DinoTuning.groundHeight)
            .allowsHitTesting(false)
    }

    private func movingGround(size: CGSize) -> some View {
        VStack(spacing: 0) {
            Spacer()

            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.030, green: 0.105, blue: 0.14),
                        Color(red: 0.010, green: 0.030, blue: 0.050)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                Canvas { context, canvasSize in
                    let spacing: CGFloat = 48
                    let offset = engine.groundOffset

                    var x = -spacing - offset
                    while x < canvasSize.width + spacing {
                        let dash = CGRect(
                            x: x,
                            y: 15,
                            width: 23,
                            height: 2
                        )
                        context.fill(
                            Capsule().path(in: dash),
                            with: .color(TideColors.accent.opacity(0.20))
                        )
                        x += spacing
                    }

                    var gridPath = Path()
                    var diagonalX: CGFloat = -canvasSize.height - offset
                    while diagonalX < canvasSize.width + canvasSize.height {
                        gridPath.move(to: CGPoint(x: diagonalX, y: 0))
                        gridPath.addLine(
                            to: CGPoint(
                                x: diagonalX + canvasSize.height,
                                y: canvasSize.height
                            )
                        )
                        diagonalX += spacing
                    }
                    context.stroke(
                        gridPath,
                        with: .color(TideColors.accent.opacity(0.055)),
                        lineWidth: 1
                    )
                }
            }
            .frame(height: DinoTuning.groundHeight)
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
                    .frame(maxWidth: 314)
                    .position(x: size.width / 2, y: size.height * 0.38)
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
            Image(
                systemName: manager.connectionState == .connected
                    ? "dot.radiowaves.left.and.right"
                    : "iphone"
            )
            .font(.caption.weight(.bold))
            .foregroundStyle(
                manager.connectionState == .connected
                    ? TideColors.accent
                    : .orange
            )
            .symbolEffect(.pulse, value: ringPulse)

            Text(
                manager.connectionState == .connected
                    ? "RING READY"
                    : "SCREEN CONTROL"
            )
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

            Text(String(format: "%05d", engine.best))
                .contentTransition(.numericText())
        }
        .font(.system(size: 12, weight: .bold, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(.white.opacity(0.88))
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(.black.opacity(0.42), in: Capsule())
        .overlay {
            Capsule().stroke(.white.opacity(0.12), lineWidth: 1)
        }
    }

    private var scoreView: some View {
        VStack(spacing: 2) {
            Text(String(format: "%05d", engine.score))
                .font(.system(size: 40, weight: .black, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(.white)
                .shadow(color: TideColors.glow.opacity(0.45), radius: 11)
                .shadow(color: .black.opacity(0.65), radius: 2, y: 2)

            Text("DISTANCE")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .tracking(1.6)
                .foregroundStyle(.white.opacity(0.36))
        }
    }

    private var idleCard: some View {
        VStack(spacing: 19) {
            ZStack {
                Circle()
                    .fill(TideColors.glow.opacity(0.13))
                    .frame(width: 84, height: 84)
                    .blur(radius: 13)

                DinoSprite(
                    isJumping: false,
                    alternateLeg: false,
                    isDead: false
                )
                .frame(width: 58, height: 64)
                .shadow(color: TideColors.glow.opacity(0.60), radius: 13)
            }

            VStack(spacing: 7) {
                Text("DINO RING")
                    .font(.system(size: 31, weight: .black, design: .rounded))
                    .tracking(-0.8)
                    .foregroundStyle(.white)

                Text("Jump the desert from your finger.")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.58))
            }

            HStack(spacing: 10) {
                controlChip(icon: "hand.tap.fill", label: "Tap ring")
                controlChip(icon: "hand.point.up.fill", label: "Tap screen")
            }

            VStack(spacing: 7) {
                Text("TAP TO RUN")
                    .font(.system(size: 12, weight: .black, design: .rounded))
                    .tracking(2)
                    .foregroundStyle(TideColors.accent)

                Text("Time each jump — there is no double jump")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.38))
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 25)
        .background {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.black.opacity(0.37))
                .background(
                    .ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: 28, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [
                                    .white.opacity(0.24),
                                    TideColors.accent.opacity(0.16),
                                    .clear
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
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
                Text(
                    engine.didSetNewBest
                        ? "NEW DISTANCE RECORD"
                        : "RUN ENDED"
                )
                .font(.system(size: 11, weight: .black, design: .rounded))
                .tracking(1.7)
                .foregroundStyle(
                    engine.didSetNewBest
                        ? Color.yellow
                        : TideColors.accent
                )

                Text(String(format: "%05d", engine.score))
                    .font(.system(size: 53, weight: .black, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)

                Text("DISTANCE")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(1.4)
                    .foregroundStyle(.white.opacity(0.38))
            }

            Divider().overlay(.white.opacity(0.12))

            HStack {
                Label("BEST", systemImage: "crown.fill")
                    .foregroundStyle(.white.opacity(0.48))
                Spacer()
                Text(String(format: "%05d", engine.best))
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }
            .font(.system(size: 13, weight: .bold, design: .rounded))

            Text("TAP TO RUN AGAIN")
                .font(.system(size: 12, weight: .black, design: .rounded))
                .tracking(1.6)
                .foregroundStyle(TideColors.accent)
                .padding(.top, 2)
        }
        .padding(25)
        .background {
            RoundedRectangle(cornerRadius: 27, style: .continuous)
                .fill(.black.opacity(0.52))
                .background(
                    .ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: 27, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 27, style: .continuous)
                        .stroke(.white.opacity(0.18), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
        }
    }
}

// MARK: - Dino sprite

private struct DinoSprite: View {
    let isJumping: Bool
    let alternateLeg: Bool
    let isDead: Bool

    var body: some View {
        Canvas { context, size in
            let sx = size.width / 56
            let sy = size.height / 62

            func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
                CGRect(
                    x: x * sx,
                    y: y * sy,
                    width: width * sx,
                    height: height * sy
                )
            }

            let bodyColor = Color(red: 0.52, green: 0.90, blue: 0.98)
            let shadowColor = TideColors.accentDeep

            var tail = Path()
            tail.move(to: CGPoint(x: 18 * sx, y: 31 * sy))
            tail.addLine(to: CGPoint(x: 1 * sx, y: 24 * sy))
            tail.addLine(to: CGPoint(x: 17 * sx, y: 42 * sy))
            tail.closeSubpath()
            context.fill(tail, with: .color(shadowColor))

            context.fill(
                RoundedRectangle(cornerRadius: 5 * sx).path(in: rect(13, 25, 28, 25)),
                with: .linearGradient(
                    Gradient(colors: [bodyColor, shadowColor]),
                    startPoint: CGPoint(x: 14 * sx, y: 25 * sy),
                    endPoint: CGPoint(x: 40 * sx, y: 52 * sy)
                )
            )

            context.fill(
                RoundedRectangle(cornerRadius: 4 * sx).path(in: rect(28, 4, 24, 27)),
                with: .color(bodyColor)
            )
            context.fill(
                RoundedRectangle(cornerRadius: 2 * sx).path(in: rect(39, 21, 17, 10)),
                with: .color(bodyColor)
            )

            context.fill(
                RoundedRectangle(cornerRadius: 1.5 * sx).path(in: rect(19, 39, 7, 5)),
                with: .color(Color.white.opacity(0.18))
            )

            let eyeRect = rect(42, 10, 5, 5)
            context.fill(
                Circle().path(in: eyeRect),
                with: .color(isDead ? Color.red.opacity(0.9) : Color(red: 0.01, green: 0.04, blue: 0.07))
            )

            if isDead {
                var cross = Path()
                cross.move(to: CGPoint(x: eyeRect.minX, y: eyeRect.minY))
                cross.addLine(to: CGPoint(x: eyeRect.maxX, y: eyeRect.maxY))
                cross.move(to: CGPoint(x: eyeRect.maxX, y: eyeRect.minY))
                cross.addLine(to: CGPoint(x: eyeRect.minX, y: eyeRect.maxY))
                context.stroke(cross, with: .color(.white), lineWidth: max(1, sx))
            }

            context.fill(
                RoundedRectangle(cornerRadius: 1.5 * sx).path(in: rect(31, 31, 5, 14)),
                with: .color(shadowColor)
            )
            context.fill(
                RoundedRectangle(cornerRadius: 1.5 * sx).path(in: rect(35, 41, 9, 4)),
                with: .color(shadowColor)
            )

            if isJumping {
                context.fill(
                    RoundedRectangle(cornerRadius: 2 * sx).path(in: rect(18, 47, 8, 11)),
                    with: .color(shadowColor)
                )
                context.fill(
                    RoundedRectangle(cornerRadius: 2 * sx).path(in: rect(31, 47, 8, 11)),
                    with: .color(shadowColor)
                )
            } else if alternateLeg {
                context.fill(
                    RoundedRectangle(cornerRadius: 2 * sx).path(in: rect(17, 47, 8, 14)),
                    with: .color(shadowColor)
                )
                context.fill(
                    RoundedRectangle(cornerRadius: 2 * sx).path(in: rect(32, 47, 13, 7)),
                    with: .color(shadowColor)
                )
            } else {
                context.fill(
                    RoundedRectangle(cornerRadius: 2 * sx).path(in: rect(17, 47, 13, 7)),
                    with: .color(shadowColor)
                )
                context.fill(
                    RoundedRectangle(cornerRadius: 2 * sx).path(in: rect(32, 47, 8, 14)),
                    with: .color(shadowColor)
                )
            }

            context.stroke(
                RoundedRectangle(cornerRadius: 5 * sx).path(in: rect(13, 25, 28, 25)),
                with: .color(.white.opacity(0.26)),
                lineWidth: max(0.8, sx)
            )
        }
        .drawingGroup()
    }
}

// MARK: - Cactus sprite

private struct CactusSprite: View {
    let kind: DinoObstacle.Kind

    var body: some View {
        Canvas { context, size in
            let glow = TideColors.glow.opacity(0.24)
            let light = Color(red: 0.23, green: 0.78, blue: 0.70)
            let dark = Color(red: 0.035, green: 0.29, blue: 0.30)

            func cactusStem(in rect: CGRect) {
                context.fill(
                    RoundedRectangle(cornerRadius: rect.width * 0.28).path(in: rect),
                    with: .linearGradient(
                        Gradient(colors: [light, dark]),
                        startPoint: CGPoint(x: rect.minX, y: rect.minY),
                        endPoint: CGPoint(x: rect.maxX, y: rect.maxY)
                    )
                )
                context.stroke(
                    RoundedRectangle(cornerRadius: rect.width * 0.28).path(in: rect),
                    with: .color(.white.opacity(0.20)),
                    lineWidth: 1
                )
            }

            context.fill(
                Ellipse().path(
                    in: CGRect(
                        x: size.width * 0.06,
                        y: size.height * 0.82,
                        width: size.width * 0.88,
                        height: size.height * 0.22
                    )
                ),
                with: .color(glow)
            )

            switch kind {
            case .shortCactus:
                let stem = CGRect(
                    x: size.width * 0.34,
                    y: 0,
                    width: size.width * 0.32,
                    height: size.height
                )
                cactusStem(in: stem)
                cactusStem(
                    in: CGRect(
                        x: size.width * 0.12,
                        y: size.height * 0.38,
                        width: size.width * 0.28,
                        height: size.height * 0.19
                    )
                )
                cactusStem(
                    in: CGRect(
                        x: size.width * 0.62,
                        y: size.height * 0.24,
                        width: size.width * 0.26,
                        height: size.height * 0.22
                    )
                )

            case .tallCactus:
                let stem = CGRect(
                    x: size.width * 0.34,
                    y: 0,
                    width: size.width * 0.33,
                    height: size.height
                )
                cactusStem(in: stem)
                cactusStem(
                    in: CGRect(
                        x: size.width * 0.08,
                        y: size.height * 0.42,
                        width: size.width * 0.32,
                        height: size.height * 0.20
                    )
                )
                cactusStem(
                    in: CGRect(
                        x: size.width * 0.61,
                        y: size.height * 0.28,
                        width: size.width * 0.31,
                        height: size.height * 0.22
                    )
                )

            case .cactusPair:
                cactusStem(
                    in: CGRect(
                        x: size.width * 0.11,
                        y: size.height * 0.13,
                        width: size.width * 0.24,
                        height: size.height * 0.87
                    )
                )
                cactusStem(
                    in: CGRect(
                        x: size.width * 0.53,
                        y: 0,
                        width: size.width * 0.25,
                        height: size.height
                    )
                )
                cactusStem(
                    in: CGRect(
                        x: size.width * 0.70,
                        y: size.height * 0.34,
                        width: size.width * 0.22,
                        height: size.height * 0.19
                    )
                )
            }
        }
        .shadow(color: TideColors.glow.opacity(0.34), radius: 6)
        .drawingGroup()
    }
}

// MARK: - Deterministic background RNG

private struct DinoRNG: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0xD1A0 : seed
    }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

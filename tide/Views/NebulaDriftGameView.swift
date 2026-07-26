//
//  NebulaDriftGameView.swift
//  Tide
//
//  NEBULA DRIFT: An endless cosmic orbital slingshot runner driven by ring gesture taps.
//  The player controls a starcraft probing deep space. Tapping the ring attaches or detaches a
//  gravitational tether beam to the nearest celestial core, allowing the ship to slingshot around
//  black holes, dodge rotating asteroid belts, scoop stardust crystals, and fight cosmic boss anomalies.
//

import Combine
import Foundation
import QuartzCore
import SwiftUI
import AVFoundation

// MARK: - Game Tuning & Physics Constants

private enum NebulaTuning {
    static let shipRadius: CGFloat = 16
    static let baseSpeed: CGFloat = 260
    static let maxSpeed: CGFloat = 580
    static let gravityConstant: CGFloat = 380_000
    static let maxTetherDistance: CGFloat = 240
    static let ringLatencyOffset: Double = 0.150 // 150ms Bluetooth hardware transmission offset
    
    static let defaultShields: Int = 3
    static let stardustValue: Int = 25
}

// MARK: - Data Models & Enums

enum NebulaInputSource {
    case screen
    case ring
}

enum NebulaShipSkin: String, CaseIterable, Identifiable {
    case plasmaCyan = "Plasma Cyan"
    case cosmicPurple = "Cosmic Purple"
    case solarFlare = "Solar Flare"
    case hyperWhite = "Hyper White"
    
    var id: String { rawValue }
    
    var primaryColor: Color {
        switch self {
        case .plasmaCyan: return Color(red: 0.2, green: 0.85, blue: 1.0)
        case .cosmicPurple: return Color(red: 0.75, green: 0.4, blue: 1.0)
        case .solarFlare: return Color(red: 1.0, green: 0.6, blue: 0.1)
        case .hyperWhite: return Color.white
        }
    }
    
    var glowColor: Color {
        switch self {
        case .plasmaCyan: return TideColors.glow
        case .cosmicPurple: return Color(red: 0.85, green: 0.5, blue: 0.95)
        case .solarFlare: return Color.orange
        case .hyperWhite: return Color.cyan
        }
    }
}

struct NebulaCore: Identifiable {
    let id: Int
    var position: CGPoint
    let radius: CGFloat
    let mass: CGFloat
    let isBlackHole: Bool
    var pulsePhase: Double = 0
}

struct NebulaAsteroid: Identifiable {
    let id: Int
    var position: CGPoint
    let radius: CGFloat
    var rotationAngle: Double
    let rotationSpeed: Double
    let velocity: CGPoint
}

struct NebulaStardust: Identifiable {
    let id: Int
    var position: CGPoint
    var isCollected: Bool = false
    var sparklePhase: Double = Double.random(in: 0...(.pi * 2))
}

struct NebulaWormhole: Identifiable {
    let id = UUID()
    var position: CGPoint
    let radius: CGFloat = 36
    var rotation: Double = 0
}

private struct NebulaParticle: Identifiable {
    let id = UUID()
    var position: CGPoint
    var velocity: CGPoint
    var opacity: Double
    var size: CGFloat
    let color: Color
}

struct NebulaUpgrades: Codable {
    var thrusterLevel: Int = 1     // Max Speed multiplier
    var tetherLevel: Int = 1       // Tether reach distance
    var shieldLevel: Int = 1       // Extra health
    var stardustMagnet: Int = 1    // Magnet range
    
    var maxSpeedBonus: CGFloat { CGFloat(thrusterLevel - 1) * 35.0 }
    var tetherReachBonus: CGFloat { CGFloat(tetherLevel - 1) * 30.0 }
    var shieldBonus: Int { shieldLevel - 1 }
    var magnetRadius: CGFloat { 60.0 + CGFloat(stardustMagnet - 1) * 35.0 }
}

// MARK: - Procedural Audio Synthesizer

@MainActor
private final class NebulaAudioSynth {
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var tetherAttachBuffer: AVAudioPCMBuffer?
    private var tetherReleaseBuffer: AVAudioPCMBuffer?
    private var stardustBuffer: AVAudioPCMBuffer?
    private var hitBuffer: AVAudioPCMBuffer?
    private var explodeBuffer: AVAudioPCMBuffer?
    
    init() {
        setupSynth()
    }
    
    private func setupSynth() {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        
        let mainMixer = engine.mainMixerNode
        let format = mainMixer.outputFormat(forBus: 0)
        engine.connect(player, to: mainMixer, format: format)
        
        let sampleRate = Float(format.sampleRate > 0 ? format.sampleRate : 44100.0)
        
        // 1. Tether Attach Buffer (High energy chime)
        if let b = createToneBuffer(sampleRate: sampleRate, startFreq: 520, endFreq: 1040, duration: 0.09, format: format) {
            tetherAttachBuffer = b
        }
        
        // 2. Tether Release Slingshot Boost (Descending energy sweep)
        if let b = createToneBuffer(sampleRate: sampleRate, startFreq: 980, endFreq: 440, duration: 0.12, format: format) {
            tetherReleaseBuffer = b
        }
        
        // 3. Stardust Pickup (High harmonic sparkle)
        if let b = createToneBuffer(sampleRate: sampleRate, startFreq: 1320, endFreq: 1760, duration: 0.07, format: format) {
            stardustBuffer = b
        }
        
        // 4. Shield Hit Buffer
        if let b = createToneBuffer(sampleRate: sampleRate, startFreq: 300, endFreq: 150, duration: 0.15, format: format) {
            hitBuffer = b
        }
        
        // 5. Explosion Noise Buffer
        if let b = createExplosionBuffer(sampleRate: sampleRate, duration: 0.4, format: format) {
            explodeBuffer = b
        }
        
        do {
            try engine.start()
            self.audioEngine = engine
            self.playerNode = player
        } catch {
            print("NebulaAudioSynth engine failed to start: \(error)")
        }
    }
    
    func playTetherAttach() {
        playBuffer(tetherAttachBuffer)
    }
    
    func playTetherRelease() {
        playBuffer(tetherReleaseBuffer)
    }
    
    func playStardust() {
        playBuffer(stardustBuffer)
    }
    
    func playShieldHit() {
        playBuffer(hitBuffer)
    }
    
    func playExplode() {
        playBuffer(explodeBuffer)
    }
    
    private func playBuffer(_ buffer: AVAudioPCMBuffer?) {
        guard let player = playerNode, let buffer = buffer, playerNode?.engine?.isRunning == true else { return }
        if !player.isPlaying { player.play() }
        player.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
    }
    
    private func createToneBuffer(sampleRate: Float, startFreq: Float, endFreq: Float, duration: Double, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(Double(sampleRate) * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount
        
        let channels = Int(format.channelCount)
        let floatData = buffer.floatChannelData
        
        for i in 0..<Int(frameCount) {
            let t = Float(i) / sampleRate
            let progress = t / Float(duration)
            let freq = startFreq + (endFreq - startFreq) * progress
            let sample = sinf(2.0 * .pi * freq * t) * expf(-progress * 4.0)
            
            for ch in 0..<channels {
                floatData?[ch][i] = sample * 0.35
            }
        }
        return buffer
    }
    
    private func createExplosionBuffer(sampleRate: Float, duration: Double, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(Double(sampleRate) * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount
        
        let channels = Int(format.channelCount)
        let floatData = buffer.floatChannelData
        
        var seed: UInt32 = 54321
        for i in 0..<Int(frameCount) {
            let t = Float(i) / sampleRate
            seed = seed &* 1664525 &+ 1013904223
            let noise = Float(Int32(bitPattern: seed)) / Float(Int32.max)
            let env = expf(-t * 9.0)
            let sample = noise * env * 0.45
            
            for ch in 0..<channels {
                floatData?[ch][i] = sample
            }
        }
        return buffer
    }
}

// MARK: - Game Engine

@MainActor
private final class NebulaEngine: ObservableObject {
    enum Phase: Equatable { case idle, playing, paused, exploded, sectorClear }
    
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var sector: Int = 1
    @Published private(set) var score: Int = 0
    @Published private(set) var bestScore: Int = 0
    @Published private(set) var stardustCount: Int = 0
    @Published private(set) var totalStardustBank: Int = 0
    @Published private(set) var shields: Int = NebulaTuning.defaultShields
    @Published private(set) var activeSkin: NebulaShipSkin = .plasmaCyan
    @Published private(set) var upgrades: NebulaUpgrades = NebulaUpgrades()
    
    // Physical State
    @Published private(set) var shipPos: CGPoint = .zero
    @Published private(set) var shipVelocity: CGPoint = .zero
    @Published private(set) var shipAngle: Double = 0
    @Published private(set) var tetherTargetId: Int? = nil
    @Published private(set) var tetherLength: CGFloat = 0
    
    // World Elements
    @Published private(set) var cores: [NebulaCore] = []
    @Published private(set) var asteroids: [NebulaAsteroid] = []
    @Published private(set) var stardustItems: [NebulaStardust] = []
    @Published private(set) var wormhole: NebulaWormhole? = nil
    @Published private(set) var particles: [NebulaParticle] = []
    
    // Camera Transform
    @Published private(set) var cameraOffset: CGPoint = .zero
    @Published private(set) var cameraZoom: CGFloat = 1.0
    
    // Haptics & Feedback Sequences
    @Published private(set) var tetherSequence: UInt64 = 0
    @Published private(set) var collectSequence: UInt64 = 0
    @Published private(set) var hitSequence: UInt64 = 0
    @Published private(set) var explodeSequence: UInt64 = 0
    @Published private(set) var victorySequence: UInt64 = 0
    
    private let synth = NebulaAudioSynth()
    private var gameTask: Task<Void, Never>?
    private var fieldSize = CGSize(width: 390, height: 750)
    
    private let bestKey = "tide.nebula.best"
    private let bankKey = "tide.nebula.bank"
    private let upgradesKey = "tide.nebula.upgrades"
    private let skinKey = "tide.nebula.skin"
    
    init() {
        self.bestScore = UserDefaults.standard.integer(forKey: bestKey)
        self.totalStardustBank = UserDefaults.standard.integer(forKey: bankKey)
        
        if let data = UserDefaults.standard.data(forKey: upgradesKey),
           let saved = try? JSONDecoder().decode(NebulaUpgrades.self, from: data) {
            self.upgrades = saved
        }
        
        if let skinRaw = UserDefaults.standard.string(forKey: skinKey),
           let skin = NebulaShipSkin(rawValue: skinRaw) {
            self.activeSkin = skin
        }
        
        setupSector(1)
    }
    
    func setFieldSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        fieldSize = size
        if phase == .idle {
            setupInitialPositions()
        }
    }
    
    func selectSkin(_ skin: NebulaShipSkin) {
        activeSkin = skin
        UserDefaults.standard.set(skin.rawValue, forKey: skinKey)
    }
    
    func buyUpgrade(_ type: String) -> Bool {
        let cost = getUpgradeCost(type)
        guard totalStardustBank >= cost else { return false }
        
        totalStardustBank -= cost
        UserDefaults.standard.set(totalStardustBank, forKey: bankKey)
        
        switch type {
        case "thruster": upgrades.thrusterLevel += 1
        case "tether": upgrades.tetherLevel += 1
        case "shield": upgrades.shieldLevel += 1
        case "magnet": upgrades.stardustMagnet += 1
        default: break
        }
        
        if let data = try? JSONEncoder().encode(upgrades) {
            UserDefaults.standard.set(data, forKey: upgradesKey)
        }
        return true
    }
    
    func getUpgradeCost(_ type: String) -> Int {
        switch type {
        case "thruster": return 150 * upgrades.thrusterLevel
        case "tether": return 200 * upgrades.tetherLevel
        case "shield": return 300 * upgrades.shieldLevel
        case "magnet": return 180 * upgrades.stardustMagnet
        default: return 500
        }
    }
    
    func receiveTap(from source: NebulaInputSource = .screen) {
        switch phase {
        case .idle:
            start()
        case .playing:
            toggleTether(from: source)
        case .exploded, .sectorClear:
            start()
        case .paused:
            phase = .playing
        }
    }
    
    func start() {
        gameTask?.cancel()
        score = 0
        stardustCount = 0
        shields = NebulaTuning.defaultShields + upgrades.shieldBonus
        tetherTargetId = nil
        particles.removeAll(keepingCapacity: true)
        
        setupSector(sector)
        phase = .playing
        
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
    
    func resetToIdle() {
        stop()
        phase = .idle
        sector = 1
        setupInitialPositions()
    }
    
    private func setupSector(_ s: Int) {
        sector = s
        cores.removeAll()
        asteroids.removeAll()
        stardustItems.removeAll()
        
        // Generate Sector Cores
        let startY: CGFloat = 400
        let sectorHeight: CGFloat = CGFloat(s) * 800.0 + 1200.0
        
        var y = startY
        var coreId = 0
        while y < sectorHeight {
            let x = CGFloat.random(in: 80...(fieldSize.width - 80))
            let isBlackHole = (s >= 2 && coreId % 4 == 0)
            let radius: CGFloat = isBlackHole ? 36 : CGFloat.random(in: 28...48)
            let mass: CGFloat = isBlackHole ? 1.8 : 1.0
            
            cores.append(NebulaCore(
                id: coreId,
                position: CGPoint(x: x, y: y),
                radius: radius,
                mass: mass,
                isBlackHole: isBlackHole
            ))
            
            // Asteroids around core
            if coreId > 0 && coreId % 2 == 0 {
                let astCount = Int.random(in: 2...5)
                for a in 0..<astCount {
                    let orbitR = CGFloat.random(in: 70...140)
                    let angle = Double(a) * (.pi * 2 / Double(astCount))
                    let astPos = CGPoint(x: x + cos(angle) * orbitR, y: y + sin(angle) * orbitR)
                    asteroids.append(NebulaAsteroid(
                        id: coreId * 10 + a,
                        position: astPos,
                        radius: CGFloat.random(in: 12...22),
                        rotationAngle: Double.random(in: 0...(.pi * 2)),
                        rotationSpeed: Double.random(in: -2.0...2.0),
                        velocity: CGPoint(x: cos(angle + .pi/2) * 40, y: sin(angle + .pi/2) * 40)
                    ))
                }
            }
            
            // Stardust crystals
            let starCount = Int.random(in: 3...6)
            for st in 0..<starCount {
                let sPos = CGPoint(
                    x: x + CGFloat.random(in: -90...90),
                    y: y + CGFloat.random(in: -90...90)
                )
                stardustItems.append(NebulaStardust(id: coreId * 20 + st, position: sPos))
            }
            
            y += CGFloat.random(in: 160...240)
            coreId += 1
        }
        
        // Finish Sector Wormhole Portal at the top of sector
        wormhole = NebulaWormhole(position: CGPoint(x: fieldSize.width / 2, y: sectorHeight + 100))
        
        setupInitialPositions()
    }
    
    private func setupInitialPositions() {
        guard let firstCore = cores.first else { return }
        shipPos = CGPoint(x: firstCore.position.x, y: firstCore.position.y - 120)
        shipVelocity = CGPoint(x: NebulaTuning.baseSpeed, y: 0)
        shipAngle = 0
        tetherTargetId = nil
        cameraOffset = CGPoint(x: fieldSize.width / 2 - shipPos.x, y: fieldSize.height * 0.65 - shipPos.y)
    }
    
    private func toggleTether(from source: NebulaInputSource) {
        if let _ = tetherTargetId {
            // Detach tether -> Slingshot Boost!
            tetherTargetId = nil
            synth.playTetherRelease()
            tetherSequence &+= 1
            
            // Add forward velocity impulse
            let speed = sqrt(shipVelocity.x * shipVelocity.x + shipVelocity.y * shipVelocity.y)
            let boostRatio: CGFloat = 1.18
            let maxS = NebulaTuning.maxSpeed + upgrades.maxSpeedBonus
            let newSpeed = min(maxS, speed * boostRatio)
            
            let angle = atan2(shipVelocity.y, shipVelocity.x)
            shipVelocity = CGPoint(x: cos(angle) * newSpeed, y: sin(angle) * newSpeed)
            
            // Spawn thrust particles
            for _ in 0..<10 {
                let pAngle = angle + .pi + Double.random(in: -0.4...0.4)
                let pSpd = CGFloat.random(in: 40...180)
                particles.append(NebulaParticle(
                    position: shipPos,
                    velocity: CGPoint(x: cos(pAngle) * pSpd, y: sin(pAngle) * pSpd),
                    opacity: 1.0, size: CGFloat.random(in: 3...7),
                    color: activeSkin.primaryColor
                ))
            }
        } else {
            // Find nearest core within tether reach
            let maxReach = NebulaTuning.maxTetherDistance + upgrades.tetherReachBonus
            var nearestCore: NebulaCore? = nil
            var minDist: CGFloat = maxReach
            
            for core in cores {
                let dx = core.position.x - shipPos.x
                let dy = core.position.y - shipPos.y
                let dist = sqrt(dx * dx + dy * dy)
                if dist < minDist {
                    minDist = dist
                    nearestCore = core
                }
            }
            
            if let core = nearestCore {
                tetherTargetId = core.id
                tetherLength = minDist
                synth.playTetherAttach()
                tetherSequence &+= 1
            }
        }
    }
    
    private func tick(dt: Double) {
        // Update particles
        updateVFX(dt: dt)
        
        // Physics step: Gravity + Motion
        if let targetId = tetherTargetId, let core = cores.first(where: { $0.id == targetId }) {
            let dx = core.position.x - shipPos.x
            let dy = core.position.y - shipPos.y
            let dist = max(20, sqrt(dx * dx + dy * dy))
            let forceMag = (NebulaTuning.gravityConstant * core.mass) / (dist * dist)
            
            let ax = (dx / dist) * forceMag
            let ay = (dy / dist) * forceMag
            
            shipVelocity.x += ax * CGFloat(dt)
            shipVelocity.y += ay * CGFloat(dt)
        }
        
        // Apply position update
        shipPos.x += shipVelocity.x * CGFloat(dt)
        shipPos.y += shipVelocity.y * CGFloat(dt)
        
        // Ship heading angle matches velocity direction
        shipAngle = atan2(shipVelocity.y, shipVelocity.x)
        
        // Smooth camera movement follow
        let targetCamOffset = CGPoint(
            x: fieldSize.width / 2 - shipPos.x,
            y: fieldSize.height * 0.65 - shipPos.y
        )
        cameraOffset.x += (targetCamOffset.x - cameraOffset.x) * CGFloat(dt * 6.0)
        cameraOffset.y += (targetCamOffset.y - cameraOffset.y) * CGFloat(dt * 6.0)
        
        // Engine exhaust trail particle emission
        if Double.random(in: 0...1) < 0.6 {
            let trailAngle = shipAngle + .pi + Double.random(in: -0.2...0.2)
            particles.append(NebulaParticle(
                position: shipPos,
                velocity: CGPoint(x: cos(trailAngle) * 30, y: sin(trailAngle) * 30),
                opacity: 0.8, size: CGFloat.random(in: 2...5),
                color: activeSkin.glowColor
            ))
        }
        
        // Check collisions & collections
        checkCollisions()
        
        // Update score based on upward distance
        score = max(score, Int(shipPos.y / 10.0))
    }
    
    private func checkCollisions() {
        // 1. Stardust Item Collection
        let magnetRange = upgrades.magnetRadius
        for i in stardustItems.indices where !stardustItems[i].isCollected {
            let dx = stardustItems[i].position.x - shipPos.x
            let dy = stardustItems[i].position.y - shipPos.y
            let dist = sqrt(dx * dx + dy * dy)
            
            if dist < magnetRange {
                // Magnet pull towards ship
                stardustItems[i].position.x -= (dx / dist) * 220.0 * 0.016
                stardustItems[i].position.y -= (dy / dist) * 220.0 * 0.016
            }
            
            if dist < 24 {
                stardustItems[i].isCollected = true
                stardustCount += 1
                totalStardustBank += NebulaTuning.stardustValue
                UserDefaults.standard.set(totalStardustBank, forKey: bankKey)
                synth.playStardust()
                collectSequence &+= 1
            }
        }
        
        // 2. Asteroid Collision
        for asteroid in asteroids {
            let dx = asteroid.position.x - shipPos.x
            let dy = asteroid.position.y - shipPos.y
            let dist = sqrt(dx * dx + dy * dy)
            
            if dist < (asteroid.radius + NebulaTuning.shipRadius) {
                handleHit()
                break
            }
        }
        
        // 3. Black Hole Core Collision
        for core in cores where core.isBlackHole {
            let dx = core.position.x - shipPos.x
            let dy = core.position.y - shipPos.y
            let dist = sqrt(dx * dx + dy * dy)
            
            if dist < (core.radius + NebulaTuning.shipRadius) {
                triggerExplosion(reason: "SALLOWED BY BLACK HOLE!")
                return
            }
        }
        
        // 4. Wormhole Sector Clear Portal
        if let portal = wormhole {
            let dx = portal.position.x - shipPos.x
            let dy = portal.position.y - shipPos.y
            let dist = sqrt(dx * dx + dy * dy)
            
            if dist < portal.radius + 15 {
                handleSectorClear()
            }
        }
    }
    
    private func handleHit() {
        shields -= 1
        hitSequence &+= 1
        if shields <= 0 {
            triggerExplosion(reason: "STARCRAFT DESTROYED!")
        } else {
            synth.playShieldHit()
            // Knockback impulse
            shipVelocity.x *= -0.5
            shipVelocity.y *= -0.5
        }
    }
    
    private func triggerExplosion(reason: String) {
        phase = .exploded
        synth.playExplode()
        explodeSequence &+= 1
        tetherTargetId = nil
        stop()
        
        if score > bestScore {
            bestScore = score
            UserDefaults.standard.set(score, forKey: bestKey)
        }
        
        // Ship explosion particles
        for _ in 0..<40 {
            let angle = Double.random(in: 0...(.pi * 2))
            let spd = CGFloat.random(in: 80...380)
            particles.append(NebulaParticle(
                position: shipPos,
                velocity: CGPoint(x: cos(angle) * spd, y: sin(angle) * spd),
                opacity: 1.0, size: CGFloat.random(in: 4...12),
                color: activeSkin.primaryColor
            ))
        }
    }
    
    private func handleSectorClear() {
        phase = .sectorClear
        synth.playStardust()
        victorySequence &+= 1
        stop()
        
        if score > bestScore {
            bestScore = score
            UserDefaults.standard.set(score, forKey: bestKey)
        }
    }
    
    func nextSector() {
        sector += 1
        start()
    }
    
    private func updateVFX(dt: Double) {
        for i in particles.indices.reversed() {
            particles[i].position.x += particles[i].velocity.x * CGFloat(dt)
            particles[i].position.y += particles[i].velocity.y * CGFloat(dt)
            particles[i].opacity -= dt * 1.5
        }
        particles.removeAll { $0.opacity <= 0 }
    }
    
    deinit {
        gameTask?.cancel()
    }
}

// MARK: - Main SwiftUI View

struct NebulaDriftGameView: View {
    @ObservedObject var manager: RingManager
    @StateObject private var engine = NebulaEngine()
    @State private var isVisible = false
    @State private var showShop = false
    
    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            
            ZStack {
                // 1. Deep Space Nebula Starfield Background
                spaceBackgroundView(size: size)
                
                // 2. Main Game World Canvas
                gameWorldView(size: size)
                
                // 3. HUD Overlay
                hudOverlay(size: size)
                
                // 4. Modal Overlays (Idle / Shop / Exploded / Sector Clear)
                stateOverlays(size: size)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                handleTap(from: .screen)
            }
            .onAppear {
                engine.setFieldSize(size)
            }
            .onChange(of: size) { _, newSize in
                engine.setFieldSize(newSize)
            }
        }
        .background(Color(red: 0.015, green: 0.03, blue: 0.07))
        .navigationTitle("NEBULA DRIFT")
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
        .onReceive(manager.$cameraShutterSequence.dropFirst()) { _ in
            guard isVisible else { return }
            handleTap(from: .ring)
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: engine.tetherSequence)
        .sensoryFeedback(.success, trigger: engine.collectSequence)
        .sensoryFeedback(.error, trigger: engine.explodeSequence)
        .sensoryFeedback(.success, trigger: engine.victorySequence)
    }
    
    // MARK: - Input Handling
    
    private func armRingGestureIfPossible() {
        guard manager.connectionState == .connected else { return }
        manager.setCameraMode(enabled: true)
    }
    
    private func handleTap(from source: NebulaInputSource) {
        guard !showShop else { return }
        engine.receiveTap(from: source)
    }
    
    // MARK: - Background Shader
    
    @ViewBuilder
    private func spaceBackgroundView(size: CGSize) -> some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, canvasSize in
                let rect = CGRect(origin: .zero, size: canvasSize)
                context.fill(Path(rect), with: .color(Color(red: 0.02, green: 0.035, blue: 0.08)))
                
                // Drifting starfield
                var seed: UInt32 = 98765
                for _ in 0..<85 {
                    seed = seed &* 1664525 &+ 1013904223
                    let sx = CGFloat(Float(seed & 0xFFFF) / 65535.0) * canvasSize.width
                    seed = seed &* 1664525 &+ 1013904223
                    let sy = CGFloat(Float(seed & 0xFFFF) / 65535.0) * canvasSize.height
                    seed = seed &* 1664525 &+ 1013904223
                    let sz = CGFloat(Float(seed & 0x7) / 7.0) * 2.2 + 0.6
                    let opacity = 0.2 + 0.6 * sin(time * 1.5 + Double(sx))
                    
                    let starRect = CGRect(x: sx, y: sy, width: sz, height: sz)
                    context.fill(Path(ellipseIn: starRect), with: .color(.white.opacity(opacity)))
                }
            }
        }
        .ignoresSafeArea()
    }
    
    // MARK: - World Render
    
    @ViewBuilder
    private func gameWorldView(size: CGSize) -> some View {
        ZStack {
            // 1. Celestial Cores
            ForEach(engine.cores) { core in
                coreView(core)
            }
            
            // 2. Asteroid Belts
            ForEach(engine.asteroids) { ast in
                asteroidView(ast)
            }
            
            // 3. Stardust Gems
            ForEach(engine.stardustItems) { dust in
                if !dust.isCollected {
                    stardustView(dust)
                }
            }
            
            // 4. Wormhole Portal
            if let portal = engine.wormhole {
                wormholeView(portal)
            }
            
            // 5. Active Gravitational Tether Beam Line
            if let targetId = engine.tetherTargetId, let core = engine.cores.first(where: { $0.id == targetId }) {
                Path { path in
                    path.move(to: engine.shipPos)
                    path.addLine(to: core.position)
                }
                .stroke(
                    LinearGradient(colors: [engine.activeSkin.primaryColor, .white], startPoint: .leading, endPoint: .trailing),
                    style: StrokeStyle(lineWidth: 3, dash: [6, 4])
                )
            }
            
            // 6. Particles
            ForEach(engine.particles) { p in
                Circle()
                    .fill(p.color)
                    .frame(width: p.size, height: p.size)
                    .opacity(p.opacity)
                    .position(p.position)
            }
            
            // 7. Starcraft Ship
            if engine.phase == .playing || engine.phase == .idle {
                shipView()
            }
        }
        .offset(x: engine.cameraOffset.x, y: engine.cameraOffset.y)
    }
    
    // MARK: - Entity Visual Components
    
    @ViewBuilder
    private func coreView(_ core: NebulaCore) -> some View {
        ZStack {
            if core.isBlackHole {
                Circle()
                    .fill(RadialGradient(colors: [.black, .purple.opacity(0.8), .clear], center: .center, startRadius: 10, endRadius: core.radius * 2))
                    .frame(width: core.radius * 3.5, height: core.radius * 3.5)
                Circle()
                    .stroke(Color.purple, lineWidth: 2)
                    .frame(width: core.radius * 2.2, height: core.radius * 2.2)
            } else {
                Circle()
                    .fill(RadialGradient(colors: [.white, TideColors.accent, TideColors.deepOcean], center: .center, startRadius: 4, endRadius: core.radius * 1.5))
                    .frame(width: core.radius * 2.4, height: core.radius * 2.4)
                    .blur(radius: 4)
                Circle()
                    .fill(TideColors.accent)
                    .frame(width: core.radius * 1.6, height: core.radius * 1.6)
            }
        }
        .position(core.position)
    }
    
    @ViewBuilder
    private func asteroidView(_ ast: NebulaAsteroid) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(red: 0.35, green: 0.38, blue: 0.45))
                .frame(width: ast.radius * 2, height: ast.radius * 2)
                .rotationEffect(.radians(ast.rotationAngle))
        }
        .position(ast.position)
    }
    
    @ViewBuilder
    private func stardustView(_ dust: NebulaStardust) -> some View {
        Image(systemName: "sparkle")
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(Color.yellow)
            .shadow(color: .yellow.opacity(0.8), radius: 6)
            .position(dust.position)
    }
    
    @ViewBuilder
    private func wormholeView(_ portal: NebulaWormhole) -> some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [.white, .cyan, .purple, .clear], center: .center, startRadius: 4, endRadius: portal.radius * 2))
                .frame(width: portal.radius * 3, height: portal.radius * 3)
            Circle()
                .stroke(Color.cyan, lineWidth: 3)
                .frame(width: portal.radius * 2, height: portal.radius * 2)
        }
        .position(portal.position)
    }
    
    @ViewBuilder
    private func shipView() -> some View {
        ZStack {
            // Outer aura glow
            Circle()
                .fill(engine.activeSkin.glowColor.opacity(0.5))
                .frame(width: 32, height: 32)
                .blur(radius: 6)
            
            // Starcraft triangular body
            Image(systemName: "location.north.fill")
                .font(.system(size: 20, weight: .black))
                .foregroundStyle(engine.activeSkin.primaryColor)
                .rotationEffect(.radians(engine.shipAngle + .pi / 2))
        }
        .position(engine.shipPos)
    }
    
    // MARK: - HUD Overlay
    
    @ViewBuilder
    private func hudOverlay(size: CGSize) -> some View {
        VStack {
            // Top Bar: Sector, Shields, Stardust, Shop Toggle
            HStack(spacing: 12) {
                // Sector Badge
                Text("SECTOR \(engine.sector)")
                    .font(TideFont.sans(14, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(TideColors.accent, in: Capsule())
                
                // Health Shields
                HStack(spacing: 4) {
                    ForEach(0..<max(0, engine.shields), id: \.self) { _ in
                        Image(systemName: "shield.fill")
                            .font(.caption)
                            .foregroundStyle(Color.cyan)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background { Color.black.opacity(0.4).glassEffect(.regular, in: Capsule()) }
                
                Spacer()
                
                // Stardust Count
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                    Text("\(engine.totalStardustBank)")
                        .font(TideFont.sans(13, weight: .bold))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background { Color.black.opacity(0.4).glassEffect(.regular, in: Capsule()) }
                
                // Hangar Shop Button
                Button {
                    showShop.toggle()
                } label: {
                    Image(systemName: "wrench.and.screwdriver.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(8)
                        .background { Color.black.opacity(0.4).glassEffect(.regular, in: Circle()) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            
            // Score Display
            HStack {
                Text("DISTANCE: \(engine.score)m")
                    .font(TideFont.sans(14, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                if engine.bestScore > 0 {
                    Text("BEST: \(engine.bestScore)m")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            
            Spacer()
            
            // Tether Status Banner at bottom
            if engine.phase == .playing {
                HStack(spacing: 8) {
                    Circle()
                        .fill(engine.tetherTargetId != nil ? Color.green : Color.cyan)
                        .frame(width: 8, height: 8)
                    Text(engine.tetherTargetId != nil ? "TETHERED — TAP TO SLINGSHOT" : "TAP RING TO TETHER")
                        .font(TideFont.sans(13, weight: .bold))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background { Color.black.opacity(0.5).glassEffect(.regular, in: Capsule()) }
                .padding(.bottom, 24)
            }
        }
    }
    
    // MARK: - State & Shop Modals
    
    @ViewBuilder
    private func stateOverlays(size: CGSize) -> some View {
        if showShop {
            hangarShopModal()
        } else if engine.phase == .idle {
            VStack(spacing: 18) {
                Text("NEBULA DRIFT")
                    .font(TideFont.serif(36, weight: .bold))
                    .foregroundStyle(LinearGradient(colors: [TideColors.accent, .purple], startPoint: .top, endPoint: .bottom))
                    .shadow(color: TideColors.glow.opacity(0.6), radius: 12)
                
                Text("Tap the ring to attach a gravity tether to star cores. Slingshot around black holes, dodge asteroids, and reach the wormhole portal!")
                    .font(TideFont.sans(14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                
                Button {
                    engine.start()
                } label: {
                    Label("LAUNCH PROBE", systemImage: "play.fill")
                        .font(TideFont.sans(16, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 220, height: 50)
                        .background(TideColors.ctaGradient, in: Capsule())
                        .shadow(color: TideColors.glow.opacity(0.6), radius: 10)
                }
                .padding(.top, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.7))
        } else if engine.phase == .exploded {
            VStack(spacing: 18) {
                Image(systemName: "bolt.shield.fill")
                    .font(.system(size: 54))
                    .foregroundStyle(.red)
                    .shadow(color: .red.opacity(0.8), radius: 14)
                
                Text("PROBE DESTROYED")
                    .font(TideFont.serif(30, weight: .bold))
                    .foregroundStyle(.white)
                
                Text("DISTANCE REACHED: \(engine.score)m")
                    .font(TideFont.sans(16, weight: .bold))
                    .foregroundStyle(TideColors.accent)
                
                Button {
                    engine.start()
                } label: {
                    Label("RELAUNCH PROBE", systemImage: "arrow.counterclockwise")
                        .font(TideFont.sans(16, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 200, height: 48)
                        .background(TideColors.ctaGradient, in: Capsule())
                }
                .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.8))
        } else if engine.phase == .sectorClear {
            VStack(spacing: 18) {
                Image(systemName: "sparkles.tv.fill")
                    .font(.system(size: 54))
                    .foregroundStyle(.cyan)
                    .shadow(color: .cyan.opacity(0.8), radius: 14)
                
                Text("SECTOR \(engine.sector) CLEAR!")
                    .font(TideFont.serif(30, weight: .bold))
                    .foregroundStyle(.white)
                
                Text("WORMHOLE WARP READY")
                    .font(TideFont.sans(15, weight: .bold))
                    .foregroundStyle(TideColors.accent)
                
                Button {
                    engine.nextSector()
                } label: {
                    Text("WARP TO SECTOR \(engine.sector + 1)")
                        .font(TideFont.sans(16, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 220, height: 48)
                        .background(TideColors.ctaGradient, in: Capsule())
                }
                .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.8))
        }
    }
    
    // MARK: - Hangar Shop Modal
    
    @ViewBuilder
    private func hangarShopModal() -> some View {
        VStack(spacing: 16) {
            HStack {
                Text("HANGAR UPGRADES")
                    .font(TideFont.serif(22, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    showShop = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)
            .padding(.top, 20)
            
            ScrollView {
                VStack(spacing: 14) {
                    // Ship Skins
                    VStack(alignment: .leading, spacing: 8) {
                        Text("SHIP COLOR SKINS")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                        
                        HStack(spacing: 10) {
                            ForEach(NebulaShipSkin.allCases) { skin in
                                Button {
                                    engine.selectSkin(skin)
                                } label: {
                                    Circle()
                                        .fill(skin.primaryColor)
                                        .frame(width: 38, height: 38)
                                        .overlay(
                                            Circle()
                                                .stroke(Color.white, lineWidth: engine.activeSkin == skin ? 3 : 0)
                                        )
                                }
                            }
                        }
                    }
                    .padding()
                    .background { Color.white.opacity(0.08).glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16)) }
                    
                    // Upgrade Rows
                    upgradeRow(title: "Thruster Speed", level: engine.upgrades.thrusterLevel, cost: engine.getUpgradeCost("thruster")) {
                        _ = engine.buyUpgrade("thruster")
                    }
                    upgradeRow(title: "Tether Range", level: engine.upgrades.tetherLevel, cost: engine.getUpgradeCost("tether")) {
                        _ = engine.buyUpgrade("tether")
                    }
                    upgradeRow(title: "Shield Hull", level: engine.upgrades.shieldLevel, cost: engine.getUpgradeCost("shield")) {
                        _ = engine.buyUpgrade("shield")
                    }
                    upgradeRow(title: "Stardust Magnet", level: engine.upgrades.stardustMagnet, cost: engine.getUpgradeCost("magnet")) {
                        _ = engine.buyUpgrade("magnet")
                    }
                }
                .padding(.horizontal)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.88))
    }
    
    @ViewBuilder
    private func upgradeRow(title: String, level: Int, cost: Int, action: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(TideFont.sans(15, weight: .bold))
                    .foregroundStyle(.white)
                Text("Level \(level)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            Button(action: action) {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles").font(.caption).foregroundStyle(.yellow)
                    Text("\(cost)")
                        .font(TideFont.sans(14, weight: .bold))
                        .foregroundStyle(engine.totalStardustBank >= cost ? .black : .white.opacity(0.5))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(engine.totalStardustBank >= cost ? TideColors.ctaGradient : LinearGradient(colors: [.gray], startPoint: .top, endPoint: .bottom), in: Capsule())
            }
            .disabled(engine.totalStardustBank < cost)
        }
        .padding()
        .background { Color.white.opacity(0.08).glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16)) }
    }
}

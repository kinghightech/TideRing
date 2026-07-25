//
//  RipTideGameView.swift
//  Tide
//
//  RIPTIDE: An insanely difficult, liquid-glass rhythm game driven by ring taps.
//  Two glowing orbs (Blue Water Orb & White Moon Orb) orbit each other along a floating tile path
//  over a reactive dark ocean. Every ring press makes the orbiting orb land on the next tile.
//  Press exactly on the beat to continue; press too early or late to explode and restart.
//

import Combine
import Foundation
import QuartzCore
import SwiftUI
import AVFoundation

// MARK: - Game Tuning & Constants

private enum RipTideTuning {
    static let baseOrbitRadius: CGFloat = 38
    static let tileSize: CGFloat = 28
    static let defaultBPM: Double = 75.0
    static let ringLatencyOffset: Double = 0.150   // 150ms Bluetooth hardware transmission offset
    
    // Timing windows (in seconds) - Generous & forgiving for ring gestures
    static let perfectWindowEasy: Double = 0.380   // ±380ms
    static let perfectWindowMedium: Double = 0.300 // ±300ms
    static let perfectWindowHard: Double = 0.220   // ±220ms
    static let perfectWindowEvil: Double = 0.160   // ±160ms
    static let perfectWindowUltraEvil: Double = 0.120 // ±120ms
}

// MARK: - Data Models

enum RipTideInputSource {
    case screen
    case ring
}

enum RipTideOrbRole: Equatable {
    case blueWater    // Blue water orb is the pivot, White moon orb is orbiting
    case whiteMoon    // White moon orb is the pivot, Blue water orb is orbiting
}

struct RipTideTile: Identifiable {
    let id: Int
    let position: CGPoint           // Tile position in track coordinate system
    let beatDuration: Double        // Duration (in seconds) to land on this tile from previous
    let isCorner: Bool              // Sharp corner (rapid)
    let isDecoy: Bool               // Fake three-way branch tile (visual mind game)
    let disappearsEarly: Bool       // Fades out 250ms before beat
    let cameraAngleDelta: Double    // Angle twist on press
    let targetZoom: CGFloat         // Dynamic camera zoom factor
    let isSilentBeat: Bool          // Silent section (music drops out)
    let isReverse: Bool             // Reverse orbit direction
}

private struct WaterRipple: Identifiable {
    let id = UUID()
    let center: CGPoint
    var radius: CGFloat
    let maxRadius: CGFloat
    var opacity: Double
    let color: Color
}

private struct WaterParticle: Identifiable {
    let id = UUID()
    var position: CGPoint
    var velocity: CGPoint
    var opacity: Double
    var size: CGFloat
    let color: Color
}

// MARK: - Procedural Audio Synthesizer

@MainActor
private final class RipTideAudioSynth {
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var hitBuffer: AVAudioPCMBuffer?
    private var beatBuffer: AVAudioPCMBuffer?
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
        
        // Build Hit Sound Buffer (high sine tone + fast decay)
        if let b = createToneBuffer(sampleRate: sampleRate, frequency: 880, duration: 0.08, format: format, sweep: -200) {
            hitBuffer = b
        }
        
        // Build Beat Tick Buffer (muffled woodblock tick)
        if let b = createToneBuffer(sampleRate: sampleRate, frequency: 440, duration: 0.04, format: format, sweep: 0) {
            beatBuffer = b
        }
        
        // Build Explosion Buffer (low noise burst)
        if let b = createExplosionBuffer(sampleRate: sampleRate, duration: 0.35, format: format) {
            explodeBuffer = b
        }
        
        do {
            try engine.start()
            self.audioEngine = engine
            self.playerNode = player
        } catch {
            print("RipTideAudioSynth engine failed to start: \(error)")
        }
    }
    
    func playHit() {
        guard let player = playerNode, let buffer = hitBuffer, playerNode?.engine?.isRunning == true else { return }
        if !player.isPlaying { player.play() }
        player.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
    }
    
    func playBeatTick() {
        guard let player = playerNode, let buffer = beatBuffer, playerNode?.engine?.isRunning == true else { return }
        if !player.isPlaying { player.play() }
        player.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
    }
    
    func playExplode() {
        guard let player = playerNode, let buffer = explodeBuffer, playerNode?.engine?.isRunning == true else { return }
        if !player.isPlaying { player.play() }
        player.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
    }
    
    private func createToneBuffer(sampleRate: Float, frequency: Float, duration: Double, format: AVAudioFormat, sweep: Float) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(Double(sampleRate) * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount
        
        let channels = Int(format.channelCount)
        let floatData = buffer.floatChannelData
        
        for i in 0..<Int(frameCount) {
            let t = Float(i) / sampleRate
            let freq = frequency + sweep * (t / Float(duration))
            let sample = sinf(2.0 * .pi * freq * t) * expf(-t * 30.0) // damped sine envelope
            
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
        
        var seed: UInt32 = 12345
        for i in 0..<Int(frameCount) {
            let t = Float(i) / sampleRate
            // White noise * low-frequency rumble envelope
            seed = seed &* 1664525 &+ 1013904223
            let noise = Float(Int32(bitPattern: seed)) / Float(Int32.max)
            let env = expf(-t * 12.0)
            let sample = noise * env * (1.0 - sinf(2.0 * .pi * 80.0 * t)) * 0.5
            
            for ch in 0..<channels {
                floatData?[ch][i] = sample
            }
        }
        return buffer
    }
}

// MARK: - Level Preset Generator

private struct RipTideLevelPreset {
    let levelNumber: Int
    let name: String
    let subtitle: String
    let totalTimeSeconds: Double
    let baseBPM: Double
    let tiles: [RipTideTile]
    let decoyTiles: [RipTideTile] // Off-path decoy visual mind game tiles
}

private enum RipTideLevelFactory {
    static func buildLevel(_ level: Int) -> RipTideLevelPreset {
        switch level {
        case 1:
            return buildLevel1()
        case 2:
            return buildLevel2()
        case 3:
            return buildLevel3()
        case 4:
            return buildLevel4()
        case 5:
            return buildLevel5()
        case 6:
            return buildLevel6()
        default:
            return buildLevel7()
        }
    }
    
    // Level 1: "Calm Waters" (Relaxed 65 BPM intro)
    private static func buildLevel1() -> RipTideLevelPreset {
        var tiles: [RipTideTile] = []
        var decoys: [RipTideTile] = []
        let bpm = 65.0
        let beatSec = 60.0 / bpm
        var currentPos = CGPoint(x: 180, y: 550)
        var currentAngle: Double = -.pi / 2 // Move up
        
        tiles.append(RipTideTile(
            id: 0, position: currentPos, beatDuration: beatSec,
            isCorner: false, isDecoy: false, disappearsEarly: false,
            cameraAngleDelta: 0, targetZoom: 1.0, isSilentBeat: false, isReverse: false
        ))
        
        let stepCount = 38
        for i in 1...stepCount {
            let isCorner = (i % 6 == 0)
            if isCorner {
                currentAngle += (i % 12 == 0) ? .pi / 3 : -.pi / 3
            }
            
            let dist: CGFloat = isCorner ? 52 : 68
            currentPos.x += cos(currentAngle) * dist
            currentPos.y += sin(currentAngle) * dist
            
            let dur = isCorner ? beatSec * 0.75 : beatSec
            
            tiles.append(RipTideTile(
                id: i, position: currentPos, beatDuration: dur,
                isCorner: isCorner, isDecoy: false, disappearsEarly: false,
                cameraAngleDelta: 0, targetZoom: 1.0, isSilentBeat: false, isReverse: false
            ))
        }
        
        return RipTideLevelPreset(
            levelNumber: 1, name: "Calm Waters", subtitle: "Tap on the exact beat to orbit along the path.",
            totalTimeSeconds: 45.0, baseBPM: bpm, tiles: tiles, decoyTiles: decoys
        )
    }
    
    // Level 2: "Riptide Surge" (Gentle 75 BPM zigzags)
    private static func buildLevel2() -> RipTideLevelPreset {
        var tiles: [RipTideTile] = []
        var decoys: [RipTideTile] = []
        var bpm = 75.0
        var beatSec = 60.0 / bpm
        var currentPos = CGPoint(x: 180, y: 600)
        var currentAngle: Double = -.pi / 2
        
        tiles.append(RipTideTile(
            id: 0, position: currentPos, beatDuration: beatSec,
            isCorner: false, isDecoy: false, disappearsEarly: false,
            cameraAngleDelta: 0, targetZoom: 1.0, isSilentBeat: false, isReverse: false
        ))
        
        let stepCount = 58
        for i in 1...stepCount {
            let isZigZag = (i >= 12 && i <= 28)
            let isSpiral = (i >= 36 && i <= 48)
            
            if isZigZag {
                currentAngle += (i % 2 == 0) ? .pi / 2.2 : -.pi / 2.2
            } else if isSpiral {
                currentAngle -= .pi / 5.5
                bpm += 2.5 // Accelerating BPM!
                beatSec = 60.0 / bpm
            } else if i % 5 == 0 {
                currentAngle += .pi / 3
            }
            
            let dur = isZigZag ? (i % 2 == 0 ? beatSec * 0.5 : beatSec * 1.2) : beatSec
            let dist: CGFloat = 62
            currentPos.x += cos(currentAngle) * dist
            currentPos.y += sin(currentAngle) * dist
            
            let zoom: CGFloat = isSpiral ? 1.25 : 1.0
            
            tiles.append(RipTideTile(
                id: i, position: currentPos, beatDuration: dur,
                isCorner: isZigZag, isDecoy: false, disappearsEarly: false,
                cameraAngleDelta: 0, targetZoom: zoom, isSilentBeat: false, isReverse: false
            ))
        }
        
        return RipTideLevelPreset(
            levelNumber: 2, name: "Riptide Surge", subtitle: "Zigzags & accelerating spirals. Stay in sync!",
            totalTimeSeconds: 60.0, baseBPM: 115.0, tiles: tiles, decoyTiles: decoys
        )
    }
    
    // Level 3: "Abyssal Mind" (82 BPM board rotation & decoys)
    private static func buildLevel3() -> RipTideLevelPreset {
        var tiles: [RipTideTile] = []
        var decoys: [RipTideTile] = []
        let bpm = 82.0
        let beatSec = 60.0 / bpm
        var currentPos = CGPoint(x: 180, y: 620)
        var currentAngle: Double = -.pi / 2
        
        tiles.append(RipTideTile(
            id: 0, position: currentPos, beatDuration: beatSec,
            isCorner: false, isDecoy: false, disappearsEarly: false,
            cameraAngleDelta: 0, targetZoom: 1.0, isSilentBeat: false, isReverse: false
        ))
        
        let stepCount = 74
        for i in 1...stepCount {
            if i % 4 == 0 { currentAngle += .pi / 4 }
            if i % 7 == 0 { currentAngle -= .pi / 3 }
            
            let dist: CGFloat = 60
            currentPos.x += cos(currentAngle) * dist
            currentPos.y += sin(currentAngle) * dist
            
            let disappears = (i >= 20 && i % 3 == 0)
            let isDecoyBranch = (i % 8 == 0)
            
            if isDecoyBranch {
                // Add fake decoy tile branching off visually
                let decoyAngle = currentAngle + .pi / 2
                let decoyPos = CGPoint(x: currentPos.x + cos(decoyAngle) * 55, y: currentPos.y + sin(decoyAngle) * 55)
                decoys.append(RipTideTile(
                    id: 1000 + i, position: decoyPos, beatDuration: beatSec,
                    isCorner: false, isDecoy: true, disappearsEarly: false,
                    cameraAngleDelta: 0, targetZoom: 1.0, isSilentBeat: false, isReverse: false
                ))
            }
            
            tiles.append(RipTideTile(
                id: i, position: currentPos, beatDuration: beatSec,
                isCorner: false, isDecoy: false, disappearsEarly: disappears,
                cameraAngleDelta: 0.05, targetZoom: 1.0 + (sin(Double(i) * 0.3) * 0.2),
                isSilentBeat: false, isReverse: (i >= 50 && i <= 60)
            ))
        }
        
        return RipTideLevelPreset(
            levelNumber: 3, name: "Abyssal Mind", subtitle: "Rotating path, disappearing tiles & ghost decoys.",
            totalTimeSeconds: 75.0, baseBPM: bpm, tiles: tiles, decoyTiles: decoys
        )
    }
    
    // Level 4: "Tsunami Chaos" (90 BPM steady cadence)
    private static func buildLevel4() -> RipTideLevelPreset {
        var tiles: [RipTideTile] = []
        var decoys: [RipTideTile] = []
        var bpm = 90.0
        var beatSec = 60.0 / bpm
        var currentPos = CGPoint(x: 180, y: 640)
        var currentAngle: Double = -.pi / 2
        
        tiles.append(RipTideTile(
            id: 0, position: currentPos, beatDuration: beatSec,
            isCorner: false, isDecoy: false, disappearsEarly: false,
            cameraAngleDelta: 0, targetZoom: 1.0, isSilentBeat: false, isReverse: false
        ))
        
        let stepCount = 98
        for i in 1...stepCount {
            if i % 3 == 0 { currentAngle += .pi / 3.5 }
            if i % 5 == 0 { currentAngle -= .pi / 2.8 }
            
            // Sudden BPM spike near end
            if i > 70 { bpm = 150.0; beatSec = 60.0 / bpm }
            
            let isSilent = (i >= 35 && i <= 42) // 7-beat silent drop!
            let isFinalSection = (i >= 80)
            let angleShift: Double = isFinalSection ? .pi / 4 : 0.08
            
            let dist: CGFloat = 58
            currentPos.x += cos(currentAngle) * dist
            currentPos.y += sin(currentAngle) * dist
            
            if i % 6 == 0 {
                let decoyAngle = currentAngle - .pi / 2
                let decoyPos = CGPoint(x: currentPos.x + cos(decoyAngle) * 58, y: currentPos.y + sin(decoyAngle) * 58)
                decoys.append(RipTideTile(
                    id: 2000 + i, position: decoyPos, beatDuration: beatSec,
                    isCorner: false, isDecoy: true, disappearsEarly: false,
                    cameraAngleDelta: 0, targetZoom: 1.0, isSilentBeat: false, isReverse: false
                ))
            }
            
            tiles.append(RipTideTile(
                id: i, position: currentPos, beatDuration: beatSec,
                isCorner: (i % 4 == 0), isDecoy: false, disappearsEarly: (i % 2 == 0),
                cameraAngleDelta: angleShift, targetZoom: 1.0 + (sin(Double(i) * 0.4) * 0.3),
                isSilentBeat: isSilent, isReverse: (i >= 60 && i <= 72)
            ))
        }
        
        return RipTideLevelPreset(
            levelNumber: 4, name: "Tsunami Chaos (EVIL)", subtitle: "Silent drop, camera flips, sub-50ms window. NO CHECKPOINTS.",
            totalTimeSeconds: 90.0, baseBPM: 135.0, tiles: tiles, decoyTiles: decoys
        )
    }
    
    // Level 5: "Maelstrom Mirage" (96 BPM dual orbit illusions)
    private static func buildLevel5() -> RipTideLevelPreset {
        var tiles: [RipTideTile] = []
        var decoys: [RipTideTile] = []
        var bpm = 96.0
        var beatSec = 60.0 / bpm
        var currentPos = CGPoint(x: 180, y: 680)
        var currentAngle: Double = -.pi / 2
        
        tiles.append(RipTideTile(
            id: 0, position: currentPos, beatDuration: beatSec,
            isCorner: false, isDecoy: false, disappearsEarly: false,
            cameraAngleDelta: 0, targetZoom: 1.0, isSilentBeat: false, isReverse: false
        ))
        
        let stepCount = 129
        for i in 1...stepCount {
            if i > 40 && i <= 80 {
                bpm = 155.0
                beatSec = 60.0 / bpm
            } else if i > 80 {
                bpm = 170.0
                beatSec = 60.0 / bpm
            }
            
            let isZigZag = (i >= 20 && i <= 45)
            let isSpiral = (i >= 60 && i <= 95)
            let isReverse = (i >= 30 && i <= 45) || (i >= 100 && i <= 115)
            let disappears = (i >= 50 && i % 2 == 0)
            
            if isZigZag {
                currentAngle += (i % 2 == 0) ? .pi / 2.4 : -.pi / 2.4
            } else if isSpiral {
                currentAngle += .pi / 4.8
            } else if i % 4 == 0 {
                currentAngle -= .pi / 3.2
            }
            
            let dist: CGFloat = (i % 8 == 0) ? 45 : 56
            currentPos.x += cos(currentAngle) * dist
            currentPos.y += sin(currentAngle) * dist
            
            // Generate visual decoy branching mind-game tiles
            if i % 5 == 0 {
                let decoyAngle = currentAngle + (i % 2 == 0 ? .pi / 2 : -.pi / 2)
                let decoyPos = CGPoint(x: currentPos.x + cos(decoyAngle) * 52, y: currentPos.y + sin(decoyAngle) * 52)
                decoys.append(RipTideTile(
                    id: 3000 + i, position: decoyPos, beatDuration: beatSec,
                    isCorner: false, isDecoy: true, disappearsEarly: false,
                    cameraAngleDelta: 0, targetZoom: 1.0, isSilentBeat: false, isReverse: false
                ))
            }
            
            let dur = isZigZag ? (i % 2 == 0 ? beatSec * 0.45 : beatSec * 1.1) : beatSec
            let zoom: CGFloat = 1.0 + (sin(Double(i) * 0.25) * 0.35)
            let angleShift: Double = (i % 6 == 0) ? .pi / 6 : 0.04
            
            tiles.append(RipTideTile(
                id: i, position: currentPos, beatDuration: dur,
                isCorner: (i % 3 == 0), isDecoy: false, disappearsEarly: disappears,
                cameraAngleDelta: angleShift, targetZoom: zoom,
                isSilentBeat: (i >= 72 && i <= 76), isReverse: isReverse
            ))
        }
        
        return RipTideLevelPreset(
            levelNumber: 5, name: "Maelstrom Mirage", subtitle: "170 BPM bursts, dual orbit illusions & 130-tile path.",
            totalTimeSeconds: 105.0, baseBPM: 140.0, tiles: tiles, decoyTiles: decoys
        )
    }
    
    // Level 6: "Vortex Ascension" (102 BPM ascending spiral)
    private static func buildLevel6() -> RipTideLevelPreset {
        var tiles: [RipTideTile] = []
        var decoys: [RipTideTile] = []
        var bpm = 102.0
        var beatSec = 60.0 / bpm
        var currentPos = CGPoint(x: 180, y: 720)
        var currentAngle: Double = -.pi / 2
        
        tiles.append(RipTideTile(
            id: 0, position: currentPos, beatDuration: beatSec,
            isCorner: false, isDecoy: false, disappearsEarly: false,
            cameraAngleDelta: 0, targetZoom: 1.0, isSilentBeat: false, isReverse: false
        ))
        
        let stepCount = 164
        for i in 1...stepCount {
            if i > 50 && i <= 100 {
                bpm = 165.0
                beatSec = 60.0 / bpm
            } else if i > 100 {
                bpm = 178.0
                beatSec = 60.0 / bpm
            }
            
            let isSilentDrop = (i >= 30 && i <= 36) || (i >= 85 && i <= 92) || (i >= 140 && i <= 147)
            let isSpiralAscent = (i >= 40 && i <= 80) || (i >= 110 && i <= 150)
            let isReverse = (i >= 65 && i <= 85)
            let disappears = (i >= 25 && i % 2 == 0)
            
            if isSpiralAscent {
                currentAngle -= .pi / 4.2
            } else if i % 3 == 0 {
                currentAngle += (i % 6 == 0) ? .pi / 2.6 : -.pi / 2.6
            }
            
            let dist: CGFloat = isSpiralAscent ? 48 : 54
            currentPos.x += cos(currentAngle) * dist
            currentPos.y += sin(currentAngle) * dist
            
            // Decoy mazes
            if i % 4 == 0 {
                let decoyAngle1 = currentAngle + .pi / 2.2
                let decoyPos1 = CGPoint(x: currentPos.x + cos(decoyAngle1) * 50, y: currentPos.y + sin(decoyAngle1) * 50)
                decoys.append(RipTideTile(
                    id: 4000 + i, position: decoyPos1, beatDuration: beatSec,
                    isCorner: false, isDecoy: true, disappearsEarly: false,
                    cameraAngleDelta: 0, targetZoom: 1.0, isSilentBeat: false, isReverse: false
                ))
            }
            
            let zoom: CGFloat = isSpiralAscent ? 1.35 : 0.95
            let angleShift: Double = (i > 120) ? .pi / 4.5 : 0.06
            
            tiles.append(RipTideTile(
                id: i, position: currentPos, beatDuration: beatSec,
                isCorner: (i % 3 == 0), isDecoy: false, disappearsEarly: disappears,
                cameraAngleDelta: angleShift, targetZoom: zoom,
                isSilentBeat: isSilentDrop, isReverse: isReverse
            ))
        }
        
        return RipTideLevelPreset(
            levelNumber: 6, name: "Vortex Ascension", subtitle: "3 silent drops, 178 BPM spiral ascent & 165 tiles.",
            totalTimeSeconds: 120.0, baseBPM: 155.0, tiles: tiles, decoyTiles: decoys
        )
    }
    
    // Level 7: "NEPTUNE'S WRATH" (110 BPM climax)
    private static func buildLevel7() -> RipTideLevelPreset {
        var tiles: [RipTideTile] = []
        var decoys: [RipTideTile] = []
        var bpm = 110.0
        var beatSec = 60.0 / bpm
        var currentPos = CGPoint(x: 180, y: 750)
        var currentAngle: Double = -.pi / 2
        
        tiles.append(RipTideTile(
            id: 0, position: currentPos, beatDuration: beatSec,
            isCorner: false, isDecoy: false, disappearsEarly: false,
            cameraAngleDelta: 0, targetZoom: 1.0, isSilentBeat: false, isReverse: false
        ))
        
        let stepCount = 199
        for i in 1...stepCount {
            if i > 60 && i <= 120 {
                bpm = 175.0
                beatSec = 60.0 / bpm
            } else if i > 120 {
                bpm = 185.0 // Brutal 185 BPM climax!
                beatSec = 60.0 / bpm
            }
            
            let isClimax = (i >= 150)
            let isSilentDrop = (i >= 45 && i <= 52) || (i >= 115 && i <= 123)
            let isReverse = (i >= 70 && i <= 90) || (i >= 160 && i <= 180)
            let disappears = (i >= 30) // Tiles flicker out almost everywhere!
            
            if i % 2 == 0 {
                currentAngle += (i % 4 == 0) ? .pi / 2.3 : -.pi / 2.3
            } else if i % 5 == 0 {
                currentAngle -= .pi / 3.5
            }
            
            let dist: CGFloat = isClimax ? 44 : 52
            currentPos.x += cos(currentAngle) * dist
            currentPos.y += sin(currentAngle) * dist
            
            if i % 3 == 0 {
                let decoyAngle = currentAngle + (i % 2 == 0 ? .pi / 2 : -.pi / 2)
                let decoyPos = CGPoint(x: currentPos.x + cos(decoyAngle) * 48, y: currentPos.y + sin(decoyAngle) * 48)
                decoys.append(RipTideTile(
                    id: 5000 + i, position: decoyPos, beatDuration: beatSec,
                    isCorner: false, isDecoy: true, disappearsEarly: false,
                    cameraAngleDelta: 0, targetZoom: 1.0, isSilentBeat: false, isReverse: false
                ))
            }
            
            let dur = (i % 4 == 0) ? beatSec * 0.4 : beatSec
            let zoom: CGFloat = isClimax ? 1.45 : 1.0
            let angleShift: Double = isClimax ? .pi / 3.5 : 0.12 // Extreme camera flips!
            
            tiles.append(RipTideTile(
                id: i, position: currentPos, beatDuration: dur,
                isCorner: true, isDecoy: false, disappearsEarly: disappears,
                cameraAngleDelta: angleShift, targetZoom: zoom,
                isSilentBeat: isSilentDrop, isReverse: isReverse
            ))
        }
        
        return RipTideLevelPreset(
            levelNumber: 7, name: "NEPTUNE'S WRATH (ULTRA EVIL)", subtitle: "The ultimate 200-tile gauntlet. 185 BPM, ±30ms window, zero mercy.",
            totalTimeSeconds: 135.0, baseBPM: 165.0, tiles: tiles, decoyTiles: decoys
        )
    }
}

// MARK: - Game Engine

@MainActor
private final class RipTideEngine: ObservableObject {
    enum Phase: Equatable { case idle, playing, exploded, victory }
    
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var currentLevelIndex: Int = 1
    @Published private(set) var currentTileIndex: Int = 0
    @Published private(set) var activeRole: RipTideOrbRole = .blueWater
    @Published private(set) var score: Int = 0
    @Published private(set) var combo: Int = 0
    @Published private(set) var maxCombo: Int = 0
    @Published private(set) var bestScore: Int = 0
    @Published private(set) var feedbackText: String = ""
    @Published private(set) var feedbackColor: Color = .white
    @Published private(set) var feedbackSequence: UInt64 = 0
    @Published private(set) var hitSequence: UInt64 = 0
    @Published private(set) var explodeSequence: UInt64 = 0
    @Published private(set) var victorySequence: UInt64 = 0
    
    // Orb & Camera Visual Transform
    @Published private(set) var blueOrbPos: CGPoint = .zero
    @Published private(set) var whiteOrbPos: CGPoint = .zero
    @Published private(set) var ghostBlueOrbPos: CGPoint = .zero
    @Published private(set) var ghostWhiteOrbPos: CGPoint = .zero
    @Published private(set) var cameraOffset: CGPoint = .zero
    @Published private(set) var cameraRotation: Double = 0
    @Published private(set) var cameraZoom: CGFloat = 1.0
    @Published private(set) var isSilentMode: Bool = false
    
    // Water VFX & Particles
    @Published private(set) var ripples: [WaterRipple] = []
    @Published private(set) var particles: [WaterParticle] = []
    @Published private(set) var oceanTime: Double = 0
    
    // Level Presets
    private(set) var preset: RipTideLevelPreset
    private let synth = RipTideAudioSynth()
    private var gameTask: Task<Void, Never>?
    
    // Beat Timing Tracking
    private var stepStartTime: Double = 0
    private var currentBeatDuration: Double = 0.5
    private var orbAngle: Double = 0
    private var orbitDirection: Double = 1.0 // 1.0 = CW, -1.0 = CCW
    private var fieldSize = CGSize(width: 390, height: 750)
    
    private let bestKeyPrefix = "tide.riptide.best."
    
    init(level: Int = 1) {
        self.currentLevelIndex = level
        self.preset = RipTideLevelFactory.buildLevel(level)
        self.bestScore = UserDefaults.standard.integer(forKey: bestKeyPrefix + "\(level)")
        setupInitialPositions()
    }
    
    func selectLevel(_ level: Int) {
        stop()
        currentLevelIndex = level
        preset = RipTideLevelFactory.buildLevel(level)
        bestScore = UserDefaults.standard.integer(forKey: bestKeyPrefix + "\(level)")
        phase = .idle
        setupInitialPositions()
    }
    
    func setFieldSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        fieldSize = size
        if phase == .idle {
            setupInitialPositions()
        }
    }
    
    private func setupInitialPositions() {
        guard !preset.tiles.isEmpty else { return }
        let startTile = preset.tiles[0]
        blueOrbPos = startTile.position
        whiteOrbPos = CGPoint(x: startTile.position.x + RipTideTuning.baseOrbitRadius, y: startTile.position.y)
        cameraOffset = CGPoint(x: fieldSize.width / 2 - startTile.position.x, y: fieldSize.height * 0.62 - startTile.position.y)
        cameraRotation = 0
        cameraZoom = 1.0
        currentTileIndex = 0
        activeRole = .blueWater
        ripples.removeAll()
        particles.removeAll()
    }
    
    func receiveTap(from source: RipTideInputSource = .screen) {
        switch phase {
        case .idle:
            start()
        case .playing:
            evaluateTap(from: source)
        case .exploded, .victory:
            start()
        }
    }
    
    func start() {
        gameTask?.cancel()
        currentTileIndex = 0
        score = 0
        combo = 0
        maxCombo = 0
        activeRole = .blueWater
        cameraRotation = 0
        cameraZoom = 1.0
        orbitDirection = 1.0
        isSilentMode = false
        ripples.removeAll(keepingCapacity: true)
        particles.removeAll(keepingCapacity: true)
        
        setupInitialPositions()
        phase = .playing
        
        let startTile = preset.tiles[0]
        stepStartTime = CACurrentMediaTime()
        currentBeatDuration = startTile.beatDuration
        orbAngle = 0
        
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
        setupInitialPositions()
    }
    
    private func tick(dt: Double) {
        oceanTime += dt
        updateVFX(dt: dt)
        
        guard currentTileIndex < preset.tiles.count else { return }
        
        let now = CACurrentMediaTime()
        let elapsedInStep = now - stepStartTime
        
        let targetTileIndex = min(currentTileIndex + 1, preset.tiles.count - 1)
        let currentTile = preset.tiles[currentTileIndex]
        let targetTile = preset.tiles[targetTileIndex]
        
        isSilentMode = targetTile.isSilentBeat
        
        // Reverse section check
        if targetTile.isReverse {
            orbitDirection = -1.0
        } else {
            orbitDirection = 1.0
        }
        
        // Calculate orbit angle
        // One beat = 180 degrees sweep to line up with next tile
        let targetAngle = atan2(targetTile.position.y - currentTile.position.y, targetTile.position.x - currentTile.position.x)
        let progress = elapsedInStep / currentBeatDuration
        orbAngle = targetAngle - .pi + (progress * .pi * orbitDirection)
        
        let pivotPos = (activeRole == .blueWater) ? currentTile.position : currentTile.position
        let orbitingOffset = CGPoint(
            x: cos(orbAngle) * RipTideTuning.baseOrbitRadius,
            y: sin(orbAngle) * RipTideTuning.baseOrbitRadius
        )
        
        if activeRole == .blueWater {
            blueOrbPos = pivotPos
            whiteOrbPos = CGPoint(x: pivotPos.x + orbitingOffset.x, y: pivotPos.y + orbitingOffset.y)
        } else {
            whiteOrbPos = pivotPos
            blueOrbPos = CGPoint(x: pivotPos.x + orbitingOffset.x, y: pivotPos.y + orbitingOffset.y)
        }
        
        // Secondary decoy orbit pair update (Level 3 & 4 mind games)
        if preset.levelNumber >= 3 {
            let ghostOffset = CGPoint(x: cos(orbAngle + .pi / 3) * (RipTideTuning.baseOrbitRadius * 1.2), y: sin(orbAngle + .pi / 3) * (RipTideTuning.baseOrbitRadius * 1.2))
            ghostBlueOrbPos = CGPoint(x: pivotPos.x + 35 + ghostOffset.x, y: pivotPos.y - 25 + ghostOffset.y)
            ghostWhiteOrbPos = CGPoint(x: pivotPos.x + 35, y: pivotPos.y - 25)
        }
        
        // Smooth camera follow
        let targetCamOffset = CGPoint(
            x: fieldSize.width / 2 - pivotPos.x,
            y: fieldSize.height * 0.58 - pivotPos.y
        )
        cameraOffset.x += (targetCamOffset.x - cameraOffset.x) * CGFloat(dt * 8.0)
        cameraOffset.y += (targetCamOffset.y - cameraOffset.y) * CGFloat(dt * 8.0)
        
        let targetCamZoom = targetTile.targetZoom
        cameraZoom += (targetCamZoom - cameraZoom) * CGFloat(dt * 4.0)
        
        // Track canvas rotation
        if preset.levelNumber >= 3 {
            cameraRotation += targetTile.cameraAngleDelta * dt * 0.5
        }
        
        // Missed beat check (overstayed beat tolerance window)
        let maxTolerance = getTimingWindow() + 0.250
        if elapsedInStep > (currentBeatDuration + maxTolerance) {
            triggerExplosion(reason: "TOO LATE!")
        }
    }
    
    private func evaluateTap(from source: RipTideInputSource) {
        let now = CACurrentMediaTime()
        var elapsedInStep = now - stepStartTime
        
        // Hardware Bluetooth latency compensation: ring gestures take ~150ms to transmit over BLE
        if source == .ring {
            elapsedInStep = max(0, elapsedInStep - RipTideTuning.ringLatencyOffset)
        }
        
        let delta = elapsedInStep - currentBeatDuration // Difference from perfect beat
        let absDelta = abs(delta)
        let tolerance = getTimingWindow()
        
        if absDelta <= tolerance {
            // SUCCESSFUL HIT!
            handleHit(delta: delta)
        } else {
            // MISSED / EXPLODE!
            let reason = delta < 0 ? "TOO EARLY!" : "TOO LATE!"
            triggerExplosion(reason: reason)
        }
    }
    
    private func handleHit(delta: Double) {
        currentTileIndex += 1
        combo += 1
        maxCombo = max(maxCombo, combo)
        score += 100 + (combo * 15)
        
        let targetTile = preset.tiles[min(currentTileIndex, preset.tiles.count - 1)]
        
        // Swap active orb role
        activeRole = (activeRole == .blueWater) ? .whiteMoon : .blueWater
        
        // Reset step timing for next tile
        stepStartTime = CACurrentMediaTime()
        currentBeatDuration = targetTile.beatDuration
        
        // Audio & Visual feedback
        if !isSilentMode {
            synth.playHit()
        }
        hitSequence &+= 1
        
        // Instant camera angle snap in evil level section
        if targetTile.cameraAngleDelta != 0 {
            cameraRotation += targetTile.cameraAngleDelta
        }
        
        // Spawn water ripple & shockwave particles
        let hitPos = targetTile.position
        ripples.append(WaterRipple(center: hitPos, radius: 8, maxRadius: 110, opacity: 0.9, color: activeRole == .blueWater ? TideColors.accent : .white))
        
        for _ in 0..<12 {
            let angle = Double.random(in: 0...(.pi * 2))
            let spd = CGFloat.random(in: 60...220)
            particles.append(WaterParticle(
                position: hitPos,
                velocity: CGPoint(x: cos(angle) * spd, y: sin(angle) * spd),
                opacity: 1.0, size: CGFloat.random(in: 3...7),
                color: activeRole == .blueWater ? TideColors.accent : .white
            ))
        }
        
        // Rating feedback text
        let absD = abs(delta)
        if absD < 0.025 {
            feedbackText = "PERFECT!"
            feedbackColor = Color(red: 0.3, green: 1.0, blue: 0.8)
        } else {
            feedbackText = "GOOD!"
            feedbackColor = TideColors.accent
        }
        feedbackSequence &+= 1
        
        // Check Victory
        if currentTileIndex >= preset.tiles.count - 1 {
            handleVictory()
        }
    }
    
    private func triggerExplosion(reason: String) {
        phase = .exploded
        synth.playExplode()
        explodeSequence &+= 1
        feedbackText = reason
        feedbackColor = .red
        feedbackSequence &+= 1
        stop()
        
        // Explosion particle burst
        let explodePos = (activeRole == .blueWater) ? whiteOrbPos : blueOrbPos
        for _ in 0..<36 {
            let angle = Double.random(in: 0...(.pi * 2))
            let spd = CGFloat.random(in: 100...450)
            particles.append(WaterParticle(
                position: explodePos,
                velocity: CGPoint(x: cos(angle) * spd, y: sin(angle) * spd),
                opacity: 1.0, size: CGFloat.random(in: 4...12),
                color: .orange
            ))
        }
    }
    
    private func handleVictory() {
        phase = .victory
        synth.playHit()
        victorySequence &+= 1
        feedbackText = "LEVEL CLEAR!"
        feedbackColor = .yellow
        feedbackSequence &+= 1
        
        if score > bestScore {
            bestScore = score
            UserDefaults.standard.set(score, forKey: bestKeyPrefix + "\(currentLevelIndex)")
        }
        stop()
    }
    
    private func getTimingWindow() -> Double {
        switch preset.levelNumber {
        case 1:
            return RipTideTuning.perfectWindowEasy
        case 2:
            return RipTideTuning.perfectWindowMedium
        case 3:
            return RipTideTuning.perfectWindowHard
        case 4:
            return currentTileIndex > 75 ? RipTideTuning.perfectWindowEvil : RipTideTuning.perfectWindowHard
        case 5:
            return currentTileIndex > 90 ? RipTideTuning.perfectWindowEvil : RipTideTuning.perfectWindowHard
        case 6:
            return currentTileIndex > 120 ? RipTideTuning.perfectWindowEvil : RipTideTuning.perfectWindowHard
        default:
            // Level 7: Neptune's Wrath gets sub-30ms window in climax!
            return currentTileIndex > 150 ? RipTideTuning.perfectWindowUltraEvil : RipTideTuning.perfectWindowEvil
        }
    }
    
    private func updateVFX(dt: Double) {
        // Update ripples
        for i in ripples.indices.reversed() {
            ripples[i].radius += CGFloat(dt * 180.0)
            ripples[i].opacity -= dt * 0.9
        }
        ripples.removeAll { $0.opacity <= 0 || $0.radius >= $0.maxRadius }
        
        // Update particles
        for i in particles.indices.reversed() {
            particles[i].position.x += particles[i].velocity.x * CGFloat(dt)
            particles[i].position.y += particles[i].velocity.y * CGFloat(dt)
            particles[i].opacity -= dt * 1.8
        }
        particles.removeAll { $0.opacity <= 0 }
    }
    
    deinit {
        gameTask?.cancel()
    }
}

// MARK: - Main SwiftUI View

struct RipTideGameView: View {
    private enum InputSource { case screen, ring }
    
    @ObservedObject var manager: RingManager
    @StateObject private var engine = RipTideEngine(level: 1)
    @State private var isVisible = false
    
    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            
            ZStack {
                // 1. Ocean Background Shader / Waves
                oceanBackgroundView(size: size)
                
                // 2. Main Game Canvas (Path, Tiles, Ripples, Orbs)
                gameWorldView(size: size)
                
                // 3. HUD Overlay
                hudOverlay(size: size)
                
                // 4. State Modals (Idle / Exploded / Victory)
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
        .background(TideColors.deepOcean)
        .navigationTitle("RIPTIDE")
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
        .sensoryFeedback(.impact(weight: .heavy), trigger: engine.hitSequence)
        .sensoryFeedback(.error, trigger: engine.explodeSequence)
        .sensoryFeedback(.success, trigger: engine.victorySequence)
    }
    
    // MARK: - Input
    
    private func armRingGestureIfPossible() {
        guard manager.connectionState == .connected else { return }
        manager.setCameraMode(enabled: true)
    }
    
    private func handleTap(from source: RipTideInputSource) {
        engine.receiveTap(from: source)
    }
    
    // MARK: - Ocean Shader Canvas
    
    @ViewBuilder
    private func oceanBackgroundView(size: CGSize) -> some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, canvasSize in
                // Base deep ocean gradient
                let rect = CGRect(origin: .zero, size: canvasSize)
                context.fill(Path(rect), with: .color(TideColors.deepOcean))
                
                // Render reactive ocean wave sine lines
                let waveCount = 5
                for w in 0..<waveCount {
                    let speed = Double(w + 1) * 0.7
                    let amplitude = CGFloat(12 + w * 6)
                    let frequency = 0.008 + Double(w) * 0.003
                    let yOffset = canvasSize.height * (0.2 + CGFloat(w) * 0.16)
                    
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: yOffset))
                    
                    for x in stride(from: 0, to: canvasSize.width + 20, by: 10) {
                        let sinVal = sin((Double(x) * frequency) + (time * speed))
                        let y = yOffset + sinVal * amplitude
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                    
                    let strokeColor = Color(red: 0.12, green: 0.45, blue: 0.75).opacity(0.18 - Double(w) * 0.02)
                    context.stroke(path, with: .color(strokeColor), lineWidth: CGFloat(2 + w))
                }
            }
        }
        .ignoresSafeArea()
    }
    
    // MARK: - Game World Render
    
    @ViewBuilder
    private func gameWorldView(size: CGSize) -> some View {
        ZStack {
            // Path Line Connectors
            pathConnectorCanvas()
            
            // Tiles
            ForEach(engine.preset.tiles) { tile in
                tileView(tile)
            }
            
            // Decoy mind game tiles
            ForEach(engine.preset.decoyTiles) { decoy in
                tileView(decoy)
            }
            
            // Water Shockwave Ripples
            ForEach(engine.ripples) { ripple in
                Circle()
                    .stroke(ripple.color.opacity(ripple.opacity), lineWidth: 2.5)
                    .frame(width: ripple.radius * 2, height: ripple.radius * 2)
                    .position(ripple.center)
            }
            
            // Water & Explosion Particles
            ForEach(engine.particles) { p in
                Circle()
                    .fill(p.color)
                    .frame(width: p.size, height: p.size)
                    .opacity(p.opacity)
                    .position(p.position)
            }
            
            // Decoy Ghost Orbs (Level 3/4)
            if engine.preset.levelNumber >= 3 {
                ghostOrbView(pos: engine.ghostBlueOrbPos, color: TideColors.accent.opacity(0.35))
                ghostOrbView(pos: engine.ghostWhiteOrbPos, color: Color.white.opacity(0.35))
            }
            
            // Primary Orbs & Orbit Ring Line
            if engine.phase == .playing || engine.phase == .idle {
                // Orbit connecting line
                Path { path in
                    path.move(to: engine.blueOrbPos)
                    path.addLine(to: engine.whiteOrbPos)
                }
                .stroke(
                    LinearGradient(colors: [TideColors.accent.opacity(0.6), Color.white.opacity(0.6)], startPoint: .leading, endPoint: .trailing),
                    style: StrokeStyle(lineWidth: 2, dash: [4, 4])
                )
                
                // Blue Water Orb
                orbView(
                    pos: engine.blueOrbPos,
                    isPivot: engine.activeRole == .blueWater,
                    innerColor: TideColors.accent,
                    outerGlow: Color(red: 0.15, green: 0.75, blue: 1.0)
                )
                
                // White Moon Orb
                orbView(
                    pos: engine.whiteOrbPos,
                    isPivot: engine.activeRole == .whiteMoon,
                    innerColor: .white,
                    outerGlow: Color(red: 0.9, green: 0.95, blue: 1.0)
                )
            }
        }
        .scaleEffect(engine.cameraZoom)
        .rotationEffect(.radians(engine.cameraRotation))
        .offset(x: engine.cameraOffset.x, y: engine.cameraOffset.y)
        .animation(.smooth(duration: 0.25), value: engine.cameraRotation)
    }
    
    // MARK: - Path Canvas
    
    @ViewBuilder
    private func pathConnectorCanvas() -> some View {
        Canvas { context, _ in
            let tiles = engine.preset.tiles
            guard tiles.count > 1 else { return }
            
            var path = Path()
            path.move(to: tiles[0].position)
            for i in 1..<tiles.count {
                path.addLine(to: tiles[i].position)
            }
            
            context.stroke(
                path,
                with: .color(TideColors.accent.opacity(0.4)),
                lineWidth: 3
            )
        }
    }
    
    // MARK: - Tile Component
    
    @ViewBuilder
    private func tileView(_ tile: RipTideTile) -> some View {
        let isCurrent = (tile.id == engine.currentTileIndex)
        let isTarget = (tile.id == engine.currentTileIndex + 1)
        let isPassed = (tile.id < engine.currentTileIndex)
        
        let hideTile = tile.disappearsEarly && isTarget && (CACurrentMediaTime().truncatingRemainder(dividingBy: 0.5) > 0.25)
        
        ZStack {
            // Pulsing target ring preview on next target tile
            if isTarget {
                Circle()
                    .stroke(TideColors.accent.opacity(0.7), lineWidth: 2)
                    .frame(width: RipTideTuning.tileSize + 16, height: RipTideTuning.tileSize + 16)
                    .scaleEffect(1.3)
                    .opacity(0.8)
            }
            
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    tile.isDecoy ? Color.purple.opacity(0.2) :
                    (isCurrent ? TideColors.accent : (isTarget ? Color.white.opacity(0.85) : Color.white.opacity(0.25)))
                )
                .frame(width: RipTideTuning.tileSize, height: RipTideTuning.tileSize)
                .shadow(
                    color: isCurrent ? TideColors.glow : (isTarget ? .white.opacity(0.6) : .clear),
                    radius: isCurrent ? 12 : 6
                )
            
            if tile.isCorner {
                Circle()
                    .stroke(Color.cyan, lineWidth: 1.5)
                    .frame(width: RipTideTuning.tileSize + 6, height: RipTideTuning.tileSize + 6)
            }
        }
        .position(tile.position)
        .opacity(hideTile ? 0.05 : (isPassed ? 0.35 : 1.0))
    }
    
    // MARK: - Orb Visual Component
    
    @ViewBuilder
    private func orbView(pos: CGPoint, isPivot: Bool, innerColor: Color, outerGlow: Color) -> some View {
        ZStack {
            // Outer aura glow
            Circle()
                .fill(outerGlow.opacity(0.45))
                .frame(width: isPivot ? 32 : 26, height: isPivot ? 32 : 26)
                .blur(radius: isPivot ? 6 : 3)
            
            // Core sphere
            Circle()
                .fill(
                    RadialGradient(colors: [.white, innerColor, outerGlow.opacity(0.8)], center: .topLeading, startRadius: 2, endRadius: 14)
                )
                .frame(width: 20, height: 20)
                .shadow(color: outerGlow, radius: 8)
        }
        .position(pos)
    }
    
    @ViewBuilder
    private func ghostOrbView(pos: CGPoint, color: Color) -> some View {
        Circle()
            .stroke(color, lineWidth: 2)
            .frame(width: 18, height: 18)
            .position(pos)
    }
    
    // MARK: - HUD Overlay
    
    @ViewBuilder
    private func hudOverlay(size: CGSize) -> some View {
        VStack {
            // Header Bar
            HStack(spacing: 12) {
                // Level Picker Menu
                Menu {
                    Button("Level 1: Calm Waters") { engine.selectLevel(1) }
                    Button("Level 2: Riptide Surge") { engine.selectLevel(2) }
                    Button("Level 3: Abyssal Mind") { engine.selectLevel(3) }
                    Button("Level 4: Tsunami Chaos (EVIL)") { engine.selectLevel(4) }
                    Button("Level 5: Maelstrom Mirage") { engine.selectLevel(5) }
                    Button("Level 6: Vortex Ascension") { engine.selectLevel(6) }
                    Button("Level 7: NEPTUNE'S WRATH") { engine.selectLevel(7) }
                } label: {
                    HStack(spacing: 6) {
                        Text("L\(engine.preset.levelNumber)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(TideColors.accent, in: Capsule())
                        
                        Text(engine.preset.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                        
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background { Color.black.opacity(0.4).glassEffect(.regular, in: Capsule()) }
                }
                
                Spacer()
                
                // Ring connection status indicator
                HStack(spacing: 5) {
                    Circle()
                        .fill(manager.connectionState == .connected ? Color.green : Color.orange)
                        .frame(width: 7, height: 7)
                    Text(manager.connectionState == .connected ? "Ring Active" : "Tap Screen")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background { Color.black.opacity(0.4).glassEffect(.regular, in: Capsule()) }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            
            // Track Progress Bar
            let progress = Float(engine.currentTileIndex) / Float(max(1, engine.preset.tiles.count - 1))
            GeometryReader { p in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.15)).frame(height: 4)
                    Capsule()
                        .fill(LinearGradient(colors: [TideColors.accent, .white], startPoint: .leading, endPoint: .trailing))
                        .frame(width: p.size.width * CGFloat(min(1.0, max(0.0, progress))), height: 4)
                }
            }
            .frame(height: 4)
            .padding(.horizontal, 16)
            .padding(.top, 4)
            
            // Combo & Score Display
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("SCORE: \(engine.score)")
                        .font(TideFont.sans(14, weight: .bold))
                        .foregroundStyle(.white)
                    if engine.bestScore > 0 {
                        Text("BEST: \(engine.bestScore)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                
                Spacer()
                
                if engine.combo > 1 {
                    Text("\(engine.combo)x COMBO")
                        .font(TideFont.sans(14, weight: .black))
                        .foregroundStyle(TideColors.accent)
                        .scaleEffect(1.0 + min(CGFloat(engine.combo) * 0.02, 0.3))
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            
            Spacer()
            
            // Transient Beat Feedback Popup Text ("PERFECT!", "TOO EARLY!")
            if !engine.feedbackText.isEmpty {
                Text(engine.feedbackText)
                    .font(TideFont.sans(22, weight: .black))
                    .foregroundStyle(engine.feedbackColor)
                    .shadow(color: engine.feedbackColor.opacity(0.8), radius: 8)
                    .id(engine.feedbackSequence)
                    .transition(.scale.combined(with: .opacity))
                    .padding(.bottom, 90)
            }
        }
    }
    
    // MARK: - Modal Overlays
    
    @ViewBuilder
    private func stateOverlays(size: CGSize) -> some View {
        if engine.phase == .idle {
            VStack(spacing: 16) {
                Text("RIPTIDE")
                    .font(TideFont.serif(36, weight: .bold))
                    .foregroundStyle(LinearGradient(colors: [TideColors.accent, .white], startPoint: .top, endPoint: .bottom))
                    .shadow(color: TideColors.glow.opacity(0.5), radius: 12)
                
                Text(engine.preset.subtitle)
                    .font(TideFont.sans(14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Circle().fill(TideColors.accent).frame(width: 10, height: 10)
                        Text("Blue Water Orb & White Moon Orb orbit each other")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        Image(systemName: "hand.tap.fill").foregroundStyle(TideColors.accent)
                        Text("1 Ring Press per beat — missing resets level!")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.orange)
                    }
                }
                .padding()
                .background { Color.black.opacity(0.4).glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16)) }
                .padding(.horizontal, 24)
                
                Button {
                    engine.start()
                } label: {
                    Label("START RIPTIDE", systemImage: "play.fill")
                        .font(TideFont.sans(16, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 220, height: 50)
                        .background(TideColors.ctaGradient, in: Capsule())
                        .shadow(color: TideColors.glow.opacity(0.6), radius: 10)
                }
                .padding(.top, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.65))
        } else if engine.phase == .exploded {
            VStack(spacing: 18) {
                Image(systemName: "bolt.shield.fill")
                    .font(.system(size: 54))
                    .foregroundStyle(.red)
                    .shadow(color: .red.opacity(0.7), radius: 14)
                
                Text("ORBS EXPLODED!")
                    .font(TideFont.serif(30, weight: .bold))
                    .foregroundStyle(.white)
                
                Text(engine.feedbackText)
                    .font(TideFont.sans(16, weight: .bold))
                    .foregroundStyle(.red)
                
                Text("Zero checkpoints. One mistake restarts the song.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                Button {
                    engine.start()
                } label: {
                    Label("TRY AGAIN", systemImage: "arrow.counterclockwise")
                        .font(TideFont.sans(16, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 200, height: 48)
                        .background(TideColors.ctaGradient, in: Capsule())
                }
                .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.75))
        } else if engine.phase == .victory {
            VStack(spacing: 18) {
                Image(systemName: "trophy.fill")
                    .font(.system(size: 54))
                    .foregroundStyle(.yellow)
                    .shadow(color: .yellow.opacity(0.7), radius: 14)
                
                Text("RIPTIDE CONQUERED!")
                    .font(TideFont.serif(30, weight: .bold))
                    .foregroundStyle(.white)
                
                VStack(spacing: 6) {
                    Text("SCORE: \(engine.score)")
                        .font(TideFont.sans(18, weight: .bold))
                        .foregroundStyle(TideColors.accent)
                    Text("MAX COMBO: \(engine.maxCombo)")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.9))
                }
                
                HStack(spacing: 12) {
                    if engine.currentLevelIndex < 7 {
                        Button {
                            engine.selectLevel(engine.currentLevelIndex + 1)
                            engine.start()
                        } label: {
                            Text("NEXT LEVEL")
                                .font(TideFont.sans(15, weight: .bold))
                                .foregroundStyle(.black)
                                .frame(width: 140, height: 46)
                                .background(TideColors.ctaGradient, in: Capsule())
                        }
                    }
                    
                    Button {
                        engine.start()
                    } label: {
                        Text("REPLAY")
                            .font(TideFont.sans(15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 110, height: 46)
                            .background { Color.white.opacity(0.2).glassEffect(.regular, in: Capsule()) }
                    }
                }
                .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.75))
        }
    }
}
//
//  RingEnums.swift
//  ringmvp
//
//  Supporting value types for the JRing protocol.
//
//  Protocol logic in this folder is ported from PulseLoop by Saksham Bhutani
//  (https://github.com/saksham2001/PulseLoopiOS), licensed under
//  Creative Commons Attribution 4.0 International (CC BY 4.0).
//

import Foundation

/// High-level connection state surfaced to the UI.
enum RingConnectionState: String, Codable, CaseIterable {
    case idle
    case scanning
    case connecting
    case connected
    case disconnected
    case reconnecting
    case failed

    var displayName: String {
        switch self {
        case .idle: return "Idle"
        case .scanning: return "Scanning"
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        case .disconnected: return "Disconnected"
        case .reconnecting: return "Reconnecting"
        case .failed: return "Failed"
        }
    }
}

/// The kind of a stored/streamed history measurement.
/// Raw values are persisted — append cases, never rename/reorder.
enum MeasurementKind: String, Codable, CaseIterable {
    case heartRate = "hr"
    case spo2
    case stress
    case hrv
    case temperature = "temp"
    case bloodPressureSystolic = "bp_sys"
    case bloodPressureDiastolic = "bp_dia"
    case fatigue
    case bloodSugar = "glucose"

    /// Display unit for a measurement of this kind.
    var unit: String {
        switch self {
        case .heartRate: return "bpm"
        case .spo2: return "%"
        case .stress: return ""
        case .hrv: return "ms"
        case .temperature: return "°C"
        case .bloodPressureSystolic, .bloodPressureDiastolic: return "mmHg"
        case .fatigue: return ""
        case .bloodSugar: return "mg/dL"
        }
    }
}

/// One decoded sleep-stage bucket from the 0x11 sleep timeline.
enum SleepStage: String, Codable, CaseIterable {
    case light
    case deep
    case awake
    case unknown
    case rem

    var displayName: String {
        switch self {
        case .light: return "Light"
        case .deep: return "Deep"
        case .awake: return "Awake"
        case .rem: return "REM"
        case .unknown: return "Unknown"
        }
    }
}

/// Direction of a raw BLE frame in the debug feed.
enum PacketDirection: String, Codable, CaseIterable {
    case incoming
    case outgoing

    var arrow: String {
        switch self {
        case .incoming: return "RX"
        case .outgoing: return "TX"
        }
    }
}

/// How confident the decoder is that it understood a frame — surfaced in the debug feed.
enum DecodeConfidence: String, Codable, CaseIterable {
    case known
    case partial
    case unknown

    var debugLabel: String {
        switch self {
        case .known: return "high"
        case .partial: return "medium"
        case .unknown: return "unknown"
        }
    }
}

//
//  RingManager.swift
//  ringmvp
//
//  The single Bluetooth implementation for RingMVP. There is no other BLE code in the app.
//
//  This consolidates PulseLoop's proven JRing path into one class: the CoreBluetooth plumbing +
//  connection-reliability hardening from `RingBLEClient`, and the startup / bind / measurement command
//  flow from `JringSyncEngine`. The byte-level protocol (`RingEncoder`/`RingDecoder`/`JringClock`) is
//  ported verbatim, so on-the-wire behaviour matches PulseLoop exactly.
//
//  Protocol + connection logic derived from PulseLoop by Saksham Bhutani
//  (https://github.com/saksham2001/PulseLoopiOS), licensed under CC BY 4.0.
//

import Combine
@preconcurrency import CoreBluetooth
import Foundation

// MARK: - Discovery + log models

/// A peripheral seen during a scan, for the picker UI.
struct DiscoveredRing: Identifiable, Equatable {
    let id: UUID
    let name: String
    let rssi: Int
    /// True when the advertisement matches the JRing signature (name/service/manufacturer).
    let isLikelyRing: Bool
}

/// One line in the debug feed.
struct RingLogLine: Identifiable, Equatable {
    enum Kind: String { case info, tx, rx }
    let id = UUID()
    let timestamp: Date
    let kind: Kind
    let text: String
}

/// User-tunable settings that also seed the connect-time command sequence. Persisted locally.
struct RingSettings: Codable, Equatable {
    /// Display name entered during onboarding. Purely local — never sent to the ring.
    var name: String = ""
    /// User-facing name for the paired ring. Optional keeps older saved settings decodable.
    var ringName: String? = nil
    var age: Int = 25
    var isMale: Bool = true
    var heightCm: Int = 175
    var weightKg: Int = 70
    var hrBackgroundEnabled: Bool = true
    var hrIntervalMinutes: Int = 30
    /// Optional keeps settings saved by older Tide builds decodable. Missing means enabled.
    var automaticVitalsEnabled: Bool? = nil
    var stepGoal: Int = 10_000
    /// App-local daily goals (no on-ring command; used for rings in the Summary/goal UI).
    var calorieGoal: Int = 500
    var sleepGoalHours: Double = 8
    var bpCalibrationSystolic: Int = 0
    var bpCalibrationDiastolic: Int = 0
    var appIdentifier: String = "RingMVP"

    var displayRingName: String {
        let trimmed = ringName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Tide Ring" : trimmed
    }

    var isAutomaticVitalsEnabled: Bool { automaticVitalsEnabled ?? true }
}

@MainActor
final class RingManager: NSObject, ObservableObject {
    /// Local storage. Owned here; observed directly by the History views.
    let store = RingStore()

    // MARK: Observable connection state
    @Published private(set) var connectionState: RingConnectionState = .idle
    @Published private(set) var isBluetoothReady = false
    @Published private(set) var bluetoothStateText = "Unknown"
    @Published private(set) var authorizationText = "Unknown"
    @Published private(set) var discovered: [DiscoveredRing] = []
    @Published private(set) var connectedDeviceName: String?
    @Published private(set) var lastError: String?
    @Published private(set) var isBound = false
    @Published private(set) var syncProgress: String?
    @Published private(set) var lastSyncAt: Date?
    @Published private(set) var syncResultMessage: String?

    // MARK: Observable ring data
    @Published private(set) var batteryPercent: Int? {
        didSet {
            // Level-triggered low-battery alert (<20%). One `didSet` covers both battery sources
            // (the GATT read and the 0x0b packet). The service latches so it fires once per drop.
            if let batteryPercent { TideNotificationService.shared.evaluateBattery(batteryPercent) }
        }
    }
    @Published private(set) var firmwareVersion: String?
    @Published private(set) var deviceAddress: String?
    @Published private(set) var bandCapabilities: JringBandCapabilities?

    @Published private(set) var currentHeartRate: Int?
    @Published private(set) var isMeasuringHeartRate = false
    @Published private(set) var heartRateStatus = "Idle"

    @Published private(set) var isMeasuringVitals = false
    @Published private(set) var vitalsStatus = "Idle"

    /// Incremented for every verified 0x06/0x02 camera gesture from the ring.
    @Published private(set) var cameraShutterSequence: UInt64 = 0

    @Published private(set) var debugLog: [RingLogLine] = []

    // MARK: Settings (persisted)
    @Published var settings: RingSettings {
        didSet { persistSettings() }
    }

    // MARK: CoreBluetooth
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var discoveredPeripherals: [UUID: CBPeripheral] = [:]
    private var writeChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?
    private var batteryChar: CBCharacteristic?

    // MARK: Protocol
    private let encoder = RingEncoder()
    private var clock = JringClock()
    private var decoder = RingDecoder()
    /// The firmware exposes only a binary camera action, not motion magnitude. Collapse noisy
    /// repeats so one physical double-tap can never create a burst of photos.
    private var lastAcceptedCameraGestureAt: Date?
    private let cameraGestureDebounceSeconds: TimeInterval = 0.1
    private var cameraModeEnabled = false

    private enum VitalsMeasurementSource {
        case manualCombined
        case manualBloodPressure
        case automatic
    }
    private var vitalsMeasurementSource: VitalsMeasurementSource?
    private var vitalsMeasurementTimeoutTask: Task<Void, Never>?
    private var automaticVitalsTask: Task<Void, Never>?
    private var lastAutomaticVitalsAttemptAt: Date?

    // MARK: History sync state
    private var syncTimeoutTask: Task<Void, Never>?
    private let syncStallTimeout: UInt64 = 20_000_000_000
    private var syncRecordCount = 0

    // MARK: JRing UUIDs
    private let serviceUUID = CBUUID(string: RingUUIDs.service)
    private let writeUUID = CBUUID(string: RingUUIDs.write)
    private let notifyUUID = CBUUID(string: RingUUIDs.notify)
    private let batteryServiceUUID = CBUUID(string: "180F")
    private let batteryCharUUID = CBUUID(string: RingUUIDs.battery)
    private let disServiceUUID = CBUUID(string: "180A")
    private let firmwareCharUUIDs: Set<CBUUID> = [CBUUID(string: "2A26"), CBUUID(string: "2A28")]

    // JRing advertisement signature (from PulseLoop's JringCoordinator).
    private let advertisedName = "SMART_RING"
    private let manufacturerHexNeedle = "41422ec75b6a"

    // MARK: Write serialization (mirrors RingBLEClient)
    private var writeQueue: [Data] = []
    private var writeInFlight = false
    private var writeSeq: UInt64 = 0
    private let writeAckTimeout: UInt64 = 4_000_000_000

    // MARK: Reliability
    private var autoReconnect = true
    private var lastActivityAt: Date?
    private var keepaliveTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private let keepaliveInterval: UInt64 = 15_000_000_000
    private let watchdogInterval: UInt64 = 15_000_000_000
    private let linkStaleSeconds: TimeInterval = 60
    private var watchdogTicks = 0

    private static let lastPeripheralKey = "ring.lastPeripheralIdentifier"
    private static let settingsKey = "ring.settings"
    private static let lastSyncKey = "ring.lastHistorySyncAt"

    override init() {
        settings = Self.loadSettings()
        lastSyncAt = UserDefaults.standard.object(forKey: Self.lastSyncKey) as? Date
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
        updateAuthorization()
        log(.info, "Ring manager initialized.")
    }

    // MARK: - Public API

    func startScanning() {
        guard isBluetoothReady else {
            lastError = "Bluetooth is not powered on."
            log(.info, "Cannot scan: Bluetooth is \(bluetoothStateText).")
            return
        }
        discovered = []
        discoveredPeripherals = [:]
        lastError = nil
        autoReconnect = true
        connectionState = .scanning
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        log(.info, "Scanning for nearby BLE devices…")
    }

    func stopScanning() {
        central.stopScan()
        if connectionState == .scanning { connectionState = .idle }
        log(.info, "Stopped scanning.")
    }

    func connect(to id: UUID) {
        guard let target = discoveredPeripherals[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first else {
            lastError = "Ring no longer available; scan again."
            return
        }
        beginConnect(to: target)
    }

    /// Silently reconnect to the last paired ring on launch.
    func connectLastKnown() {
        guard isBluetoothReady, let id = lastKnownIdentifier,
              let known = central.retrievePeripherals(withIdentifiers: [id]).first else { return }
        beginConnect(to: known)
    }

    func disconnect() {
        autoReconnect = false
        central.stopScan()
        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
        } else {
            connectionState = .idle
        }
        log(.info, "Disconnecting.")
    }

    /// Forget the ring: release it (0x4B UNBOND so it re-advertises for other apps), disconnect, and
    /// clear the remembered identifier so we no longer auto-reconnect.
    func forget() {
        if connectionState == .connected {
            enqueue(encoder.makeBindCommand(action: 5))
            log(.info, "Sent unbind (0x4B action 5).")
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                finalizeForget()
            }
        } else {
            finalizeForget()
        }
    }

    private func finalizeForget() {
        disconnect()
        UserDefaults.standard.removeObject(forKey: Self.lastPeripheralKey)
        isBound = false
        settings.ringName = nil
        log(.info, "Ring forgotten.")
    }

    var lastKnownIdentifier: UUID? {
        UserDefaults.standard.string(forKey: Self.lastPeripheralKey).flatMap(UUID.init)
    }
    var hasLastKnownRing: Bool { lastKnownIdentifier != nil }

    // MARK: Measurement actions

    /// Live heart-rate stream (0x14 → samples → 0x27 complete).
    func startHeartRate() {
        guard connectionState == .connected else { return }
        currentHeartRate = nil
        isMeasuringHeartRate = true
        heartRateStatus = "Waiting for sensor reading…"
        enqueue(encoder.makeHeartRateStartCommand())
        log(.info, "Started live heart-rate stream (0x14).")
    }

    func stopHeartRate() {
        enqueue(encoder.makeHeartRateStopCommand())
        // Restore the user's background HR cadence after a live stream.
        enqueue(encoder.makeAutomaticHeartRateCommand(
            enabled: settings.hrBackgroundEnabled, cadenceMinutes: settings.hrIntervalMinutes))
        isMeasuringHeartRate = false
        heartRateStatus = "Stopped"
        log(.info, "Stopped live heart-rate stream (0x15).")
    }

    /// One PPG sweep that returns every vital at once in the 0x24 packet (HR, BP, SpO₂, fatigue…).
    func measureVitals() {
        beginVitalsMeasurement(
            source: .manualCombined,
            status: "Measuring…",
            command: encoder.makeSpO2StartCommand()
        )
        log(.info, "Started combined vitals sweep (0x23 mode 2).")
    }

    func stopVitals() {
        finishVitalsMeasurement(status: "Stopped", sendStop: true)
        log(.info, "Stopped vitals sweep (0x23 mode 0).")
    }

    /// Spot blood-pressure sweep (0x23 mode 1). Result arrives in the 0x24 packet.
    func measureBloodPressure() {
        beginVitalsMeasurement(
            source: .manualBloodPressure,
            status: "Measuring blood pressure…",
            command: encoder.makeBloodPressureStartCommand()
        )
        log(.info, "Started blood-pressure sweep (0x23 mode 1).")
    }

    /// Ask the ring for its current activity totals (0x02 query → 0x03 reply).
    func refreshActivity() {
        guard connectionState == .connected else { return }
        enqueue(encoder.makeActivityQueryCommand())
        log(.info, "Requested current activity (0x02 query).")
    }

    /// Pull the ring's stored activity/sleep stream (0x10) + 1-minute HR history (0x16).
    func syncHistory() {
        guard connectionState == .connected, syncProgress == nil else { return }
        if isMeasuringVitals { finishVitalsMeasurement(status: "Stopped for history sync", sendStop: true) }
        beginHistorySync()
        enqueue(encoder.makeHistoryQueryCommand())
        enqueue(encoder.makeHistoryMeasurementQueryCommand())
        log(.info, "Requested stored history (0x10 + 0x16).")
    }

    /// Flash/vibrate the ring so the user can locate it (0x04).
    func findDevice() {
        guard connectionState == .connected else { return }
        enqueue(encoder.makeFindRingCommand())
        log(.info, "Sent find-device (0x04).")
    }

    /// Arms gesture capture only while Tide's camera is visible.
    func setCameraMode(enabled: Bool) {
        cameraModeEnabled = enabled
        guard connectionState == .connected else { return }
        enqueue(encoder.makePhotoModeCommand(enabled: enabled))
        log(.info, "Ring camera mode \(enabled ? "enabled" : "disabled") (0x07).")
    }

    /// Re-push the RTC (used after a timezone/clock change).
    func syncClock() {
        guard connectionState == .connected else { return }
        clock.capture()
        enqueue(encoder.makeTimeSyncCommand())
        log(.info, "Re-synced clock (0x01).")
    }

    // MARK: Settings actions (store + send now)

    func applyUserProfile() {
        enqueue(userInfoCommand())
        log(.info, "Applied user profile (0x02).")
    }

    func applyMeasurementInterval() {
        enqueue(encoder.makeAutomaticHeartRateCommand(
            enabled: settings.hrBackgroundEnabled, cadenceMinutes: settings.hrIntervalMinutes))
        restartAutomaticVitalsScheduler()
        log(.info, "Applied background HR schedule (0x19, \(settings.hrIntervalMinutes) min).")
    }

    /// Called when Tide becomes active. iOS does not promise exact 30-minute execution while an app
    /// is suspended, so an overdue sweep is run immediately on return instead of silently skipped.
    func appDidBecomeActive() {
        runAutomaticVitalsIfDue()
    }

    func applyStepGoal() {
        enqueue(encoder.makeGoalCommand(steps: settings.stepGoal))
        log(.info, "Applied step goal (0x1a, \(settings.stepGoal)).")
    }

    func applyBloodPressureCalibration() {
        guard settings.bpCalibrationSystolic > 0, settings.bpCalibrationDiastolic > 0 else { return }
        enqueue(encoder.makeBPAdjustCommand(
            systolic: settings.bpCalibrationSystolic, diastolic: settings.bpCalibrationDiastolic))
        log(.info, "Applied BP calibration (0x33).")
    }

    func clearLog() { debugLog.removeAll() }

    // MARK: - Automatic vitals + measurement lifecycle

    private func beginVitalsMeasurement(
        source: VitalsMeasurementSource,
        status: String,
        command: Data
    ) {
        guard connectionState == .connected, !isMeasuringVitals, !isMeasuringHeartRate else { return }
        isMeasuringVitals = true
        vitalsMeasurementSource = source
        vitalsStatus = status
        enqueue(command)
        armVitalsMeasurementTimeout()
    }

    private func finishVitalsMeasurement(status: String, sendStop: Bool) {
        guard isMeasuringVitals || vitalsMeasurementSource != nil else { return }
        vitalsMeasurementTimeoutTask?.cancel()
        vitalsMeasurementTimeoutTask = nil
        if sendStop, connectionState == .connected {
            enqueue(encoder.makeSpO2StopCommand())
        }
        if vitalsMeasurementSource == .automatic {
            lastAutomaticVitalsAttemptAt = Date()
        }
        vitalsMeasurementSource = nil
        isMeasuringVitals = false
        vitalsStatus = status
    }

    private func armVitalsMeasurementTimeout() {
        vitalsMeasurementTimeoutTask?.cancel()
        vitalsMeasurementTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 50_000_000_000)
            guard let self, !Task.isCancelled, self.isMeasuringVitals else { return }
            self.finishVitalsMeasurement(status: "No reading — try again", sendStop: true)
            self.log(.info, "Vitals sweep timed out and was stopped.")
        }
    }

    private func restartAutomaticVitalsScheduler() {
        automaticVitalsTask?.cancel()
        automaticVitalsTask = nil
        guard connectionState == .connected, settings.isAutomaticVitalsEnabled else { return }
        automaticVitalsTask = Task { @MainActor [weak self] in
            // Let connect-time configuration/history finish before the first PPG sweep.
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            while let self, !Task.isCancelled, self.connectionState == .connected {
                self.runAutomaticVitalsIfDue()
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }

    private func runAutomaticVitalsIfDue() {
        guard connectionState == .connected,
              settings.isAutomaticVitalsEnabled,
              syncProgress == nil,
              !cameraModeEnabled,
              !isMeasuringHeartRate,
              !isMeasuringVitals else { return }

        let now = Date()
        let latestStoredVital = [store.latestSpO2?.date, store.latestBloodPressure?.date]
            .compactMap { $0 }
            .max()
        let lastAttempt = [lastAutomaticVitalsAttemptAt, latestStoredVital]
            .compactMap { $0 }
            .max()
        let cadence = TimeInterval(max(5, settings.hrIntervalMinutes) * 60)
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < cadence { return }

        lastAutomaticVitalsAttemptAt = now
        beginVitalsMeasurement(
            source: .automatic,
            status: "Automatic vitals check…",
            command: encoder.makeSpO2StartCommand()
        )
        log(.info, "Started scheduled combined vitals sweep (\(settings.hrIntervalMinutes)-minute cadence while connected).")
    }

    // MARK: - History sync lifecycle

    private func beginHistorySync() {
        syncTimeoutTask?.cancel()
        syncRecordCount = 0
        syncResultMessage = nil
        syncProgress = "Syncing ring history…"
        armHistorySyncTimeout()
    }

    private func noteHistoryRecord(stage: String? = nil) {
        guard syncProgress != nil else { return }
        syncRecordCount += 1
        if let stage { syncProgress = stage }
        armHistorySyncTimeout()
    }

    private func armHistorySyncTimeout() {
        syncTimeoutTask?.cancel()
        syncTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: self?.syncStallTimeout ?? 20_000_000_000)
            guard let self, !Task.isCancelled, self.syncProgress != nil else { return }
            self.finishHistorySync(didReceiveEndMarker: false, interrupted: false)
        }
    }

    private func finishHistorySync(didReceiveEndMarker: Bool, interrupted: Bool) {
        guard syncProgress != nil else {
            if didReceiveEndMarker { store.freezeTodayReadiness(settings: settings) }
            return
        }

        syncTimeoutTask?.cancel()
        syncTimeoutTask = nil
        syncProgress = nil

        if interrupted {
            syncResultMessage = "Sync interrupted — reconnect your ring and try again."
            log(.info, "History sync interrupted after \(syncRecordCount) records.")
            return
        }

        if didReceiveEndMarker || syncRecordCount > 0 {
            let finishedAt = Date()
            lastSyncAt = finishedAt
            UserDefaults.standard.set(finishedAt, forKey: Self.lastSyncKey)
            syncResultMessage = syncRecordCount == 0
                ? "History is already up to date."
                : "Synced \(syncRecordCount.formatted()) history records."

            // Freeze Tide's simple wellness score once the completed history batch is available.
            store.freezeTodayReadiness(settings: settings)
            TideNotificationService.shared.refreshMorningSleepSummary(store: store, settings: settings)
            if let activity = store.todayActivityRecord() {
                TideNotificationService.shared.evaluateActivity(activity, settings: settings)
            }
            log(.info, "History sync finished with \(syncRecordCount) records\(didReceiveEndMarker ? "." : " after the stream became quiet.")")
            runAutomaticVitalsIfDue()
        } else {
            syncResultMessage = "No history was returned. Keep the ring nearby and try again."
            log(.info, "History sync timed out without receiving records.")
        }
    }

    // MARK: - Startup sequence (from JringSyncEngine.runStartup)

    /// Claim the ring (0x48) so it streams to us, push the user profile (0x02) + BP calibration (0x33),
    /// then the canonical status → time → locale → monitoring → capabilities → history flow. Ordering
    /// is guaranteed by the serialized write queue.
    private func runStartup() {
        log(.info, "Running startup command sequence.")
        enqueue(encoder.makeAppIdentifierCommand(appId: settings.appIdentifier))
        enqueue(userInfoCommand())
        if settings.bpCalibrationSystolic > 0, settings.bpCalibrationDiastolic > 0 {
            enqueue(encoder.makeBPAdjustCommand(
                systolic: settings.bpCalibrationSystolic, diastolic: settings.bpCalibrationDiastolic))
        }
        enqueue(encoder.makeStatusCommand())
        clock.capture()
        enqueue(encoder.makeTimeSyncCommand())
        enqueue(encoder.makeLocaleCommand())
        // 0x19 arms the ring's continuous background sensor logging. Without it the ring records almost
        // nothing — this is why a guessed protocol that omits it never activates the sensors.
        enqueue(encoder.makeAutomaticHeartRateCommand(
            enabled: settings.hrBackgroundEnabled, cadenceMinutes: settings.hrIntervalMinutes))
        enqueue(encoder.makeBandFunctionCommand())
        beginHistorySync()
        enqueue(encoder.makeHistoryQueryCommand())
        enqueue(encoder.makeHistoryMeasurementQueryCommand())
        restartAutomaticVitalsScheduler()
    }

    private func userInfoCommand() -> Data {
        encoder.makeUserInfoCommand(
            age: settings.age, isMale: settings.isMale,
            heightCm: settings.heightCm, weightKg: settings.weightKg)
    }

    /// Respond to the ring-driven bind handshake (0x4B): INIT(0) → APP_START(1); ACK(2) → SUCCESS(4).
    /// This is the app-level binding that makes the ring flash green and start streaming — the piece a
    /// guessed protocol misses entirely.
    private func respondToBind(action: UInt8, state: UInt8) {
        switch action {
        case 0:
            enqueue(encoder.makeBindCommand(action: 1))
            log(.info, "Bind INIT → replied APP_START (0x4B action 1).")
        case 2:
            enqueue(encoder.makeBindCommand(action: 4))
            isBound = true
            log(.info, "Bind ACK → replied SUCCESS (0x4B action 4). Ring bound.")
        case 4:
            isBound = true
            log(.info, "Bind SUCCESS received. Ring bound.")
        default:
            log(.info, "Bind frame action \(action), state \(state).")
        }
    }

    // MARK: - Connection internals

    private func beginConnect(to target: CBPeripheral) {
        central.stopScan()
        autoReconnect = true
        if syncProgress != nil { finishHistorySync(didReceiveEndMarker: false, interrupted: true) }
        finishVitalsMeasurement(status: "Stopped", sendStop: false)
        stopReliabilityTimers()
        if let old = peripheral, old.identifier != target.identifier || old.state != .disconnected {
            central.cancelPeripheralConnection(old)
        }
        writeChar = nil; notifyChar = nil; batteryChar = nil
        writeInFlight = false; writeQueue = []
        isBound = false
        // Fresh clock + decoder per connection so the latched offset never leaks across reconnects.
        clock = JringClock()
        decoder = RingDecoder(clock: clock)
        peripheral = target
        target.delegate = self
        connectedDeviceName = target.name ?? advertisedName
        connectionState = .connecting
        central.connect(target, options: nil)
        log(.info, "Connecting to \(connectedDeviceName ?? "ring") [\(target.identifier.uuidString)]…")
    }

    /// Enqueue a framed 20-byte command. JRing framing is the identity.
    private func enqueue(_ command: Data) {
        writeQueue.append(command)
        pumpWrites()
    }

    private func pumpWrites() {
        guard !writeInFlight, let peripheral, let writeChar, !writeQueue.isEmpty else { return }
        let data = writeQueue.removeFirst()
        writeInFlight = true
        writeSeq &+= 1
        let seq = writeSeq
        log(.tx, hexString(data))
        peripheral.writeValue(data, for: writeChar, type: .withResponse)
        // Guard against a missed didWriteValueFor — one dropped ACK can't wedge the queue.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: writeAckTimeout)
            if writeInFlight, seq == writeSeq {
                writeInFlight = false
                pumpWrites()
            }
        }
    }

    private func readBattery() {
        guard let peripheral, let batteryChar else { return }
        peripheral.readValue(for: batteryChar)
    }

    // MARK: Reliability timers

    private func noteActivity() { lastActivityAt = Date() }

    private func startKeepalive() {
        keepaliveTask?.cancel()
        keepaliveTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: self?.keepaliveInterval ?? 15_000_000_000)
                guard let self, !Task.isCancelled, self.connectionState == .connected else { return }
                self.enqueue(self.encoder.makeKeepaliveCommand())
            }
        }
    }

    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTicks = 0
        watchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: self?.watchdogInterval ?? 15_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.watchdogTick()
            }
        }
    }

    private func watchdogTick() {
        watchdogTicks += 1
        if watchdogTicks >= 240, connectionState == .connected {   // ~every 60 min
            watchdogTicks = 0
            readBattery()
        }
        guard isBluetoothReady, connectionState == .connected, let last = lastActivityAt else { return }
        if Date().timeIntervalSince(last) > linkStaleSeconds {
            // Zombie link: drop it and let the disconnect handler auto-reconnect.
            if let peripheral { central.cancelPeripheralConnection(peripheral) }
            log(.info, "Watchdog: link stale, forcing reconnect.")
        }
    }

    private func stopReliabilityTimers() {
        keepaliveTask?.cancel(); keepaliveTask = nil
        watchdogTask?.cancel(); watchdogTask = nil
        automaticVitalsTask?.cancel(); automaticVitalsTask = nil
    }

    // MARK: - Decoded-event handling

    private func handle(_ raw: RingDecodedEvent) {
        // Advance the bind handshake regardless of plausibility gating.
        if case let .bind(action, state) = raw {
            respondToBind(action: action, state: state)
        }
        if case let .bandFunction(caps) = raw {
            bandCapabilities = caps
        }
        guard let event = RingEventGate.validate(raw) else { return }
        apply(event)
    }

    private func apply(_ event: RingDecodedEvent) {
        switch event {
        case let .activityUpdate(timestamp, steps, distanceMeters, calories):
            let record = ActivityRecord(
                steps: steps, distanceMeters: distanceMeters, calories: calories, timestamp: timestamp)
            store.updateActivity(record)
            store.updateActivityScore(onLocalDay: timestamp, settings: settings)
            // Step / calorie goal-complete notifications (latched once per day per goal).
            TideNotificationService.shared.evaluateActivity(record, settings: settings)

        case let .activityBucket(timestamp, steps, distanceMeters):
            store.addActivityBucket(timestamp: timestamp, steps: steps, distanceMeters: distanceMeters)
            noteHistoryRecord(stage: "Syncing activity…")

        case let .heartRateSample(bpm, timestamp):
            currentHeartRate = bpm
            if isMeasuringHeartRate { heartRateStatus = "Measuring: \(bpm) bpm" }
            store.addHeartRate(bpm: bpm, date: timestamp, source: "live")

        case .heartRateComplete:
            isMeasuringHeartRate = false
            heartRateStatus = "Complete"

        case let .spo2Result(value, timestamp):
            store.addSpO2(value: value, date: timestamp)
            if isMeasuringVitals {
                finishVitalsMeasurement(status: "Complete", sendStop: true)
            } else {
                vitalsStatus = "SpO₂ \(value)%"
            }

        case .spo2Complete:
            if isMeasuringVitals { finishVitalsMeasurement(status: "Complete", sendStop: false) }

        case let .historyMeasurement(kind, value, timestamp):
            noteHistoryRecord(stage: "Syncing heart rate…")
            switch kind {
            case .heartRate: store.addHeartRate(bpm: Int(value), date: timestamp, source: "history")
            case .spo2: store.addSpO2(value: Int(value), date: timestamp, source: "history")
            default: store.addExtra(kind: kind, value: value, date: timestamp)
            }

        case let .sleepTimeline(timestamp, stages):
            noteHistoryRecord(stage: "Syncing sleep…")
            store.addSleepFrame(start: timestamp, stages: stages)
            // Sleep goal-complete + schedule/deliver the 9:30 AM morning sleep summary.
            TideNotificationService.shared.evaluateSleep(store.latestNight, settings: settings)

        case let .bloodPressureSample(systolic, diastolic, timestamp):
            store.addBloodPressure(systolic: systolic, diastolic: diastolic, date: timestamp)
            if isMeasuringVitals { finishVitalsMeasurement(status: "Complete", sendStop: true) }

        case let .stressSample(value, timestamp):
            store.addExtra(kind: .stress, value: Double(value), date: timestamp)

        case let .hrvSample(value, timestamp):
            store.addExtra(kind: .hrv, value: Double(value), date: timestamp)

        case let .temperatureSample(celsius, timestamp):
            store.addExtra(kind: .temperature, value: celsius, date: timestamp)

        case let .fatigueSample(value, timestamp):
            store.addExtra(kind: .fatigue, value: Double(value), date: timestamp)

        case let .bloodSugarSample(mgdl, timestamp):
            store.addExtra(kind: .bloodSugar, value: mgdl, date: timestamp)

        case let .battery(percent):
            batteryPercent = percent

        case let .cameraShutter(timestamp):
            lastAcceptedCameraGestureAt = timestamp
            cameraShutterSequence &+= 1
            log(.info, "Ring camera gesture received (0x06 action 2).")

        case let .status(address):
            if let address { deviceAddress = address }

        case let .firmware(version):
            firmwareVersion = version

        case .historySyncFinished:
            finishHistorySync(didReceiveEndMarker: true, interrupted: false)

        case let .historySyncProgress(stage):
            guard syncProgress != nil else { break }
            syncProgress = stage
            armHistorySyncTimeout()

        default:
            break
        }
    }

    // MARK: - Helpers

    private func updateAuthorization() {
        switch CBManager.authorization {
        case .notDetermined: authorizationText = "Not Determined"
        case .restricted: authorizationText = "Restricted"
        case .denied: authorizationText = "Denied"
        case .allowedAlways: authorizationText = "Allowed"
        @unknown default: authorizationText = "Unknown"
        }
    }

    private func hexString(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    private func log(_ kind: RingLogLine.Kind, _ text: String) {
        debugLog.append(RingLogLine(timestamp: Date(), kind: kind, text: text))
        if debugLog.count > 400 { debugLog.removeFirst(debugLog.count - 400) }
    }

    private func matchesRing(name: String?, advertisementData: [String: Any]) -> Bool {
        if let name, name == advertisedName { return true }
        let serviceUUIDs = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        if serviceUUIDs.contains(serviceUUID) { return true }
        if let mfg = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
           mfg.hexString.contains(manufacturerHexNeedle) { return true }
        return false
    }

    // MARK: Settings persistence

    private func persistSettings() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.settingsKey)
        }
    }

    private static func loadSettings() -> RingSettings {
        guard let data = UserDefaults.standard.data(forKey: settingsKey),
              let decoded = try? JSONDecoder().decode(RingSettings.self, from: data) else {
            return RingSettings()
        }
        return decoded
    }
}

// MARK: - CBCentralManagerDelegate

extension RingManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            isBluetoothReady = (central.state == .poweredOn)
            updateAuthorization()
            switch central.state {
            case .unknown: bluetoothStateText = "Unknown"
            case .resetting: bluetoothStateText = "Resetting"
            case .unsupported: bluetoothStateText = "Unsupported"
            case .unauthorized: bluetoothStateText = "Unauthorized"
            case .poweredOff: bluetoothStateText = "Powered Off"
            case .poweredOn: bluetoothStateText = "Powered On"
            @unknown default: bluetoothStateText = "Unknown"
            }
            log(.info, "Bluetooth state: \(bluetoothStateText) (auth: \(authorizationText)).")

            switch central.state {
            case .poweredOn:
                if autoReconnect, hasLastKnownRing, peripheral == nil {
                    connectLastKnown()
                }
            case .poweredOff, .unauthorized, .unsupported:
                if syncProgress != nil { finishHistorySync(didReceiveEndMarker: false, interrupted: true) }
                finishVitalsMeasurement(status: "Stopped", sendStop: false)
                connectionState = .idle
                connectedDeviceName = nil
                stopReliabilityTimers()
            default:
                break
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        MainActor.assumeIsolated {
            let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
            guard let displayName = name, !displayName.isEmpty else { return }
            discoveredPeripherals[peripheral.identifier] = peripheral
            let ring = DiscoveredRing(
                id: peripheral.identifier,
                name: displayName,
                rssi: RSSI.intValue,
                isLikelyRing: matchesRing(name: name, advertisementData: advertisementData)
            )
            if let index = discovered.firstIndex(where: { $0.id == ring.id }) {
                discovered[index] = ring
            } else {
                discovered.append(ring)
            }
            discovered.sort { ($0.isLikelyRing ? 0 : 1, -$0.rssi) < ($1.isLikelyRing ? 0 : 1, -$1.rssi) }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            peripheral.delegate = self
            log(.info, "Connected. Discovering services…")
            peripheral.discoverServices(nil)
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            lastError = error?.localizedDescription ?? "Failed to connect."
            log(.info, "Failed to connect: \(lastError ?? "")")
            if autoReconnect, let peripheral = self.peripheral {
                connectionState = .reconnecting
                central.connect(peripheral, options: nil)
            } else {
                connectionState = .failed
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            if syncProgress != nil { finishHistorySync(didReceiveEndMarker: false, interrupted: true) }
            finishVitalsMeasurement(status: "Stopped", sendStop: false)
            stopReliabilityTimers()
            lastActivityAt = nil
            writeChar = nil; notifyChar = nil; batteryChar = nil
            writeInFlight = false; writeQueue = []
            isMeasuringHeartRate = false
            cameraModeEnabled = false
            isBound = false
            if let error {
                log(.info, "Disconnected: \(error.localizedDescription)")
            } else {
                log(.info, "Disconnected.")
            }
            if autoReconnect {
                connectionState = .reconnecting
                central.connect(peripheral, options: nil)
            } else {
                connectionState = .disconnected
                connectedDeviceName = nil
                self.peripheral = nil
            }
        }
    }
}

// MARK: - CBPeripheralDelegate

extension RingManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            for service in peripheral.services ?? [] {
                if service.uuid == serviceUUID {
                    peripheral.discoverCharacteristics([writeUUID, notifyUUID], for: service)
                } else if service.uuid == batteryServiceUUID {
                    peripheral.discoverCharacteristics([batteryCharUUID], for: service)
                } else if service.uuid == disServiceUUID {
                    peripheral.discoverCharacteristics(Array(firmwareCharUUIDs), for: service)
                }
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            for characteristic in service.characteristics ?? [] {
                let uuid = characteristic.uuid
                if uuid == writeUUID { writeChar = characteristic }
                if uuid == notifyUUID {
                    notifyChar = characteristic
                    peripheral.setNotifyValue(true, for: characteristic)
                }
                if uuid == batteryCharUUID {
                    batteryChar = characteristic
                    peripheral.readValue(for: characteristic)
                } else if firmwareCharUUIDs.contains(uuid) {
                    peripheral.readValue(for: characteristic)
                }
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            guard characteristic.uuid == notifyUUID, characteristic.isNotifying else { return }
            guard connectionState != .connected else { return }
            connectionState = .connected
            connectedDeviceName = peripheral.name ?? advertisedName
            UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.lastPeripheralKey)
            noteActivity()
            startKeepalive()
            startWatchdog()
            readBattery()
            log(.info, "Notifications enabled on 33F4. Fully connected.")
            runStartup()
            pumpWrites()
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            guard let value = characteristic.value else { return }
            noteActivity()
            if characteristic.uuid == batteryCharUUID {
                if let first = value.first { batteryPercent = Int(first) }
                return
            }
            if firmwareCharUUIDs.contains(characteristic.uuid) {
                if let fw = String(data: value, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !fw.isEmpty {
                    firmwareVersion = fw
                }
                return
            }
            guard characteristic.uuid == notifyUUID else { return }
            for decoded in decoder.decodeAll(value) {
                log(.rx, "\(hexString(value))  →  \(decoded.kind) [\(decoded.confidence.debugLabel)] \(decoded.debugJSON)")
                handle(decoded)
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            noteActivity()
            writeInFlight = false
            pumpWrites()
        }
    }
}

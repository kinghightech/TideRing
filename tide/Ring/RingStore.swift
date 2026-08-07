//
//  RingStore.swift
//  Tide
//
//  Local-only persistence for everything the ring reports. Nothing here touches the network:
//  readings are held in memory and mirrored to a single JSON file in the app's Application Support
//  directory. This is the app's entire storage layer.
//
//  Heart rate is a SINGLE unified series (live spot readings and the ring's stored background log
//  land in the same place, like Apple Health). Sleep-stage frames are grouped into nights keyed by
//  the morning of waking (matching PulseLoop's model). Activity is kept both as the live "today"
//  snapshot and as a per-day history so step charts have something to plot.
//

import Combine
import Foundation
import UIKit

// MARK: - Reading models

/// A single scalar reading (heart rate, SpO₂, stress, etc.) with the instant it was taken.
struct RingReading: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var value: Double
    var date: Date
    /// "live", "history", "manual" — provenance, kept for diagnostics but not shown as separate lists.
    var source: String
}

struct BloodPressureReading: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var systolic: Int
    var diastolic: Int
    var date: Date
}

/// Stress / HRV / temperature / fatigue / blood-sugar samples, keyed by measurement kind.
struct ExtraMeasurement: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var kindRaw: String
    var value: Double
    var date: Date
    var kind: MeasurementKind? { MeasurementKind(rawValue: kindRaw) }
}

/// One sleep-stage block decoded from a `0x11` frame.
struct SleepBlock: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var stageRaw: String
    var start: Date
    var minutes: Int
    /// Optional keeps legacy snapshots decodable. See `RingStore.sleepSchemaVersion`.
    var sampleSchemaVersion: Int? = nil
    /// The waking-day key of the 0x11 frame this sample came from. PulseLoop keys a whole *packet*
    /// to one session (`persistSleepTimeline`), so a frame straddling 7 PM keeps all fifteen of its
    /// samples together instead of splitting across two nights. Storing it at ingest reproduces
    /// that exactly. Optional for older snapshots, which fall back to the sample's own timestamp.
    var nightKeyRef: Date? = nil
    var stage: SleepStage { SleepStage(rawValue: stageRaw) ?? .unknown }
}

/// A night of sleep, assembled from its blocks. Computed, not persisted.
struct SleepNight: Identifiable {
    let id: Date          // local "night of" key, anchored to the session's starting evening
    let blocks: [SleepBlock]

    var start: Date { blocks.map(\.start).min() ?? id }
    var end: Date { blocks.map { $0.start.addingTimeInterval(TimeInterval($0.minutes * 60)) }.max() ?? id }
    func minutes(_ stage: SleepStage) -> Int { blocks.filter { $0.stage == stage }.reduce(0) { $0 + $1.minutes } }
    var lightMinutes: Int { minutes(.light) }
    var deepMinutes: Int { minutes(.deep) }
    /// This ring family reports light/deep/awake only — never REM. Kept so legacy snapshots and
    /// preview seeds that contain "rem" blocks still add up. See `RingProtocol.stage(_:)`.
    var remMinutes: Int { minutes(.rem) }
    var awakeMinutes: Int { minutes(.awake) }
    /// Measured sleep: only minutes the ring actually reported as a sleep stage. This is the input
    /// to the Home readiness score (`TideReadinessEngine.sleepScore`) — do not change its meaning.
    var asleepMinutes: Int { lightMinutes + deepMinutes + remMinutes }

    /// The session length: first block start → last block end. This is PulseLoop's
    /// `session.totalMinutes` (PulseEventBus.swift:456) — a pure span — and is what the Sleep screen
    /// headlines, so the big number always matches the start–end range printed under it.
    var timeInBedMinutes: Int { max(0, Int(end.timeIntervalSince(start) / 60)) }
}

/// A per-day cumulative activity snapshot (steps/distance/calories).
struct DailyActivity: Identifiable, Codable, Equatable {
    var day: Date          // start of day (local)
    var steps: Int
    var distanceMeters: Double
    var calories: Double
    var timestamp: Date
    /// Final Tide activity score for this local day. Updated idempotently as late totals arrive.
    var activityScore: Int? = nil
    var id: Date { day }
}

/// Latest cumulative activity snapshot (the live "today" number).
struct ActivityRecord: Codable, Equatable {
    var steps: Int
    var distanceMeters: Double
    var calories: Double
    var timestamp: Date
}

/// One timestamped activity-history bucket. Persisting buckets makes repeated syncs idempotent:
/// each minute is stored once, then the local-day total is recomputed from distinct timestamps.
private struct StoredActivityBucket: Codable, Equatable {
    var timestamp: Date
    var steps: Int
    var distanceMeters: Double
}

/// One day's summary of a scalar metric, for range charts (min/max/avg).
struct DayStat: Identifiable {
    let id: Date          // start of day
    let day: Date
    let min: Double
    let max: Double
    let avg: Double
    let count: Int
    let last: Double
}

// MARK: - Persisted snapshot

private nonisolated struct RingStoreSnapshot: Codable {
    var heartRate: [RingReading] = []
    var spo2: [RingReading] = []
    var bloodPressure: [BloodPressureReading] = []
    var extraMeasurements: [ExtraMeasurement] = []
    var sleepBlocks: [SleepBlock] = []
    var dailyActivity: [DailyActivity] = []
    var activity: ActivityRecord?
    /// Optional so snapshots written before activity-history support remain decodable.
    var activityBuckets: [StoredActivityBucket]? = nil
    /// Optional so snapshots written by older Tide builds continue to decode.
    var readinessSnapshots: [TideReadinessSnapshot]? = nil
}

@MainActor
final class RingStore: ObservableObject {
    @Published private(set) var heartRate: [RingReading] = []
    @Published private(set) var spo2: [RingReading] = []
    @Published private(set) var bloodPressure: [BloodPressureReading] = []
    @Published private(set) var extraMeasurements: [ExtraMeasurement] = []
    @Published private(set) var sleepBlocks: [SleepBlock] = []
    @Published private(set) var dailyActivity: [DailyActivity] = []
    @Published private(set) var activity: ActivityRecord?
    @Published private(set) var readinessSnapshots: [TideReadinessSnapshot] = []
    /// Forces observing screens to cross midnight/time-zone boundaries even without new ring data.
    @Published private(set) var calendarRevision: UInt64 = 0

    /// Bumped whenever the sleep decoding changes in a way that invalidates stored blocks. Version 3
    /// is the PulseLoop-exact stage mapping (0x28 light / 0x63 deep / 0x00 awake, everything else
    /// discarded); versions below it are ignored and re-synced from the ring.
    static let sleepSchemaVersion = 3
    /// PulseLoop's `Calendar.sleepEveningBoundaryHour`.
    static let sleepEveningBoundaryHour = 19
    /// `RingReading.source` for rows replayed from the ring's stored log, as opposed to live samples.
    static let historySource = "history"

    private let perSeriesCap = 5000
    /// Sleep is capped by age, not row count — see `addSleepFrame`. Covers the Year range.
    private let sleepRetentionDays: TimeInterval = 400
    private let fileURL: URL
    /// Serial writes preserve mutation order when a sync emits many packets in quick succession.
    private let saveQueue = DispatchQueue(label: "com.tide.ring-store-writer", qos: .utility)
    private var calendar: Calendar { .autoupdatingCurrent }
    private var calendarCancellables: Set<AnyCancellable> = []
    private var activityBuckets: [StoredActivityBucket] = []

    // MARK: Latest-value convenience

    var latestHeartRate: RingReading? { heartRate.max(by: { $0.date < $1.date }) }
    var latestSpO2: RingReading? { spo2.max(by: { $0.date < $1.date }) }
    var latestBloodPressure: BloodPressureReading? { bloodPressure.max(by: { $0.date < $1.date }) }
    var latestNight: SleepNight? { sleepNights.max(by: { $0.id < $1.id }) }

    func latestExtra(_ kind: MeasurementKind) -> ExtraMeasurement? {
        extraMeasurements.filter { $0.kindRaw == kind.rawValue }.max(by: { $0.date < $1.date })
    }

    /// One night per waking day, exactly as PulseLoop assembles a `SleepSession`
    /// (`PulseEventBus.persistSleepTimeline`): every frame is filed under its waking-day key and all
    /// of that day's blocks form the session. There is deliberately no gap clustering and no
    /// choosing between sessions — those were Tide-only inventions that produced nights spanning
    /// from a daytime nap to the next morning.
    var sleepNights: [SleepNight] {
        // Only blocks written by the current decoder. Earlier builds classified every unrecognized
        // 0x11 byte as light or deep sleep; those rows record padding as sleep and can only be
        // discarded and re-synced, not repaired.
        let visibleBlocks = sleepBlocks.filter { $0.sampleSchemaVersion == Self.sleepSchemaVersion }
        var groups: [Date: [SleepBlock]] = [:]
        for block in visibleBlocks {
            let key = block.nightKeyRef ?? nightKey(for: block.start)
            groups[key, default: []].append(block)
        }
        return groups.map { SleepNight(id: $0.key, blocks: $0.value.sorted { $0.start < $1.start }) }
            .sorted { $0.id < $1.id }
    }

    init(filename: String = "tide-store.json") {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        fileURL = base.appendingPathComponent(filename)
        load()
        observeCalendarChanges()
    }

    // MARK: Ingest

    /// Unified heart-rate ingest: live samples and stored history land in the same series, deduped by
    /// minute so re-syncing the ring's log can't double-count.
    func addHeartRate(bpm: Int, date: Date, source: String) {
        if source == Self.historySource {
            // History rows are upserted on the exact timestamp, matching PulseLoop's
            // `isDuplicateHistory` (PulseEventBus.swift:368-384): the ring re-sends a slot with a
            // refined average, and that revision must replace the row rather than sit beside it.
            // Keying on (minute, value) — as this used to — treated a corrected reading as a new
            // one, so every re-sync piled up near-duplicates for the same minute and dragged the
            // average, min and max around.
            let epoch = Int(date.timeIntervalSince1970)
            if let index = heartRate.firstIndex(where: {
                $0.source == Self.historySource && Int($0.date.timeIntervalSince1970) == epoch
            }) {
                guard Int(heartRate[index].value) != bpm else { return }
                heartRate[index].value = Double(bpm)
                save()
                return
            }
        } else {
            // Live samples keep the minute-level guard so a streaming measurement can't fill the
            // series with identical rows.
            let minute = Int(date.timeIntervalSince1970 / 60)
            if heartRate.contains(where: {
                Int($0.date.timeIntervalSince1970 / 60) == minute && Int($0.value) == bpm
            }) { return }
        }
        heartRate.append(RingReading(value: Double(bpm), date: date, source: source))
        heartRate.sort { $0.date < $1.date }
        trim(&heartRate)
        save()
    }

    /// Collapse history rows that share a timestamp, keeping the most recently written value. Rows
    /// stored before the upsert above exist as duplicates already; this repairs them once at load
    /// so past averages stop being skewed.
    private func collapseDuplicateHistory(_ series: [RingReading]) -> [RingReading] {
        var keptIndexByEpoch: [Int: Int] = [:]
        var result: [RingReading] = []
        for reading in series {
            guard reading.source == Self.historySource else {
                result.append(reading)
                continue
            }
            let epoch = Int(reading.date.timeIntervalSince1970)
            if let index = keptIndexByEpoch[epoch] {
                result[index].value = reading.value
            } else {
                keptIndexByEpoch[epoch] = result.count
                result.append(reading)
            }
        }
        return result
    }

    func addSpO2(value: Int, date: Date, source: String = "live") {
        let minute = Int(date.timeIntervalSince1970 / 60)
        if spo2.contains(where: { Int($0.date.timeIntervalSince1970 / 60) == minute && Int($0.value) == value }) { return }
        spo2.append(RingReading(value: Double(value), date: date, source: source))
        spo2.sort { $0.date < $1.date }
        trim(&spo2)
        save()
    }

    func addBloodPressure(systolic: Int, diastolic: Int, date: Date) {
        let minute = Int(date.timeIntervalSince1970 / 60)
        if bloodPressure.contains(where: {
            Int($0.date.timeIntervalSince1970 / 60) == minute &&
            $0.systolic == systolic && $0.diastolic == diastolic
        }) { return }
        bloodPressure.append(BloodPressureReading(systolic: systolic, diastolic: diastolic, date: date))
        bloodPressure.sort { $0.date < $1.date }
        if bloodPressure.count > perSeriesCap { bloodPressure.removeFirst(bloodPressure.count - perSeriesCap) }
        save()
    }

    func addExtra(kind: MeasurementKind, value: Double, date: Date) {
        let minute = Int(date.timeIntervalSince1970 / 60)
        if extraMeasurements.contains(where: {
            $0.kindRaw == kind.rawValue &&
            Int($0.date.timeIntervalSince1970 / 60) == minute &&
            abs($0.value - value) < 0.001
        }) { return }
        extraMeasurements.append(ExtraMeasurement(kindRaw: kind.rawValue, value: value, date: date))
        extraMeasurements.sort { $0.date < $1.date }
        if extraMeasurements.count > perSeriesCap { extraMeasurements.removeFirst(extraMeasurements.count - perSeriesCap) }
        save()
    }

    /// Expand a `0x11` sleep frame (start + one stage per one-minute sample) into blocks, deduped by
    /// start time so a re-synced night doesn't duplicate.
    ///
    /// Every sample is stored, `.unknown` included — PulseLoop's `persistSleepTimeline` inserts the
    /// decoded stage unconditionally, and its session bounds are computed over all of them. Unknown
    /// samples are then excluded from the stage totals and hidden in the hypnogram, never dropped.
    func addSleepFrame(start: Date, stages: [SleepStage]) {
        var changed = false
        // One key for the whole frame, from the frame's start — see `SleepBlock.nightKeyRef`.
        let frameKey = nightKey(for: start)
        for (i, stage) in stages.enumerated() {
            let blockStart = start.addingTimeInterval(TimeInterval(i * 60))
            let exists = sleepBlocks.contains {
                $0.sampleSchemaVersion == Self.sleepSchemaVersion
                    && abs($0.start.timeIntervalSince(blockStart)) < 30
            }
            if exists { continue }
            sleepBlocks.append(SleepBlock(
                stageRaw: stage.rawValue,
                start: blockStart,
                minutes: 1,
                sampleSchemaVersion: Self.sleepSchemaVersion,
                nightKeyRef: frameKey
            ))
            changed = true
        }
        if changed {
            sleepBlocks.sort { $0.start < $1.start }
            // Sleep is stored one block per minute, so a single night is ~480 blocks. A 5000-row cap
            // would silently evict everything older than ~10 nights and leave the Month/Year ranges
            // empty. Trim by age instead, which is what those ranges actually need.
            let cutoff = Date().addingTimeInterval(-sleepRetentionDays * 24 * 3600)
            sleepBlocks.removeAll { $0.start < cutoff }
            save()
        }
    }

    func updateActivity(_ record: ActivityRecord) {
        if activity == nil || record.timestamp >= activity!.timestamp {
            activity = record
        }
        let day = calendar.startOfDay(for: record.timestamp)
        let daily = DailyActivity(day: day, steps: record.steps, distanceMeters: record.distanceMeters,
                                  calories: record.calories, timestamp: record.timestamp)
        if let index = dailyActivity.firstIndex(where: {
            calendar.isDate($0.timestamp, inSameDayAs: record.timestamp)
        }) {
            // Cumulative totals only ratchet up during a day.
            dailyActivity[index].day = day
            dailyActivity[index].steps = max(dailyActivity[index].steps, daily.steps)
            dailyActivity[index].distanceMeters = max(dailyActivity[index].distanceMeters, daily.distanceMeters)
            dailyActivity[index].calories = max(dailyActivity[index].calories, daily.calories)
            dailyActivity[index].timestamp = max(dailyActivity[index].timestamp, daily.timestamp)
        } else {
            dailyActivity.append(daily)
            dailyActivity.sort { $0.day < $1.day }
        }
        save()
    }

    /// Upsert one one-minute history bucket, then rebuild that day's total from distinct buckets.
    /// Returns `true` only when this sync added or corrected data.
    @discardableResult
    func addActivityBucket(timestamp: Date, steps: Int, distanceMeters: Double) -> Bool {
        let minute = Int(timestamp.timeIntervalSince1970 / 60)
        if let index = activityBuckets.firstIndex(where: {
            Int($0.timestamp.timeIntervalSince1970 / 60) == minute
        }) {
            let existing = activityBuckets[index]
            guard existing.steps != steps || existing.distanceMeters != distanceMeters else { return false }
            activityBuckets[index] = StoredActivityBucket(
                timestamp: timestamp, steps: steps, distanceMeters: distanceMeters
            )
        } else {
            activityBuckets.append(StoredActivityBucket(
                timestamp: timestamp, steps: steps, distanceMeters: distanceMeters
            ))
        }

        activityBuckets.sort { $0.timestamp < $1.timestamp }
        if activityBuckets.count > 15_000 {
            activityBuckets.removeFirst(activityBuckets.count - 15_000)
        }
        rebuildActivityDay(containing: timestamp)
        save()
        return true
    }

    func clearAll() {
        heartRate = []; spo2 = []; bloodPressure = []; extraMeasurements = []
        sleepBlocks = []; dailyActivity = []; activityBuckets = []; activity = nil; readinessSnapshots = []
        save()
    }

    /// Merged cumulative activity totals for a local day. Taking maxima makes duplicate history
    /// packets and time-zone-created duplicate rows harmless rather than double-counting them.
    func activityRecord(onLocalDay date: Date) -> DailyActivity? {
        let rows = dailyActivity.filter {
            calendar.isDate($0.timestamp, inSameDayAs: date) || calendar.isDate($0.day, inSameDayAs: date)
        }
        guard !rows.isEmpty else { return nil }
        let latest = rows.max(by: { $0.timestamp < $1.timestamp })!
        return DailyActivity(
            day: calendar.startOfDay(for: date),
            steps: rows.map(\.steps).max() ?? 0,
            distanceMeters: rows.map(\.distanceMeters).max() ?? 0,
            calories: rows.map(\.calories).max() ?? 0,
            timestamp: latest.timestamp,
            activityScore: rows.compactMap(\.activityScore).last
        )
    }

    func todayActivityRecord(now: Date = Date()) -> ActivityRecord? {
        guard let row = activityRecord(onLocalDay: now) else { return nil }
        return ActivityRecord(
            steps: row.steps,
            distanceMeters: row.distanceMeters,
            calories: row.calories,
            timestamp: row.timestamp
        )
    }

    /// The sleep session that completed as "last night."
    ///
    /// Nights are keyed to the morning they end on (see `nightKey`), so last night's key is *today*,
    /// not yesterday. Before 4 AM the current night is still in progress and today has no key yet,
    /// so we fall back to yesterday's — PulseLoop's `dayReferenceNight` rule
    /// (PulseServices.swift:596-608).
    func lastNight(forToday now: Date = Date()) -> SleepNight? {
        let today = calendar.startOfDay(for: now)
        let hour = calendar.component(.hour, from: now)
        let reference = hour < 4
            ? (calendar.date(byAdding: .day, value: -1, to: today) ?? today)
            : today
        return sleepNights
            .filter { calendar.isDate($0.id, inSameDayAs: reference) && $0.end <= now }
            .max(by: { $0.end < $1.end })
    }

    /// Recomputes and persists one day's final Activity Score from its ratcheted totals. Repeating
    /// this after duplicate or late updates is safe and converges on the same final score.
    @discardableResult
    func updateActivityScore(onLocalDay date: Date, settings: RingSettings) -> Int? {
        guard let row = activityRecord(onLocalDay: date) else { return nil }
        let calories = ActiveEnergy.resolved(
            ringCalories: row.calories,
            steps: row.steps,
            weightKg: settings.weightKg
        )
        let score = TideReadinessEngine.activityScore(
            steps: row.steps,
            activeCalories: calories,
            stepGoal: settings.stepGoal,
            calorieGoal: settings.calorieGoal
        )
        let matching = dailyActivity.indices.filter {
            calendar.isDate(dailyActivity[$0].timestamp, inSameDayAs: date) ||
            calendar.isDate(dailyActivity[$0].day, inSameDayAs: date)
        }
        for index in matching { dailyActivity[index].activityScore = score }
        if !matching.isEmpty { save() }
        return score
    }

    /// Calculates today's wellness snapshot after history sync, then freezes a complete score for
    /// the local day. An incomplete snapshot is allowed to heal when the missing history arrives.
    @discardableResult
    func freezeTodayReadiness(settings: RingSettings, now: Date = Date()) -> TideReadinessSnapshot {
        let todayKey = TideReadinessEngine.localDayKey(for: now, calendar: calendar)
        let existingIndex = readinessSnapshots.firstIndex(where: { $0.dayKey == todayKey })

        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let sourceKey = TideReadinessEngine.localDayKey(for: yesterday, calendar: calendar)
        let night = lastNight(forToday: now)
        let sleepScore = night.flatMap {
            TideReadinessEngine.sleepScore(
                actualSleepMinutes: $0.asleepMinutes,
                sleepGoalHours: settings.sleepGoalHours
            )
        }

        let activityScore = updateActivityScore(onLocalDay: yesterday, settings: settings)
        let yesterdayBP = bloodPressure
            .filter { calendar.isDate($0.date, inSameDayAs: yesterday) }
            .max(by: { $0.date < $1.date })
        let bpBand = yesterdayBP.map {
            TideReadinessEngine.bloodPressureBand(systolic: $0.systolic, diastolic: $0.diastolic)
        }
        let penalty = bpBand?.readinessPenalty ?? 0
        let score = TideReadinessEngine.readinessScore(
            sleepScore: sleepScore,
            activityScore: activityScore,
            penalty: penalty
        )
        // Recompute from live data every time, and keep the stored snapshot only when nothing it was
        // built from has changed. The old code returned the first score of the day forever, so once
        // Home had shown a number it could never be corrected — not by a re-sync, not by re-decoded
        // sleep, not by yesterday's activity arriving late. Returning early on an unchanged result
        // keeps `computedAt` and the persisted history stable without ever showing a stale figure.
        if let existingIndex {
            let existing = readinessSnapshots[existingIndex]
            if existing.score == score,
               existing.sleepScore == sleepScore,
               existing.activityScore == activityScore,
               existing.bloodPressurePenalty == penalty {
                return existing
            }
        }

        let snapshot = TideReadinessSnapshot(
            dayKey: todayKey,
            sourceDayKey: sourceKey,
            timeZoneIdentifier: calendar.timeZone.identifier,
            computedAt: now,
            sleepScore: sleepScore,
            activityScore: activityScore,
            bloodPressureBand: bpBand,
            bloodPressurePenalty: penalty,
            score: score
        )
        if let existingIndex {
            // A sync can finish before every history stream has landed. Do not let that first,
            // incomplete result lock the Home screen in LEARNING for the rest of the day.
            readinessSnapshots[existingIndex] = snapshot
        } else {
            readinessSnapshots.append(snapshot)
        }
        readinessSnapshots.sort { $0.computedAt < $1.computedAt }
        if readinessSnapshots.count > 45 {
            readinessSnapshots.removeFirst(readinessSnapshots.count - 45)
        }
        save()
        return snapshot
    }

    func readinessSnapshot(forToday now: Date = Date()) -> TideReadinessSnapshot? {
        let key = TideReadinessEngine.localDayKey(for: now, calendar: calendar)
        return readinessSnapshots.first { $0.dayKey == key }
    }

    // MARK: Analytics helpers (for charts)

    /// Per-day min/max/avg for a scalar series over the last `days` days (oldest→newest, gaps included).
    func dayStats(_ series: [RingReading], days: Int, now: Date = Date()) -> [DayStat] {
        let startDay = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -(days - 1), to: now) ?? now)
        let grouped = Dictionary(grouping: series.filter { $0.date >= startDay }) { calendar.startOfDay(for: $0.date) }
        var out: [DayStat] = []
        for offset in 0..<days {
            guard let day = calendar.date(byAdding: .day, value: offset, to: startDay) else { continue }
            let entries = grouped[day] ?? []
            let values = entries.map(\.value).sorted()
            if values.isEmpty {
                out.append(DayStat(id: day, day: day, min: 0, max: 0, avg: 0, count: 0, last: 0))
            } else {
                out.append(DayStat(id: day, day: day, min: values.first!, max: values.last!,
                                   avg: values.reduce(0, +) / Double(values.count), count: values.count,
                                   last: entries.max(by: { $0.date < $1.date })!.value))
            }
        }
        return out
    }

    /// Samples of a series that fall on a given calendar day (for the intraday day chart).
    func samples(_ series: [RingReading], onDay day: Date) -> [RingReading] {
        series.filter { calendar.isDate($0.date, inSameDayAs: day) }.sorted { $0.date < $1.date }
    }

    /// Per-day step totals over the last `days` days (gaps → 0).
    func stepDays(_ days: Int, now: Date = Date()) -> [DayStat] {
        let startDay = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -(days - 1), to: now) ?? now)
        let byDay = Dictionary(uniqueKeysWithValues: dailyActivity.map { ($0.day, $0) })
        var out: [DayStat] = []
        for offset in 0..<days {
            guard let day = calendar.date(byAdding: .day, value: offset, to: startDay) else { continue }
            let steps = Double(byDay[day]?.steps ?? 0)
            out.append(DayStat(id: day, day: day, min: 0, max: steps, avg: steps, count: byDay[day] == nil ? 0 : 1, last: steps))
        }
        return out
    }

    /// Per-day active-calorie totals over the last `days` days. Uses the ring's calorie field when
    /// present, otherwise a step-based estimate (`weightKg` from the user profile). Gaps → 0.
    func calorieDays(_ days: Int, weightKg: Int, now: Date = Date()) -> [DayStat] {
        let startDay = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -(days - 1), to: now) ?? now)
        let byDay = Dictionary(uniqueKeysWithValues: dailyActivity.map { ($0.day, $0) })
        var out: [DayStat] = []
        for offset in 0..<days {
            guard let day = calendar.date(byAdding: .day, value: offset, to: startDay) else { continue }
            let record = byDay[day]
            let kcal = record.map { ActiveEnergy.resolved(ringCalories: $0.calories, steps: $0.steps, weightKg: weightKg) } ?? 0
            out.append(DayStat(id: day, day: day, min: 0, max: kcal, avg: kcal, count: record == nil ? 0 : 1, last: kcal))
        }
        return out
    }

    // MARK: Internal

    /// The waking-morning key for a sleep session, ported from PulseLoop's
    /// `Calendar.wakingDay(forSleepStart:)` (PulseServices.swift:541-556).
    ///
    /// Sleep starting at or after 7 PM belongs to the *next* day's morning — you fall asleep tonight
    /// and wake tomorrow — so a night crossing midnight lands on the single morning it ends on.
    /// Anything earlier (small hours, or a daytime nap) stays on the current day. A night is
    /// therefore keyed to the date you woke up on.
    private func nightKey(for date: Date) -> Date {
        let startOfDay = calendar.startOfDay(for: date)
        let hour = calendar.component(.hour, from: date)
        guard hour >= Self.sleepEveningBoundaryHour else { return startOfDay }
        return calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? startOfDay
    }

    private func trim(_ series: inout [RingReading]) {
        if series.count > perSeriesCap { series.removeFirst(series.count - perSeriesCap) }
    }

    private func snapshot() -> RingStoreSnapshot {
        RingStoreSnapshot(
            heartRate: heartRate, spo2: spo2, bloodPressure: bloodPressure,
            extraMeasurements: extraMeasurements, sleepBlocks: sleepBlocks,
            dailyActivity: dailyActivity, activity: activity, activityBuckets: activityBuckets,
            readinessSnapshots: readinessSnapshots
        )
    }

    private func rebuildActivityDay(containing timestamp: Date) {
        let day = calendar.startOfDay(for: timestamp)
        let buckets = activityBuckets.filter { calendar.isDate($0.timestamp, inSameDayAs: day) }
        guard !buckets.isEmpty else { return }

        let bucketSteps = buckets.reduce(0) { $0 + $1.steps }
        let bucketDistance = buckets.reduce(0) { $0 + $1.distanceMeters }
        let latestBucketAt = buckets.map(\.timestamp).max() ?? timestamp

        if let index = dailyActivity.firstIndex(where: {
            calendar.isDate($0.timestamp, inSameDayAs: day) || calendar.isDate($0.day, inSameDayAs: day)
        }) {
            // A current cumulative packet can be newer/more complete than the history stream. Keep
            // whichever total is larger; history re-syncs can never make today's visible value fall.
            dailyActivity[index].day = day
            dailyActivity[index].steps = max(dailyActivity[index].steps, bucketSteps)
            dailyActivity[index].distanceMeters = max(dailyActivity[index].distanceMeters, bucketDistance)
            dailyActivity[index].timestamp = max(dailyActivity[index].timestamp, latestBucketAt)
        } else {
            dailyActivity.append(DailyActivity(
                day: day,
                steps: bucketSteps,
                distanceMeters: bucketDistance,
                calories: 0,
                timestamp: latestBucketAt
            ))
            dailyActivity.sort { $0.day < $1.day }
        }

        if calendar.isDateInToday(day), let row = activityRecord(onLocalDay: day) {
            let rebuilt = ActivityRecord(
                steps: row.steps,
                distanceMeters: row.distanceMeters,
                calories: row.calories,
                timestamp: row.timestamp
            )
            if activity == nil || rebuilt.steps >= activity!.steps { activity = rebuilt }
        }
    }

    private func save() {
        let snapshot = snapshot()
        let url = fileURL
        saveQueue.async {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            if let data = try? encoder.encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(RingStoreSnapshot.self, from: data) else { return }
        heartRate = collapseDuplicateHistory(snapshot.heartRate)
        spo2 = snapshot.spo2
        bloodPressure = snapshot.bloodPressure
        extraMeasurements = snapshot.extraMeasurements
        // Blocks written by an older decoder are unusable — their stage labels are wrong, not just
        // stale — so drop them at load rather than carrying dead rows forever. The next sync
        // re-populates from the ring, which keeps roughly a week of history.
        sleepBlocks = snapshot.sleepBlocks.filter { $0.sampleSchemaVersion == Self.sleepSchemaVersion }
        dailyActivity = snapshot.dailyActivity
        activity = snapshot.activity
        activityBuckets = snapshot.activityBuckets ?? []
        readinessSnapshots = snapshot.readinessSnapshots ?? []
    }

    private func observeCalendarChanges() {
        let names: [Notification.Name] = [
            .NSCalendarDayChanged,
            .NSSystemTimeZoneDidChange,
            UIApplication.significantTimeChangeNotification,
        ]
        for name in names {
            NotificationCenter.default.publisher(for: name)
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.calendarRevision &+= 1 }
                .store(in: &calendarCancellables)
        }
    }
}

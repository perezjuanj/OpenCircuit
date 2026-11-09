// The strap's own workout records, offered for review (#226, decision 91): the "DETECTED BY STRAP"
// inbox of the strap's Workout screen, the ring's detected-workout inbox done for the strap.
//
// `HelioStoreSink` hands every record the sync's walk delivers to `judge` (91c, the pure
// `HelioStrapWorkoutKeep`); the kept ones wait here until the person saves (one `HKWorkout` through the
// strap's own Health write path, `StrapWorkoutHealthWriting`, 91d) or discards them. After each walk,
// `reconcile` re-reads the app's workout history from Apple Health, drops what it now covers, and
// announces each newly kept record once (91e).
//
// UserDefaults, not SwiftData, like the ring's inbox (`RingSession`'s `workout.automaticDetection.*`
// keys): no model and no schema version. A record's heart rate is stored compactly (5 bytes a reading).

import Foundation
import Observation
import UserNotifications
import OpenCircuitKit
import ZeppKit

/// One kept record, as the inbox stores it.
struct StrapDetectedWorkout: Codable, Equatable, Identifiable {
    let timelineRaw: String
    let start: Date
    let durationSeconds: Int
    let kilocalories: Int?
    let averageHeartRate: Int?
    let maximumHeartRate: Int?
    let minimumHeartRate: Int?
    let sportCode: UInt64?
    let raw2_13: UInt64?
    /// Each reading: u32 LE milliseconds after `start`, then the u8 bpm.
    let heartRateData: Data

    var id: Date { start }
    var end: Date { start.addingTimeInterval(TimeInterval(durationSeconds)) }
    var window: DateInterval { DateInterval(start: start, end: end) }
    var duration: TimeInterval { TimeInterval(durationSeconds) }
    var timeline: SyncDeviceID { SyncDeviceID(rawValue: timelineRaw) }
    /// The sport the review starts on: the record's own where the app has it, else Other (91d).
    var suggestedSport: WorkoutSportType { ZeppWorkoutSport.sport(forCode: sportCode) }

    init(_ record: ZeppWorkoutRecord, timeline: SyncDeviceID) {
        let s = record.summary
        timelineRaw = timeline.rawValue
        start = s.start
        durationSeconds = s.durationSeconds
        kilocalories = s.kilocalories
        averageHeartRate = s.averageHeartRate
        maximumHeartRate = s.maximumHeartRate
        minimumHeartRate = s.minimumHeartRate
        sportCode = s.sportCode
        raw2_13 = s.raw2_13
        var data = Data(capacity: record.heartRate.count * 5)
        for reading in record.heartRate {
            let ms = (reading.time.timeIntervalSince(s.start) * 1000).rounded()
            guard ms >= 0, ms <= Double(UInt32.max), (0...255).contains(reading.bpm) else { continue }
            let value = UInt32(ms)
            data.append(contentsOf: [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF),
                                     UInt8(value >> 24), UInt8(reading.bpm)])
        }
        heartRateData = data
    }

    var heartRate: [ZeppWorkoutHeartRate] {
        let bytes = [UInt8](heartRateData)
        return stride(from: 0, to: bytes.count - 4, by: 5).map { i in
            var ms: UInt32 = 0
            for k in 0..<4 { ms |= UInt32(bytes[i + k]) << UInt32(8 * k) }
            return ZeppWorkoutHeartRate(time: start.addingTimeInterval(TimeInterval(ms) / 1000), bpm: Int(bytes[i + 4]))
        }
    }

    var record: ZeppWorkoutRecord {
        ZeppWorkoutRecord(summary: ZeppWorkoutSummary(
            start: start, durationSeconds: durationSeconds, kilocalories: kilocalories,
            averageHeartRate: averageHeartRate, maximumHeartRate: maximumHeartRate, minimumHeartRate: minimumHeartRate,
            sportCode: sportCode, raw2_13: raw2_13), heartRate: heartRate)
    }
}

/// Everything the inbox persists, in one value under one key.
struct StrapWorkoutInboxState: Codable, Equatable {
    struct Window: Codable, Equatable {
        let start: Date
        let end: Date
        var interval: DateInterval { DateInterval(start: start, end: max(start, end)) }
    }

    /// Kept records waiting for review, newest first.
    var pending: [StrapDetectedWorkout] = []
    /// Records the person discarded (91d: for good).
    var discarded: [Window] = []
    /// Records the person saved to Apple Health from here, so a re-delivery never comes back even
    /// before Health's history is read again.
    var saved: [Window] = []
    /// The app's own workouts as Apple Health last listed them (`reconcile`).
    var history: [Window] = []
    /// Starts already announced (91e).
    var announced: [Date] = []
    /// The walk's cursor per strap timeline (91c).
    var cursors: [String: Date] = [:]
}

@MainActor
@Observable
final class StrapDetectedWorkouts {
    nonisolated static let key = "strapWorkouts.detected.v1"
    static let shared = StrapDetectedWorkouts()

    private(set) var state: StrapWorkoutInboxState
    /// The ring's copy (91d): shown in the review when a Health write failed; nil otherwise.
    private(set) var saveError: String?
    private(set) var saving = false
    /// Called after a save landed, so the history and Today's recent workouts reload.
    @ObservationIgnored var onWorkoutsChanged: () -> Void = {}

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let writer: any StrapWorkoutHealthWriting
    @ObservationIgnored private let historyWindows: @MainActor (DateInterval) async -> [DateInterval]
    @ObservationIgnored private let notify: @MainActor (StrapDetectedWorkout) async -> Bool
    @ObservationIgnored private let zones: @MainActor () async -> HeartRateZones
    @ObservationIgnored private let clock: () -> Date
    /// The inbox is the strap's: with the ring chosen it offers nothing (91f).
    @ObservationIgnored private let isStrapChosen: @MainActor () -> Bool
    /// Starts claimed for a notification in flight (the ring's in-memory claim).
    @ObservationIgnored private var announcing: Set<Date> = []

    /// The ring's error copy for a failed "Add to Apple Health" (`WorkoutSessionManager.importDetectedWorkout`).
    static let saveFailedCopy = "Apple Health did not accept the detected workout. It was not removed, so you can try again."

    init(defaults: UserDefaults = .standard,
         writer: (any StrapWorkoutHealthWriting)? = nil,
         historyWindows: @escaping @MainActor (DateInterval) async -> [DateInterval] = StrapDetectedWorkouts.healthHistory,
         notify: @escaping @MainActor (StrapDetectedWorkout) async -> Bool = StrapDetectedWorkouts.postNotification,
         zones: @escaping @MainActor () async -> HeartRateZones = { await HeartRateZoneDefaults.currentZones() },
         isStrapChosen: @escaping @MainActor () -> Bool = { ActiveDeviceChoiceStore.shared.isHelio },
         clock: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.writer = writer ?? StrapWorkoutHealthWriter()
        self.historyWindows = historyWindows
        self.notify = notify
        self.zones = zones
        self.clock = clock
        self.isStrapChosen = isStrapChosen
        state = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(StrapWorkoutInboxState.self, from: $0) }
            ?? StrapWorkoutInboxState()
    }

    /// The records offered for review, newest first, none older than the inbox's two days. Nothing
    /// while the ring is the chosen device.
    var items: [StrapDetectedWorkout] {
        guard isStrapChosen() else { return [] }
        let cutoff = clock().addingTimeInterval(-HelioStrapWorkoutKeep.retention)
        return state.pending.filter { $0.end >= cutoff }.sorted { $0.start > $1.start }
    }

    // MARK: The walk (91a, 91c)

    func cursor(for timeline: SyncDeviceID) -> Date? { state.cursors[timeline.rawValue] }

    /// The verdict for one delivered record. A kept one is stored (re-delivery replaces it, never
    /// duplicates it); one dropped for good leaves the inbox if it was there.
    @discardableResult
    func judge(_ record: ZeppWorkoutRecord, timeline: SyncDeviceID, owned: Bool, now: Date) -> HelioStrapWorkoutKeep.Verdict {
        let verdict = HelioStrapWorkoutKeep.verdict(
            window: record.summary.window, owned: owned, history: (state.history + state.saved).map(\.interval),
            deleted: WorkoutTombstones(defaults).entries.map { DateInterval(start: $0.start, end: max($0.start, $0.end)) },
            discarded: state.discarded.map(\.interval), now: now)
        switch verdict {
        case .keep:
            let item = StrapDetectedWorkout(record, timeline: timeline)
            state.pending.removeAll { $0.start == item.start }
            state.pending.append(item)
        case .drop:
            state.pending.removeAll { $0.start == record.start }
        case .notYet:
            break
        }
        persist(now: now)
        return verdict
    }

    func setCursor(_ cursor: Date?, for timeline: SyncDeviceID, now: Date) {
        guard let cursor, cursor != state.cursors[timeline.rawValue] else { return }
        state.cursors[timeline.rawValue] = cursor
        persist(now: now)
    }

    // MARK: After a walk (91c, 91e)

    /// Re-reads the app's workouts from Apple Health, drops the pending records they (or a deletion)
    /// now cover, then announces each newly kept record once.
    func reconcile() async {
        let now = clock()
        let span = DateInterval(start: now.addingTimeInterval(-HelioStrapWorkoutKeep.retention - 86_400), end: now)
        let history = await historyWindows(span)
        state.history = history.map { StrapWorkoutInboxState.Window(start: $0.start, end: $0.end) }
        let deleted = WorkoutTombstones(defaults).entries.map { DateInterval(start: $0.start, end: max($0.start, $0.end)) }
        let covered = (state.history + state.saved).map(\.interval) + deleted
        state.pending.removeAll { item in covered.contains { HelioStrapWorkoutKeep.overlaps($0, item.window) } }
        persist(now: now)
        await announce(now: now)
    }

    private func announce(now: Date) async {
        let done = Set(state.announced).union(announcing)
        let due = items.filter { HelioStrapWorkoutAnnouncement.shouldAnnounce(start: $0.start, end: $0.end, announced: done, now: now) }
        guard !due.isEmpty else { return }
        announcing.formUnion(due.map(\.start))
        for item in due {
            let handled = await notify(item)
            announcing.remove(item.start)
            if handled {
                state.announced.append(item.start)
                persist(now: clock())
            }
        }
    }

    // MARK: Review (91d)

    /// One `HKWorkout` with the record's heart rate, through the strap's Health write path. On success
    /// the record leaves the inbox (and can't come back); on failure it stays, with the ring's copy.
    @discardableResult
    func save(_ item: StrapDetectedWorkout, as sport: WorkoutSportType) async -> Bool {
        guard !saving else { return false }
        saving = true
        saveError = nil
        defer { saving = false }
        let record = item.record
        // The ring's import uses the user's current zones too (`importDetectedWorkout`).
        let zones = await zones()
        let write = StrapWorkoutWrite(summary: HelioStrapWorkoutImport.summary(record, sport: sport, zones: zones),
                                      samples: HelioStrapWorkoutImport.samples(record), route: [], timeline: item.timeline)
        guard await writer.save(write) else {
            saveError = Self.saveFailedCopy
            return false
        }
        state.pending.removeAll { $0.start == item.start }
        state.saved.append(.init(start: item.start, end: item.end))
        persist(now: clock())
        onWorkoutsChanged()
        return true
    }

    /// Not a workout: gone for good, whatever the strap re-delivers.
    func discard(_ item: StrapDetectedWorkout) {
        state.pending.removeAll { $0.start == item.start }
        state.discarded.append(.init(start: item.start, end: item.end))
        persist(now: clock())
    }

    func clearSaveError() { saveError = nil }

    // MARK: Storage

    /// Bookkeeping older than any record the walk can still keep is dropped (91c: pruned at 2 days).
    private func persist(now: Date) {
        let cutoff = now.addingTimeInterval(-HelioStrapWorkoutKeep.retention)
        let bookkeepingCutoff = cutoff.addingTimeInterval(-86_400)
        state.pending.removeAll { $0.end < cutoff }
        state.discarded.removeAll { $0.end < bookkeepingCutoff }
        state.saved.removeAll { $0.end < bookkeepingCutoff }
        state.history.removeAll { $0.end < bookkeepingCutoff }
        state.announced.removeAll { $0 < bookkeepingCutoff.addingTimeInterval(-HelioStrapWorkoutKeep.retention) }
        if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: Self.key) }
    }

    // MARK: Production collaborators

    /// The windows of the app's own workouts in Apple Health that end inside `span`.
    static func healthHistory(_ span: DateInterval) async -> [DateInterval] {
        await WorkoutHistoryReader().workouts(startingBefore: nil, limit: 100)
            .filter { $0.end >= span.start && $0.start <= span.end }
            .map { DateInterval(start: $0.start, end: max($0.start, $0.end)) }
    }

    /// The notification's text, held to `NotificationBudget` like the ring's.
    nonisolated static func notificationCopy(duration: TimeInterval, start: Date, now: Date = Date(),
                                             calendar: Calendar = .current) -> (title: String, body: String) {
        let minutes = max(Int(duration / 60), 1)
        let durationText = minutes >= 90 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes) minutes"
        let time = calendar.isDate(start, inSameDayAs: now)
            ? start.formatted(date: .omitted, time: .shortened)
            : start.formatted(date: .abbreviated, time: .shortened)
        return ("Workout recorded by your strap",
                "Your strap recorded about \(durationText) starting at \(time). Open Workouts to review it.")
    }

    /// The ring's authorization handling (`RingSession.postAutomaticWorkoutNotification`): asked lazily,
    /// a declined prompt is final (handled), only a transient enqueue error is retried.
    static func postNotification(_ item: StrapDetectedWorkout) async -> Bool {
        let center = UNUserNotificationCenter.current()
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            break
        case .notDetermined:
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            guard granted else { return true }
        default:
            return true
        }
        let copy = notificationCopy(duration: item.duration, start: item.start)
        let content = UNMutableNotificationContent()
        content.title = copy.title
        content.body = copy.body
        content.sound = .default
        let identifier = "workout.strapDetected.\(item.timelineRaw).\(Int(item.start.timeIntervalSince1970))"
        do {
            try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
            return true
        } catch {
            return false
        }
    }
}

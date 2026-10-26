import Foundation
import os
import OpenCircuitKit
import SwiftData
import ZeppKit

// The Helio Strap's rows in `LocalStore` (#215 phase 3). No schema change: the strap writes the
// SchemaV8 tables the ring already uses, under its own timeline (`zeppos:<id>`, decision 10):
//   • samples through `ingest(_:device:)`, deduplicated by the timeline's per-kind cursors;
//   • per-minute steps into `StoredStepSample` / `StoredDaily`, deduplicated by a step cursor;
//   • each history type's fetch watermark as a `StoredCursor` row (`HelioFetchPlan.cursorName`);
//   • nights through `saveSleepSummary`, which already refuses to overwrite a manually edited night;
//   • naps (#231) through `saveNap`, as `StoredNap` rows like the ring's (`saveHelioNap`).

extension LocalStore {

    /// The step ledger's cursor name. Not a `MetricKind`: steps bypass `ingest`, whose cumulative
    /// counter path would take deltas of the strap's per-minute counts (decision 16: they are deltas).
    static let helioStepCursorName = "zepp.steps"

    // MARK: Cursors

    /// Every fetch watermark stored for `device`, by type.
    func helioFetchCursors(device: SyncDeviceID) -> [ZeppFetchType: Date] {
        var out: [ZeppFetchType: Date] = [:]
        for row in helioCursorRows(device: device) {
            guard let name = SyncCursorKey.name(fromKey: row.kindRaw, device: device),
                  let type = HelioFetchPlan.type(forCursorName: name) else { continue }
            out[type] = row.last
        }
        return out
    }

    /// The last value of one named cursor of `device`, or nil.
    func helioCursor(_ name: String, device: SyncDeviceID) -> Date? {
        let key = SyncCursorKey.key(name, device: device)
        let descriptor = FetchDescriptor<StoredCursor>(predicate: #Predicate { $0.kindRaw == key })
        return (try? context.fetch(descriptor).first)?.last
    }

    /// Upsert a named cursor of `device` (not saved: the caller saves with its rows).
    func stageHelioCursor(_ name: String, to date: Date, device: SyncDeviceID) {
        let key = SyncCursorKey.key(name, device: device)
        let descriptor = FetchDescriptor<StoredCursor>(predicate: #Predicate { $0.kindRaw == key })
        if let existing = try? context.fetch(descriptor).first {
            existing.last = date
        } else {
            context.insert(StoredCursor(kindRaw: key, last: date, deviceID: device.rawValue))
        }
    }

    /// Persist one fetch watermark.
    ///
    /// A backfilled type's watermark carries its ledger (`stageHelioCursorWithLedger`, stress `0x13`
    /// and PAI `0x0d`): this is the ONLY place any watermark is written, so routing every type
    /// through here is what makes "the ledger moves in the same save as the watermark" impossible to
    /// forget at a future call site (review-242b SF-1). Any other type stages only its watermark,
    /// exactly as before.
    func setHelioFetchCursor(_ type: ZeppFetchType, to date: Date, device: SyncDeviceID) throws {
        stageHelioCursorWithLedger(type, to: date, device: device)
        do { try context.save() } catch { context.rollback(); throw error }
    }

    private func helioCursorRows(device: SyncDeviceID) -> [StoredCursor] {
        let deviceID = device.rawValue
        let descriptor = FetchDescriptor<StoredCursor>(predicate: #Predicate { $0.deviceID == deviceID })
        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: Steps (decision 16)

    /// Store the strap's per-minute step counts newer than `device`'s step cursor, each as its own
    /// `StoredStepSample` over its own minute (so Apple Health gets additive deltas over their real
    /// interval, through the ring's step writer), and add them to the day's `StoredDaily`. Rows and
    /// cursor commit in one save; nothing is kept on failure. Returns the rows added.
    @discardableResult
    func ingestHelioStepMinutes(_ minutes: [QuantitySample], device: SyncDeviceID, now: Date = Date()) throws -> Int {
        let last = helioCursor(Self.helioStepCursorName, device: device) ?? .distantPast
        let ceiling = now.addingTimeInterval(86_400)
        let log = Self.ownershipLog()
        // Decision 28 / 28b, the ring's rule mirrored: a minute counts if `device` owns its last
        // instant, and its row is clamped to that ownership's start, so it lies wholly in the strap's
        // time (the minute a switch lands in goes to the device switched TO).
        func lastInstant(_ minute: QuantitySample) -> Date { max(minute.start, minute.end.addingTimeInterval(-1)) }
        let fresh = minutes
            .filter { $0.kind == .steps && $0.value > 0 && $0.start > last && $0.start <= ceiling }
            .filter { log.owns(device, at: lastInstant($0)) }
            .sorted { $0.start < $1.start }
        guard let newest = fresh.last?.start else { return 0 }
        var dailies: [Date: StoredDaily] = [:]
        for minute in fresh {
            let delta = Int(minute.value)
            let start = max(minute.start, log.ownershipStart(at: lastInstant(minute)))
            let day = Calendar.current.startOfDay(for: start)
            if dailies[day] == nil {
                let descriptor = FetchDescriptor<StoredDaily>(predicate: #Predicate { $0.day == day })
                if let existing = try context.fetch(descriptor).first {
                    dailies[day] = existing
                } else {
                    let row = StoredDaily(day: day, steps: 0)
                    context.insert(row)
                    dailies[day] = row
                }
            }
            dailies[day]?.steps += delta
            dailies[day]?.updatedAt = now
            context.insert(StoredStepSample(start: start, end: minute.end, delta: delta))
        }
        stageHelioCursor(Self.helioStepCursorName, to: newest, device: device)
        do { try context.save() } catch { context.rollback(); throw error }
        return fresh.count
    }

    // MARK: Nights (decisions 12, 13)

    /// The in-bed windows of nights the person edited by hand (decision 13's "never overwrite").
    func manuallyEditedSleepWindows(from start: Date, to end: Date) -> [DateInterval] {
        let lo = start.addingTimeInterval(-86_400)
        let hi = end.addingTimeInterval(86_400)
        let rows = (try? sleepSummaries(from: lo, to: hi)) ?? []
        return rows.compactMap { row in
            guard row.isManuallyEdited, row.inBedEnd > row.inBedStart else { return nil }
            return DateInterval(start: row.inBedStart, end: row.inBedEnd)
        }
    }

    /// Store one of the strap's staged nights, with its nightly skin temperature judged exactly as
    /// the ring's (`SkinTempBaseline.nightlyVerdict` over the stored, gated readings in the window).
    @discardableResult
    func saveHelioNight(_ night: HelioSleepSelection.Night, device: SyncDeviceID) throws -> SleepPersistOutcome {
        let segments = night.segments
        let window = night.window
        var extras = SleepNightExtras()
        extras.hypnogram = segments
        let temperatures = helioTemperatures(in: window, device: device)
        // Decision 71i: judged over the night's in-bed spans, so a joined night's awake gap is no sleep.
        // Decision 74c: its sleep fragments' spans, never an awake run of the fill.
        switch HelioSkinTemperatureGate.nightlyVerdict(samples: temperatures, inBedSpans: night.sleepSpans) {
        case .published(let mean): extras.skinTempC = mean
        case .rejectedCoverage: extras.skinTempWithheld = true
        case .notMeasured: break
        }
        let sleep = SleepStaging.sleepWindow(segments)
        // #246 / decision 48: the night's Sleep Score and overnight recovery, from the strap's own
        // stored rows (`LocalStore+HelioNightScore.swift`). Nothing is written as 0.
        applyHelioNightScores(to: &extras, window: window, segments: segments, device: device)
        return try saveSleepSummary(SleepStaging.summary(segments),
                                    night: SleepNightKey.night(inBedStart: window.start, inBedEnd: window.end),
                                    inBedStart: window.start, inBedEnd: window.end,
                                    sleepOnset: sleep?.onset ?? .distantPast, sleepWake: sleep?.wake ?? .distantPast,
                                    extras: extras, device: device)
    }

    /// The span of the night already mirrored to Apple Health under `night`'s key (`mirrorSettledNight`
    /// records it), if any: the key of the stored summary it overlaps, else the key its window files
    /// under, as the mirror resolves it.
    func writtenNightSpan(for night: HelioSleepSelection.Night) -> DateInterval? {
        let row = try? sleepSummaryOverlapping(start: night.window.start, end: night.window.end)
        let key = row?.night ?? SleepNightKey.night(inBedStart: night.window.start, inBedEnd: night.window.end)
        guard let record = mirroredNight(night: key), record.spanEnd > record.spanStart else { return nil }
        return DateInterval(start: record.spanStart, end: record.spanEnd)
    }

    // MARK: Naps (#231)

    /// Every stored night's window near `[start, end]`, whichever device stored it: the recorded in-bed
    /// window and, for an edited night, the edited one too. The main sleeps a strap nap is judged
    /// against (`HelioSleepSelection.naps(from:mainSleeps:now:)`), so a nap never sits in or beside a
    /// night either device keeps.
    ///
    /// Decision 77c: a strap night's recorded window is taken without its in-bed lead-in, so the
    /// lead-in never changes which sleep is a nap (a night without one: its window, as before).
    func storedNightWindows(from start: Date, to end: Date) -> [DateInterval] {
        let lo = Calendar.current.date(byAdding: .day, value: -2, to: start) ?? start
        let hi = Calendar.current.date(byAdding: .day, value: 2, to: end) ?? end
        let rows = (try? sleepSummaries(from: lo, to: hi)) ?? []
        var windows: [DateInterval] = []
        for row in rows {
            if row.inBedEnd > row.inBedStart {
                let window = DateInterval(start: row.inBedStart, end: row.inBedEnd)
                windows.append(HelioSleepSelection.windowWithoutLeadIn(SleepHypnogramCodec.decode(row.hypnogramData), window: window))
            }
            if row.isManuallyEdited, row.editedInBedEnd > row.editedInBedStart {
                windows.append(DateInterval(start: row.editedInBedStart, end: row.editedInBedEnd))
            }
        }
        return windows
    }

    /// Whether a stored nap other than the one keyed at `window.start` overlaps `window`: a nap the
    /// person added or edited (theirs, never replaced by a detection), or an earlier detection under
    /// another start. Either way the strap's nap is not stored beside it, so no sleep is counted twice.
    func otherNapOverlaps(_ window: DateInterval) -> Bool {
        let lo = window.start.addingTimeInterval(-86_400)
        let hi = window.end.addingTimeInterval(86_400)
        let rows = (try? naps(from: lo, to: hi)) ?? []
        return rows.contains { nap in
            guard nap.start != window.start || nap.isManuallyAdded || nap.isManuallyEdited else { return false }
            let start = min(nap.start, nap.effectiveStart)
            let end = max(nap.end, nap.effectiveEnd)
            return start < window.end && window.start < end
        }
    }

    /// Store one of the strap's naps (#231) exactly as the ring's are (`saveNap`): keyed by its start,
    /// the strap's stages as its hypnogram, so Apple Health gets them as ordinary sleep (§21.5 step 5)
    /// on the next flush (`HealthKitWriter.flushNaps`), named after the strap.
    func saveHelioNap(_ nap: HelioSleepSelection.Night) throws {
        try saveNap(start: nap.window.start, end: nap.window.end,
                    asleepMin: Int((SleepStaging.totalAsleep(nap.segments) / 60).rounded()),
                    isLongNap: nap.window.duration >= NapDetection.longNapDuration,
                    segments: nap.segments, family: .zeppOS)
    }

    /// Decision 74 (#278): `segments` (a strap night over `window`) with the awake time between its
    /// fragments filled from the STORED heart rate (`HelioSleepSelection.awakeFilled`): `device`'s own
    /// `.heartRate` rows in `window`, for time `device` owns (decision 28). Never a sync's fetched
    /// minutes (74b), so the night stored by a sync, the one handed to its flush and the one the 50b
    /// backstop rebuilds from the stored hypnogram are the same segments, whatever each sync fetched.
    /// A night with one fragment is returned as it is, and nothing is read.
    ///
    /// Decision 77b: a night stored with its in-bed lead-in keeps it. The fill is judged on the night
    /// without it (the lead-in lies before the first fragment, so it is no gap), and the lead-in it was
    /// stored with is put back, so the 50a hand-over and the 50b backstop rebuild the stored night.
    func helioAwakeFilled(_ segments: [SleepSegment], window: DateInterval, device: SyncDeviceID) -> [SleepSegment] {
        if let lead = HelioSleepSelection.leadIn(in: segments) {
            let base = HelioSleepSelection.windowWithoutLeadIn(segments, window: window)
            let filled = helioAwakeFilled(HelioSleepSelection.withoutLeadIn(segments), window: base, device: device)
            return HelioSleepSelection.withLeadIn(filled, window: base, from: lead.start)
        }
        guard HelioSleepSelection.inBedSpans(of: segments, window: window).count > 1 else { return segments }
        let kindRaw = MetricKind.heartRate.rawValue
        let deviceID = device.rawValue
        let start = window.start
        let end = window.end
        let descriptor = FetchDescriptor<StoredSample>(
            predicate: #Predicate { $0.kindRaw == kindRaw && $0.deviceID == deviceID && $0.start >= start && $0.start < end && $0.value > 0 },
            sortBy: [SortDescriptor(\.start)])
        let log = Self.ownershipLog()
        let minutes = ((try? context.fetch(descriptor)) ?? []).map(\.start).filter { log.owns(device, at: $0) }
        return HelioSleepSelection.awakeFilled(segments, window: window, heartRateMinutes: minutes)
    }

    /// `helioAwakeFilled` for a staged night: its window, score and recorded zone are unchanged.
    func helioAwakeFilled(_ night: HelioSleepSelection.Night, device: SyncDeviceID) -> HelioSleepSelection.Night {
        HelioSleepSelection.Night(segments: helioAwakeFilled(night.segments, window: night.window, device: device),
                                  window: night.window, strapScore: night.strapScore, recordedTimeZone: night.recordedTimeZone)
    }

    /// `device`'s stored skin temperatures in `window` (already gated when stored).
    func helioTemperatures(in window: DateInterval, device: SyncDeviceID) -> [TemperatureSample] {
        let kindRaw = MetricKind.temperature.rawValue
        let deviceID = device.rawValue
        let start = window.start
        let end = window.end
        let descriptor = FetchDescriptor<StoredSample>(
            predicate: #Predicate { $0.kindRaw == kindRaw && $0.deviceID == deviceID && $0.start >= start && $0.start < end },
            sortBy: [SortDescriptor(\.start)])
        return ((try? context.fetch(descriptor)) ?? []).map { TemperatureSample(time: $0.start, celsius: $0.value) }
    }
}

// MARK: - The sink

/// `HelioHistorySink` over `LocalStore`: what each fetched round becomes (decisions 10–17).
@MainActor
final class HelioStoreSink: HelioHistorySink {
    private let store: LocalStore

    // Per-sync context: the temperature gate needs this sync's activity minutes and nights.
    private var activity: [ZeppActivityMinute] = []
    private var sessions: [ZeppSleepSession] = []
    private var storedNights: [HelioSleepSelection.Night] = []
    /// Decision 50a (#253): the re-delivered nights the merge kept a stored night over this sync. Only
    /// remembered here; what reaches the flush is derived from the stored rows at the end of the sync
    /// (`heldNightsForHealth`), because a later night of the same sync can replace that row (review-snh).
    private var keptFullerNights: [HelioSleepSelection.Night] = []
    /// Daytime sessions already logged this sync (decision 28c), so a re-run logs each once.
    private var notOvernightLogged: Set<DateInterval> = []
    /// Sleeps kept out of a night already written to Apple Health (28f, 58b), logged once per sync.
    private var keptApartLogged: Set<DateInterval> = []
    /// #231: what the store made of each overnight sleep offered as a night this sync, by window. Only an
    /// overnight sleep another night kept out of its key (`nightKeptOut`) may be judged as a nap.
    private var nightOutcomes: [DateInterval: SleepPersistOutcome] = [:]
    /// #231: nap verdicts already logged this sync, so a re-run logs each once.
    private var napLogged: Set<DateInterval> = []
    /// Decision 72: this sync's sleep-session round, for the diagnostics line (counts only).
    private var sleepRoundSeen = false
    private var napsStoredWindows: Set<DateInterval> = []
    private var napsUnsettledWindows: Set<DateInterval> = []
    private var napsTooShortWindows: Set<DateInterval> = []
    private var latestStress: HelioReading?
    private var latestPAI: HelioReading?

    /// The strap's link breadcrumbs (`HelioConnection` hands them over); nil in tests.
    private let breadcrumbs: HelioBreadcrumbs?
    /// Where the store's own sleep breadcrumbs go (`sleep-extend`, decision 58b).
    private let observability: ObservabilityStore

    init(store: LocalStore, breadcrumbs: HelioBreadcrumbs? = nil, observability: ObservabilityStore = ObservabilityStore()) {
        self.store = store
        self.breadcrumbs = breadcrumbs
        self.observability = observability
    }

    func fetchCursors(timeline: SyncDeviceID, now: Date) -> [ZeppFetchType: Date] {
        // Before the plan is built: #239 (stress `0x13`) and decision 45 (PAI `0x0d`). Each is due at
        // most once per hole another build left, and neither can fire for an ordinary quiet stretch.
        //
        // Both take the SYNC's `now`, like `notBefore` and `persist` (review-248 SF-1): PAI's rewind
        // is floored at `now − 30 days` of sample retention, and reading the wall clock for it while
        // the rest of the sync ran on the session clock made that floor disagree with the plan built
        // from it. On a phone the two are the same instant; under an injected clock they are not.
        store.applyHelioStressBackfillIfNeeded(device: timeline, now: now)
        store.applyHelioPAIBackfillIfNeeded(device: timeline, now: now)
        return store.helioFetchCursors(device: timeline)
    }

    /// Decision 28: the strap's current ownership start. If it doesn't own the present (switched
    /// away mid-sync), nothing older than now is fetched.
    func notBefore(timeline: SyncDeviceID, now: Date) -> Date? {
        LocalStore.ownershipLog().currentStart(of: DeviceOwnershipLog.Family(timeline: timeline)) ?? now
    }

    /// Only what the strap recorded for time it owned is stored (decision 28). Nothing is lost:
    /// the acks stay `03 09`, so the strap keeps the rest.
    private func owned(_ samples: [QuantitySample], _ timeline: SyncDeviceID) -> [QuantitySample] {
        let log = LocalStore.ownershipLog()
        return samples.filter { log.owns(timeline, at: $0.start) }
    }

    func beginSync(timeline: SyncDeviceID, now: Date) {
        activity = []
        sessions = []
        storedNights = []
        keptFullerNights = []
        notOvernightLogged = []
        keptApartLogged = []
        nightOutcomes = [:]
        napLogged = []
        sleepRoundSeen = false
        napsStoredWindows = []
        napsUnsettledWindows = []
        napsTooShortWindows = []
        latestStress = nil
        latestPAI = nil
    }

    func persist(_ round: ZeppFetchRound, timeline: SyncDeviceID, now: Date) -> Bool {
        do {
            switch round.parsed.records {
            case .activity(let minutes):
                activity += minutes
                _ = try store.ingest(owned(ZeppMetricMapping.storedSamples(from: round.parsed), timeline), device: timeline)
                try store.ingestHelioStepMinutes(ZeppMetricMapping.stepMinutes(from: round.parsed), device: timeline, now: now)
            case .sleepSession(let records):
                sessions += records
                sleepRoundSeen = true
                try storeNights(timeline: timeline, now: now)
            case .temperature(let minutes):
                let nights = ownedNights(timeline: timeline, now: now)
                // Decision 71i: each night's in-bed spans, so a minute in a joined night's awake gap
                // is outside every sleep window. Decision 74c: its sleep fragments' spans, never an
                // awake run.
                let gated = HelioSkinTemperatureGate.samples(temperatures: minutes, activity: activity,
                                                             sleepWindows: nights.flatMap(\.sleepSpans))
                _ = try store.ingest(owned(gated, timeline), device: timeline)
                // Hold the watermark where a minute may still pass the gate later (no night yet, or
                // no wear record this sync), so it is fetched again instead of skipped for good.
                let previous = store.helioFetchCursors(device: timeline)[.temperature]
                let held = HelioFetchPlan.temperatureCursor(
                    proposed: HelioFetchPlan.advancedCursor(previous: previous, round: round, now: now),
                    previous: previous,
                    earliestWearUnknown: HelioSkinTemperatureGate.earliestWearUnknown(temperatures: minutes, activity: activity),
                    latestNightEnd: sessionNightsEnd(timeline: timeline, now: now), now: now)
                if let held, held != previous { try store.setHelioFetchCursor(.temperature, to: held, device: timeline) }
                return true
            case .autoStress(let minutes):
                if let last = minutes.last(where: { $0.level != nil }), let level = last.level {
                    latestStress = HelioReading(value: Double(level), at: last.time)
                }
                // #239: every minute is kept as `.stress` history, in the app only (no Health type).
                _ = try store.ingest(owned(ZeppMetricMapping.storedSamples(from: round.parsed), timeline), device: timeline)
            case .pai(let records):
                if let last = records.last { latestPAI = HelioReading(value: Double(last.totalPAI), at: last.time) }
                // Decision 45: every valid record is kept as one `.pai` row, in the app only (no
                // Health type). The card reads the newest of them, so it survives a sync with no PAI
                // record — `0x0d` arrives about daily — and every relaunch.
                _ = try store.ingest(owned(ZeppMetricMapping.storedSamples(from: round.parsed), timeline), device: timeline)
            default:
                _ = try store.ingest(owned(ZeppMetricMapping.storedSamples(from: round.parsed), timeline), device: timeline)
            }
            let previous = store.helioFetchCursors(device: timeline)[round.type]
            if let next = HelioFetchPlan.advancedCursor(previous: previous, round: round, now: now), next != previous {
                try store.setHelioFetchCursor(round.type, to: next, device: timeline)
            }
            return true
        } catch {
            helioLog.error("helio: storing a \(round.type.displayName, privacy: .public) round failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Store every staged night seen so far this sync that the person hasn't edited.
    /// The strap's own nights in this sync's sessions (review-224e S-1): each session's sleep, kept only
    /// when the strap owns its OWN window (decision 28/28a), and only then 28f's stitch. Stitching first
    /// let a doze from before a ring → strap switch drag the strap's own night into ring time, and then
    /// neither device kept it. Used by `storeNights` and the temperature gate. With an empty log (a
    /// ring-only install) nothing is the strap's, as before.
    ///
    /// Decision 73 (#278): this sync's activity sleep blocks (the strap's kind-sleep minutes outside every
    /// staged session) are stitched in like raw sleeps, each kept only when the strap owns its own window
    /// (71d), and a block is used only when it joins a night that holds a session (73c): one standing
    /// alone never reaches `storeNights`, `storeNaps` or the temperature gate. With no activity minutes
    /// (no activity round, or it failed) this is the sessions' stitch, as before.
    private func ownedNights(timeline: SyncDeviceID, now: Date) -> [HelioSleepSelection.Night] {
        ownedSleep(timeline: timeline, now: now).nights
    }

    /// `ownedNights` with the decision-73c counts.
    private func ownedSleep(timeline: SyncDeviceID, now: Date) -> HelioSleepSelection.ActivityJoin {
        let log = LocalStore.ownershipLog()
        let family = DeviceOwnershipLog.Family(timeline: timeline)
        let staged = sessions.compactMap { HelioSleepSelection.night(from: $0, now: now) }
        let blocks = HelioSleepSelection.activityBlocks(from: activity, sessions: staged, now: now)
            .filter { log.owner(ofNightFrom: $0.window.start, to: $0.window.end) == family }
        return HelioSleepSelection.nights(sessions: ownedSessions(staged, timeline: timeline), activityBlocks: blocks)
    }

    /// Decision 73d: the latest end of the strap's own SESSION nights (no activity block), which holds
    /// the temperature watermark exactly as before decision 73. The activity round starts at that
    /// watermark at the latest (`HelioFetchPlan.plan`), so every sync re-fetches the activity minutes
    /// after the night's record ended, and a block is always judged whole: one held while in progress,
    /// and an earlier block of a night that keeps growing. Held at a joined block's end instead, the
    /// next sync would miss the earlier block's minutes, and an extension without them would replace
    /// the night in Apple Health.
    private func sessionNightsEnd(timeline: SyncDeviceID, now: Date) -> Date? {
        let staged = sessions.compactMap { HelioSleepSelection.night(from: $0, now: now) }
        return HelioSleepSelection.stitch(ownedSessions(staged, timeline: timeline)).map(\.window.end).max()
    }

    /// The staged sessions the strap owns, each judged on its own window (decision 28a/71d).
    private func ownedSessions(_ staged: [HelioSleepSelection.Night], timeline: SyncDeviceID) -> [HelioSleepSelection.Night] {
        let log = LocalStore.ownershipLog()
        let family = DeviceOwnershipLog.Family(timeline: timeline)
        return staged.filter { log.owner(ofNightFrom: $0.window.start, to: $0.window.end) == family }
    }

    private func storeNights(timeline: SyncDeviceID, now: Date) throws {
        let nights = ownedNights(timeline: timeline, now: now)
        guard let first = nights.first?.window.start, let last = nights.last?.window.end else { return }
        let edited = store.manuallyEditedSleepWindows(from: first, to: last)
        // Decision 28a: a night belongs to the device chosen when it began (saveSleepSummary also refuses
        // one the ring already keeps; only nights stored here reach the Health hand-off).
        let log = LocalStore.ownershipLog()
        let family = DeviceOwnershipLog.Family(timeline: timeline)
        // Decision 28c (review-224c S-1): only an overnight strap sleep is a night. The ring's own gate,
        // with the ring's parameters (`SleepWindow.isOvernightBlock(start:end:)`, local calendar), so a
        // daytime session never takes a night key and can never make the ring's night unkeepable.
        // Decision 28d (review-224d S-1): it must also END in its key's wake window, the store's own rule
        // for "this is the night its key names" (`SleepNightKey.endsInWakeWindow`), so an evening doze
        // the overnight gate accepts (20:00–22:30) never takes a night key either.
        // Decision 28e (review-224d S-2): both judged in the zone the night was RECORDED in (the strap's
        // own local-midnight reference), never the phone's zone at sync time, so a normal night first
        // synced after a flight is still a night. Same functions, one explicit calendar.
        // Decision 71a (#278): the one shared predicate (`HelioSleepSelection.overnightVerdict`), which
        // `stitch` also uses to join the overnight sleeps of one night.
        let overnight = nights.filter { night in
            let verdict = HelioSleepSelection.overnightVerdict(night)
            if verdict == .overnight { return true }
            if notOvernightLogged.insert(night.window).inserted {
                let span = Self.clockSpan(night.window, in: night.recordedTimeZone)
                if verdict == .notOvernight {
                    helioLog.notice("helio: sleep session \(span, privacy: .public) is not overnight; not stored as a night")
                } else {
                    helioLog.notice("helio: sleep session \(span, privacy: .public) doesn't end in its night's wake window; not stored as a night")
                }
            }
            return false
        }
        // The ownership check again, on the stitched window: a backstop (`ownedNights` already kept
        // only the strap's own sleeps).
        for staged in HelioSleepSelection.nightsToWrite(overnight, manuallyEdited: edited)
        where log.owner(ofNightFrom: staged.window.start, to: staged.window.end) == family
            && !storedNights.contains(where: { $0.windowWithoutLeadIn == staged.window }) {
            // Decision 74 (#278): the awake time between the night's fragments, from the stored heart
            // rate (the activity round, which ingests it, runs before this sleep round). Inside the
            // window, so every window rule below judges the night exactly as before.
            let filled = store.helioAwakeFilled(staged, device: timeline)
            // Decision 77 (#328): the in-bed lead-in before the first fragment, from the stored heart
            // rate and steps (77b), judged after the stitch and the nap split (77c: `staged` is already
            // stitched, and the sync's other sleeps, naps to be included, clamp it). It moves the
            // window's start only. 77f: a night already in Apple Health is never rewritten for it.
            // Written with this very lead-in, it passes as before; written without one (an earlier
            // build, or before the heart rate was stored), it goes on WITHOUT a lead-in, exactly as
            // before decision 77, so the card and Health keep agreeing; any other start-only
            // difference is kept out below (28f, 58b). Only an extension (58b) takes its lead-in along.
            let withLeadIn = store.helioWithLeadIn(filled, sleeps: nights.map(\.window), device: timeline)
            var night = withLeadIn
            // Decision 28f stitches sessions 60 min or less apart into one night, and decision 71b
            // (#278) the overnight sleeps of one night key whatever the gap, so a night can grow after
            // it was written to Apple Health (back to bed after a mid-night awakening, after the Sleep
            // Focus finalization or the settle margin let the first part through), and the strap lets the
            // phone read a night still in progress (decision 58, #274), so a night written early can
            // be far shorter than the final record. The written night stands against anything that
            // does not EXTEND it (decision 58b): a different night for its key is kept out unless it
            // overlaps the written span and ends at least 10 min later (`strapNightExtends`). That
            // one is stored like any other, and its flush goes through the writer's signature rewrite
            // (`mirrorSettledNight`: write first, then delete the old span, nap-safe), behind the same
            // settle margin. Anything else is kept out, so Health gets no second write of it and
            // nothing written is silently replaced or shortened. A night not yet written still
            // stitches. A stitched session is not stored as a row of its own: it is 60 min or less
            // from the night, or an overnight sleep of the night's own key (71c), so it is part of the
            // main sleep, never a nap (#231, `storeNaps` never sees it). A night joined over a later
            // part overlaps the written first part and ends later, so it is an extension like any
            // other (71e). One joined over an EARLIER part ends where the written night ends, so it is
            // no extension and is kept out: a night an earlier build split as "earlier part = strap
            // nap, later part = the night in Health" stays split, nothing counted twice (71h, a known
            // gap; this build's own stitch never makes that split).
            var extending: DateInterval?
            if let written = store.writtenNightSpan(for: filled) {
                if !Self.sameSpan(written, withLeadIn.window), Self.sameSpan(written, filled.window) {
                    night = filled
                }
                if !Self.sameSpan(written, night.window) {
                    guard LocalStore.strapNightExtends(night.window, written: written) else {
                        if keptApartLogged.insert(staged.window).inserted {
                            helioLog.notice("helio: sleep \(Self.clockSpan(night.window, in: night.recordedTimeZone), privacy: .public) would change a night already in Apple Health (\(Self.clockSpan(written, in: night.recordedTimeZone), privacy: .public)) without extending it; the written night stands")
                        }
                        continue
                    }
                    extending = written
                }
            }
            let before = (try? store.sleepSummaryOverlapping(start: night.window.start, end: night.window.end))
                .map { DateInterval(start: $0.inBedStart, end: max($0.inBedStart, $0.inBedEnd)) }
            let outcome = try store.saveHelioNight(night, device: timeline)
            // Keyed by the stitched sleep's own window (what `storeNaps` looks up), never the lead-in's.
            nightOutcomes[staged.window] = outcome
            if outcome == .inserted || outcome == .updated { storedNights.append(night) }
            // Decision 58b: one breadcrumb per accepted extension, when it changed the stored row (so
            // several for one night whose in-progress copies keep growing). Not for a kept-out night:
            // every full sleep round re-delivers the last night or two, so that one would flood.
            if let written = extending, outcome == .inserted || outcome == .updated, before != night.window {
                recordExtension(night, written: written)
            }
            // Decision 50a (#253): the merge kept the stored night over this re-delivery, so without
            // this nothing offers the night to Health again: its first store can land inside the
            // settle margin, and every later sync re-delivers it a little thinner. Only remember it
            // here. Only the CURRENT stored row's night is handed to the flush, re-read when the sync
            // ends (`heldNightsForHealth`): a later sleep of this same round can still replace the row
            // (review-snh B-1), and then the copy kept here is no longer the night.
            if outcome == .keptFullerStoredNight, !keptFullerNights.contains(where: { $0.window == night.window }) {
                keptFullerNights.append(night)
            }
        }
        // #231: then the naps, judged against the nights as they are stored NOW, so a nap is never
        // chosen over a night (the nights above were stored first, and nothing here touches a night).
        storeNaps(nights, overnight: overnight, timeline: timeline, now: now)
    }

    /// The outcomes that mean another night holds the sleep's key, so the sleep itself is no night: the
    /// longer part of its own night (review-224e S-2; since decision 71b only when joining the two would
    /// exceed `maxNightLength`), the other device's night (28a), or a night the key already names
    /// (28d). Any other outcome (stored, kept as edited, deferred, failed) leaves the sleep a night,
    /// never a nap.
    private static let nightKeptOut: Set<SleepPersistOutcome> = [.keptFullerStoredNight, .ownedByOtherDevice, .refusedNightKeyCollision]

    /// #231 (ZEPP_PROTOCOL.md §21.5): store the strap's naps among `sleeps` (the sync's own stitched
    /// sleeps, `ownedNights`) like the ring's (`StoredNap`), shown in the same views and written to
    /// Apple Health by the same flush.
    ///
    /// The candidates are the sleeps that are no night: those 28c/28d kept from being one (daytime, or
    /// not ending in a wake window), and overnight ones another night kept out of their key
    /// (`nightKeptOut`). A sleep offered as a night and stored, edited, deferred or left out for any
    /// other reason is never a candidate. `HelioSleepSelection.naps` then judges them against every
    /// stored night (either device's) and the day's main-sleep window: a nap is more than 60 min from
    /// every main sleep, 20 min or longer, and settled. Only a nap the strap owned all of is stored
    /// (decision 28); `saveNap` refuses one overlapping a stored night, and a night stored later prunes
    /// an auto nap it overlaps, so a nap never displaces a night.
    private func storeNaps(_ sleeps: [HelioSleepSelection.Night], overnight: [HelioSleepSelection.Night],
                           timeline: SyncDeviceID, now: Date) {
        let overnightWindows = Set(overnight.map(\.window))
        var candidates: [HelioSleepSelection.Night] = []
        var keptOutOfItsNight: [HelioSleepSelection.Night] = []   // review-224e S-2's case
        for sleep in sleeps {
            if overnightWindows.contains(sleep.window) {
                guard let outcome = nightOutcomes[sleep.window], Self.nightKeptOut.contains(outcome) else { continue }
                if outcome == .keptFullerStoredNight { keptOutOfItsNight.append(sleep) }
            }
            candidates.append(sleep)
        }
        guard let first = candidates.map(\.window.start).min(), let last = candidates.map(\.window.end).max() else { return }
        let split = HelioSleepSelection.naps(from: candidates, mainSleeps: store.storedNightWindows(from: first, to: last), now: now)
        let log = LocalStore.ownershipLog()
        let family = DeviceOwnershipLog.Family(timeline: timeline)
        var storedAsNaps: Set<DateInterval> = []
        napsUnsettledWindows.formUnion(split.unsettled.map(\.window))
        napsTooShortWindows.formUnion(split.tooShort.map(\.window))
        for nap in split.naps {
            let span = Self.clockSpan(nap.window, in: nap.recordedTimeZone)
            guard log.ownsWholly(family, from: nap.window.start, to: nap.window.end) else {
                if napLogged.insert(nap.window).inserted {
                    helioLog.notice("helio: nap \(span, privacy: .public) is not wholly in the strap's time; not stored")
                }
                continue
            }
            guard !store.otherNapOverlaps(nap.window) else {
                if napLogged.insert(nap.window).inserted {
                    helioLog.notice("helio: nap \(span, privacy: .public) overlaps another stored nap; not stored")
                }
                continue
            }
            // Best effort: a nap that fails to save is judged again on the next sync (the strap keeps
            // its sessions, decision 8); it never fails the round, whose nights are already stored.
            do { try store.saveHelioNap(nap) } catch {
                helioLog.error("helio: storing a nap failed: \(error.localizedDescription, privacy: .public)")
                continue
            }
            storedAsNaps.insert(nap.window)
            napsStoredWindows.insert(nap.window)
            if napLogged.insert(nap.window).inserted {
                helioLog.notice("helio: sleep session \(span, privacy: .public) stored as a nap")
            }
        }
        for sleep in split.tooShort where napLogged.insert(sleep.window).inserted {
            // §21.5 step 4: the strap shouldn't send these, so one arriving says the rule is wrong.
            helioLog.notice("helio: sleep session \(Self.clockSpan(sleep.window, in: sleep.recordedTimeZone), privacy: .public) is under 20 min; not a nap")
            breadcrumbs?.strapSleepTooShort(day: Calendar.current.startOfDay(for: sleep.window.end))
        }
        // Review-224e S-2: a sleep more than 60 min from the night's longer part is kept out of its
        // night (since decision 71b only one that joining would push past `maxNightLength`); say
        // whether it is a nap now, without its time or length.
        for sleep in keptOutOfItsNight where (try? store.sleepSummaryOverlapping(start: sleep.window.start, end: sleep.window.end)) == nil {
            breadcrumbs?.strapSleepKeptOut(nightKey: SleepNightKey.night(inBedStart: sleep.window.start, inBedEnd: sleep.window.end),
                                           storedAsNap: storedAsNaps.contains(sleep.window))
        }
    }

    /// Decision 50a (#253), at the end of the sync: the stored nights the sync's re-deliveries were kept
    /// out of, each the CURRENT stored row's night, for this sync's flush (review-snh B-1). A stored
    /// night is never handed over beside a different night for its key:
    /// - a kept night whose row no longer overlaps its re-delivery (a later sleep of this sync replaced
    ///   the row in place) resolves to no row and is dropped. Handed over, the writer would find no row
    ///   to judge it against (its thinner-than-card bail needs one), write it over the night the card
    ///   shows, and 28f would then keep that night out for good;
    /// - one whose row is a night this sync stored (`.inserted`/`.updated`, already in `result.nights`)
    ///   is dropped, and two that resolve to one row are handed over once. Deduplicated by the row's key.
    private func heldNightsForHealth(timeline: SyncDeviceID, now: Date) -> [HelioSleepSelection.Night] {
        let family = DeviceOwnershipLog.Family(timeline: timeline)
        var keys = Set(storedNights.compactMap {
            (try? store.sleepSummaryOverlapping(start: $0.window.start, end: $0.window.end))?.night
        })
        var held: [HelioSleepSelection.Night] = []
        for incoming in keptFullerNights {
            guard let pick = heldForHealth(incoming, timeline: timeline, family: family, now: now),
                  keys.insert(pick.key).inserted else { continue }
            held.append(pick.night)
        }
        return held
    }

    /// Decision 50a (#253): the stored row `incoming` overlaps now, rebuilt from its stored hypnogram
    /// with the row's key, or nil when it must not be offered:
    /// - a row still overlaps `incoming` (re-read as the sync leaves the store);
    /// - the stored row is the strap's too (the loop's ownership check, on the row's own window);
    /// - it isn't manually edited (the edit reconcile owns it) and has a hypnogram;
    /// - Health has no mirror record for its key (a written night is the mirror's to keep current),
    ///   EXCEPT when the stored night, as offered (its segments' span), extends the written span
    ///   (decision 58e, 58b's `strapNightExtends`) and the writer hasn't declined that exact stored
    ///   hypnogram. That is a night stored over a shorter written one inside its settle margin, which
    ///   the strap then re-delivers a little thinner: kept by the merge, and otherwise never offered
    ///   again. After the writer's rewrite the mirror span is the union, which covers the row, so a
    ///   thinner re-delivery is held out again (50a's protection);
    /// - the strap's re-delivered copy has settled as well: the margin is judged on the LATER of the
    ///   two ends, so a stored row that ends early is never sent while the night is still going on.
    /// The strap's score and recorded zone come from the incoming night; the window is the stored
    /// segments' span. The segments carry the awake fill from the stored heart rate (decision 74), as
    /// the store path and the 50b backstop give them.
    private func heldForHealth(_ incoming: HelioSleepSelection.Night, timeline: SyncDeviceID, family: DeviceOwnershipLog.Family,
                               now: Date) -> (night: HelioSleepSelection.Night, key: Date)? {
        guard let row = try? store.sleepSummaryOverlapping(start: incoming.window.start, end: incoming.window.end),
              !row.isManuallyEdited,
              LocalStore.ownershipLog().owner(ofNightFrom: row.inBedStart, to: row.inBedEnd) == family else { return nil }
        let segments = SleepHypnogramCodec.decode(row.hypnogramData)
        guard let start = segments.map(\.start).min(), let end = segments.map(\.end).max(), end > start,
              SleepHealthGate.isSettled(latestSegmentEnd: max(incoming.segments.map(\.end).max() ?? incoming.window.end, end),
                                        now: now) else { return nil }
        if let written = store.writtenNightSpan(for: incoming) {
            guard LocalStore.strapNightExtends(DateInterval(start: start, end: end), written: written),
                  StrapNightDeclinedOverlay.load(storedNight: row.night) != row.hypnogramData else { return nil }
        }
        let window = DateInterval(start: start, end: end)
        return (HelioSleepSelection.Night(segments: store.helioAwakeFilled(segments, window: window, device: timeline), window: window,
                                          strapScore: incoming.strapScore, recordedTimeZone: incoming.recordedTimeZone),
                row.night)
    }

    /// Decision 58b's "the same span": both ends within 1 s (an identical window passes through).
    private static func sameSpan(_ a: DateInterval, _ b: DateInterval) -> Bool {
        abs(a.start.timeIntervalSince(b.start)) <= 1 && abs(a.end.timeIntervalSince(b.end)) <= 1
    }

    /// `HH:mm–HH:mm` in the recorded zone, for the 28c log line: when a session ran, no health value.
    private static func clockSpan(_ window: DateInterval, in zone: TimeZone?) -> String {
        let f = DateFormatter()
        if let zone { f.timeZone = zone }
        f.dateFormat = "HH:mm"
        return "\(f.string(from: window.start))–\(f.string(from: window.end))"
    }

    /// Decision 58b (#274): the `sleep-extend` breadcrumb for a night stored over a shorter one already
    /// in Apple Health: its key and both spans (`HH:mm` in the recorded zone). No health value.
    private func recordExtension(_ night: HelioSleepSelection.Night, written: DateInterval) {
        let key = (try? store.sleepSummaryOverlapping(start: night.window.start, end: night.window.end))?.night
            ?? SleepNightKey.night(inBedStart: night.window.start, inBedEnd: night.window.end)
        let day = DateFormatter()   // the key is a start of day in the current zone, as stored
        day.dateFormat = "MM-dd"
        observability.recordMetricEvent(
            source: "sleep-extend",
            detail: "EXTENDED night=\(day.string(from: key)) written=\(Self.clockSpan(written, in: night.recordedTimeZone)) "
                + "incoming=\(Self.clockSpan(night.window, in: night.recordedTimeZone))")
    }

    func finishSync(timeline: SyncDeviceID, now: Date) -> HelioSyncResult {
        // Re-save the nights now that their skin temperatures are stored (temperature is fetched
        // after sleep sessions): the same staging, so the summary is updated in place.
        for night in storedNights {
            _ = try? store.saveHelioNight(night, device: timeline)
        }
        // #246 / decision 48: score any strap night still stored without one — a merge that kept the
        // stored night never reaches `applyExtras`, and builds 59-62 stored every night unscored.
        _ = try? store.scoreUnscoredHelioNights()
        var result = HelioSyncResult()
        result.nights = storedNights
        result.nights += heldNightsForHealth(timeline: timeline, now: now)   // decision 50a (#253), review-snh B-1
        result.todaySteps = try? store.todaySteps(day: now)
        result.latestStress = latestStress
        result.latestPAI = latestPAI
        result.sleepRound = sleepRoundSummary(timeline: timeline, now: now)
        return result
    }

    /// Decision 72: the counts for this sync's diagnostics line, nil when no sleep-session round came.
    /// Reads only; nothing here stores, stitches or writes.
    private func sleepRoundSummary(timeline: SyncDeviceID, now: Date) -> StrapSleepRoundSummary? {
        guard sleepRoundSeen else { return nil }
        let staged = sessions.compactMap { HelioSleepSelection.night(from: $0, now: now) }
        var summary = StrapSleepRoundSummary()
        // Distinct records and sessions: a record the strap sends in two rounds is one record.
        summary.records = Set(sessions.map { DateInterval(start: $0.sleepStart, end: max($0.sleepStart, $0.sleepEnd)) }).count
        summary.staged = Set(staged.map(\.window)).count
        // 72a's nights and joined counts are the sessions' own (raw sessions, no activity block).
        let nights = HelioSleepSelection.stitch(ownedSessions(staged, timeline: timeline))
        summary.nights = nights.count
        summary.joinedSessions = nights.map(\.inBedSpans.count).filter { $0 > 1 }.reduce(0, +)
        let join = ownedSleep(timeline: timeline, now: now)
        summary.activityBlocksJoined = join.joinedBlocks
        summary.activityBlocksAlone = join.aloneBlocks
        for outcome in nightOutcomes.values { summary.outcomes[outcome, default: 0] += 1 }
        summary.keptOut58b = keptApartLogged.count
        summary.napsStored = napsStoredWindows.count
        summary.napsUnsettled = napsUnsettledWindows.count
        summary.napsTooShort = napsTooShortWindows.count
        if let oldest = staged.map(\.window.start).min() {
            let newestStoredEnd = store.storedNightWindows(from: oldest, to: now).map(\.end).max() ?? .distantPast
            summary.endsAfterNewestNight = Set(staged.filter { $0.window.end > newestStoredEnd }.map(\.window)).count
        }
        let since = now.addingTimeInterval(-24 * 3600)
        summary.activitySleepMinutesOutsideSessions = Set(activity.filter { minute in
            minute.kind == ZeppActivityMinute.kindSleep && minute.time >= since && minute.time <= now
                && !staged.contains { $0.window.start <= minute.time && minute.time < $0.window.end }
        }.map(\.time)).count
        return summary
    }
}

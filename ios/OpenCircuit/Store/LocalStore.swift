import Foundation
import SwiftData
import OpenCircuitKit

// SwiftData persistence: raw decoded samples + the per-metric sync cursor. The
// cursor mirrors OpenCircuitKit.SyncCursor (the testable source of truth); these
// @Model types are just its on-disk form.

@Model
final class StoredSample {
    var kindRaw: String
    var start: Date
    var end: Date
    var value: Double
    var rawValue: Double?
    // Default required so SwiftData can auto-migrate stores written before these
    // cumulative-counter columns existed (#21) — a new non-optional attribute with no
    // default fails lightweight migration and traps at ModelContainer init on launch.
    var isDelta: Bool = false
    var dailyTotal: Double?

    init(
        kindRaw: String,
        start: Date,
        end: Date,
        value: Double,
        rawValue: Double? = nil,
        isDelta: Bool = false,
        dailyTotal: Double? = nil
    ) {
        self.kindRaw = kindRaw
        self.start = start
        self.end = end
        self.value = value
        self.rawValue = rawValue
        self.isDelta = isDelta
        self.dailyTotal = dailyTotal
    }

    convenience init(
        _ s: QuantitySample,
        rawValue: Double? = nil,
        isDelta: Bool = false,
        dailyTotal: Double? = nil
    ) {
        self.init(
            kindRaw: s.kind.rawValue,
            start: s.start,
            end: s.end,
            value: s.value,
            rawValue: rawValue,
            isDelta: isDelta,
            dailyTotal: dailyTotal
        )
    }

    var sample: QuantitySample? {
        guard let kind = MetricKind(rawValue: kindRaw) else { return nil }
        return QuantitySample(kind: kind, start: start, end: end, value: value)
    }
}

@Model
final class StoredCursor {
    @Attribute(.unique) var kindRaw: String
    var last: Date

    init(kindRaw: String, last: Date) {
        self.kindRaw = kindRaw
        self.last = last
    }
}

/// Persisted nightly sleep summary (total asleep + estimated stage breakdown) so the
/// dashboard shows the last night OFFLINE, after the ring disconnects. Keyed by `night`
/// (start-of-day of the sleep window's start) and UPSERTED so re-syncing the same night
/// replaces rather than duplicates. Stage minutes are an on-device ESTIMATE — the ring
/// doesn't transmit stage labels (PROTOCOL.md §5.3).
///
/// Every non-optional attribute has a default so SwiftData lightweight migration can add
/// this table to stores written before it existed without trapping at launch (cf. #21).
@Model
final class StoredSleepSummary {
    @Attribute(.unique) var night: Date = Date.distantPast
    var asleepMin: Int = 0
    var deepMin: Int = 0
    var lightMin: Int = 0
    var remMin: Int = 0
    var awakeMin: Int = 0
    var efficiency: Double = 0
    /// IN-BED window clock times (first segment start … last segment end), NOT start-of-day — so a
    /// night-temp window aligns to real bedtime/get-up, not midnight. This is TIME IN BED: it
    /// includes the pre-sleep and post-wake awake-in-bed spans, so it is wider than the sleep window.
    var inBedStart: Date = Date.distantPast
    var inBedEnd: Date = Date.distantPast
    /// ACTUAL SLEEP window clock times: real onset (first asleep epoch) … final wake (last asleep
    /// epoch). Narrower than [inBedStart, inBedEnd] by the sleep latency + any lie-in. `distantPast`
    /// = not recorded (a legacy row written before these columns; the card falls back to the in-bed
    /// window). Defaulted so SwiftData lightweight migration adds them to older stores (cf. #21).
    var sleepOnset: Date = Date.distantPast
    var sleepWake: Date = Date.distantPast
    var updatedAt: Date = Date.distantPast

    // MARK: Wave-1 sleep analytics (#69/#70/#71). Every column is DEFAULTED so SwiftData
    // lightweight migration can add it to stores written before it existed (cf. #21). A 0
    // sentinel means "not computed" for the optional metrics (skin temp / scores), since a
    // worn night's skin temp is always > 28 °C and the scores are 1…100.

    /// Nightly MEAN sleeping skin temperature (°C), 0 = none. Baseline/offset are derived at
    /// display time from the trailing nights' `skinTempC` (#69) — only the nightly value is stored.
    var skinTempC: Double = 0
    /// Composite 0–100 Sleep Score (#70), 0 = not computed.
    var sleepScore: Int = 0
    /// Overnight stress score 1–100 from sleep-window RMSSD (#71), 0 = not computed.
    var stressScore: Int = 0
    /// Subjective "how did you sleep?" rating 1–9 (#70), 0 = unrated. Set by the user; NEVER
    /// overwritten by a re-sync.
    var feelScore: Int = 0
    /// Per-stage average HR (bpm), 0 = none (#70).
    var hrDeep: Int = 0
    var hrLight: Int = 0
    var hrRem: Int = 0
    var hrAwake: Int = 0
    /// Per-epoch (2.5-min) movement levels 0/1/2 across the night (#70) — small enough to
    /// persist so the movement chart redraws offline.
    var movementLevels: [Int] = []

    init(
        night: Date,
        asleepMin: Int = 0,
        deepMin: Int = 0,
        lightMin: Int = 0,
        remMin: Int = 0,
        awakeMin: Int = 0,
        efficiency: Double = 0,
        inBedStart: Date = Date.distantPast,
        inBedEnd: Date = Date.distantPast,
        sleepOnset: Date = Date.distantPast,
        sleepWake: Date = Date.distantPast,
        updatedAt: Date = Date(),
        skinTempC: Double = 0,
        sleepScore: Int = 0,
        stressScore: Int = 0,
        feelScore: Int = 0,
        hrDeep: Int = 0,
        hrLight: Int = 0,
        hrRem: Int = 0,
        hrAwake: Int = 0,
        movementLevels: [Int] = []
    ) {
        self.night = night
        self.asleepMin = asleepMin
        self.deepMin = deepMin
        self.lightMin = lightMin
        self.remMin = remMin
        self.awakeMin = awakeMin
        self.efficiency = efficiency
        self.inBedStart = inBedStart
        self.inBedEnd = inBedEnd
        self.sleepOnset = sleepOnset
        self.sleepWake = sleepWake
        self.updatedAt = updatedAt
        self.skinTempC = skinTempC
        self.sleepScore = sleepScore
        self.stressScore = stressScore
        self.feelScore = feelScore
        self.hrDeep = hrDeep
        self.hrLight = hrLight
        self.hrRem = hrRem
        self.hrAwake = hrAwake
        self.movementLevels = movementLevels
    }

    /// Rebuild a `SleepStaging.Summary` for the dashboard. `inBed` is recovered from the
    /// stored efficiency (asleep / efficiency) so the displayed % matches; the per-stage
    /// minutes round-trip exactly since they're already whole minutes.
    var asSummary: SleepStaging.Summary {
        let light = Double(lightMin) * 60
        let deep = Double(deepMin) * 60
        let rem = Double(remMin) * 60
        let awake = Double(awakeMin) * 60
        let asleep = light + deep + rem
        let inBed = efficiency > 0 ? asleep / efficiency : asleep + awake
        return SleepStaging.Summary(inBed: inBed, awake: awake, light: light, deep: deep, rem: rem)
    }
}

/// Per-day rollups for values that are NOT epoch samples and must NOT flow through the
/// cumulative-counter `ingest` path (which computes HealthKit deltas). Currently the
/// ring's onboard step count for the day. Keyed by `day` (start-of-day) and UPSERTED, so
/// the dashboard can show "steps today" offline without disturbing `SyncCursor` /
/// `cumulativeState` / Apple Health writes.
@Model
final class StoredDaily {
    @Attribute(.unique) var day: Date = Date.distantPast
    var steps: Int = 0
    var updatedAt: Date = Date.distantPast
    /// Running step total already written to Apple Health for this day. The next Health
    /// write pushes only `steps - healthWrittenSteps` as a stepCount sample, so HealthKit
    /// (which SUMS stepCount) lands on the daily total instead of overcounting on every
    /// sync. Defaulted for lightweight migration of stores written before this column.
    var healthWrittenSteps: Int = 0

    init(day: Date, steps: Int = 0, updatedAt: Date = Date(), healthWrittenSteps: Int = 0) {
        self.day = day
        self.steps = steps
        self.updatedAt = updatedAt
        self.healthWrittenSteps = healthWrittenSteps
    }
}

/// One auto-detected daytime nap (#76) — daytime stillness ≥ 15 min OUTSIDE the main overnight
/// sleep window. Kept separate from `StoredSleepSummary` so naps never double-count against the
/// night. Keyed by `start` and UPSERTED, so re-syncing the same day replaces rather than
/// duplicates. `healthWritten` gates the (separate) Apple Health sleep write so a nap is written
/// once. Every column is defaulted for SwiftData lightweight migration (cf. #21).
@Model
final class StoredNap {
    @Attribute(.unique) var start: Date = Date.distantPast
    var end: Date = Date.distantPast
    var asleepMin: Int = 0
    var isLongNap: Bool = false
    var healthWritten: Bool = false
    var updatedAt: Date = Date.distantPast

    init(start: Date, end: Date, asleepMin: Int = 0, isLongNap: Bool = false,
         healthWritten: Bool = false, updatedAt: Date = Date()) {
        self.start = start
        self.end = end
        self.asleepMin = asleepMin
        self.isLongNap = isLongNap
        self.healthWritten = healthWritten
        self.updatedAt = updatedAt
    }

    var durationMin: Int { max(Int(end.timeIntervalSince(start) / 60), 0) }
}

@MainActor
struct LocalStore {
    let context: ModelContext

    init(_ context: ModelContext) { self.context = context }

    /// The store-ingest cursor rows (live `@Model` objects, so mutating `.last` updates the
    /// context). Skips the `hk:`-prefixed HealthKit-watermark rows (see `pendingHealthSamples`)
    /// — they live in the same table but track a separate concern and must not pollute the
    /// store-ingest cursor.
    private func storeCursorRows() throws -> [StoredCursor] {
        try context.fetch(FetchDescriptor<StoredCursor>())
            .filter { !$0.kindRaw.hasPrefix(Self.healthCursorPrefix) }
    }

    /// Rebuild the in-memory SyncCursor from persisted rows.
    func loadCursor() throws -> SyncCursor {
        var map: [String: Date] = [:]
        for r in try storeCursorRows() { map[r.kindRaw] = r.last }
        return SyncCursor(lastByKind: map)
    }

    /// Persist new samples and advance the cursor in one step.
    ///
    /// Ordering matters (#22): the cursor advance is STAGED in memory and only the rows that
    /// actually moved are written, then samples + cursor commit together in a single
    /// `context.save()`. On a save failure we roll back, so the persisted cursor never moves
    /// ahead of un-stored samples — they're retried on the next ingest instead of being lost.
    func ingest(_ samples: [QuantitySample]) throws -> [QuantitySample] {
        // Fetch the cursor rows ONCE and reuse them for both the in-memory cursor and the
        // post-insert upsert — no per-`MetricKind` fetch loop (#33).
        let rows = try storeCursorRows()
        var rowByKind: [String: StoredCursor] = [:]
        for r in rows { rowByKind[r.kindRaw] = r }
        let cursor = SyncCursor(lastByKind: rowByKind.mapValues(\.last))

        // Stage the advance — don't touch the persisted cursor until the save commits (#22).
        let (fresh, advanced) = cursor.selectNewStaged(samples)
        guard !fresh.isEmpty else { return [] }

        var cumulativeStates: [MetricKind: CumulativeMetricState] = [:]
        var cumulativeStateDays: [MetricKind: Date] = [:]
        var ingested: [QuantitySample] = []

        for s in fresh {
            // Single ingest choke point for HR plausibility: drop heart-rate samples outside
            // LiveHR.validBPM (30…220), including 0-bpm placeholders. This protects EVERY store
            // consumer and the Apple Health mirror, present and future — covering paths the
            // sleep-vitals decoder guard doesn't (e.g. EpochSync value-0 placeholders). The cursor
            // still advances (computed above) so a skipped garbage sample isn't re-ingested.
            if s.kind == .heartRate, !LiveHR.validBPM.contains(Int(s.value)) { continue }

            guard s.kind.isCumulativeCounter else {
                context.insert(StoredSample(s))
                ingested.append(s)
                continue
            }

            // The daily total resets at midnight. `fresh` is sorted oldest→newest, so a
            // single batch can span a day boundary; when it does, carry the raw counter
            // forward (so the delta stays correct) but reset the running total to 0 for the
            // new day. The initial DB-backed state is already day-bounded by `cumulativeState`.
            let dayStart = Calendar.current.startOfDay(for: s.start)
            let state: CumulativeMetricState
            if let existing = cumulativeStates[s.kind] {
                state = cumulativeStateDays[s.kind] == dayStart
                    ? existing
                    : CumulativeMetricState(previousRawValue: existing.previousRawValue, dailyTotal: 0)
            } else {
                // First sample of this kind in the batch: the ONLY DB hit for cumulative state.
                // Subsequent samples of the same kind reuse the in-memory `cumulativeStates`
                // cache above, so no further per-sample lookups occur this ingest (#33).
                state = try cumulativeState(for: s.kind, before: s.start)
            }

            let result = CumulativeMetricAccumulator.accumulate(s, state: state)
            let deltaSample = QuantitySample(kind: s.kind, start: s.start, end: s.end, value: result.deltaValue)
            context.insert(StoredSample(
                deltaSample,
                rawValue: result.rawValue,
                isDelta: true,
                dailyTotal: result.dailyTotal
            ))
            cumulativeStates[s.kind] = CumulativeMetricState(
                previousRawValue: result.rawValue,
                dailyTotal: result.dailyTotal
            )
            cumulativeStateDays[s.kind] = dayStart
            // Return the per-epoch DELTA, not the running total: HealthKit *sums* cumulative
            // quantity types (stepCount / activeEnergyBurned), so writing the daily total on
            // every epoch would massively overcount. Deltas sum back to the daily total in Health.
            ingested.append(deltaSample)
        }
        // Persist ONLY the kinds whose cursor actually advanced, reusing the rows already
        // fetched above — no fetch-per-`MetricKind.allCases` loop (#33).
        for kind in advanced.advancedKinds(since: cursor) {
            guard let last = advanced.last(kind) else { continue }
            if let existing = rowByKind[kind.rawValue] {
                existing.last = last
            } else {
                context.insert(StoredCursor(kindRaw: kind.rawValue, last: last))
            }
        }
        do {
            // Samples + cursor advance commit atomically. On failure, roll back the staged
            // inserts and cursor moves so the next ingest re-stores the same samples (#22).
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        return ingested
    }

    // MARK: Retention (#32)
    //
    // Days of raw `StoredSample` history kept on-device. Older epochs are pruned — the data
    // already lives in Apple Health — while the rollup tables (`StoredSleepSummary` /
    // `StoredDaily`) are kept long-term so the offline dashboard still shows past nights/days.
    static let sampleRetentionDays = 30

    /// Delete raw samples older than the retention window; rollup tables are untouched. Meant to
    /// run occasionally (e.g. once at launch), NOT per write: with no column index a predicate
    /// delete scans `start`, so running it on every live sample would reintroduce the unbounded
    /// scan #32 is removing. The cumulative-counter day chain is unaffected (it only reaches back
    /// to the current day, far inside the window).
    func pruneExpiredSamples(olderThan days: Int = LocalStore.sampleRetentionDays,
                             now: Date = Date()) throws {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: now) ?? now
        try context.delete(model: StoredSample.self,
                           where: #Predicate { $0.start < cutoff })
        try context.save()
    }

    /// One-time cleanup: delete physiologically-impossible heart-rate samples — those outside
    /// `LiveHR.validBPM` (30…220 bpm), including 0-bpm placeholders — that were persisted BEFORE
    /// the decoder gained its band guard. A single garbage epoch (e.g. 4 bpm) otherwise surfaced
    /// as an impossible "Resting HR 4 bpm" and depressed the sleep score / per-stage HR / Health
    /// mirror across every consumer, not just one view. The decoder now blocks NEW out-of-band
    /// values at the source, so this only scrubs the existing rows once. Returns the number deleted.
    @discardableResult
    func purgeImplausibleHeartRate() throws -> Int {
        let hr = MetricKind.heartRate.rawValue
        let lo = Double(LiveHR.minValidBPM)
        let hi = Double(LiveHR.maxValidBPM)
        let descriptor = FetchDescriptor<StoredSample>(
            predicate: #Predicate { $0.kindRaw == hr && ($0.value < lo || $0.value > hi) })
        let stale = try context.fetch(descriptor)
        guard !stale.isEmpty else { return 0 }
        for row in stale { context.delete(row) }
        try context.save()
        return stale.count
    }

    /// Stored samples of one kind within `[start, end)`, oldest→newest. Used by the
    /// dashboard to average overnight skin-temperature samples (which only exist while the
    /// ring was connected) over a night window.
    func samples(kind: MetricKind, from start: Date, to end: Date) throws -> [QuantitySample] {
        let kindRaw = kind.rawValue
        let descriptor = FetchDescriptor<StoredSample>(
            predicate: #Predicate { $0.kindRaw == kindRaw && $0.start >= start && $0.start < end },
            sortBy: [SortDescriptor(\.start, order: .forward)]
        )
        return try context.fetch(descriptor).compactMap(\.sample)
    }

    /// Stored samples of one kind newer than `since`, oldest→newest. Bounded by the predicate so
    /// it never scans all history — used by the health-alert engine (#73/#85) to evaluate recent
    /// HR/SpO2 readings against the user's thresholds.
    func recentSamples(kind: MetricKind, since: Date) throws -> [QuantitySample] {
        let kindRaw = kind.rawValue
        let descriptor = FetchDescriptor<StoredSample>(
            predicate: #Predicate { $0.kindRaw == kindRaw && $0.start >= since && $0.value > 0 },
            sortBy: [SortDescriptor(\.start, order: .forward)])
        return try context.fetch(descriptor).compactMap(\.sample)
    }

    func latestSample(kind: MetricKind) throws -> QuantitySample? {
        let kindRaw = kind.rawValue
        var descriptor = FetchDescriptor<StoredSample>(
            predicate: #Predicate { $0.kindRaw == kindRaw },
            sortBy: [SortDescriptor(\.start, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first?.sample
    }

    // MARK: HealthKit write watermark (decoupled from the store-ingest cursor)
    //
    // The store-ingest cursor (`ingest`) dedupes ROWS in the local store so the dashboard
    // never double-counts a re-synced night. Apple Health needs its OWN high-water mark:
    // previously both shared one cursor, so the dashboard's auto-persist advanced it before
    // the Health write could claim the samples — HR/HRV/SpO2/respiratory/temperature were
    // persisted for the dashboard but NEVER reached Apple Health. This watermark reads from
    // the store (the single source of truth the auto-persist fills) and only advances after
    // a confirmed write, so an un-authorized or failed write safely backfills next time.

    /// Non-cumulative scalar metrics mirrored into Apple Health straight from the store.
    /// (Sleep uses `pendingHealthSleep`/`markSleepWritten`; cumulative step/energy counters
    /// take their own paths.)
    static let healthMirroredKinds: [MetricKind] = [.heartRate, .hrvSDNN, .spo2, .respiratoryRate, .temperature]
    private static let healthCursorPrefix = "hk:"

    /// Stored samples of the Health-mirrored kinds newer than the Health watermark,
    /// oldest→newest — everything synced to the store but not yet written to Apple Health.
    /// Does NOT advance the watermark (call `markHealthWritten` after a successful write).
    func pendingHealthSamples() throws -> [QuantitySample] {
        let cursor = try loadHealthCursor()
        var out: [QuantitySample] = []
        for kind in Self.healthMirroredKinds {
            let kindRaw = kind.rawValue
            let last = cursor.last(kind) ?? .distantPast
            let descriptor = FetchDescriptor<StoredSample>(
                predicate: #Predicate { $0.kindRaw == kindRaw && $0.start > last && $0.value > 0 },
                sortBy: [SortDescriptor(\.start, order: .forward)])
            out += try context.fetch(descriptor).compactMap(\.sample)
        }
        return out.sorted { $0.start < $1.start }
    }

    /// Sleep segments for a night not yet mirrored to Apple Health, gated on the `.sleep`
    /// cursor — WITHOUT advancing it (call `markSleepWritten` only after a confirmed write,
    /// so a failed save backfills next time instead of losing the night). Returns `[]` when
    /// this night is already in Health.
    func pendingHealthSleep(_ segments: [SleepSegment]) throws -> [SleepSegment] {
        guard let latest = segments.map(\.end).max() else { return [] }
        let cursor = try loadCursor()
        guard cursor.isNew(.sleep, latest) else { return [] }
        // A stitched multi-fragment night re-includes earlier fragments that an earlier drain may have
        // ALREADY mirrored to Health (the watermark sits inside this night). Write only segments that
        // extend past it — otherwise the morning sync re-writes the earlier fragment, duplicating /
        // overlapping sleep samples (HealthKit doesn't dedup). With the cursor before the night (the
        // common case) every segment passes, so a whole night still lands. (Adversarial review.)
        if let last = cursor.last(.sleep) { return segments.filter { $0.end > last } }
        return segments
    }

    /// Advance the `.sleep` cursor past the night just written to Apple Health.
    func markSleepWritten(_ segments: [SleepSegment]) throws {
        guard let latest = segments.map(\.end).max() else { return }
        var cursor = try loadCursor()
        guard cursor.isNew(.sleep, latest) else { return }
        cursor.advance(.sleep, to: latest)
        if let last = cursor.last(.sleep) {
            upsertCursor(kind: MetricKind.sleep.rawValue, last: last)
        }
        try context.save()
    }

    /// Advance the Health watermark past the newest written sample per kind.
    func markHealthWritten(_ samples: [QuantitySample]) throws {
        guard !samples.isEmpty else { return }
        var cursor = try loadHealthCursor()
        _ = cursor.selectNew(samples)   // advances per kind to the newest start
        for kind in Self.healthMirroredKinds {
            guard let last = cursor.last(kind) else { continue }
            upsertCursor(kind: Self.healthCursorPrefix + kind.rawValue, last: last)
        }
        try context.save()
    }

    /// Health watermark, read from the `hk:`-prefixed cursor rows (keyed by bare kind).
    private func loadHealthCursor() throws -> SyncCursor {
        let rows = try context.fetch(FetchDescriptor<StoredCursor>())
        var map: [String: Date] = [:]
        for r in rows where r.kindRaw.hasPrefix(Self.healthCursorPrefix) {
            map[String(r.kindRaw.dropFirst(Self.healthCursorPrefix.count))] = r.last
        }
        return SyncCursor(lastByKind: map)
    }

    // MARK: Sleep summary + daily steps (offline dashboard, separate from `ingest`)

    /// Upsert the nightly sleep summary, keyed by start-of-day of `night`. Re-syncing the
    /// same night overwrites the existing row rather than inserting a duplicate. Does NOT
    /// touch the SyncCursor — gating sleep history for HealthKit stays in the `.sleep`
    /// watermark (`pendingHealthSleep`/`markSleepWritten`).
    /// The Wave-1 analytics computed for a night alongside the stage totals (#69/#70/#71). All
    /// optional — a value left at its default means "not computed" and the upsert leaves any
    /// existing value untouched isn't needed (these are recomputed each sync), but `feelScore`
    /// IS preserved across re-syncs since it's user-entered, not derived.
    struct SleepNightExtras {
        var skinTempC: Double = 0
        var sleepScore: Int = 0
        var stressScore: Int = 0
        var hrByStage: [SleepStage: Int] = [:]
        var movementLevels: [Int] = []
    }

    func saveSleepSummary(_ summary: SleepStaging.Summary, night: Date,
                          inBedStart: Date, inBedEnd: Date,
                          sleepOnset: Date = .distantPast, sleepWake: Date = .distantPast,
                          extras: SleepNightExtras = SleepNightExtras()) throws {
        let dayStart = Calendar.current.startOfDay(for: night)
        let m = summary.minutes
        let descriptor = FetchDescriptor<StoredSleepSummary>(
            predicate: #Predicate { $0.night == dayStart })
        if let existing = try? context.fetch(descriptor).first {
            // Non-destructive upsert. A night can be drained in MORE THAN ONE piece (e.g. a
            // background drain mid-night, then the foreground morning sync) — the ring hands off
            // un-delivered history incrementally, so each drain stages only its own slice. Blindly
            // overwriting let a later, SHORTER slice clobber a fuller capture already stored for this
            // date (a 4 h fragment replacing a full night). Replace only when the new staging is at
            // least as complete (wider in-bed span); otherwise keep the fuller stored night untouched.
            // Non-regressive vs. blind overwrite; truly stitching two disjoint partials into one night
            // (and the periodic overnight draining that needs it) is a follow-up that requires
            // per-epoch persistence. See OpenCircuitKit/SleepSummaryMerge.
            let storedSpan = existing.inBedEnd > existing.inBedStart
                ? existing.inBedEnd.timeIntervalSince(existing.inBedStart) : 0
            let newSpan = inBedEnd > inBedStart ? inBedEnd.timeIntervalSince(inBedStart) : 0
            // Completeness is judged on time ASLEEP (span is a fallback): a later, shorter slice — or a
            // wide window padded with awake — can't shrink a fuller night. See SleepSummaryMerge.
            guard SleepSummaryMerge.shouldReplace(
                storedInBed: storedSpan, newInBed: newSpan,
                storedAsleep: TimeInterval(existing.asleepMin) * 60,
                newAsleep: TimeInterval(m.asleep) * 60) else {
                return   // keep the fuller existing night (its window, stages, extras + feelScore)
            }
            existing.asleepMin = m.asleep
            existing.deepMin = m.deep
            existing.lightMin = m.light
            existing.remMin = m.rem
            existing.awakeMin = m.awake
            existing.efficiency = summary.efficiency
            existing.inBedStart = inBedStart
            existing.inBedEnd = inBedEnd
            existing.sleepOnset = sleepOnset
            existing.sleepWake = sleepWake
            existing.updatedAt = Date()
            applyExtras(extras, to: existing)   // feelScore deliberately preserved
        } else {
            let row = StoredSleepSummary(
                night: dayStart,
                asleepMin: m.asleep,
                deepMin: m.deep,
                lightMin: m.light,
                remMin: m.rem,
                awakeMin: m.awake,
                efficiency: summary.efficiency,
                inBedStart: inBedStart,
                inBedEnd: inBedEnd,
                sleepOnset: sleepOnset,
                sleepWake: sleepWake
            )
            applyExtras(extras, to: row)
            context.insert(row)
        }
        try context.save()
    }

    private func applyExtras(_ extras: SleepNightExtras, to row: StoredSleepSummary) {
        // 0 = "not computed this pass" — keep any previously stored value rather than wiping it
        // (a quick daytime live-read might re-stage the night with no temp/HRV coverage).
        if extras.skinTempC > 0 { row.skinTempC = extras.skinTempC }
        if extras.sleepScore > 0 { row.sleepScore = extras.sleepScore }
        if extras.stressScore > 0 { row.stressScore = extras.stressScore }
        if let v = extras.hrByStage[.asleepDeep] { row.hrDeep = v }
        if let v = extras.hrByStage[.asleepCore] { row.hrLight = v }
        if let v = extras.hrByStage[.asleepREM] { row.hrRem = v }
        if let v = extras.hrByStage[.awake] { row.hrAwake = v }
        if !extras.movementLevels.isEmpty { row.movementLevels = extras.movementLevels }
    }

    /// Most recent stored sleep summary (latest night), or nil.
    func latestSleepSummary() throws -> StoredSleepSummary? {
        var descriptor = FetchDescriptor<StoredSleepSummary>(
            sortBy: [SortDescriptor(\.night, order: .reverse)])
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// Trailing sleep summaries (latest first), for the rolling skin-temp baseline (#69) and
    /// any short-window trend. Bounded so it never scans the whole table.
    func recentSleepSummaries(limit: Int = 40) throws -> [StoredSleepSummary] {
        var descriptor = FetchDescriptor<StoredSleepSummary>(
            sortBy: [SortDescriptor(\.night, order: .reverse)])
        descriptor.fetchLimit = limit
        return try context.fetch(descriptor)
    }

    /// Persist the user's subjective sleep rating (1–9, #70) onto an existing night. No-op if
    /// the night isn't in the store yet (a rating only makes sense once a night exists).
    func setFeelScore(_ score: Int, night: Date) throws {
        let dayStart = Calendar.current.startOfDay(for: night)
        let descriptor = FetchDescriptor<StoredSleepSummary>(
            predicate: #Predicate { $0.night == dayStart })
        guard let row = try? context.fetch(descriptor).first else { return }
        row.feelScore = max(0, min(score, 9))
        row.updatedAt = Date()
        try context.save()
    }

    // MARK: Naps (#76) — separate from the night so they never double-count

    /// Upsert one auto-detected nap, keyed by start. A re-detected nap with the same start
    /// updates in place; a genuinely new nap inserts. Preserves `healthWritten` on update so a
    /// nap already mirrored to Health isn't re-written.
    func saveNap(start: Date, end: Date, asleepMin: Int, isLongNap: Bool) throws {
        let descriptor = FetchDescriptor<StoredNap>(predicate: #Predicate { $0.start == start })
        if let existing = try? context.fetch(descriptor).first {
            existing.end = end
            existing.asleepMin = asleepMin
            existing.isLongNap = isLongNap
            existing.updatedAt = Date()
        } else {
            context.insert(StoredNap(start: start, end: end, asleepMin: asleepMin, isLongNap: isLongNap))
        }
        try context.save()
    }

    /// Naps that started on `day` (start-of-day bucket), latest first.
    func naps(on day: Date = Date()) throws -> [StoredNap] {
        let dayStart = Calendar.current.startOfDay(for: day)
        let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let descriptor = FetchDescriptor<StoredNap>(
            predicate: #Predicate { $0.start >= dayStart && $0.start < dayEnd },
            sortBy: [SortDescriptor(\.start, order: .reverse)])
        return try context.fetch(descriptor)
    }

    /// Naps not yet mirrored to Apple Health (oldest first), for `HealthKitWriter.flushNaps`.
    func pendingNaps() throws -> [StoredNap] {
        let descriptor = FetchDescriptor<StoredNap>(
            predicate: #Predicate { $0.healthWritten == false },
            sortBy: [SortDescriptor(\.start, order: .forward)])
        return try context.fetch(descriptor)
    }

    /// Mark a nap written to Apple Health so it isn't written again.
    func markNapWritten(start: Date) throws {
        let descriptor = FetchDescriptor<StoredNap>(predicate: #Predicate { $0.start == start })
        guard let row = try? context.fetch(descriptor).first else { return }
        row.healthWritten = true
        try context.save()
    }

    /// Accumulate a step DELTA into the running total for `day`, UPSERTED by start-of-day. The
    /// ring's onboard counter is a since-handoff delta that RESETS (the official app sums the
    /// deltas in local memory), so we sum observed deltas the same way rather than storing the
    /// raw counter — `StepAccumulator` (#34) computes the reset-aware delta. New day = new row.
    /// `day` is the SAMPLE time of the reading (when the descriptor arrived), so a delta observed
    /// just after midnight for late-night steps is stamped onto its own day, not the prior one.
    func addDailySteps(_ delta: Int, day: Date = Date()) throws {
        guard delta > 0 else { return }
        let dayStart = Calendar.current.startOfDay(for: day)
        let descriptor = FetchDescriptor<StoredDaily>(predicate: #Predicate { $0.day == dayStart })
        if let existing = try? context.fetch(descriptor).first {
            existing.steps += delta
            existing.updatedAt = Date()
        } else {
            context.insert(StoredDaily(day: dayStart, steps: delta))
        }
        try context.save()
    }

    /// Today's accumulated step total (0 if none yet).
    func todaySteps(day: Date = Date()) throws -> Int {
        let dayStart = Calendar.current.startOfDay(for: day)
        let descriptor = FetchDescriptor<StoredDaily>(predicate: #Predicate { $0.day == dayStart })
        return (try? context.fetch(descriptor).first)?.steps ?? 0
    }

    /// Steps accumulated today but not yet written to Apple Health (0 if none/caught up).
    /// Pairs with `advanceStepsWritten` so the day's stepCount reaches Health as deltas that
    /// sum to the daily total, never the full total re-added on every sync.
    func pendingStepDelta(day: Date = Date()) throws -> Int {
        let dayStart = Calendar.current.startOfDay(for: day)
        let descriptor = FetchDescriptor<StoredDaily>(predicate: #Predicate { $0.day == dayStart })
        guard let row = try? context.fetch(descriptor).first else { return 0 }
        return max(row.steps - row.healthWrittenSteps, 0)
    }

    /// Record that `delta` more of today's steps are now reflected in Apple Health. Advancing
    /// by the delta just written (rather than to an external total) keeps the watermark exactly
    /// in step with what was pushed, so the next `pendingStepDelta` is correct.
    func advanceStepsWritten(by delta: Int, day: Date = Date()) throws {
        guard delta > 0 else { return }
        let dayStart = Calendar.current.startOfDay(for: day)
        let descriptor = FetchDescriptor<StoredDaily>(predicate: #Predicate { $0.day == dayStart })
        guard let row = try? context.fetch(descriptor).first else { return }
        row.healthWrittenSteps = min(row.healthWrittenSteps + delta, row.steps)
        try context.save()
    }

    /// Most recent stored daily rollup (latest day), or nil.
    func latestDaily() throws -> StoredDaily? {
        var descriptor = FetchDescriptor<StoredDaily>(
            sortBy: [SortDescriptor(\.day, order: .reverse)])
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// Trailing daily rollups (latest first), bounded by `limit`. Used by TrendsView (#74) to
    /// build 7-day rolling aggregates for steps. Bounded so it never scans the whole table.
    func recentDailies(limit: Int = 14) throws -> [StoredDaily] {
        var descriptor = FetchDescriptor<StoredDaily>(
            sortBy: [SortDescriptor(\.day, order: .reverse)])
        descriptor.fetchLimit = limit
        return try context.fetch(descriptor)
    }

    private func upsertCursor(kind: String, last: Date) {
        let descriptor = FetchDescriptor<StoredCursor>(
            predicate: #Predicate { $0.kindRaw == kind })
        if let existing = try? context.fetch(descriptor).first {
            existing.last = last
        } else {
            context.insert(StoredCursor(kindRaw: kind, last: last))
        }
    }

    private func cumulativeState(for kind: MetricKind, before date: Date) throws -> CumulativeMetricState {
        let kindRaw = kind.rawValue
        var previousDescriptor = FetchDescriptor<StoredSample>(
            predicate: #Predicate { $0.kindRaw == kindRaw && $0.start < date },
            sortBy: [SortDescriptor(\.start, order: .reverse)]
        )
        previousDescriptor.fetchLimit = 1
        let previous = try context.fetch(previousDescriptor).first
        let previousRaw = previous.map { $0.rawValue ?? $0.value }

        let dayInterval = Calendar.current.dateInterval(of: .day, for: date)
        let dayStart = dayInterval?.start ?? date
        let nextDay = dayInterval?.end ?? date
        var dayDescriptor = FetchDescriptor<StoredSample>(
            predicate: #Predicate {
                $0.kindRaw == kindRaw && $0.start >= dayStart && $0.start < nextDay && $0.start < date
            },
            sortBy: [SortDescriptor(\.start, order: .reverse)]
        )
        dayDescriptor.fetchLimit = 1

        if let latestToday = try context.fetch(dayDescriptor).first {
            if let dailyTotal = latestToday.dailyTotal {
                return CumulativeMetricState(previousRawValue: previousRaw, dailyTotal: dailyTotal)
            }
            if !latestToday.isDelta {
                return CumulativeMetricState(
                    previousRawValue: previousRaw,
                    dailyTotal: latestToday.rawValue ?? latestToday.value
                )
            }
        }

        return CumulativeMetricState(previousRawValue: previousRaw)
    }
}

struct LaunchSnapshot {
    let lastHeartRate: QuantitySample?

    @MainActor
    static func load(from store: LocalStore) throws -> LaunchSnapshot {
        LaunchSnapshot(lastHeartRate: try store.latestSample(kind: .heartRate))
    }
}

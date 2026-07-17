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

    // MARK: OSA sleep-apnea SpO₂ (#91) — decoded locally from the dense `0x48` assessment burst.
    // Every column DEFAULTED for SwiftData lightweight migration (cf. #21). `osaValidWindows == 0`
    // = no assessment drained that night (the card row stays hidden). `osaAvgSpO2` is validated
    // (±1 % vs the RingConn app); `osaMinSpO2`/`osaTimeBelow90Sec`/`osaODI` are ESTIMATES — the UI
    // labels them EXPERIMENTAL. Set post-construction via `LocalStore.applyOSASummary` (the burst
    // finalizes ~5 s after the sleep drain), so they are NOT init parameters.
    var osaAvgSpO2: Double = 0
    var osaMinSpO2: Double = 0
    var osaTimeBelow90Sec: Double = 0
    var osaODI: Double = 0
    var osaValidWindows: Int = 0

    // MARK: Manual sleep-time edit overlay (#176) — RingConn parity (EditSleepStagePage /
    // SleepEditableTimeRange). DEFAULTED for SwiftData lightweight migration (cf. #21). `distantPast`
    // = not edited. When set, this night's display window + durations were recomputed for the user's
    // edited [editedInBedStart, editedInBedEnd] (within ±3 h of the recorded onset/wake), and a
    // re-sync must NOT overwrite them — the raw epoch archive still holds the original staging, so the
    // edit is a non-destructive overlay. Set via `LocalStore.applySleepEdit`.
    var editedInBedStart: Date = Date.distantPast
    var editedInBedEnd: Date = Date.distantPast
    /// Persisted (rather than inferred from the dates) so an unchanged Save can never accidentally
    /// turn a recorded night into a manual edit, and so lightweight migration has an explicit flag.
    var isManuallyEdited: Bool = false

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

    var sleepEditRecordedInBedStart: Date {
        inBedStart
    }
    var sleepEditRecordedInBedEnd: Date {
        inBedEnd
    }
    var sleepEditRecordedOnset: Date {
        sleepOnset
    }
    var sleepEditRecordedWake: Date {
        sleepWake
    }

    var sleepEditCurrentInBedStart: Date {
        isManuallyEdited ? editedInBedStart : inBedStart
    }
    var sleepEditCurrentInBedEnd: Date {
        isManuallyEdited ? editedInBedEnd : inBedEnd
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
    /// SUPERSEDED as the Health-write gate by `StoredStepSample.healthWritten` (#steps-history)
    /// — Health now receives each timestamped snapshot individually rather than one per-day
    /// delta off this watermark. Kept (frozen, no longer written) only so existing stores don't
    /// need a destructive migration; safe to ignore when reasoning about what's in Health.
    var healthWrittenSteps: Int = 0

    init(day: Date, steps: Int = 0, updatedAt: Date = Date(), healthWrittenSteps: Int = 0) {
        self.day = day
        self.steps = steps
        self.updatedAt = updatedAt
        self.healthWrittenSteps = healthWrittenSteps
    }
}

/// One timestamped step DELTA as actually observed off the ring's `0x10/0x87` descriptor
/// counter (#steps-history). Unlike `StoredDaily` (a single running per-day total with no
/// timing info), `start`/`end` bound the window this delta was folded over, so:
///   - Apple Health receives a narrow, correctly-timed `stepCount` sample instead of one
///     `startOfDay→now` write that HealthKit's hourly view would smear evenly across every
///     elapsed hour of the day.
///   - A Trends/table view can show the actual intraday step shape, not just a daily total.
/// Append-only, no unique key — many rows per day are expected.
@Model
final class StoredStepSample {
    var start: Date = Date.distantPast
    var end: Date = Date.distantPast
    var delta: Int = 0
    var healthWritten: Bool = false

    init(start: Date, end: Date, delta: Int, healthWritten: Bool = false) {
        self.start = start
        self.end = end
        self.delta = delta
        self.healthWritten = healthWritten
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
    // Manual nap edit/add overlay (RingConn `SleepNapModel.isEdited` parity). DEFAULTED for SwiftData
    // lightweight migration (cf. #21). A manual nap (edited window or user-added) is PRESERVED across
    // auto re-detection — see `saveNap`. `isManuallyAdded` marks a nap the ring never detected.
    var isManuallyEdited: Bool = false
    var isManuallyAdded: Bool = false
    /// Encoded staged `[SleepSegment]` hypnogram for the Apple Health write (Deep/Light/REM — RingConn
    /// `sleepPhases` parity). nil = coarse, and `flushNaps` then writes a plain inBed+asleepCore pair.
    var napSegmentsData: Data? = nil
    /// Edit overlay (#nap-parity): the user-adjusted window. The unique `start` KEY is kept STABLE on
    /// edit so auto re-detection updates the SAME row (no duplicate at the old start); display + Health
    /// use the effective window below. nil = unedited.
    var editedStart: Date? = nil
    var editedEnd: Date? = nil

    init(start: Date, end: Date, asleepMin: Int = 0, isLongNap: Bool = false,
         healthWritten: Bool = false, updatedAt: Date = Date()) {
        self.start = start
        self.end = end
        self.asleepMin = asleepMin
        self.isLongNap = isLongNap
        self.healthWritten = healthWritten
        self.updatedAt = updatedAt
    }

    /// The window actually shown + written to Health — the manual edit if present, else the detected
    /// window. `start` stays the stable dedup key; everything user-facing uses these.
    var effectiveStart: Date { editedStart ?? start }
    var effectiveEnd: Date { editedEnd ?? end }
    var durationMin: Int { max(Int(effectiveEnd.timeIntervalSince(effectiveStart) / 60), 0) }

    /// The staged per-nap hypnogram (decoded from `napSegmentsData`), or nil when the nap is coarse.
    var stagedSegments: [SleepSegment]? {
        get { napSegmentsData.flatMap { try? JSONDecoder().decode([SleepSegment].self, from: $0) } }
        set { napSegmentsData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }
}

/// A DAYTIME skin-temp reading, kept entirely separate from the nightly `StoredSleepSummary
/// .skinTempC` baseline and from Apple Health (#41 deliberately blocks daytime readings from
/// that path — mixing them in would skew the nightly cycle-tracking baseline and mis-report a
/// daytime spot reading as the night's value). This table exists purely so the Trends UI can
/// show a true intraday temperature line; it is re-derivable from the ring's live descriptor
/// stream (not backed up before a schema-wipe, like `StoredSample`) and pruned on the same
/// retention window. Every column is defaulted for SwiftData lightweight migration (cf. #21).
@Model
final class StoredDaytimeTemp {
    var time: Date = Date.distantPast
    var celsius: Double = 0

    init(time: Date, celsius: Double) {
        self.time = time
        self.celsius = celsius
    }
}

@MainActor
struct LocalStore {
    let context: ModelContext

    init(_ context: ModelContext) { self.context = context }

    struct IngestPreview: Equatable {
        var inputCount = 0
        var plausibleCount = 0
        var freshCount = 0
        var duplicateCount = 0
        var invalidTimestampCount = 0
        var invalidHeartRateCount = 0
    }

    /// The store-ingest cursor rows (live `@Model` objects, so mutating `.last` updates the
    /// context). Skips the `hk:`-prefixed HealthKit-watermark rows (see `pendingHealthSamples`)
    /// — they live in the same table but track a separate concern and must not pollute the
    /// store-ingest cursor.
    private func storeCursorRows() throws -> [StoredCursor] {
        try context.fetch(FetchDescriptor<StoredCursor>())
            .filter { !$0.kindRaw.hasPrefix(Self.healthCursorPrefix) }
    }

    /// Dry-run of `ingest(_:)` for logging/observability. Lets the caller tell whether a captured
    /// sample would be rejected as implausible or duplicate before the real write runs.
    func previewIngest(_ samples: [QuantitySample], now: Date = Date()) throws -> IngestPreview {
        let rows = try storeCursorRows()
        let cursor = SyncCursor(lastByKind: Dictionary(uniqueKeysWithValues: rows.map { ($0.kindRaw, $0.last) }))

        var preview = IngestPreview()
        preview.inputCount = samples.count
        var plausible: [QuantitySample] = []
        plausible.reserveCapacity(samples.count)

        let epochFloor = Date(timeIntervalSince1970: TimeInterval(Command.syncEpoch))
        let futureCeiling = now.addingTimeInterval(86_400)
        for s in samples {
            if s.start < epochFloor || s.start > futureCeiling {
                preview.invalidTimestampCount += 1
                continue
            }
            if s.kind == .heartRate, !LiveHR.validBPM.contains(Int(s.value)) {
                preview.invalidHeartRateCount += 1
                continue
            }
            plausible.append(s)
        }

        preview.plausibleCount = plausible.count
        preview.freshCount = cursor.selectNewStaged(plausible).fresh.count
        preview.duplicateCount = max(preview.plausibleCount - preview.freshCount, 0)
        return preview
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

        // Plausibility BEFORE the cursor ever sees these samples. A SyncCursor only moves
        // FORWARD (never resets), so a single corrupted-timestamp sample (e.g. a misaligned
        // bulk-page parse computing a date decades off) or an out-of-band HR value advancing a
        // kind's watermark would silently block every later LEGITIMATE sample of that kind
        // forever — exactly what happened to `.heartRate` (and, transitively, sleep staging,
        // which can't run without HR). Filtering here, before `selectNewStaged`, means a sample
        // that's about to be discarded can never poison the watermark in the first place. (See
        // `repairFutureSyncCursors` for undoing damage from before this reordering existed.)
        let plausible = samples.filter { Self.isPlausible($0) }

        // Stage the advance — don't touch the persisted cursor until the save commits (#22).
        let (fresh, advanced) = cursor.selectNewStaged(plausible)
        guard !fresh.isEmpty else { return [] }

        var cumulativeStates: [MetricKind: CumulativeMetricState] = [:]
        var cumulativeStateDays: [MetricKind: Date] = [:]
        var ingested: [QuantitySample] = []

        for s in fresh {
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

    /// Single ingest choke point for sample plausibility, checked BEFORE the SyncCursor — see the
    /// ordering note in `ingest`. Two independent gates:
    /// - TIMESTAMP: reject any sample whose `start` predates the ring's own counter epoch
    ///   (2019-12-31 — nothing real can be older) or sits implausibly far in the future
    ///   (clock-skew tolerance). Catches a corrupted epoch-counter decode that would otherwise
    ///   surface as something like "13y ago" — or, worse, decades in the FUTURE.
    /// - HEART RATE: reject values outside `LiveHR.validBPM` (30…220), including 0-bpm
    ///   placeholders — covers paths the sleep-vitals decoder guard doesn't (e.g. EpochSync
    ///   value-0 placeholders).
    private static func isPlausible(_ s: QuantitySample, now: Date = Date()) -> Bool {
        let epochFloor = Date(timeIntervalSince1970: TimeInterval(Command.syncEpoch))
        guard s.start >= epochFloor, s.start <= now.addingTimeInterval(86_400) else { return false }
        if s.kind == .heartRate, !LiveHR.validBPM.contains(Int(s.value)) { return false }
        return true
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
        try context.delete(model: StoredDaytimeTemp.self,
                           where: #Predicate { $0.time < cutoff })
        try context.delete(model: StoredStepSample.self,
                           where: #Predicate { $0.start < cutoff })
        try context.save()
    }

    /// Record one DAYTIME skin-temp reading (Trends-only — see `StoredDaytimeTemp`). Plain
    /// insert, no upsert: readings are frequent and timestamped, so duplicates aren't a
    /// dedup concern the way a single nightly summary row is.
    func recordDaytimeTemperature(_ celsius: Double, at time: Date) throws {
        context.insert(StoredDaytimeTemp(time: time, celsius: celsius))
        try context.save()
    }

    /// Daytime skin-temp readings in `[start, end)`, oldest first.
    func daytimeTemperatures(from start: Date, to end: Date) throws -> [StoredDaytimeTemp] {
        let descriptor = FetchDescriptor<StoredDaytimeTemp>(
            predicate: #Predicate { $0.time >= start && $0.time < end },
            sortBy: [SortDescriptor(\.time)]
        )
        return try context.fetch(descriptor)
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

    /// One-time scrub for samples with an implausible TIMESTAMP, predating the `ingest` epoch
    /// guard added alongside it. A single misaligned bulk-page parse can mint a sample dated years
    /// off (e.g. before the ring's own counter epoch), which then surfaces as something like "13y
    /// ago" in any relative-time caption that reads it — every consumer, not just one view. New
    /// out-of-band timestamps are now blocked at `ingest`'s source; this only scrubs existing rows
    /// once. Returns the number deleted.
    @discardableResult
    func purgeImplausibleTimestamps() throws -> Int {
        let epochFloor = Date(timeIntervalSince1970: TimeInterval(Command.syncEpoch))
        let futureCeiling = Date().addingTimeInterval(86_400)
        let descriptor = FetchDescriptor<StoredSample>(
            predicate: #Predicate { $0.start < epochFloor || $0.start > futureCeiling })
        let stale = try context.fetch(descriptor)
        guard !stale.isEmpty else { return 0 }
        for row in stale { context.delete(row) }
        try context.save()
        return stale.count
    }

    /// Repair for a `SyncCursor` watermark stuck in the far future — the lasting damage from a
    /// corrupted-timestamp sample that advanced a kind's cursor BEFORE `ingest` checked
    /// plausibility ahead of the cursor (see the ordering note there). A cursor only moves
    /// FORWARD, so once poisoned it silently blocks every later legitimate sample of that kind —
    /// `purgeImplausibleTimestamps` cleans the bad SAMPLE rows but never touches the cursor itself,
    /// so without this the block persists even after the source bug is fixed.
    ///
    /// Covers BOTH cursor families sharing this table: the plain ingest cursor (`heartRate`) and
    /// the `hk:`-prefixed HealthKit-mirror cursor (`hk:heartRate`) — a poisoned mirror cursor would
    /// keep new, valid LOCAL samples from ever reaching Apple Health even after the ingest side is
    /// fixed. Each poisoned row is reset to the latest ALREADY-STORED plausible sample of its bare
    /// kind, or removed entirely when none exists, so the next ingest/flush re-admits the backlog
    /// instead of staying stuck forever.
    ///
    /// Deliberately run on EVERY launch (not gated to once) rather than a one-time scrub like the
    /// sample purges above: it's a handful of cursor rows (cheap to re-check), and a single
    /// one-time pass turned out NOT to be reliably sufficient — `hk:heartRate` was still observed
    /// stuck after the first run (cause unconfirmed; likely launch-task ordering against the other
    /// one-time scrubs). Re-running it every launch is a self-healing no-op once nothing's stuck,
    /// and guarantees this can't silently stay broken from one bad run. Returns the number of rows
    /// repaired (logged by the caller).
    @discardableResult
    func repairFutureSyncCursors(now: Date = Date()) throws -> Int {
        let ceiling = now.addingTimeInterval(86_400)
        let rows = try context.fetch(FetchDescriptor<StoredCursor>())
        let stuck = rows.filter { $0.last > ceiling }
        guard !stuck.isEmpty else { return 0 }
        // Capture kind names BEFORE any `context.delete` below — reading a property off a
        // deleted-but-unsaved SwiftData model is unreliable, so the log message must not touch
        // `stuck` again after the mutation loop.
        let stuckKinds = stuck.map(\.kindRaw)

        for row in stuck {
            let bareKind = row.kindRaw.hasPrefix(Self.healthCursorPrefix)
                ? String(row.kindRaw.dropFirst(Self.healthCursorPrefix.count))
                : row.kindRaw
            var latestDescriptor = FetchDescriptor<StoredSample>(
                predicate: #Predicate { $0.kindRaw == bareKind && $0.start <= now },
                sortBy: [SortDescriptor(\.start, order: .reverse)]
            )
            latestDescriptor.fetchLimit = 1
            if let latest = try context.fetch(latestDescriptor).first {
                row.last = latest.start
            } else {
                context.delete(row)
            }
        }
        try context.save()
        ringLog.notice("cursor repair: reset \(stuckKinds.count) stuck row(s): \(stuckKinds.joined(separator: ", "), privacy: .public)")
        return stuckKinds.count
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
        if let last = cursor.last(.sleep) {
            // Clip a segment that crosses the watermark instead of re-writing its already-saved
            // prefix. This matters for a re-edited wake extension: 08:00→10:00 presented after a
            // prior 08:00→09:00 extension must append only 09:00→10:00, not duplicate an hour.
            return segments.compactMap { segment in
                let start = max(segment.start, last)
                return segment.end > start
                    ? SleepSegment(start: start, end: segment.end, stage: segment.stage)
                    : nil
            }
        }
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
            // A manually edited night (#176) is authoritative: a later re-sync must not overwrite the
            // user's window/durations. Preserve it. The raw epoch archive still holds the original
            // staging, so the edit stays reversible by re-editing.
            if existing.isManuallyEdited { return }
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
            // A classifier refinement can legitimately turn formerly-asleep quiet wake into
            // awake-in-bed while using the exact same archived coverage. Treat matching boundaries
            // (within one ring epoch) as a reclassification, not as a thinner fragment; otherwise the
            // old, larger asleep total would be merge-protected forever after an onset fix ships.
            let epochTolerance = TimeInterval(BulkRecord.epochSeconds)
            let sameCoverage = storedSpan > 0 && newSpan > 0
                && abs(existing.inBedStart.timeIntervalSince(inBedStart)) <= epochTolerance
                && abs(existing.inBedEnd.timeIntervalSince(inBedEnd)) <= epochTolerance
            // Completeness is judged on time ASLEEP (span is a fallback): a later, shorter slice — or a
            // wide window padded with awake — can't shrink a fuller night. See SleepSummaryMerge.
            guard SleepSummaryMerge.shouldReplace(
                storedInBed: storedSpan, newInBed: newSpan,
                storedAsleep: TimeInterval(existing.asleepMin) * 60,
                newAsleep: TimeInterval(m.asleep) * 60,
                sameCoverage: sameCoverage) else {
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

    /// Attach a decoded OSA SpO₂ summary (#91) to the most recent night's stored summary. The
    /// `0x48` assessment burst finalizes ~5 s AFTER the `0x4c` sleep drain, so the night's row
    /// already exists — we update it in place rather than routing through `saveSleepSummary`.
    /// No-op if the summary has no valid windows or there's no stored night yet. Returns whether it
    /// was applied. `updatedAt` is bumped so the `@Query`-backed card refreshes.
    @discardableResult
    func applyOSASummary(_ osa: OSASpO2.NightSummary) -> Bool {
        guard osa.validWindows > 0, let row = try? latestSleepSummary() else { return false }
        row.osaAvgSpO2 = osa.averageSpO2
        row.osaMinSpO2 = osa.minSpO2
        row.osaTimeBelow90Sec = osa.timeBelow90Seconds
        row.osaODI = osa.odi
        row.osaValidWindows = osa.validWindows
        row.updatedAt = Date()
        try? context.save()
        return true
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

    /// Sleep summaries whose `night` bucket falls within `[from, to)`, oldest first.
    func sleepSummaries(from: Date, to: Date) throws -> [StoredSleepSummary] {
        let descriptor = FetchDescriptor<StoredSleepSummary>(
            predicate: #Predicate { $0.night >= from && $0.night < to },
            sortBy: [SortDescriptor(\.night, order: .forward)])
        return try context.fetch(descriptor)
    }

    func sleepSummary(night: Date) throws -> StoredSleepSummary? {
        let dayStart = Calendar.current.startOfDay(for: night)
        let descriptor = FetchDescriptor<StoredSleepSummary>(
            predicate: #Predicate { $0.night == dayStart })
        return try context.fetch(descriptor).first
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

    /// Apply a manual sleep-time edit (#176) to an existing night: persist the edited in-bed window
    /// overlay and the recomputed durations/stages/efficiency/score. Non-destructive — the raw epoch
    /// archive is untouched, and `isManuallyEdited` makes a later re-sync preserve this row (see
    /// `saveSleepSummary`). `feelScore` is left as the user set it. Returns false if the night isn't
    /// in the store. The caller (RingSession) re-stages from the archive and appends the extension to
    /// Apple Health separately (append-only; nothing is deleted).
    @discardableResult
    func applySleepEdit(night: Date, editedWindow: SleepEdit.Window,
                        summary: SleepStaging.Summary, sleepOnset: Date, sleepWake: Date) throws -> Bool {
        let dayStart = Calendar.current.startOfDay(for: night)
        let descriptor = FetchDescriptor<StoredSleepSummary>(predicate: #Predicate { $0.night == dayStart })
        guard let row = try? context.fetch(descriptor).first else { return false }
        // Defense in depth behind the sheet/session dirty checks: submitting the recorded values
        // unchanged must not manufacture a manual edit or rewrite its score/timestamp.
        if SleepEdit.isSamePickerMinute(editedWindow.inBedStart, row.sleepEditCurrentInBedStart),
           SleepEdit.isSamePickerMinute(editedWindow.inBedEnd, row.sleepEditCurrentInBedEnd) {
            return true
        }
        let m = summary.minutes
        row.editedInBedStart = editedWindow.inBedStart
        row.editedInBedEnd = editedWindow.inBedEnd
        row.isManuallyEdited = true
        row.asleepMin = m.asleep
        row.deepMin = m.deep
        row.lightMin = m.light
        row.remMin = m.rem
        row.awakeMin = m.awake
        row.efficiency = summary.efficiency
        // Recompute the duration-driven Sleep Score from the edited night (HR/temp factors dropped →
        // renormalised, per SleepScore's contract — never fabricated).
        row.sleepScore = SleepScore.composite(.init(
            totalAsleep: summary.totalAsleep, timeAwake: summary.awake, efficiency: summary.efficiency,
            deep: summary.deep, light: summary.light, rem: summary.rem)).score
        row.updatedAt = Date()
        try context.save()
        return true
    }

    struct PendingSleepEditHealthWrite {
        let night: Date
        let segments: [SleepSegment]
    }

    private static func sleepEditLeadingCursorKey(_ night: Date) -> String {
        "hk:sleep-edit-leading:\(Calendar.current.startOfDay(for: night).timeIntervalSince1970)"
    }

    private func sleepEditLeadingWatermark(_ night: Date) throws -> Date? {
        let key = Self.sleepEditLeadingCursorKey(night)
        let descriptor = FetchDescriptor<StoredCursor>(predicate: #Predicate { $0.kindRaw == key })
        return try context.fetch(descriptor).first?.last
    }

    /// Extensions waiting for an append-only Health write. Wake-side progress uses the ordinary
    /// forward sleep cursor; bedtime-side progress uses the per-row leading watermark. Rows are
    /// offered only after their original night is known to be in Health; otherwise the ordinary
    /// first full-night write carries the extension once.
    func pendingSleepEditHealthWrites() throws -> [PendingSleepEditHealthWrite] {
        guard let sleepCursor = try loadCursor().last(.sleep) else { return [] }
        let rows = try context.fetch(FetchDescriptor<StoredSleepSummary>())
        return rows.compactMap { row in
            guard row.isManuallyEdited else { return nil }
            let recordedStart = row.sleepEditRecordedInBedStart
            let recordedEnd = row.sleepEditRecordedInBedEnd
            guard recordedEnd > recordedStart, sleepCursor >= recordedEnd else { return nil }
            let writtenStart = (try? sleepEditLeadingWatermark(row.night)) ?? recordedStart
            let writtenEnd = max(recordedEnd, min(sleepCursor, row.editedInBedEnd))
            var segments: [SleepSegment] = []
            let leadEnd = min(writtenStart, row.editedInBedEnd)
            if row.editedInBedStart < leadEnd {
                segments += [
                    SleepSegment(start: row.editedInBedStart, end: leadEnd, stage: .inBed),
                    SleepSegment(start: row.editedInBedStart, end: leadEnd, stage: .asleepCore),
                ]
            }
            if row.editedInBedEnd > writtenEnd {
                segments += [
                    SleepSegment(start: writtenEnd, end: row.editedInBedEnd, stage: .inBed),
                    SleepSegment(start: writtenEnd, end: row.editedInBedEnd, stage: .asleepCore),
                ]
            }
            return segments.isEmpty ? nil : PendingSleepEditHealthWrite(night: row.night,
                                                                         segments: segments)
        }
    }

    /// Advance both per-row manual-extension edges after one atomic HealthKit save.
    func markSleepEditHealthWritten(night: Date, segments: [SleepSegment]) throws {
        guard let row = try sleepSummary(night: night),
              let first = segments.map(\.start).min(), let last = segments.map(\.end).max() else { return }
        let recordedStart = row.sleepEditRecordedInBedStart
        var changed = false
        if first < recordedStart {
            let key = Self.sleepEditLeadingCursorKey(row.night)
            let descriptor = FetchDescriptor<StoredCursor>(predicate: #Predicate { $0.kindRaw == key })
            if let cursor = try context.fetch(descriptor).first {
                if first < cursor.last { cursor.last = first; changed = true }
            } else {
                context.insert(StoredCursor(kindRaw: key, last: first))
                changed = true
            }
        }
        // A retry can carry the wake-side extension after the ordinary sleep write failed. Advance
        // the shared forward cursor too, but never regress it for an older edited night; otherwise a
        // later re-edit can offer the same successful tail through `pendingHealthSleep` again.
        let cursor = try loadCursor()
        if cursor.isNew(.sleep, last) {
            upsertCursor(kind: MetricKind.sleep.rawValue, last: last)
            changed = true
        }
        if changed { try context.save() }
    }

    /// A normal first full-night write can already include the manual leading extension. Mark any
    /// such row covered so the separate bedtime append path never sends the same interval again.
    func markSleepEditHealthCovered(by segments: [SleepSegment]) throws {
        guard let first = segments.map(\.start).min(), let last = segments.map(\.end).max() else { return }
        let rows = try context.fetch(FetchDescriptor<StoredSleepSummary>())
        var changed = false
        for row in rows where row.isManuallyEdited {
            let recordedStart = row.sleepEditRecordedInBedStart
            let recordedEnd = row.sleepEditRecordedInBedEnd
            if row.editedInBedStart < recordedStart,
               first <= row.editedInBedStart, last >= recordedEnd,
               (try? sleepEditLeadingWatermark(row.night)) == nil {
                context.insert(StoredCursor(kindRaw: Self.sleepEditLeadingCursorKey(row.night),
                                            last: row.editedInBedStart))
                changed = true
            }
        }
        if changed { try context.save() }
    }

    // MARK: Naps (#76) — separate from the night so they never double-count

    /// Upsert one auto-detected nap, keyed by start. A re-detected nap with the same start
    /// updates in place; a genuinely new nap inserts. Preserves `healthWritten` on update so a
    /// nap already mirrored to Health isn't re-written.
    func saveNap(start: Date, end: Date, asleepMin: Int, isLongNap: Bool,
                 segments: [SleepSegment] = []) throws {
        let descriptor = FetchDescriptor<StoredNap>(predicate: #Predicate { $0.start == start })
        if let existing = try? context.fetch(descriptor).first {
            // A manually edited/added nap is authoritative — auto re-detection must not overwrite it.
            if existing.isManuallyEdited || existing.isManuallyAdded { return }
            existing.end = end
            existing.asleepMin = asleepMin
            existing.isLongNap = isLongNap
            existing.stagedSegments = segments.isEmpty ? nil : segments
            existing.updatedAt = Date()
        } else {
            let row = StoredNap(start: start, end: end, asleepMin: asleepMin, isLongNap: isLongNap)
            row.stagedSegments = segments.isEmpty ? nil : segments
            context.insert(row)
        }
        try context.save()
    }

    /// Add a user-logged nap the ring never detected (#nap-parity, RingConn add-nap). Coarse segments
    /// (the user asserts the window). `isManuallyAdded` so re-detection can't remove it, and
    /// `healthWritten=false` so the next flush APPENDS it to Apple Health (never deletes). Returns
    /// false if a nap already exists at that exact start.
    @discardableResult
    func addManualNap(start: Date, end: Date) throws -> Bool {
        guard end > start else { return false }
        // Persistence-layer backstop for the night-overlap rule (the sheet's guard can be nil-fed):
        // a manual nap must not sit inside the recorded night, or it double-counts + duplicates Health.
        if overlapsLatestNight(start, end) { return false }
        let dup = FetchDescriptor<StoredNap>(predicate: #Predicate { $0.start == start })
        if (try? context.fetch(dup).first) != nil { return false }
        let row = StoredNap(start: start, end: end,
                            asleepMin: Int((end.timeIntervalSince(start) / 60).rounded()),
                            isLongNap: end.timeIntervalSince(start) >= NapDetection.longNapDuration)
        row.isManuallyAdded = true
        // The user asserts they slept the whole window (no ring staging), so the coarse hypnogram is
        // the full window asleep — matching the full-window asleepMin above.
        row.stagedSegments = [
            SleepSegment(start: start, end: end, stage: .inBed),
            SleepSegment(start: start, end: end, stage: .asleepCore),
        ]
        context.insert(row)
        do { try context.save() } catch { context.rollback(); return false }
        return true
    }

    /// Edit an existing nap's window (#nap-parity, RingConn `isEdited`). OVERLAY: the unique `start`
    /// key is kept STABLE and the new window stored in `editedStart/editedEnd`, so a later auto
    /// re-detection updates the SAME row (no duplicate nap at the old start). Marks `isManuallyEdited`
    /// so re-detection can't clobber it, and keeps `healthWritten` as-is: an already-mirrored nap is NOT
    /// re-written (app-side edit — nothing is deleted from Apple Health); a not-yet-written nap flushes
    /// with the new times. Returns false if the nap isn't found or the new window overlaps the night.
    @discardableResult
    func editNap(originalStart: Date, newStart: Date, newEnd: Date) throws -> Bool {
        guard newEnd > newStart else { return false }
        if overlapsLatestNight(newStart, newEnd) { return false }
        let descriptor = FetchDescriptor<StoredNap>(predicate: #Predicate { $0.start == originalStart })
        guard let row = try? context.fetch(descriptor).first else { return false }
        row.editedStart = newStart          // keep `start` (the dedup key) stable — overlay the edit
        row.editedEnd = newEnd
        row.asleepMin = Int((newEnd.timeIntervalSince(newStart) / 60).rounded())
        row.isLongNap = newEnd.timeIntervalSince(newStart) >= NapDetection.longNapDuration
        row.isManuallyEdited = true
        row.stagedSegments = [
            SleepSegment(start: newStart, end: newEnd, stage: .inBed),
            SleepSegment(start: newStart, end: newEnd, stage: .asleepCore),
        ]
        row.updatedAt = Date()
        do { try context.save() } catch { context.rollback(); return false }
        return true
    }

    /// True when [start,end] overlaps the latest stored night's in-bed window — the persistence-layer
    /// guard that keeps a manual nap from double-counting / duplicating the night in Apple Health.
    private func overlapsLatestNight(_ start: Date, _ end: Date) -> Bool {
        var d = FetchDescriptor<StoredSleepSummary>(sortBy: [SortDescriptor(\.night, order: .reverse)])
        d.fetchLimit = 1
        guard let n = try? context.fetch(d).first, n.inBedEnd > n.inBedStart else { return false }
        return start < n.inBedEnd && end > n.inBedStart
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

    /// Naps whose start time falls within `[from, to)`, oldest first.
    func naps(from: Date, to: Date) throws -> [StoredNap] {
        let descriptor = FetchDescriptor<StoredNap>(
            predicate: #Predicate { $0.start >= from && $0.start < to },
            sortBy: [SortDescriptor(\.start, order: .forward)])
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

    /// Accumulate a SAME-DAY step delta into the running total for `day`, UPSERTED by
    /// start-of-day, AND record a timestamped `StoredStepSample` snapshot (#steps-history) so the
    /// delta's actual observation window survives alongside the rollup. `RingSession` derives the
    /// delta from the descriptor's current-day raw total: within one day it stores only the
    /// increment between repeated reads, while the first read of a new day credits that day's
    /// full already-taken count. New day = new row. `day` is the SAMPLE time of the reading (when
    /// the descriptor arrived), so a value observed just after midnight is stamped onto its own
    /// day, not the prior one. `windowStart` is when the PREVIOUS reading was observed (the start
    /// of the window this delta was folded over); falls back to the day boundary when the caller
    /// doesn't know one (fresh baseline / day rollover), matching the rollup's own "today so far"
    /// fallback.
    func addDailySteps(_ delta: Int, day: Date = Date(), windowStart: Date? = nil) throws {
        guard delta > 0 else { return }
        let dayStart = Calendar.current.startOfDay(for: day)
        let descriptor = FetchDescriptor<StoredDaily>(predicate: #Predicate { $0.day == dayStart })
        if let existing = try? context.fetch(descriptor).first {
            existing.steps += delta
            existing.updatedAt = Date()
        } else {
            context.insert(StoredDaily(day: dayStart, steps: delta))
        }
        context.insert(StoredStepSample(start: windowStart ?? dayStart, end: day, delta: delta))
        try context.save()
    }

    /// Today's accumulated step total (0 if none yet).
    func todaySteps(day: Date = Date()) throws -> Int {
        let dayStart = Calendar.current.startOfDay(for: day)
        let descriptor = FetchDescriptor<StoredDaily>(predicate: #Predicate { $0.day == dayStart })
        return (try? context.fetch(descriptor).first)?.steps ?? 0
    }

    /// Step snapshots not yet mirrored to Apple Health, oldest first — each carries its own
    /// narrow `start`/`end` window (#steps-history), so `HealthKitWriter` can write accurately-
    /// timed `stepCount` samples instead of one `startOfDay→now` smear. Unbounded by "today":
    /// also picks up any earlier day's leftover delta a missed flush left pending.
    func pendingStepSamples() throws -> [StoredStepSample] {
        let descriptor = FetchDescriptor<StoredStepSample>(
            predicate: #Predicate { $0.healthWritten == false },
            sortBy: [SortDescriptor(\.start, order: .forward)])
        return try context.fetch(descriptor)
    }

    /// Mark step snapshots written to Apple Health so they aren't re-sent. Mutates the live
    /// `@Model` rows `pendingStepSamples()` just returned (same context) rather than re-fetching.
    func markStepSamplesWritten(_ samples: [StoredStepSample]) throws {
        guard !samples.isEmpty else { return }
        for row in samples { row.healthWritten = true }
        try context.save()
    }

    /// Step snapshots in `[from, to)`, oldest first — the timestamped step history for the
    /// Trends/day-detail intraday views (#steps-history); `StoredDaily` only has the day total.
    func stepSamples(from: Date, to: Date) throws -> [StoredStepSample] {
        let descriptor = FetchDescriptor<StoredStepSample>(
            predicate: #Predicate { $0.start >= from && $0.start < to },
            sortBy: [SortDescriptor(\.start, order: .forward)])
        return try context.fetch(descriptor)
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

    /// Daily step rollups whose `day` bucket falls within `[from, to)`, oldest first.
    func dailies(from: Date, to: Date) throws -> [StoredDaily] {
        let descriptor = FetchDescriptor<StoredDaily>(
            predicate: #Predicate { $0.day >= from && $0.day < to },
            sortBy: [SortDescriptor(\.day, order: .forward)])
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

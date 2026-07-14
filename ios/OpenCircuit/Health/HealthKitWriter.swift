import Foundation
import HealthKit
import OpenCircuitKit

// Writes ring metrics into Apple Health. Type/unit choices follow
// docs/HEALTHKIT_MAPPING.md. Samples are saved with the device's own timestamps
// so history backfills; a stable bundle id + the SyncCursor avoid duplicates.

@MainActor
final class HealthKitWriter {
    private let store = HKHealthStore()
    private static let systolicType = HKQuantityType(.bloodPressureSystolic)
    private static let diastolicType = HKQuantityType(.bloodPressureDiastolic)
    private static let bloodPressureType = HKCorrelationType.correlationType(forIdentifier: .bloodPressure)!
    /// Reentrancy guard for `flushToHealth`: the method suspends on each HealthKit `save`,
    /// and it's triggered from several UI/lifecycle points — without this, two overlapping
    /// flushes could both read the same pending set before either advanced its watermark and
    /// double-write to Health. STATIC so it serializes across the separate foreground and
    /// background-task `HealthKitWriter` instances too (both run on the MainActor, which reads/
    /// writes this synchronously around the awaits — they share one underlying SQLite store).
    private static var isFlushing = false

    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    /// HKQuantityType for a scalar metric, or nil for non-quantity kinds (sleep).
    static func quantityType(for kind: MetricKind) -> HKQuantityType? {
        let id: HKQuantityTypeIdentifier
        switch kind {
        case .heartRate: id = .heartRate
        case .restingHeartRate: id = .restingHeartRate
        case .hrvSDNN: id = .heartRateVariabilitySDNN
        case .spo2: id = .oxygenSaturation
        // Skin temp is captured ONLY during the nightly sleep window (RingSession). The ideal
        // sleeping-wrist type (`.appleSleepingWristTemperature`) is Apple-COMPUTED and read-only
        // for third parties: it can't be save()d, and putting it in the `toShare` set of
        // `requestAuthorization` raises NSInvalidArgumentException, which would crash auth or —
        // swallowed by the call-site `try?` — silently disable EVERY metric's writeback. We
        // previously used `.basalBodyTemperature`, but Apple Health hard-wires that type to
        // Cycle Tracking's basal body temperature (BBT) chart, which is a specific fertility
        // signal — polluting it with nightly skin readings misreports BBT. Writing to the
        // general `.bodyTemperature` keeps the data in Health without entangling it with the
        // menstrual-cycle chart. Units stay °C (see `unit(for:)`).
        case .temperature: id = .bodyTemperature
        case .respiratoryRate: id = .respiratoryRate
        case .steps: id = .stepCount
        case .activeEnergy: id = .activeEnergyBurned
        case .sleep: return nil
        // ESTIMATE — steps × RingConn's own per-step constant. See DistanceEstimate.swift (#81).
        case .distance: id = .distanceWalkingRunning
        // Apple Exercise Time is an Apple-COMPUTED Activity-ring metric — NOT third-party
        // shareable or writable. Listing it in `requestAuthorization(toShare:)` raises an Obj-C
        // NSInvalidArgumentException (-[HKHealthStore _throwIfAuthorizationDisallowedForSharing:])
        // that crashed the app on first Health auth (TestFlight #110), and `save()` of it errors.
        // Apps contribute exercise time only via HKWorkout (the #93 path), so there is no writable
        // quantity type for it — return nil so it is excluded from BOTH the auth set and writes.
        case .exerciseMinutes: return nil
        }
        return HKQuantityType(id)
    }

    /// HKUnit matching MetricKind.unit (the canonical units in OpenCircuitKit).
    static func unit(for kind: MetricKind) -> HKUnit {
        switch kind {
        case .heartRate, .restingHeartRate, .respiratoryRate:
            return HKUnit.count().unitDivided(by: .minute())
        case .hrvSDNN: return .secondUnit(with: .milli)
        case .spo2: return .percent()                 // value is a 0…1 fraction
        case .temperature: return .degreeCelsius()
        case .steps: return .count()
        case .activeEnergy: return .kilocalorie()
        case .sleep: return .count()                  // unused
        case .distance: return .meter()              // ESTIMATE — steps × RingConn's per-step constant
        case .exerciseMinutes: return .minute()      // ESTIMATE — elevated HR minutes
        }
    }

    // Internal (not private) so HealthKitShareTypesTests can guard the set's contents.
    var allTypes: Set<HKSampleType> {
        var set = Set<HKSampleType>()
        for k in MetricKind.allCases {
            if let t = Self.quantityType(for: k) { set.insert(t) }
        }
        set.insert(HKQuantityType(.basalEnergyBurned))
        set.insert(HKCategoryType(.sleepAnalysis))
        // Workout types (#75): HKWorkout + GPS route (workout sessions feature).
        set.insert(HKWorkoutType.workoutType())
        set.insert(HKSeriesType.workoutRoute())
        // Cycling distance is written for cycling workouts (foot-based sports use the
        // .distanceWalkingRunning type already covered by MetricKind.distance above).
        set.insert(HKQuantityType(.distanceCycling))
        // Women's health (#78): user-logged period flow written to Health.
        // NOTE: temperature is NOT added here — it already ships via the canonical
        // `.bodyTemperature` path (MetricKind.temperature). No triple-write.
        set.insert(HKCategoryType(.menstrualFlow))
        // Blood pressure (#121): authorization is granted on the two CONSTITUENT quantity
        // types only. The `bloodPressureType` HKCorrelationType must NEVER be added here:
        // correlation types are not authorizable, and their presence in the `toShare` set of
        // `requestAuthorization`/`statusForAuthorizationRequest` raises an uncatchable Obj-C
        // NSInvalidArgumentException — which crashed the app whenever the auth path ran, e.g.
        // right after the user revoked Health access in the Health app (the #119 auth-recovery
        // path re-requests). Saving the HKCorrelation itself needs no correlation-level grant;
        // it is authorized through systolic + diastolic.
        set.insert(Self.systolicType)
        set.insert(Self.diastolicType)
        return set
    }

    /// True once the user has granted share access (probed on heart rate as a representative
    /// type). Lets the app auto-flush to Health without a button tap, while staying silent
    /// when access was never granted. (HealthKit hides READ status for privacy, but SHARE
    /// status is reportable.)
    var isShareAuthorized: Bool {
        Self.isAvailable
            && store.authorizationStatus(for: HKQuantityType(.heartRate)) == .sharingAuthorized
    }

    /// The shareable, AUTHORIZABLE types the user has explicitly DENIED (turned off in the iOS
    /// permission sheet or later in Settings ▸ Health ▸ Data Access). SHARE status is reportable
    /// per-type (unlike READ status), so this is a trustworthy signal. `allTypes` already excludes
    /// the non-authorizable `bloodPressureType` HKCorrelationType (querying it throws an uncatchable
    /// Obj-C exception), so this never touches it. Includes `.sleepAnalysis` and `.menstrualFlow`.
    func deniedShareTypes() -> [HKSampleType] {
        guard Self.isAvailable else { return [] }
        return allTypes.filter { store.authorizationStatus(for: $0) == .sharingDenied }
    }

    /// Tri-state Health share status so the UI can tell "never granted" from "some granted, some
    /// denied" — the partial case is the trap #132 fixes: `isShareAuthorized` (heart rate) is `true`
    /// yet other metrics silently never reach Health. `isShareAuthorized` stays as-is so the flush
    /// keeps writing the metrics that ARE granted; this only drives the honest status copy.
    enum ShareState: Equatable {
        case unauthorized
        case partial([HKSampleType])   // HR granted, but these types are denied
        case authorized
    }

    var shareState: ShareState {
        guard Self.isAvailable else { return .unauthorized }
        return Self.resolveShareState(authorizableTypes: allTypes) {
            store.authorizationStatus(for: $0)
        }
    }

    /// Pure share-state resolution over an injected authorization-status lookup — testable without a
    /// live `HKHealthStore` (the simulator reports every type `.notDetermined`). Heart rate is the
    /// representative "did the user grant anything" gate, mirroring `isShareAuthorized`.
    static func resolveShareState(authorizableTypes: Set<HKSampleType>,
                                  status: (HKSampleType) -> HKAuthorizationStatus) -> ShareState {
        guard status(HKQuantityType(.heartRate)) == .sharingAuthorized else { return .unauthorized }
        let denied = authorizableTypes.filter { status($0) == .sharingDenied }
        return denied.isEmpty ? .authorized : .partial(Array(denied))
    }

    /// User-facing name for a share type, for the partial-grant / failure warnings. Maps quantity
    /// types back through `MetricKind` where possible; a small table covers the non-`MetricKind`
    /// extras (sleep, energy, cycle tracking, blood pressure, workouts).
    static func friendlyName(for type: HKSampleType) -> String {
        for k in MetricKind.allCases {
            if let qt = quantityType(for: k), qt.isEqual(type) { return k.displayName }
        }
        if type.isEqual(HKCategoryType(.sleepAnalysis)) { return "Sleep" }
        if type.isEqual(HKQuantityType(.basalEnergyBurned)) { return "Resting Energy" }
        if type.isEqual(HKCategoryType(.menstrualFlow)) { return "Cycle Tracking" }
        if type.isEqual(systolicType) || type.isEqual(diastolicType) { return "Blood Pressure" }
        if type.isEqual(HKQuantityType(.distanceCycling)) { return "Cycling Distance" }
        if type is HKWorkoutType || type is HKSeriesType { return "Workouts" }
        return type.identifier
    }

    /// De-duplicated, stably-sorted friendly names for a set of denied/failed types (both BP
    /// constituents collapse to one "Blood Pressure", etc.).
    static func friendlyNames(for types: [HKSampleType]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for name in types.map({ friendlyName(for: $0) }).sorted() where seen.insert(name).inserted {
            out.append(name)
        }
        return out
    }

    /// Deep link into the Health app — the recovery path once the one-time permission sheet
    /// has been used up (see `authorizationPromptAvailable`). There is no per-app deep link to
    /// Health's privacy page; the app root is as close as iOS allows.
    static let healthAppURL = URL(string: "x-apple-health://")!

    /// Whether calling `requestAuthorization()` would actually present the iOS permission
    /// sheet. iOS shows the HealthKit sheet ONCE per app for a given type set: after the user
    /// responds — even declining everything — later requests return immediately with no UI,
    /// which reads as a dead "Connect" button. `false` (while unauthorized) means the only
    /// path left is the Health app's own toggles, so the UI must route there instead. `nil` =
    /// status unknown (the entitlement-stripped sideload case) — treat as promptable so the
    /// tap path can throw and surface `healthUnavailable` as before. A new shareable type
    /// added in an update flips this back to `true` (the sheet re-appears for the new types
    /// only), so the prompt path self-heals across upgrades.
    func authorizationPromptAvailable() async -> Bool? {
        guard Self.isAvailable else { return false }
        let read: Set<HKObjectType> = [HKCategoryType(.sleepAnalysis)]
        guard let status = try? await store.statusForAuthorizationRequest(toShare: allTypes,
                                                                          read: read)
        else { return nil }
        return status == .shouldRequest
    }

    /// What a `flushToHealth` pass actually wrote (for a status line); all-zero when there
    /// was nothing pending or share access isn't granted.
    struct FlushResult: Equatable {
        var samples = 0, sleepSegments = 0, steps = 0
        var restingDays = 0, passiveHours = 0
        var activeKcal = 0.0
        var naps = 0
        var distanceM = 0.0         // estimated distance written (#81)
        var exerciseMinutes = 0.0   // estimated exercise minutes written (#82)
        var menstrualFlowEntries = 0  // user-logged period entries written (#78)
        /// Metrics whose HealthKit `save` actually THREW this pass (#135) — distinct from "nothing
        /// pending". Persisted per-metric so the UI can surface an honest "X hasn't synced" warning
        /// instead of the blanket "Auto-syncing" line. Empty on a clean/idle flush.
        var failures: Set<MetricKind> = []
        var wroteAnything: Bool {
            samples > 0 || sleepSegments > 0 || steps > 0
                || restingDays > 0 || passiveHours > 0 || activeKcal > 0 || naps > 0
                || distanceM > 0 || exerciseMinutes > 0 || menstrualFlowEntries > 0
        }
    }

    /// Metrics whose HealthKit `save` threw during the CURRENT flush pass. Reset at the top of
    /// `flushToHealth`; the inline blocks and per-helper flushes add to it on a caught save error.
    /// Rolled into `FlushResult.failures` and persisted (below) so all three flush entry points
    /// (foreground, RingSession, background task) surface a consistent failure state. (#135)
    private var pendingFlushFailures: Set<MetricKind> = []

    // MARK: Persisted per-metric write-failure map (#135)
    //
    // Flushes run from three entry points on SEPARATE `HealthKitWriter` instances, so the last
    // failure per metric lives in UserDefaults (mirroring the `hk.*` watermark pattern) where all
    // three can write it and the UI can read it. Set on a caught save error, CLEARED on the next
    // successful write of that metric — so "nothing pending" and "writes failing" stay distinct.
    private static let failureMapKey = "hk.failures.byMetric"   // [MetricKind.rawValue : since1970]

    /// Merge one flush pass into the persisted failure map: stamp `failed` metrics with `now`, and
    /// clear any `written` metric's flag (a later success wins, so a re-enabled type self-heals).
    static func recordFlushOutcome(written: Set<MetricKind>, failed: Set<MetricKind>,
                                   now: Date = Date(), _ defaults: UserDefaults = .standard) {
        var map = (defaults.dictionary(forKey: failureMapKey) as? [String: Double]) ?? [:]
        for m in failed { map[m.rawValue] = now.timeIntervalSince1970 }
        for m in written { map.removeValue(forKey: m.rawValue) }
        if map.isEmpty { defaults.removeObject(forKey: failureMapKey) }
        else { defaults.set(map, forKey: failureMapKey) }
    }

    /// The persisted per-metric write failures (metric → last failure time), for the UI warning.
    static func healthWriteFailures(_ defaults: UserDefaults = .standard) -> [MetricKind: Date] {
        guard let map = defaults.dictionary(forKey: failureMapKey) as? [String: Double] else { return [:] }
        return map.reduce(into: [:]) { acc, kv in
            if let kind = MetricKind(rawValue: kv.key) { acc[kind] = Date(timeIntervalSince1970: kv.value) }
        }
    }

    /// Mirror everything pending into Apple Health in one pass — scalar vitals, the night's
    /// sleep, and today's step delta — each gated by its own watermark so nothing double-
    /// writes. No-op (and advances no watermark) when share access isn't granted, so the
    /// data backfills on the first flush after the user authorizes. Best-effort: a failure
    /// on one metric doesn't block the others or advance its watermark.
    @discardableResult
    func flushToHealth(store: LocalStore, sleepSegments: [SleepSegment] = []) async -> FlushResult {
        var result = FlushResult()
        guard isShareAuthorized, !Self.isFlushing else { return result }
        Self.isFlushing = true
        defer { Self.isFlushing = false }

        pendingFlushFailures = []            // per-pass failure accumulator (#135)
        var writtenKinds: Set<MetricKind> = []  // metrics that landed at least one sample this pass

        // Scalars: write, THEN advance the watermark, so a failed save backfills next time. The
        // write is SPLIT per metric (#132): a single denied type (e.g. SpO₂) no longer sinks the
        // whole batch — the granted metrics still land and only the denied one is left pending.
        if let pending = try? store.pendingHealthSamples(), !pending.isEmpty {
            let outcome = await write(pending)
            if !outcome.written.isEmpty {
                try? store.markHealthWritten(outcome.written)   // advance ONLY for what actually saved
                result.samples = outcome.written.count
                writtenKinds.formUnion(outcome.written.map(\.kind))
            }
            pendingFlushFailures.formUnion(outcome.failed)
        }
        // Sleep: same write-then-mark order (a failed save must not lose the night). Only mirror a
        // SETTLED night (SleepHealthGate): with periodic overnight draining the staged night grows
        // as epochs arrive, and `pendingHealthSleep` keys off the latest segment end — writing an
        // in-progress night each drain would lay down OVERLAPPING sleep samples. Once the block has
        // stopped advancing (sleeper is up), it writes once and the `.sleep` cursor blocks re-writes.
        if SleepHealthGate.isSettled(latestSegmentEnd: sleepSegments.map(\.end).max(), now: Date()),
           let pendingSleep = try? store.pendingHealthSleep(sleepSegments), !pendingSleep.isEmpty {
            do {
                try await write(sleep: pendingSleep)
                try store.markSleepWritten(pendingSleep)
                try store.markSleepEditHealthCovered(by: pendingSleep)
                result.sleepSegments = pendingSleep.count
                writtenKinds.insert(.sleep)
            } catch {
                // A denied .sleepAnalysis type throws here forever — surface it (#135) instead of
                // silently retrying, so the card can say "Sleep hasn't synced". Cursor stays put.
                pendingFlushFailures.insert(.sleep)
            }
        }
        // Persisted manual extensions backfill after the ordinary night write. This is essential for
        // bedtime slices (which sit before the forward cursor) and also retries a wake extension if
        // the edit happened while Health was denied/offline. Watermarks advance only after `save`
        // succeeds; no HealthKit object is queried, replaced, or deleted.
        if let edits = try? store.pendingSleepEditHealthWrites() {
            for edit in edits {
                guard SleepHealthGate.isSettled(
                    latestSegmentEnd: edit.segments.map(\.end).max(), now: Date()
                ) else { continue }
                do {
                    try await write(sleep: edit.segments)
                    try store.markSleepEditHealthWritten(night: edit.night, segments: edit.segments)
                    result.sleepSegments += edit.segments.count
                    writtenKinds.insert(.sleep)
                } catch {
                    pendingFlushFailures.insert(.sleep)
                    break
                }
            }
        }
        // Naps (#76): each carries its own `healthWritten` flag (NOT the night's `.sleep` cursor),
        // so a daytime nap and the overnight night write independently and never collide.
        result.naps = await flushNaps(store: store)
        if result.naps > 0 { writtenKinds.insert(.sleep) }

        // Women's health (#78): write pending user-logged period flow entries to Health.
        // Gated by each entry's own `healthWritten` flag — independent of all other writes.
        result.menstrualFlowEntries = await flushMenstrualFlow(localStore: store)

        // Profile is used for calories + exercise-minute thresholds — resolved once here so the
        // derived writes use the same snapshot. Body inputs come from the shared profile defaults;
        // the ring transmits none of them. Distance (below) no longer needs it — PROTOCOL.md §5.3.1
        // confirms RingConn's distance derivation is a fixed per-step constant, not height/sex.
        let profile = Self.storedUserProfile()

        // Steps + distance estimate (#81, #steps-history): write each pending TIMESTAMPED step
        // snapshot as its OWN narrow-window stepCount sample (its real observed start/end), not
        // one `startOfDay→now` lump. HealthKit's stepCount type apportions a sample across every
        // hour it overlaps, so the old single-window write smeared a whole day's steps evenly
        // across every elapsed hour instead of landing them near when they actually happened —
        // per-snapshot writes fix that while HealthKit's SUM still lands the correct daily total.
        // Distance is netted/credited per CALENDAR DAY (the GPS-credit ledger in UserDefaults is
        // day-keyed), so snapshots are grouped by day rather than assuming one day's worth.
        if let pending = try? store.pendingStepSamples(), !pending.isEmpty {
            let stepSamples: [QuantitySample] = pending.map {
                QuantitySample(kind: .steps, start: $0.start, end: $0.end, value: Double($0.delta))
            }
            // Derive the per-day distance samples (and their GPS-credit reductions) up front, but do
            // NOT fold them into the step write — see the coupling note below. `netDistanceEstimate`
            // only COMPUTES the net (reading the day-keyed GPS ledger); the ledger is mutated solely
            // by `commitDistanceGPSCredit`, which we defer until distance actually writes.
            var distanceSamples: [QuantitySample] = []
            var gpsCommits: [(reduction: Double, day: Date)] = []
            let byDay = Dictionary(grouping: pending) { Calendar.current.startOfDay(for: $0.end) }
            for (day, rows) in byDay {
                let dayDelta = rows.reduce(0) { $0 + $1.delta }
                let rawDistanceM = DistanceEstimate.meters(steps: dayDelta)
                let (netDistanceM, gpsReduction) = Self.netDistanceEstimate(rawDistanceM, day: day)
                if netDistanceM > 0 {
                    let dayEnd = rows.map(\.end).max() ?? day
                    distanceSamples.append(QuantitySample(kind: .distance, start: day, end: dayEnd, value: netDistanceM))
                }
                gpsCommits.append((gpsReduction, day))
            }
            // Scalar KINDS split independently (#132), but steps and the DERIVED distance stay COUPLED:
            // distance has no watermark of its own — it's re-derived from the same `StoredStepSample`
            // rows every flush and rides their `healthWritten` flag (advanced only by
            // `markStepSamplesWritten`). So distance is written in a SEPARATE pass that runs ONLY after
            // the step rows are marked written this flush. Folding distance into the step batch would
            // let a granted-distance sample LAND even when the steps save fails (the per-kind split
            // saves each kind independently) — and, with the rows still pending, re-derive + re-write
            // every subsequent flush → HealthKit SUMS it → the day's distance inflates ~N×. Writing
            // distance only after a successful step save defers it instead of duplicating it.
            let stepsOutcome = await write(stepSamples)
            if !stepsOutcome.failed.contains(.steps) {
                try? store.markStepSamplesWritten(pending)
                result.steps = pending.reduce(0) { $0 + $1.delta }
                writtenKinds.insert(.steps)
                // Steps landed and the rows are now marked written → safe to write/commit distance.
                if !distanceSamples.isEmpty {
                    let distanceOutcome = await write(distanceSamples)
                    if Self.distanceMayWrite(stepsFailed: false,
                                             distanceFailed: distanceOutcome.failed.contains(.distance)) {
                        for commit in gpsCommits { Self.commitDistanceGPSCredit(commit.reduction, day: commit.day) }
                        let distanceWritten = distanceOutcome.written
                            .filter { $0.kind == .distance }.reduce(0) { $0 + $1.value }
                        result.distanceM = distanceWritten
                        if distanceWritten > 0 { writtenKinds.insert(.distance) }
                    } else {
                        // TRADEOFF (accepted): steps granted + distance denied → this window's distance
                        // estimate is skipped and won't backfill if the user later enables Distance,
                        // because the step rows are already marked written. Distance is a DERIVED
                        // estimate (steps × stride), not measured data; a separate `distanceWritten`
                        // flag + migration to make it independently backfillable is out of scope. The
                        // GPS credit is NOT committed here, so it isn't consumed against a write that
                        // didn't happen.
                        pendingFlushFailures.insert(.distance)
                    }
                }
            }
            // If steps FAILED, distance was never written (deferred with the rows), so no distance
            // failure is recorded here.
            pendingFlushFailures.formUnion(stepsOutcome.failed.subtracting([.distance]))
        }
        // Pre-fetch HR samples for the 32-day basal-energy lookback — the widest window needed
        // by both resting HR and passive-calorie flushes. Fetched once and shared so we don't
        // query LocalStore twice for overlapping ranges (#172 review, fix #2).
        let basalHR = Self.prefetchHRSamples(local: store, lookbackDays: Self.basalRHRLookbackDays,
                                              now: Date())

        // Derived daily resting HR — one sample per finalized day (#18, #37). Idempotency is a
        // UserDefaults day-watermark, NOT the store cursor: RHR isn't a stored sample, and the
        // `hk:` cursor rows belong to the raw-sample mirror above.
        result.restingDays = await flushRestingHR(prefetchedHR: basalHR, sleepSegments: sleepSegments)
        if result.restingDays > 0 { writtenKinds.insert(.restingHeartRate) }

        // Energy: passive (hourly BMR) + active (HR-derived or steps-derived estimate).
        // Watermark-gated (#37) and labeled as derived estimates in HealthKit metadata.
        result.passiveHours = await flushPassiveCalories(profile: profile, prefetchedHR: basalHR)
        result.activeKcal = await flushActiveCalories(local: store, profile: profile)
        if result.activeKcal > 0 { writtenKinds.insert(.activeEnergy) }

        // Exercise minutes estimate (#82): elevated-HR minutes outside the sleep window.
        // ESTIMATE — basic 50% maxHR threshold. Full 4-level intensity follows #93 decode.
        result.exerciseMinutes = await flushExerciseMinutes(local: store, profile: profile)

        // Roll the per-pass failures into the result and persist the per-metric failure map so all
        // three flush entry points surface a consistent "X hasn't synced" state; a same-pass success
        // clears a prior failure so a re-enabled type self-heals. (#135)
        result.failures = pendingFlushFailures
        Self.recordFlushOutcome(written: writtenKinds, failed: pendingFlushFailures)
        return result
    }

    /// Write each pending nap to Apple Health as sleep (a coarse inBed + asleepCore pair over the
    /// nap window) and mark it written, returning the count. Gated by each nap's own
    /// `healthWritten` flag — independent of the night's `.sleep` cursor — so naps and the night
    /// never collide. Best-effort: a failed save leaves the flag so it retries next flush.
    private func flushNaps(store: LocalStore) async -> Int {
        guard let pending = try? store.pendingNaps(), !pending.isEmpty else { return 0 }
        var written = 0
        for nap in pending {
            // Write the nap's staged hypnogram (Deep/Light/REM — RingConn sleepPhases parity) when it
            // has one, else a coarse inBed+asleepCore pair. Append-only, gated by the nap's own flag.
            let segs = nap.stagedSegments ?? [
                SleepSegment(start: nap.start, end: nap.end, stage: .inBed),
                SleepSegment(start: nap.start, end: nap.end, stage: .asleepCore),
            ]
            do {
                try await write(sleep: segs)
                try store.markNapWritten(start: nap.start)
                written += 1
            } catch { pendingFlushFailures.insert(.sleep); break }   // surface + stop; naps retry next flush
        }
        return written
    }

    /// Write pending user-logged period flow entries to Apple Health, returning the count
    /// written. Apple Health Cycle Tracking models flow as one sample PER DAY, so each logged
    /// day from start through the logged end (capped at today) is mirrored as its own one-day
    /// `menstrualFlow` sample. We NEVER invent a duration: an OPEN period (no logged end) only
    /// mirrors days up to today and stays pending, so subsequent days are added as they are
    /// actually logged/elapse. Before re-writing (after an edit, or extending an open period)
    /// the previously-written sample(s) are deleted by UUID so the append-only HealthKit store
    /// doesn't accumulate duplicates. (#78)
    private func flushMenstrualFlow(localStore: LocalStore) async -> Int {
        guard let pending = try? localStore.pendingPeriodEntries(), !pending.isEmpty else { return 0 }
        var written = 0
        for entry in pending {
            // Remove any prior samples for this entry first (edit / open-period extension).
            if !entry.hkSampleUUIDs.isEmpty {
                await deleteMenstrualFlowSamples(uuidStrings: entry.hkSampleUUIDs)
            }
            let finalized = entry.end != nil
            do {
                let uuids = try await writeMenstrualFlow(entry: entry)
                try localStore.recordPeriodEntryHK(start: entry.start,
                                                   hkSampleUUIDs: uuids, finalized: finalized)
                if !uuids.isEmpty { written += 1 }
            } catch { break }   // stop on first failure; unwritten entries retry next flush
        }
        return written
    }

    /// Write one single-day `menstrualFlow` category sample per logged day of a period (start
    /// through the logged end, capped at today — future days are never asserted). Returns the
    /// UUID strings of the samples saved so the caller can persist them for later delete/replace.
    /// `HKMetadataKeyMenstrualCycleStart: true` is set on the FIRST day only (period start =
    /// cycle start). Never fabricates a duration the user didn't log (P1 fix).
    private func writeMenstrualFlow(entry: StoredPeriodEntry) async throws -> [String] {
        let type = HKCategoryType(.menstrualFlow)
        let flowValue: HKCategoryValueMenstrualFlow
        switch entry.flowLevelRaw {
        case 1: flowValue = .light
        case 3: flowValue = .heavy
        default: flowValue = .medium
        }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let firstDay = cal.startOfDay(for: entry.start)
        // Finalized period: through the logged end day. Open period: only up to today.
        // Either way, never write a day in the future.
        let endCandidate = entry.end.map { cal.startOfDay(for: $0) } ?? today
        let lastDay = min(endCandidate, today)
        guard lastDay >= firstDay else { return [] }

        var samples: [HKCategorySample] = []
        var day = firstDay
        var isFirstDay = true
        while day <= lastDay {
            let dayEnd = cal.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
            // Mark only the first day of the period as the first day of the cycle.
            let metadata: [String: Any]? = isFirstDay ? [HKMetadataKeyMenstrualCycleStart: true] : nil
            samples.append(HKCategorySample(type: type, value: flowValue.rawValue,
                                            start: day, end: dayEnd, metadata: metadata))
            isFirstDay = false
            day = dayEnd
        }
        guard !samples.isEmpty else { return [] }
        try await store.save(samples)
        return samples.map { $0.uuid.uuidString }
    }

    /// Delete previously-written `menstrualFlow` samples by UUID (best-effort). Used when a
    /// logged period is edited (delete-then-rewrite) or deleted in-app, so Apple Health never
    /// keeps a stale or orphaned flow sample. (#78)
    func deleteMenstrualFlowSamples(uuidStrings: [String]) async {
        let uuids = Set(uuidStrings.compactMap { UUID(uuidString: $0) })
        guard !uuids.isEmpty, Self.isAvailable else { return }
        let predicate = HKQuery.predicateForObjects(with: uuids)
        _ = try? await store.deleteObjects(of: HKCategoryType(.menstrualFlow), predicate: predicate)
    }

    func requestAuthorization() async throws {
        // Read sleepAnalysis so the iOS Sleep-schedule window (HealthKitSleepSchedule) works
        // the moment the HealthKit entitlement is enabled — no further auth change needed.
        // (No effect today: without the entitlement the request is a no-op, so it can't prompt.)
        var read: Set<HKObjectType> = [HKCategoryType(.sleepAnalysis)]
        for type in allTypes {
            if type is HKWorkoutType || type is HKSeriesType { continue }
            read.insert(type)
        }
        // Every type in `allTypes` is deliberately third-party-WRITABLE (that's why `.temperature`
        // maps to `.bodyTemperature`, not the read-only `.appleSleepingWristTemperature`) —
        // an unshareable type here would poison the whole request. Defensive isolation: if the
        // request still throws (a future/edge type the OS refuses to share), retry WITHOUT
        // temperature so one bad type degrades to "temp not shared" instead of disabling share
        // access for every metric. (A genuinely non-shareable Apple-computed type raises an Obj-C
        // NSInvalidArgumentException this can't catch — which is exactly why we never list one.)
        do {
            try await store.requestAuthorization(toShare: allTypes, read: read)
        } catch {
            var writable = allTypes
            if let temp = Self.quantityType(for: .temperature) { writable.remove(temp) }
            try await store.requestAuthorization(toShare: writable, read: read)
        }
    }

    /// Outcome of a split scalar write (#132): which input samples actually LANDED (so the caller
    /// advances only their watermark) and which metric KINDS threw (so they're surfaced + retried).
    struct ScalarWriteOutcome {
        var written: [QuantitySample] = []
        var failed: Set<MetricKind> = []
    }

    /// Whether the derived distance estimate may be WRITTEN + GPS-credited this pass. Distance rides
    /// the step rows' single `healthWritten` flag, so it may only land when steps saved (rows marked
    /// written, so nothing re-derives) AND distance itself wasn't denied — else a granted distance
    /// re-writes every flush while steps stay pending and HealthKit sums the duplicate (#132 fix).
    static func distanceMayWrite(stepsFailed: Bool, distanceFailed: Bool) -> Bool {
        !stepsFailed && !distanceFailed
    }

    /// Write scalar samples, SPLIT per metric kind. Caller filters with SyncCursor first.
    ///
    /// The batch is grouped by `MetricKind` and each group saved on its own, so a single DENIED
    /// type (which makes `store.save` throw `errorAuthorizationDenied` for everything in one call)
    /// no longer sinks the whole batch — the granted metrics still reach Health and only the denied
    /// kind is reported as failed and left pending (#132). Non-throwing: failures are returned, not
    /// raised, so the caller can advance watermarks per surviving kind.
    func write(_ samples: [QuantitySample]) async -> ScalarWriteOutcome {
        var outcome = ScalarWriteOutcome()
        let byKind = Dictionary(grouping: samples, by: \.kind)
        for (kind, group) in byKind {
            let hk: [HKQuantitySample] = group.compactMap { s in
                guard let type = Self.quantityType(for: s.kind) else { return nil }
                let q = HKQuantity(unit: Self.unit(for: s.kind), doubleValue: s.value)
                return HKQuantitySample(type: type, quantity: q, start: s.start, end: s.end,
                                        metadata: Self.metadata(for: s.kind))
            }
            guard !hk.isEmpty else { continue }   // no writable HK type for this kind — nothing to save
            do {
                try await store.save(hk)
                outcome.written.append(contentsOf: group)
            } catch {
                outcome.failed.insert(kind)   // this metric is denied/failing; others still land
            }
        }
        return outcome
    }

    /// Metadata key on HRV samples flagging which statistic the value actually is.
    static let hrvStatisticMetadataKey = "OpenCircuitHRVStatistic"

    /// Per-kind sample metadata. The ring reports HRV as **RMSSD**, but HealthKit only offers
    /// an **SDNN** field — so we store the RMSSD value in `.heartRateVariabilitySDNN` and tag it
    /// honestly here rather than invent an RMSSD→SDNN conversion constant (the two are not a
    /// fixed ratio; see docs/HEALTHKIT_MAPPING.md). Readers can distinguish via this key.
    static func metadata(for kind: MetricKind) -> [String: Any]? {
        switch kind {
        case .hrvSDNN: return [hrvStatisticMetadataKey: "RMSSD"]
        // Distance is an ESTIMATE (steps × height-based stride, not GPS). Tag it so Health
        // readers can filter or label it appropriately (#81). Replaced by decoded device
        // distance once the activity-epoch [15:22] payload is decoded (#93).
        case .distance: return [HKMetadataKeyWasUserEntered: false,
                                "OpenCircuitDistanceSource": "steps×stride-estimate"]
        default: return nil
        }
    }

    /// Metadata flag marking basal (passive) energy samples as a derived ESTIMATE — a BMR formula
    /// prorated per hour, NOT a value the ring measured — so Health readers can label or filter it.
    static let basalEnergyEstimateMetadataKey = "OpenCircuitBasalEnergyEstimated"

    /// Metadata flag on a basal-energy sample recording whether the day's MEASURED resting HR
    /// actually modulated the formula BMR this hour (true), or it fell back to the static value
    /// (false — new user / no baseline yet). Lets Health readers and QA see which path ran.
    static let basalEnergyRHRAdjustedMetadataKey = "OpenCircuitBasalEnergyRHRAdjusted"

    /// Write one hour of basal (passive) energy. Previously this was a STATIC per-profile constant
    /// (Mifflin-St Jeor ÷ 24) — identical every hour of every day. It's now nudged by how far the
    /// day's MEASURED resting HR (`restingHR`) sits from the person's own recent baseline
    /// (`baselineRestingHR`); pass either as nil to fall back to the static BMR (never zero). Still
    /// an ESTIMATE, labeled as such in metadata.
    func writePassiveCalories(profile: UserProfile, date: Date,
                              restingHR: Double? = nil, baselineRestingHR: Double? = nil) async throws {
        let type = HKQuantityType(.basalEnergyBurned)
        let quantity = HKQuantity(
            unit: .kilocalorie(),
            doubleValue: Calories.basalKcalPerHour(profile: profile,
                                                   restingHR: restingHR,
                                                   baselineRestingHR: baselineRestingHR)
        )
        let adjusted = restingHR != nil && baselineRestingHR != nil
        let sample = HKQuantitySample(
            type: type,
            quantity: quantity,
            start: date,
            end: date.addingTimeInterval(3600),
            metadata: [Self.basalEnergyEstimateMetadataKey: true,
                       Self.basalEnergyRHRAdjustedMetadataKey: adjusted,
                       HKMetadataKeyWasUserEntered: false]
        )
        try await store.save(sample)
    }

    /// Metadata flag marking active-energy samples as a derived ESTIMATE (HR-TRIMP / steps×distance),
    /// NOT a value the ring measured — so Health readers can label or filter it (#82-style).
    static let activeEnergyEstimateMetadataKey = "OpenCircuitActiveEnergyEstimated"

    func writeActiveCalories(kcal: Double, date: Date) async throws {
        guard kcal > 0 else { return }
        let type = HKQuantityType(.activeEnergyBurned)
        let quantity = HKQuantity(unit: .kilocalorie(), doubleValue: kcal)
        let sample = HKQuantitySample(
            type: type,
            quantity: quantity,
            start: date,
            end: date.addingTimeInterval(3600),
            metadata: [Self.activeEnergyEstimateMetadataKey: true,
                       HKMetadataKeyWasUserEntered: false]
        )
        try await store.save(sample)
    }

    func writeActiveCalories(hrSamples: [HRSample], profile: UserProfile, date: Date) async throws {
        let maxHR = max(220 - profile.age, 1)
        let kcal = Calories.activeKcal(hrSamples: hrSamples, maxHR: maxHR)
        try await writeActiveCalories(kcal: kcal, date: date)
    }

    /// One derived resting-HR sample for a day (anchored at start-of-day; HealthKit buckets it
    /// onto that calendar day). Value comes from `RestingHR` (sleep mean → low-activity floor).
    func writeRestingHR(bpm: Double, day: Date) async throws {
        let q = HKQuantity(unit: Self.unit(for: .restingHeartRate), doubleValue: bpm)
        let sample = HKQuantitySample(type: HKQuantityType(.restingHeartRate),
                                      quantity: q, start: day, end: day)
        try await store.save(sample)
    }

    // MARK: Derived-write watermarks (UserDefaults — see flushToHealth)
    //
    // Resting HR and energy are DERIVED, not stored samples, so they can't ride the LocalStore
    // `hk:` cursor (which gates the raw-sample mirror). Each keeps its own idempotency mark in
    // UserDefaults — shared across the foreground + background `HealthKitWriter` instances, and
    // only advanced after a confirmed write, so a failed/unauthorized flush backfills next time.
    private static let rhrWatermarkKey = "hk.restingHR.lastDay"      // start-of-day last written
    private static let basalWatermarkKey = "hk.basalEnergy.nextHour" // first hour not yet written
    private static let activeDayKey = "hk.activeEnergy.day"          // start-of-day of the accumulator
    private static let activeWrittenKey = "hk.activeEnergy.writtenKcal"
    // Exercise minutes (#82) watermark — like active energy, delta-based per day.
    private static let exerciseDayKey     = "hk.exerciseTime.day"         // start-of-day
    private static let exerciseWrittenKey = "hk.exerciseTime.writtenMin"  // total minutes already counted

    // Distance double-count avoidance (steps×stride estimate vs workout GPS).
    // WorkoutSessionManager records foot-based (walk/run/hike) GPS distance written to
    // .distanceWalkingRunning today via `recordWorkoutWalkRunDistance`; the daily steps×stride
    // estimate nets out this GPS distance so the same foot-distance isn't summed twice in
    // Health's "Walking + Running Distance" total. Cycling GPS goes to .distanceCycling, which
    // doesn't overlap the walk/run estimate, so it's never netted. GPS is preferred (the
    // accurate measurement is kept; only the estimate is reduced for the overlapping window).
    static let workoutWalkRunDistanceDayKey    = "hk.workoutWalkRunDistance.day"
    static let workoutWalkRunDistanceMetersKey = "hk.workoutWalkRunDistance.meters"
    static let workoutActiveKcalDayKey         = "hk.workoutActiveKcal.day"
    static let workoutActiveKcalKey            = "hk.workoutActiveKcal.kcal"
    private static let estimateGPSCreditedDayKey    = "hk.distanceEstimate.gpsCreditedDay"
    private static let estimateGPSCreditedMetersKey = "hk.distanceEstimate.gpsCreditedMeters"

    /// Record foot-based workout GPS distance (meters) written to .distanceWalkingRunning today,
    /// so the daily steps×stride estimate can net it out and avoid double counting. Day-keyed.
    static func recordWorkoutWalkRunDistance(_ meters: Double, now: Date = Date(),
                                             _ defaults: UserDefaults = .standard) {
        guard meters > 0 else { return }
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let storedDay = Date(timeIntervalSince1970: defaults.double(forKey: workoutWalkRunDistanceDayKey))
        var total = cal.startOfDay(for: storedDay) == today
            ? defaults.double(forKey: workoutWalkRunDistanceMetersKey) : 0
        total += meters
        defaults.set(today.timeIntervalSince1970, forKey: workoutWalkRunDistanceDayKey)
        defaults.set(total, forKey: workoutWalkRunDistanceMetersKey)
    }

    /// Record workout active energy that was successfully committed to HealthKit. The daily
    /// active-energy estimate uses this to avoid double-counting workout HR that #121 now also
    /// persists into LocalStore for Goals/Trends.
    static func recordWorkoutActiveKcal(_ kcal: Double, day: Date = Date(),
                                        _ defaults: UserDefaults = .standard) {
        guard kcal > 0 else { return }
        let cal = Calendar.current
        let today = cal.startOfDay(for: day)
        let storedDay = Date(timeIntervalSince1970: defaults.double(forKey: workoutActiveKcalDayKey))
        let prior = cal.startOfDay(for: storedDay) == today
            ? defaults.double(forKey: workoutActiveKcalKey) : 0
        defaults.set(today.timeIntervalSince1970, forKey: workoutActiveKcalDayKey)
        defaults.set(prior + kcal, forKey: workoutActiveKcalKey)
    }

    private static func workoutActiveKcalCredited(day today: Date,
                                                  _ defaults: UserDefaults = .standard) -> Double {
        let cal = Calendar.current
        let storedDay = Date(timeIntervalSince1970: defaults.double(forKey: workoutActiveKcalDayKey))
        return cal.startOfDay(for: storedDay) == today
            ? defaults.double(forKey: workoutActiveKcalKey) : 0
    }

    /// Net a completed workout's committed active energy out of today's daily active-energy
    /// estimate. The daily estimate is `max(hrKcal, stepKcal)` — whichever channel is larger for
    /// the day — and the workout ALREADY wrote its own `activeEnergyBurned` sample to Health. So we
    /// subtract the committed workout kcal from the CHOSEN daily estimate, not from one channel:
    ///   • HR-locked outdoor run → HR channel dominates → credit nets the HR side,
    ///   • indoor/treadmill (steps counted, HR sparse) → step channel dominates → credit STILL nets
    ///     (the old "HR side only" netting left indoor sessions double-counted — reviewer #1),
    ///   • distance-derived workout (HR never locked) → credit nets whichever channel is chosen,
    ///     never over-subtracting a channel that never held the workout (reviewer #2).
    /// Clamped at 0 so a workout larger than the whole-day estimate can't push it negative.
    static func netDailyActiveKcalEstimate(hrKcal: Double, stepKcal: Double,
                                           workoutActiveKcal: Double) -> Double {
        let dailyEstimate = max(max(hrKcal, 0), max(stepKcal, 0))
        return max(0, dailyEstimate - max(workoutActiveKcal, 0))
    }

    /// Reduce a raw steps×stride distance estimate by however much workout GPS walk/run distance
    /// hasn't yet been netted out today, preferring the accurate GPS measurement. Returns the
    /// net meters to write (≥ 0) and the reduction applied (to commit after a successful write).
    private static func netDistanceEstimate(_ raw: Double, day today: Date,
                                            _ defaults: UserDefaults = .standard) -> (net: Double, reduction: Double) {
        let cal = Calendar.current
        let gpsDay = Date(timeIntervalSince1970: defaults.double(forKey: workoutWalkRunDistanceDayKey))
        let gpsTotal = cal.startOfDay(for: gpsDay) == today
            ? defaults.double(forKey: workoutWalkRunDistanceMetersKey) : 0
        let creditedDay = Date(timeIntervalSince1970: defaults.double(forKey: estimateGPSCreditedDayKey))
        let credited = cal.startOfDay(for: creditedDay) == today
            ? defaults.double(forKey: estimateGPSCreditedMetersKey) : 0
        let uncredited = max(0, gpsTotal - credited)
        let reduction = min(max(raw, 0), uncredited)
        return (raw - reduction, reduction)
    }

    /// Commit a distance-estimate GPS netting after a successful write (advances the credited
    /// accumulator so the same GPS meters aren't subtracted again on a later flush).
    private static func commitDistanceGPSCredit(_ reduction: Double, day today: Date,
                                                _ defaults: UserDefaults = .standard) {
        guard reduction > 0 else { return }
        let cal = Calendar.current
        let creditedDay = Date(timeIntervalSince1970: defaults.double(forKey: estimateGPSCreditedDayKey))
        let credited = cal.startOfDay(for: creditedDay) == today
            ? defaults.double(forKey: estimateGPSCreditedMetersKey) : 0
        defaults.set(today.timeIntervalSince1970, forKey: estimateGPSCreditedDayKey)
        defaults.set(credited + reduction, forKey: estimateGPSCreditedMetersKey)
    }

    /// A day's resting HR is finalized once the day is ~half over, so a pre-dawn flush can't
    /// freeze a partial-night value, yet last night's RHR still lands the same day (by midday).
    private static let restingFinalizationDelay: TimeInterval = 12 * 3600

    /// Pre-fetch HR samples from LocalStore for a given lookback, returning mapped HRSamples.
    /// Called once per flush cycle; the result is shared across `flushRestingHR` and
    /// `flushPassiveCalories` to avoid redundant LocalStore queries (#172 review, fix #2).
    private static func prefetchHRSamples(local: LocalStore, lookbackDays: Int,
                                           now: Date) -> [HRSample] {
        let cal = Calendar.current
        let from = cal.date(byAdding: .day, value: -lookbackDays, to: cal.startOfDay(for: now))
            ?? now.addingTimeInterval(-Double(lookbackDays) * 86_400)
        guard let stored = try? local.samples(kind: .heartRate, from: from, to: now),
              !stored.isEmpty else { return [] }
        return stored.map { HRSample(bpm: Int($0.value), start: $0.start, end: $0.end) }
    }

    /// Write one resting-HR sample per finalized day not yet covered by the day-watermark.
    /// Uses pre-fetched HR samples (shared with `flushPassiveCalories`) to avoid a redundant
    /// LocalStore query.
    private func flushRestingHR(prefetchedHR: [HRSample], sleepSegments: [SleepSegment]) async -> Int {
        let cal = Calendar.current
        let now = Date()
        let defaults = UserDefaults.standard
        let lastWritten = Date(timeIntervalSince1970: defaults.double(forKey: Self.rhrWatermarkKey))
        let cutoff = now.addingTimeInterval(-Self.restingFinalizationDelay)
        // Bound the scan: never re-read already-written days, and look back at most a week so a
        // first run backfills recent history without an unbounded query.
        let lookback = cal.date(byAdding: .day, value: -7, to: cal.startOfDay(for: now))
            ?? now.addingTimeInterval(-7 * 86_400)
        let scanStart = max(lookback, lastWritten)
        let hr = prefetchedHR.filter { $0.start >= scanStart }
        guard !hr.isEmpty else { return 0 }
        let days = RestingHR.dailyValues(hr: hr, sleep: sleepSegments, calendar: cal)

        var written = 0
        var newWatermark = lastWritten
        for d in days where d.day > lastWritten && d.day <= cutoff {  // days ascend
            do {
                try await writeRestingHR(bpm: d.bpm, day: d.day)
                written += 1
                newWatermark = d.day
            } catch { pendingFlushFailures.insert(.restingHeartRate); break }  // surface; stop, already-written days stay covered
        }
        if newWatermark > lastWritten {
            defaults.set(newWatermark.timeIntervalSince1970, forKey: Self.rhrWatermarkKey)
        }
        return written
    }

    /// How far back the basal-energy path reads daily resting HR: enough to hold the personal
    /// baseline window plus the couple of days an hourly backfill can touch. Bounds the query.
    private static let basalRHRLookbackDays = 32

    /// Write basal (passive) energy for each completed hour since the watermark, returning the
    /// count. First run starts the meter at the current hour (no historical flood); a long gap
    /// is clamped to the last ~24 hours.
    ///
    /// Basal energy is no longer a static per-profile constant: each hour is nudged by the MEASURED
    /// resting HR for the calendar day it belongs to, judged against the person's own prior-day
    /// baseline. Uses pre-fetched HR samples (shared with `flushRestingHR`) and derives daily RHR
    /// WITHOUT sleep segments so all days in the window use the same `lowestSustained` method —
    /// ensuring derivation parity between today and the baseline (#172 review, fix #1).
    /// Days with no RHR or too little baseline history fall back to the static per-hour BMR.
    private func flushPassiveCalories(profile: UserProfile,
                                      prefetchedHR: [HRSample]) async -> Int {
        let cal = Calendar.current
        let defaults = UserDefaults.standard
        let now = Date()
        let currentHour = Self.startOfHour(now)
        let stored = defaults.double(forKey: Self.basalWatermarkKey)
        var hour = stored == 0 ? currentHour : Date(timeIntervalSince1970: stored)
        hour = max(hour, currentHour.addingTimeInterval(-24 * 3600))  // clamp a long gap

        // Per-calendar-day resting HR over the baseline window (empty on missing/thin data → the
        // loop below simply degrades to static BMR for those hours).
        let dailyRHR = Self.dailyRestingHR(prefetchedHR: prefetchedHR, now: now, calendar: cal)

        var written = 0
        while hour < currentHour {
            let (rhr, baseline) = Self.restingEnergyInputs(forDay: cal.startOfDay(for: hour),
                                                           from: dailyRHR)
            do {
                try await writePassiveCalories(profile: profile, date: hour,
                                               restingHR: rhr, baselineRestingHR: baseline)
                written += 1
                hour = hour.addingTimeInterval(3600)
            } catch { break }  // leave the watermark at the failed hour; retry next flush
        }
        // `hour` now points at the first hour still unwritten (currentHour when all succeeded).
        if hour.timeIntervalSince1970 > stored {
            defaults.set(hour.timeIntervalSince1970, forKey: Self.basalWatermarkKey)
        }
        return written
    }

    /// Per-calendar-day resting HR (bpm), oldest day first. Derives daily RHR from pre-fetched
    /// HR samples using the `lowestSustained` path for ALL days (sleep segments intentionally
    /// omitted). This ensures derivation parity between today's RHR and the baseline: the flush
    /// receives `sleepSegments` covering only the most recent night, so passing them would make
    /// today use `sleepMean` while baseline days fall to `lowestSustained` — a systematic offset
    /// in the (today − baseline) delta that the ±20% clamp bounds but doesn't eliminate.
    /// By using `lowestSustained` uniformly, both sides of the comparison are on the same basis.
    ///
    /// NOTE (expected, not a bug): the RHR this produces to SCALE basal energy (`lowestSustained`,
    /// sleep omitted) intentionally will NOT match the daily resting-HR SAMPLE written to Health by
    /// `flushRestingHR`, which passes `sleepSegments` and so uses the sleep-mean for the most recent
    /// night. Basal-energy scaling wants a uniform, sleep-independent signal across the whole
    /// baseline window (derivation parity, above); the displayed daily RHR wants the clinically
    /// familiar sleeping resting-HR. So the internal driver and the shown metric are two different
    /// derivations by design — the divergence is expected, not a discrepancy to reconcile.
    static func dailyRestingHR(prefetchedHR: [HRSample],
                                       now: Date, calendar cal: Calendar) -> [RestingHR.DailyValue] {
        guard !prefetchedHR.isEmpty else { return [] }
        return RestingHR.dailyValues(hr: prefetchedHR, sleep: [], calendar: cal)
    }

    /// Resolve `(day's measured RHR, personal baseline)` for one calendar `day` from ascending
    /// daily values. RHR is that day's value (nil when the day has none); baseline is the trimmed
    /// mean of PRIOR days' values, or nil below the trusted minimum. Either nil ⇒ caller uses
    /// static BMR.
    static func restingEnergyInputs(forDay day: Date,
                                            from daily: [RestingHR.DailyValue])
        -> (restingHR: Double?, baseline: Double?) {
        guard let today = daily.first(where: { $0.day == day })?.bpm else { return (nil, nil) }
        let prior = daily.filter { $0.day < day }.map(\.bpm)
        return (today, Calories.restingBaselineBpm(prior: prior))
    }

    /// Write today's active-energy DELTA (today's HR-derived TRIMP kcal minus what's already
    /// been written today), returning the kcal written. HealthKit SUMS activeEnergyBurned, so
    /// writing the delta lands the running daily total without re-adding it each flush.
    private func flushActiveCalories(local: LocalStore, profile: UserProfile) async -> Double {
        let cal = Calendar.current
        let now = Date()
        let today = cal.startOfDay(for: now)
        let defaults = UserDefaults.standard
        let storedDay = Date(timeIntervalSince1970: defaults.double(forKey: Self.activeDayKey))
        var written = defaults.double(forKey: Self.activeWrittenKey)
        if cal.startOfDay(for: storedDay) != today { written = 0 }  // new day → reset accumulator

        // HR-derived TRIMP active energy. Sparse by nature — usually ~0 without dense daytime HR,
        // which is exactly why a day with walking used to show 0 active calories. Kept as one
        // input; never widened/fabricated.
        let hr = (try? local.samples(kind: .heartRate, from: today, to: now)) ?? []
        let hrSamples = hr.map { HRSample(bpm: Int($0.value), start: $0.start, end: $0.end) }
        let maxHR = max(220 - profile.age, 1)
        let hrKcal = hrSamples.isEmpty ? 0 : Calories.activeKcal(hrSamples: hrSamples, maxHR: maxHR)

        // Step/distance-derived estimate — works even with no HR. The workout's foot-distance is
        // netted out of the daily estimate below (via the committed workout kcal), so no per-channel
        // distance netting is needed here.
        let steps = (try? local.todaySteps(day: today)) ?? 0
        let stepKcal = Calories.activeKcalFromSteps(steps: steps, profile: profile)

        // #121 started persisting workout HR into LocalStore for Goals/Trends, and workouts also
        // write their own activeEnergyBurned sample. Subtract the committed workout active kcal from
        // whichever daily channel (HR or step) is chosen, so both HR-locked and indoor/step-only
        // workouts are netted exactly once (see `netDailyActiveKcalEstimate`).
        let total = Self.netDailyActiveKcalEstimate(
            hrKcal: hrKcal,
            stepKcal: stepKcal,
            workoutActiveKcal: Self.workoutActiveKcalCredited(day: today)
        )
        let delta = total - written
        guard delta >= 1.0 else {  // ignore sub-kcal churn; still persist the (reset) day marker
            defaults.set(today.timeIntervalSince1970, forKey: Self.activeDayKey)
            defaults.set(written, forKey: Self.activeWrittenKey)
            return 0
        }
        do {
            try await writeActiveCalories(kcal: delta, date: today)
            defaults.set(today.timeIntervalSince1970, forKey: Self.activeDayKey)
            defaults.set(total, forKey: Self.activeWrittenKey)
            return delta
        } catch { pendingFlushFailures.insert(.activeEnergy); return 0 }
    }

    /// The user's body profile, read from the shared `@AppStorage` keys (the same keys
    /// `UserProfileSettingsView`/`CaloriesCardView` use — keep these defaults in sync). Feeds the
    /// BMR/TRIMP energy estimates; the ring transmits none of these inputs.
    static func storedUserProfile(_ defaults: UserDefaults = .standard) -> UserProfile {
        let age = defaults.object(forKey: "userProfile.age") as? Int ?? 35
        let weightKg = defaults.object(forKey: "userProfile.weightKg") as? Double ?? 70
        let heightCm = defaults.object(forKey: "userProfile.heightCm") as? Double ?? 170
        let sexRaw = defaults.string(forKey: "userProfile.sex") ?? BiologicalSex.male.rawValue
        return UserProfile(age: age, weightKg: max(weightKg, 1), heightCm: max(heightCm, 1),
                           sex: BiologicalSex(rawValue: sexRaw) ?? .male)
    }

    private static func startOfHour(_ date: Date, _ cal: Calendar = .current) -> Date {
        cal.date(from: cal.dateComponents([.year, .month, .day, .hour], from: date)) ?? date
    }

    /// Write today's exercise-minute DELTA (elevated-HR minutes not yet pushed to Health),
    /// returning minutes written. ESTIMATE — basic 50% maxHR threshold (#82).
    /// Full 4-level intensity (Vigorous/Moderate/Low/Inactive) follows the activity-epoch
    /// decode (#93). Uses a per-day UserDefaults accumulator identical to active energy.
    private func flushExerciseMinutes(local: LocalStore, profile: UserProfile) async -> Double {
        let cal = Calendar.current
        let now = Date()
        let today = cal.startOfDay(for: now)
        let defaults = UserDefaults.standard
        let storedDay = Date(timeIntervalSince1970: defaults.double(forKey: Self.exerciseDayKey))
        var writtenMin = defaults.double(forKey: Self.exerciseWrittenKey)
        if cal.startOfDay(for: storedDay) != today { writtenMin = 0 }

        guard let rawSamples = try? local.samples(kind: .heartRate, from: today, to: now),
              !rawSamples.isEmpty else {
            defaults.set(today.timeIntervalSince1970, forKey: Self.exerciseDayKey)
            defaults.set(writtenMin, forKey: Self.exerciseWrittenKey)
            return 0
        }
        // Exclude the latest detected sleep window so sleeping elevated HR doesn't count.
        let sleepWindow: DateInterval? = (try? local.latestSleepSummary()).flatMap { s in
            guard s.inBedStart > Date.distantPast else { return nil }
            return DateInterval(start: s.inBedStart, end: s.inBedEnd)
        }
        let hrSamples = rawSamples.map { HRSample(bpm: Int($0.value), start: $0.start, end: $0.end) }
        let maxHR = max(220 - profile.age, 1)
        let totalMin = ExerciseMinutes.estimate(hrSamples: hrSamples, maxHR: maxHR,
                                                sleepWindow: sleepWindow)
        let pendingMin = totalMin - writtenMin
        guard pendingMin >= 1.0 else {
            defaults.set(today.timeIntervalSince1970, forKey: Self.exerciseDayKey)
            defaults.set(writtenMin, forKey: Self.exerciseWrittenKey)
            return 0
        }
        // Apple Exercise Time is Apple-computed and not third-party writable (saving it errors,
        // and requesting share auth for it crashes — see `quantityType(for:)`). So the estimate
        // is surfaced in-app only and is NOT mirrored to Apple Health; advance the day watermark
        // so the running total stays correct. Contributing to the Exercise ring needs HKWorkout (#93).
        defaults.set(today.timeIntervalSince1970, forKey: Self.exerciseDayKey)
        defaults.set(totalMin, forKey: Self.exerciseWrittenKey)
        return pendingMin
    }

    /// Write a night as contiguous sleepAnalysis category samples (mapping notes).
    func write(sleep segments: [SleepSegment]) async throws {
        let type = HKCategoryType(.sleepAnalysis)
        let samples = segments.map { seg in
            HKCategorySample(type: type, value: Self.sleepValue(seg.stage).rawValue,
                             start: seg.start, end: seg.end)
        }
        guard !samples.isEmpty else { return }
        try await store.save(samples)
    }

    static func sleepValue(_ stage: SleepStage) -> HKCategoryValueSleepAnalysis {
        switch stage {
        case .inBed: return .inBed
        case .awake: return .awake
        case .asleepCore: return .asleepCore
        case .asleepDeep: return .asleepDeep
        case .asleepREM: return .asleepREM
        }
    }

    /// Write one correlated blood-pressure estimate to Apple Health.
    @discardableResult
    func writeBPEstimate(sbp: Double, dbp: Double, at date: Date) async -> Bool {
        let metadata: [String: Any] = ["OpenCircuitBPSource": "RingPPGCalibration"]
        let mmHg = HKUnit.millimeterOfMercury()
        let systolic = HKQuantitySample(
            type: Self.systolicType,
            quantity: HKQuantity(unit: mmHg, doubleValue: sbp),
            start: date,
            end: date,
            metadata: metadata
        )
        let diastolic = HKQuantitySample(
            type: Self.diastolicType,
            quantity: HKQuantity(unit: mmHg, doubleValue: dbp),
            start: date,
            end: date,
            metadata: metadata
        )
        let correlation = HKCorrelation(
            type: Self.bloodPressureType,
            start: date,
            end: date,
            objects: [systolic, diastolic],
            metadata: metadata
        )
        do {
            try await store.save(correlation)
            return true
        } catch {
            return false
        }
    }
}

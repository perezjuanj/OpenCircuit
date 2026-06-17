import Foundation
import HealthKit
import OpenRingKit

// Writes ring metrics into Apple Health. Type/unit choices follow
// docs/HEALTHKIT_MAPPING.md. Samples are saved with the device's own timestamps
// so history backfills; a stable bundle id + the SyncCursor avoid duplicates.

@MainActor
final class HealthKitWriter {
    private let store = HKHealthStore()
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
        // Skin temp is captured ONLY during the nightly sleep window (RingSession), so a
        // rest-oriented type is the right home — NOT clinical `.bodyTemperature`, whose chart a
        // skin reading (~5 °C below oral/core) would pollute (#29). The ideal sleeping-wrist type
        // (`.appleSleepingWristTemperature`) is Apple-COMPUTED and read-only for third parties:
        // it can't be save()d, and putting it in the `toShare` set of `requestAuthorization`
        // raises NSInvalidArgumentException, which would crash auth or — swallowed by the
        // call-site `try?` — silently disable EVERY metric's writeback. So we use the writable,
        // rest-scoped `.basalBodyTemperature` instead. Units stay °C (see `unit(for:)`).
        case .temperature: id = .basalBodyTemperature
        case .respiratoryRate: id = .respiratoryRate
        case .steps: id = .stepCount
        case .activeEnergy: id = .activeEnergyBurned
        case .sleep: return nil
        // ESTIMATE — steps × stride. See DistanceEstimate.swift for the derivation (#81).
        case .distance: id = .distanceWalkingRunning
        // ESTIMATE — elevated HR minutes. Basic threshold; 4-level intensity follows #93 (#82).
        case .exerciseMinutes: id = .appleExerciseTime
        }
        return HKQuantityType(id)
    }

    /// HKUnit matching MetricKind.unit (the canonical units in OpenRingKit).
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
        case .distance: return .meter()              // ESTIMATE — steps × stride
        case .exerciseMinutes: return .minute()      // ESTIMATE — elevated HR minutes
        }
    }

    private var allTypes: Set<HKSampleType> {
        var set = Set<HKSampleType>()
        for k in MetricKind.allCases {
            if let t = Self.quantityType(for: k) { set.insert(t) }
        }
        set.insert(HKQuantityType(.basalEnergyBurned))
        set.insert(HKCategoryType(.sleepAnalysis))
        // Workout types (#75): HKWorkout + GPS route (workout sessions feature).
        set.insert(HKWorkoutType.workoutType())
        set.insert(HKSeriesType.workoutRoute())
        // Women's health (#78): user-logged period flow written to Health.
        // NOTE: temperature is NOT added here — it already ships via the canonical
        // `.basalBodyTemperature` path (MetricKind.temperature). No triple-write.
        set.insert(HKCategoryType(.menstrualFlow))
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
        var wroteAnything: Bool {
            samples > 0 || sleepSegments > 0 || steps > 0
                || restingDays > 0 || passiveHours > 0 || activeKcal > 0 || naps > 0
                || distanceM > 0 || exerciseMinutes > 0 || menstrualFlowEntries > 0
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

        // Scalars: write, THEN advance the watermark, so a failed save backfills next time.
        if let pending = try? store.pendingHealthSamples(), !pending.isEmpty {
            do { try await write(pending); try store.markHealthWritten(pending); result.samples = pending.count }
            catch { /* leave the watermark; retry next flush */ }
        }
        // Sleep: same write-then-mark order (a failed save must not lose the night).
        if let pendingSleep = try? store.pendingHealthSleep(sleepSegments), !pendingSleep.isEmpty {
            do { try await write(sleep: pendingSleep); try store.markSleepWritten(pendingSleep); result.sleepSegments = pendingSleep.count }
            catch { /* leave the .sleep cursor; retry next flush */ }
        }
        // Naps (#76): each carries its own `healthWritten` flag (NOT the night's `.sleep` cursor),
        // so a daytime nap and the overnight night write independently and never collide.
        result.naps = await flushNaps(store: store)

        // Women's health (#78): write pending user-logged period flow entries to Health.
        // Gated by each entry's own `healthWritten` flag — independent of all other writes.
        result.menstrualFlowEntries = await flushMenstrualFlow(localStore: store)

        // Profile is used for distance stride + calorie TRIMP — resolved once here so all three
        // derived writes use the same snapshot. Body inputs come from the shared profile defaults;
        // the ring transmits none of them.
        let profile = Self.storedUserProfile()

        // Steps + distance estimate (#81): write both atomically from the same pending delta.
        // HealthKit SUMS stepCount / distanceWalkingRunning, so writing the delta lands the
        // day's running total without re-adding on every sync. Distance is an ESTIMATE
        // (steps × height-based stride — not GPS) and is labeled as such in HealthKit metadata.
        if let delta = try? store.pendingStepDelta(), delta > 0 {
            let startOfDay = Calendar.current.startOfDay(for: Date())
            let distanceM = DistanceEstimate.meters(steps: delta, profile: profile)
            var toWrite: [QuantitySample] = [
                QuantitySample(kind: .steps, start: startOfDay, end: Date(), value: Double(delta))
            ]
            if distanceM > 0 {
                toWrite.append(QuantitySample(kind: .distance, start: startOfDay, end: Date(), value: distanceM))
            }
            do {
                try await write(toWrite)
                try store.advanceStepsWritten(by: delta)
                result.steps = delta
                result.distanceM = distanceM
            } catch { /* leave the watermark; retry next flush */ }
        }
        // Derived daily resting HR — one sample per finalized day (#18, #37). Idempotency is a
        // UserDefaults day-watermark, NOT the store cursor: RHR isn't a stored sample, and the
        // `hk:` cursor rows belong to the raw-sample mirror above.
        result.restingDays = await flushRestingHR(local: store, sleepSegments: sleepSegments)

        // Energy: passive (hourly BMR) + active (HR-derived Edwards TRIMP). Watermark-gated (#37).
        result.passiveHours = await flushPassiveCalories(profile: profile)
        result.activeKcal = await flushActiveCalories(local: store, profile: profile)

        // Exercise minutes estimate (#82): elevated-HR minutes outside the sleep window.
        // ESTIMATE — basic 50% maxHR threshold. Full 4-level intensity follows #93 decode.
        result.exerciseMinutes = await flushExerciseMinutes(local: store, profile: profile)

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
            let segs = [
                SleepSegment(start: nap.start, end: nap.end, stage: .inBed),
                SleepSegment(start: nap.start, end: nap.end, stage: .asleepCore),
            ]
            do {
                try await write(sleep: segs)
                try store.markNapWritten(start: nap.start)
                written += 1
            } catch { break }   // stop on first failure; unwritten naps retry next flush
        }
        return written
    }

    /// Write pending user-logged period flow entries to Apple Health as
    /// `menstrualFlow` category samples, returning the count written.
    /// Each entry is gated by its own `healthWritten` flag — independent of
    /// all other HK writes. One HKCategorySample per period entry spanning
    /// start…end (or start + 5 days when no end is logged yet).
    /// `HKMetadataKeyMenstrualCycleStart: true` marks each as the first day
    /// of a new cycle (period start = cycle start). (#78)
    private func flushMenstrualFlow(localStore: LocalStore) async -> Int {
        guard let pending = try? localStore.pendingPeriodEntries(), !pending.isEmpty else { return 0 }
        var written = 0
        for entry in pending {
            do {
                try await writeMenstrualFlow(entry: entry)
                try localStore.markPeriodEntryWritten(start: entry.start)
                written += 1
            } catch { break }   // stop on first failure; unwritten entries retry next flush
        }
        return written
    }

    /// Write a single `menstrualFlow` category sample for a period entry.
    private func writeMenstrualFlow(entry: StoredPeriodEntry) async throws {
        let type = HKCategoryType(.menstrualFlow)
        // Map app flow level to HKCategoryValueMenstrualFlow.
        let flowValue: HKCategoryValueMenstrualFlow
        switch entry.flowLevelRaw {
        case 1: flowValue = .light
        case 3: flowValue = .heavy
        default: flowValue = .medium
        }
        // Use logged end date, or start + 5 days as a sensible stand-in when the
        // user hasn't closed the period yet. HK only stores what the user logged.
        let endDate = entry.end ?? entry.start.addingTimeInterval(5 * 86_400)
        let sample = HKCategorySample(
            type: type,
            value: flowValue.rawValue,
            start: entry.start,
            end: endDate,
            metadata: [
                // Mark the first day of the period as the first day of the cycle.
                HKMetadataKeyMenstrualCycleStart: true,
            ]
        )
        try await store.save(sample)
    }

    func requestAuthorization() async throws {
        // Read sleepAnalysis so the iOS Sleep-schedule window (HealthKitSleepSchedule) works
        // the moment the HealthKit entitlement is enabled — no further auth change needed.
        // (No effect today: without the entitlement the request is a no-op, so it can't prompt.)
        let read: Set<HKObjectType> = [HKCategoryType(.sleepAnalysis)]
        // Every type in `allTypes` is deliberately third-party-WRITABLE (that's why `.temperature`
        // maps to `.basalBodyTemperature`, not the read-only `.appleSleepingWristTemperature`) —
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

    /// Write scalar samples. Caller filters with SyncCursor first.
    func write(_ samples: [QuantitySample]) async throws {
        let hkSamples: [HKQuantitySample] = samples.compactMap { s in
            guard let type = Self.quantityType(for: s.kind) else { return nil }
            let q = HKQuantity(unit: Self.unit(for: s.kind), doubleValue: s.value)
            return HKQuantitySample(type: type, quantity: q, start: s.start, end: s.end,
                                    metadata: Self.metadata(for: s.kind))
        }
        guard !hkSamples.isEmpty else { return }
        try await store.save(hkSamples)
    }

    /// Metadata key on HRV samples flagging which statistic the value actually is.
    static let hrvStatisticMetadataKey = "OpenRingConnHRVStatistic"

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
                                "OpenRingConnDistanceSource": "steps×stride-estimate"]
        default: return nil
        }
    }

    func writePassiveCalories(profile: UserProfile, date: Date) async throws {
        let type = HKQuantityType(.basalEnergyBurned)
        let quantity = HKQuantity(
            unit: .kilocalorie(),
            doubleValue: Calories.bmrKcalPerHour(profile: profile)
        )
        let sample = HKQuantitySample(
            type: type,
            quantity: quantity,
            start: date,
            end: date.addingTimeInterval(3600)
        )
        try await store.save(sample)
    }

    func writeActiveCalories(kcal: Double, date: Date) async throws {
        guard kcal > 0 else { return }
        let type = HKQuantityType(.activeEnergyBurned)
        let quantity = HKQuantity(unit: .kilocalorie(), doubleValue: kcal)
        let sample = HKQuantitySample(
            type: type,
            quantity: quantity,
            start: date,
            end: date.addingTimeInterval(3600)
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
    private static let exerciseWrittenKey = "hk.exerciseTime.writtenMin"  // total minutes already pushed
    // Metadata key for estimated exercise time samples
    static let exerciseEstimateMetadataKey = "OpenRingConnExerciseTimeEstimated"
    /// A day's resting HR is finalized once the day is ~half over, so a pre-dawn flush can't
    /// freeze a partial-night value, yet last night's RHR still lands the same day (by midday).
    private static let restingFinalizationDelay: TimeInterval = 12 * 3600

    /// Write one resting-HR sample per finalized day not yet covered by the day-watermark.
    /// Reads HR straight from the store (the dashboard's source) via its public accessor.
    private func flushRestingHR(local: LocalStore, sleepSegments: [SleepSegment]) async -> Int {
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
        guard let stored = try? local.samples(kind: .heartRate, from: scanStart, to: now),
              !stored.isEmpty else { return 0 }
        let hr = stored.map { HRSample(bpm: Int($0.value), start: $0.start, end: $0.end) }
        let days = RestingHR.dailyValues(hr: hr, sleep: sleepSegments, calendar: cal)

        var written = 0
        var newWatermark = lastWritten
        for d in days where d.day > lastWritten && d.day <= cutoff {  // days ascend
            do {
                try await writeRestingHR(bpm: d.bpm, day: d.day)
                written += 1
                newWatermark = d.day
            } catch { break }  // stop at the first failure; already-written days stay covered
        }
        if newWatermark > lastWritten {
            defaults.set(newWatermark.timeIntervalSince1970, forKey: Self.rhrWatermarkKey)
        }
        return written
    }

    /// Write basal (passive) energy for each completed hour since the watermark, returning the
    /// count. First run starts the meter at the current hour (no historical flood); a long gap
    /// is clamped to the last ~24 hours.
    private func flushPassiveCalories(profile: UserProfile) async -> Int {
        let defaults = UserDefaults.standard
        let now = Date()
        let currentHour = Self.startOfHour(now)
        let stored = defaults.double(forKey: Self.basalWatermarkKey)
        var hour = stored == 0 ? currentHour : Date(timeIntervalSince1970: stored)
        hour = max(hour, currentHour.addingTimeInterval(-24 * 3600))  // clamp a long gap

        var written = 0
        while hour < currentHour {
            do {
                try await writePassiveCalories(profile: profile, date: hour)
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

        guard let stored = try? local.samples(kind: .heartRate, from: today, to: now),
              !stored.isEmpty else {
            defaults.set(today.timeIntervalSince1970, forKey: Self.activeDayKey)
            defaults.set(written, forKey: Self.activeWrittenKey)
            return 0
        }
        let hr = stored.map { HRSample(bpm: Int($0.value), start: $0.start, end: $0.end) }
        let maxHR = max(220 - profile.age, 1)
        let total = Calories.activeKcal(hrSamples: hr, maxHR: maxHR)
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
        } catch { return 0 }
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
        do {
            let type = HKQuantityType(.appleExerciseTime)
            let qty = HKQuantity(unit: .minute(), doubleValue: pendingMin)
            // Tag as estimated so Health readers know this came from a basic HR threshold,
            // NOT the ring's native activity-intensity sensor data (#93).
            let sample = HKQuantitySample(type: type, quantity: qty, start: today, end: now,
                                          metadata: [Self.exerciseEstimateMetadataKey: true])
            try await store.save(sample)
            defaults.set(today.timeIntervalSince1970, forKey: Self.exerciseDayKey)
            defaults.set(totalMin, forKey: Self.exerciseWrittenKey)
            return pendingMin
        } catch { return 0 }
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
}

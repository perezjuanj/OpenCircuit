// WorkoutSession.swift — Pure workout analytics: HR-zone classification, time-in-zone,
// session aggregation. No HealthKit or CoreLocation imports; all app-framework concerns
// stay in the app target.
//
// Zones are "Zone 1" … "Zone 5". Where each starts comes from `HeartRateZones` (decision 83: % of
// max heart rate 50/60/70/80/90 by default, % of reserve, or custom bounds); data below zone 1's
// lower bound is not counted. Max heart rate is `220 − age` unless the user typed one.
//
// Live-HR (#45) WARNING: The 0x95→0x15 live-HR path is best-effort — it has no
// background-refresh and on-demand polling often misses updates. A long workout
// session is the worst case. This code records only ACTUAL decoded readings; it
// never fills gaps by interpolation or fabrication. Gaps are preserved and surfaced
// to the user. See issue #45 for the underlying reliability constraint.

import Foundation

// MARK: - Sport types

/// Sport types the app supports. Each maps to an HKWorkoutActivityType on the app side.
/// Outdoor types (walking, running, cycling, hiking) enable GPS route capture via
/// CoreLocation; indoor types (strength, yoga, other) do not.
public enum WorkoutSportType: String, Codable, CaseIterable, Sendable {
    case walkingOutdoor
    case walkingIndoor
    case runningOutdoor
    case runningIndoor
    case cyclingOutdoor
    case cyclingIndoor
    case rowing
    case hiking
    case strengthTraining
    case yoga
    case other

    public var displayName: String {
        switch self {
        case .walkingOutdoor: return "Outdoor Walking"
        case .walkingIndoor:  return "Indoor Walking"
        case .runningOutdoor: return "Outdoor Running"
        case .runningIndoor:  return "Indoor Running"
        case .cyclingOutdoor: return "Outdoor Cycling"
        case .cyclingIndoor:  return "Indoor Cycling"
        case .rowing:         return "Indoor Rowing"
        case .hiking:         return "Hiking"
        case .strengthTraining: return "Strength"
        case .yoga:           return "Yoga"
        case .other:          return "Other"
        }
    }

    /// Whether this sport type benefits from GPS route capture (phone-side CoreLocation).
    /// For indoor types, no route is captured even when location permission is granted.
    public var isOutdoor: Bool {
        switch self {
        case .walkingOutdoor, .runningOutdoor, .cyclingOutdoor, .hiking: return true
        case .walkingIndoor, .runningIndoor, .cyclingIndoor, .rowing, .strengthTraining, .yoga, .other: return false
        }
    }

    public var systemImageName: String {
        switch self {
        case .walkingOutdoor:    return "figure.walk"
        case .walkingIndoor:     return "figure.walk.treadmill"
        case .runningOutdoor:    return "figure.run"
        case .runningIndoor:     return "figure.run.treadmill"
        case .cyclingOutdoor:    return "bicycle"
        case .cyclingIndoor:     return "figure.indoor.cycle"
        case .rowing:            return "figure.rower"
        case .hiking:            return "mountain.2"
        case .strengthTraining:  return "dumbbell"
        case .yoga:              return "figure.yoga"
        case .other:             return "heart.circle"
        }
    }

    /// The ring's native sport-mode type byte for `Command.sportStart` (🟢 #90). Types the ring
    /// doesn't natively support (hiking/strength/other) map to the closest ring mode — the byte
    /// only tunes the ring's own HR sampling; the HealthKit activity type is chosen separately.
    public var firmwareByte: UInt8 {
        switch self {
        case .runningOutdoor:   return SportType.outdoorRunning.rawValue   // 0x01
        case .walkingOutdoor:   return SportType.outdoorWalking.rawValue   // 0x02
        case .walkingIndoor:    return SportType.outdoorWalking.rawValue   // 0x02 — ring has no indoor-walk code
        case .runningIndoor:    return SportType.indoorRunning.rawValue    // 0x03
        case .cyclingOutdoor:   return SportType.outdoorCycling.rawValue   // 0x04
        case .cyclingIndoor:    return SportType.indoorCycling.rawValue    // 0x05
        case .rowing:           return SportType.indoorRowing.rawValue     // 0x06
        case .yoga:             return SportType.yoga.rawValue             // 0x07
        case .hiking:           return SportType.outdoorWalking.rawValue   // ≈ outdoor walk
        case .strengthTraining, .other: return SportType.yoga.rawValue     // ≈ generic indoor
        }
    }
}

// MARK: - HR Zones

/// The five heart-rate zones. They are named "Zone 1" … "Zone 5" everywhere (decision 83a); the case
/// names are historical (they match the stored `WorkoutZoneBreakdown` fields and must not change
/// without a migration). Where a zone starts is NOT a property of the zone: it comes from the user's
/// `HeartRateZones`.
public enum HRZone: Int, CaseIterable, Sendable {
    case warmUp    = 1
    case fatBurn   = 2
    case aerobic   = 3
    case anaerobic = 4
    case extreme   = 5

    /// "Zone 1" … "Zone 5".
    public var displayName: String { "Zone \(rawValue)" }

    /// Color token names (used in the app UI; resolved in SwiftUI).
    public var colorName: String {
        switch self {
        case .warmUp:    return "zoneBlue"
        case .fatBurn:   return "zoneGreen"
        case .aerobic:   return "zoneYellow"
        case .anaerobic: return "zoneOrange"
        case .extreme:   return "zoneRed"
        }
    }
}

// MARK: - Zone classifier

/// Pure functions for HR zone classification and time-in-zone accumulation.
public enum HRZoneClassifier {

    /// Classify a single BPM reading against the user's zones, returning the zone (or nil below
    /// zone 1's lower bound: those readings are not counted in the zone distribution, 83e).
    public static func zone(bpm: Int, zones: HeartRateZones) -> HRZone? {
        zones.zone(bpm: bpm)
    }

    /// The default zones (50/60/70/80/90 % of `maxHR`). For code that has only a max heart rate; the
    /// app always classifies with the user's `HeartRateZones`.
    public static func zone(bpm: Int, maxHR: Int) -> HRZone? {
        guard maxHR > 0 else { return nil }
        return zone(bpm: bpm, zones: HeartRateZones(percentOfMax: maxHR))
    }

    /// Accumulate time (seconds) spent in each zone from a list of timestamped HR samples.
    /// Only actual decoded readings are counted — no gap filling, no interpolation.
    /// Gaps between samples (e.g. polling misses due to #45 flakiness) are NOT attributed
    /// to any zone; the duration used for each sample is the sample's own interval
    /// (end - start), defaulting to 0 if end == start (instantaneous reading).
    public static func timeInZones(
        hrSamples: [HRSample],
        zones: HeartRateZones
    ) -> WorkoutZoneBreakdown {
        var seconds = [HRZone: Double]()
        for z in HRZone.allCases { seconds[z] = 0 }
        for sample in hrSamples {
            let dur = sample.end.timeIntervalSince(sample.start)
            guard dur > 0, let zone = zones.zone(bpm: sample.bpm) else { continue }
            seconds[zone, default: 0] += dur
        }
        return WorkoutZoneBreakdown(secondsInZone: seconds)
    }

    /// `timeInZones` over the default zones for `maxHR`.
    public static func timeInZones(hrSamples: [HRSample], maxHR: Int) -> WorkoutZoneBreakdown {
        timeInZones(hrSamples: hrSamples, zones: HeartRateZones(percentOfMax: max(maxHR, 1)))
    }

    /// Default cap for a single reading's held interval (seconds). The sport stream lands ~every 10 s,
    /// so 30 s absorbs a missed reading or jitter while refusing to invent zone time across a genuine
    /// dropout (ring off-wrist / lost link).
    public static let defaultHoldCapSeconds: Double = 30

    /// Time-in-zone using STEP-FUNCTION (last-value-held) attribution — the fix for zone totals reading
    /// far short of the workout (e.g. 0:50 for a 5:05 ride). The ring reports HR PERIODICALLY (~every
    /// 10 s in sport mode), so each reading represents the interval it covers, not just the ~2 s poll
    /// window it was stamped with. Each sample is held until the NEXT sample's timestamp; the final
    /// sample is held until `sessionEnd`.
    ///
    /// Every held interval is CAPPED at `maxGapSeconds` (default `defaultHoldCapSeconds`) so a real
    /// dropout is never fabricated into zone time — the total stays honest: ≈ the workout duration when
    /// HR is continuous, and legitimately less when readings were actually missed. Time before the
    /// first reading is not attributed (no zone is assumed before any data). Readings below zone 1
    /// contribute no zone time. Samples are sorted by start; pure and unit-testable.
    public static func timeInZonesHeld(
        hrSamples: [HRSample],
        zones: HeartRateZones,
        sessionEnd: Date,
        maxGapSeconds: Double = defaultHoldCapSeconds
    ) -> WorkoutZoneBreakdown {
        var seconds = [HRZone: Double]()
        for z in HRZone.allCases { seconds[z] = 0 }
        let sorted = hrSamples.sorted { $0.start < $1.start }
        for (i, sample) in sorted.enumerated() {
            let nextAnchor = (i + 1 < sorted.count) ? sorted[i + 1].start : sessionEnd
            let held = min(max(nextAnchor.timeIntervalSince(sample.start), 0), maxGapSeconds)
            guard held > 0, let zone = zones.zone(bpm: sample.bpm) else { continue }
            seconds[zone, default: 0] += held
        }
        return WorkoutZoneBreakdown(secondsInZone: seconds)
    }
}

extension HRZoneClassifier {
    /// `timeInZonesHeld` over the default zones for `maxHR`.
    public static func timeInZonesHeld(
        hrSamples: [HRSample],
        maxHR: Int,
        sessionEnd: Date,
        maxGapSeconds: Double = defaultHoldCapSeconds
    ) -> WorkoutZoneBreakdown {
        timeInZonesHeld(hrSamples: hrSamples, zones: HeartRateZones(percentOfMax: max(maxHR, 1)),
                        sessionEnd: sessionEnd, maxGapSeconds: maxGapSeconds)
    }
}

// MARK: - Zone breakdown

/// Time-in-zone breakdown for one workout (seconds per zone).
/// Flat struct (not a dictionary) so Codable synthesis works without custom CodingKey.
public struct WorkoutZoneBreakdown: Equatable, Codable, Sendable {
    public var warmUpSeconds: Double
    public var fatBurnSeconds: Double
    public var aerobicSeconds: Double
    public var anaerobicSeconds: Double
    public var extremeSeconds: Double

    public init(warmUpSeconds: Double = 0, fatBurnSeconds: Double = 0,
                aerobicSeconds: Double = 0, anaerobicSeconds: Double = 0,
                extremeSeconds: Double = 0) {
        self.warmUpSeconds = warmUpSeconds
        self.fatBurnSeconds = fatBurnSeconds
        self.aerobicSeconds = aerobicSeconds
        self.anaerobicSeconds = anaerobicSeconds
        self.extremeSeconds = extremeSeconds
    }

    /// Convenience initialiser from a zone → seconds dictionary (used internally).
    init(secondsInZone: [HRZone: Double]) {
        warmUpSeconds    = secondsInZone[.warmUp]    ?? 0
        fatBurnSeconds   = secondsInZone[.fatBurn]   ?? 0
        aerobicSeconds   = secondsInZone[.aerobic]   ?? 0
        anaerobicSeconds = secondsInZone[.anaerobic] ?? 0
        extremeSeconds   = secondsInZone[.extreme]   ?? 0
    }

    public func seconds(in zone: HRZone) -> Double {
        switch zone {
        case .warmUp:    return warmUpSeconds
        case .fatBurn:   return fatBurnSeconds
        case .aerobic:   return aerobicSeconds
        case .anaerobic: return anaerobicSeconds
        case .extreme:   return extremeSeconds
        }
    }

    /// Total zone-counted seconds (excludes intervals below zone 1).
    public var totalZoneSeconds: Double {
        warmUpSeconds + fatBurnSeconds + aerobicSeconds + anaerobicSeconds + extremeSeconds
    }

    /// Fraction 0…1 for a zone's share of total zone time.
    public func fraction(in zone: HRZone) -> Double {
        let total = totalZoneSeconds
        guard total > 0 else { return 0 }
        return seconds(in: zone) / total
    }
}

// MARK: - Workout summary

/// Completed workout summary. Produced after the session ends; never contains fabricated values.
/// HR stats derive solely from actual decoded samples — gaps from #45 polling flakiness are
/// NOT filled or interpolated.
public struct WorkoutSummary: Equatable, Codable, Sendable {
    /// Sport type selected by the user.
    public let sport: WorkoutSportType
    /// Wall-clock start time of the session.
    public let startDate: Date
    /// Wall-clock end time of the session (when the user tapped Stop).
    public let endDate: Date
    /// Elapsed time in seconds (wall-clock duration, including periods with no HR readings).
    public var durationSeconds: TimeInterval { endDate.timeIntervalSince(startDate) }
    /// Average BPM across all actual decoded HR readings (nil if no readings were captured).
    public let avgHR: Int?
    /// Maximum BPM recorded during the session (nil if no readings).
    public let maxHR: Int?
    /// Estimated active calories (ESTIMATE — labeled as such in the UI): Keytel HR→energy over the
    /// workout duration when HR was captured, else a distance×body-mass estimate. nil only when there
    /// is NEITHER any HR reading NOR a distance — never fabricated.
    public let estimatedActiveKcal: Double?
    /// 5-zone HR breakdown using held (step-function) attribution — each periodic reading covers the
    /// interval until the next (capped so real dropouts aren't fabricated). See `timeInZonesHeld`.
    public let zoneBreakdown: WorkoutZoneBreakdown
    /// GPS distance in meters (phone-side CoreLocation). nil for indoor sports or when
    /// location permission was denied.
    public let distanceMeters: Double?
    /// Whether a GPS route was captured (and attached as HKWorkoutRoute in HealthKit).
    public let hasRoute: Bool
    /// Count of actual HR readings captured during the session.
    public let hrSampleCount: Int
    /// Steps counted by the ring during the workout (native sport-mode `0x4e` stream, #90).
    /// nil when the workout wasn't recorded in native sport mode (e.g. the legacy live-HR path).
    public let steps: Int?
    /// True when the max HR the zones were drawn with was the `220 − age` formula, false when the user
    /// had typed one.
    public let usedFormulaMaxHR: Bool

    public init(
        sport: WorkoutSportType,
        startDate: Date,
        endDate: Date,
        avgHR: Int?,
        maxHR: Int?,
        estimatedActiveKcal: Double?,
        zoneBreakdown: WorkoutZoneBreakdown,
        distanceMeters: Double?,
        hasRoute: Bool,
        hrSampleCount: Int,
        steps: Int? = nil,
        usedFormulaMaxHR: Bool = true
    ) {
        self.sport = sport
        self.startDate = startDate
        self.endDate = endDate
        self.avgHR = avgHR
        self.maxHR = maxHR
        self.estimatedActiveKcal = estimatedActiveKcal
        self.zoneBreakdown = zoneBreakdown
        self.distanceMeters = distanceMeters
        self.hasRoute = hasRoute
        self.hrSampleCount = hrSampleCount
        self.steps = steps
        self.usedFormulaMaxHR = usedFormulaMaxHR
    }
}

// MARK: - Session aggregator

/// Builds a `WorkoutSummary` from accumulated HR samples. Call `add(sample:)` as readings
/// arrive, then `finalize(sport:endDate:distanceMeters:hasRoute:profile:)` to produce the
/// summary. Thread-safety: designed for @MainActor use (all calls from WorkoutSessionManager).
public final class WorkoutSessionAggregator: @unchecked Sendable {

    private var samples: [HRSample] = []
    private let startDate: Date
    /// The zones this session classifies against, fixed when it started.
    public let zones: HeartRateZones

    /// - Parameters:
    ///   - startDate: When the session started (wall clock).
    ///   - userAge: The age behind the default zones (Automatic max HR, % of max) when `zones` is nil.
    ///   - zones: The user's zones (`HeartRateZoneSettings` resolved for this workout). The app always
    ///     passes them; nil is the default zones for `userAge`.
    public init(startDate: Date, userAge: Int, zones: HeartRateZones? = nil) {
        self.startDate = startDate
        self.zones = zones ?? HeartRateZones(percentOfMax: MaxHeartRate.automatic(age: max(userAge, 1)))
    }

    /// Record a decoded HR reading. `start` and `end` should bound the interval the
    /// sample represents (so time-in-zone accounting is accurate). For instantaneous
    /// poll results, pass end == start; the zone classifier will still classify the
    /// BPM but contribute 0 s to the zone seconds (it is still counted in avg/max).
    public func add(sample: HRSample) {
        samples.append(sample)
    }

    /// Merge real HR the ring already has for this workout's window (e.g. surfaced by a history
    /// sync) into the captured set, de-duplicating by timestamp. NEVER interpolates or fabricates
    /// — when the store has nothing for the window the captured samples are left untouched (#45).
    public func backfill(_ stored: [HRSample], window: DateInterval) {
        samples = WorkoutHRBackfill.merge(captured: samples, stored: stored, window: window)
    }

    /// Produce the final `WorkoutSummary`. Safe to call with zero samples — all HR
    /// fields will be nil rather than fabricated.
    public func finalize(
        sport: WorkoutSportType,
        endDate: Date,
        distanceMeters: Double?,
        hasRoute: Bool,
        profile: UserProfile,
        steps: Int? = nil
    ) -> WorkoutSummary {
        let avgHR: Int?
        let maxHRValue: Int?
        let estimatedKcal: Double?

        let hrKcal: Double?
        if samples.isEmpty {
            avgHR = nil
            maxHRValue = nil
            hrKcal = nil
        } else {
            let sum = samples.reduce(0) { $0 + $1.bpm }
            avgHR = sum / samples.count
            maxHRValue = samples.map(\.bpm).max()
            // Active calories: Keytel HR→energy over the workout's TRUE duration (endDate−startDate).
            // Positive for any real exertion — unlike Edwards-TRIMP, which zeroes below 50% HR-reserve
            // (so easy/moderate sessions read 0 kcal) and needs ≥600 samples (the sparse ~10 s sport
            // stream never reaches that in a normal workout, so it returned nil → "--"). LABELED an
            // estimate in the UI. Numeric (incl. 0) whenever HR was captured, so we never show "--"
            // for a workout with real readings.
            hrKcal = Calories.workoutActiveKcal(
                avgHR: avgHR!,
                durationSeconds: endDate.timeIntervalSince(startDate),
                profile: profile
            )
        }
        // Distance-based active-energy fallback: a GPS walk/run/hike/cycle whose HR never locked
        // (the live-HR path rarely locks in motion, #45) would otherwise show "--" active calories.
        // Estimate from the measured GPS distance + body mass instead (clearly labeled an estimate),
        // and surface the LARGER of the HR-TRIMP and distance estimates. nil only when NEITHER a
        // dense-enough HR series nor a distance exists — never fabricated.
        let distKcal = (distanceMeters ?? 0) > 0
            ? Calories.activeKcalFromDistance(meters: distanceMeters!, profile: profile)
            : nil
        estimatedKcal = [hrKcal, distKcal].compactMap { $0 }.max()

        let breakdown = HRZoneClassifier.timeInZonesHeld(
            hrSamples: samples, zones: zones, sessionEnd: endDate)
        return WorkoutSummary(
            sport: sport,
            startDate: startDate,
            endDate: endDate,
            avgHR: avgHR,
            maxHR: maxHRValue,
            estimatedActiveKcal: estimatedKcal,
            zoneBreakdown: breakdown,
            distanceMeters: distanceMeters,
            hasRoute: hasRoute,
            hrSampleCount: samples.count,
            steps: steps,
            usedFormulaMaxHR: zones.maxHRIsAutomatic
        )
    }

    /// All samples collected so far (for HealthKit HR series write).
    public var collectedSamples: [HRSample] { samples }

    // MARK: Live snapshot (for the in-progress Live Activity / UI)

    /// Running average BPM across all readings captured so far, or nil if none yet. Same integer
    /// truncation as `finalize` so the live number matches the final summary once the session ends.
    public var currentAvgHR: Int? {
        guard !samples.isEmpty else { return nil }
        return samples.reduce(0) { $0 + $1.bpm } / samples.count
    }

    /// High-water mark backing `liveActiveKcal` so the DISPLAYED estimate never ticks DOWN. The
    /// instantaneous avg-HR×elapsed model can dip when a lower reading pulls the running average down
    /// (e.g. 8→6 kcal after a low lock), but physically calories burned only accumulate. Per-session:
    /// a fresh aggregator (one per workout) starts at 0.
    private var liveKcalHighWater: Double = 0

    /// Live active-calorie estimate as of `asOf` (wall clock), using the same Keytel HR→energy model
    /// as `finalize` — running avg HR over the elapsed session so far — CLAMPED to a monotonic
    /// high-water so the Live Activity's number never ticks down. Returns the high-water (initially 0)
    /// when no HR has locked yet — honest: no readings ⇒ no HR-based estimate. HR-only: the distance
    /// fallback `finalize` applies is not included here. Unit-testable (no CoreLocation).
    ///
    /// SIDE EFFECT: advances the internal high-water; call it as the live progressive read, not as a
    /// pure query. With constant HR it equals the instantaneous value, so at session end it matches
    /// `finalize`'s HR-based estimate for a distance-less (indoor) workout.
    public func liveActiveKcal(profile: UserProfile, asOf: Date) -> Double {
        guard let avg = currentAvgHR else { return liveKcalHighWater }
        let instantaneous = Calories.workoutActiveKcal(
            avgHR: avg,
            durationSeconds: asOf.timeIntervalSince(startDate),
            profile: profile
        )
        liveKcalHighWater = max(liveKcalHighWater, instantaneous)
        return liveKcalHighWater
    }
}

// MARK: - HR backfill

/// Pure merge of real stored HR into a workout's captured HR, for filling a workout window from
/// the ring's own on-device record when the live poll missed it (#45). The DURABLE source is the
/// all-day HR stream decode (#99); until that lands this is typically empty for daytime windows,
/// and that empty result is preserved — never interpolated or fabricated (CLAUDE.md).
public enum WorkoutHRBackfill {
    /// Captured + in-window stored HR, de-duplicated by `start` timestamp (captured/live wins on a
    /// tie), sorted ascending. Stored samples outside `window` are ignored.
    public static func merge(captured: [HRSample], stored: [HRSample],
                             window: DateInterval) -> [HRSample] {
        var byStart: [Date: HRSample] = [:]
        for s in stored where window.contains(s.start) { byStart[s.start] = s }
        for s in captured { byStart[s.start] = s }   // captured (live) wins on an exact-timestamp tie
        return byStart.values.sorted { $0.start < $1.start }
    }
}

// MARK: - Buffered ring sport records → a manual workout (tester report 2026-09-27)

/// Fill a MANUAL workout's live-HR gaps from the ring's own buffered 10-second sport records.
///
/// WHY. A manual workout records HR only from the LIVE `0x4e` stream, so with the phone out of range
/// it records nothing — yet the ring keeps measuring and hands the 10-s records (`0x4d`,
/// `HistoricalSportFrame`) over on reconnect. They were routed only to automatic-workout detection,
/// so a tester's pickleball session stayed in zone 0 (43 background readings over 90 min) while
/// ~42 min of the ring's own HR/steps for that very window were offered back as a "detected walk".
///
/// THE RULE. A buffered record is used only where live data is ABSENT. Coverage is decided primarily
/// by the ring's OWN clock: a live `0x4e` frame whose cursor falls in the record's 10-s interval
/// `(end − 10, end]` covers it — HR AND steps, because the live path already summed that frame's
/// steps whether or not it yielded an HR sample (adversarial review 2026-09-28: judging coverage
/// from HR samples alone double-counted the steps of warm-up / dropout / background-missed frames).
/// A captured HR sample ending inside the interval (± `liveOverlapSlack`) also covers it — that is
/// the only signal for the cursor-less `0x95` fallback poll. Records outside `window`, or without a valid HR, contribute no HR (a
/// record's steps still count if its interval is uncovered and inside the window). Never
/// interpolates (#45) — every value returned is one the ring measured.
public enum WorkoutBufferedSportFill {
    /// Slack when testing live coverage of a 10-s record: the live snapshot stamps a ~2-s window at
    /// its capture time and the `0x4e` cadence is ~10 s, so a record whose interval is within one
    /// snapshot of a live reading is treated as covered.
    public static let liveOverlapSlack: TimeInterval = 2

    public struct Fill: Equatable, Sendable {
        public let hrSamples: [HRSample]
        public let steps: Int
        /// Per-record step counts with each record's end time, so a caller that needs to exclude
        /// steps for part of the window (a workout pause, #283 B2) can filter the same way it
        /// already filters `hrSamples` — `steps` alone is a pre-summed scalar and can't be split.
        /// Populated for every record `steps` counts, in the same order; filtering this and summing
        /// `.steps` must always equal the unfiltered total.
        public let stepRecords: [StepRecord]
        /// Cursors consumed (HR or steps), so a caller merging repeatedly never adds one twice.
        public let cursors: Set<UInt32>
    }

    /// One buffered record's step count and the end of its 10 s interval (#283 B2).
    public struct StepRecord: Equatable, Sendable {
        public let end: Date
        public let steps: Int
    }

    public static func fill(captured: [HRSample],
                            buffered: [HistoricalSportFrame.Sample],
                            window: DateInterval,
                            alreadyMerged: Set<UInt32> = [],
                            liveFrameCursors: Set<UInt32> = []) -> Fill {
        var hr: [HRSample] = []
        var steps = 0
        var stepRecords: [StepRecord] = []
        var used: Set<UInt32> = []
        let interval = HistoricalSportFrame.intervalSeconds
        for record in buffered where !alreadyMerged.contains(record.cursor) {
            let end = record.endDate
            let start = end.addingTimeInterval(-interval)
            guard start >= window.start, end <= window.end else { continue }
            let span = UInt32(interval)
            if (0 ..< span).contains(where: { record.cursor >= $0 && liveFrameCursors.contains(record.cursor - $0) }) {
                continue
            }
            let lo = start.addingTimeInterval(-liveOverlapSlack)
            let hi = end.addingTimeInterval(liveOverlapSlack)
            if captured.contains(where: { $0.end >= lo && $0.end <= hi }) { continue }
            if let bpm = record.heartRate { hr.append(HRSample(bpm: bpm, start: start, end: end)) }
            steps += record.steps
            stepRecords.append(StepRecord(end: end, steps: record.steps))
            used.insert(record.cursor)
        }
        return Fill(hrSamples: hr.sorted { $0.start < $1.start }, steps: steps,
                   stepRecords: stepRecords, cursors: used)
    }
}

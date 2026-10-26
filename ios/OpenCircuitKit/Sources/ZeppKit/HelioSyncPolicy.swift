// The Amazfit Helio Strap's app-side rules (#215 phase 3; the decisions of record are
// briefs/helio-decisions.md 4, 8–17, 44): what a pasted key is, where each history type's next fetch
// starts, and which parts of a fetched round may be stored and written to Apple Health.
//
// Pure: no CoreBluetooth, HealthKit or SwiftData, so every rule is covered by `swift test`. The app
// (ios/OpenCircuit/Helio) only moves bytes and rows.

import Foundation
import OpenCircuitKit

// MARK: - Key text (decision 4)

/// The 16-byte auth key as a person pastes it.
public enum HelioKeyText {

    /// The key as 32 lower-case hex digits, or nil. Accepts exactly 32 hex digits with any
    /// whitespace and colons anywhere, after one optional leading `0x`/`0X`. Anything else (31 or
    /// 33 digits, a hyphen, a non-hex letter, a full-width digit) is rejected: a wrong key must be a
    /// visible error, never a fallback (ZEPP_PROTOCOL.md §4.1, §9 #12).
    public static func normalized(_ text: String) -> String? {
        var body = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if body.hasPrefix("0x") || body.hasPrefix("0X") { body = body.dropFirst(2) }
        let digits = body.filter { !$0.isWhitespace && $0 != ":" }
        guard digits.count == 32, digits.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        return digits.lowercased()
    }

    /// The key for `ZeppLink`, or nil for anything `normalized` rejects.
    public static func parse(_ text: String) -> ZeppAuthKey? {
        normalized(text).flatMap { ZeppAuthKey(hex: $0) }
    }
}

// MARK: - Apple Health policy (decisions 12, 15, 17, 44)

public enum HelioHealthPolicy {

    /// Decision 44 (supersedes 14): the strap's HRV is taken as RMSSD, 🟡. Amazfit documents that
    /// "Amazfit devices measure HRV using the RMSSD method"
    /// (https://us.amazfit.com/pages/amazfit-technology-page-health-technology), a product-line
    /// statement that doesn't name the Helio Strap; a third-party Helio review says the same. Not
    /// compared with Zepp's display on our strap (ZEPP_PROTOCOL.md §6.5, §10 item 9). Juan chose to ship
    /// on it, labelled. It is written exactly like the ring's: the RMSSD
    /// value in Apple Health's only HRV type, SDNN, tagged `OpenCircuitHRVStatistic = "RMSSD"`
    /// (`HealthKitWriter.metadata(for:)`, HEALTHKIT_MAPPING.md, #37). Rows stored while this was off
    /// backfill on the next flush: the strap's `hk:hrvSDNN` watermark was never advanced.
    public static let writesHRV = true

    /// The stored kinds a strap's timeline mirrors to Apple Health through the ring's store → Health
    /// path: heart rate, SpO₂ and respiratory rate (decision 17), the gated skin temperature
    /// (decision 12) and HRV (decision 44). Resting HR, steps and energy go through the ring's own daily
    /// and cumulative writers (decisions 16–17); stress and PAI have no Health type and stay in the app
    /// (decision 15).
    public static func healthMirroredKinds(writesHRV: Bool = writesHRV) -> [MetricKind] {
        var kinds: [MetricKind] = [.heartRate, .spo2, .respiratoryRate, .temperature]
        if writesHRV { kinds.append(.hrvSDNN) }
        return kinds
    }

    /// Decision 12: a skin temperature outside this band is dropped, never stored or written (°C).
    public static let skinTemperatureRange: ClosedRange<Double> = 30...42
}

// MARK: - Mapping into the store (decision 10)

extension ZeppMetricMapping {

    /// Samples for the LOCAL store from one parsed round: `samples(from:)` (the Apple-Health-clean
    /// mapping) plus the strap's HRV (RMSSD) as `.hrvSDNN`, which reaches Apple Health through the
    /// store → Health path when `HelioHealthPolicy.writesHRV` (decision 44). An HRV of 0 ms is no reading.
    /// The strap's all-day stress becomes `.stress` (`stressSamples`) and its PAI `.pai`
    /// (`paiSamples`), neither of which has a Health type at all.
    ///
    /// Steps and skin temperature are NOT here: steps go to the step ledger as additive per-minute
    /// deltas (decision 16) and temperature only through `HelioSkinTemperatureGate` (decision 12).
    public static func storedSamples(from parsed: ZeppParsedRecords) -> [QuantitySample] {
        if case .hrv(let readings) = parsed.records {
            return readings.compactMap { reading in
                reading.milliseconds > 0
                    ? QuantitySample(kind: .hrvSDNN, start: reading.time, value: Double(reading.milliseconds))
                    : nil
            }
        }
        if case .autoStress = parsed.records { return stressSamples(from: parsed) }
        if case .pai = parsed.records { return paiSamples(from: parsed) }
        return samples(from: parsed).filter { $0.kind != .steps && $0.kind != .temperature }
    }

    /// The all-day stress minutes of an `.autoStress` round as `.stress` samples (0–100), one per
    /// minute at the minute's own time (#239). A byte above 100 is the strap's "no reading" (`ff`,
    /// ZEPP_PROTOCOL.md §6.5 `0x13`) and is skipped, never stored as a value. Empty for any other type.
    ///
    /// In the app only (decision 15): `.stress` is in no Health-mirrored kind list and
    /// `HealthKitWriter.quantityType(for: .stress)` is nil.
    public static func stressSamples(from parsed: ZeppParsedRecords) -> [QuantitySample] {
        guard case .autoStress(let minutes) = parsed.records else { return [] }
        return minutes.compactMap { minute in
            minute.rawLevel <= 100 ? QuantitySample(kind: .stress, start: minute.time, value: Double(minute.rawLevel)) : nil
        }
    }

    /// The total PAI of each kept `0x0d` record as one `.pai` sample at the record's own time
    /// (decision 45). The parser already dropped every record that is not type `05` (pre-reset and
    /// unknown types), so what arrives here is the strap's own valid readings.
    ///
    /// A total of **0 is a real reading** — a week with no qualifying activity — and is stored like
    /// any other. The only values skipped are ones no reading can be: a non-finite float, or a
    /// negative total (SPEC-GAP: ZEPP_PROTOCOL.md §6.5 tags the `0x0d` fields 🟡, so a misread float
    /// must not become a stored number).
    ///
    /// In the app only (decision 15): `.pai` is in no Health-mirrored kind list and
    /// `HealthKitWriter.quantityType(for: .pai)` is nil.
    public static func paiSamples(from parsed: ZeppParsedRecords) -> [QuantitySample] {
        guard case .pai(let records) = parsed.records else { return [] }
        return records.compactMap { record in
            let total = Double(record.totalPAI)
            guard total.isFinite, total >= 0 else { return nil }
            return QuantitySample(kind: .pai, start: record.time, value: total)
        }
    }

    /// The per-minute step counts of an activity round, each spanning its own minute (decision 16:
    /// additive deltas over their real interval). Minutes with no steps are omitted.
    public static func stepMinutes(from parsed: ZeppParsedRecords) -> [QuantitySample] {
        samples(from: parsed).filter { $0.kind == .steps }
    }
}

// MARK: - Stress bands (#239)

/// Amazfit's four words for an all-day stress level (`0x13`), exactly as ZEPP_PROTOCOL.md §6.5
/// records them: 0–39 relaxed, 40–59 mild, 60–79 moderate, 80–100 high (🟡, the fields' source).
/// The ONLY labels the app puts on the strap's stress. It is the strap's own scale and its own
/// words, not a judgement of the person, and there is deliberately no "usual" for it (#239).
public enum HelioStressBand: String, CaseIterable, Sendable {
    case relaxed, mild, moderate, high

    /// The band for a level, or nil outside 0–100 (a byte above 100 is the strap's "no reading").
    public init?(level: Int) {
        switch level {
        case 0...39: self = .relaxed
        case 40...59: self = .mild
        case 60...79: self = .moderate
        case 80...100: self = .high
        default: return nil
        }
    }

    /// The level range the band covers, for the copy that lists them.
    public var range: ClosedRange<Int> {
        switch self {
        case .relaxed: return 0...39
        case .mild: return 40...59
        case .moderate: return 60...79
        case .high: return 80...100
        }
    }
}

// MARK: - Skin temperature gate (decision 12)

/// Which of the strap's per-minute skin temperatures may be stored and written to Apple Health.
///
/// The review of #219 (U1) found that ungated per-minute `0x2e` values can be ambient or charger
/// temperature. A minute is kept only when ALL of these hold:
/// 1. it has a reading in 30–42 °C (`HelioHealthPolicy.skinTemperatureRange`);
/// 2. the strap's activity record for the SAME minute is known and marks it worn: not `0x73`
///    (not worn) and not `0x76` (charging), ZEPP_PROTOCOL.md §6.5. A minute whose activity record we
///    don't hold is dropped: unknown wear is not evidence of wear;
/// 3. it lies inside one of the strap's own sleep windows (the ring's #29/#41 nightly semantics).
public enum HelioSkinTemperatureGate {

    public enum Exclusion: Equatable {
        /// No reading, or outside 30–42 °C.
        case noReadingInRange
        /// No activity record for the minute.
        case wearUnknown
        case notWorn
        case charging
        case outsideSleepWindow
    }

    /// Whole minutes since 1970, the join key between two per-minute types.
    public static func minuteKey(_ date: Date) -> Int {
        Int((date.timeIntervalSince1970 / 60).rounded(.down))
    }

    /// nil when the minute is kept, else why it isn't.
    public static func exclusion(for minute: ZeppTemperatureMinute, activityKind: UInt8?,
                                 sleepWindows: [DateInterval]) -> Exclusion? {
        guard let celsius = minute.celsius, HelioHealthPolicy.skinTemperatureRange.contains(celsius) else {
            return .noReadingInRange
        }
        guard let kind = activityKind else { return .wearUnknown }
        if kind == ZeppActivityMinute.kindNotWorn { return .notWorn }
        if kind == ZeppActivityMinute.kindCharging { return .charging }
        // Half-open: a reading taken at the window's end minute is already outside it.
        guard sleepWindows.contains(where: { $0.start <= minute.time && minute.time < $0.end }) else {
            return .outsideSleepWindow
        }
        return nil
    }

    /// The earliest minute with a reading in range whose activity record isn't in `activity`: it may
    /// still pass once that record arrives (`HelioFetchPlan.temperatureCursor` waits for it).
    public static func earliestWearUnknown(temperatures: [ZeppTemperatureMinute],
                                           activity: [ZeppActivityMinute]) -> Date? {
        let known = Set(activity.map { minuteKey($0.time) })
        return temperatures
            .filter { exclusion(for: $0, activityKind: known.contains(minuteKey($0.time)) ? 0x01 : nil,
                                sleepWindows: [DateInterval(start: .distantPast, end: .distantFuture)]) == .wearUnknown }
            .map(\.time).min()
    }

    /// The kept minutes as `.temperature` samples, oldest first.
    public static func samples(temperatures: [ZeppTemperatureMinute], activity: [ZeppActivityMinute],
                               sleepWindows: [DateInterval]) -> [QuantitySample] {
        var kindByMinute: [Int: UInt8] = [:]
        for minute in activity { kindByMinute[minuteKey(minute.time)] = minute.kind }
        return temperatures
            .filter { exclusion(for: $0, activityKind: kindByMinute[minuteKey($0.time)], sleepWindows: sleepWindows) == nil }
            .sorted { $0.time < $1.time }
            .compactMap { minute in minute.celsius.map { QuantitySample(kind: .temperature, start: minute.time, value: $0) } }
    }

    /// Decision 71i (#278): a strap night's nightly skin-temperature verdict, judged over its in-bed
    /// spans (`HelioSleepSelection.Night.inBedSpans`), never over the awake gap of a joined night.
    /// `SkinTempBaseline.nightlyVerdict` (shared with the ring, unchanged) over each span's hour-long
    /// buckets: a reading counts in the first span that contains it, the count is over those
    /// readings, and the coverage is the hit buckets over every span's buckets. One span (a night
    /// that wasn't joined) is exactly `SkinTempBaseline.nightlyVerdict(samples:in:)` over it.
    public static func nightlyVerdict(samples: [TemperatureSample], inBedSpans spans: [DateInterval],
                                      minSamples: Int = SkinTempBaseline.minNightlySamples,
                                      minCoverage: Double = SkinTempBaseline.minNightlyCoverage) -> SkinTempBaseline.NightlyVerdict {
        guard spans.count > 1 else {
            guard let span = spans.first else { return .notMeasured }
            return SkinTempBaseline.nightlyVerdict(samples: samples, in: span, minSamples: minSamples, minCoverage: minCoverage)
        }
        var inSpans: [TemperatureSample] = []
        var hit: Set<[Int]> = []
        for sample in samples {
            guard let index = spans.firstIndex(where: { $0.contains(sample.time) }) else { continue }
            inSpans.append(sample)
            hit.insert([index, Int(sample.time.timeIntervalSince(spans[index].start) / 3600)])
        }
        guard inSpans.count >= max(1, minSamples) else { return .notMeasured }
        let buckets = spans.reduce(0) { $0 + max(1, Int(($1.duration / 3600).rounded(.up))) }
        let coverage = Double(hit.count) / Double(buckets)
        guard minCoverage <= 0 || coverage >= minCoverage else { return .rejectedCoverage(coverage) }
        return .published(inSpans.map(\.celsius).reduce(0, +) / Double(inSpans.count))
    }
}

// MARK: - Sleep-stage selection (decision 13)

/// Which sleep staging reaches the store and Apple Health for the strap.
///
/// Decision 13 is: the strap's own staging when it has a night; otherwise OpenCircuit's
/// `SleepStaging` on the strap's per-minute HR and motion; never overwrite a manually edited night.
///
/// DECISION-GAP: the `SleepStaging` fallback is not implemented. `SleepStaging.classify` only
/// accepts RingConn `0x4c` wire records (`BulkRecord`): 150 s epochs whose motion channel and
/// thresholds are calibrated to the ring's accelerometer counts. Feeding it the strap would mean
/// synthesising ring records and inventing an intensity → ring-motion calibration that no capture
/// supports, which decision 25 forbids ("never invent a number"). The most conservative
/// alternative is used instead: a night the strap did not stage is not staged, stored or written,
/// and the app says so. `nights(from:now:)` is the single place a fallback would plug in.
public enum HelioSleepSelection {

    /// One night the strap staged.
    public struct Night: Equatable {
        /// Per session, oldest first: one `.inBed` segment over the session's in-bed span (decision 70b,
        /// `inBedSpan`), then its stage segments, which never overlap each other. The `.inBed` layer
        /// overlaps the stages, as on the ring's nights; a stitched night carries one per session
        /// (fragment), and the gap between fragments is covered by no segment at all.
        public let segments: [SleepSegment]
        /// The union of the sessions' in-bed spans: the first `.inBed` start … the last `.inBed` end.
        public let window: DateInterval
        /// The strap's own sleep score, kept for display. Not OpenCircuit's composite score. nil for a
        /// sleep with no session record (an activity sleep block, decision 73b).
        public let strapScore: UInt8?
        /// The time zone the night was recorded in, from the strap's local-midnight reference
        /// (`ZeppSleepSession.midnightReference`). nil when unknown; then the phone's zone is used.
        public let recordedTimeZone: TimeZone?

        public init(segments: [SleepSegment], window: DateInterval, strapScore: UInt8?,
                    recordedTimeZone: TimeZone? = nil) {
            self.segments = segments
            self.window = window
            self.strapScore = strapScore
            self.recordedTimeZone = recordedTimeZone
        }

        /// Decision 71i (#278): the spans the night was in bed, one per fragment (`HelioSleepSelection
        /// .inBedSpans(of:window:)`). The awake gap of a joined night is in none of them; a night that
        /// wasn't joined has one, its window.
        public var inBedSpans: [DateInterval] { HelioSleepSelection.inBedSpans(of: segments, window: window) }

        /// The calendar to judge this night in (decision 28e, review-224d S-2): the phone's calendar
        /// in the zone the night was RECORDED in, never the zone the phone is in at sync time.
        public var recordedCalendar: Calendar {
            var calendar = Calendar.current
            if let recordedTimeZone { calendar.timeZone = recordedTimeZone }
            return calendar
        }
    }

    /// Decision 71i (#278): the in-bed spans of a strap night's `segments`, oldest first: its `.inBed`
    /// segments (one per fragment, never overlapping, decision 70j), or `window` when it has none (a
    /// row stored before decision 70). The strap-only readers that judge a night's time (the skin
    /// temperature gate and verdict, the overnight HRV) take these, never the union window, whose
    /// awake gap is no sleep.
    public static func inBedSpans(of segments: [SleepSegment], window: DateInterval) -> [DateInterval] {
        let spans = segments.filter { $0.stage == .inBed && $0.end > $0.start }
            .map { DateInterval(start: $0.start, end: $0.end) }
            .sorted { $0.start < $1.start }
        return spans.isEmpty ? [window] : spans
    }

    /// The fixed-offset zone whose local midnight is `midnight` (the strap's own reference).
    ///
    /// SPEC-GAP: §6.6 gives only the instant, not the offset. An offset is read off the instant's
    /// time of day, normalised to (−12 h, +12 h]; a zone at +13/+14 h reads as −11/−10 h, which only
    /// matters for a night judged near the 09:00/21:00 gate edges there.
    public static func recordedTimeZone(midnight: Date) -> TimeZone? {
        let seconds = Int(midnight.timeIntervalSince1970.rounded())
        var utcTimeOfDay = seconds % 86_400
        if utcTimeOfDay < 0 { utcTimeOfDay += 86_400 }
        var offset = -utcTimeOfDay
        if offset <= -12 * 3600 { offset += 86_400 }
        return TimeZone(secondsFromGMT: offset)
    }

    /// A staged night longer than this is not plausible for one sleep and is dropped (it is what a
    /// wrong minute base, §6.6 🔴, would produce).
    public static let maxNightLength: TimeInterval = 20 * 3600

    /// Stage bytes (§6.6): `04` light → core, `05` deep, `07` awake, `08` REM.
    ///
    /// SPEC-GAP: any other stage byte is "generic sleep" (§6.6). OpenCircuit's `SleepStage` has no
    /// unspecified-sleep case, so it maps to `.asleepCore`, the stage OpenCircuit's own staging gives
    /// "asleep, nothing more specific". It is counted as sleep either way; only the label is a choice.
    public static func stage(for kind: ZeppSleepSession.StageKind) -> SleepStage {
        switch kind {
        case .light: return .asleepCore
        case .deep: return .asleepDeep
        case .awake: return .awake
        case .rem: return .asleepREM
        case .other: return .asleepCore
        }
    }

    /// The night one sleep-session record describes, or nil when it has no usable staging.
    ///
    /// Each stage's own start and end are used (§6.6: "use both and flag gaps"), the end being one
    /// minute after its inclusive end minute (`ZeppSleepSession.Stage.segmentEnd`, decision 70e): a
    /// gap between stages stays a gap, never filled in. A stage that starts before the previous one
    /// ends is trimmed to start where the previous ended, so no two stage segments overlap. The
    /// stages are preceded by one `.inBed` segment over the session's in-bed span (`inBedSpan`,
    /// decisions 70a/70b), which is also the window. nil when nothing survives, when the stages span
    /// more than `maxNightLength`, or when the night ends in the future.
    public static func night(from session: ZeppSleepSession, now: Date) -> Night? {
        var segments: [SleepSegment] = []
        var previousEnd = Date.distantPast
        for stage in session.stages.sorted(by: { $0.start < $1.start }) {
            let start = max(stage.start, previousEnd)
            guard stage.segmentEnd > start else { continue }
            segments.append(SleepSegment(start: start, end: stage.segmentEnd, stage: Self.stage(for: stage.kind)))
            previousEnd = stage.segmentEnd
        }
        guard let first = segments.first?.start, let last = segments.last?.end, last > first else { return nil }
        let stageSpan = DateInterval(start: first, end: last)
        guard stageSpan.duration <= maxNightLength else { return nil }
        let window = inBedSpan(stageSpan: stageSpan, recordStart: session.sleepStart, recordEnd: session.sleepEnd)
        guard window.end <= now.addingTimeInterval(3600) else { return nil }
        guard segments.contains(where: { $0.stage != .awake }) else { return nil }
        segments.insert(SleepSegment(start: window.start, end: window.end, stage: .inBed), at: 0)
        return Night(segments: segments, window: window, strapScore: session.score,
                     recordedTimeZone: recordedTimeZone(midnight: session.midnightReference))
    }

    /// Decision 70a (#311): a session's in-bed span. The union of its stage span and its record span
    /// (`ZeppSleepSession.sleepStart` … `sleepEnd`) when the record span is valid: it starts before it
    /// ends, it overlaps the stage span, and the union is no longer than `maxNightLength`. Otherwise
    /// the stage span. The record carries no lead-in; the store adds its estimate later, before the
    /// night's first fragment (decision 77, `HelioInBedLeadIn`).
    public static func inBedSpan(stageSpan: DateInterval, recordStart: Date, recordEnd: Date) -> DateInterval {
        guard recordStart < recordEnd, recordStart < stageSpan.end, stageSpan.start < recordEnd else { return stageSpan }
        let union = DateInterval(start: min(stageSpan.start, recordStart), end: max(stageSpan.end, recordEnd))
        return union.duration <= maxNightLength ? union : stageSpan
    }

    /// Decision 28f (review-224d S-3): consecutive sessions this far apart or closer are one night.
    /// Amazfit's own rule: sleep more than 60 min from the main sleep is recorded as a nap.
    ///
    /// Decision 71 (#278): OpenCircuit joins two overnight sleeps of one night (`areOneNight`) whatever
    /// the gap, so a long mid-night awakening no longer splits the night. This 60-min rule still decides
    /// everything else (an evening doze, a daytime or late-morning sleep).
    public static let stitchGap: TimeInterval = 60 * 60

    /// What `overnightVerdict` found: an overnight sleep (decision 71a), or which half of the gate it failed.
    public enum OvernightVerdict: Equatable {
        case overnight
        /// Its midpoint is outside the night (`SleepWindow.isOvernightBlock`, decision 28c).
        case notOvernight
        /// It doesn't end in its key's wake window (`SleepNightKey.endsInWakeWindow`, decision 28d).
        case endsOutsideWakeWindow
    }

    /// Decision 71a (#278): whether `night` is an overnight sleep: its own window passes
    /// `SleepWindow.isOvernightBlock` (28c) AND ends in its key's wake window (28d), both judged in the
    /// calendar it was recorded in (`Night.recordedCalendar`, 28e). The one gate for both the nights the
    /// store keeps (`HelioStoreSink.storeNights`) and the same-night join in `stitch`.
    public static func overnightVerdict(_ night: Night) -> OvernightVerdict {
        let calendar = night.recordedCalendar
        guard SleepWindow.isOvernightBlock(start: night.window.start, end: night.window.end, calendar: calendar) else {
            return .notOvernight
        }
        guard SleepNightKey.endsInWakeWindow(night.window.end, calendar: calendar) else { return .endsOutsideWakeWindow }
        return .overnight
    }

    /// Decision 71a: `overnightVerdict(night) == .overnight`.
    public static func isOvernightSleep(_ night: Night) -> Bool {
        overnightVerdict(night) == .overnight
    }

    /// The night key `night` files under (`SleepNightKey.night(inBedStart:inBedEnd:calendar:)` of its
    /// own window), in the calendar it was recorded in.
    public static func nightKey(of night: Night) -> Date {
        SleepNightKey.night(inBedStart: night.window.start, inBedEnd: night.window.end, calendar: night.recordedCalendar)
    }

    /// Decision 71b (#278): whether two sleeps are one night whatever the gap between them: both are
    /// overnight sleeps (71a) and both file under the same night key.
    public static func areOneNight(_ a: Night, _ b: Night) -> Bool {
        isOvernightSleep(a) && isOvernightSleep(b) && nightKey(of: a) == nightKey(of: b)
    }

    /// Every staged night in `sessions`, oldest first: each session's night (`night(from:now:)`), then
    /// `stitch`.
    public static func nights(from sessions: [ZeppSleepSession], now: Date) -> [Night] {
        stitch(sessions.compactMap { night(from: $0, now: now) })
    }

    /// The single stitching rule (decisions 28f and 71b), for anything that turns strap sleeps into
    /// nights or naps: oldest first by their stages; a sleep whose STAGES overlap an earlier one's is
    /// dropped (the strap re-delivers sessions on an overlapping fetch); the next sleep joins the night
    /// accumulated so far when the two are `stitchGap` or less apart (28f), OR when both are overnight
    /// sleeps of the same night key (`areOneNight`, 71b: a long mid-night awakening, whatever its
    /// length), unless the joined window would exceed `maxNightLength`. Joined, their segments stay
    /// exactly as reported, and the gap between them stays a gap: no segment is invented for it.
    ///
    /// The join is judged on the ACCUMULATED night against the next sleep, so a night of three
    /// fragments is one night even when its first fragment alone is no overnight sleep (it ends before
    /// midnight). A first fragment that ends before midnight and is more than `stitchGap` from the next
    /// is still not joined (decision 71, a known gap).
    ///
    /// Decision 70j (review-311 B1): the duplicate is judged on the stage spans, never on the in-bed
    /// `window`. A session's record span can reach into its neighbour's (a lead-in, a trailing end), and
    /// judged on the window that dropped the whole neighbour. The gap and the length are the window's
    /// (70d).
    public static func stitch(_ sleeps: [Night]) -> [Night] {
        var out: [Night] = []
        for night in sleeps.sorted(by: { stageSpan(of: $0).start < stageSpan(of: $1).start }) {
            if let last = out.last, stageSpan(of: last).end > stageSpan(of: night).start { continue }
            if let last = out.last,
               night.window.end.timeIntervalSince(last.window.start) <= maxNightLength,
               night.window.start.timeIntervalSince(last.window.end) <= stitchGap || areOneNight(last, night) {
                out[out.count - 1] = stitched(last, night)
                continue
            }
            out.append(night)
        }
        return out
    }

    /// First stage start … last stage end (the non-`.inBed` segments); the window when there are none.
    static func stageSpan(of night: Night) -> DateInterval {
        let stages = night.segments.filter { $0.stage != .inBed }
        guard let start = stages.map(\.start).min(), let end = stages.map(\.end).max(), end > start else { return night.window }
        return DateInterval(start: start, end: end)
    }

    /// Two sessions as one night: both segment lists as reported (each with its own `.inBed` segment,
    /// decision 70b), the window spanning both, the longer session's score (the other's when the longer
    /// has none, an activity block, decision 73b) and the first's recorded zone.
    ///
    /// Decision 70j: one `.inBed` per fragment, never overlapping, both halves kept. When the earlier
    /// fragment's `.inBed` overlaps the later one's, the later one starts where the earlier ends; if that
    /// would start after the later fragment's first stage, the earlier one ends at that first stage
    /// instead (and the later one starts there, so the two still don't overlap). The stages are never
    /// touched, and the window is the union of the `.inBed` spans.
    static func stitched(_ first: Night, _ second: Night) -> Night {
        var earlier = first.segments
        var later = second.segments
        if let e = earlier.lastIndex(where: { $0.stage == .inBed }),
           let l = later.firstIndex(where: { $0.stage == .inBed }),
           earlier[e].end > later[l].start {
            let laterFirstStage = later.filter { $0.stage != .inBed }.map(\.start).min() ?? later[l].end
            if earlier[e].end <= laterFirstStage {
                later[l] = SleepSegment(start: earlier[e].end, end: later[l].end, stage: .inBed)
            } else {
                earlier[e] = SleepSegment(start: earlier[e].start, end: laterFirstStage, stage: .inBed)
                later[l] = SleepSegment(start: laterFirstStage, end: later[l].end, stage: .inBed)
            }
        }
        let segments = earlier + later
        let inBeds = segments.filter { $0.stage == .inBed }
        let window: DateInterval
        if let start = inBeds.map(\.start).min(), let end = inBeds.map(\.end).max() {
            window = DateInterval(start: start, end: end)
        } else {
            window = DateInterval(start: first.window.start, end: second.window.end)
        }
        let (longer, shorter) = second.window.duration > first.window.duration ? (second, first) : (first, second)
        return Night(segments: segments, window: window,
                     strapScore: longer.strapScore ?? shorter.strapScore,
                     recordedTimeZone: first.recordedTimeZone ?? second.recordedTimeZone)
    }

    /// Decision 70h (#311, #312): the shapes a build before decisions 70b and 70e gave the strap night
    /// `segments` now describe, for the Health mirror to recognise a night it already holds. Forward-only
    /// (70c): a night already written is not rewritten when its only differences from the written night
    /// are the `.inBed` layer and/or the stage end's extra minute.
    ///
    /// Three shapes, all without the `.inBed` layer: the stages as they are (the layer alone differs);
    /// every stage a minute shorter (an inclusive-end record, the format observed, §6.6 🟡: the stages
    /// were contiguous, so each start is unchanged); and every stage a minute shorter with a start that
    /// met the previous stage's end a minute earlier too (a record that already ended a stage at the
    /// next start, where the overlap trim moved that start). A stage that would have no length was
    /// never written, so it is left out. Empty when there are no stages.
    public static func shapesBeforeInBedAndInclusiveEnd(_ segments: [SleepSegment]) -> [[SleepSegment]] {
        let stages = segments.filter { $0.stage != .inBed }
        guard !stages.isEmpty else { return [] }
        let minute = ZeppSleepSession.stageEndMinute
        var shortened: [SleepSegment] = []
        var trimmed: [SleepSegment] = []
        var previousEnd: Date?
        for stage in stages {
            let end = stage.end.addingTimeInterval(-minute)
            if end > stage.start { shortened.append(SleepSegment(start: stage.start, end: end, stage: stage.stage)) }
            let start = stage.start == previousEnd ? stage.start.addingTimeInterval(-minute) : stage.start
            if end > start { trimmed.append(SleepSegment(start: start, end: end, stage: stage.stage)) }
            previousEnd = stage.end
        }
        return [stages, shortened, trimmed]
    }

    /// The nights that may be stored or written: decision 13's "never overwrite a manually edited
    /// night". A night whose window overlaps a manually edited window is left to the person's edit.
    public static func nightsToWrite(_ nights: [Night], manuallyEdited: [DateInterval]) -> [Night] {
        nights.filter { night in
            !manuallyEdited.contains { edited in
                edited.start < night.window.end && night.window.start < edited.end
            }
        }
    }

    // MARK: Naps (#231, ZEPP_PROTOCOL.md §21.5)

    /// §21.1 / §21.5 step 4: Amazfit doesn't record sleep shorter than this, so it is never a nap.
    public static let minNapLength: TimeInterval = 20 * 60

    /// §21.5 step 3: a sleep more than this from the main sleep is a nap; one this close or closer
    /// belongs to the main sleep. The same 60 minutes as `stitchGap`, so a sleep `stitch` keeps apart
    /// from its own night is always far enough from it. An overnight sleep of the night's own key is
    /// never kept apart from it (decision 71b), so it is never judged here as a nap.
    public static let napGap: TimeInterval = stitchGap

    /// §21.5 step 2: the main-sleep window, as hours of the recorded local day: 00:00–08:00, what the
    /// strap uses without a sleep plan. OpenCircuit can't read Zepp's sleep plan (no known config arg).
    public static let defaultMainSleepHours: Range<Int> = 0..<8

    /// A sleep is judged as a nap only once this long has passed since it ended: until then a later
    /// session can still start within `stitchGap` of it and stitch it into a night (28f).
    ///
    /// SPEC-GAP: §21.4 can't say when the strap writes a session record (🔴), so a later session can
    /// still arrive after this. A stored nap that a night later absorbs is removed by the night's own
    /// store (`LocalStore.saveSleepSummary` prunes the auto naps its window overlaps, and a strap night
    /// the strap's auto naps within `napGap` of it, decision 76l).
    public static let napSettleTime: TimeInterval = stitchGap

    /// What `naps(from:mainSleeps:now:)` made of each sleep.
    public struct NapSplit: Equatable {
        /// The naps, oldest first: sleeps of `minNapLength` or more, more than `napGap` from every
        /// main sleep, and settled (`napSettleTime`).
        public var naps: [Night] = []
        /// The sleeps taken as the main sleep of a day no known main sleep covered (§21.5 step 2):
        /// never naps, whatever else is true of them.
        public var mainSleeps: [Night] = []
        /// Sleeps that overlap a main sleep or lie `napGap` or less from one: they belong to the main
        /// sleep (§21.5 step 3), so they are no nap.
        public var nearMainSleep: [Night] = []
        /// §21.5 step 4: shorter than `minNapLength`. The strap shouldn't send these; one that arrives
        /// says the rule is wrong, so the caller logs it.
        public var tooShort: [Night] = []
        /// Naps in every other respect that ended less than `napSettleTime` ago: judged again later.
        public var unsettled: [Night] = []

        public init() {}
    }

    /// §21.5: which of `sleeps` are naps.
    ///
    /// 1. The sleeps are stitched first (`stitch`): sessions 60 min or less apart are one sleep (28f),
    ///    and so are overnight sleeps of one night key whatever the gap (decision 71b, #278), so of two
    ///    overnight sleeps of one night neither is a nap. Every other sleep keeps the 60-min rule.
    /// 2. A main sleep is a known one (`mainSleeps`: the nights already stored, by either device), or,
    ///    for a day whose main-sleep window (`mainSleepHours` of the day, in the zone the sleep was
    ///    recorded in) no known main sleep overlaps, the longest of these sleeps that overlaps it.
    ///    Such a sleep is never a nap: a night not stored yet (in progress, or a save that failed)
    ///    can't turn into one.
    /// 3. Any other sleep that overlaps a main sleep, or lies `napGap` or less from one, belongs to it.
    /// 4. Of the rest, one shorter than `minNapLength` is `tooShort`; one that ended less than
    ///    `napSettleTime` before `now` is `unsettled`; every other one is a nap.
    ///
    /// A nap never displaces a night: a sleep is a nap only when it is no main sleep, and nothing here
    /// changes which sleep is a night.
    public static func naps(from sleeps: [Night], mainSleeps known: [DateInterval], now: Date,
                            mainSleepHours: Range<Int> = defaultMainSleepHours) -> NapSplit {
        let stitchedSleeps = stitch(sleeps)
        // Step 2: the provisional main sleep of each main-sleep window no known main sleep covers.
        var longestByWindow: [Date: (index: Int, window: DateInterval)] = [:]
        for (index, sleep) in stitchedSleeps.enumerated() {
            for window in mainSleepWindows(touching: sleep, hours: mainSleepHours)
            where overlaps(window, sleep.window) && !known.contains(where: { overlaps($0, window) }) {
                if let best = longestByWindow[window.start],
                   stitchedSleeps[best.index].window.duration >= sleep.window.duration { continue }
                longestByWindow[window.start] = (index, window)
            }
        }
        let provisional = Set(longestByWindow.values.map { $0.index })
        let anchors = known + provisional.sorted().map { stitchedSleeps[$0].window }

        var split = NapSplit()
        for (index, sleep) in stitchedSleeps.enumerated() {
            if provisional.contains(index) {
                split.mainSleeps.append(sleep)
            } else if anchors.contains(where: { gap($0, sleep.window) <= napGap }) {
                split.nearMainSleep.append(sleep)
            } else if sleep.window.duration < minNapLength {
                split.tooShort.append(sleep)
            } else if now < sleep.window.end.addingTimeInterval(napSettleTime) {
                split.unsettled.append(sleep)
            } else {
                split.naps.append(sleep)
            }
        }
        return split
    }

    /// The main-sleep windows (`hours` of a local day, in the sleep's recorded zone) of the days the
    /// sleep starts and ends on. A sleep is at most `maxNightLength` (20 h) long, so no other day's
    /// window can lie inside it.
    static func mainSleepWindows(touching sleep: Night, hours: Range<Int>) -> [DateInterval] {
        let calendar = sleep.recordedCalendar
        var days = [calendar.startOfDay(for: sleep.window.start)]
        let lastDay = calendar.startOfDay(for: sleep.window.end)
        if lastDay != days[0] { days.append(lastDay) }
        return days.compactMap { day in
            guard let start = calendar.date(byAdding: .hour, value: hours.lowerBound, to: day),
                  let end = calendar.date(byAdding: .hour, value: hours.upperBound, to: day),
                  end > start else { return nil }
            return DateInterval(start: start, end: end)
        }
    }

    /// Whether two windows share some time (touching edges don't).
    static func overlaps(_ a: DateInterval, _ b: DateInterval) -> Bool {
        a.start < b.end && b.start < a.end
    }

    /// The time between two windows: zero or less when they touch or overlap.
    static func gap(_ a: DateInterval, _ b: DateInterval) -> TimeInterval {
        max(b.start.timeIntervalSince(a.end), a.start.timeIntervalSince(b.end))
    }
}

// MARK: - Fetch plan and watermarks

/// Where each history type's next fetch starts. One watermark per type (§6.4), persisted per strap
/// as a `StoredCursor` row named `cursorName(for:)` under the strap's timeline (`SyncCursorKey`).
public enum HelioFetchPlan {

    /// The types the app fetches, in this order. Activity and sleep sessions come before
    /// temperature so the skin-temperature gate has their minutes when the temperature rounds
    /// arrive. Not fetched: max HR (no Health type, §6.5), manual HR and manual stress (only ever
    /// empty on the Helio, §10.1), sleep SpO₂ (its layout is 🔴, §6.5) and workouts (out of scope).
    public static let types: [ZeppFetchType] = [
        .activity, .sleepSession, .temperature, .spo2, .sleepRespiratoryRate,
        .restingHeartRate, .hrv, .autoStress, .pai,
    ]

    /// How far back a type's first-ever fetch reaches.
    ///
    /// SPEC-GAP: §6.4 only records that Gadgetbridge starts 100 days back. The strap keeps everything
    /// (the app always acks `03 09`, decision 8), so nothing is lost by starting nearer: a week gives
    /// last night and the week's trends on the first sync without a long first transfer, and without
    /// re-importing months of data Zepp may already have written to Apple Health.
    public static let firstSyncLookback: TimeInterval = 7 * 86_400

    /// No fetch reaches further back than this, however old a watermark is: the store keeps 30 days
    /// of raw samples (`LocalStore.sampleRetentionDays`).
    public static let maxLookback: TimeInterval = 30 * 86_400

    /// A watermark this far ahead of the phone's clock is treated as unknown (a clock that moved
    /// back, or a strap clock that ran ahead before the time was set), rather than stalling the type.
    public static let futureTolerance: TimeInterval = 5 * 60

    /// Sleep sessions are re-fetched from this far before the temperature watermark, so every
    /// temperature minute still to be gated has its night's session in the same sync.
    public static let sleepSessionOverlap: TimeInterval = 24 * 3600

    private static let cursorPrefix = "zepp.fetch."

    /// The cursor name for a type (`zepp.fetch.2e`). Not a `MetricKind`, so no store reader mistakes
    /// it for a sample watermark.
    public static func cursorName(for type: ZeppFetchType) -> String {
        cursorPrefix + String(format: "%02x", type.rawValue)
    }

    /// The type a cursor name belongs to; nil for any other name.
    public static func type(forCursorName name: String) -> ZeppFetchType? {
        guard name.hasPrefix(cursorPrefix), let raw = UInt8(name.dropFirst(cursorPrefix.count), radix: 16) else {
            return nil
        }
        return ZeppFetchType(rawValue: raw)
    }

    /// `date` rounded down to the whole minute: the fetch *since* has minute precision (§6.2).
    public static func floorToMinute(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.down) * 60)
    }

    /// The fetch plan: each type with the *since* of its first round.
    ///
    /// - A type with no watermark, or one more than `futureTolerance` ahead of `now`, starts
    ///   `firstSyncLookback` back. No type starts more than `maxLookback` back.
    /// - Activity starts at the earlier of its own and temperature's watermark, and sleep sessions
    ///   at the earlier of their own and temperature's minus `sleepSessionOverlap`: the temperature
    ///   gate needs each minute's wear state and night. Re-delivered minutes are deduplicated by the
    ///   store's per-kind cursors.
    /// - `notBefore` (decision 28: the strap's CURRENT ownership start) bounds every type's start,
    ///   including those two re-fetch windows: the strap never fetches time the ring owned.
    public static func plan(cursors: [ZeppFetchType: Date], now: Date,
                            notBefore: Date? = nil) -> [(type: ZeppFetchType, since: Date)] {
        let first = floorToMinute(now.addingTimeInterval(-firstSyncLookback))
        let oldest = floorToMinute(now.addingTimeInterval(-maxLookback))
        let latest = floorToMinute(now)
        let bound = notBefore.map { min(floorToMinute($0), latest) }
        func resolved(_ type: ZeppFetchType) -> Date {
            guard let cursor = cursors[type], cursor <= now.addingTimeInterval(futureTolerance) else { return first }
            return min(max(floorToMinute(cursor), oldest), latest)
        }
        var since: [ZeppFetchType: Date] = [:]
        for type in types { since[type] = resolved(type) }
        let temperature = resolved(.temperature)
        since[.activity] = min(resolved(.activity), temperature)
        since[.sleepSession] = max(oldest, min(resolved(.sleepSession),
                                               temperature.addingTimeInterval(-sleepSessionOverlap)))
        return types.map { type in
            let start = since[type] ?? first
            return (type, bound.map { max(start, $0) } ?? start)
        }
    }

    /// The watermark to persist once `round` is durably stored: the round's next *since* (last
    /// record + 1 minute), never later than `now` and never behind `previous`. `previous` when the
    /// round had no records.
    public static func advancedCursor(previous: Date?, round: ZeppFetchRound, now: Date) -> Date? {
        guard let next = round.nextSince else { return previous }
        let clamped = min(next, floorToMinute(now))
        guard let previous else { return clamped }
        return max(previous, clamped)
    }

    // MARK: One-time fetch-watermark backfills (#239 stress, decision 45 PAI)

    /// How far back a stress backfill reaches at most. Build 59 fetched the all-day stress (`0x13`)
    /// on every sync but kept only its latest value, while the type's watermark advanced, so no stress
    /// history was stored; build 60 does the same. Rewinding that watermark refetches the hole.
    ///
    /// SPEC-GAP: how much stress history the strap itself still holds is not documented (§6.4 says
    /// nothing about retention). The app always acked `03 09` (keep on strap, decision 8), so nothing
    /// was released; if the strap has rotated older minutes out, those rounds just come back short.
    public static let stressBackfillLookback: TimeInterval = 7 * 86_400

    /// The stress watermark a backfill rewinds to, or nil when no backfill is due.
    ///
    /// **The test is exact: "did another build advance the stress watermark?"** (review-242b SF-1).
    /// `ledger` is the watermark as THIS code last left it, written in the same save as every advance
    /// or rewind this code makes (`LocalStore.helioStressLedger`). So:
    ///
    /// - `watermark > ledger` can only mean a build that fetches `0x13` and drops it moved the
    ///   watermark on. The hole is exactly `[ledger, watermark]`, and it is refetched.
    /// - `watermark == ledger` is every ordinary case — a wear gap, charging, stress monitoring off
    ///   (#240), a strap that rotated minutes out — because this code advanced the watermark itself
    ///   and recorded that it did. **Never due.** The previous gap heuristic could not tell those
    ///   apart from a rollback: `ff` minutes advance the watermark but store no row, so an hour off
    ///   the wrist re-armed a 7-day refetch whose minutes the strictly-forward `.stress` ingest cursor
    ///   then dropped — pure cost, roughly once per gap.
    /// - No `ledger` yet, but a watermark exists: the first run of this code on a timeline that an
    ///   older build already advanced. That is the original build-59/60 upgrade, and it gets the
    ///   7-day backfill.
    /// - No watermark at all: nil. The type's first fetch already reaches `firstSyncLookback` back.
    ///
    /// The rewind is `max(ledger, watermark − stressBackfillLookback, notBefore)` — never past the
    /// ledger (everything before it is already stored), never more than a week, and never before
    /// `notBefore` (decision 28: the strap's current ownership start, rounded UP to its minute, so the
    /// target never lies even seconds inside the ring's time). nil when that leaves nothing to move.
    ///
    /// `plan(cursors:now:notBefore:)` bounds every type's start by `notBefore` again, so even a
    /// watermark written before any of this existed cannot reach time the ring owned.
    public static func stressBackfillCursor(watermark: Date?, ledger: Date?, notBefore: Date?) -> Date? {
        backfillCursor(watermark: watermark, ledger: ledger, notBefore: notBefore,
                       lookback: stressBackfillLookback)
    }

    /// How far back a PAI backfill reaches at most (decision 45). Builds 59–62 fetched `0x0d` on
    /// every sync, kept only its latest value for the card and still advanced the type's watermark,
    /// so no PAI row was ever stored.
    ///
    /// A week, the same as stress and `firstSyncLookback`: `0x0d` is written about once a day, so a
    /// week is already seven records (714 bytes) and more than enough for the card to show a number
    /// on build 63's first sync. It also sits well inside the store's 30-day raw-sample retention
    /// (`LocalStore.sampleRetentionDays`), so nothing a rewind stores is pruned the moment it lands.
    ///
    /// SPEC-GAP: how much PAI history the strap itself keeps is not documented (§6.4 says nothing
    /// about retention). The app always acked `03 09` (keep on strap, decision 8), so nothing was
    /// released; if the strap has rotated older records out, the rounds just come back short.
    public static let paiBackfillLookback: TimeInterval = 7 * 86_400

    /// The PAI watermark a backfill rewinds to, or nil when none is due. Exactly the stress rule
    /// above — the ledger is "where this code left the watermark", so a hole is only ever another
    /// build's advance — with PAI's own lookback and its own ledger row.
    public static func paiBackfillCursor(watermark: Date?, ledger: Date?, notBefore: Date?) -> Date? {
        backfillCursor(watermark: watermark, ledger: ledger, notBefore: notBefore,
                       lookback: paiBackfillLookback)
    }

    /// The shared ledger rule both backfills are: nil unless `watermark > ledger` (or there is a
    /// watermark and no ledger at all), then `max(ledger, watermark − lookback, notBefore)`, with
    /// `notBefore` rounded UP to its minute so the target never lies even seconds inside time the
    /// strap doesn't own. nil when that leaves nothing to move.
    public static func backfillCursor(watermark: Date?, ledger: Date?, notBefore: Date?,
                                      lookback: TimeInterval) -> Date? {
        guard let watermark else { return nil }
        // Due only when another build moved the watermark past where this code left it.
        if let ledger, watermark <= ledger { return nil }
        var target = floorToMinute(watermark.addingTimeInterval(-lookback))
        if let ledger { target = max(target, ledger) }
        if let notBefore {
            target = max(target, Date(timeIntervalSince1970: (notBefore.timeIntervalSince1970 / 60).rounded(.up) * 60))
        }
        return target < watermark ? target : nil
    }

    /// How far back a temperature minute may still be waiting for its night: a night's session is
    /// written when the strap sees the wake, so a sync during (or just after) the night comes before it.
    public static let temperatureSettleWindow: TimeInterval = 36 * 3600

    /// The temperature watermark after a round, held back so no minute that may still pass the gate
    /// (decision 12) is skipped for good. `proposed` is `advancedCursor`'s value.
    ///
    /// A minute excluded only because its night isn't recorded yet, or its activity record wasn't
    /// fetched, becomes gateable later, but nothing re-fetches temperature behind its own watermark.
    /// So the watermark never passes:
    /// - the earliest minute of this round excluded as `wearUnknown`;
    /// - the end of the latest night known this sync, or `now − temperatureSettleWindow` if that is
    ///   later (a night can only arrive for minutes after the last known one; older minutes are final).
    /// It never moves behind `previous`. The cost is re-fetching up to a day and a half of
    /// temperature and activity per sync; the store's cursors deduplicate them.
    public static func temperatureCursor(proposed: Date?, previous: Date?, earliestWearUnknown: Date?,
                                         latestNightEnd: Date?, now: Date) -> Date? {
        guard let proposed else { return previous }
        var limit = max(latestNightEnd ?? .distantPast, floorToMinute(now.addingTimeInterval(-temperatureSettleWindow)))
        if let wearUnknown = earliestWearUnknown { limit = min(limit, floorToMinute(wearUnknown)) }
        let held = min(proposed, limit)
        guard let previous else { return held }
        return max(previous, held)
    }
}

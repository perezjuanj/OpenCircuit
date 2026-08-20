// Coverage-aware sleep confidence: WHY this night's number might be wrong, not just THAT it might.
//
// `SleepConfidence.classify(asleep:inBed:)` sees two totals and nothing else, which is why it cannot
// see a data hole. Measured on the 21 staged nights of the sleep corpus (master `f042639`), that
// blindness has a precise cost:
//
//   • it fires on 4 of 21 nights, and of the 5 LABELLED nights it fires on exactly ONE —
//     `R3_2026-08-15`, worst edge error 8 min, the most accurate night in the corpus — while staying
//     silent on all four we get wrong.
//   • the two worst nights in the corpus never reach the efficiency test at all: `guard inBed >=
//     minNightForFlag` (`SleepConfidence.swift:55`, 5 h at `:31`) discards `R2_2026-08-17` (102 min
//     in bed) and `R2_2026-08-18` (253 min), each understated by 246 min because nothing was
//     recorded after 02:39:14 / 02:37:02 for the next 243.6 / 241.9 min.
//
// ⚠️ THE GATE IS NOT THE BUG, AND LOWERING IT IS ACTIVELY HARMFUL. A truncated night that reaches
// the efficiency test reads at 1.0000 / 0.9873 and would be told `.durationLikelyHigh` — "you lay
// still, so we over-counted" — when the measured truth is that the duration reads LOW by 246 min.
// The inverse of the truth is worse than silence. It would also newly fire on `R3_2026-06-28`, a
// benign 71-minute morning fragment at efficiency 1.0000, which is exactly the case the 5 h gate was
// written to exclude. So this file does not touch the gate, the threshold, or `classify`: it ADDS a
// second, independent question — did the recording actually cover the night? — and makes the
// duration verdict yield to it when both have something to say.
//
// 70 % of the measurable sleep-edge error in this corpus is ACQUISITION, not staging (492 of 699
// minutes): the records simply do not exist. Nothing here changes a staged number.
//
// Pure (no Apple frameworks) so it unit-tests on the CLI. `SleepConfidence.swift` is untouched.

import Foundation

extension SleepConfidence {

    // MARK: - Input

    /// The acquisition facts a night's confidence depends on, as SIX INSTANTS the app can actually
    /// fetch — not the night's record array.
    ///
    /// WHY PRECOMPUTED INSTANTS AND NOT `[Date]`. The consumer is `SleepCardView`, on the render
    /// path. `LocalStore.latestSample(kind:before:)` (`LocalStore.swift:646`) is a one-row indexed
    /// fetch carrying the comment "runs on the sleep card's render path, so it must never become a
    /// scan" — it already feeds `BedtimeProvenance` there. Every field below is that same shape: one
    /// indexed row, `fetchLimit = 1`. Handing this type a night of observed record times would
    /// instead mean loading ~400 rows per render to answer a question that only ever looks at the
    /// two records adjacent to the window edges. The staging path (`RingSession` → `BulkSleep`) does
    /// hold the records, but it is not the caller: the card recomputes provenance from disk on every
    /// appearance precisely so nothing has to be persisted (see `refreshBedtimeProvenance`, which
    /// documents why a stored provenance flag — and its SwiftData migration — was rejected).
    ///
    /// The two "measurement" fields want a HEART-RATE observation specifically, for the reason
    /// `BedtimeProvenance` gives: HR is band-guarded to 30…220 bpm, so a charging or pocketed ring
    /// yields none, whereas skin-temp keeps arriving from a docked ring.
    public struct Coverage: Equatable, Sendable {

        /// Detected opening edge of the night — `SleepStaging` segments' min start.
        public let inBedStart: Date
        /// Detected closing edge of the night — `SleepStaging` segments' max end. This is also the
        /// instant the card prints as the wake time, and the instant the copy names when it reports
        /// a gap; on 21 of 21 corpus nights it sits within one 150 s epoch of a real record (max
        /// 145 s), so naming it rather than the raw record keeps the caveat and the headline from
        /// disagreeing by a minute.
        public let inBedEnd: Date

        /// Newest measurement strictly BEFORE `inBedStart`, or nil.
        /// `LocalStore.latestSample(kind: .heartRate, before: inBedStart)`.
        public let lastMeasurementBeforeStart: Date?
        /// Oldest measurement strictly AFTER `inBedEnd`, or nil.
        /// `LocalStore.earliestSample(kind: .heartRate, after: inBedEnd)`.
        public let firstMeasurementAfterEnd: Date?
        /// Oldest measurement retained at all, or nil on an empty store.
        /// `LocalStore.earliestSample(kind: .heartRate)` — tells "the ring recorded nothing" from
        /// "retention no longer reaches back that far".
        public let earliestRetainedMeasurement: Date?

        public init(inBedStart: Date,
                    inBedEnd: Date,
                    lastMeasurementBeforeStart: Date?,
                    firstMeasurementAfterEnd: Date?,
                    earliestRetainedMeasurement: Date?) {
            self.inBedStart = inBedStart
            self.inBedEnd = inBedEnd
            self.lastMeasurementBeforeStart = lastMeasurementBeforeStart
            self.firstMeasurementAfterEnd = firstMeasurementAfterEnd
            self.earliestRetainedMeasurement = earliestRetainedMeasurement
        }
    }

    // MARK: - Output

    /// One thing that is true about this night's number. Several can hold at once, which is the
    /// whole reason this is a list and not another single-case enum.
    ///
    /// Each case carries the INSTANT the copy should name, so the UI can be concrete — "no recording
    /// between 02:37 and 06:39" rather than "this night may be incomplete".
    ///
    /// ⚠️ THE NAMES SAY "NO RECORDING", NOT "THE RING STOPPED", AND THAT IS DELIBERATE — the same bar
    /// `BedtimeProvenance` sets. What we can observe is that OUR store holds nothing across that
    /// span. A ring that stopped, a drain that has not caught up yet, a ring taken off and a
    /// contended resume pointer (#188) are indistinguishable from the persisted stream. Copy that
    /// blames the device would be an invented claim, and it would be wrong every time the real cause
    /// was our own sync — which, given `ack-implies-retain` and `in-drain-page-volatility`, is not a
    /// hypothetical.
    public enum Reason: Hashable, Sendable {

        /// Nothing was recorded for `silentFor` seconds after the night's trailing edge. The
        /// reported duration reads LOW by an unknown amount BOUNDED BY (not equal to) that gap.
        ///
        /// `from` is `Coverage.inBedEnd` — the same instant the card prints as the wake time.
        case noRecordingAfterWake(from: Date, silentFor: TimeInterval)

        /// Nothing was recorded for `silentFor` seconds before the night's leading edge, so the
        /// printed bedtime is where recording resumed, not where the user settled.
        ///
        /// ⚠️ OVERLAPS A SHIPPED HINT. `SleepCardView.bedtimeProvenanceHint` already says this,
        /// driven by `BedtimeProvenance` at its 300 s tolerance — a strictly WIDER band than the
        /// `materialGapSeconds` used here (4 of 21 corpus nights vs 3 of 21). A caller adopting this
        /// type must render one or the other, never both, or the same edge gets caveated twice.
        case noRecordingBeforeBedtime(until: Date, silentFor: TimeInterval)

        /// The legacy signal: a multi-hour night at implausibly high efficiency, i.e. still-but-awake
        /// time the ring cannot sense got absorbed into light sleep. Identical in meaning to
        /// `Level.durationLikelyHigh`; emitted only when no acquisition reason applies.
        case durationLikelyHigh
    }

    /// The full verdict on a night: the legacy level, plus every reason that holds, plus the two
    /// edge provenances the reasons were derived from (so a caller can drive an existing
    /// `BedtimeProvenance` hint from the same object instead of fetching the rows twice).
    public struct Assessment: Equatable, Sendable {

        /// EXACTLY what `SleepConfidence.classify(asleep:inBed:)` returns for these totals, with no
        /// coverage influence whatsoever. Preserved so adopting `assess` cannot silently move the
        /// shipped duration verdict.
        public let level: Level

        /// Every reason that holds, most-important first. At most one of each case.
        ///
        /// PRECEDENCE, and why: the back edge comes first because it is where both 246-minute corpus
        /// errors are AND the only one with no other surface in the app; the front edge next because
        /// `BedtimeProvenance` already reports it; `.durationLikelyHigh` last, and only when neither
        /// acquisition reason fired — telling someone their duration reads HIGH on a night whose
        /// recording stopped is the inverse of the truth. (`SleepCardView.swift:458` already applies
        /// the same mutual exclusion by hand against `isLikelyTruncated`; this makes it a property of
        /// the type. On the corpus the suppression is a measured no-op — the 4 nights that flag
        /// `.durationLikelyHigh` and the 3 that flag an acquisition reason do not intersect.)
        public let reasons: [Reason]

        /// Leading-edge provenance for these inputs (`BedtimeProvenance.classify`).
        public let bedtime: BedtimeProvenance.Verdict
        /// Trailing-edge provenance for these inputs (`WakeProvenance.classify`).
        public let wake: WakeProvenance.Verdict

        /// Whether anything at all should be said about this night.
        public var flags: Bool { !reasons.isEmpty }

        /// The single reason to show when there is room for only one.
        public var primary: Reason? { reasons.first }

        /// True when a reason describes MISSING RECORDS rather than an over-counted duration. The
        /// two are opposite claims and must never be rendered together.
        public var hasAcquisitionReason: Bool {
            reasons.contains { if case .durationLikelyHigh = $0 { return false } else { return true } }
        }
    }

    // MARK: - Classification

    /// Classify a night's confidence from its totals AND its acquisition coverage.
    ///
    /// - Parameters:
    ///   - asleep: total time asleep (Light + Deep + REM), seconds — `Summary.totalAsleep`.
    ///   - inBed:  the in-bed window, seconds — `Summary.inBed`.
    ///   - coverage: the six acquisition instants, or nil when the caller has none — in which case
    ///     the result is exactly the legacy verdict, expressed as a reason list.
    ///   - materialGapSeconds: how long the stream must be absent at an edge before it is worth
    ///     telling the user. Defaults to `WakeProvenance.materialGapSeconds` (60 min). Read the
    ///     constant's doc before changing it: the corpus cannot distinguish any cut in
    ///     (33 min, 242 min]. `0` makes every non-witnessed edge material; `.infinity` is the kill
    ///     switch — no acquisition reason is emitted and the result reduces to the legacy verdict.
    ///
    /// - Note: the DURATION test is unchanged and still gated at `minNightForFlag`. The acquisition
    ///   tests are NOT gated on night length, deliberately: the two nights the length gate discards
    ///   are the two worst nights in the corpus, and "the recording stopped" is exactly as true of a
    ///   102-minute night as of a 9-hour one.
    public static func assess(asleep: TimeInterval,
                              inBed: TimeInterval,
                              coverage: Coverage?,
                              materialGapSeconds: TimeInterval = WakeProvenance.materialGapSeconds)
        -> Assessment {

        let level = classify(asleep: asleep, inBed: inBed)

        guard let c = coverage else {
            return Assessment(level: level,
                              reasons: level == .durationLikelyHigh ? [.durationLikelyHigh] : [],
                              bedtime: .unknown, wake: .unknown)
        }

        let bedtime = BedtimeProvenance.classify(
            inBedStart: c.inBedStart,
            lastMeasurementBefore: c.lastMeasurementBeforeStart,
            earliestRetainedMeasurement: c.earliestRetainedMeasurement)
        let wake = WakeProvenance.classify(inBedEnd: c.inBedEnd,
                                           firstMeasurementAfter: c.firstMeasurementAfterEnd)

        var reasons: [Reason] = []

        if case .stoppedThenResumed(let gap) = wake, gap > materialGapSeconds {
            reasons.append(.noRecordingAfterWake(from: c.inBedEnd, silentFor: gap))
        }
        if case .resumedAfterGap(let gap) = bedtime, gap > materialGapSeconds {
            reasons.append(.noRecordingBeforeBedtime(until: c.inBedStart, silentFor: gap))
        }
        // The duration claim is the OPPOSITE of the acquisition claim — never both.
        if reasons.isEmpty, level == .durationLikelyHigh {
            reasons.append(.durationLikelyHigh)
        }

        return Assessment(level: level, reasons: reasons, bedtime: bedtime, wake: wake)
    }

    /// Convenience overload for a staged-night `Summary`.
    public static func assess(_ summary: SleepStaging.Summary,
                              coverage: Coverage?,
                              materialGapSeconds: TimeInterval = WakeProvenance.materialGapSeconds)
        -> Assessment {
        assess(asleep: summary.totalAsleep, inBed: summary.inBed,
               coverage: coverage, materialGapSeconds: materialGapSeconds)
    }
}

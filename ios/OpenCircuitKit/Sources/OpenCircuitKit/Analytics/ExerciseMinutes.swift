// Estimate Apple Exercise Time (elevated-HR minutes) from stored HR samples (#82).
//
// SCOPE — BASIC ESTIMATE ONLY.
// A basic threshold model: minutes where HR ≥ 50% of max HR (equivalent to brisk
// walking, Apple's own exercise definition). This estimate uses ONLY the decoded
// HR samples we have — sleep-window bulk epochs (0x4c[4], 🟢) and live monitoring
// readings — and EXCLUDES the overnight sleep window to avoid counting sleeping
// elevated HR as voluntary exercise.
//
// ⚠️ The FULL 4-level intensity mapping (Vigorous/Moderate/Low/Inactive minutes) is
// GATED on the *separate, still-uncaptured* 历史活动响应 activity record (#93,
// PROTOCOL.md §5.3.1) — NOT on 0x4c[15:22], which is just the tail of the
// already-decoded `acti_counts` intensity blob on the MEASUREMENT record we already
// have (a same-record "is it moving" signal, not 4 calibrated bands). Do not invent
// 4 intensity buckets from the basic HR threshold alone. This file is the
// basic-threshold placeholder until that capture (sync-open `byte[6]=0x02`, see
// `RingSession.probeActivityChannels`) lands and the bands can be calibrated against
// the app's own per-day readout.
//
// HealthKit target: `.appleExerciseTime` (written by HealthKitWriter as a delta,
// not stored as a ring sample in LocalStore).

import Foundation

public enum ExerciseMinutes {

    /// ══ THE PERSONALISED THRESHOLD IS OFF. READ THIS BEFORE TURNING IT BACK ON. ══
    ///
    /// `false` ⇒ the %-of-max model, byte-identical to what shipped through build 41. This is the
    /// ONE switch: `elevatedPieces`, `estimate` and `Calories` all resolve their baseline through
    /// `effectiveRestingBaseline`, so nothing can be left half-converted.
    ///
    /// It is off because the personalised model as tuned here is WRONG IN THE OTHER DIRECTION, and
    /// that was measured, not guessed. Release review built this Kit and ran realistic days at the
    /// ring's 150 s epoch cadence: a 35-year-old walker with a 66.5 bpm resting pulse, walking at
    /// 96–99 bpm, went from **95 elevated minutes to 0**, active calories 406 → 72, and an Activity
    /// Score of 100 to 50 — on a completely unchanged day. The tester whose report motivated the
    /// change went from 200 minutes to 0. And it is provably one-directional: `new < old` requires
    /// `rhr < maxHR/6 ≈ 31 bpm`, which the 35 bpm plausibility floor excludes, so NO user anywhere
    /// gains a single minute or calorie.
    ///
    /// The error was mine and it is worth naming precisely, because the arithmetic below is fine.
    /// 0.40 HRR is the textbook ACSM floor for MODERATE INTENSITY — but this file estimates Apple
    /// EXERCISE TIME, whose definition is "brisk walk or above", and a brisk walk does not reach
    /// 40 % HRR. Equating the two is a taxonomy conflation; it made us stricter than the metric we
    /// are approximating. I measured the fix on a high-resting-pulse day, saw 280 min → 12.5, and
    /// read the collapse as success without asking whether 12.5 was the right answer for a day that
    /// contained a real walk. It was not.
    ///
    /// The reported defect is still real — an absolute %-of-max bar over-credits a fast resting
    /// pulse — and heart-rate reserve is still the right shape for the fix. What it needs before it
    /// ships: a fraction re-fitted against days with KNOWN activity (review's sweep put the cliff
    /// between 0.25 and 0.30 HRR — 0.25 → 60 min, 0.30 → 2 min, so ~0.25 is the candidate), a
    /// resting baseline that outlives the day so the ring cannot run backwards mid-morning, and a
    /// re-baselined `GoalDefaults.defaultActivityMinutes` (still 30, set against the old bar).
    public static let personalisedThresholdEnabled = false

    /// Fraction of HEART-RATE RESERVE at which a reading counts as elevated. Dormant while
    /// `personalisedThresholdEnabled` is false. ⚠️ 0.40 is the ACSM MODERATE floor, which is NOT the
    /// same band as Apple's "brisk walk or above" — see above. Re-fit before enabling.
    public static let hrReserveFraction = 0.40

    /// The baseline every consumer must resolve through, so the kill-switch cannot be honoured in
    /// one place and ignored in another.
    ///
    /// This exists because the first version of the switch DIDN'T work: `Calories.legacyDailyEstimate`
    /// re-derived the baseline directly, so flipping `deriveRestingHR` produced a hybrid — old-model
    /// minutes divided into new-model qualifying samples. Release review measured the wreckage
    /// (40 min priced at 0.00 kcal where 161.66 was correct; 70 min at 574.69 where 410.09 was
    /// correct, +40 %) and noted `swift test` could not see it, because both models are individually
    /// self-consistent. A kill-switch that corrupts the thing it is meant to restore is worse than
    /// no kill-switch.
    public static func effectiveRestingBaseline(
        _ hrSamples: [HRSample],
        derive: Bool = personalisedThresholdEnabled
    ) -> Double? {
        derive ? restingBaseline(hrSamples) : nil
    }

    /// Plausibility band for a derived resting HR. Outside it we do not trust the value and fall
    /// back to the %-of-max model rather than compute a threshold off a bad baseline.
    ///
    /// The 90 ceiling is deliberately below the physiological maximum for a resting pulse: a
    /// derived value that high is far more likely to mean "this sample set never contained rest"
    /// than "this person rests at 95". Falling back there errs toward the LOWER threshold, i.e.
    /// toward crediting the user, which is the safe direction for a goal ring.
    static let plausibleRestingHR: ClosedRange<Double> = 35 ... 90

    /// Minimum readings before a derived resting baseline is trusted.
    static let minRestingBaselineSamples = 12
    /// Minimum span the readings must cover before a derived resting baseline is trusted.
    ///
    /// These guards exist because `lowestSustained` answers "what is the quietest stretch IN THIS
    /// ARRAY", which is only a resting HR if the array actually contains a quiet stretch. Three
    /// readings taken during a workout produce a "resting HR" of 100 and a threshold of 134 — the
    /// exact failure a unit fixture hit when this landed.
    ///
    /// ⚠️ 2 h, NOT the 4 h this first shipped with, and the reason is a real UX defect adversarial
    /// review measured (2026-08-12). The derived threshold is always ≥ the %-of-max one for any
    /// realistic age (new < old ⟺ rhr < maxHR/6, impossible with rhr floored at 35), so the moment
    /// this guard flips the threshold JUMPS UP and the day's elevated minutes JUMP DOWN. Measured at
    /// maxHR 185: a ring put on at 07:00, 1 h at 62 bpm then a 40-min walk at 95 bpm read 40 elevated
    /// minutes (baseline nil, threshold 92) and then **0** once the span passed the guard (baseline
    /// 62, threshold 111) — the goal ring visibly running backwards mid-morning.
    ///
    /// Halving the span halves that exposure without weakening the "did this array contain rest"
    /// test, because that test is really carried by `plausibleRestingHR` and by the
    /// sustained-window requirement below, not by elapsed time. On any ring worn overnight the
    /// guard is satisfied long before waking and the day is unaffected either way.
    ///
    /// 🔴 KNOWN RESIDUAL, not fixed here: the jump still exists inside the first 2 h after a ring is
    /// put on (charge-day mornings, day 1 of pairing). Eliminating it needs a baseline that outlives
    /// the day — yesterday's stored resting HR carried in as a fallback — which is real plumbing
    /// through every `Calories.dailyEstimate` call site and is the named follow-up.
    /// `testEstimateIsNonMonotonicAcrossTheBaselineBoundary` pins the current behaviour so the
    /// boundary is visible rather than surprising.
    static let minRestingBaselineSpan: TimeInterval = 2 * 3600

    /// HR threshold for exercise, in bpm.
    ///
    /// ══ WHY THIS IS RELATIVE TO RESTING HR ══
    ///
    /// With `restingHR` nil this is the ORIGINAL model — 50 % of max HR — kept byte-identical as
    /// the degrade path and the kill-switch.
    ///
    /// That model is wrong in a specific, reported way: it ignores where the person STARTS. A
    /// tester wrote "Elevated HR… seems to fill up too easily… it was nearly complete right after I
    /// woke up. I generally have a fast heart rate" (2026-08-12). She is describing the defect
    /// exactly. At age 35 the old threshold is 92 bpm for everyone; for someone resting at 78 that
    /// is 14 bpm above rest — reached by standing up and making coffee — while for someone resting
    /// at 45 the same 92 bpm is real exertion. One absolute number cannot mean the same thing to
    /// both, so the ring filled from ordinary morning ambulation for her and would under-credit an
    /// endurance athlete on the same day.
    ///
    /// Heart-rate reserve is the standard fix and the one the exercise-physiology literature
    /// defines intensity in: `threshold = RHR + fraction · (maxHR − RHR)` (Karvonen). At 40 % HRR
    /// the same two people get 120 bpm and 101 bpm — each 40 % of the way up their OWN range.
    /// (78 + 0.4·107 = 120.8 → 120 after truncation; 45 + 0.4·140 = 101.)
    ///
    /// Note this generally RAISES the threshold versus 50 % maxHR (ACSM puts 40–59 % HRR at
    /// 64–76 % maxHR, so the old constant sat below even the LIGHT band). Elevated-HR minutes and
    /// the active-calorie estimate that prices the same qualifying periods therefore both come
    /// down. That is the intended direction: the old number over-credited.
    ///
    /// The `max(…, 60)` absolute floor is retained from the original model unchanged — no adult's
    /// exercise threshold should land below 60 bpm regardless of what the inputs say.
    ///
    /// NOTE: Full 4-level intensity (Vigorous/Moderate/Low/Inactive) follows the #93
    /// activity-record capture (PROTOCOL.md §5.3.1), not the current measurement record.
    public static func threshold(maxHR: Int, restingHR: Double? = nil) -> Int {
        let mx = Double(max(maxHR, 1))
        guard let rhr = restingHR, plausibleRestingHR.contains(rhr), rhr < mx else {
            return max(Int(mx * 0.5), 60)
        }
        return max(Int(rhr + hrReserveFraction * (mx - rhr)), 60)
    }

    /// The resting-HR baseline to price a day's elevated time against, derived from the SAME HR
    /// samples the estimate is computed over.
    ///
    /// Deriving it here rather than threading a parameter through every call site is deliberate and
    /// load-bearing: `ExerciseMinutes.elevatedPieces` is the single owner of "which periods count",
    /// and `Calories` prices exactly those periods. A caller that forgot to pass the baseline would
    /// silently produce a different qualifying set for calories than for the minutes ring — the one
    /// invariant `GoalsCardView`'s footnote promises the user ("Active calories and elevated-HR
    /// minutes now use the same qualifying heart-rate periods"). Same input samples ⇒ same
    /// baseline ⇒ same periods, with no call site able to get it wrong.
    ///
    /// `RestingHR.lowestSustained` is the lowest rolling 5-min mean — Apple Health's own resting-HR
    /// convention. nil — too few samples, too short a span, no genuinely sustained window, or a
    /// value outside `plausibleRestingHR` — degrades to the %-of-max model.
    ///
    /// ⚠️ THE SUSTAINED-WINDOW CHECK IS NOT REDUNDANT. `lowestSustained` falls back to the single
    /// lowest reading whenever NO 5-min window held two readings, and the production auto-measure
    /// cadence is 600 s — longer than that window. So on a day whose HR is spot reads only (before
    /// the morning bulk sync, or a night that never synced) every window holds one reading and the
    /// "resting HR" becomes the day's single lowest read: one poor-contact 40 bpm sample would set
    /// the bar for the whole day. Adversarial review reproduced it — 30 reads at 10-min spacing, all
    /// 68 bpm except one 44, gave a baseline of 44.0 (2026-08-12). An earlier version of this comment
    /// claimed `lowestSustained`'s ≥2-reading rule prevented exactly that; it does not, because of
    /// the fallback. Asking for the guarantee explicitly is what makes the claim true.
    public static func restingBaseline(_ hrSamples: [HRSample]) -> Double? {
        let valid = hrSamples.filter { LiveHR.validBPM.contains($0.bpm) }
        guard valid.count >= minRestingBaselineSamples,
              let first = valid.map(\.start).min(), let last = valid.map(\.start).max(),
              last.timeIntervalSince(first) >= minRestingBaselineSpan,
              let derived = RestingHR.lowestSustainedDetailed(hr: valid,
                                                              window: RestingHR.sustainedWindow),
              derived.wasSustained
        else { return nil }
        return plausibleRestingHR.contains(derived.value) ? derived.value : nil
    }

    /// Estimate exercise minutes as the total merged duration of elevated-HR intervals,
    /// excluding samples that fall inside a sleep window.
    ///
    /// Algorithm:
    /// 1. Filter to samples with HR ≥ threshold and outside the sleep window.
    /// 2. Map each sample to an interval. Samples with a real span (end > start) use it
    ///    directly. POINT samples (start == end) are ambiguous on the wire: a 0x4c bulk
    ///    sleep-vitals epoch genuinely spans `epochSeconds`, but a live-HR spot read
    ///    (RingSession persists these as point samples too) represents only an instant.
    ///    To keep the bulk-epoch behavior without letting one isolated non-exercise spot
    ///    read inflate the Apple Exercise ring by a full 2.5 min, a point sample gets the
    ///    full `epochSeconds` width ONLY when it is part of a run of ≥2 consecutive
    ///    elevated readings spaced within one epoch (back-to-back bulk epochs / sustained
    ///    elevated HR). An ISOLATED elevated point read gets only `pointSampleWidth`
    ///    (default 0 — a single spot read is not evidence of voluntary exercise).
    /// 3. Merge overlapping intervals so consecutive elevated epochs are counted once.
    /// 4. Return the sum of merged interval durations in minutes.
    ///
    /// ESTIMATE — based on available HR samples only. Accuracy improves after #93 decode.
    ///
    /// Defined as the total duration of `elevatedPieces` so the scalar the Apple Exercise ring
    /// writes and the per-piece slices the energy estimate prices can never drift apart. See
    /// `elevatedPieces` for the algorithm; this contract is unchanged.
    public static func estimate(
        hrSamples: [HRSample],
        maxHR: Int,
        sleepWindow: DateInterval? = nil,
        epochSeconds: TimeInterval = TimeInterval(BulkRecord.epochSeconds),
        pointSampleWidth: TimeInterval = 0,
        restingHR: Double? = nil,
        deriveRestingHR: Bool = personalisedThresholdEnabled
    ) -> Double {
        let seconds = elevatedPieces(hrSamples: hrSamples,
                                     maxHR: maxHR,
                                     sleepWindow: sleepWindow,
                                     epochSeconds: epochSeconds,
                                     pointSampleWidth: pointSampleWidth,
                                     restingHR: restingHR,
                                     deriveRestingHR: deriveRestingHR)
            .reduce(0.0) { $0 + $1.seconds }
        return seconds / 60.0
    }

    /// One disjoint slice of elevated-HR time, carrying the bpm that priced it.
    ///
    /// `estimate` collapses the day to a single duration, which forces any energy model built on
    /// it to price the whole day at ONE average HR. That average is what froze active energy for
    /// the rest of the day once the last bout ended, and what let an isolated spot read dilute a
    /// morning workout's price (tester, 2026-07-28). Pieces keep the time structure so each slice
    /// can be priced — and placed — on its own.
    public struct ElevatedPiece: Equatable, Sendable {
        public let start: Date
        public let end: Date
        public let bpm: Int

        public init(start: Date, end: Date, bpm: Int) {
            self.start = start
            self.end = end
            self.bpm = bpm
        }

        public var seconds: TimeInterval { Swift.max(0, end.timeIntervalSince(start)) }
    }

    /// The same elevated intervals `estimate` sums, emitted as NON-OVERLAPPING, chronologically
    /// ordered slices that each carry their own bpm. Filtering, point-sample widening and overlap
    /// collapse are identical to `estimate` — which is now defined in terms of this — so the two
    /// can never disagree about how much elevated time a day contains.
    ///
    /// Overlap rule: where two elevated samples cover the same instant, the EARLIER one keeps it
    /// (the later slice starts where the earlier ends). Total duration is therefore exactly the
    /// merged-union duration, and a live spot read landing inside a bulk epoch cannot add time.
    ///
    /// `restingHR` personalises the threshold (see `threshold(maxHR:restingHR:)`). Left nil — every
    /// production call site — it is DERIVED from `hrSamples` via `restingBaseline`, so callers
    /// cannot accidentally price calories against a different qualifying set than the minutes ring
    /// uses. Pass a value explicitly only to override that derivation.
    ///
    /// `deriveRestingHR: false` is THE KILL-SWITCH: it restores the pre-HRR %-of-max model exactly,
    /// everywhere at once. It exists as a parameter rather than a mutable global so it stays
    /// Sendable and so the tests can pin both models side by side; flipping this default to `false`
    /// is the one-line revert. Note nil-`restingHR` alone does NOT mean "old model" here — nil means
    /// "derive it", which is why this flag is separate.
    public static func elevatedPieces(
        hrSamples: [HRSample],
        maxHR: Int,
        sleepWindow: DateInterval? = nil,
        epochSeconds: TimeInterval = TimeInterval(BulkRecord.epochSeconds),
        pointSampleWidth: TimeInterval = 0,
        restingHR: Double? = nil,
        deriveRestingHR: Bool = personalisedThresholdEnabled
    ) -> [ElevatedPiece] {
        let effectiveRHR = restingHR ?? effectiveRestingBaseline(hrSamples, derive: deriveRestingHR)
        let thresh = threshold(maxHR: maxHR, restingHR: effectiveRHR)
        let elevated = hrSamples
            .filter { s in
                s.bpm >= thresh
                    && (sleepWindow.map { !$0.contains(s.start) } ?? true)
            }
            .sorted { $0.start < $1.start }

        guard !elevated.isEmpty else { return [] }

        // Build intervals. Real-span samples use their own duration. A point sample gets a
        // full epoch only when it neighbours another elevated reading within one epoch
        // (a sustained run); an isolated point read gets only `pointSampleWidth`.
        let intervals: [(start: Date, end: Date, bpm: Int)] = elevated.enumerated().map { idx, s in
            let dur = s.end.timeIntervalSince(s.start)
            if dur > 0 { return (s.start, s.end, s.bpm) }
            let prevClose = idx > 0
                && s.start.timeIntervalSince(elevated[idx - 1].start) <= epochSeconds
            let nextClose = idx < elevated.count - 1
                && elevated[idx + 1].start.timeIntervalSince(s.start) <= epochSeconds
            let width = (prevClose || nextClose) ? epochSeconds : pointSampleWidth
            return (s.start, s.start.addingTimeInterval(width), s.bpm)
        }

        // Collapse overlaps by sweeping a cursor instead of merging into maximal runs: each
        // interval contributes only the part not already covered. The emitted slices therefore
        // tile exactly the same union the old merge produced (same total duration), but keep the
        // per-slice bpm the merge threw away.
        var pieces: [ElevatedPiece] = []
        var cursor: Date?
        for interval in intervals {
            let start = cursor.map { Swift.max(interval.start, $0) } ?? interval.start
            guard interval.end > start else { continue }  // fully covered, or zero-width
            pieces.append(ElevatedPiece(start: start, end: interval.end, bpm: interval.bpm))
            cursor = interval.end
        }
        return pieces
    }
}

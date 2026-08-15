// Did we WATCH the user go to bed, or is the "bedtime" we print just where the data starts? (#198)
//
// #193 settled the arithmetic half of this and found nothing left to win. On 2026-08-08→09 the ring
// charged 22:19:38–22:35:12 (🟢 hardware-witnessed: 59 descriptors with charger byte [2] == 0x04,
// battery 58→81 %) and records resume 22:36:18. #193 correctly moved the detected block's opening
// edge to 22:36:18 — but 22:36:18 is "the first moment the ring was back on a wrist", and the app
// labels it BEDTIME. Every alternative anchor #193 tried lands on 22:36:18 or later; anything
// earlier would be fabricated, and there are n = 0 bedtime labels in the corpus to justify anything
// later. So the NUMBER is as good as it gets and what remains is a TRUST problem: a leading edge
// that is an artifact of when recording resumed is presented exactly like one we observed.
//
// This classifier answers only that question, and answers it from evidence that is already on disk.
//
// ⚠️ IT DELIBERATELY DOES NOT NAME A CAUSE. Charging, taking the ring off, and a BLE dropout are
// indistinguishable from the persisted record stream — the charger byte rides the live 0x10/0x87
// descriptor and is never stored per epoch. Reporting a gap as "you were charging" would be exactly
// the invented claim the #198 bar forbids. It reports THAT the stream was absent and for how long;
// the copy layer says no more than that.
//
// Pure (no Apple frameworks) so it unit-tests on the CLI.

import Foundation

public enum BedtimeProvenance: Equatable, Sendable {

    /// What the record stream says about the moment the night's in-bed window opens.
    public enum Verdict: Equatable, Sendable {
        /// The stream runs CONTINUOUSLY into the detected bedtime — the ring was on a wrist and
        /// measuring right up to that moment, so the edge is an observed settle, not a data edge.
        case witnessed
        /// The stream STOPS and then resumes at the detected bedtime. The associated value is how
        /// long the ring recorded nothing beforehand. The true bedtime may be anywhere in that gap.
        case resumedAfterGap(TimeInterval)
        /// There is no measurement at all before the detected bedtime, and retention reaches far
        /// enough back that its absence is real (first sync after a new ring / a history reset).
        case noPriorMeasurement
        /// Retention does not reach far enough back to judge. Distinct from `witnessed` on purpose:
        /// "we did not look" must never be presented as "we watched".
        case unknown
    }

    /// How close the last measurement must sit to the bedtime for the stream to count as CONTINUOUS.
    ///
    /// The ring emits one 0x4c epoch every 150 s, so on an unbroken stream the newest measurement
    /// before any instant is at most one cadence old. Two cadences (300 s) absorbs a single dropped
    /// or unparsed epoch without calling an intact stream a gap. Anything beyond this is the ring
    /// genuinely not measuring, which is the case #198 is about.
    public static let continuousToleranceSeconds: TimeInterval = 300

    /// How far back retention must reach before the ABSENCE of prior measurement is evidence.
    ///
    /// Below this we return `.unknown`: a night at the very edge of the retention window has no
    /// prior rows simply because they were pruned, which says nothing about the wearer.
    public static let priorEvidenceWindowSeconds: TimeInterval = 30 * 60

    /// Classify the leading edge of a night's in-bed window.
    ///
    /// - Parameters:
    ///   - inBedStart: the detected opening edge of the night.
    ///   - lastMeasurementBefore: timestamp of the newest wrist measurement strictly before
    ///     `inBedStart`, or nil if there is none. Callers should pass a HEART-RATE observation:
    ///     HR is band-guarded to 30…220 bpm, so a charging or pocketed ring produces none, which is
    ///     exactly the "not on a wrist" signal wanted here. A skin-temp or step row is NOT a
    ///     substitute — those keep arriving from a docked ring and would call a charge cycle
    ///     "witnessed".
    ///   - earliestRetainedMeasurement: timestamp of the OLDEST measurement still on disk, used to
    ///     tell "nothing was recorded" from "nothing was retained". nil when the store is empty.
    public static func classify(inBedStart: Date,
                                lastMeasurementBefore: Date?,
                                earliestRetainedMeasurement: Date?) -> Verdict {
        guard let last = lastMeasurementBefore else {
            // No prior measurement. Only meaningful if retention reaches back far enough that we
            // WOULD have seen one.
            guard let earliest = earliestRetainedMeasurement,
                  earliest <= inBedStart.addingTimeInterval(-priorEvidenceWindowSeconds) else {
                return .unknown
            }
            return .noPriorMeasurement
        }
        // A measurement at or after the edge is not "before" it; treat a caller that passes one as
        // giving no usable evidence rather than silently computing a negative gap.
        guard last < inBedStart else { return .unknown }
        let gap = inBedStart.timeIntervalSince(last)
        return gap <= continuousToleranceSeconds ? .witnessed : .resumedAfterGap(gap)
    }

    /// Whether the UI must qualify the bedtime it prints. `.witnessed` is the only verdict that
    /// earns an unqualified clock time; `.unknown` qualifies too, because not having looked is not
    /// the same as having seen.
    public static func needsQualification(_ verdict: Verdict) -> Bool {
        verdict != .witnessed
    }
}

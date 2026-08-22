// THE ONE LINE THAT LETS THE APPLE HEALTH SUBTRACTION SHIP.
//
// The provenance change stops writing invented sleep to Apple Health. Shipped alone, that opens a
// gap nothing on screen accounts for: on a real tester night the Sleep card still reads 6 h 43 m at
// 92 % while Health quietly holds 2 h 42 m. The land review made the release conditional on closing
// exactly that gap — "ship the semantics and storage alone, OR ship the Health subtraction together
// with the card copy — never the subtraction alone."
//
// WHY THIS CARRIES NO DETECTION RISK, unlike the parked coverage-caveat card. That card fires on a
// DETECTED condition (a suspected data gap) whose false-positive rate is unknown and unmeasurable
// from the corpus. This line fires on two facts that are both CERTAIN and both already on the row:
//
//   1. the user EDITED this night — `isManuallyEdited`, set by their own Save; and
//   2. some of the sleep the card is showing sits over ground holding NO records —
//      `assertedAsleepSeconds`, computed by `SleepProvenanceBreakdown` from the record set itself
//      and persisted with the row (`sleepBasis == .assertedTagged`).
//
// Neither is an inference, so neither can be a false positive. There is nothing here to detect: we
// know they edited it because they edited it, and we know we hold nothing there because we hold
// nothing there.
//
// IT MUST NOT SCOLD. The wearer told us something true that the ring could not see. The copy keeps
// their times ("We kept the times you set"), calls the unmeasured part "your own account" rather
// than a guess or an estimate, and reports the Health consequence as a fact about what this app
// writes — never as a judgement about the night.
//
// 🟢 THE TWO DEVICE NIGHTS IT WAS WRITTEN AGAINST (Gen 2 Air, Europe/Paris, both hand-corrected by
// the wearer; numbers re-derived from raw bytes by `SleepProvenanceCardProbe`):
//   R2_2026-08-18  card 403 asleep = 162 measured + 241 asserted -> Health 161.6 asleep-min
//   R2_2026-08-17  card 246 asleep =   3 measured + 243 asserted -> Health   2.9 asleep-min
//
// Pure (no Apple frameworks) so the exact rendered sentence unit-tests on the CLI and can be printed
// per-night by the corpus harness.

import Foundation

/// The Sleep-card line for an edited night that contains asserted-unmeasured sleep.
///
/// ⚠️ SCOPED TO ASSERTED **ASLEEP**, DELIBERATELY, AND THIS IS A DECLARED LIMIT — not an oversight.
/// `healthPublishable` also drops `.awake` segments over unrecorded ground, so a night can hold
/// asserted AWAKE with zero asserted asleep and still differ from Health. Measured on the corpus:
/// exactly one such night (`R1_2026-08-16`, 120.3 min asserted awake, 0.0 asserted asleep) out of
/// the three non-discounted replayable edits. It stays SILENT, because the difference it produces is
/// representational rather than quantitative: the `.inBed` layer is published in full, so Apple
/// Health's "Time in Bed" is unchanged and those minutes simply read as in-bed instead of as awake —
/// which is how Apple's own Sleep UI shows "in bed, not known to be asleep" anyway. The asleep case
/// is different in kind: Health's headline "Time Asleep" falls by four hours, which is the number a
/// wearer notices and disbelieves. Widening to awake would need a third sentence for a difference no
/// user has reported; if a reviewer disagrees, the gate is one comparison.
public enum SleepEditedNightNotice {

    /// Least asserted-asleep time worth a line. NOT a detection threshold — the condition is already
    /// certain — purely a rendering floor: below one whole minute the sentence would print "1 minute"
    /// for a sub-minute rounding artifact and the Apple Health difference it explains would be
    /// invisible. A night under this simply stays silent.
    public static let minAssertedAsleep: TimeInterval = 60

    /// Below this the ring measured NOTHING and a different sentence is used, because `duration`
    /// floors at one minute and "the ring recorded 1 minute" would then be a fabrication.
    ///
    /// Deliberately sub-second rather than a round minute: at 40 measured seconds "the ring wasn't
    /// recording for any of this night" would be an overstatement, and `duration(40)` already
    /// renders the honest "1 minute". Only true zero gets the stronger sentence.
    public static let noMeasuredAsleep: TimeInterval = 1

    /// The rendered line, or `nil` when this night must stay silent.
    ///
    /// - Parameters:
    ///   - measuredAsleep: asleep seconds over ground the ring recorded across
    ///     (`StoredSleepSummary.measuredAsleepSeconds`). A NEGATIVE value is the store's
    ///     "not computed" sentinel and returns `nil` — never treated as zero, because "we did not
    ///     compute it" and "the ring measured nothing" are different statements and only one of them
    ///     may be printed.
    ///   - assertedAsleep: asleep seconds the user's edit claims over ground holding no records
    ///     (`StoredSleepSummary.assertedAsleepSeconds`). Negative is the same sentinel.
    ///   - mirrorsSleepToHealth: whether this app is actually writing sleep to Apple Health right
    ///     now. When false the Health sentence is DROPPED rather than reworded: telling a user whose
    ///     Health sleep permission is off what Apple Health "gets" would be exactly the kind of
    ///     unearned claim this whole change exists to remove. Callers must pass the real permission
    ///     state; the parameter has no default for that reason.
    public static func line(measuredAsleep: TimeInterval,
                            assertedAsleep: TimeInterval,
                            mirrorsSleepToHealth: Bool) -> String? {
        guard measuredAsleep >= 0, assertedAsleep >= minAssertedAsleep else { return nil }
        let asserted = duration(assertedAsleep)

        // ⚠️ THE HEALTH CLAUSE IS SCOPED TO **THIS NIGHT**, on purpose. A blanket "only measured
        // sleep is written to Apple Health" would be FALSE in this app: a manually typed nap is
        // unmeasured sleep and is still mirrored unlabelled (a declared open decision, not a
        // defect this line may paper over). "The measured part" refers to the figure named in the
        // sentence before it, so the claim stays inside what this night's row can support.
        // ⚠️ "FOR THE OTHER <span> WE HAVE…" IS A GRAMMAR FIX, NOT A STYLE ONE. The obvious phrasing
        // — "the other \(asserted) is your account" — is ungrammatical for every sub-hour plural the
        // formatter can produce ("the other 2 minutes is…"), which is reachable on any modest edit
        // into a small hole. Putting the span in a prepositional phrase makes the sentence agree for
        // both "1 minute" and "4h 1m" without branching on the number.
        if measuredAsleep < noMeasuredAsleep {
            let head = "We kept the times you set. The ring wasn’t recording for any of this night, "
                + "so all \(asserted) of the sleep above is your account, not a measurement."
            guard mirrorsSleepToHealth else { return head }
            return head + " No sleep reaches Apple Health for this night — only your time in bed."
        }

        let head = "We kept the times you set. The ring recorded \(duration(measuredAsleep)) of the "
            + "sleep above; for the other \(asserted) we have your account, not a measurement."
        guard mirrorsSleepToHealth else { return head }
        return head + " Only the measured part reaches Apple Health, so your sleep there reads shorter."
    }

    /// A span at the precision the measurement supports — whole minutes under an hour, then hours and
    /// minutes. Never seconds: the underlying edges are 150 s epoch boundaries.
    ///
    /// This is the Sleep card's existing house formatter, lifted here so the new line and the
    /// bedtime-provenance line it sits beside cannot drift apart.
    public static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(Int((seconds / 60).rounded()), 1)
        if minutes < 60 { return "\(minutes) minute\(minutes == 1 ? "" : "s")" }
        let (h, m) = (minutes / 60, minutes % 60)
        return m == 0 ? "\(h) hour\(h == 1 ? "" : "s")" : "\(h)h \(m)m"
    }
}

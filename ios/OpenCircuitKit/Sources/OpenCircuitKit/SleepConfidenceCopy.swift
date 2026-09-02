// The SENTENCES the sleep card puts under a night, derived from `SleepConfidence.Assessment`.
//
// WHY THE COPY LIVES IN THE KIT AND NOT IN THE VIEW. The corpus harness
// (`SleepCoverageMeasureTests`) is a CLI `swift test` target: it can stage all 21 nights from raw
// bytes and ask the shipped classifier what it thinks, but it cannot instantiate a SwiftUI view. If
// the strings lived in `SleepCardView`, "what does the card actually SAY on R2_2026-08-18" would be
// unanswerable without a device, and the only measurable thing would be a boolean. With the copy
// here, the harness prints the final card state for every corpus night — which is the whole point of
// a flag whose value is entirely in what the wearer reads. `HeadacheAlertCopy` (HealthAlerts.swift)
// already sets this precedent for notification titles/bodies.
//
// THREE RULES THE STRINGS BELOW OBEY, each one measured rather than stylistic:
//
//  1. NAME THE MEASUREMENT, NEVER A CAUSE. "Nothing was recorded between 02:37 and 06:39" is what the
//     store says. "The ring stopped" is a guess: a stopped ring, a dead battery, a contended resume
//     pointer (#188 / `in-drain-page-volatility`) and the wearer taking the ring off are
//     indistinguishable from the persisted stream — and when the cause is our OWN sync, blaming the
//     device is not just unsupported, it is wrong.
//  2. STATE THE GAP, NEVER AN INFERRED SLEEP TOTAL. The gap BOUNDS the error; it does not estimate
//     it. On `R2_2026-08-17` / `R2_2026-08-18` the hole matched the error to within 2.4 and 4.1 min
//     only because both testers slept through the whole hole; on `R1_2026-08-16` a 241.3 min hole
//     sits against a 120.0 min error because she went to bed INSIDE it (n = 3).
//  3. POINT AT EDIT. It is the only lever the wearer has, and an edit is also the supervised LABEL
//     this whole area lacks (`SleepEditLabel.minimumNightsToFit` = 10; the corpus has 5).
//
// Pure (no Apple frameworks, no SwiftUI) so it unit-tests on the CLI. The one thing it cannot own is
// the CLOCK format — that is locale- and calendar-dependent — so the caller injects it.
//
// ⚠️ REVIVED 2026-09-01 from the parked `feat/sleep-coverage-card` (a9f249c, 2026-08-19), which had
// fallen 103 commits behind master. Its `exportName`/`gapSeconds` helpers are NOT reproduced here:
// they shipped to master separately in `SleepConfidenceCoverage.swift` and are already the wire
// format the exports use. Only the SENTENCES were still missing.

import Foundation

extension SleepConfidence {

    /// One caveat as the card will render it: which `Reason` produced it, the SF Symbol beside it,
    /// and the sentence itself. Deliberately carries NO colour: a tint is a SwiftUI value, and the
    /// card paints every hint `.secondary` on purpose (see `SleepCardView.coverageHints`).
    public struct Hint: Equatable, Sendable {
        public let reason: Reason
        public let systemImage: String
        public let text: String

        public init(reason: Reason, systemImage: String, text: String) {
            self.reason = reason
            self.systemImage = systemImage
            self.text = text
        }
    }

    /// A gap rendered at the precision the measurement supports — whole minutes under an hour, then
    /// hours and minutes. NEVER seconds: every edge here is a 150 s epoch boundary, so a "4 h 1 m
    /// 36 s" would assert a precision the cadence cannot carry.
    ///
    /// Moved here verbatim from `SleepCardView.approximateDuration` so the card and the exports
    /// cannot render the same gap two different ways.
    public static func approximateDuration(_ seconds: TimeInterval) -> String {
        let minutes = max(Int((seconds / 60).rounded()), 1)
        if minutes < 60 { return "\(minutes) minute\(minutes == 1 ? "" : "s")" }
        let (h, m) = (minutes / 60, minutes % 60)
        return m == 0 ? "\(h) hour\(h == 1 ? "" : "s")" : "\(h)h \(m)m"
    }

    /// Render an assessment's reasons, IN ORDER, as the card's caveat rows.
    ///
    /// - Parameters:
    ///   - assessment: the result of `SleepConfidence.assess`.
    ///   - clock: renders an instant as a short local time ("2:37 AM"). Injected because the format
    ///     is locale/calendar-dependent and this file is framework-free; the card passes its own
    ///     `Self.clock`, so the caveat and the times printed above it are formatted identically.
    /// - Returns: zero, one or more hints. An empty array means SAY NOTHING — the common case
    ///   (12 of 21 corpus nights). Order is `assessment.reasons`' order: back edge, then front edge,
    ///   then the legacy duration note, which `assess` already suppresses whenever either edge fired.
    ///
    /// - Note: there is no `.noPriorMeasurement` copy, unlike the hint this replaces. That
    ///   `BedtimeProvenance` branch is UNREACHABLE from the card's real caller — it needs "no
    ///   measurement before the edge" AND "retention reaches ≥30 min before the edge", and both
    ///   inputs are read from the same single-kind store, so the second cannot hold when the first
    ///   does. The shipped card carried a sentence that could never render (`SleepCardView`
    ///   :542-544 before this change); it is not reproduced here.
    public static func hints(_ assessment: Assessment,
                             clock: (Date) -> String) -> [Hint] {
        assessment.reasons.map { reason in
            switch reason {

            // BACK EDGE — the one with no other surface in the app, and where both 246-minute corpus
            // errors are. Names BOTH instants and the gap: the wearer can check the claim against
            // their own memory of the night, which "this night may be incomplete" does not allow.
            // "may be where the data ends, not when you woke" is the honest hedge — if they really
            // did get up at 02:37 and take the ring off, the printed time is correct and the sentence
            // does not contradict them.
            case let .noRecordingAfterWake(from, silentFor):
                return Hint(
                    reason: reason,
                    systemImage: "sunrise",
                    text: "Nothing was recorded between \(clock(from)) and "
                        + "\(clock(from.addingTimeInterval(silentFor))) — "
                        + "\(approximateDuration(silentFor)) with no data — so \(clock(from)) may be "
                        + "where the data ends, not when you woke. If you slept longer, tap Edit to "
                        + "correct it.")

            // FRONT EDGE — the sentence the shipped `bedtimeProvenanceHint` already carried, KEPT
            // WORD FOR WORD. It was written and reviewed for #198, it obeys all three rules above,
            // and changing wording that is already on testers' phones would add a variable to a
            // change whose whole purpose is to measure whether the NEW signal helps.
            case let .noRecordingBeforeBedtime(until, silentFor):
                return Hint(
                    reason: reason,
                    systemImage: "bed.double",
                    text: "\(clock(until)) is when the ring started recording again, not when you "
                        + "settled — it recorded nothing for \(approximateDuration(silentFor)) "
                        + "before that. If you were already in bed, tap Edit to correct it.")

            // DURATION — also verbatim from the shipped `confidenceHint`. Same reasoning.
            case .durationLikelyHigh:
                return Hint(
                    reason: reason,
                    systemImage: "info.circle",
                    text: "Very still night — duration may read a little high. The ring can't sense "
                        + "motionless wakefulness (no movement, near-sleep heart rate), so quiet "
                        + "time awake in bed is counted as light sleep.")
            }
        }
    }
}

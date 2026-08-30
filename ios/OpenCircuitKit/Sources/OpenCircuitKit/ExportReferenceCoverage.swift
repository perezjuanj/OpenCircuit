// COVERAGE MEASURED AGAINST A WAKE THE RECORDING DID NOT DEFINE.
//
// THE DEFECT THIS EXISTS FOR. `ExportCoverage.assess` is handed the DETECTED window, and the
// detected window's right edge IS the last record — `SleepStaging` builds the night out of the
// epochs it was given, so the window cannot extend past them. A night that ends early *because* the
// records stopped therefore has its denominator shortened by exactly the thing it should be
// reporting, and `coverageFraction` comes out at ~1.0 with an empty `gaps` list. The number is not
// wrong, it is UNFALSIFIABLE: no truncation at the trailing edge can ever move it.
//
// That is not a hypothesis about the arithmetic, it is the arithmetic. It also matches what the two
// surfaces that already looked have said: `ExportEngine.SleepEdgeProvenanceRow` records 0.976–1.049
// across 21 of 21 corpus nights, and `SleepConfidenceCoverage` records the two worst nights in that
// corpus (each understated by 246 min) as having their ~4 h hole begin exactly AT the in-bed end.
// The 2026-08-26 tester investigation is the same shape from the other end: a night reported
// `coverageFraction 1.0000, gaps: []` while its last hours were missing.
//
// WHAT THIS ADDS. A SECOND measurement of the same records over a window whose right edge came from
// somewhere the recording had no vote in. Then a hole at the trailing edge is inside the window, and
// the fraction can fall — which is the whole point: a number that can only ever say "fine" is not
// evidence that anything is fine.
//
// ⚠️ IT IS A REFERENCE, NOT A TRUTH. A scheduled wake is when the wearer INTENDS to get up. On a
// night they slept in, or got up early, or did not follow the schedule at all, this fraction is low
// for a reason that is about the schedule and not about the ring — which is why `reference` and
// `referenceEnd` travel with the number, why the signed `beyondDetectedEndSeconds` is published
// beside it, and why nothing in the app is gated on it. It is instrumentation for the export and the
// diagnostics bundle.
//
// ⚠️ ONLY THE RIGHT EDGE MOVES, AND DELIBERATELY. A schedule also names a BEDTIME, and the leading
// edge has the same structural blindness — but a wearer who went to bed two hours late would then be
// reported as a two-hour hole on a night nothing was wrong with. The trailing edge is the one the
// measured corpus errors sit on, and holding the left edge at the detected start keeps this from
// manufacturing an error out of an ordinary late night.
//
// NO REFERENCE IS INVENTED. When the caller has none — the wearer never enabled a manual sleep
// schedule — `assess` returns nil and the export says so, rather than filling in a denominator.

import Foundation

public enum ExportReferenceCoverage {

    /// Where the wake instant came from. A closed set on purpose: every case must name something a
    /// human supplied or an observation made, never a value this app chose.
    public enum Reference: String, Equatable, Sendable {
        /// The wake time in the wearer's own manual sleep schedule (`SleepScheduleDefaults`),
        /// resolved for the night through `SleepWindow.interval`.
        case manualScheduleWake
    }

    /// One night's coverage against an external wake.
    public struct Row: Equatable, Sendable {
        public let reference: Reference
        /// The wake instant the window was closed at.
        public let referenceEnd: Date
        /// `referenceEnd − detectedEnd`. POSITIVE when the reference reaches past where the records
        /// stopped — the only sign under which this row can falsify anything. Negative means the
        /// reference closed EARLIER than the detected window, so the fraction below is measured over
        /// a SHORTER span than `coverage` next door and is not comparable with it. Published signed,
        /// rather than suppressed, so the row is never quietly dropped on the nights it flatters us.
        public let beyondDetectedEndSeconds: TimeInterval
        /// The measurement itself, over `[detectedStart, referenceEnd]`.
        public let assessment: ExportCoverage.Assessment
    }

    /// What the export has to say about the second measurement for one night.
    ///
    /// ⚠️ `unavailable` IS EMITTED, NOT OMITTED, and that is the difference between this key and
    /// `osa`/`coverage` next to it. Those two use absence to mean "we have nothing"; here absence
    /// would be ambiguous with an export written before the key existed, and the whole reason the key
    /// exists is that a reader could not tell "nothing is wrong" from "nothing could be checked".
    /// Saying so out loud costs one short object per night.
    public enum Outcome: Equatable, Sendable {
        case measured(Row)
        /// No wake reference the recording did not define was available for this night. The payload
        /// is a stable machine token, not display copy.
        case unavailable(reason: String)

        /// The wearer has not enabled a manual sleep schedule, so there is no wake instant this app
        /// did not derive from the records themselves. Nothing is invented in its place.
        public static let noManualSleepSchedule = "noManualSleepSchedule"
        /// A schedule exists but resolved to a wake at or before the night's detected start, so
        /// there is no window to measure. (`SleepWindow.interval` also returns nil for a degenerate
        /// bed == wake schedule, which lands here.)
        public static let referenceNotAfterBedtime = "referenceNotAfterBedtime"
    }

    /// Measure `sampleTimes` over `[detectedStart, referenceEnd]`.
    ///
    /// - Parameters:
    ///   - sampleTimes: the SAME witness the detected-window assessment counted — union the epoch
    ///     archive in first (`ExportCoverageWitness.sampleTimes`), or this reports our own
    ///     forward-only sync cursor as the ring's recording.
    ///   - detectedStart: the detected window's left edge, held fixed (see the header).
    ///   - detectedEnd: the detected window's right edge, used only for `beyondDetectedEndSeconds`.
    ///   - referenceEnd: the external wake instant.
    ///   - reference: where that instant came from.
    /// - Returns: nil when `referenceEnd` does not lie after `detectedStart` — a non-positive window
    ///   has no denominator, and reporting 0 for it would state a total outage. Callers with no
    ///   reference at all must not call this; they have nothing to measure against and the export
    ///   says so.
    public static func assess(sampleTimes: [Date],
                              detectedStart: Date,
                              detectedEnd: Date,
                              referenceEnd: Date,
                              reference: Reference) -> Row? {
        guard referenceEnd > detectedStart else { return nil }
        return Row(reference: reference,
                   referenceEnd: referenceEnd,
                   beyondDetectedEndSeconds: referenceEnd.timeIntervalSince(detectedEnd),
                   assessment: ExportCoverage.assess(sampleTimes: sampleTimes,
                                                     from: detectedStart, to: referenceEnd))
    }
}

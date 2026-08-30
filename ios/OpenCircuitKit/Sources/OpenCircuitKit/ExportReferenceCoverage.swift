// COVERAGE MEASURED AGAINST A WAKE THE RECORDING DID NOT DEFINE.
//
// THE DEFECT THIS EXISTS FOR. `ExportCoverage.assess` is handed the night's REPORTED in-bed window
// — the one the card and Apple Health show. On every night nobody corrected, that window IS the
// detected window, and the detected window's right edge IS the last record: `SleepStaging` builds
// the night out of the epochs it was given, so the window cannot extend past them. A night that
// ends early *because* the records stopped therefore has its denominator shortened by exactly the
// thing it should be reporting, and `coverageFraction` comes out at ~1.0 with an empty `gaps` list.
// The number is not wrong, it is UNFALSIFIABLE: no truncation at the trailing edge can ever move it.
//
// That is not a hypothesis about the arithmetic, it is the arithmetic. It also matches what the two
// surfaces that already looked have said: `ExportEngine.SleepEdgeProvenanceRow` records 0.976–1.049
// across 21 of 21 corpus nights, and `SleepConfidenceCoverage` records the two worst nights in that
// corpus (each understated by 246 min) as having their ~4 h hole begin exactly AT the in-bed end.
//
// ⚠️ AND IT IS THE UNEDITED NIGHT THIS IS ABOUT — the scope was overstated in review and is stated
// precisely here. Once the wearer CORRECTS a night, `ExportBuilder` measures `coverage` over her
// corrected window (`StoredSleepSummary.sleepEditCurrentInBedEnd`), which is already a right edge
// the recording did not choose, so the trailing hole is already inside it and the fraction already
// falls: the committed `R2_2026-08-18` fixture carries `appCoverageFraction 0.377` for exactly such
// a night (`SleepProvenanceTesterNightTests`). What the fixture also shows is the other half of the
// same fact — measured over that night's DETECTED window the identical records score 1.0000 with no
// gaps (`testCoverageInTheDetectedWindowCannotSeeTheFourHourHole`). A wearer who never opens the
// editor gets only that second number, and it can never fall.
//
// WHAT THIS ADDS. A SECOND measurement of the same records over a window whose right edge came from
// somewhere the recording had no vote in — for the nights nobody corrected, which are the nights
// with no other witness. Then a hole at the trailing edge is inside the window, and the fraction can
// fall — which is the whole point: a number that can only ever say "fine" is not evidence that
// anything is fine.
//
// ⚠️ IT IS A REFERENCE, NOT A TRUTH. A scheduled wake is when the wearer INTENDS to get up. On a
// night they slept in, or got up early, or did not follow the schedule at all, this fraction is low
// for a reason that is about the schedule and not about the ring — which is why `reference` and
// `referenceEnd` travel with the number, why the signed `beyondReportedEndSeconds` is published
// beside it, and why nothing in the app is gated on it. It is instrumentation for the export and the
// diagnostics bundle.
//
// ⚠️ AND IT NEVER REACHES PAST THE PRESENT. A schedule wake that has not arrived yet names an
// instant no recording could exist for, so measuring to it would report the FUTURE as a hole — a
// deficiency manufactured by the export's own clock, on the freshest night in the file, which is the
// one a triager reads first. The caller clamps to the export instant and says so in `reference`
// (`manualScheduleWakeSoFar`), rather than publishing a fraction that falls because it is early.
//
// ⚠️ ONLY THE RIGHT EDGE MOVES, AND DELIBERATELY. A schedule also names a BEDTIME, and the leading
// edge has the same structural blindness — but a wearer who went to bed two hours late would then be
// reported as a two-hour hole on a night nothing was wrong with. The trailing edge is the one the
// measured corpus errors sit on, and holding the left edge at the reported start keeps this from
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
        /// The same schedule wake, but it lies in the FUTURE, so the window was closed at the export
        /// instant instead. Nothing here is chosen by this app except the refusal to measure time
        /// that has not happened: the fraction below is over `[reportedStart, exportedAt]`, so it can
        /// still see a hole that has already opened and can never report one that has not.
        case manualScheduleWakeSoFar
    }

    /// One night's coverage against an external wake.
    public struct Row: Equatable, Sendable {
        public let reference: Reference
        /// The instant the window was closed at — the reference wake, or the export instant when
        /// `reference` says the wake had not arrived yet.
        public let referenceEnd: Date
        /// `referenceEnd − reportedEnd`. POSITIVE when the reference reaches past where the night's
        /// reported window closed — the only sign under which this row can falsify anything. Negative
        /// means the reference closed EARLIER than the reported window, so the fraction below is
        /// measured over a SHORTER span than `coverage` next door and is not comparable with it.
        /// Published signed, rather than suppressed, so the row is never quietly dropped on the
        /// nights it flatters us.
        public let beyondReportedEndSeconds: TimeInterval
        /// The measurement itself, over `[reportedStart, referenceEnd]`.
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
        /// A schedule exists but resolved to a wake at or before the night's reported start, so
        /// there is no window to measure. (`SleepWindow.interval` also returns nil for a degenerate
        /// bed == wake schedule, which lands here; so does a night still in progress whose schedule
        /// wake has not arrived and whose bedtime is already past the export instant.)
        public static let referenceNotAfterBedtime = "referenceNotAfterBedtime"
    }

    /// Bound a scheduled wake to an instant that has actually arrived, and name which of the two it
    /// turned out to be.
    ///
    /// ⚠️ THIS IS THE ONLY PLACE THE FUTURE IS REFUSED, and it lives in the Kit rather than at the
    /// call site so it is covered by `swift test` — the app-target suite is not in preflight. A
    /// schedule wake is a TIME OF DAY, so on the freshest night in an export it is routinely still
    /// ahead of the clock (export at 05:00 against a 06:30 schedule). Measuring to it would count
    /// epochs that could not exist as expected-but-missing and publish a hole manufactured by the
    /// export's own clock. Clamping keeps every hole that has already opened visible and makes the
    /// unopened one unreportable.
    ///
    /// - Returns: nil when there is no scheduled wake at all — the caller must then say so rather
    ///   than invent a denominator.
    public static func reference(forScheduledWake wake: Date?,
                                 asOf now: Date) -> (end: Date, reference: Reference)? {
        guard let wake else { return nil }
        return wake > now ? (now, .manualScheduleWakeSoFar) : (wake, .manualScheduleWake)
    }

    /// Measure `sampleTimes` over `[reportedStart, referenceEnd]`.
    ///
    /// - Parameters:
    ///   - sampleTimes: the SAME witness the reported-window assessment counted — union the epoch
    ///     archive in first (`ExportCoverageWitness.sampleTimes`), or this reports our own
    ///     forward-only sync cursor as the ring's recording.
    ///   - reportedStart: the reported in-bed window's left edge, held fixed (see the header).
    ///   - reportedEnd: the reported in-bed window's right edge, used only for
    ///     `beyondReportedEndSeconds`.
    ///   - referenceEnd: the external wake instant, already bounded by the caller to an instant that
    ///     has actually arrived (see `Reference.manualScheduleWakeSoFar`). This type cannot check
    ///     that itself — it holds no clock — so the bound is the caller's contract, and violating it
    ///     reports the future as a hole.
    ///   - reference: where that instant came from.
    /// - Returns: nil when `referenceEnd` does not lie after `reportedStart` — a non-positive window
    ///   has no denominator, and reporting 0 for it would state a total outage. Callers with no
    ///   reference at all must not call this; they have nothing to measure against and the export
    ///   says so.
    public static func assess(sampleTimes: [Date],
                              reportedStart: Date,
                              reportedEnd: Date,
                              referenceEnd: Date,
                              reference: Reference) -> Row? {
        guard referenceEnd > reportedStart else { return nil }
        return Row(reference: reference,
                   referenceEnd: referenceEnd,
                   beyondReportedEndSeconds: referenceEnd.timeIntervalSince(reportedEnd),
                   assessment: ExportCoverage.assess(sampleTimes: sampleTimes,
                                                     from: reportedStart, to: referenceEnd))
    }
}

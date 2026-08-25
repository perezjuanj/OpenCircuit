// EDIT → RECONCILE → RECONCILE MUST NOT LEAVE TWO NIGHTS IN APPLE HEALTH.
//
// WHY THIS TEST EXISTS, AND WHY IT IS HERE RATHER THAN IN THE APP TARGET. `HealthKitWriter` builds a
// live `HKHealthStore`, so nothing that saves or deletes can be executed in a test (the house
// pattern is to pull the decision out as a pure value and assert THAT — see
// `HealthKitWriter.activeEnergySample`). The decision that governs duplication is a pair of pure
// values: what we PUBLISH, and what we report as WITHHELD. The delete that removes the previous
// copy of a night is explicitly told to spare every withheld span
// (`deletePriorEditedNightSleep`, `withheld:`) — so if a span is published AND reported as withheld,
// the cleanup is barred from the exact ground the fresh write just landed on, and Apple Health keeps
// both copies. Forever, and once per re-edit.
//
// That is not hypothetical: it is the shape the 2026-08-24 reversal would have produced if
// `withheldSpans` had been left as a free-standing "asserted spans" filter while the publication
// started writing those same spans. The control test below runs exactly that stale definition
// through the same model and shows the duplicate, so the passing assertion above it cannot pass for
// an unrelated reason.

import XCTest
@testable import OpenCircuitKit

final class SleepHealthPublicationIdempotencyTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private func at(_ m: Double) -> Date { t0.addingTimeInterval(m * 60) }

    /// A recorded night 00:00 → 08:00 that the wearer extended to 10:00 over ground the records
    /// prove empty — the ordinary edit shape, with a proven hole at the trailing edge.
    private var edited: [SleepSegment] {
        let base = [SleepSegment(start: at(0), end: at(480), stage: .inBed),
                    SleepSegment(start: at(0), end: at(480), stage: .asleepCore)]
        return SleepEdit.recompute(
            baseSegments: base,
            times: .init(inBedStart: at(0), sleepOnset: at(0), sleepWake: at(600)),
            coverage: MeasuredCoverage(intervals: [at(0) ..< at(480)]))
    }

    // MARK: The invariant

    func testNoPublishedSpanIsAlsoReportedAsWithheld() {
        let segments = edited
        XCTAssertTrue(segments.containsAssertedTime, "precondition: this night has a proven hole")
        XCTAssertFalse(SleepStaging.totalAsleep(segments.healthUserEntered) == 0,
                       "precondition: the hole is published as the wearer's own entry")

        for span in segments.withheldSpans {
            for seg in segments.healthPublishable where seg.end > span.start && seg.start < span.end {
                XCTFail("published \(seg) overlaps withheld \(span) — the cleanup cannot remove the "
                        + "previous copy of this span, so Apple Health keeps both")
            }
        }
    }

    // MARK: The model — one reconcile, then another

    /// One Apple Health sleep sample, as this app's cleanup sees it.
    private struct Sample: Equatable {
        let id: Int
        let span: Range<Date>
        let app: Bool          // authored by us; HealthKit refuses to delete anyone else's
    }

    /// A minimal model of `deletePriorEditedNightSleep`'s transition cleanup (b): delete this app's
    /// sleep OVERLAPPING the recorded in-bed span, EXCEPT the samples just written and except every
    /// withheld span. Overlap (not containment) is HealthKit's own semantics for
    /// `predicateForSamples(withStart:end:options: [])`, and it applies to the exclusions too.
    private func afterCleanup(_ inHealth: [Sample], freshIDs: Set<Int>,
                              recorded: Range<Date>, withheld: [DateInterval]) -> [Sample] {
        inHealth.filter { sample in
            guard sample.app else { return true }
            guard sample.span.overlaps(recorded) else { return true }
            if freshIDs.contains(sample.id) { return true }
            if withheld.contains(where: { sample.span.overlaps($0.start ..< $0.end) }) { return true }
            return false
        }
    }

    func testASecondReconcileLeavesExactlyOneCopyOfTheAssertedSpan() {
        let segments = edited
        let hole = at(480) ..< at(600)
        let recorded = at(0) ..< at(480)

        // An UNTRACKED prior sample over the hole: written by `mirrorSettledNight` before this night
        // was edited, or by a build whose UUID bookkeeping was lost. The tracked-UUID delete (a)
        // cannot see it, so cleanup (b) is the only thing that can ever remove it — and (b) is what
        // `withheldSpans` gates.
        let prior = Sample(id: 1, span: at(0) ..< at(600), app: true)
        // The fresh write: everything the publication publishes.
        let fresh = Sample(id: 2, span: at(0) ..< at(600), app: true)

        let after = afterCleanup([prior, fresh], freshIDs: [fresh.id],
                                 recorded: recorded, withheld: segments.withheldSpans)
        XCTAssertEqual(after.map(\.id), [fresh.id],
                       "the previous copy of the night must be removed — one night, one copy")
        XCTAssertEqual(after.filter { $0.span.overlaps(hole) }.count, 1,
                       "the asserted span must exist exactly once in Apple Health")
    }

    func testTheSTALEWithheldDefinitionIsWhatDuplicatesIt() {
        // THE CONTROL. `withheldSpans` before it was derived from the publication: every asserted
        // span, whether or not we write it. Same model, same inputs, one duplicate.
        let segments = edited
        let staleWithheld = MeasuredCoverage(intervals: segments
            .filter { $0.provenance.isProvenUnmeasured && $0.end > $0.start }
            .map { $0.start ..< $0.end }).intervals
            .map { DateInterval(start: $0.lowerBound, end: $0.upperBound) }
        XCTAssertFalse(staleWithheld.isEmpty, "precondition: the stale rule names the hole")

        let prior = Sample(id: 1, span: at(0) ..< at(600), app: true)
        let fresh = Sample(id: 2, span: at(0) ..< at(600), app: true)
        let after = afterCleanup([prior, fresh], freshIDs: [fresh.id],
                                 recorded: at(0) ..< at(480), withheld: staleWithheld)
        XCTAssertEqual(after.count, 2,
                       "with the stale definition the previous night survives — this is the defect")
    }

    func testAnotherAppsSleepIsNeverRemovedByEitherPass() {
        // HealthKit refuses to delete another source's samples; the model keeps that property
        // explicit so a future widening of the predicate has to confront it.
        let segments = edited
        let theirs = Sample(id: 9, span: at(60) ..< at(120), app: false)
        let fresh = Sample(id: 2, span: at(0) ..< at(600), app: true)
        let after = afterCleanup([theirs, fresh], freshIDs: [fresh.id],
                                 recorded: at(0) ..< at(480), withheld: segments.withheldSpans)
        XCTAssertTrue(after.contains(theirs))
    }
}

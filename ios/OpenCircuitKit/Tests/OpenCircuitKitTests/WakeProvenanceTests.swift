import XCTest
@testable import OpenCircuitKit

/// The nights this exists for: `R2_2026-08-17` and `R2_2026-08-18` (Gen 2 Air, same tester). Staging
/// closed both nights at 02:39:14 / 02:37:02, the record stream resumed 243.6 / 241.9 min later, and
/// each night's duration reads 246 min LOW against the user's own edit. Nothing shipped says a word:
/// `SleepConfidence` discards both under its 5 h gate, `SleepCaptureCoverage` returns `.full`, and
/// the ~4 h hole starts exactly AT the in-bed end so no internal-hole test can see it.
///
/// The instants below are the measured ones, converted to absolute time so the arithmetic is real.
final class WakeProvenanceTests: XCTestCase {

    /// 2026-08-18 02:37:02 +02:00 — `R2_2026-08-18`'s detected in-bed end (stored to the second).
    private let stopped = Date(timeIntervalSince1970: 1_787_013_422)
    private func t(_ offsetFromStopped: TimeInterval) -> Date {
        stopped.addingTimeInterval(offsetFromStopped)
    }

    /// `WakeProvenance.classify` with retention deep enough (30 days before the edge) that the
    /// retention guard never fires — the shape of every test below that is about the EDGE rather
    /// than about retention. The retention tests spell the real call out in full.
    ///
    /// ⚠️ `earliestRetainedMeasurement` has NO DEFAULT in the real signature, on purpose: leaving
    /// that guard to the caller is exactly the defect the parameter closed, and a default value
    /// would reinstate it for anyone who did not know to think about it. Do not add one to make
    /// these call sites shorter.
    private func edgeVerdict(after: Date?) -> WakeProvenance.Verdict {
        WakeProvenance.classify(inBedEnd: stopped,
                                firstMeasurementAfter: after,
                                earliestRetainedMeasurement: t(-30 * 86_400))
    }

    /// The fixture's own provenance: assert the epoch really is the instant the comment names, in
    /// the ring's own zone. A hand-typed epoch that drifts by a day would still make every test
    /// below pass — they only ever use differences.
    func testFixtureInstantIsTheNightItClaimsToBe() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 2 * 3600)!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: stopped)
        XCTAssertEqual([c.year, c.month, c.day, c.hour, c.minute, c.second],
                       [2026, 8, 18, 2, 37, 2])
    }

    // MARK: The nights it exists for

    func testTesterBNightIsStoppedThenResumed() {
        // Records resume 06:38:57, i.e. 241.9 min = 14_515 s later.
        let verdict = edgeVerdict(after: t(14_515))
        XCTAssertEqual(verdict, .stoppedThenResumed(14_515))
        XCTAssertTrue(WakeProvenance.isMaterial(verdict))
    }

    func testTheGapIsReportedNotTheMissingSleep() {
        // The measured error on this night is 246 min against a 241.9 min gap — close, but only
        // because the tester slept through the whole hole. On `R1_2026-08-16` a 241.3 min gap sits
        // against a 120.0 min error. The verdict must carry the GAP and nothing derived from it.
        guard case .stoppedThenResumed(let gap) = edgeVerdict(after: t(14_515)) else {
            return XCTFail("expected a gap verdict")
        }
        XCTAssertEqual(gap, 14_515, accuracy: 0.001,
                       "the associated value is the measured silence, never an inferred sleep total")
    }

    // MARK: Continuity — the 10 of 21 nights that must stay silent

    func testStreamContinuingPastWakeIsWitnessed() {
        // One 150 s epoch later: the stager chose this edge while data kept arriving.
        let verdict = edgeVerdict(after: t(150))
        XCTAssertEqual(verdict, .witnessed)
        XCTAssertFalse(WakeProvenance.isMaterial(verdict))
    }

    func testOneDroppedEpochStillCountsAsContinuous() {
        XCTAssertEqual(edgeVerdict(after: t(WakeProvenance.continuousToleranceSeconds)), .witnessed)
    }

    func testJustBeyondToleranceIsAGapButNotYetMaterial() {
        let verdict = edgeVerdict(after: t(WakeProvenance.continuousToleranceSeconds + 1))
        XCTAssertEqual(verdict, .stoppedThenResumed(WakeProvenance.continuousToleranceSeconds + 1))
        XCTAssertFalse(WakeProvenance.isMaterial(verdict),
                       "a 5-minute gap is a measurement, not something to tell a user about")
    }

    // MARK: The two constants

    func testToleranceIsTheSameConstantAsTheLeadingEdge() {
        // A front/back asymmetry would be unexplainable to anyone reading the two hints together.
        XCTAssertEqual(WakeProvenance.continuousToleranceSeconds,
                       BedtimeProvenance.continuousToleranceSeconds)
        XCTAssertEqual(WakeProvenance.continuousToleranceSeconds, 300)
    }

    func testMaterialCutSitsInTheEmptyIntervalTheCorpusMeasured() {
        // Sorted corpus gaps after the in-bed end (minutes): … 2.5, 7.5, 33.0, 241.9, 243.6.
        // (243.2 appeared in this list until 2026-08-20 and was never a measured gap —
        // `R3_2026-08-04`'s next record is in a different capture artifact. Withheld now.)
        // The cut must separate the small cluster from the ~4 h cluster. Every value in
        // (33.0, 241.9] does that identically — this asserts the PROPERTY, not the number, so a
        // future retune inside the empty interval stays green and one outside it does not.
        let cut = WakeProvenance.materialGapSeconds / 60
        XCTAssertGreaterThan(cut, 33.0, "would newly flag R5_2026-08-11, unlabelled Gen 3")
        XCTAssertLessThanOrEqual(cut, 241.9, "would stop flagging R2_2026-08-18, a 246-min error")
    }

    func testThresholdIsCallerOverridableInBothDirections() {
        let fiveMinuteGap = edgeVerdict(after: t(450))
        XCTAssertFalse(WakeProvenance.isMaterial(fiveMinuteGap))
        XCTAssertTrue(WakeProvenance.isMaterial(fiveMinuteGap, threshold: 0),
                      "0 = maximally loud, for a sweep")
        let bigGap = edgeVerdict(after: t(14_515))
        XCTAssertFalse(WakeProvenance.isMaterial(bigGap, threshold: .infinity),
                       ".infinity is the kill switch")
    }

    // MARK: Absence — the 6 of 21 nights that CANNOT be adjudicated

    func testNoLaterMeasurementIsUnknownNotStopped() {
        // "The ring stopped recording" and "you synced the moment you woke" are the same picture.
        // 6 of 21 corpus nights land here and not one of them can be adjudicated, so the honest
        // verdict is unknown and the honest UI is silence.
        let verdict = edgeVerdict(after: nil)
        XCTAssertEqual(verdict, .unknown)
        XCTAssertFalse(WakeProvenance.isMaterial(verdict),
                       "an unadjudicable night must never produce user copy")
    }

    func testUnknownStaysUnknownAtEveryThreshold() {
        XCTAssertFalse(WakeProvenance.isMaterial(edgeVerdict(after: nil), threshold: 0),
                       "even maximally loud, 'we could not tell' must not become a claim")
    }

    // MARK: Retention — the guard that used to live in the caller

    /// The defect the guard closes, now asserted against the PUBLIC classifier rather than against
    /// `SleepConfidence.assess`. `StoredSample` rows are pruned at `sampleRetentionDays` (30) while
    /// `StoredSleepSummary` is kept, so an aged-out night keeps its row and loses every raw sample
    /// around it — and `earliestSample(after:)` then returns the OLDEST SURVIVING ROW, days later.
    /// Unguarded, that reads as a resume and the copy says "nothing was recorded between 02:37 and
    /// <three weeks later>": local housekeeping reported as a hole in the night.
    func testRetentionThatStopsShortOfTheEdgeIsUnknownNotAThreeWeekSilence() {
        let boundary = t(21 * 86_400)
        XCTAssertEqual(WakeProvenance.classify(inBedEnd: stopped,
                                               firstMeasurementAfter: boundary,
                                               earliestRetainedMeasurement: boundary),
                       .unknown,
                       "the oldest row we hold is NEWER than this night's end, so everything at and "
                       + "after that edge was pruned and the 'next' measurement is a boundary, not "
                       + "evidence")
    }

    /// The guard must not swallow the real case. Identical successor, retention deep enough to
    /// vouch for the silence ⇒ the gap is evidence and must still be reported. Without this the
    /// "fix" could be "always unknown", which would silence the two nights the classifier exists for.
    func testTheSameGapIsStillReportedWhenRetentionReachesPastTheEdge() {
        let verdict = WakeProvenance.classify(inBedEnd: stopped,
                                              firstMeasurementAfter: t(21 * 86_400),
                                              earliestRetainedMeasurement: t(-30 * 86_400))
        XCTAssertEqual(verdict, .stoppedThenResumed(21 * 86_400))
        XCTAssertTrue(WakeProvenance.isMaterial(verdict))
    }

    /// nil means "the caller has no retention information", NOT "retention stops here". The corpus
    /// harness withholds the field on nights whose leading edge is undeterminable, and
    /// `R2_2026-08-17` — one of the two 246-minute nights this classifier exists for — is one of
    /// them; on device it means an empty store, where there is no successor either.
    func testMissingRetentionInformationLeavesTheRawVerdictStanding() {
        XCTAssertEqual(WakeProvenance.classify(inBedEnd: stopped,
                                               firstMeasurementAfter: t(14_616),
                                               earliestRetainedMeasurement: nil),
                       .stoppedThenResumed(14_616))
    }

    /// The boundary: retention reaching EXACTLY the edge is not "short of" it. `>` not `>=`, the
    /// same strictness the successor test uses, so an edge that coincides with the oldest surviving
    /// row is still judged.
    func testRetentionExactlyAtTheEdgeStillJudges() {
        XCTAssertEqual(WakeProvenance.classify(inBedEnd: stopped,
                                               firstMeasurementAfter: t(14_515),
                                               earliestRetainedMeasurement: stopped),
                       .stoppedThenResumed(14_515))
    }

    /// The whole point of moving it: both edges now answer the retention question themselves, from
    /// the same field, so a caller cannot get one right and the other wrong. Same inputs, same
    /// silence.
    func testBothEdgesGuardRetentionTheSameWay() {
        let boundary = t(21 * 86_400)
        XCTAssertEqual(WakeProvenance.classify(inBedEnd: stopped,
                                               firstMeasurementAfter: boundary,
                                               earliestRetainedMeasurement: boundary),
                       .unknown)
        XCTAssertEqual(BedtimeProvenance.classify(inBedStart: stopped,
                                                  lastMeasurementBefore: nil,
                                                  earliestRetainedMeasurement: boundary),
                       .unknown)
    }

    // MARK: Caller hazards

    func testMeasurementAtOrBeforeTheEdgeIsUnknownNotANegativeGap() {
        // The newest record INSIDE the window is always ≤ inBedEnd, so a caller that queries
        // `>= end` instead of `> end` trips this on every night.
        for offset in [-60.0, 0.0] {
            XCTAssertEqual(edgeVerdict(after: t(offset)), .unknown,
                           "offset \(offset) must not produce a negative gap")
        }
    }

    // MARK: The run walk (the one-epoch defeat)

    /// 🟢 THE REGRESSION THIS WALK EXISTS FOR — tester `40CFFE2E`, Gen 2 Air FR04.009, night
    /// 2026-09-01, taken from her own diagnostics export (`opencircuit-night-2026-09-01.json`).
    /// Every instant below is read out of that file, not constructed:
    ///
    ///   * `sleep[0].inBedEnd`            = 2026-09-01T01:32:21Z  (the staged edge)
    ///   * `epochArchive[0].lastEpoch`    = 2026-09-01T01:32:51Z  (+30 s — the LAST record there is)
    ///   * first heart rate after it      = 2026-09-01T05:35:20.951Z
    ///     (+14549.951 s from the ARCHIVE EPOCH — i.e. +14579.951 s from `inBedEnd`; the silence
    ///     is measured from the last record before it, which is the whole point of `Stoppage`)
    ///
    /// She got up at 07:30 local. Four hours of her night are missing, and the export carries
    /// `edgeProvenance.wakeVerdict: "witnessed"` — the single 30 s epoch was enough to end the
    /// enquiry. (Her post-edit export re-probes from the +120 s recorded edge and reports the same
    /// hole as `wakeGapSeconds: 14429.95`; the two differ only by where the probe starts.)
    func testOneEpochOfDataDoesNotBuyAWitnessedVerdict() {
        // 2026-09-01T01:32:21Z. ⚠️ The literal was 1_788_485_541 until a review decoded it as
        // 2026-09-04 — three days out, under a header promising every instant was read from the
        // export. The arithmetic below is all relative so the test still passed, which is exactly
        // why a stated-provenance claim has to be checked rather than trusted.
        let end = Date(timeIntervalSince1970: 1_788_226_341)
        let resumed = end.addingTimeInterval(30)              // 01:32:51Z, the archive's last record
        let morning = end.addingTimeInterval(30 + 14549.951)  // 05:35:20.951Z, a live heart rate

        // What shipped before this change, from exactly these instants.
        XCTAssertEqual(WakeProvenance.classify(inBedEnd: end,
                                               firstMeasurementAfter: resumed,
                                               earliestRetainedMeasurement: deepRetention(before: end)),
                       .witnessed,
                       "precondition: the single-step rule is defeated by one epoch")

        // What the walk says. Compared with a tolerance because the instants are reconstructed
        // through `Date`'s binary seconds — asserting the literal would be testing Double, not this.
        let walked = WakeProvenance.classify(inBedEnd: end,
                                             measurementsAfter: [resumed, morning],
                                             earliestRetainedMeasurement: deepRetention(before: end))
        guard case .stoppedThenResumed(let gap) = walked else {
            return XCTFail("expected a stop, got \(walked)")
        }
        XCTAssertEqual(gap, 14549.951, accuracy: 0.001)
        XCTAssertTrue(WakeProvenance.isMaterial(walked))
    }

    /// The bound is what stops the walk turning an ordinary daytime disconnect into a hole in the
    /// night. A ring worn through the morning emits every 150 s; the first real break here is 3 h
    /// after the edge, long past `resumeRunMaxSeconds`, and must read `.witnessed`.
    func testARunThatCarriesOnPastTheBoundStaysWitnessed() {
        let end = stopped
        var series: [Date] = []
        var offset: TimeInterval = 150
        while offset <= 3 * 3600 { series.append(t(offset)); offset += 150 }
        series.append(t(3 * 3600 + 4 * 3600))  // a 4 h daytime disconnect, hours past the edge

        XCTAssertEqual(WakeProvenance.classify(inBedEnd: end,
                                               measurementsAfter: series,
                                               earliestRetainedMeasurement: deepRetention(before: end)),
                       .witnessed)
    }

    /// A hole that begins just INSIDE the bound is still this night's; just outside it is not.
    func testTheBoundIsTheHoleSTARTNotItsSize() {
        let end = stopped
        func verdict(runLength: TimeInterval) -> WakeProvenance.Verdict {
            var series: [Date] = []
            var offset: TimeInterval = 150
            while offset <= runLength { series.append(t(offset)); offset += 150 }
            series.append(t(runLength + 4 * 3600))
            return WakeProvenance.classify(inBedEnd: end,
                                           measurementsAfter: series,
                                           earliestRetainedMeasurement: deepRetention(before: end),
                                           resumeRunLimit: 600)
        }
        XCTAssertEqual(verdict(runLength: 600), .stoppedThenResumed(4 * 3600))
        XCTAssertEqual(verdict(runLength: 750), .witnessed)
    }

    /// The kill switch must reproduce the shipped rule EXACTLY — that is what makes "default off"
    /// a real rollback rather than a hope.
    func testWalkKillSwitchReproducesSingleStep() {
        let end = stopped
        let series = [t(150), t(150 + 14429), t(150 + 14429 + 150)]
        XCTAssertEqual(WakeProvenance.classify(inBedEnd: end,
                                               measurementsAfter: series,
                                               earliestRetainedMeasurement: deepRetention(before: end),
                                               resumeRunLimit: 0),
                       WakeProvenance.classify(inBedEnd: end,
                                               firstMeasurementAfter: series.first,
                                               earliestRetainedMeasurement: deepRetention(before: end)))
    }

    /// Additive only: the walk may upgrade `.witnessed`, never touch the other two verdicts.
    func testWalkNeverSilencesAStopAndNeverInventsOne() {
        let end = stopped
        // Already a stop at the first step — the walk must return it untouched, not re-measure.
        XCTAssertEqual(WakeProvenance.classify(inBedEnd: end,
                                               measurementsAfter: [t(14616), t(14766)],
                                               earliestRetainedMeasurement: deepRetention(before: end)),
                       .stoppedThenResumed(14616))
        // Nothing after the edge stays `.unknown`.
        XCTAssertEqual(WakeProvenance.classify(inBedEnd: end,
                                               measurementsAfter: [],
                                               earliestRetainedMeasurement: deepRetention(before: end)),
                       .unknown)
        // Retention no longer reaches the night — `.unknown` regardless of what the series holds.
        XCTAssertEqual(WakeProvenance.classify(inBedEnd: end,
                                               measurementsAfter: [t(150), t(150 + 14429)],
                                               earliestRetainedMeasurement: t(60)),
                       .unknown)
        // An unbroken run to the end of what we hold is not evidence of a stop.
        XCTAssertEqual(WakeProvenance.classify(inBedEnd: end,
                                               measurementsAfter: [t(150), t(300), t(450)],
                                               earliestRetainedMeasurement: deepRetention(before: end)),
                       .witnessed)
    }

    /// Unsorted and duplicated input must not change the answer — the real caller reads a store.
    func testWalkIsOrderAndDuplicateInsensitive() {
        let end = stopped
        let jumbled = [t(150 + 14429), t(150), t(150), t(150 + 14429)]
        XCTAssertEqual(WakeProvenance.classify(inBedEnd: end,
                                               measurementsAfter: jumbled,
                                               earliestRetainedMeasurement: deepRetention(before: end)),
                       .stoppedThenResumed(14429))
    }

    /// 🟢 THE REGRESSION M1 — the walk must report WHERE the silence began, not just how long it
    /// lasted. Under the single-step rule the silence always started at `inBedEnd`, so the card
    /// could render `inBedEnd … inBedEnd + gap` and be exactly right. The walk can consume records
    /// first, and rendering from the edge then names TWO instants that never happened.
    ///
    /// Review probe (shortened to fit `resumeRunMaxSeconds`, which the same review narrowed to the
    /// 300 s continuity tolerance): in-bed end, heart rates at +60/+210 s, then the ring is off and
    /// the stream resumes 3h 30m after that last record. Rendered from the edge the card would say
    /// the silence began at the wake time; it began 3½ minutes later.
    func testTheReportedSilenceStartsAtTheLastRecordNotTheEdge() {
        let end = stopped
        let run = [t(60), t(210)]
        let resume = t(210 + 12_600)
        let s = WakeProvenance.stoppage(inBedEnd: end,
                                        measurementsAfter: run + [resume],
                                        earliestRetainedMeasurement: deepRetention(before: end))
        XCTAssertEqual(s.verdict, .stoppedThenResumed(12_600))
        XCTAssertEqual(s.silenceBegan, t(210), "the silence began at the LAST record, not inBedEnd")
        // The invariant the copy depends on.
        guard case .stoppedThenResumed(let gap) = s.verdict, let from = s.silenceBegan else {
            return XCTFail("expected a stop")
        }
        XCTAssertEqual(from.addingTimeInterval(gap), resume,
                       "from + silentFor must be the instant recording resumed")
    }

    /// 🟢 THE NARROWED BOUND (review M3). A ring worn well past the staged wake and THEN removed is
    /// the ordinary morning-charge routine, and it is the false-positive class the corpus cannot
    /// measure — 0 of its 21 nights populate this shape. At the 300 s tolerance such a night is
    /// `.witnessed` and silent, exactly as on master. This is a deliberate cost, not an oversight:
    /// it is what buys back the unmeasured risk.
    func testARingWornSeveralMinutesPastWakeThenRemovedStaysSilent() {
        let end = stopped
        let run = [t(60), t(210), t(360), t(510)]   // still recording 8.5 min past the edge
        XCTAssertEqual(WakeProvenance.classify(inBedEnd: end,
                                               measurementsAfter: run + [t(510 + 12_600)],
                                               earliestRetainedMeasurement: deepRetention(before: end)),
                       .witnessed)
    }

    /// A hole beginning exactly at the edge still reports the edge — the single-step behaviour.
    func testASilenceAtTheEdgeStillReportsTheEdge() {
        let end = stopped
        let s = WakeProvenance.stoppage(inBedEnd: end,
                                        measurementsAfter: [t(14_616)],
                                        earliestRetainedMeasurement: deepRetention(before: end))
        XCTAssertEqual(s.verdict, .stoppedThenResumed(14_616))
        XCTAssertEqual(s.silenceBegan, end)
    }

    /// ⚠️ PINS A DELIBERATE NON-MONOTONICITY (review M2). Adding a real record can OPEN a hole,
    /// because the walk measures the space BETWEEN consecutive records. An earlier comment in
    /// `ExportCoverageWitness` claimed the opposite as a safety invariant; it was false, and this
    /// test exists so the true behaviour is stated rather than assumed.
    func testAddingARecordCanOpenAHoleAndThatIsIntended() {
        let end = stopped
        let retention = deepRetention(before: end)
        XCTAssertEqual(WakeProvenance.classify(inBedEnd: end,
                                               measurementsAfter: [t(30)],
                                               earliestRetainedMeasurement: retention),
                       .witnessed)
        XCTAssertEqual(WakeProvenance.classify(inBedEnd: end,
                                               measurementsAfter: [t(30), t(400)],
                                               earliestRetainedMeasurement: retention),
                       .stoppedThenResumed(370))
    }

    private func deepRetention(before d: Date) -> Date { d.addingTimeInterval(-30 * 86400) }
}

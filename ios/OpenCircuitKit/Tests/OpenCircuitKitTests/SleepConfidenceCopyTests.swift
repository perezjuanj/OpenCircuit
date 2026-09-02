// The card's SENTENCES, asserted as claims rather than as strings.
//
// Most of these do not check wording — they check that a sentence does not make a claim the
// measurement cannot support. The three rules from the file header, as tests:
//
//   1. no cause is named ("the ring stopped", "charging", "you took it off"),
//   2. the measured gap appears and no sleep TOTAL is inferred from it,
//   3. the wearer is pointed at Edit, the only lever they have (and the supervised label we lack).
//
// Plus the structural one that a golden-string test would miss entirely: the duration note and an
// acquisition note are OPPOSITE claims about the same night and must never both render.

import XCTest
@testable import OpenCircuitKit

final class SleepConfidenceCopyTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_723_000_000)   // arbitrary, fixed

    /// A fixed 24 h clock so the assertions never depend on the runner's locale.
    private func clock(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    private func hints(asleep: TimeInterval, inBed: TimeInterval,
                       before: Date?, after: Date?,
                       start: Date, end: Date) -> [SleepConfidence.Hint] {
        SleepConfidence.hints(
            SleepConfidence.assess(
                asleep: asleep, inBed: inBed,
                coverage: SleepConfidence.Coverage(
                    inBedStart: start, inBedEnd: end,
                    lastMeasurementBeforeStart: before,
                    firstMeasurementAfterEnd: after,
                    // Empty: these cases predate the run walk and exercise the single-step rule,
                    // which an empty series reproduces exactly (`WakeProvenance.classify`).
                    measurementsAfterEnd: [],
                    earliestRetainedMeasurement: start.addingTimeInterval(-7 * 86_400))),
            clock: clock)
    }

    // MARK: - The back edge — the R2_2026-08-18 shape

    /// 253 min in bed, recording stops at the wake and resumes 241.9 min later. Nothing shipped
    /// before this change said a word about this night; it is understated by 246 minutes.
    func testStoppedAtWakeNamesBothInstantsAndTheGap() {
        let start = t0, end = t0.addingTimeInterval(253 * 60)
        let list = hints(asleep: 250 * 60, inBed: 253 * 60,
                         before: start.addingTimeInterval(-60),
                         after: end.addingTimeInterval(241.9 * 60),
                         start: start, end: end)
        XCTAssertEqual(list.count, 1)
        let text = list[0].text
        XCTAssertTrue(text.contains(clock(end)), "must name where the data ends")
        XCTAssertTrue(text.contains(clock(end.addingTimeInterval(241.9 * 60))),
                      "must name where it resumes — that is what makes the gap checkable")
        XCTAssertTrue(text.contains("4h 2m"), "must state the MEASURED gap: \(text)")
        XCTAssertTrue(text.contains("Edit"), "must point at the only lever the wearer has")
    }

    /// The gap BOUNDS the error, it does not estimate it (n = 3; on `R1_2026-08-16` a 241.3 min hole
    /// sits against a 120.0 min error, because she went to bed INSIDE the hole). So the ONLY
    /// duration a sentence may contain is the measured gap itself — any second figure would be an
    /// inferred sleep total dressed as a measurement.
    ///
    /// Asserted structurally, on the numbers, rather than as a blocklist of phrasings: a blocklist
    /// also rejects the CONDITIONAL "if you slept longer", which asserts nothing and is the whole
    /// point of the sentence. What must never appear is a second quantity.
    func testTheOnlyDurationInTheCopyIsTheMeasuredGap() {
        let start = t0, end = t0.addingTimeInterval(253 * 60)
        let backGap: TimeInterval = 241.9 * 60, frontGap: TimeInterval = 149.3 * 60
        let list = hints(asleep: 250 * 60, inBed: 253 * 60,
                         before: start.addingTimeInterval(-frontGap),
                         after: end.addingTimeInterval(backGap),
                         start: start, end: end)
        XCTAssertEqual(list.count, 2, "fixture must produce both edges")

        // Every "<n>h <n>m" / "<n> hours" / "<n> minutes" token in a sentence, in order.
        let pattern = try! NSRegularExpression(
            pattern: #"\d+h \d+m|\d+ hours?|\d+ minutes?"#)
        for hint in list {
            let text = hint.text
            let found = pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
                .map { String(text[Range($0.range, in: text)!]) }
            let expected: String
            switch hint.reason {
            case .noRecordingAfterWake(_, let g), .noRecordingBeforeBedtime(_, let g):
                expected = SleepConfidence.approximateDuration(g)
            case .durationLikelyHigh:
                expected = ""
            }
            XCTAssertEqual(found, [expected],
                           "the only duration in this sentence must be the measured gap: \(text)")
        }
    }

    /// A stopped ring, a dead battery, a contended resume pointer (#188) and the wearer taking the
    /// ring off are indistinguishable from the persisted stream — and when the cause is our own
    /// sync, blaming the device is wrong, not merely unsupported.
    func testNoCopyNamesACause() {
        let start = t0, end = t0.addingTimeInterval(253 * 60)
        var all = hints(asleep: 250 * 60, inBed: 253 * 60,
                        before: start.addingTimeInterval(-60),
                        after: end.addingTimeInterval(241.9 * 60),
                        start: start, end: end).map(\.text)
        all += hints(asleep: 250 * 60, inBed: 253 * 60,
                     before: start.addingTimeInterval(-241.3 * 60), after: nil,
                     start: start, end: end).map(\.text)
        for text in all {
            for cause in ["ring stopped", "stopped recording", "charging", "battery",
                          "took it off", "didn’t transfer", "didn't transfer", "RingConn"] {
                XCTAssertFalse(text.lowercased().contains(cause.lowercased()),
                               "'\(cause)' is a cause we cannot observe: \(text)")
            }
        }
    }

    // MARK: - Mutual exclusion

    /// "Your duration may read a little HIGH" on a night whose recording stopped for four hours is
    /// the INVERSE of the truth — the measured error on both such corpus nights is −246 min.
    func testAcquisitionSilencesTheDurationNote() {
        let start = t0, end = t0.addingTimeInterval(6 * 3600)
        // Efficiency 0.99 over a 6 h night ⇒ classify() alone says .durationLikelyHigh.
        let asleep = 6 * 3600 * 0.99
        XCTAssertEqual(SleepConfidence.classify(asleep: asleep, inBed: 6 * 3600),
                       .durationLikelyHigh, "fixture must trip the legacy rule")
        let list = hints(asleep: asleep, inBed: 6 * 3600,
                         before: start.addingTimeInterval(-60),
                         after: end.addingTimeInterval(4 * 3600),
                         start: start, end: end)
        XCTAssertEqual(list.map(\.reason), [.noRecordingAfterWake(from: end, silentFor: 4 * 3600)])
        XCTAssertFalse(list.contains { $0.text.contains("read a little high") })
    }

    /// The same night with a WITNESSED wake keeps the shipped duration note, word for word — the
    /// legacy signal is superseded in place, not deleted.
    func testWitnessedNightStillGetsTheShippedDurationSentence() {
        let start = t0, end = t0.addingTimeInterval(6 * 3600)
        let list = hints(asleep: 6 * 3600 * 0.99, inBed: 6 * 3600,
                         before: start.addingTimeInterval(-60),
                         after: end.addingTimeInterval(60),
                         start: start, end: end)
        XCTAssertEqual(list.map(\.reason), [.durationLikelyHigh])
        XCTAssertEqual(list[0].text,
                       "Very still night — duration may read a little high. The ring can't sense "
                       + "motionless wakefulness (no movement, near-sleep heart rate), so quiet "
                       + "time awake in bed is counted as light sleep.")
    }

    /// The front edge keeps the #198 sentence VERBATIM. Changing wording already on testers' phones
    /// would add a variable to a change whose purpose is to measure the new signal.
    func testFrontEdgeSentenceIsTheShippedOne() {
        let start = t0, end = t0.addingTimeInterval(329 * 60)
        let list = hints(asleep: 246 * 60, inBed: 329 * 60,
                         before: start.addingTimeInterval(-241.3 * 60),
                         after: end.addingTimeInterval(60),
                         start: start, end: end)
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].text,
                       "\(clock(start)) is when the ring started recording again, not when you "
                       + "settled — it recorded nothing for 4h 1m before that. If you were already "
                       + "in bed, tap Edit to correct it.")
    }

    // MARK: - Silence

    func testWitnessedOnBothEdgesAndPlausibleEfficiencySaysNothing() {
        let start = t0, end = t0.addingTimeInterval(8 * 3600)
        XCTAssertTrue(hints(asleep: 7 * 3600, inBed: 8 * 3600,
                            before: start.addingTimeInterval(-60),
                            after: end.addingTimeInterval(60),
                            start: start, end: end).isEmpty)
    }

    /// `.unknown` must SHIP SILENT: 6 of 21 corpus nights land there and the corpus cannot adjudicate
    /// one of them. Nothing after the edge is equally consistent with "the ring stopped" and with
    /// "the drain has not reached that far yet".
    func testNothingAfterTheEdgeSaysNothing() {
        let start = t0, end = t0.addingTimeInterval(8 * 3600)
        let list = hints(asleep: 7 * 3600, inBed: 8 * 3600,
                         before: start.addingTimeInterval(-60), after: nil,
                         start: start, end: end)
        XCTAssertTrue(list.isEmpty, "an unknown trailing edge must not produce copy")
    }

    /// Ordering IS the precedence: the back edge first, because it is where both 246-minute corpus
    /// errors are and the only edge with no other surface in the app.
    func testBothEdgesRenderBackEdgeFirst() {
        let start = t0, end = t0.addingTimeInterval(698 * 60)
        let list = hints(asleep: 587 * 60, inBed: 698 * 60,
                         before: start.addingTimeInterval(-149.3 * 60),
                         after: end.addingTimeInterval(243.2 * 60),
                         start: start, end: end)
        XCTAssertEqual(list.count, 2)
        guard case .noRecordingAfterWake = list[0].reason else {
            return XCTFail("back edge must come first, got \(list[0].reason)")
        }
        guard case .noRecordingBeforeBedtime = list[1].reason else {
            return XCTFail("front edge must come second, got \(list[1].reason)")
        }
    }

    /// The kill switch reaches the copy, not just the classifier.
    func testInfiniteThresholdRendersNoAcquisitionCopy() {
        let start = t0, end = t0.addingTimeInterval(253 * 60)
        let a = SleepConfidence.assess(
            asleep: 250 * 60, inBed: 253 * 60,
            coverage: SleepConfidence.Coverage(
                inBedStart: start, inBedEnd: end,
                lastMeasurementBeforeStart: start.addingTimeInterval(-241.3 * 60),
                firstMeasurementAfterEnd: end.addingTimeInterval(241.9 * 60),
                measurementsAfterEnd: [],
                earliestRetainedMeasurement: start.addingTimeInterval(-7 * 86_400)),
            materialGapSeconds: .infinity)
        XCTAssertTrue(SleepConfidence.hints(a, clock: clock).isEmpty)
    }

    // MARK: - Gap rendering

    func testApproximateDurationNeverPrintsSecondsAndRoundsToTheEpoch() {
        XCTAssertEqual(SleepConfidence.approximateDuration(0), "1 minute",
                       "a sub-minute gap still reads as a minute — the cadence is 150 s")
        XCTAssertEqual(SleepConfidence.approximateDuration(90), "2 minutes")
        XCTAssertEqual(SleepConfidence.approximateDuration(3_600), "1 hour")
        XCTAssertEqual(SleepConfidence.approximateDuration(7_200), "2 hours")
        XCTAssertEqual(SleepConfidence.approximateDuration(241.9 * 60), "4h 2m")
    }

    // MARK: - Wire names

    /// These strings are a wire format for the diagnostics bundle and the data export: a rename
    /// silently invalidates every bundle already collected.
    func testExportNamesArePinned() {
        XCTAssertEqual(SleepConfidence.exportName(SleepConfidence.Reason.durationLikelyHigh),
                       "durationLikelyHigh")
        XCTAssertEqual(SleepConfidence.exportName(
            SleepConfidence.Reason.noRecordingAfterWake(from: t0, silentFor: 1)),
                       "noRecordingAfterWake")
        XCTAssertEqual(SleepConfidence.exportName(
            SleepConfidence.Reason.noRecordingBeforeBedtime(until: t0, silentFor: 1)),
                       "noRecordingBeforeBedtime")
        XCTAssertEqual(SleepConfidence.exportName(BedtimeProvenance.Verdict.resumedAfterGap(1)),
                       "resumedAfterGap")
        XCTAssertEqual(SleepConfidence.exportName(WakeProvenance.Verdict.stoppedThenResumed(1)),
                       "stoppedThenResumed")
        XCTAssertEqual(SleepConfidence.exportName(WakeProvenance.Verdict.unknown), "unknown")
    }

    /// A verdict that measured NO silence must report nil, not 0 — 0 would claim a continuous
    /// stream, which is precisely what `.unknown` cannot claim.
    func testGapSecondsIsNilRatherThanZeroWhenNothingWasMeasured() {
        XCTAssertNil(SleepConfidence.gapSeconds(BedtimeProvenance.Verdict.witnessed))
        XCTAssertNil(SleepConfidence.gapSeconds(BedtimeProvenance.Verdict.unknown))
        XCTAssertNil(SleepConfidence.gapSeconds(WakeProvenance.Verdict.witnessed))
        XCTAssertNil(SleepConfidence.gapSeconds(WakeProvenance.Verdict.unknown))
        XCTAssertEqual(SleepConfidence.gapSeconds(WakeProvenance.Verdict.stoppedThenResumed(42)), 42)
        XCTAssertEqual(SleepConfidence.gapSeconds(BedtimeProvenance.Verdict.resumedAfterGap(42)), 42)
    }
}

import XCTest
@testable import OpenCircuitKit

/// THE EDITABLE CEILING MUST NOT BE A FUNCTION OF HOW BADLY THE NIGHT WAS TRUNCATED.
///
/// THE REPORT (2026-08-27, Gen 2 tester, verbatim): *"this morning it again said I only slept for
/// less than 2h and then when I tried to edit it manually it had a limit on how late I could set the
/// wake up time. Why does it make these limits?"* No export was sent, so nothing here is fitted to
/// her night and nothing here claims to be her data — the numbers below are a SHAPE ("staging kept a
/// short head fragment of a full night"), chosen to be arithmetically representative of a sub-2 h
/// report, not a measurement. The justification for the fix is structural, and it is the sweep in
/// `testTheCeilingNeverTightensAsTheTruncationGetsWorse`, not any single night.
///
/// THE STRUCTURAL DEFECT. `bounds` anchored its ceiling on `recordedWake + strandedEditMargin` —
/// `recordedWake` being the very number the wearer opened the sheet to correct. Truncation moves
/// `recordedWake` earlier, so it moved the ceiling earlier by exactly the same amount: the editor was
/// at its tightest precisely when detection was at its worst. `SleepEdit.bounds`' own comment already
/// condemns that inference in its SPAN form (2026-08-24, "the inference 'long ⇒ not truncated' was
/// drawing its evidence from the very number she was trying to correct"); this suite pins the ANCHOR
/// form of the same argument.
///
/// Fixed anchor, no wall-clock — the bounds must not depend on when the sheet is opened.
final class SleepEditTruncatedCeilingTests: XCTestCase {

    private let ref = Date(timeIntervalSince1970: 1_700_000_000)
    private func at(_ h: Double) -> Date { ref.addingTimeInterval(h * 3600) }

    /// The rule the fix installs, restated independently of the implementation: the ceiling is at
    /// least one plausible night after the earliest bedtime the ±3 h parity rule itself would accept.
    private func oneNightAfterTheParityBedtime(_ recordedOnset: Date) -> Date {
        recordedOnset.addingTimeInterval(-SleepEdit.editMargin)
            .addingTimeInterval(SleepEdit.defaultMaxNightSpan)
    }

    // MARK: - the new property

    /// THE PROPERTY, AND THE ONE THAT FAILS ON MASTER. Hold the recorded ONSET still and truncate the
    /// night harder and harder by walking the recorded WAKE backwards. Every step is the same wearer,
    /// the same real night, and a progressively worse detection of it. The ceiling must have a FLOOR
    /// that the truncation cannot push through.
    ///
    /// On master there is no such floor: `latest` is `recordedWake + 6 h` and nothing else, so each
    /// 30-minute step of extra truncation costs the wearer exactly 30 minutes of reach, all the way
    /// down to nothing. Master fails this from the first step below the 5 h crossover and never
    /// recovers.
    ///
    /// ⚠️ THE HONEST SCOPE, because the stronger claim is tempting and false. This is NOT global
    /// monotonicity in truncation: above the crossover the ceiling still tracks `recordedWake`, so a
    /// night truncated from 9 h to 6 h does lose ceiling. That is unavoidable — "how much reach did
    /// this wearer lose?" cannot be answered without knowing the real night, which is precisely what
    /// we do not have. What CAN be guaranteed is a floor derived from an anchor the truncation does
    /// not move, and that is what is asserted.
    func testTheCeilingHasAFloorTheTruncationCannotMove() {
        let onset = at(0)
        let floor = oneNightAfterTheParityBedtime(onset)
        for wakeH in stride(from: 9.0, through: 0.25, by: -0.25) {
            let b = SleepEdit.bounds(recordedOnset: onset, recordedWake: at(wakeH))
            XCTAssertGreaterThanOrEqual(
                b.latest, floor,
                "a night truncated to \(wakeH)h dropped the editable ceiling below one plausible "
                + "night after the parity bedtime — the limit tightens as detection gets worse")
        }
    }

    /// The same defect as a wearer experiences it: staging kept a short head fragment of a full
    /// night, so the reported sleep is under two hours and the real morning wake sits past the old
    /// ceiling. SHAPE, not a capture (see the type comment).
    func testAHeadFragmentNightCanReachTheRealMorningWake() {
        let recordedOnset = at(0)        // ring-derived onset ≈ the real bedtime
        let recordedWake = at(1.75)      // where the record of the night stops: a 1 h 45 m "night"
        let realWake = at(8.5)           // the wearer knows when she got up

        XCTAssertLessThan(recordedWake.addingTimeInterval(SleepEdit.strandedEditMargin), realWake,
                          "precondition: the master ceiling (recordedWake + 6 h) is below her wake")

        let b = SleepEdit.bounds(recordedOnset: recordedOnset, recordedWake: recordedWake)
        XCTAssertGreaterThanOrEqual(b.latest, realWake,
                                    "her real wake must be selectable in the picker")

        // …and the corrected night validates end to end, so Save is not silently disabled.
        let times = SleepEdit.Times(inBedStart: recordedOnset,
                                    sleepOnset: recordedOnset.addingTimeInterval(300),
                                    sleepWake: realWake)
        XCTAssertNil(SleepEdit.validate(times, recordedOnset: recordedOnset,
                                        recordedWake: recordedWake, minDuration: 30 * 60),
                     "the validator must accept exactly what the picker offered")
    }

    /// The rule, spelled out so it cannot drift into a hand-tuned margin: for a truncated night the
    /// ceiling is ONE PLAUSIBLE NIGHT (`defaultMaxNightSpan`) after the earliest bedtime the ±3 h
    /// parity rule would accept — the same `floorEarliest + maxNightSpan` expression `bounds` already
    /// used to CAP `dataCoverage`. No new constant enters the file.
    func testTheCeilingIsOneNightAfterTheParityBedtime() {
        for wakeH in [0.5, 1.0, 2.0, 3.0, 4.0] {
            let b = SleepEdit.bounds(recordedOnset: at(0), recordedWake: at(wakeH))
            XCTAssertEqual(b.latest.timeIntervalSince1970,
                           oneNightAfterTheParityBedtime(at(0)).timeIntervalSince1970,
                           accuracy: 0.1,
                           "a \(wakeH) h recorded night must reach one night past the parity bedtime")
        }
    }

    // MARK: - what still bounds the night

    /// THE ADVERSARIAL CASE THE WIDENING MUST NOT BUY: a wearer trying to save a 20-hour "night".
    /// A far single edge is not a long window; only the pair is, and the pair is `validate`'s
    /// `.tooLong` rule. It must still bite — including on the widest window the new bounds offer.
    func testATwentyHourNightIsStillRejected() {
        let recordedOnset = at(0), recordedWake = at(1.75)
        let b = SleepEdit.bounds(recordedOnset: recordedOnset, recordedWake: recordedWake)

        let twentyHours = SleepEdit.Times(inBedStart: at(-6), sleepOnset: at(-5.75),
                                          sleepWake: at(14))
        XCTAssertEqual(twentyHours.inBedDuration, 20 * 3600, accuracy: 0.1, "precondition: 20 h")
        XCTAssertNotNil(SleepEdit.validate(twentyHours, recordedOnset: recordedOnset,
                                           recordedWake: recordedWake),
                        "a 20-hour night must be refused")
        // (It leaves the bounds as well as being too long, so `.endAfterLatest` is what the wearer
        // is told first. The case that matters is the next one: a too-long window built ENTIRELY out
        // of times the picker itself offers, where the pair rule is the only thing left to catch it.)

        // The widest window the picker itself can offer is refused — the edges deliberately no
        // longer pairwise-cap each other, so `.tooLong` is what carries the rule.
        let widest = SleepEdit.Times(inBedStart: b.earliest,
                                     sleepOnset: b.earliest.addingTimeInterval(900),
                                     sleepWake: b.latest)
        XCTAssertGreaterThan(widest.inBedDuration, SleepEdit.defaultMaxNightSpan,
                             "precondition: the bounds span more than one night")
        XCTAssertEqual(SleepEdit.validate(widest, recordedOnset: recordedOnset,
                                          recordedWake: recordedWake),
                       .tooLong(maxMinutes: Int(SleepEdit.defaultMaxNightSpan / 60)))

        // …and a window at exactly one night is accepted: the rule caps, it does not creep.
        let atLimit = SleepEdit.Times(inBedStart: b.earliest,
                                      sleepOnset: b.earliest.addingTimeInterval(900),
                                      sleepWake: b.earliest.addingTimeInterval(SleepEdit.defaultMaxNightSpan))
        XCTAssertLessThanOrEqual(atLimit.sleepWake, b.latest, "precondition: inside the bounds")
        XCTAssertNil(SleepEdit.validate(atLimit, recordedOnset: recordedOnset,
                                        recordedWake: recordedWake))
    }

    // MARK: - the invariants the three earlier drafts broke

    /// PURELY WIDENING. Master's ceiling (`recordedWake + strandedEditMargin`) is never lowered for
    /// any night, so nothing that used to be reachable stops being reachable.
    func testTheCeilingNeverFallsBelowTheStrandedMargin() {
        for onsetH in [-4.0, 0.0, 3.0] {
            for spanH in [0.25, 1.0, 3.0, 5.0, 8.0, 11.0, 13.0] {
                let onset = at(onsetH), wake = at(onsetH + spanH)
                let b = SleepEdit.bounds(recordedOnset: onset, recordedWake: wake)
                XCTAssertGreaterThanOrEqual(b.latest,
                                            wake.addingTimeInterval(SleepEdit.strandedEditMargin),
                                            "onset \(onsetH)h span \(spanH)h: the stranded ceiling "
                                            + "is a FLOOR the new rule may only add to")
            }
        }
    }

    /// TIME-INVARIANT: `bounds` is a pure function of the recorded night, so growing the archive
    /// through the day cannot move the ceiling down, and cannot move it at all once the truncation
    /// ceiling dominates. (Three earlier drafts made the editable window trail the wall clock.)
    func testTheCeilingDoesNotDependOnWhenTheSheetIsOpened() {
        let onset = at(0), wake = at(1.75)
        var previous: Date?
        for archiveEndH in [2.0, 4.0, 7.0, 10.0, 14.0, 20.0] {
            let b = SleepEdit.bounds(recordedOnset: onset, recordedWake: wake,
                                     dataCoverage: at(-3)...at(archiveEndH))
            if let previous {
                XCTAssertGreaterThanOrEqual(b.latest, previous,
                                            "the ceiling moved DOWN as the archive grew")
            }
            previous = b.latest
        }
    }

    /// A WELL-RECORDED NIGHT IS UNTOUCHED. The truncation ceiling is dominated by the stranded margin
    /// for any recorded span of 5 h or more (`maxNightSpan − editMargin − strandedEditMargin`), so
    /// every night that was already reachable keeps exactly the ceiling it had — the change is scoped
    /// to the nights that are demonstrably short.
    func testAWellRecordedNightKeepsExactlyTheOldCeiling() {
        for spanH in [5.0, 6.0, 8.0, 9.5, 12.0] {
            let onset = at(0), wake = at(spanH)
            let b = SleepEdit.bounds(recordedOnset: onset, recordedWake: wake)
            XCTAssertEqual(b.latest.timeIntervalSince1970,
                           wake.addingTimeInterval(SleepEdit.strandedEditMargin).timeIntervalSince1970,
                           accuracy: 0.1,
                           "a \(spanH) h recorded night must be byte-identical to the old rule")
        }
    }

    /// AN ALREADY-SAVED EDIT STAYS FULLY SELECTABLE, and a later fuller staging (`widenRecorded`
    /// pulls the recorded ONSET earlier) can never push it out of range. This is the one place the
    /// truncation ceiling is not monotone — it is anchored on the recorded onset, so an onset that
    /// moves earlier lowers it — and this test pins the two floors that make that harmless: the
    /// stranded ceiling and the saved edit itself, both applied after every cap.
    func testAnOnsetWideningCannotStrandASavedEdit() {
        let wake = at(1.75)
        let saved = at(0)...at(8.5)                      // what she saved this morning
        var lowestSeen = Date.distantFuture
        for onsetH in [0.0, -1.0, -3.0, -6.0] {          // successively fuller stagings
            let b = SleepEdit.bounds(recordedOnset: at(onsetH), recordedWake: wake,
                                     existingEdit: saved)
            XCTAssertLessThanOrEqual(b.earliest, saved.lowerBound)
            XCTAssertGreaterThanOrEqual(b.latest, saved.upperBound,
                                        "a fuller staging must not strand her own saved wake")
            XCTAssertGreaterThanOrEqual(b.latest,
                                        wake.addingTimeInterval(SleepEdit.strandedEditMargin),
                                        "…nor drop below the ceiling master already guaranteed")
            lowestSeen = min(lowestSeen, b.latest)
            XCTAssertNil(SleepEdit.validate(.init(inBedStart: saved.lowerBound,
                                                  sleepOnset: saved.lowerBound.addingTimeInterval(300),
                                                  sleepWake: saved.upperBound),
                                            recordedOnset: at(onsetH), recordedWake: wake,
                                            existingEdit: saved),
                         "re-opening an edited night must not silently clamp her own times")
        }
        XCTAssertGreaterThanOrEqual(lowestSeen, saved.upperBound)
    }

    // MARK: - the bounds ↔ provenance pairing

    /// THE PAIRING. Widening the bounds without the provenance tagging turns one wrong number into a
    /// bigger wrong number. Everything the new ceiling makes reachable must still be labelled: the
    /// minutes past what the ring recorded come back `.asserted`, not `.measured`.
    func testEveryMinuteTheNewCeilingUnlocksIsStillTaggedAsserted() {
        let recordedOnset = at(0), recordedWake = at(1.75), realWake = at(8.5)
        let b = SleepEdit.bounds(recordedOnset: recordedOnset, recordedWake: recordedWake)
        XCTAssertGreaterThanOrEqual(b.latest, realWake, "precondition: the new ceiling reaches it")

        let base = [SleepSegment(start: recordedOnset, end: recordedWake, stage: .asleepCore)]
        // The ring recorded the fragment and nothing after it.
        let coverage = MeasuredCoverage(intervals: [recordedOnset ..< recordedWake])
        let out = SleepEdit.recompute(baseSegments: base,
                                      times: .init(inBedStart: recordedOnset,
                                                   sleepOnset: recordedOnset,
                                                   sleepWake: realWake),
                                      coverage: coverage)
        let asserted = out.filter { $0.stage != .inBed && $0.provenance == .asserted }
            .reduce(0.0) { $0 + $1.duration }
        let measured = out.filter { $0.stage != .inBed && $0.provenance == .measured }
            .reduce(0.0) { $0 + $1.duration }
        XCTAssertEqual(asserted, realWake.timeIntervalSince(recordedWake), accuracy: 1,
                       "every unlocked minute past the recording must be tagged .asserted")
        XCTAssertEqual(measured, recordedWake.timeIntervalSince(recordedOnset), accuracy: 1,
                       "and the recorded fragment must stay .measured")
        XCTAssertFalse(out.contains { $0.stage != .inBed && $0.end > recordedWake
                                        && $0.provenance == .measured },
                       "nothing past the recording may claim to be a measurement")
    }
}

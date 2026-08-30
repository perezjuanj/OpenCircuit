// THE TWO DEVICE-PROVEN TESTER NIGHTS, COMMITTED AS FIXTURES.
//
// WHAT IS COMMITTED HERE AND WHY IT IS ALLOWED. Only two kinds of number appear below: epoch-second
// TIMESTAMPS of when the ring was and was not recording, and the STAGE LABELS the shipped staging
// pipeline produced. No heart rate, no SpO2, no HRV, no motion, no temperature — no physiological
// payload of any kind, and no raw capture. These are decoded findings, which `CLAUDE.md` permits and
// requires; the raw `.b64` stays gitignored in `desktop/captures/sleep-corpus`.
//
// PROVENANCE OF EVERY NUMBER IN THIS FILE. Extracted 2026-08-20 by `SleepProvenanceFixtureProbe`
// from those raw bytes, through the same `SleepReplay` transcription the fidelity proof uses. The
// corpus-gated `SleepProvenanceCorpusTests` re-derives the same conclusions from the bytes
// themselves on a machine that holds them; this file is what survives on a machine that does not.
//
// "FAILS ON MASTER" — precisely what that means here. Master has no `coverage:` parameter, no
// `SleepProvenance`, and no `SleepProvenanceBreakdown`, so this file cannot compile against it. What
// makes the tests non-vacuous is that each one runs BOTH arms on identical inputs: the OFF arm
// (`coverage: nil`) is the kill switch and is byte-identical to master, and every test asserts the
// master-equivalent number is WRONG and the new one is right. `testOffArmReproducesTheShippedCard`
// pins the OFF arm to the efficiency the tester's phone actually exported, to 16 digits — so the
// baseline these tests measure against is the shipped product, not an assumption about it.

import XCTest
@testable import OpenCircuitKit

final class SleepProvenanceTesterNight0818Tests: XCTestCase {

    // R2_2026-08-18 · RingConn Gen 2 Air FR04.009 · Europe/Paris · 388 records · app build 45.
    // Stored by the app: 403 asleep / 36 awake / efficiency 0.9179954441913439 / score 71,
    // on a night whose own exported `appCoverageFraction` is 0.377.

    private func d(_ e: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(e)) }

    /// The seven merged spans the ring actually recorded across, from the FULL record union.
    /// Note the sixth ends 02:37:32 and the seventh does not begin until 06:38:57 — that
    /// 4-hour hole is the ground the app filled with `.asleepCore`.
    private var coverage: MeasuredCoverage {
        MeasuredCoverage(intervals: [
            d(1_786_960_827) ..< d(1_786_965_327),   // 12:00:27 -> 13:15:27
            d(1_786_965_331) ..< d(1_786_984_681),   // 13:15:31 -> 18:38:01
            d(1_786_989_748) ..< d(1_786_996_648),   // 20:02:28 -> 21:57:28
            d(1_786_996_649) ..< d(1_786_999_542),   // 21:57:29 -> 22:45:42
            d(1_786_999_587) ..< d(1_787_012_637),   // 22:46:27 -> 02:23:57
            d(1_787_012_702) ..< d(1_787_013_452),   // 02:25:02 -> 02:37:32
            d(1_787_027_937) ..< d(1_787_029_137),   // 06:38:57 -> 06:58:57   <- after the hole
        ])
    }

    /// What `SleepStaging.classify` produced from those bytes: in-bed 22:24:25 -> 02:37:02,
    /// 253 in-bed / 249 asleep / 3 awake / deep 43 / rem 51 / light 156, efficiency 0.9873.
    private var stagedBase: [SleepSegment] {
        func s(_ a: Int, _ b: Int, _ st: SleepStage) -> SleepSegment {
            SleepSegment(start: d(a), end: d(b), stage: st)
        }
        return [
            s(1_786_998_265, 1_787_013_422, .inBed),
            s(1_786_998_265, 1_786_998_342, .awake),
            s(1_786_998_342, 1_786_998_792, .asleepCore),
            s(1_786_998_792, 1_786_999_092, .asleepREM),
            s(1_786_999_092, 1_787_002_737, .asleepCore),
            s(1_787_002_737, 1_787_003_637, .asleepREM),
            s(1_787_003_637, 1_787_003_821, .asleepCore),
            s(1_787_003_821, 1_787_003_937, .awake),
            s(1_787_003_937, 1_787_005_437, .asleepCore),
            s(1_787_005_437, 1_787_006_037, .asleepDeep),
            s(1_787_006_037, 1_787_007_987, .asleepCore),
            s(1_787_007_987, 1_787_009_037, .asleepDeep),
            s(1_787_009_037, 1_787_009_487, .asleepCore),
            s(1_787_009_487, 1_787_009_937, .asleepREM),
            s(1_787_009_937, 1_787_010_237, .asleepCore),
            s(1_787_010_237, 1_787_011_137, .asleepDeep),
            s(1_787_011_137, 1_787_011_287, .asleepCore),
            s(1_787_011_287, 1_787_012_037, .asleepREM),
            s(1_787_012_037, 1_787_012_337, .asleepCore),
            s(1_787_012_337, 1_787_013_002, .asleepREM),
            s(1_787_013_002, 1_787_013_422, .asleepCore),
        ]
    }

    /// What the tester dragged: in bed 23:24, asleep from 00:00, awake at 06:43.
    private var times: SleepEdit.Times {
        SleepEdit.Times(inBedStart: d(1_787_001_840),   // 2026-08-17 23:24:00 +02:00
                        sleepOnset: d(1_787_004_000),   // 2026-08-18 00:00:00 +02:00
                        sleepWake: d(1_787_028_180))    // 2026-08-18 06:43:00 +02:00
    }

    private var off: [SleepSegment] {
        SleepEdit.recompute(baseSegments: stagedBase, times: times, coverage: nil)
    }
    private var on: [SleepSegment] {
        SleepEdit.recompute(baseSegments: stagedBase, times: times, coverage: coverage)
    }

    // MARK: The defect, reproduced

    func testOffArmReproducesTheShippedCardToSixteenDigits() {
        // If this drifts, every "before" number in this file is unmoored — so pin it hard.
        let m = SleepStaging.summary(off).minutes
        XCTAssertEqual(m.asleep, 403, "the app stored 403 asleep-minutes for this night")
        XCTAssertEqual(m.awake, 36)
        XCTAssertEqual(SleepStaging.summary(off).efficiency, 0.9179954441913439, accuracy: 1e-15,
                       "the tester's own export carries this efficiency to 16 digits")
    }

    func testMasterEmitsOneInventedBlockOverTheFourHourHole() {
        // The single segment at the heart of the defect: `{asleepCore, 02:37:02 -> 06:43:00}`.
        let invented = off.filter {
            $0.stage == .asleepCore && $0.start == d(1_787_013_422) && $0.end == d(1_787_028_180)
        }
        XCTAssertEqual(invented.count, 1, "the 246-minute fill must still be emitted — display is honoured")
        XCTAssertEqual(invented.first?.duration, 14758, "14758 s, exactly as exported")

        // …and on master it is indistinguishable from measured sleep.
        XCTAssertTrue(off.allSatisfy { $0.provenance == .measured })
        XCTAssertFalse(off.containsAssertedTime)
    }

    // MARK: The fix

    func testTheInventedBlockIsTaggedAssertedAndTheDisplayIsUNCHANGED() {
        // Clause 1: an assertion wins for display. The user still sees the window they dragged.
        XCTAssertEqual(SleepStaging.summary(on).minutes.asleep,
                       SleepStaging.summary(off).minutes.asleep,
                       "the fix must not silently shorten the user's night")

        let b = SleepProvenanceBreakdown(segments: on)
        XCTAssertEqual(b.displayedAsleep / 60, 403, accuracy: 0.5)

        // Clause 3: but almost none of it is measured.
        XCTAssertEqual(b.assertedAsleep / 60, 241.4, accuracy: 0.2,
                       "241.4 of the 403 displayed asleep-minutes are over ground holding no records")
        XCTAssertEqual(b.measuredAsleep / 60, 161.6, accuracy: 0.2)
        XCTAssertGreaterThan(b.longestUnmeasuredGap, 4 * 3600 - 60,
                             "the 02:37 -> 06:39 hole is over four hours long")
    }

    func testEfficiencyIsRecomputedOverCoveredGroundOnly() {
        let b = SleepProvenanceBreakdown(segments: on)
        XCTAssertEqual(b.coverageFraction, 0.448, accuracy: 0.002)
        let eff = try? XCTUnwrap(b.efficiency)
        XCTAssertEqual(eff ?? -1, 0.8223, accuracy: 0.001,
                       "0.8223 over ground the ring saw, versus the 0.9180 the app shipped")
        XCTAssertLessThan(eff ?? 1, SleepStaging.summary(off).efficiency,
                          "the honest number must be lower than the one built on the invented block")
    }

    func testTheScoreIsWithheldOnThisNight() {
        // 55 % of this in-bed window holds no data. `timeAsleep` is the score's dominant factor
        // (weight 0.30, SleepScore.swift:93) and is precisely what cannot be answered here.
        XCTAssertFalse(SleepProvenanceBreakdown(segments: on).isScorable)
        XCTAssertNotNil(SleepProvenanceBreakdown(segments: on).withheldReason)
    }

    func testPerStageMinutesExcludeTheInventedBlock() {
        // Today the 246-minute block lands in `light` (Summary.light), so a third-party chart shows
        // four hours of light sleep that never existed. There is no defensible way to stage
        // unmeasured time.
        let offLight = SleepStaging.summary(off).minutes.light
        let b = SleepProvenanceBreakdown(segments: on)
        XCTAssertEqual(offLight, 329, "the app stored 329 light-minutes for this night")
        XCTAssertEqual(b.minutes.light, 88, accuracy: 2,
                       "measured light only — the invented core block is gone from the breakdown")
        XCTAssertEqual(b.minutes.deep, 43, accuracy: 1, "measured deep is untouched")
        XCTAssertEqual(b.minutes.rem, 31, accuracy: 1, "measured REM is untouched")
    }

    /// THE NUMBER THE SLEEP CARD'S HATCH IS SIZED BY, pinned so the comment on `stageBar` cites a
    /// measurement this repo can re-derive rather than a remembered one. `assertedLight` is the part
    /// of the stored Light bar that is the wearer's account over ground we can PROVE holds no
    /// records; measured Light plus asserted Light must reconstruct the bar the card actually draws,
    /// or the hatch would be sized against a total it does not belong to.
    func testTheAssertedLightIsTheHatchedShare() {
        let b = SleepProvenanceBreakdown(segments: on)
        XCTAssertEqual(b.assertedLight / 60, 241.4, accuracy: 0.2,
                       "the 246-minute fill lands in Light, and it is hers")
        XCTAssertEqual(b.assertedDeep, 0)
        XCTAssertEqual(b.assertedREM, 0)
        XCTAssertEqual(Double(SleepStaging.summary(off).minutes.light),
                       b.measuredLight / 60 + b.assertedLight / 60, accuracy: 1.5,
                       "88 measured + 241 asserted is the 329 the app stored and the card draws")
    }

    // MARK: Apple Health

    /// ⚠️ RE-BASELINED 2026-08-24, AND THE NUMBER IT PINS DID NOT MOVE. This used to assert that no
    /// asleep sample overlaps the 4 h hole and that 241.4 minutes were REMOVED from the Apple Health
    /// write. The maintainer reversed the withholding after a second tester wrote in — her corrected
    /// night never reached Health while the official RingConn app's did — so the same 241.4 minutes
    /// are now written, carrying `HKMetadataKeyWasUserEntered`. The assertion follows them: every
    /// asleep sample over the hole must be in the USER-ENTERED bucket, which is a strictly stronger
    /// statement than "there are none" (it fails both if one is missing and if one is untagged).
    func testTheAssertedSleepReachesHealthTaggedAndTheInBedClaimSurvives() {
        let publication = on.healthPublication
        let asleepStages: Set<SleepStage> = [.asleepCore, .asleepDeep, .asleepREM]

        // No PLAIN asleep sample may overlap the hole — a sample over ground holding no records
        // must never be indistinguishable from a measurement.
        let hole = d(1_787_013_452) ..< d(1_787_027_937)
        for seg in publication.measured where asleepStages.contains(seg.stage) {
            XCTAssertFalse(seg.start < hole.upperBound && seg.end > hole.lowerBound,
                           "an UNTAGGED asleep sample overlaps the 4 h hole: \(seg)")
        }

        // …the user's in-bed claim is still written, because we hold no competing measurement about
        // where their body was. Apple's own Sleep UI reads Time in Bed 7 h 19 m.
        let inBedEnd = publication.published.filter { $0.stage == .inBed }.map(\.end).max()
        XCTAssertEqual(inBedEnd, d(1_787_028_180),
                       "the in-bed envelope must still reach 06:43 — dropping it discards a user claim")

        // …and Apple's Time Asleep now matches the card, with 241.4 of its minutes attributed to her.
        let removed = (SleepStaging.totalAsleep(off) - SleepStaging.totalAsleep(publication.published)) / 60
        XCTAssertEqual(removed, 0, accuracy: 0.01, "nothing is retracted from the write any more")
        let tagged = SleepStaging.totalAsleep(publication.userEntered) / 60
        XCTAssertEqual(tagged, 241.4, accuracy: 0.2,
                       "241.4 asleep-minutes reach Apple Health as the wearer's own entry")
        XCTAssertTrue(on.withheldSpans.isEmpty,
                      "withheld ground drives a DELETE exclusion — publishing while still reporting "
                      + "these spans as withheld duplicates the night on every re-edit")
    }

    // MARK: The measurement survives

    func testTheRingsOwnStagingIsRecoverableAlongsideTheEdit() {
        // 94 minutes of dense measurement are destroyed by this edit in the OTHER direction:
        // 58.3 min of recorded sleep dropped outside the in-bed window, and 36.0 min painted awake.
        // The edit output cannot carry them — which is exactly why the recorded hypnogram is
        // persisted separately (`StoredSleepSummary.recordedHypnogramData`).
        let recordedSleep = SleepStaging.sleepWindow(stagedBase)
        XCTAssertEqual(recordedSleep?.onset, d(1_786_998_342), "22:25:42 — 58.3 min before the edit's in-bed start")
        XCTAssertLessThan(try XCTUnwrap(recordedSleep?.onset), times.inBedStart)

        // The edit output has no segment before 23:24, so this measurement is unreachable from it.
        XCTAssertNil(on.map(\.start).min().flatMap { $0 < times.inBedStart ? $0 : nil })
        // …and the recorded hypnogram round-trips through the codec unchanged, provenance included.
        XCTAssertEqual(SleepHypnogramCodec.decode(SleepHypnogramCodec.encode(stagedBase)), stagedBase)
    }

    // MARK: The export's coverage number cannot see this night's hole

    /// THE FALSIFIABILITY DEFECT, ON THE NIGHT IT WAS FOUND ON.
    ///
    /// This fixture's DETECTED window is 22:24:25 → 02:37:02 — it ends there because that is where
    /// the records end. So the four-hour hole this whole file exists for begins one instant AFTER
    /// the window closes, and coverage measured over it reports a flawless night. Move only the
    /// right edge to a wake the recording did not define and the same records score barely half.
    ///
    /// ⚠️ WHAT THIS DOES *NOT* CLAIM. The export did not publish 1.0000 for THIS night: it measures
    /// `sleepSessions[].coverage` over the night's REPORTED window, and this night was corrected, so
    /// the real export carries `appCoverageFraction 0.377` (the class header). The defect this pins
    /// is the one a wearer who never opens the editor is left with — for her the reported window IS
    /// the detected window, and the number below is the only one she gets.
    ///
    /// The instants are generated at the ring's own 150 s epoch step across this fixture's COMMITTED
    /// recording spans — they are that fixture's statement of when the ring was and was not
    /// recording, not a new measurement. The reference instant is this night's own corrected wake
    /// (06:43, the one externally-supplied instant the fixture carries); in production the reference
    /// is the wearer's manual schedule wake (`ExportReferenceCoverage`), and the arithmetic below
    /// does not depend on which of the two supplies it.
    func testCoverageInTheDetectedWindowCannotSeeTheFourHourHole() {
        var witness: [Date] = []
        for span in coverage.intervals {
            var t = span.lowerBound
            while t < span.upperBound {
                witness.append(t)
                t = t.addingTimeInterval(150)
            }
        }
        let detectedStart = d(1_786_998_265)   // 22:24:25 — stagedBase's in-bed start
        let detectedEnd = d(1_787_013_422)     // 02:37:02 — and its end, i.e. the last record

        let detected = ExportCoverage.assess(sampleTimes: witness,
                                             from: detectedStart, to: detectedEnd)
        XCTAssertEqual(detected.coverageFraction, 1.0, accuracy: 1e-9,
                       "1.0000 on the night the app invented 246 minutes of sleep")
        XCTAssertTrue(detected.gaps.isEmpty, "and not one gap, because the hole is outside")

        let againstHerWake = ExportCoverage.assess(sampleTimes: witness,
                                                   from: detectedStart, to: times.sleepWake)
        XCTAssertLessThan(againstHerWake.coverageFraction, 0.60,
                          "the same records, one denominator the recording did not choose")
        XCTAssertEqual(againstHerWake.gaps.count, 1)
        XCTAssertGreaterThan(againstHerWake.gaps.first?.seconds ?? 0, 4 * 3600,
                             "over four hours, and it was invisible to the number we published")
    }
}

final class SleepProvenanceTesterNight0817Tests: XCTestCase {

    // R2_2026-08-17 · same ring, the night before. Stored: 246 asleep / 245 awake / eff 0.5008 /
    // score 19. This is the night that decides the DESIGN: her asserted 246-minute sleep window
    // contains ONE epoch, so 100 % of the displayed sleep total is invented — while the 102.5 min
    // the ring actually staged (97.6 % covered, 30 min deep + 20 min REM) is displayed as awake.

    private func d(_ e: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(e)) }

    private var coverage: MeasuredCoverage {
        MeasuredCoverage(intervals: [
            d(1_786_921_006) ..< d(1_786_926_856),   // 00:56:46 -> 02:34:16
            d(1_786_927_034) ..< d(1_786_927_184),   // 02:37:14 -> 02:39:44   <- the ONE epoch
            d(1_786_941_771) ..< d(1_786_948_971),   // 06:42:51 -> 08:42:51
            d(1_786_948_977) ..< d(1_786_960_827),   // 08:42:57 -> 12:00:27
        ])
    }

    private var stagedBase: [SleepSegment] {
        func s(_ a: Int, _ b: Int, _ st: SleepStage) -> SleepSegment {
            SleepSegment(start: d(a), end: d(b), stage: st)
        }
        return [
            s(1_786_921_006, 1_786_927_154, .inBed),
            s(1_786_921_006, 1_786_921_456, .asleepCore),
            s(1_786_921_456, 1_786_921_906, .asleepREM),
            s(1_786_921_906, 1_786_923_106, .asleepCore),
            s(1_786_923_106, 1_786_924_306, .asleepDeep),
            s(1_786_924_306, 1_786_925_806, .asleepCore),
            s(1_786_925_806, 1_786_926_556, .asleepREM),
            s(1_786_926_556, 1_786_927_154, .asleepDeep),
        ]
    }

    /// 22:33:46 the previous evening, "asleep" from 02:39:00, awake 06:45:00.
    private var times: SleepEdit.Times {
        SleepEdit.Times(inBedStart: d(1_786_912_426),
                        sleepOnset: d(1_786_927_140),
                        sleepWake: d(1_786_941_900))
    }

    func testTheEntireDisplAYEDSleepTotalIsAnAssertion() {
        let on = SleepEdit.recompute(baseSegments: stagedBase, times: times, coverage: coverage)
        let b = SleepProvenanceBreakdown(segments: on)
        XCTAssertEqual(b.displayedAsleep / 60, 246, accuracy: 0.5, "the card still says 246 min")
        XCTAssertEqual(b.measuredAsleep / 60, 2.9, accuracy: 0.2,
                       "one 150 s epoch — 1.0 % of the asserted window")
        XCTAssertEqual(b.assertedAsleep / 60, 243.1, accuracy: 0.2)
        XCTAssertNil(b.efficiency, "102 min of covered in-bed is not enough ground for a ratio")
        XCTAssertFalse(b.isScorable)
    }

    func testTheNAIVEVETOWouldProduceAWorseNumberThanTheBug() {
        // THE REASON THIS FILE ARGUES FOR PROVENANCE INSTEAD OF REFUSING THE FILL.
        // `preservedEnd - preservedStart` = 02:39:14 − 02:39:00 = 14 SECONDS. Delete the fill and
        // her card reads 0 min asleep across an 8 h 11 m in-bed window — a nonsense number
        // replacing a wrong one, on the night she took the trouble to correct it.
        let recorded = try? XCTUnwrap(SleepStaging.sleepWindow(stagedBase.filter { $0.stage != .inBed }))
        let preservedStart = max(times.sleepOnset, recorded?.onset ?? .distantPast)
        let preservedEnd = min(times.sleepWake, recorded?.wake ?? .distantFuture)
        XCTAssertEqual(preservedEnd.timeIntervalSince(preservedStart), 14, accuracy: 0.5,
                       "fourteen seconds — this is what a data-availability veto would preserve")
    }

    func testTheRelabelledMeasuredSleepIsVisibleAsADisagreement() {
        // 102.5 min of 97.6 %-covered sleep — 30 min of it deep — is painted `.awake` by the edit.
        // We do NOT overrule her (clause 1), but the paint is tagged `.assertedOverMeasured`, so the
        // app can say "the ring recorded 1 h 43 m of sleep inside the time you marked awake" and
        // offer Restore. That disagreement is also a LABEL, and this campaign is starved of labels.
        let on = SleepEdit.recompute(baseSegments: stagedBase, times: times, coverage: coverage)
        let contested = on.filter { $0.stage == .awake && $0.provenance == .assertedOverMeasured }
        let contestedMin = contested.reduce(0.0) { $0 + $1.duration } / 60
        XCTAssertEqual(contestedMin, 100.0, accuracy: 1.0,
                       "~100 min of the awake paint sits on ground the ring recorded")

        // And the ring's own reading survives verbatim in the recorded hypnogram.
        let deep = stagedBase.filter { $0.stage == .asleepDeep }.reduce(0.0) { $0 + $1.duration } / 60
        XCTAssertEqual(deep, 30.0, accuracy: 0.5, "30 minutes of measured deep sleep, recoverable")
    }

    /// ⚠️ RE-BASELINED 2026-08-24, SAME SPLIT, NEW DESTINATION. This asserted that Health received
    /// 2.9 of the 246 asleep-minutes — the other 243.1 withheld. The maintainer reversed the
    /// withholding, so Health receives all 246 and 243.1 of them carry
    /// `HKMetadataKeyWasUserEntered`. The 243.1 is still pinned, on the bucket it now lands in; the
    /// 2.9 measured minutes are still pinned as the part the ring actually saw.
    func testTheAssertedSleepIsWrittenAsHerOwnEntryOnThisNight() {
        let on = SleepEdit.recompute(baseSegments: stagedBase, times: times, coverage: coverage)
        let publication = on.healthPublication
        XCTAssertEqual(SleepStaging.totalAsleep(publication.published) / 60, 246, accuracy: 0.5,
                       "the night she asserted reaches Apple Health in full")
        XCTAssertEqual(SleepStaging.totalAsleep(publication.userEntered) / 60, 243.1, accuracy: 0.2,
                       "243.1 of those minutes are her account, and are tagged as such")
        XCTAssertEqual(SleepStaging.totalAsleep(publication.measured) / 60, 2.9, accuracy: 0.2,
                       "only 2.9 asleep-minutes go in as an unqualified measurement")
        // The in-bed claim survives in full: 22:33:46 -> 06:45:00.
        let published = publication.published
        XCTAssertEqual(published.filter { $0.stage == .inBed }.map(\.start).min(), d(1_786_912_426))
        XCTAssertEqual(published.filter { $0.stage == .inBed }.map(\.end).max(), d(1_786_941_900))
    }
}

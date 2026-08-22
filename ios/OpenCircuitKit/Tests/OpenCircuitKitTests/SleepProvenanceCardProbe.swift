// Prints the full before/after card + Health payload for the two tester nights, from the committed
// fixtures (no corpus needed) — this is the evidence artifact for the change.
//
// ⚠️ IT ALSO ASSERTS. A print-only test reports `passed` having checked nothing, which is exactly
// the silent-pass pattern the corpus-gate audit was written to kill. `report` returns the two
// numbers the whole change turns on — the shipped card it must reproduce, and the asleep-minutes it
// stops writing to Health — and the caller pins both.

import XCTest
@testable import OpenCircuitKit

final class SleepProvenanceCardProbe: XCTestCase {

    private func d(_ e: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(e)) }

    /// - Returns: `(shippedAsleepMin, retractedAsleepMin, cardNotice)` — the before-card total this
    ///   must reproduce, the asleep-minutes removed from the Apple Health write, and the exact Sleep
    ///   card line that accounts for the difference between the two.
    @discardableResult
    private func report(_ name: String, base: [SleepSegment], times: SleepEdit.Times,
                        coverage: MeasuredCoverage) -> (shippedAsleepMin: Int,
                                                        retractedAsleepMin: Double,
                                                        cardNotice: String?) {
        let off = SleepEdit.recompute(baseSegments: base, times: times, coverage: nil)
        let on = SleepEdit.recompute(baseSegments: base, times: times, coverage: coverage)
        let sOff = SleepStaging.summary(off), mOff = sOff.minutes
        let b = SleepProvenanceBreakdown(segments: on)
        let m = b.minutes

        func score(_ s: SleepStaging.Summary) -> Int {
            SleepScore.composite(.init(totalAsleep: s.totalAsleep, timeAwake: s.awake,
                                       efficiency: s.efficiency, deep: s.deep,
                                       light: s.light, rem: s.rem)).score
        }
        let healthOff = SleepStaging.totalAsleep(off) / 60
        let healthOn = SleepStaging.totalAsleep(on.healthPublishable) / 60
        let inBedOff = off.filter { $0.stage == .inBed }.reduce(0.0) { $0 + $1.duration } / 60
        let inBedOn = on.healthPublishable.filter { $0.stage == .inBed }
            .reduce(0.0) { $0 + $1.duration } / 60
        // The Sleep-card line the wearer reads under the footer — the copy half of this change,
        // rendered from the very same breakdown the Health filter is driven by. `true` here is the
        // sleep-share-authorized case, i.e. what the tester actually sees.
        let notice = SleepEditedNightNotice.line(measuredAsleep: b.measuredAsleep,
                                                 assertedAsleep: b.assertedAsleep,
                                                 mirrorsSleepToHealth: true)

        print("""

        ================ \(name) ================
        BEFORE (master / kill switch)
          card      asleep \(mOff.asleep)  awake \(mOff.awake)  inBed \(mOff.inBed)
          stages    light \(mOff.light)  deep \(mOff.deep)  rem \(mOff.rem)
          eff       \(String(format: "%.4f", sOff.efficiency))
          score     \(score(sOff))
          -> Health asleep \(String(format: "%.1f", healthOff)) min · inBed \(String(format: "%.1f", inBedOff)) min
        AFTER (provenance)
          card      asleep \(mOff.asleep) = \(m.measuredAsleep) measured + \(m.assertedAsleep) asserted
                    awake \(mOff.awake)  inBed \(m.inBed) (covered \(m.coveredInBed))
          stages    light \(m.light)  deep \(m.deep)  rem \(m.rem)   [measured only]
          eff       \(b.efficiency.map { String(format: "%.4f", $0) } ?? "WITHHELD (—)") \
        over covered ground
          score     \(b.isScorable ? String(score(sOff)) : "WITHHELD (—)")
          coverage  \(String(format: "%.4f", b.coverageFraction))  longest gap \
        \(String(format: "%.1f", b.longestUnmeasuredGap / 60)) min
          -> Health asleep \(String(format: "%.1f", healthOn)) min · inBed \(String(format: "%.1f", inBedOn)) min
          RETRACTED  \(String(format: "%.1f", healthOff - healthOn)) asleep-min no longer written
          reason     \(b.withheldReason ?? "—")
          CARD LINE  \(notice ?? "— (silent)")
        """)

        // The card the user sees must not change — clause 1.
        XCTAssertEqual(SleepStaging.summary(on).minutes.asleep, mOff.asleep, name)
        // …and the in-bed claim must survive to Health in full.
        XCTAssertEqual(inBedOn, inBedOff, accuracy: 0.01, "\(name): the in-bed claim was dropped")
        // The retraction may not ship without the line that accounts for it.
        XCTAssertNotNil(notice, "\(name): Health drops asleep-minutes with nothing on the card saying so")
        return (mOff.asleep, healthOff - healthOn, notice)
    }

    func testBothTesterNightsReproduceTheShippedCardAndRetractTheInventedSleep() {
        func s(_ a: Int, _ b: Int, _ st: SleepStage) -> SleepSegment {
            SleepSegment(start: d(a), end: d(b), stage: st)
        }

        let n0818 = report("R2_2026-08-18  (shipped: 403 asleep / 36 awake / 0.9180 / score 71)",
               base: [
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
               ],
               times: .init(inBedStart: d(1_787_001_840), sleepOnset: d(1_787_004_000),
                            sleepWake: d(1_787_028_180)),
               coverage: MeasuredCoverage(intervals: [
                d(1_786_960_827) ..< d(1_786_965_327), d(1_786_965_331) ..< d(1_786_984_681),
                d(1_786_989_748) ..< d(1_786_996_648), d(1_786_996_649) ..< d(1_786_999_542),
                d(1_786_999_587) ..< d(1_787_012_637), d(1_787_012_702) ..< d(1_787_013_452),
                d(1_787_027_937) ..< d(1_787_029_137),
               ]))

        let n0817 = report("R2_2026-08-17  (shipped: 246 asleep / 245 awake / 0.5008 / score 19)",
               base: [
                s(1_786_921_006, 1_786_927_154, .inBed),
                s(1_786_921_006, 1_786_921_456, .asleepCore),
                s(1_786_921_456, 1_786_921_906, .asleepREM),
                s(1_786_921_906, 1_786_923_106, .asleepCore),
                s(1_786_923_106, 1_786_924_306, .asleepDeep),
                s(1_786_924_306, 1_786_925_806, .asleepCore),
                s(1_786_925_806, 1_786_926_556, .asleepREM),
                s(1_786_926_556, 1_786_927_154, .asleepDeep),
               ],
               times: .init(inBedStart: d(1_786_912_426), sleepOnset: d(1_786_927_140),
                            sleepWake: d(1_786_941_900)),
               coverage: MeasuredCoverage(intervals: [
                d(1_786_921_006) ..< d(1_786_926_856), d(1_786_927_034) ..< d(1_786_927_184),
                d(1_786_941_771) ..< d(1_786_948_971), d(1_786_948_977) ..< d(1_786_960_827),
               ]))

        // Pin the two headline numbers so this file cannot decay into a print-only pass.
        XCTAssertEqual(n0818.shippedAsleepMin, 403, "must reproduce the tester's stored card")
        XCTAssertEqual(n0817.shippedAsleepMin, 246, "must reproduce the tester's stored card")
        XCTAssertEqual(n0818.retractedAsleepMin, 241.4, accuracy: 0.2)
        XCTAssertEqual(n0817.retractedAsleepMin, 243.1, accuracy: 0.2)
        XCTAssertEqual(n0818.retractedAsleepMin + n0817.retractedAsleepMin, 484.5, accuracy: 0.4,
                       "484.5 invented asleep-minutes stop reaching Apple Health across the two nights")

        // …and pin the exact card line for each, verbatim. This is the sentence that keeps the
        // Health subtraction from shipping unaccounted for; a silent reword is a regression.
        XCTAssertEqual(n0818.cardNotice,
                       "We kept the times you set. The ring recorded 2h 42m of the sleep above; for "
                       + "the other 4h 1m we have your account, not a measurement. Only the measured "
                       + "part reaches Apple Health, so your sleep there reads shorter.")
        XCTAssertEqual(n0817.cardNotice,
                       "We kept the times you set. The ring recorded 3 minutes of the sleep above; "
                       + "for the other 4h 3m we have your account, not a measurement. Only the "
                       + "measured part reaches Apple Health, so your sleep there reads shorter.")
    }
}

// THE FROZEN "PROVEN HOLE" THAT LATER FILLS — the 2026-08-24 tester night, as a fixture.
//
// WHAT IS COMMITTED HERE AND WHY IT IS ALLOWED. Epoch-second TIMESTAMPS of when the ring was and was
// not recording, plus the STAGE LABELS the shipped edit path produced. No heart rate, no SpO2, no
// HRV, no motion, no temperature — decoded findings only, exactly as `CLAUDE.md` requires.
//
// PROVENANCE OF EVERY NUMBER BELOW. Re-derived 2026-08-24 from the tester's own Data Export
// (`opencircuit-night-2026-08-24.json`, Gen 2 Air FR04.009, ring …59F91, Europe/Paris):
//   · the stored hypnogram's last segment is `{asleepCore, 02:45:17 → 06:44:00, asserted, 14323 s}`
//     — the export prints it verbatim, and `provenanceSummary.assertedAsleepSec` is the same 14323;
//   · `epochArchive.recordsBase64` decodes to NINE 0x4c records after the 02:42:47 one that was the
//     newest when she saved: 02:48:53 · 02:51:23 · 02:53:53 · 02:56:23 · 02:58:53 · 03:01:23 ·
//     03:03:53 · 03:06:23 · 03:08:53. At the 150 s cadence they are contiguous and merge into one
//     span, 02:48:53 → 03:11:23. (The triage note that opened this work said EIGHT; decoding the
//     blob gives nine. The 1350 s it quoted is right — 9 × 150 — so only the count was off.)
// So 1350 of the 14323 "proven-hole" seconds were measurable data the app held under an hour later.

import XCTest
@testable import OpenCircuitKit

final class SleepProvenanceRederivationTests: XCTestCase {

    private func d(_ e: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(e)) }

    // 2026-08-24 Europe/Paris, from the export.
    private var assertedFill: SleepSegment {
        SleepSegment(start: d(1_787_532_317),     // 02:45:17
                     end: d(1_787_546_640),       // 06:44:00
                     stage: .asleepCore, provenance: .asserted)
    }

    /// The nine records that arrived AFTER she saved, as coverage.
    private var grownArchive: MeasuredCoverage {
        MeasuredCoverage(recordDates: [
            d(1_787_532_533), d(1_787_532_683), d(1_787_532_833), d(1_787_532_983),
            d(1_787_533_133), d(1_787_533_283), d(1_787_533_433), d(1_787_533_583),
            d(1_787_533_733),
        ], epochSeconds: 150)
    }

    /// The archive as it stood at 06:50 when she pressed Save: nothing past 02:42:47.
    private var archiveAtSave: MeasuredCoverage {
        MeasuredCoverage(recordDates: [d(1_787_532_167)], epochSeconds: 150)   // 02:42:47
    }

    // MARK: The defect

    func testHerFrozenHoleIsScoredAgainstTheArchiveThatEXISTEDWhenSheSaved() {
        // The precondition, so the fix below cannot pass for having had nothing to fix: at Save time
        // the whole 14323 s span genuinely was a proven hole.
        XCTAssertNil(SleepProvenanceRederivation.upgraded([assertedFill], against: archiveAtSave),
                     "with only the 02:42:47 record in hand there is nothing to upgrade")
        XCTAssertEqual(assertedFill.duration, 14323, "14323 s, exactly as her export carries it")
    }

    func testTheLaterRecordsReclaim1350SecondsOfTheHole() throws {
        let out = try XCTUnwrap(SleepProvenanceRederivation.upgraded([assertedFill],
                                                                     against: grownArchive))
        let reclaimed = out.filter { $0.provenance == .assertedOverMeasured }
        XCTAssertEqual(reclaimed.count, 1, "the nine records are contiguous — one merged span")
        XCTAssertEqual(reclaimed.first?.start, d(1_787_532_533), "02:48:53, the first late record")
        XCTAssertEqual(reclaimed.first?.end, d(1_787_533_883), "03:11:23, 150 s past the last one")
        XCTAssertEqual(reclaimed.reduce(0) { $0 + $1.duration }, 1350,
                       "1350 s of the 'proven hole' was measurable data we held under an hour later")

        XCTAssertEqual(SleepProvenanceRederivation.upgradedAsleepSeconds(before: [assertedFill],
                                                                        after: out),
                       1350, accuracy: 0.5)
    }

    func testTheWEARERSWINDOWIsPreservedToTheSecond() throws {
        let out = try XCTUnwrap(SleepProvenanceRederivation.upgraded([assertedFill],
                                                                     against: grownArchive))
        // Extend-only means the LABELS change and nothing else. Her edges, her stage, her total.
        XCTAssertEqual(out.map(\.start).min(), assertedFill.start, "her asserted onset moved")
        XCTAssertEqual(out.map(\.end).max(), assertedFill.end, "her asserted wake moved")
        XCTAssertTrue(out.allSatisfy { $0.stage == .asleepCore }, "a stage was rewritten")
        XCTAssertEqual(out.reduce(0) { $0 + $1.duration }, assertedFill.duration, accuracy: 0.5,
                       "the pieces must tile the span exactly — no minute added or dropped")
        XCTAssertEqual(SleepStaging.totalAsleep(out), SleepStaging.totalAsleep([assertedFill]),
                       accuracy: 0.5, "the displayed night is untouched (clause 1)")
    }

    func testASecondPassOverTheSameArchiveIsANoOp() throws {
        let once = try XCTUnwrap(SleepProvenanceRederivation.upgraded([assertedFill],
                                                                      against: grownArchive))
        XCTAssertNil(SleepProvenanceRederivation.upgraded(once, against: grownArchive),
                     "nil is what stops every drain re-writing the row and Apple Health")
    }

    // MARK: The direction of travel — this must not be able to resurrect M2

    func testNothingAlreadyMEASUREDCanEverBeDowngraded() {
        // The 403.0 → 0.0 failure (`MeasuredCoverage.trusted(for:)`) is a SHRINK. This pass cannot
        // express one: a coverage that holds nothing for this night leaves every label alone.
        let night: [SleepSegment] = [
            SleepSegment(start: d(1_787_520_167), end: d(1_787_532_287), stage: .asleepCore),
            SleepSegment(start: d(1_787_517_919), end: d(1_787_520_167), stage: .awake,
                         provenance: .assertedOverMeasured),
            SleepSegment(start: d(1_787_532_287), end: d(1_787_532_317), stage: .asleepCore,
                         provenance: .assertedCoverageUnknown),
        ]
        // An archive that has rolled two days past this night.
        let rolled = MeasuredCoverage(recordDates: [d(1_787_720_000), d(1_787_720_150)],
                                      epochSeconds: 150)
        XCTAssertNil(SleepProvenanceRederivation.upgraded(night, against: rolled),
                     "an archive that cannot speak about this night must change nothing")
        XCTAssertNil(SleepProvenanceRederivation.upgraded(night, against: .empty))

        // …and even an archive that DOES cover the night only ever leaves these three as they are:
        // none of them is `.asserted`, so none of them is this pass's business.
        let dense = MeasuredCoverage(intervals: [d(1_787_517_919) ..< d(1_787_546_640)])
        XCTAssertNil(SleepProvenanceRederivation.upgraded(night, against: dense),
                     "only a PROVEN hole is re-scored; a measured or unknown label is left alone")
    }

    func testGroundThatIsSTILLEmptyStaysAsserted() throws {
        // The half that matters for honesty: her 12907 s tail (03:11:23 → 06:44:00) still holds no
        // records, and must still be the wearer's own account afterwards.
        let out = try XCTUnwrap(SleepProvenanceRederivation.upgraded([assertedFill],
                                                                     against: grownArchive))
        let stillAsserted = out.filter { $0.provenance == .asserted }
        XCTAssertEqual(stillAsserted.reduce(0) { $0 + $1.duration }, 14323 - 1350, accuracy: 0.5)
        XCTAssertEqual(stillAsserted.last?.end, d(1_787_546_640), "her 06:44 wake is still asserted")

        let b = SleepProvenanceBreakdown(segments: out)
        XCTAssertEqual(b.assertedAsleep, 12973, accuracy: 0.5)
        XCTAssertEqual(b.measuredAsleep, 1350, accuracy: 0.5)
        XCTAssertEqual(b.displayedAsleep, 14323, accuracy: 0.5, "the card total never moves")
    }

    // MARK: End to end on her real night — re-derive, then publish

    /// HER STORED HYPNOGRAM, VERBATIM from the export's `sleepSessions[0].hypnogram` (21 segments,
    /// timestamps + stage labels + provenance codes; no physiological payload).
    ///
    /// ⚠️ IT CARRIES NO `.inBed` LAYER, because the EXPORT strips one (`ExportEngine`'s
    /// `emittableHypnogram` drops `.inBed`), not because the row lacks it. So do not quote
    /// `coverageFraction` or in-bed minutes off this fixture — the asleep/awake split, which is what
    /// these tests assert, is unaffected.
    private var herStoredNight: [SleepSegment] {
        func s(_ a: Int, _ b: Int, _ stage: SleepStage,
               _ p: SleepProvenance = .measured) -> SleepSegment {
            SleepSegment(start: d(a), end: d(b), stage: stage, provenance: p)
        }
        return [
            s(1_787_517_919, 1_787_520_167, .awake, .assertedOverMeasured),
            s(1_787_520_167, 1_787_521_367, .asleepCore),
            s(1_787_521_367, 1_787_521_667, .asleepREM),
            s(1_787_521_667, 1_787_521_817, .asleepCore),
            s(1_787_521_817, 1_787_523_017, .asleepREM),
            s(1_787_523_017, 1_787_523_317, .asleepCore),
            s(1_787_523_317, 1_787_523_467, .awake),
            s(1_787_523_467, 1_787_523_767, .asleepCore),
            s(1_787_523_767, 1_787_524_217, .asleepDeep),
            s(1_787_524_217, 1_787_524_967, .asleepCore),
            s(1_787_524_967, 1_787_525_117, .awake),
            s(1_787_525_117, 1_787_525_417, .asleepCore),
            s(1_787_525_417, 1_787_525_867, .asleepDeep),
            s(1_787_525_867, 1_787_526_167, .asleepCore),
            s(1_787_526_167, 1_787_526_317, .awake),
            s(1_787_526_317, 1_787_528_717, .asleepCore),
            s(1_787_528_717, 1_787_529_167, .asleepREM),
            s(1_787_529_167, 1_787_529_467, .asleepCore),
            s(1_787_529_467, 1_787_532_287, .asleepDeep),
            s(1_787_532_287, 1_787_532_317, .asleepCore, .assertedOverMeasured),
            s(1_787_532_317, 1_787_546_640, .asleepCore, .asserted),
        ]
    }

    func testTheStoredSplitReproducesHerExportedProvenanceSummary() {
        // If this drifts, every "before" number below is unmoored — so pin it to the export.
        let b = SleepProvenanceBreakdown(segments: herStoredNight)
        XCTAssertEqual(b.measuredAsleep, 11700, accuracy: 0.5, "measuredAsleepSec, as exported")
        XCTAssertEqual(b.assertedAsleep, 14323, accuracy: 0.5, "assertedAsleepSec, as exported")
        XCTAssertEqual(b.displayedAsleep / 60, 434, accuracy: 0.5, "the 434-minute card headline")
    }

    func testAfterRederivationHerNightReachesHealthWholeWithTheAssertedPartTagged() throws {
        let upgraded = try XCTUnwrap(SleepProvenanceRederivation.upgraded(herStoredNight,
                                                                          against: grownArchive))
        let b = SleepProvenanceBreakdown(segments: upgraded)
        XCTAssertEqual(b.measuredAsleep, 13050, accuracy: 0.5, "11700 + the 1350 s reclaimed")
        XCTAssertEqual(b.assertedAsleep, 12973, accuracy: 0.5, "14323 − 1350")
        XCTAssertEqual(b.displayedAsleep / 60, 434, accuracy: 0.5,
                       "her card total is the same before and after — only the SPLIT moved")

        // …and what Apple Health receives: the whole 434 minutes, 216 of them as her own entry.
        let publication = upgraded.healthPublication
        XCTAssertEqual(SleepStaging.totalAsleep(publication.published) / 60, 434, accuracy: 0.5,
                       "the night she corrected reaches Health in full — the report this fixes")
        XCTAssertEqual(SleepStaging.totalAsleep(publication.userEntered) / 60, 216.2, accuracy: 0.2)
        XCTAssertEqual(SleepStaging.totalAsleep(publication.measured) / 60, 217.5, accuracy: 0.2)
        XCTAssertTrue(publication.withheld.isEmpty)
        XCTAssertTrue(upgraded.withheldSpans.isEmpty,
                      "a published span reported as withheld duplicates the night on re-edit")

        // Without the re-derivation the same night publishes the same 434 minutes, but 239 of them
        // are attributed to her rather than 216 — the 1350 s the ring HAD recorded would be filed
        // under her name. That is the whole reason D4 runs before D3.
        let frozen = herStoredNight.healthPublication
        XCTAssertEqual(SleepStaging.totalAsleep(frozen.userEntered) / 60, 238.7, accuracy: 0.2)
    }

    func testAnUnEDITEDNightIsNeverTouched() {
        // `SleepStaging.classify` emits only `.measured`, so the ordinary path has no asserted label
        // for this pass to find. Pinned so a future staging change that starts emitting one is a
        // deliberate act rather than a silent widening of this pass's reach.
        let staged = [SleepSegment(start: d(1_787_520_167), end: d(1_787_532_287), stage: .asleepCore)]
        XCTAssertNil(SleepProvenanceRederivation.upgraded(
            staged, against: MeasuredCoverage(intervals: [d(1_787_520_167) ..< d(1_787_532_287)])))
    }
}

import XCTest
@testable import OpenCircuitKit

/// Regression coverage for the RingConn **Gen 2 Air / FR04 family** raised-floor shape — the sibling
/// of #184's non-expressive shape, and a DIFFERENT failure that the #184 gate correctly refuses.
///
/// On this shape the primary `[10:15]` channel never returns to the `01` baseline: it holds a
/// pedestal whose LEVEL wanders across the night, faster and further than the ~30-min
/// `ActivityPeriod.motionAboveLocalFloor` window can track, so the residual survives de-flooring and
/// the phantom movement swamps `detect()`: every drain ended `noStagedSegments` with zero staged
/// segments while HR/HRV/RR/SpO2 recorded all night. The five sub-samples usually differ (so
/// `motionIsPlaceholder` never fires) and no slot pair keeps a fixed ordering (so
/// `slotOrderConsistency` reports "not an instrumentation template" and `primaryMotionIsDegenerate`
/// returns false). The decoded `[15:23)` magnitudes (#195) are clean on the same records, so
/// `motionSource` gains a third, floor-based rejection reason.
///
/// ⚠️ THE FIRST REVISION'S PREMISE IS REFUTED AND THIS HEADER USED TO CARRY IT. It said the five
/// sub-samples' "spread is far wider than `motionStillThreshold`, so `motionResolvesStillness` never
/// fires". Commit `c4fcb08` disproved that: on the real archive the ring's own motionless epochs are
/// nearly FLAT inside the epoch, the intra-epoch predicate fires on most of them, and the failure
/// lives in the drift BETWEEN epochs — which is why the gate is `primaryChannelIsStillAfterFloor`,
/// not `motionResolvesStillness`. `testWanderingPedestalFixtureMatchesTheFieldStatistics` pins
/// exactly that, and `testFixtureReproducesTheFieldShape` below asserts the REFUTED shape on the
/// first fixture — keep the two apart when reading.
///
/// ⚠️ AND IT IS NOT FR04.011-SPECIFIC. Both Gen 2 Air nights in `desktop/captures/corpus-harness-v1`
/// are FR04.009 and both carry the raised pedestal (`BulkSleep.raisedFloorMinMedianQuietMinimum`
/// holds the census). The firmware string is not the discriminator and no constant here separates
/// the two versions.
///
/// ⚠️ THE CHANNEL SHIPS OFF. `BulkSleep.activityMagnitudeChannelEnabled` is `false`, so every test
/// below that expects `.activityMagnitudes` passes an explicit `magnitudeChannelEnabled: true`
/// policy. `testMagnitudeChannelIsOffByDefault` pins the default.
///
/// All data here is SYNTHETIC — it reproduces the failure SHAPE, not a person's night. No captured
/// health data is committed (CLAUDE.md).
final class FR04RaisedPrimaryFloorTests: XCTestCase {

    private let step = UInt32(BulkRecord.epochSeconds)

    /// The channel under test is behind a kill switch that ships OFF, so every expectation of
    /// `.activityMagnitudes` has to ask for it explicitly.
    private let on = BulkSleep.MotionChannelPolicy(magnitudeChannelEnabled: true)

    /// Deterministic small noise — NOT `random`, so the suite never flakes.
    private var seed: UInt64 = 0x2545_F491_4F6C_DD1D
    private func next(_ bound: Int) -> Int {
        seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
        return Int(seed % UInt64(bound))
    }

    /// Build one 23-byte record. `magnitudes` are the five 12-bit `[15:23)` values, nibble-packed
    /// exactly as `BulkRecord.activityMagnitudes` decodes them, so the fixture exercises the real
    /// bit layout rather than a byte-aligned approximation of it.
    private func record(_ counter: UInt32, hr: UInt8, hrv: UInt8,
                        primary: [UInt8], magnitudes: [Int], sleepVitals: Bool) -> BulkRecord {
        var b = [UInt8](repeating: 0, count: BulkRecord.length)
        b[0] = UInt8(counter >> 24); b[1] = UInt8((counter >> 16) & 0xff)
        b[2] = UInt8((counter >> 8) & 0xff); b[3] = UInt8(counter & 0xff)
        b[4] = hr
        if sleepVitals { b[5] = hrv; b[7] = 120; b[8] = 96 } else { b[8] = 0x12 }
        for i in 0..<5 { b[10 + i] = primary[i] }

        var nibbles = [UInt8](repeating: 0, count: 16)
        for (k, m) in magnitudes.enumerated() {
            let v = max(0, min(4095, m))
            nibbles[k * 3] = UInt8((v >> 8) & 0x0f)
            nibbles[k * 3 + 1] = UInt8((v >> 4) & 0x0f)
            nibbles[k * 3 + 2] = UInt8(v & 0x0f)
        }
        for i in 0..<8 { b[15 + i] = (nibbles[i * 2] << 4) | nibbles[i * 2 + 1] }
        return BulkRecord(b)!
    }

    /// The FR04.011 still shape: a raised, FREELY VARYING primary channel and all-zero magnitudes.
    /// Levels are drawn from the observed clusters (17, 41–53, 71, 84–86) with the occasional `1`,
    /// and each of the five sub-samples is drawn independently — so no slot ordering is phase-locked.
    private func raisedFloorStillEpoch(_ c: UInt32, hr: UInt8 = 52) -> BulkRecord {
        let levels: [UInt8] = [1, 17, 41, 45, 49, 53, 71, 84, 85, 86]
        let primary = (0..<5).map { _ in levels[next(levels.count)] }
        return record(c, hr: hr, hrv: UInt8(38 + next(14)),
                      primary: primary, magnitudes: [0, 0, 0, 0, 0], sleepVitals: true)
    }

    /// A postural turn: the magnitude channel rises to the observed 100–450 band. Below the seam,
    /// so it must read as LIGHT movement, not an awakening.
    private func turnEpoch(_ c: UInt32) -> BulkRecord {
        let levels: [UInt8] = [41, 49, 71, 84, 86]
        let primary = (0..<5).map { _ in levels[next(levels.count)] }
        return record(c, hr: 58, hrv: UInt8(40 + next(10)), primary: primary,
                      magnitudes: [40, 60, 30, 50, 20], sleepVitals: true)
    }

    /// A genuine awakening / the morning: magnitudes well over 1000 in total, on an activity-layout
    /// epoch with an awake heart rate.
    private func awakeEpoch(_ c: UInt32) -> BulkRecord {
        let primary = (0..<5).map { _ in UInt8(120 + next(130)) }
        return record(c, hr: UInt8(84 + next(14)), hrv: 0, primary: primary,
                      magnitudes: [900, 850, 1100, 700, 950], sleepVitals: false)
    }

    /// ~9 h: an awake evening, a long still night with a handful of turns, then the morning.
    private func fr04_011Night() -> [BulkRecord] {
        var c: UInt32 = 0x0c60_0000
        var out: [BulkRecord] = []
        for _ in 0..<12 { out.append(awakeEpoch(c)); c += step }
        for i in 0..<180 {
            // Six brief turns spread through the night.
            out.append(i % 30 == 17 ? turnEpoch(c) : raisedFloorStillEpoch(c)); c += step
        }
        for _ in 0..<12 { out.append(awakeEpoch(c)); c += step }
        return out
    }

    /// The classic Gen-2 night the fix must NOT touch: an `01` baseline that reads still everywhere.
    private func baselineNight() -> [BulkRecord] {
        var c: UInt32 = 0x0c60_0000
        var out: [BulkRecord] = []
        for _ in 0..<12 { out.append(awakeEpoch(c)); c += step }
        for i in 0..<180 {
            let still = record(c, hr: 52, hrv: 45, primary: [1, 1, 1, 1, 1],
                               magnitudes: [0, 0, 0, 0, 0], sleepVitals: true)
            out.append(i % 30 == 17 ? turnEpoch(c) : still); c += step
        }
        for _ in 0..<12 { out.append(awakeEpoch(c)); c += step }
        return out
    }

    // MARK: - (a) the run now selects the magnitude channel

    func testFixtureReproducesTheFieldShape() {
        let worn = fr04_011Night().filter { $0.layout != .idle }
        let night = worn.filter(\.activityMagnitudesAreZero)

        XCTAssertGreaterThanOrEqual(BulkSleep.medianQuietMinimum(night), 16,
                                    "fixture sanity: the primary floor sits off the `01` baseline")
        XCTAssertLessThan(Double(night.filter(\.motionIsPlaceholder).count) / Double(night.count), 0.20,
                          "fixture sanity: the five sub-samples usually DIFFER, so the constant-filler "
                          + "branch cannot fire")
        XCTAssertLessThan(BulkSleep.slotOrderConsistency(night),
                          BulkSleep.degenerateMinSlotOrderFraction,
                          "fixture sanity: this is NOT the #184 fixed template — the ordering is free, "
                          + "which is exactly why `primaryMotionIsDegenerate` refuses it")
        XCTAssertFalse(BulkSleep.primaryMotionIsDegenerate(worn),
                       "the #184 gate must keep refusing this shape; that is the bug being fixed")
    }

    func testRaisedFloorSelectsTheDecodedMagnitudeChannel() {
        let recs = fr04_011Night()
        XCTAssertTrue(BulkSleep.primaryFloorIsRaised(recs.filter { $0.layout != .idle }))
        XCTAssertEqual(BulkSleep.motionSource(recs, policy: on), .activityMagnitudes)
    }

    /// The `0 / 1 / 16` alphabet the tail fallback emits, on the decoded channel: still → 0,
    /// a turn → 1 (light), the morning → 16 (active).
    func testMagnitudeChannelMapsStillTurnAndWakeOntoTheSharedScale() {
        let recs = fr04_011Night()
        let mags = BulkSleep.motionMagnitudes(from: recs, policy: on)

        XCTAssertEqual(mags[0], 16, "the morning/evening epochs exceed the seam")
        XCTAssertEqual(mags[12 + 17], 1, "a 200-unit postural turn is light movement, not an awakening")
        XCTAssertEqual(mags[12 + 18], 0, "a still epoch is the channel's own zero")
    }

    // MARK: - (b) the night stages

    func testRaisedFloorNightStagesWithPlausibleOnsetAndEfficiency() throws {
        let recs = fr04_011Night()

        let segments = BulkSleep.stagedSegments(
            from: BulkSleep.latestNightRecords(from: recs, motionPolicy: on), motionPolicy: on)
        XCTAssertFalse(segments.isEmpty,
                       "the reported failure: every drain ended `noStagedSegments` with 0 staged "
                       + "segments on an archive whose vitals decoded all night")

        let block = try XCTUnwrap(BulkSleep.mainSleep(from: recs, motionPolicy: on))
        let firstStill = recs[12].date(epoch: Command.syncEpoch)
        XCTAssertLessThan(abs(block.start.timeIntervalSince(firstStill)), 45 * 60,
                          "onset lands within minutes of the still stretch, not hours into it")
        XCTAssertGreaterThan(block.duration, 5 * 3600)

        let minutes = SleepStaging.summary(SleepStaging.classify(from: recs, motionPolicy: on)).minutes
        XCTAssertGreaterThan(minutes.inBed, 0)
        let efficiency = Double(minutes.asleep) / Double(minutes.inBed)
        XCTAssertGreaterThan(efficiency, 0.70, "a night of measured stillness is not mostly awake")
        XCTAssertLessThanOrEqual(efficiency, 1.0)
    }

    // MARK: - (c) the classic baseline night is untouched

    func testClassicBaselineNightKeepsThePrimaryChannel() {
        let recs = baselineNight()
        XCTAssertFalse(BulkSleep.primaryFloorIsRaised(recs.filter { $0.layout != .idle }),
                       "an `01` baseline resolves stillness everywhere, so the shared "
                       + "`degenerateMaxQuietStillFraction` conjunct rejects it before the floor test")
        XCTAssertEqual(BulkSleep.motionSource(recs), .primary)
        XCTAssertFalse(BulkSleep.stagedSegments(from: BulkSleep.latestNightRecords(from: recs)).isEmpty,
                       "and it still stages, off the primary channel, exactly as before")
    }

    // MARK: - the two new gates, in isolation

    /// A raised floor is NOT enough on its own: if the magnitude channel cannot say "nothing moved"
    /// on a real share of the run, swapping onto it trades one unusable channel for another.
    func testRaisedFloorWithoutAZeroMagnitudePopulationStaysOnPrimary() {
        var c: UInt32 = 0x0c60_0000
        let recs = (0..<200).map { _ -> BulkRecord in
            defer { c += step }
            let levels: [UInt8] = [41, 49, 71, 84, 86]
            return record(c, hr: 52, hrv: 45,
                          primary: (0..<5).map { _ in levels[next(levels.count)] },
                          magnitudes: [7, 3, 11, 5, 9], sleepVitals: true)
        }
        XCTAssertFalse(BulkSleep.primaryFloorIsRaised(recs))
        XCTAssertEqual(BulkSleep.motionSource(recs), .primary)
    }

    /// And a clean magnitude channel is not enough either: a primary channel whose floor is at or
    /// near the baseline is doing its job, however much it varies above it.
    func testCleanMagnitudesWithABaselineFloorStayOnPrimary() {
        var c: UInt32 = 0x0c60_0000
        let recs = (0..<200).map { i -> BulkRecord in
            defer { c += step }
            // Floor pinned at 1; the other four sub-samples vary widely above it. The baseline slot
            // ROTATES, or slot 0 would be the minimum on every epoch — a phase-locked ordering that
            // the #184 template gate would (rightly) claim first, leaving this test asserting
            // nothing about the floor.
            let base: [UInt8] = [1] + (0..<4).map { _ in UInt8(1 + next(90)) }
            let primary = (0..<5).map { base[($0 + i) % 5] }
            return record(c, hr: 52, hrv: 45, primary: primary,
                          magnitudes: i % 25 == 0 ? [40, 60, 30, 50, 20] : [0, 0, 0, 0, 0],
                          sleepVitals: true)
        }
        XCTAssertEqual(BulkSleep.medianQuietMinimum(recs.filter(\.activityMagnitudesAreZero)), 1)
        XCTAssertFalse(BulkSleep.primaryFloorIsRaised(recs))
        XCTAssertEqual(BulkSleep.motionSource(recs), .primary)
    }

    /// Sub-hour runs are never judged, matching `degenerateMinQuietEpochs`: a night arriving as
    /// several short fragments keeps today's behaviour instead of flipping verdict between scopes.
    func testShortRunIsNeverJudged() {
        var c: UInt32 = 0x0c60_0000
        let recs = (0..<20).map { _ -> BulkRecord in
            defer { c += step }
            return raisedFloorStillEpoch(c)
        }
        XCTAssertFalse(BulkSleep.primaryFloorIsRaised(recs))
        XCTAssertEqual(BulkSleep.motionSource(recs), .primary)
    }

    // MARK: - the shape the FIELD archive actually has

    /// 🟢 THE SHIPPED FIXTURE ABOVE IS NOT THE FIELD SHAPE, and the difference is the whole bug.
    /// `raisedFloorStillEpoch` draws all five sub-samples INDEPENDENTLY, so a "still" epoch spans
    /// 1…86 within itself. On the real FR04.011 archive (715 worn epochs, one night plus the
    /// preceding day) the ring's OWN motionless epochs are nearly FLAT inside the epoch — median
    /// intra-epoch spread **1 count**, p90 **6** — so `motionResolvesStillness` fires on **78 %** of
    /// them and `primaryFloorIsRaised` rejected the real archive while accepting the fixture.
    ///
    /// What the field channel really does is hold a flat pedestal whose LEVEL wanders (per-epoch
    /// minimum p10 1 / p50 40 / p90 93 across the night), far faster and further than the ~30-min
    /// `motionAboveLocalFloor` window can track. This fixture reproduces THAT: flat within an epoch,
    /// wandering between epochs. It must select the magnitude channel, and it must do so at BOTH the
    /// scopes production evaluates `motionSource` at — the night slice and the whole archive union.
    private func wanderingPedestalNight(includeDay: Bool) -> [BulkRecord] {
        var c: UInt32 = 0x0c60_0000
        var out: [BulkRecord] = []
        if includeDay {
            // ~14 h of an ordinary awake day, which is what `latestNightRecords` hands `motionSource`
            // out of the 30 h archive union. It must not change the verdict.
            for _ in 0..<336 { out.append(awakeEpoch(c)); c += step }
        }
        for _ in 0..<12 { out.append(awakeEpoch(c)); c += step }
        // The observed FR04.011 plateau levels (the commit's own clusters), held for a few epochs
        // at a time and then stepped — flat inside an epoch, wandering between them.
        let plateaus = [1, 17, 41, 45, 49, 53, 71, 84, 85, 86]
        var level = 45
        for i in 0..<180 {
            if i % 4 == 0 { level = plateaus[next(plateaus.count)] }
            let primary = (0..<5).map { _ in UInt8(max(0, level + next(3) - 1)) }
            let still = record(c, hr: 52, hrv: UInt8(38 + next(14)),
                               primary: primary, magnitudes: [0, 0, 0, 0, 0], sleepVitals: true)
            out.append(i % 30 == 17 ? turnEpoch(c) : still); c += step
        }
        for _ in 0..<12 { out.append(awakeEpoch(c)); c += step }
        return out
    }

    func testWanderingPedestalFixtureMatchesTheFieldStatistics() {
        let worn = wanderingPedestalNight(includeDay: false).filter { $0.layout != .idle }
        let quiet = worn.filter(\.activityMagnitudesAreZero)
        let stillShare = Double(quiet.filter(\.motionResolvesStillness).count) / Double(quiet.count)
        XCTAssertGreaterThan(stillShare, BulkSleep.degenerateMaxQuietStillFraction,
                             "fixture sanity: like the field archive, the ring's motionless epochs are "
                             + "FLAT inside the epoch — so the intra-epoch proxy the branch shipped with "
                             + "says `still` and would reject this channel outright")
        XCTAssertGreaterThanOrEqual(BulkSleep.medianQuietMinimum(quiet), 16)
        XCTAssertFalse(BulkSleep.primaryMotionIsDegenerate(worn))
    }

    func testWanderingPedestalSelectsTheMagnitudeChannelAtEveryScope() {
        for includeDay in [false, true] {
            let recs = wanderingPedestalNight(includeDay: includeDay)
            XCTAssertTrue(BulkSleep.primaryFloorIsRaised(recs.filter { $0.layout != .idle }),
                          "includeDay=\(includeDay): the de-floored stillness conjunct must see through "
                          + "a flat-but-wandering pedestal")
            XCTAssertEqual(BulkSleep.motionSource(recs, policy: on), .activityMagnitudes,
                           "includeDay=\(includeDay): the verdict must not depend on how much daytime "
                           + "happens to be in the archive union — that is the scope-dependence the "
                           + "removed share-of-worn conjunct introduced")
        }
    }

    func testWanderingPedestalNightStages() throws {
        let recs = wanderingPedestalNight(includeDay: true)
        let segments = BulkSleep.stagedSegments(
            from: BulkSleep.latestNightRecords(from: recs, motionPolicy: on), motionPolicy: on)
        XCTAssertFalse(segments.isEmpty,
                       "the reported failure: `noStagedSegments` on every drain while HR/HRV/RR/SpO2 "
                       + "decoded all night")
        let block = try XCTUnwrap(BulkSleep.mainSleep(from: recs, motionPolicy: on))
        XCTAssertGreaterThan(block.duration, 5 * 3600)
    }

    // MARK: - the kill switch

    /// THE DEFAULT IS THE PRE-#211 BEHAVIOUR. #211 shipped this channel unconditionally; it is now
    /// behind `activityMagnitudeChannelEnabled`, which is `false`. On the very archive shape the
    /// branch was written for, the shipped default must still choose `.primary` and must still
    /// produce exactly what the primary channel produced — otherwise "default off" is a claim, not
    /// a fact. (The corpus-wide version of this is the `baseline.tsv` sha256 quoted on the flag.)
    func testMagnitudeChannelIsOffByDefault() {
        XCTAssertFalse(BulkSleep.activityMagnitudeChannelEnabled,
                       "the channel must ship OFF until a LABELLED Gen 2 Air night exists to "
                       + "adjudicate it — see the flag's doc comment")
        XCTAssertEqual(BulkSleep.MotionChannelPolicy.default.magnitudeChannelEnabled, false)

        for recs in [fr04_011Night(), wanderingPedestalNight(includeDay: true)] {
            XCTAssertEqual(BulkSleep.motionSource(recs), .primary,
                           "the raised-floor shape must stay on the primary channel at the default")
            // Byte-identity, not just the verdict: the magnitudes the detector and the stager
            // consume have to be the primary channel's, sample for sample.
            XCTAssertNil(BulkSleep.secondaryChannelMagnitudes(recs),
                         "a `nil` secondary is what `motionTimeline` uses to fall back to raw "
                         + "`[10:15]`; anything else means the default is reading another channel")
        }
    }

    // MARK: - the Gen-3 drifting plateau this branch must NOT claim

    /// 🟢 THE GAP THIS FILLS. `Gen3MotionFloorTests` cannot cover the exclusion: every fixture there
    /// writes all five motion bytes EQUAL, so those runs are `motionIsPlaceholder` on every epoch,
    /// short-circuit at `constantFiller`, and never reach the raised-floor branch at all. Nothing
    /// pinned that a Gen-3-shaped NON-constant drifting plateau stays on `.primary`.
    ///
    /// The shape (🟢 FR05.008 capture 2026-06-23, via `Gen3MotionFloorTests`): a still Gen-3 ring
    /// idles at ~15–16 and STEPS to ~24 and ~39 as sleeping posture changes. Here each plateau is
    /// held for 40 epochs (100 min) — long relative to the 30-min `motionAboveLocalFloor` window, so
    /// the floor tracks it and the residual de-floors to ~0 — and the five sub-samples differ by at
    /// most one count, so the run is not a constant filler.
    ///
    /// It must stay on `.primary`, and the interesting part is WHY: its `medianQuietMinimum` clears
    /// `raisedFloorMinMedianQuietMinimum` outright, so the floor test alone would accept it. What
    /// refuses it is the de-floored stillness conjunct — the same conjunct that refuses
    /// `testerB-2026-08-18` in the real corpus. That is the invariant worth pinning: a floor being
    /// HIGH is not the failure; a floor that WANDERS is.
    private func gen3DriftingPlateauNight() -> [BulkRecord] {
        var c: UInt32 = 0x0c60_0000
        var out: [BulkRecord] = []
        for _ in 0..<12 { out.append(awakeEpoch(c)); c += step }
        var i = 0
        for level in [16, 16, 24, 39, 39] {          // 5 x 40 epochs = 200 epochs ~ 8.3 h
            for _ in 0..<40 {
                // Two distinct values per epoch (so never a constant run), one count apart (so the
                // plateau de-floors to still), with the parity rotating so no slot ordering is
                // phase-locked.
                let primary = (0..<5).map { k in UInt8(level + ((k + i) % 2)) }
                out.append(record(c, hr: 52, hrv: UInt8(38 + next(14)), primary: primary,
                                  magnitudes: [0, 0, 0, 0, 0], sleepVitals: true))
                c += step; i += 1
            }
        }
        for _ in 0..<12 { out.append(awakeEpoch(c)); c += step }
        return out
    }

    func testGen3DriftingPlateauStaysOnPrimaryEvenWithTheChannelEnabled() {
        let recs = gen3DriftingPlateauNight()
        let worn = recs.filter { $0.layout != .idle }
        let quiet = worn.filter(\.activityMagnitudesAreZero)

        // Fixture sanity: this is NOT the constant-filler shape, so it really does reach the branch.
        XCTAssertFalse(worn.allSatisfy(\.motionIsPlaceholder),
                       "fixture sanity: an all-equal run short-circuits at `constantFiller` and "
                       + "never reaches the raised-floor branch — that is exactly the hole "
                       + "`Gen3MotionFloorTests` leaves")
        XCTAssertFalse(BulkSleep.primaryMotionIsDegenerate(worn))
        XCTAssertGreaterThanOrEqual(quiet.count, BulkSleep.degenerateMinQuietEpochs,
                                    "fixture sanity: the quorum must be met, or the branch declines "
                                    + "for the wrong reason and this test asserts nothing")
        XCTAssertGreaterThanOrEqual(BulkSleep.medianQuietMinimum(quiet),
                                    BulkSleep.raisedFloorMinMedianQuietMinimum,
                                    "fixture sanity: the floor test on its own ACCEPTS a Gen-3 "
                                    + "plateau — so the exclusion below is the stillness conjunct's "
                                    + "doing, which is the point of the test")

        let stillAfterFloor = BulkSleep.primaryChannelIsStillAfterFloor(worn)
        let stillShare = Double(worn.indices.filter { worn[$0].activityMagnitudesAreZero
                                                      && stillAfterFloor[$0] }.count)
            / Double(quiet.count)
        XCTAssertGreaterThanOrEqual(stillShare, BulkSleep.degenerateMaxQuietStillFraction,
                                    "a plateau held longer than the floor window de-floors to still")
        XCTAssertFalse(BulkSleep.primaryFloorIsRaised(worn))
        XCTAssertEqual(BulkSleep.motionSource(recs, policy: on), .primary,
                       "a drifting-but-trackable Gen-3 floor is a WORKING channel; claiming it "
                       + "would swap a good channel for a coarser one on every Gen-3 night")
        XCTAssertEqual(BulkSleep.motionSource(recs), .primary)
    }

    /// The nibble packing the fixture writes is the one `activityMagnitudes` reads. If this ever
    /// drifts, every magnitude assertion above becomes vacuous.
    func testFixtureNibblePackingRoundTrips() {
        let r = record(0x0c60_0000, hr: 60, hrv: 45, primary: [1, 1, 1, 1, 1],
                       magnitudes: [0, 1, 4095, 1302, 97], sleepVitals: true)
        XCTAssertEqual(r.activityMagnitudes, [0, 1, 4095, 1302, 97])
        XCTAssertFalse(r.activityMagnitudesAreZero)
    }
}

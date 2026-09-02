import XCTest
@testable import OpenCircuitKit

/// Regression coverage for the RingConn Gen 2 Air on FW **FR04.011** — the sibling of #184's
/// FR04.009 shape, and a DIFFERENT failure that the #184 gate correctly refuses.
///
/// On this firmware the primary `[10:15]` channel never returns to the `01` baseline: its counts
/// wander in the 40–90 band with the occasional `1`, and — unlike FR04.009 — they wander FREELY.
/// The five sub-samples of one epoch usually differ (so `motionIsPlaceholder` never fires), their
/// spread is far wider than `motionStillThreshold` (so `motionResolvesStillness` never fires), and
/// no slot pair keeps a fixed ordering (so `slotOrderConsistency` correctly reports "this is not an
/// instrumentation template" and `primaryMotionIsDegenerate` returns false). The run therefore kept
/// `.primary`, whose permanent pedestal of phantom movement swamps `detect()`: every drain ended
/// `noStagedSegments` with zero staged segments while HR/HRV/RR/SpO2 recorded all night.
///
/// The decoded `[15:23)` magnitudes (#195) are clean on the same records — exactly 0 for the median
/// night epoch — so the fix widens `motionSource` with a third, floor-based rejection reason.
///
/// All data here is SYNTHETIC — it reproduces the failure SHAPE, not a person's night. No captured
/// health data is committed (CLAUDE.md).
final class FR04RaisedPrimaryFloorTests: XCTestCase {

    private let step = UInt32(BulkRecord.epochSeconds)

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
        XCTAssertEqual(BulkSleep.motionSource(recs), .activityMagnitudes)
    }

    /// The `0 / 1 / 16` alphabet the tail fallback emits, on the decoded channel: still → 0,
    /// a turn → 1 (light), the morning → 16 (active).
    func testMagnitudeChannelMapsStillTurnAndWakeOntoTheSharedScale() {
        let recs = fr04_011Night()
        let mags = BulkSleep.motionMagnitudes(from: recs)

        XCTAssertEqual(mags[0], 16, "the morning/evening epochs exceed the seam")
        XCTAssertEqual(mags[12 + 17], 1, "a 200-unit postural turn is light movement, not an awakening")
        XCTAssertEqual(mags[12 + 18], 0, "a still epoch is the channel's own zero")
    }

    // MARK: - (b) the night stages

    func testRaisedFloorNightStagesWithPlausibleOnsetAndEfficiency() throws {
        let recs = fr04_011Night()

        let segments = BulkSleep.stagedSegments(from: BulkSleep.latestNightRecords(from: recs))
        XCTAssertFalse(segments.isEmpty,
                       "the reported failure: every drain ended `noStagedSegments` with 0 staged "
                       + "segments on an archive whose vitals decoded all night")

        let block = try XCTUnwrap(BulkSleep.mainSleep(from: recs))
        let firstStill = recs[12].date(epoch: Command.syncEpoch)
        XCTAssertLessThan(abs(block.start.timeIntervalSince(firstStill)), 45 * 60,
                          "onset lands within minutes of the still stretch, not hours into it")
        XCTAssertGreaterThan(block.duration, 5 * 3600)

        let minutes = SleepStaging.summary(SleepStaging.classify(from: recs)).minutes
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

    /// The nibble packing the fixture writes is the one `activityMagnitudes` reads. If this ever
    /// drifts, every magnitude assertion above becomes vacuous.
    func testFixtureNibblePackingRoundTrips() {
        let r = record(0x0c60_0000, hr: 60, hrv: 45, primary: [1, 1, 1, 1, 1],
                       magnitudes: [0, 1, 4095, 1302, 97], sleepVitals: true)
        XCTAssertEqual(r.activityMagnitudes, [0, 1, 4095, 1302, 97])
        XCTAssertFalse(r.activityMagnitudesAreZero)
    }
}

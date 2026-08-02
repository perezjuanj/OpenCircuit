import XCTest
@testable import OpenCircuitKit

/// Regression coverage for #184 — RingConn Gen 2 Air, FW FR04.009: the `[10:15]` motion channel
/// idles at 25–45 with a FIXED two-level intra-epoch step (sub-sample slots 0–1 ≈ 27.6, slots 2–4
/// ≈ 34.9 on EVERY epoch) plus ±2 per-slot noise. `motionAboveLocalFloor`'s rolling floor subtracts
/// a per-window LEVEL, so it cancels a flat plateau at ANY level (Gen-2 `01`, Gen-3 `0f`, Gen-3's
/// drifting `16→24→39`) but a step INSIDE one epoch survives it. Only 26 % of sub-samples read
/// still against the 70 % `detect()` requires → no sleep block → no summary → blank card, on a
/// COMPLETE archive with perfectly decoding vitals. The `[15:20]` intensity tail is a clean
/// stillness signal on this ring, so the fix widens `motionSource` to fall through to it.
///
/// All data here is SYNTHETIC — it reproduces the failure SHAPE, not a person's night. No captured
/// health data is committed (CLAUDE.md).
final class FR04DegeneratePrimaryMotionTests: XCTestCase {

    private let step = UInt32(BulkRecord.epochSeconds)

    /// Deterministic small noise — NOT `random`, so the suite never flakes.
    private var seed: UInt64 = 0x9E3779B97F4A7C15
    private func jitter(_ span: Int) -> Int {
        seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
        return Int(seed % UInt64(2 * span + 1)) - span
    }

    private func record(_ counter: UInt32, hr: UInt8,
                        primary: [UInt8], tail: [UInt8],
                        sleepVitals: Bool) -> BulkRecord {
        var b = [UInt8](repeating: 0, count: BulkRecord.length)
        b[0] = UInt8(counter >> 24); b[1] = UInt8((counter >> 16) & 0xff)
        b[2] = UInt8((counter >> 8) & 0xff); b[3] = UInt8(counter & 0xff)
        b[4] = hr
        if sleepVitals { b[5] = 45; b[7] = 120; b[8] = 96 } else { b[8] = 0x12 }
        for i in 0..<5 { b[10 + i] = primary[i]; b[15 + i] = tail[i] }
        return BulkRecord(b)!
    }

    /// The FR04 still shape: a fixed two-level step, ±2 noise, and a ZERO intensity tail.
    private func steppedStillEpoch(_ c: UInt32, hr: UInt8 = 58) -> BulkRecord {
        let base = [27, 27, 34, 34, 35]
        return record(c, hr: hr,
                      primary: base.map { UInt8(max(0, $0 + jitter(2))) },
                      tail: [0, 0, 0, 0, 0], sleepVitals: true)
    }

    /// An awake epoch: large varying primary counts AND a non-zero tail (the ring says it moved).
    private func awakeEpoch(_ c: UInt32, i: Int) -> BulkRecord {
        let shapes: [[UInt8]] = [[103, 98, 206, 229, 206], [224, 242, 221, 230, 211],
                                 [255, 254, 254, 247, 255], [49, 54, 35, 55, 37]]
        let tails: [[UInt8]] = [[80, 90, 120, 60, 70], [140, 130, 150, 120, 110],
                                [200, 190, 210, 180, 170], [40, 55, 35, 60, 45]]
        return record(c, hr: 92, primary: shapes[i % 4], tail: tails[i % 4], sleepVitals: false)
    }

    /// 12 awake epochs, ~150 stepped-still epochs (6.25 h), 12 awake epochs.
    private func fr04Night(stillEpochs: Int = 150) -> [BulkRecord] {
        var c: UInt32 = 0x0c50_0000
        var out: [BulkRecord] = []
        for i in 0..<12 { out.append(awakeEpoch(c, i: i)); c += step }
        for _ in 0..<stillEpochs { out.append(steppedStillEpoch(c)); c += step }
        for i in 0..<12 { out.append(awakeEpoch(c, i: i)); c += step }
        return out
    }

    /// A night with a CONSTANT primary run at `level` (Gen 2 `1`, Gen 3 `15`) and the same tails.
    private func flatNight(level: UInt8) -> [BulkRecord] {
        var c: UInt32 = 0x0c50_0000
        var out: [BulkRecord] = []
        for i in 0..<12 { out.append(awakeEpoch(c, i: i)); c += step }
        for _ in 0..<150 {
            out.append(record(c, hr: 58, primary: [UInt8](repeating: level, count: 5),
                              tail: [0, 0, 0, 0, 0], sleepVitals: true)); c += step
        }
        for i in 0..<12 { out.append(awakeEpoch(c, i: i)); c += step }
        return out
    }

    /// Gen-3's drifting floor: constant WITHIN each epoch, stepping BETWEEN plateaus.
    private func driftingNight() -> [BulkRecord] {
        var c: UInt32 = 0x0c50_0000
        var out: [BulkRecord] = []
        for i in 0..<12 { out.append(awakeEpoch(c, i: i)); c += step }
        for level: UInt8 in [16, 24, 39] {
            for _ in 0..<50 {
                out.append(record(c, hr: 58, primary: [UInt8](repeating: level, count: 5),
                                  tail: [0, 0, 0, 0, 0], sleepVitals: true)); c += step
            }
        }
        for i in 0..<12 { out.append(awakeEpoch(c, i: i)); c += step }
        return out
    }

    // MARK: - The regression itself

    func testFixedIntraEpochStepIsJudgedNonExpressive() {
        let recs = fr04Night()
        let worn = recs.filter { $0.layout != .idle }
        XCTAssertTrue(BulkSleep.primaryMotionIsDegenerate(worn),
                      "a fixed intra-epoch step that never resolves stillness is a non-expressive channel")
        XCTAssertEqual(BulkSleep.motionSource(recs), .intensityTail(degenerate: true))
    }

    func testFixedIntraEpochStepStagesANight() throws {
        let recs = fr04Night()
        let block = try XCTUnwrap(BulkSleep.mainSleep(from: recs),
                                  "#184: a complete FR04 archive must not stage zero sleep (blank card)")
        XCTAssertGreaterThan(block.duration, 5 * 3600, "the ~6.25 h still block is recovered")
        XCTAssertFalse(BulkSleep.stagedSegments(from: BulkSleep.latestNightRecords(from: recs)).isEmpty)
        XCTAssertFalse(BulkSleep.sleepSegments(from: recs).isEmpty)
    }

    /// The primary channel must still WIN when it can express stillness — the awake epochs here
    /// vary hugely, so `motionResolvesStillness` holds on ~none of them, but their tails are
    /// non-zero, so they are not "quiet" and the predicate never judges them.
    func testAllMovingRunIsNotJudgedNonExpressive() {
        var c: UInt32 = 0x0c50_0000
        var out: [BulkRecord] = []
        for i in 0..<200 { out.append(awakeEpoch(c, i: i)); c += step }
        XCTAssertFalse(BulkSleep.primaryMotionIsDegenerate(out))
        XCTAssertEqual(BulkSleep.motionSource(out), .primary)
        XCTAssertNil(BulkSleep.mainSleep(from: out), "a moving run is never a night")
    }

    // MARK: - Byte-identity guards (Gen 2 / Gen 3 must take the untouched path)

    func testGen2FlatFloorIsNotJudgedNonExpressive() {
        let recs = flatNight(level: 1)
        XCTAssertFalse(BulkSleep.primaryMotionIsDegenerate(recs.filter { $0.layout != .idle }))
        XCTAssertEqual(BulkSleep.motionSource(recs), .primary,
                       "a Gen-2 flat `01` night keeps the primary channel")
    }

    func testGen3FlatFloorIsNotJudgedNonExpressive() {
        let recs = flatNight(level: 15)
        XCTAssertFalse(BulkSleep.primaryMotionIsDegenerate(recs.filter { $0.layout != .idle }))
        XCTAssertEqual(BulkSleep.motionSource(recs), .primary)
    }

    func testGen3DriftingFloorIsNotJudgedNonExpressive() {
        let recs = driftingNight()
        XCTAssertFalse(BulkSleep.primaryMotionIsDegenerate(recs.filter { $0.layout != .idle }),
                       "the Gen-3 drift is BETWEEN epochs; each epoch is still a constant run")
        XCTAssertEqual(BulkSleep.motionSource(recs), .primary)
    }

    /// The constant-filler branch must keep `degenerate: false`, i.e. the untouched 0.80 quantile.
    func testConstantFillerBranchStaysNonDegenerate() {
        var c: UInt32 = 0x0c4f_0000
        var out: [BulkRecord] = []
        for i in 0..<120 {
            let tail: [UInt8] = (i == 40) ? [0, 0, 32, 0, 0] : (i == 41 ? [0, 16, 32, 0, 0] : [0, 0, 0, 0, 0])
            out.append(record(c, hr: 55, primary: [1, 1, 1, 1, 1], tail: tail, sleepVitals: true)); c += step
        }
        XCTAssertEqual(BulkSleep.motionSource(out), .intensityTail(degenerate: false),
                       "the 2026-07-12 constant-filler shape keeps the p80 seam, byte for byte")
    }

    // MARK: - The two gates, in isolation

    func testSlotOrderConsistency() {
        var c: UInt32 = 0x0c50_0000
        let fixedStep = (0..<40).map { _ -> BulkRecord in
            defer { c += step }
            return steppedStillEpoch(c)
        }
        XCTAssertGreaterThanOrEqual(BulkSleep.slotOrderConsistency(fixedStep),
                                    BulkSleep.degenerateMinSlotOrderFraction)

        let flat = (0..<40).map { _ -> BulkRecord in
            defer { c += step }
            return record(c, hr: 58, primary: [15, 15, 15, 15, 15], tail: [0, 0, 0, 0, 0], sleepVitals: true)
        }
        XCTAssertEqual(BulkSleep.slotOrderConsistency(flat), 0, accuracy: 1e-9,
                       "a constant run ties every comparison")

        let noisy = (0..<200).map { _ -> BulkRecord in
            defer { c += step }
            return record(c, hr: 58,
                          primary: (0..<5).map { _ in UInt8(30 + jitter(2)) },
                          tail: [0, 0, 0, 0, 0], sleepVitals: true)
        }
        XCTAssertLessThan(BulkSleep.slotOrderConsistency(noisy),
                          BulkSleep.degenerateMinSlotOrderFraction,
                          "independent per-slot noise has no phase-locked ordering")
    }

    /// Sub-hour runs are never judged: `degenerateMinQuietEpochs` documents that a night arriving as
    /// several short fragments keeps today's (degraded, primary-channel) behaviour rather than
    /// flipping verdict between scopes.
    func testShortRunIsNeverJudged() {
        let recs = fr04Night(stillEpochs: 20)
        XCTAssertFalse(BulkSleep.primaryMotionIsDegenerate(recs.filter { $0.layout != .idle }))
        XCTAssertEqual(BulkSleep.motionSource(recs), .primary)
    }

    /// The unchanged "at least two non-zero tail epochs" conjunct still decides: a run with the
    /// degenerate SHAPE but no tail movement at all keeps the primary channel.
    func testDegenerateShapeWithNoTailMovementStaysOnPrimary() {
        var c: UInt32 = 0x0c50_0000
        let recs = (0..<150).map { _ -> BulkRecord in
            defer { c += step }
            return steppedStillEpoch(c)
        }
        XCTAssertTrue(BulkSleep.primaryMotionIsDegenerate(recs))
        XCTAssertEqual(BulkSleep.motionSource(recs), .primary)
    }

    // MARK: - The Otsu seam (degenerate branch only)

    /// The FR04 tail pool is a broad ramp, not a clean two-lump histogram, because the run contains
    /// its whole awake evening. The 0.80 quantile then sits INSIDE the awake mass; the Otsu seam does
    /// not. 🟢 on the tester's real archive: p80 = 549, Otsu = 370 (184 positive epochs).
    func testOtsuSeamSitsBelowTheQuantileOnABroadPool() {
        let ramp = (0..<184).map { 1 + (899 * $0) / 183 }
        let quantile = ramp[Int((Double(ramp.count - 1) * 0.80).rounded())]
        XCTAssertLessThan(BulkSleep.otsuIntensityCut(ramp), quantile)
    }

    func testOtsuNeverSplitsATie() {
        XCTAssertEqual(BulkSleep.otsuIntensityCut([64, 64]), 64)
        XCTAssertEqual(BulkSleep.otsuIntensityCut([7]), 7)
    }

    /// The behavioural reason the seam matters: a sedentary-but-AWAKE evening on this ring reads
    /// still on the (non-expressive) primary channel and only the tail can reject it. With the 0.80
    /// quantile those epochs map to `1`, which is BELOW `motionStillThreshold`, and detection swallows
    /// the evening into the night. Onset must land after it.
    func testSedentaryEveningIsNotSwallowedIntoTheNight() throws {
        var c: UInt32 = 0x0c50_0000
        var out: [BulkRecord] = []
        for i in 0..<8 { out.append(awakeEpoch(c, i: i)); c += step }
        let eveningStart = out.last!.date(epoch: Command.syncEpoch)
        // 60 epochs (2.5 h) of sedentary evening: FR04 still-shaped primary, but a MODERATE non-zero
        // tail — the ring says movement happened.
        for i in 0..<60 {
            let level = UInt8(60 + (i * 7) % 90)
            out.append(record(c, hr: 84,
                              primary: [27, 27, 34, 34, 35].map { UInt8(max(0, $0 + jitter(2))) },
                              tail: [level, level, level, level, level], sleepVitals: false))
            c += step
        }
        let nightStart = c
        for _ in 0..<150 { out.append(steppedStillEpoch(c)); c += step }
        for i in 0..<8 { out.append(awakeEpoch(c, i: i)); c += step }

        let block = try XCTUnwrap(BulkSleep.mainSleep(from: out))
        let nightStartDate = Date(timeIntervalSince1970: Double(Int(nightStart) + Command.syncEpoch))
        XCTAssertGreaterThan(block.start.timeIntervalSince(eveningStart), 60 * 60,
                             "onset must not sit in the awake evening")
        XCTAssertLessThan(abs(block.start.timeIntervalSince(nightStartDate)), 60 * 60,
                          "onset lands at the start of the genuinely still stretch")
    }
}

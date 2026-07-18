import XCTest
@testable import OpenCircuitKit

/// The bedtime widen (`SleepStaging.applyBedtimeWiden` via `preOnsetBedtimeReachEpochs`): re-open the
/// in-bed envelope over a MEASURED awake-in-bed lead-in the motion still-block missed, fixing the
/// "time in bed == time asleep / 100 % efficiency" fast-onset defect — without re-timing sleep and
/// without fabricating a latency.
///
/// Fixtures mirror the device-confirmed 07-15 shape: a moving-but-HR-elevated lead-in (reading in
/// bed), a short still settle at sleep level, then a DATA GAP, then a still low-HR sleep block. The
/// gap is load-bearing: it splits the lead-in into a fragment that stages to nothing, so the sleep
/// block itself has flat HR and collapses to inBedStart == onset (the real defect). The widen runs
/// over the FULL record set, so it can still reach the lead-in across the gap.
final class BedtimeWidenTests: XCTestCase {
    private let step: UInt32 = 150

    /// A still sleep-vitals epoch (motion `1` → joins the motion block).
    private func srec(_ counter: UInt32, hr: UInt8) -> BulkRecord {
        var b = [UInt8](repeating: 0, count: 23)
        b[0] = UInt8(counter >> 24); b[1] = UInt8((counter >> 16) & 0xFF)
        b[2] = UInt8((counter >> 8) & 0xFF); b[3] = UInt8(counter & 0xFF)
        b[4] = hr; b[5] = 60; b[8] = 0x62
        for k in 0..<5 { b[10 + k] = 1 }
        return BulkRecord(b)!
    }

    /// A MOVING epoch that still carries HR (non-uniform, non-placeholder motion → scored active by
    /// `detectFromMotion`, so it is EXCLUDED from the still block — like the pre-onset reading-in-bed
    /// epochs on 07-15). Layout `0x62` keeps `heartRate` decodable.
    private func mrec(_ counter: UInt32, hr: UInt8) -> BulkRecord {
        var b = [UInt8](repeating: 0, count: 23)
        b[0] = UInt8(counter >> 24); b[1] = UInt8((counter >> 16) & 0xFF)
        b[2] = UInt8((counter >> 8) & 0xFF); b[3] = UInt8(counter & 0xFF)
        b[4] = hr; b[5] = 60; b[8] = 0x62
        let m: [UInt8] = [30, 8, 31, 9, 30]
        for k in 0..<5 { b[10 + k] = m[k] }
        return BulkRecord(b)!
    }

    /// [leadN moving epochs @ leadHR] [3 still @ 53 (sleep-level, so the gap bridges)] [gapN missing]
    /// [120 still @ 52 = 5 h sleep]. Default lead is elevated (awake); pass `leadHR: 52` for a
    /// flat-floor lead-in that carries no awake evidence.
    private func night(leadHR: UInt8 = 72, leadN: Int = 12, gapN: Int = 12) -> [BulkRecord] {
        var recs: [BulkRecord] = []
        var c: UInt32 = 100_000
        for _ in 0..<leadN { recs.append(mrec(c, hr: leadHR)); c += step }
        for _ in 0..<3 { recs.append(srec(c, hr: 53)); c += step }
        c += step * UInt32(gapN)
        for _ in 0..<120 { recs.append(srec(c, hr: 52)); c += step }
        return recs
    }

    private func onset(_ s: [SleepSegment]) -> Date? {
        let a: Set<SleepStage> = [.asleepCore, .asleepDeep, .asleepREM]
        return s.filter { a.contains($0.stage) }.map(\.start).min()
    }
    private func wake(_ s: [SleepSegment]) -> Date? {
        let a: Set<SleepStage> = [.asleepCore, .asleepDeep, .asleepREM]
        return s.filter { a.contains($0.stage) }.map(\.end).max()
    }
    private func inBedStart(_ s: [SleepSegment]) -> Date? {
        s.filter { $0.stage == .inBed }.map(\.start).min()
    }
    private func tuning(reach: Int) -> SleepStaging.Tuning {
        SleepStaging.Tuning(preOnsetBedtimeReachEpochs: reach)
    }

    // MARK: - Core behaviour

    func testReachZeroReproducesTheFastOnsetCollapse() {
        let off = SleepStaging.classify(from: night(), tuning: tuning(reach: 0))
        XCTAssertEqual(inBedStart(off), onset(off), "reach=0: in-bed collapses onto onset (the defect)")
        XCTAssertEqual(SleepStaging.summary(off).efficiency, 1.0, accuracy: 0.001)
    }

    func testFastOnsetWidensInBedButNotSleep() {
        let recs = night()
        let off = SleepStaging.classify(from: recs, tuning: tuning(reach: 0))
        let on = SleepStaging.classify(from: recs, tuning: tuning(reach: 40))

        guard let bedOn = inBedStart(on), let onsetOn = onset(on) else { return XCTFail("no segments") }
        XCTAssertLessThan(bedOn, onsetOn, "widen pushes in-bed start before onset")
        XCTAssertLessThan(SleepStaging.summary(on).efficiency, 1.0, "efficiency must drop below 100 %")
        XCTAssertGreaterThan(SleepStaging.summary(on).awake, 0, "a pre-onset awake segment must exist")

        // #176 anchors + the sleep clock must NOT move — the widen adds only pre-onset in-bed awake.
        XCTAssertEqual(onset(on), onset(off), "onset unchanged")
        XCTAssertEqual(wake(on), wake(off), "wake unchanged")
        XCTAssertEqual(SleepStaging.summary(on).totalAsleep,
                       SleepStaging.summary(off).totalAsleep, accuracy: 0.5, "time asleep unchanged")
    }

    func testEnvelopeTilesWithoutGapOrOverlap() {
        let on = SleepStaging.classify(from: night(), tuning: tuning(reach: 40))
        guard let env = on.first(where: { $0.stage == .inBed }) else { return XCTFail("no inBed") }
        let inner = on.filter { $0.stage != .inBed }.sorted { $0.start < $1.start }
        XCTAssertEqual(inner.first?.start, env.start, "first child starts at the envelope start")
        XCTAssertEqual(inner.last?.end, env.end, "last child ends at the envelope end")
        for (a, b) in zip(inner, inner.dropFirst()) {
            XCTAssertEqual(a.end, b.start, "children tile contiguously (no gap/overlap)")
        }
    }

    // MARK: - Honesty guards (never fabricate)

    func testNoPreOnsetRecordsIsNoOp() {
        // Sleep block with nothing before it → no measured lead-in → no widen.
        var recs: [BulkRecord] = []
        var c: UInt32 = 100_000
        for _ in 0..<120 { recs.append(srec(c, hr: 52)); c += step }
        let on = SleepStaging.classify(from: recs, tuning: tuning(reach: 40))
        XCTAssertEqual(inBedStart(on), onset(on), "no pre-onset epochs → never fabricate a latency")
    }

    func testFlatFloorLeadInIsNoOp() {
        // Pre-onset epochs exist but HR is already at the sleeping floor (no awake evidence). Widening
        // here would manufacture awake time, so it must be a no-op.
        let on = SleepStaging.classify(from: night(leadHR: 52), tuning: tuning(reach: 40))
        XCTAssertEqual(inBedStart(on), onset(on), "flat-floor pre-onset HR → no awake evidence → no widen")
    }

    func testReachBoundsHowFarBack() {
        // reach smaller than the gap can't reach the lead-in (no records in range) → no widen; a reach
        // that clears the gap reaches the lead-in and widens. Proves reach is a hard bound.
        let recs = night(leadHR: 72, leadN: 20, gapN: 12)   // gap = 12 epochs
        let tooShort = SleepStaging.classify(from: recs, tuning: tuning(reach: 8))   // < gap
        let long = SleepStaging.classify(from: recs, tuning: tuning(reach: 48))      // clears gap
        XCTAssertEqual(inBedStart(tooShort), onset(tooShort), "reach inside the gap can't reach the lead-in")
        guard let bLong = inBedStart(long), let oLong = onset(long) else { return XCTFail("no segments") }
        XCTAssertLessThan(bLong, oLong, "a reach that clears the gap widens back to the lead-in")
    }

    func testStillButAwakeLeadInIsUntouched() {
        // A 07-11-style night: the awake lead-in is STILL (motion 1) so it joins the motion block, and
        // the existing HR gate already marks it pre-onset awake (windowStart > block.start). The widen's
        // fast-onset guard must skip it entirely — identical output at reach 0 and 40.
        var recs: [BulkRecord] = []
        var c: UInt32 = 100_000
        for _ in 0..<8 { recs.append(srec(c, hr: 72)); c += step }   // still-but-awake, in-block
        for _ in 0..<120 { recs.append(srec(c, hr: 52)); c += step }
        let off = SleepStaging.classify(from: recs, tuning: tuning(reach: 0))
        let on = SleepStaging.classify(from: recs, tuning: tuning(reach: 40))
        XCTAssertEqual(inBedStart(on), inBedStart(off), "existing lead-in night: in-bed start unchanged")
        XCTAssertEqual(onset(on), onset(off), "onset unchanged")
        XCTAssertEqual(SleepStaging.summary(on).awake, SleepStaging.summary(off).awake, accuracy: 0.5,
                       "awake unchanged — the widen does not double-count an already-detected lead-in")
        if let b = inBedStart(off), let o = onset(off) {
            XCTAssertLessThan(b, o, "sanity: the existing HR gate already put in-bed before onset")
        }
    }

    func testMultiFragmentInBedSegmentsNeverOverlap() {
        // Two real sleep blocks split by a gap. The widen targets only the ONSET-containing (earliest)
        // in-bed envelope, so it can never extend one fragment's in-bed into another's — assert no two
        // .inBed segments overlap (which would double-count in-bed and understate efficiency).
        var recs: [BulkRecord] = []
        var c: UInt32 = 100_000
        for _ in 0..<30 { recs.append(srec(c, hr: 52)); c += step }   // block 1 (75 min)
        c += step * 12                                                // gap
        for _ in 0..<120 { recs.append(srec(c, hr: 52)); c += step }  // block 2 (5 h)
        let on = SleepStaging.classify(from: recs, tuning: tuning(reach: 40))
        let beds = on.filter { $0.stage == .inBed }.sorted { $0.start < $1.start }
        for (a, b) in zip(beds, beds.dropFirst()) {
            XCTAssertLessThanOrEqual(a.end, b.start, "in-bed envelopes must not overlap after the widen")
        }
    }

    func testUnbridgeableAwakeGapIsNotCrossed() {
        // A gap with ELEVATED HR on the near side (awake, not asleep) must NOT be bridged — the user
        // may have been up and about, so we can't honestly call the far side "in bed".
        var recs: [BulkRecord] = []
        var c: UInt32 = 100_000
        for _ in 0..<12 { recs.append(mrec(c, hr: 72)); c += step }   // lead-in
        for _ in 0..<2 { recs.append(mrec(c, hr: 75)); c += step }    // still AWAKE right before the gap
        c += step * 12                                                // gap
        for _ in 0..<120 { recs.append(srec(c, hr: 52)); c += step }  // sleep block
        let on = SleepStaging.classify(from: recs, tuning: tuning(reach: 48))
        XCTAssertEqual(inBedStart(on), onset(on), "an awake-bordered gap is not bridged (no widen)")
    }

    func testShortAwakeBorderedDropoutStillWidens() {
        // Device regression 2026-07-18: a measured elevated-HR lead-in ended about 11 minutes
        // before the flat sleep block. Treat that as a routine sensor/history dropout, not enough
        // ambiguity to throw away the whole measured bedtime lead-in. The 30-minute guard above
        // remains a no-op, bounding how much unknown time the envelope can absorb.
        var recs: [BulkRecord] = []
        var c: UInt32 = 100_000
        for _ in 0..<12 { recs.append(mrec(c, hr: 78)); c += step }
        c += step * 3                                                // 10 min separation
        for _ in 0..<120 { recs.append(srec(c, hr: 52)); c += step }

        let on = SleepStaging.classify(from: recs, tuning: tuning(reach: 48))
        guard let bed = inBedStart(on), let sleep = onset(on) else { return XCTFail("no segments") }
        XCTAssertLessThan(bed, sleep, "a short dropout must not erase measured awake-in-bed lead-in")
        XCTAssertGreaterThan(SleepStaging.summary(on).awake, 0)
        XCTAssertLessThan(SleepStaging.summary(on).efficiency, 1.0)
    }
}

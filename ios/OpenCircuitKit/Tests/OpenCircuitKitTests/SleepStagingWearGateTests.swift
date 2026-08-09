import XCTest
@testable import OpenCircuitKit

// The #41 skin-temperature WEAR GATE, on the STAGED path (#194 item 1).
//
// The defect: `SleepStaging.classifyContiguous` called `BulkSleep.mainSleep(from:epoch:)` with NO
// `temperatures:` argument, while the coarse `BulkSleep.sleepSegments` and the night-scoping
// `BulkSleep.latestNightRecords` both passed them. `mainSleep` is the ONLY place the gate acts, so
// it was switched off on the path that produces the hypnogram — an off-wrist / charging block is
// perfectly still, and stillness is exactly what the motion detector calls sleep. The two paths
// could therefore disagree about what counts as a worn night, invisibly at the call site.
//
// ⚠️ WHY THE CORPUS CANNOT TEST THIS. The 18-night local corpus is byte-identical with the gate on:
// its only temperature source is the export bundles' `daytimeTemperatures`, and the store persists
// WORN readings only — 🟢 24 073 samples across the 7 bundles, minimum 28.00 °C, not one below the
// 28 °C `wornMinTemperatureC` line. The cold readings the gate needs live in
// `RingSession.nightTemperatureLog`, an in-memory buffer no export carries. So the evidence here is
// a SYNTHETIC unworn block over a synthetic night; the real-bytes half of the measurement (a real
// 2026-08-05 capture staged with a 20 °C block over it, 485 min → no night) lives in #194's report.
//
// ⚠️ FLAT-MOTION TRAP. Every fixture below expresses wake as ELEVATED HR, never as a motion value:
// a CONSTANT motion byte de-floors to "still", so a fixture built to look awake through motion
// stages as sleep and the assertions go vacuous.
final class SleepStagingWearGateTests: XCTestCase {

    // MARK: - Fixtures

    /// A still epoch carrying sleep-vitals HRV (`.sleepVitals` template).
    private func vrec(_ counter: UInt32, hr: UInt8, hrv: UInt8 = 55) -> BulkRecord {
        var b = [UInt8](repeating: 0, count: 23)
        b[0] = UInt8(counter >> 24); b[1] = UInt8((counter >> 16) & 0xFF)
        b[2] = UInt8((counter >> 8) & 0xFF); b[3] = UInt8(counter & 0xFF)
        b[4] = hr; b[5] = hrv; b[8] = 0x62
        for k in 0..<5 { b[10 + k] = 1 }
        return BulkRecord(b)!
    }

    /// A still epoch on the `.activity` template — the other half of the ring's SpO2 duty cycle.
    /// Motion is the baseline `1`; "no SpO2 in this epoch" is what byte[8] says here, not movement.
    private func qrec(_ counter: UInt32, hr: UInt8) -> BulkRecord {
        var b = [UInt8](repeating: 0, count: 23)
        b[0] = UInt8(counter >> 24); b[1] = UInt8((counter >> 16) & 0xFF)
        b[2] = UInt8((counter >> 8) & 0xFF); b[3] = UInt8(counter & 0xFF)
        b[4] = hr; b[8] = 0x12
        for k in 0..<5 { b[10 + k] = 1 }
        return BulkRecord(b)!
    }

    private let firstCounter: UInt32 = 1_000_000

    /// A plain still night that stages as real sleep with no temperature evidence at all. The
    /// morning is expressed as an HR rise, never as motion.
    private func stillNight(epochs: Int = 160, riseAt: Int = 130,
                            sleepHR: UInt8 = 54, wakeHR: UInt8 = 80,
                            from: UInt32? = nil) -> [BulkRecord] {
        var recs: [BulkRecord] = []
        var c = from ?? firstCounter
        for i in 0..<epochs {
            let hr = i >= riseAt ? wakeHR : sleepHR
            recs.append(i.isMultiple(of: 2) ? vrec(c, hr: hr) : qrec(c, hr: hr))
            c += UInt32(BulkRecord.epochSeconds)
        }
        return recs
    }

    private func date(_ counter: UInt32) -> Date {
        Date(timeIntervalSince1970: TimeInterval(Int(counter) + Command.syncEpoch))
    }

    /// Temperature samples every 5 minutes across `records`' whole span.
    private func temps(over records: [BulkRecord], celsius: Double) -> [TemperatureSample] {
        guard let lo = records.first?.date(), let hi = records.last?.date() else { return [] }
        var out: [TemperatureSample] = []
        var t = lo
        while t <= hi {
            out.append(TemperatureSample(time: t, celsius: celsius))
            t = t.addingTimeInterval(300)
        }
        return out
    }

    private func asleepMinutes(_ segs: [SleepSegment]) -> Int {
        Int((SleepStaging.totalAsleep(segs) / 60).rounded())
    }

    // MARK: - The gate is LIVE on the staged path

    /// THE REGRESSION TEST. Delete `temperatures:` from the `mainSleep` call in
    /// `classifyContiguous` — the exact pre-#194 line — and this goes red: the ring reads 20 °C
    /// through the entire block, and a 20 °C ring is on a charger, not on a finger.
    func testColdBlockIsNotStagedAsANight() {
        let recs = stillNight()
        let warm = SleepStaging.classify(from: recs)
        XCTAssertGreaterThan(asleepMinutes(warm), 120,
                             "fixture must stage as a real night before the gate can be shown to remove it")

        let cold = SleepStaging.classify(from: recs, temperatures: temps(over: recs, celsius: 20))
        XCTAssertEqual(asleepMinutes(cold), 0,
                       "an off-wrist block must not reach the hypnogram — the staged path ignored "
                       + "`temperatures:` before #194")
    }

    /// The gate must NOT fire on a worn night. Guards the opposite mutation — "pass temperatures and
    /// always reclassify" would pass the test above and fail this one.
    func testWornTemperaturesLeaveTheNightExactlyAsStagedWithoutThem() {
        let recs = stillNight()
        let none = SleepStaging.classify(from: recs)
        let worn = SleepStaging.classify(from: recs, temperatures: temps(over: recs, celsius: 34))
        XCTAssertEqual(worn, none, "a worn night must be byte-identical to the temperature-free replay")
        XCTAssertGreaterThan(asleepMinutes(worn), 120)
    }

    /// ABSENCE OF DATA IS NOT EVIDENCE OF BEING UNWORN. Cold samples that all sit OUTSIDE the
    /// detected block leave the night alone — the gate only judges blocks it has coverage for.
    /// Pins the contract end-to-end, not just inside `SleepDetection`.
    func testColdSamplesOutsideTheBlockDoNotDropTheNight() {
        let recs = stillNight()
        let before = date(firstCounter).addingTimeInterval(-6 * 3600)
        let outside = (0..<60).map {
            TemperatureSample(time: before.addingTimeInterval(TimeInterval($0 * 300)), celsius: 20)
        }
        XCTAssertEqual(SleepStaging.classify(from: recs, temperatures: outside),
                       SleepStaging.classify(from: recs),
                       "no coverage inside the block ⇒ trust the motion verdict, unchanged")
    }

    /// An EMPTY set is the pre-#194 call, and must be byte-identical. This is the property the
    /// 18-night corpus byte-identity rests on.
    func testEmptyTemperaturesAreByteIdenticalToTheUngatedStaging() {
        let recs = stillNight()
        XCTAssertEqual(SleepStaging.classify(from: recs, temperatures: []),
                       SleepStaging.classify(from: recs))
    }

    // MARK: - The multi-fragment (stitched) path

    /// A night handed off across two drains arrives as two contiguous runs, and `classify` stages
    /// each separately. Delete `temperatures:` from the `frags.flatMap` branch ALONE — leaving the
    /// single-fragment branch correct — and only this test goes red.
    func testStitchedNightAlsoHonoursTheWearGate() {
        // Two runs separated by a hole larger than `gravityMaxGap` (20 min), so `contiguousFragments`
        // splits them. Each run is long enough to stage on its own.
        let a = stillNight(epochs: 90, riseAt: 80, from: firstCounter)
        let gapStart = firstCounter + UInt32(90 * BulkRecord.epochSeconds) + 3600
        let b = stillNight(epochs: 90, riseAt: 80, from: gapStart)
        let recs = a + b
        XCTAssertEqual(BulkSleep.contiguousFragments(recs).count, 2, "fixture must actually be stitched")

        XCTAssertGreaterThan(asleepMinutes(SleepStaging.classify(from: recs)), 120)
        XCTAssertEqual(asleepMinutes(SleepStaging.classify(from: recs,
                                                          temperatures: temps(over: recs, celsius: 20))), 0,
                       "every fragment must be gated, not just a single-fragment night")
    }

    // MARK: - The kill switch

    /// `stagedWearGate = false` restores the pre-#194 behaviour byte-identically, even with cold
    /// samples in hand. Removing the flag (always honouring the samples) turns this red.
    func testKillSwitchRestoresTheUngatedStagingByteIdentically() {
        let recs = stillNight()
        let off = SleepStaging.classify(from: recs,
                                        temperatures: temps(over: recs, celsius: 20),
                                        tuning: SleepStaging.Tuning(stagedWearGate: false))
        XCTAssertEqual(off, SleepStaging.classify(from: recs),
                       "the escape hatch must reproduce the temperature-free staging exactly")
    }

    func testTheGateIsOnByDefault() {
        XCTAssertTrue(SleepStaging.Tuning.default.stagedWearGate,
                      "#194 ships the gate ENABLED; the flag exists to turn it off, not on")
    }

    // MARK: - The two paths must AGREE (the actual complaint in #194)

    /// The whole point: the coarse segmentation and the staged hypnogram must not disagree about
    /// whether the ring was worn. Before #194 the coarse path dropped this block and the staged path
    /// kept it.
    func testCoarseAndStagedPathsAgreeThatAColdBlockIsNotSleep() {
        let recs = stillNight()
        let cold = temps(over: recs, celsius: 20)

        let coarse = BulkSleep.sleepSegments(from: recs, temperatures: cold)
        let staged = SleepStaging.classify(from: recs, temperatures: cold)

        XCTAssertTrue(coarse.allSatisfy { $0.stage != .asleepCore },
                      "coarse path has always honoured the gate")
        XCTAssertEqual(asleepMinutes(staged), 0, "staged path must now agree with it")

        // …and they must still agree on a WORN night, in the other direction.
        let warm = temps(over: recs, celsius: 34)
        XCTAssertTrue(BulkSleep.sleepSegments(from: recs, temperatures: warm)
                        .contains { $0.stage == .asleepCore })
        XCTAssertGreaterThan(asleepMinutes(SleepStaging.classify(from: recs, temperatures: warm)), 120)
    }
}

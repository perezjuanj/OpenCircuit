import XCTest
@testable import OpenCircuitKit

/// Morning-continuation absorb in `BulkSleep.latestNightRecords`.
///
/// 🟢 Device case 2026-08-16 (Gen 2 Air, FR04.009): the wearer slept 03:44→10:30, but a ~1-min
/// detector split at 09:04 divided the block. The later 09:04–10:30 piece has a post-09:00 midpoint,
/// so `isOvernightBlock` refused it as a night and it drained away as an 86-min "nap" — the sleep
/// card (which excludes naps) reported 4 h for a 6¾ h night, and the reported wake froze hours
/// early. The fix chains FORWARD over later sleep blocks within `morningContinuationMaxGap`,
/// mirroring the backward stitch but under much stricter rules (small gap, overnight envelope
/// preserved, `maxNightSpan` respected, anchor untouched).
final class MorningContinuationAbsorbTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_780_000_000)   // ~2026, after syncEpoch

    private func record(at date: Date, still: Bool, seed: Int = 0) -> BulkRecord {
        let counter = UInt32(Int(date.timeIntervalSince1970) - Command.syncEpoch)
        var b = [UInt8](repeating: 0, count: BulkRecord.length)
        b[0] = UInt8((counter >> 24) & 0xff); b[1] = UInt8((counter >> 16) & 0xff)
        b[2] = UInt8((counter >> 8) & 0xff);  b[3] = UInt8(counter & 0xff)
        if still {
            for k in 10 ..< 15 { b[k] = 1 }                          // still baseline
        } else {
            // Elevated AND varied within/between epochs — a constant plateau would de-floor to
            // still (the flat-motion fixture trap) and never split the block.
            let jitter = UInt8(seed % 5)
            b[10] = 8 &+ jitter; b[11] = 12; b[12] = 20 &+ jitter; b[13] = 6; b[14] = 10
        }
        return BulkRecord(b)!
    }

    /// Still epochs at 150 s spacing covering [start, end).
    private func still(_ start: Date, _ end: Date) -> [BulkRecord] {
        stride(from: 0, to: end.timeIntervalSince(start), by: 150)
            .map { record(at: start.addingTimeInterval($0), still: true) }
    }

    private func moving(_ start: Date, _ end: Date) -> [BulkRecord] {
        stride(from: 0, to: end.timeIntervalSince(start), by: 150).enumerated()
            .map { record(at: start.addingTimeInterval($1), still: false, seed: $0) }
    }

    /// Local `hour`:`min` on the day containing `base` (+ dayOffset). Anchoring on local clock time
    /// keeps `isOvernightBlock` (a local-midpoint rule) deterministic across CI locales.
    private func at(_ hour: Int, _ min: Int = 0, dayOffset: Int = 0) -> Date {
        let cal = Calendar.current
        let day = cal.date(byAdding: .day, value: dayOffset, to: cal.startOfDay(for: base))!
        return cal.date(byAdding: .minute, value: hour * 60 + min, to: day)!
    }

    private func maxKeptDate(_ scoped: [BulkRecord]) -> Date? { scoped.map { $0.date() }.max() }

    /// THE DEVICE CASE, shaped: night 02:00–08:30, a 15-min real arousal, then a same-morning
    /// continuation 08:45–10:30 whose own midpoint (09:37) fails the overnight test. The
    /// continuation must be absorbed into the night.
    func testBriefArousalContinuationIsAbsorbed() {
        let union = still(at(2, 0), at(8, 30))
            + moving(at(8, 30), at(8, 45))
            + still(at(8, 45), at(10, 30))

        let scoped = BulkSleep.latestNightRecords(from: union)

        XCTAssertNotNil(maxKeptDate(scoped))
        XCTAssertGreaterThanOrEqual(maxKeptDate(scoped)!, at(10, 25),
                                    "the 08:45–10:30 continuation is part of the night")
        // The head of the night survives absorption untouched.
        XCTAssertLessThanOrEqual(scoped.map { $0.date() }.min()!, at(2, 0))
    }

    /// Kill switch: `morningContinuationGap: 0` is byte-identical to the pre-fix scoping.
    func testZeroGapIsByteIdenticalToPreFixScoping() {
        let union = still(at(2, 0), at(8, 30))
            + moving(at(8, 30), at(8, 45))
            + still(at(8, 45), at(10, 30))

        let off = BulkSleep.latestNightRecords(from: union, morningContinuationGap: 0)

        // Pre-fix behaviour: the night ends at the arousal; only the 30-min margin follows it.
        XCTAssertLessThanOrEqual(maxKeptDate(off)!, at(9, 1),
                                 "with the absorb disabled the continuation stays out")
        XCTAssertEqual(off.map(\.counter), off.map(\.counter).sorted(), "scoped set stays ordered")
    }

    /// A genuine late-morning nap keeps its hours-wide gap and stays OUT of the night.
    func testRealNapHoursLaterIsNotAbsorbed() {
        let union = still(at(2, 0), at(8, 30))
            + moving(at(8, 30), at(8, 45))
            + still(at(11, 45), at(13, 0))          // 3-h gap → a nap, not a continuation

        let scoped = BulkSleep.latestNightRecords(from: union)

        XCTAssertLessThanOrEqual(maxKeptDate(scoped)!, at(9, 1),
                                 "a 3-h gap must not be bridged — that block is a nap")
    }

    /// Absorption must never push the whole-night envelope past the overnight gate: losing a real
    /// night to recover its tail would be the anchor-eviction failure shape. A late-onset night
    /// whose extension would move the envelope midpoint past 09:00 keeps its tail split off.
    func testAbsorbStopsBeforeBreakingTheOvernightEnvelope() {
        let union = still(at(5, 0), at(8, 50))
            + moving(at(8, 50), at(9, 0))
            + still(at(9, 0), at(13, 50))           // extension would put the midpoint at 09:25

        let scoped = BulkSleep.latestNightRecords(from: union)

        XCTAssertFalse(scoped.isEmpty, "the 05:00–08:50 night itself must survive")
        XCTAssertLessThanOrEqual(maxKeptDate(scoped)!, at(9, 30),
                                 "the tail is refused rather than sinking the whole night")
        // And the surviving envelope still stages: the records still describe an overnight block.
        let lo = scoped.map { $0.date() }.min()!
        XCTAssertLessThanOrEqual(lo, at(5, 0))
    }

    /// A continuation bout can be too short to START a night yet real: candidates use the APK's
    /// nap floor (15 min), not `minSleepDuration` (60 min). 🟢 The device case's post-arousal bout
    /// was 32 min. A sub-nap-floor blip stays out.
    func testShortContinuationBoutAbsorbsButBlipDoesNot() {
        let bout = still(at(2, 0), at(8, 30))
            + moving(at(8, 30), at(8, 45))
            + still(at(8, 45), at(9, 10))            // 25 min — over the nap floor
        XCTAssertGreaterThanOrEqual(maxKeptDate(BulkSleep.latestNightRecords(from: bout))!,
                                    at(9, 5), "a 25-min post-arousal bout is part of the night")

        let blip = still(at(2, 0), at(8, 30))
            + moving(at(8, 30), at(8, 45))
            + still(at(8, 45), at(8, 55))            // 10 min — under the nap floor
        XCTAssertLessThanOrEqual(maxKeptDate(BulkSleep.latestNightRecords(from: blip))!,
                                 at(9, 1), "a sub-nap-floor blip must not extend the night")
    }

    /// Chaining: two continuation blocks separated by two brief arousals all fold into the night.
    func testChainedContinuationsAllAbsorb() {
        let union = still(at(1, 0), at(7, 0))
            + moving(at(7, 0), at(7, 10))
            + still(at(7, 10), at(8, 30))
            + moving(at(8, 30), at(8, 40))
            + still(at(8, 40), at(10, 0))

        let scoped = BulkSleep.latestNightRecords(from: union)

        XCTAssertGreaterThanOrEqual(maxKeptDate(scoped)!, at(9, 55),
                                    "both same-morning bouts belong to the night")
    }
}

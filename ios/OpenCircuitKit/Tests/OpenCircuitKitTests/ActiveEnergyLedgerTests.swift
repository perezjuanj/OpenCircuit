import XCTest
@testable import OpenCircuitKit

/// Per-bucket active-energy accounting. HealthKit SUMS `activeEnergyBurned`, so a double write is
/// PERMANENT in the user's Health store — every assertion here is ultimately about that.
final class ActiveEnergyLedgerTests: XCTestCase {

    private let day = Date(timeIntervalSince1970: 1_753_660_800)
    private let width: TimeInterval = 15 * 60

    private func at(_ hours: Double) -> Date { day.addingTimeInterval(hours * 3600) }

    private func bucket(hour: Double, kcal: Double) -> Calories.EnergyBucket {
        Calories.EnergyBucket(start: at(hour), end: at(hour).addingTimeInterval(width),
                              hrKcal: kcal, stepKcal: 0, elevatedMinutes: 0)
    }

    // MARK: Writing

    func testFirstFlushWritesEveryBucketInItsOwnWindow() {
        let buckets = [bucket(hour: 8, kcal: 40), bucket(hour: 9, kcal: 25)]
        let plan = ActiveEnergyLedger.plan(buckets: buckets, watermarks: [],
                                           dayStart: day, now: at(12))
        XCTAssertEqual(plan.writes.count, 2)
        XCTAssertEqual(plan.totalKcal, 65, accuracy: 1e-9)
        XCTAssertEqual(plan.writes[0].start, at(8))
        XCTAssertEqual(plan.writes[0].end, at(8).addingTimeInterval(width))
        XCTAssertEqual(plan.writes[1].kcal, 25, accuracy: 1e-9)
    }

    func testAlreadyWrittenBucketsAreNotRewritten() {
        let buckets = [bucket(hour: 8, kcal: 40)]
        let first = ActiveEnergyLedger.plan(buckets: buckets, watermarks: [],
                                            dayStart: day, now: at(12))
        let second = ActiveEnergyLedger.plan(buckets: buckets, watermarks: first.watermarks,
                                             dayStart: day, now: at(12))
        XCTAssertTrue(second.writes.isEmpty)
        XCTAssertEqual(second.watermarks, first.watermarks)
    }

    func testAGrowingBucketWritesOnlyItsIncrement() {
        let first = ActiveEnergyLedger.plan(buckets: [bucket(hour: 8, kcal: 40)],
                                            watermarks: [], dayStart: day, now: at(12))
        let second = ActiveEnergyLedger.plan(buckets: [bucket(hour: 8, kcal: 62)],
                                             watermarks: first.watermarks,
                                             dayStart: day, now: at(12))
        XCTAssertEqual(second.totalKcal, 22, accuracy: 1e-9)
    }

    /// A late drain delivers data for a bucket EARLIER than ones already written. Addressing marks
    /// by ordinal (not array position) is what stops the whole afternoon being re-paid.
    func testALateEarlierBucketPaysOnlyItsOwnIncrement() {
        let afternoon = [bucket(hour: 14, kcal: 30), bucket(hour: 15, kcal: 20)]
        let first = ActiveEnergyLedger.plan(buckets: afternoon, watermarks: [],
                                            dayStart: day, now: at(16))
        XCTAssertEqual(first.totalKcal, 50, accuracy: 1e-9)

        let withMorning = [bucket(hour: 9, kcal: 12)] + afternoon
        let second = ActiveEnergyLedger.plan(buckets: withMorning, watermarks: first.watermarks,
                                             dayStart: day, now: at(16))
        XCTAssertEqual(second.writes.count, 1)
        XCTAssertEqual(second.totalKcal, 12, accuracy: 1e-9)
        XCTAssertEqual(second.writes.first?.start, at(9))
    }

    // MARK: The aggregate gate

    /// A per-bucket floor would strand light constant walking forever — the reported bug in
    /// miniature. The gate is on the day's pending SUM.
    func testManySubKcalBucketsAccumulateAndThenWriteTogether() {
        // Two 0.4 kcal buckets = 0.8 for the day: under the gate, so nothing is written AND
        // nothing is marked — the kcal is still owed.
        let held = ActiveEnergyLedger.plan(
            buckets: (0 ..< 2).map { bucket(hour: 10 + Double($0) * 0.25, kcal: 0.4) },
            watermarks: [], dayStart: day, now: at(16))
        XCTAssertTrue(held.writes.isEmpty)
        XCTAssertTrue(held.watermarks.isEmpty)

        // A third arrives: the day crosses 1.0 and ALL THREE are written, none stranded.
        let released = ActiveEnergyLedger.plan(
            buckets: (0 ..< 3).map { bucket(hour: 10 + Double($0) * 0.25, kcal: 0.4) },
            watermarks: held.watermarks, dayStart: day, now: at(16))
        XCTAssertEqual(released.writes.count, 3)
        XCTAssertEqual(released.totalKcal, 1.2, accuracy: 1e-9)
    }

    func testAggregateAboveTheGateWritesEveryBucketIncludingSubKcalOnes() {
        let small = (0 ..< 4).map { bucket(hour: 10 + Double($0) * 0.25, kcal: 0.4) }
        let plan = ActiveEnergyLedger.plan(buckets: small, watermarks: [],
                                           dayStart: day, now: at(16))
        XCTAssertEqual(plan.writes.count, 4)
        XCTAssertEqual(plan.totalKcal, 1.6, accuracy: 1e-9)
    }

    func testBelowGateLeavesEveryMarkUntouchedSoTheKcalStaysOwed() {
        let plan = ActiveEnergyLedger.plan(buckets: [bucket(hour: 10, kcal: 0.5)],
                                           watermarks: [3, 4], dayStart: day, now: at(16),
                                           carry: 7)
        XCTAssertTrue(plan.writes.isEmpty)
        XCTAssertEqual(plan.watermarks, [3, 4])
        XCTAssertEqual(plan.carryRemaining, 7)
        XCTAssertEqual(plan.workoutConsumed, 0)
    }

    // MARK: Clamping to now

    func testBucketInProgressIsClampedToNow() {
        let now = at(9).addingTimeInterval(300)   // 5 min into the 09:00 bucket
        let plan = ActiveEnergyLedger.plan(buckets: [bucket(hour: 9, kcal: 5)],
                                           watermarks: [], dayStart: day, now: now)
        XCTAssertEqual(plan.writes.first?.end, now)
        XCTAssertGreaterThan(plan.writes.first!.end, plan.writes.first!.start)
    }

    func testFutureBucketIsSkippedAndStaysOwed() {
        let plan = ActiveEnergyLedger.plan(buckets: [bucket(hour: 20, kcal: 9)],
                                           watermarks: [], dayStart: day, now: at(12))
        XCTAssertTrue(plan.writes.isEmpty)
        XCTAssertTrue(plan.watermarks.isEmpty)
    }

    // MARK: Debt

    func testWorkoutCreditIsConsumedFromTheOldestIncrementsAndOnlyOnce() {
        let buckets = [bucket(hour: 8, kcal: 30), bucket(hour: 9, kcal: 40)]
        let plan = ActiveEnergyLedger.plan(buckets: buckets, watermarks: [],
                                           dayStart: day, now: at(12),
                                           uncreditedWorkoutKcal: 45)
        XCTAssertEqual(plan.workoutConsumed, 45, accuracy: 1e-9)
        XCTAssertEqual(plan.totalKcal, 25, accuracy: 1e-9)   // 70 earned − 45 already in Health
        XCTAssertEqual(plan.writes.count, 1)
        XCTAssertEqual(plan.writes.first?.start, at(9))

        // Marks advanced by the FULL increments, so the credit cannot be applied twice.
        let again = ActiveEnergyLedger.plan(buckets: buckets, watermarks: plan.watermarks,
                                            dayStart: day, now: at(12))
        XCTAssertTrue(again.writes.isEmpty)
    }

    func testCarryIsConsumedBeforeWorkoutCredit() {
        let plan = ActiveEnergyLedger.plan(buckets: [bucket(hour: 8, kcal: 100)],
                                           watermarks: [], dayStart: day, now: at(12),
                                           carry: 30, uncreditedWorkoutKcal: 20)
        XCTAssertEqual(plan.carryRemaining, 0, accuracy: 1e-9)
        XCTAssertEqual(plan.workoutConsumed, 20, accuracy: 1e-9)
        XCTAssertEqual(plan.totalKcal, 50, accuracy: 1e-9)
    }

    // MARK: Upgrade-day seeding

    /// The tester's case: mid-afternoon upgrade with 390 kcal already in Health against a day now
    /// attributed at 429. Exactly the 39 kcal difference must be written, in the AFTERNOON buckets
    /// where it was earned — never the whole 429 again.
    func testSeedingWritesOnlyTheDifferenceAndPlacesItLate() {
        let buckets = [bucket(hour: 8, kcal: 200), bucket(hour: 13, kcal: 190),
                       bucket(hour: 17, kcal: 39)]
        let seeded = ActiveEnergyLedger.seed(buckets: buckets, legacyWrittenKcal: 390,
                                             dayStart: day)
        XCTAssertEqual(seeded.carry, 0, accuracy: 1e-9)

        let plan = ActiveEnergyLedger.plan(buckets: buckets, watermarks: seeded.watermarks,
                                           dayStart: day, now: at(19), carry: seeded.carry)
        XCTAssertEqual(plan.totalKcal, 39, accuracy: 1e-9)
        XCTAssertEqual(plan.writes.count, 1)
        XCTAssertEqual(plan.writes.first?.start, at(17))
    }

    /// The legacy mark can EXCEED today's attributed total (a workout credit was already netted, or
    /// the old high-water mark latched high). The excess must become carry, not a negative write.
    func testSeedingExcessBecomesCarryAndSuppressesLaterWrites() {
        let buckets = [bucket(hour: 8, kcal: 200), bucket(hour: 13, kcal: 229)]
        let seeded = ActiveEnergyLedger.seed(buckets: buckets, legacyWrittenKcal: 500,
                                             dayStart: day)
        XCTAssertEqual(seeded.carry, 71, accuracy: 1e-9)

        let plan = ActiveEnergyLedger.plan(buckets: buckets, watermarks: seeded.watermarks,
                                           dayStart: day, now: at(19), carry: seeded.carry)
        XCTAssertTrue(plan.writes.isEmpty)

        // A later 100 kcal bucket pays only what survives the remaining 71 kcal of carry.
        let grown = buckets + [bucket(hour: 18, kcal: 100)]
        let next = ActiveEnergyLedger.plan(buckets: grown, watermarks: seeded.watermarks,
                                           dayStart: day, now: at(19), carry: seeded.carry)
        XCTAssertEqual(next.totalKcal, 29, accuracy: 1e-9)
        XCTAssertEqual(next.carryRemaining, 0, accuracy: 1e-9)
    }

    func testSeedingANewDayIsANoOp() {
        let buckets = [bucket(hour: 8, kcal: 40)]
        let seeded = ActiveEnergyLedger.seed(buckets: buckets, legacyWrittenKcal: 0, dayStart: day)
        XCTAssertEqual(seeded.carry, 0)
        XCTAssertEqual(seeded.watermarks.reduce(0, +), 0)
    }

    // MARK: Long days

    /// A DST fall-back day is 25 h. Ordinals are elapsed seconds from local midnight, so late
    /// buckets simply extend the array rather than going out of range.
    func testOrdinalsExtendPastTwentyFourHours() {
        let late = Calories.EnergyBucket(start: at(24.5), end: at(24.75),
                                         hrKcal: 10, stepKcal: 0, elevatedMinutes: 0)
        let plan = ActiveEnergyLedger.plan(buckets: [late], watermarks: [],
                                           dayStart: day, now: at(25))
        XCTAssertEqual(plan.totalKcal, 10, accuracy: 1e-9)
        XCTAssertEqual(plan.watermarks.count, 99)  // ordinal 98 (24.5 h / 15 min) + 1
    }
}

/// Regressions from the pre-release adversarial review of the attribution change.
final class ActiveEnergyLedgerReviewRegressionTests: XCTestCase {

    private let day = Date(timeIntervalSince1970: 1_753_660_800)
    private let width: TimeInterval = 15 * 60

    private func at(_ hours: Double) -> Date { day.addingTimeInterval(hours * 3600) }

    private func bucket(hour: Double, kcal: Double) -> Calories.EnergyBucket {
        Calories.EnergyBucket(start: at(hour), end: at(hour).addingTimeInterval(width),
                              hrKcal: kcal, stepKcal: 0, elevatedMinutes: 0)
    }

    /// REVIEW BLOCKER. A bucket's attributed energy can FALL between flushes — a later drain
    /// inserts an earlier HR point that re-prices a piece across a bucket edge. With per-bucket
    /// high-water marks alone, the fall stranded its inflated mark while the bucket that GAINED
    /// paid in full, so Apple Health drifted permanently high. It must net out.
    func testEnergyMovingBetweenBucketsPaysTheNetNotTheGross() {
        let before = [bucket(hour: 12, kcal: 3.847), bucket(hour: 12.25, kcal: 53.864)]
        let first = ActiveEnergyLedger.plan(buckets: before, watermarks: [],
                                            dayStart: day, now: at(13))
        XCTAssertEqual(first.totalKcal, 57.711, accuracy: 0.01)

        // The re-priced day: 12:00 gains 8.984, 12:15 loses 2.563. Net rise is 6.421.
        let after = [bucket(hour: 12, kcal: 12.831), bucket(hour: 12.25, kcal: 51.301)]
        let second = ActiveEnergyLedger.plan(buckets: after, watermarks: first.watermarks,
                                             dayStart: day, now: at(14),
                                             savedKcal: first.totalKcal)
        XCTAssertEqual(second.totalKcal, 6.421, accuracy: 0.01)

        // What Health holds must equal what the day is now worth — not the sum of gross rises.
        let held = first.totalKcal + second.totalKcal
        XCTAssertEqual(held, after.reduce(0) { $0 + $1.activeKcal }, accuracy: 0.01)
    }

    /// The netted overpayment has to SURVIVE a flush that writes nothing, or it is forgotten and
    /// the same kcal is paid again on the next rise.
    func testAFallWithNoOffsettingRiseIsHandedBackAsCarry() {
        let before = [bucket(hour: 9, kcal: 40)]
        let first = ActiveEnergyLedger.plan(buckets: before, watermarks: [], dayStart: day, now: at(10))

        let shrunk = [bucket(hour: 9, kcal: 25)]
        let second = ActiveEnergyLedger.plan(buckets: shrunk, watermarks: first.watermarks,
                                             dayStart: day, now: at(11), savedKcal: first.totalKcal)
        XCTAssertTrue(second.writes.isEmpty)
        XCTAssertEqual(second.carryRemaining, 15, accuracy: 1e-9)
        XCTAssertEqual(second.watermarks.first(where: { $0 > 0 }), 25)

        // A later 15 kcal rise is fully absorbed by that debt — Health stays at 40, the day's peak.
        let regrown = shrunk + [bucket(hour: 16, kcal: 15)]
        let third = ActiveEnergyLedger.plan(buckets: regrown, watermarks: second.watermarks,
                                            dayStart: day, now: at(17),
                                            carry: second.carryRemaining,
                                            savedKcal: first.totalKcal)
        XCTAssertTrue(third.writes.isEmpty)
    }

    /// REVIEW MAJOR. The #131 store recovery rebuilds the day from fewer rows while the marks
    /// survive in UserDefaults, and the residual step reconciliation re-places the day's energy in
    /// a DIFFERENT bucket. Without a day-total backstop that pays the same kcal twice — and
    /// HealthKit SUMS, so it can never be taken back.
    func testDayTotalBackstopBlocksRepaymentAfterEnergyIsRelocated() {
        let morning = (0 ..< 4).map { bucket(hour: 8 + Double($0) * 0.25, kcal: 30) }
        let first = ActiveEnergyLedger.plan(buckets: morning, watermarks: [],
                                            dayStart: day, now: at(13))
        XCTAssertEqual(first.totalKcal, 120, accuracy: 1e-9)

        // Store wiped: the same ~120 kcal day is rebuilt as ONE bucket at a different ordinal.
        let rebuilt = [bucket(hour: 13.75, kcal: 118)]
        let second = ActiveEnergyLedger.plan(buckets: rebuilt, watermarks: first.watermarks,
                                             dayStart: day, now: at(14),
                                             savedKcal: first.totalKcal)
        XCTAssertTrue(second.writes.isEmpty,
                      "Health already holds 120 for a day now worth 118 — nothing may be re-paid")
    }

    func testBackstopClampsAPartialWriteRatherThanDroppingIt() {
        let buckets = [bucket(hour: 9, kcal: 100)]
        let plan = ActiveEnergyLedger.plan(buckets: buckets, watermarks: [],
                                           dayStart: day, now: at(10), savedKcal: 70)
        XCTAssertEqual(plan.totalKcal, 30, accuracy: 1e-9)
    }

    /// An empty bucket set means "no data yet", not "the day lost everything" — otherwise the
    /// first flush of a morning would net the whole previous state into carry.
    func testEmptyBucketsAreNotReadAsATotalLoss() {
        let seeded = ActiveEnergyLedger.plan(buckets: [bucket(hour: 9, kcal: 40)],
                                             watermarks: [], dayStart: day, now: at(10))
        let empty = ActiveEnergyLedger.plan(buckets: [], watermarks: seeded.watermarks,
                                            dayStart: day, now: at(11), savedKcal: 40)
        XCTAssertEqual(empty.watermarks, seeded.watermarks)
        XCTAssertEqual(empty.carryRemaining, 0)
    }
}

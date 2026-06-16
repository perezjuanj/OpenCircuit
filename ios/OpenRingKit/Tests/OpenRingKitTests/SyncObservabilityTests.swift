import XCTest
@testable import OpenRingKit

final class SyncObservabilityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private let policy = SyncAlertPolicy(staleSyncThreshold: 6 * 3600,
                                         lowBatteryThreshold: 15,
                                         renotifyInterval: 6 * 3600)

    // MARK: activeConditions

    func testFreshSyncHealthyHasNoConditions() {
        let active = policy.activeConditions(
            now: now,
            lastSuccessfulSync: now.addingTimeInterval(-3600),  // 1h ago — fresh
            batteryPercent: 80,
            healthAuthorized: true,
            healthEverAuthorized: true)
        XCTAssertTrue(active.isEmpty)
    }

    func testNeverSyncedDoesNotFireStaleness() {
        // No baseline yet — a brand-new user is not nagged about staleness.
        let active = policy.activeConditions(
            now: now, lastSuccessfulSync: nil, batteryPercent: 80,
            healthAuthorized: true, healthEverAuthorized: true)
        XCTAssertFalse(active.contains(.notSynced))
    }

    func testStaleSyncFires() {
        let active = policy.activeConditions(
            now: now,
            lastSuccessfulSync: now.addingTimeInterval(-7 * 3600),  // 7h ago > 6h
            batteryPercent: 80,
            healthAuthorized: true, healthEverAuthorized: true)
        XCTAssertTrue(active.contains(.notSynced))
    }

    func testLowBatteryFiresAtThresholdAndNotAbove() {
        XCTAssertTrue(policy.activeConditions(
            now: now, lastSuccessfulSync: now, batteryPercent: 15,
            healthAuthorized: true, healthEverAuthorized: true).contains(.lowBattery))
        XCTAssertFalse(policy.activeConditions(
            now: now, lastSuccessfulSync: now, batteryPercent: 16,
            healthAuthorized: true, healthEverAuthorized: true).contains(.lowBattery))
    }

    func testNilBatterySkipsBatteryCheck() {
        let active = policy.activeConditions(
            now: now, lastSuccessfulSync: now, batteryPercent: nil,
            healthAuthorized: true, healthEverAuthorized: true)
        XCTAssertFalse(active.contains(.lowBattery))
    }

    func testHealthAuthLostOnlyWhenPreviouslyAuthorized() {
        // Never authorized → not an "auth lost" condition.
        XCTAssertFalse(policy.activeConditions(
            now: now, lastSuccessfulSync: now, batteryPercent: 80,
            healthAuthorized: false, healthEverAuthorized: false).contains(.healthAuthLost))
        // Was authorized, now off → fires.
        XCTAssertTrue(policy.activeConditions(
            now: now, lastSuccessfulSync: now, batteryPercent: 80,
            healthAuthorized: false, healthEverAuthorized: true).contains(.healthAuthLost))
    }

    // MARK: alertsToFire (debounce)

    func testAlertFiresWhenNeverFiredBefore() {
        let fire = policy.alertsToFire(
            now: now,
            lastSuccessfulSync: now.addingTimeInterval(-7 * 3600),
            batteryPercent: 80, healthAuthorized: true, healthEverAuthorized: true,
            lastFired: [:])
        XCTAssertEqual(fire, [.notSynced])
    }

    func testAlertSuppressedInsideRenotifyWindow() {
        let fire = policy.alertsToFire(
            now: now,
            lastSuccessfulSync: now.addingTimeInterval(-7 * 3600),
            batteryPercent: 80, healthAuthorized: true, healthEverAuthorized: true,
            lastFired: [.notSynced: now.addingTimeInterval(-3600)])  // fired 1h ago < 6h window
        XCTAssertTrue(fire.isEmpty)
    }

    func testAlertReFiresAfterRenotifyWindow() {
        let fire = policy.alertsToFire(
            now: now,
            lastSuccessfulSync: now.addingTimeInterval(-7 * 3600),
            batteryPercent: 80, healthAuthorized: true, healthEverAuthorized: true,
            lastFired: [.notSynced: now.addingTimeInterval(-7 * 3600)])  // fired 7h ago > 6h window
        XCTAssertEqual(fire, [.notSynced])
    }

    func testMultipleConditionsReturnedInStableOrder() {
        let fire = policy.alertsToFire(
            now: now,
            lastSuccessfulSync: now.addingTimeInterval(-7 * 3600),  // notSynced
            batteryPercent: 5,                                      // lowBattery
            healthAuthorized: false, healthEverAuthorized: true,    // healthAuthLost
            lastFired: [:])
        XCTAssertEqual(fire, [.notSynced, .lowBattery, .healthAuthLost])
    }

    // MARK: BoundedLog

    func testBoundedLogAppendsUnderLimit() {
        let out = BoundedLog.appendCapped(3, to: [1, 2], limit: 5)
        XCTAssertEqual(out, [1, 2, 3])
    }

    func testBoundedLogTrimsOldestOverLimit() {
        let out = BoundedLog.appendCapped(4, to: [1, 2, 3], limit: 3)
        XCTAssertEqual(out, [2, 3, 4])  // newest survive, oldest (1) dropped
    }

    func testBoundedLogZeroLimitIsEmpty() {
        XCTAssertEqual(BoundedLog.appendCapped(1, to: [1, 2], limit: 0), [])
    }
}

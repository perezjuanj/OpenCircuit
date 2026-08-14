import XCTest
@testable import OpenCircuitKit

/// The defect this guards: at a cold launch `ContentView` fires the trends reload from BOTH the
/// view's first `.task` AND `scenePhase == .active`, within a frame or two of each other, for the
/// same unchanged store — and 🟢 MEASURED 2026-08-14 one reload reads 24,959 rows.
///
/// The asymmetry that must survive any future edit: appear/foreground are navigation events that
/// know nothing about the store and are debounced; `.syncFinished` is the one trigger that means
/// "rows may have landed" and must NEVER be debounced, or a night that finishes draining while the
/// user is watching silently fails to appear.
final class TrendsRefreshPolicyTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_786_400_000)

    // MARK: First load is never suppressed

    func testFirstLoadAlwaysRuns() {
        for reason in [TrendsRefreshPolicy.Reason.appeared, .foregrounded, .syncFinished] {
            XCTAssertTrue(TrendsRefreshPolicy.shouldReload(reason: reason,
                                                           lastLoadedAt: nil, now: t0),
                          "a snapshot that has never loaded must not be debounced (\(reason))")
        }
    }

    // MARK: The cold-launch double-fire — the actual bug

    func testForegroundImmediatelyAfterAppearIsSuppressed() {
        // `.task` loads at t0; scenePhase flips to .active a frame later.
        XCTAssertFalse(TrendsRefreshPolicy.shouldReload(reason: .foregrounded,
                                                        lastLoadedAt: t0,
                                                        now: t0.addingTimeInterval(0.05)))
    }

    func testNavigationReloadsAreDebouncedInsideTheWindow() {
        let justInside = t0.addingTimeInterval(TrendsRefreshPolicy.minInterval - 0.001)
        XCTAssertFalse(TrendsRefreshPolicy.shouldReload(reason: .appeared,
                                                        lastLoadedAt: t0, now: justInside))
        XCTAssertFalse(TrendsRefreshPolicy.shouldReload(reason: .foregrounded,
                                                        lastLoadedAt: t0, now: justInside))
    }

    func testNavigationReloadsRunOnceTheWindowElapses() {
        let atBoundary = t0.addingTimeInterval(TrendsRefreshPolicy.minInterval)
        XCTAssertTrue(TrendsRefreshPolicy.shouldReload(reason: .appeared,
                                                       lastLoadedAt: t0, now: atBoundary))
        XCTAssertTrue(TrendsRefreshPolicy.shouldReload(reason: .foregrounded,
                                                       lastLoadedAt: t0,
                                                       now: t0.addingTimeInterval(3600)))
    }

    // MARK: A finished sync is never debounced

    func testSyncFinishedIsNeverDebounced() {
        // Same instant as the last load — a drain that commits immediately after a reload must
        // still refresh, or the rows it just wrote are invisible until the next navigation.
        XCTAssertTrue(TrendsRefreshPolicy.shouldReload(reason: .syncFinished,
                                                       lastLoadedAt: t0, now: t0))
        XCTAssertTrue(TrendsRefreshPolicy.shouldReload(reason: .syncFinished,
                                                       lastLoadedAt: t0,
                                                       now: t0.addingTimeInterval(0.001)))
    }

    // MARK: Clock hazards

    func testBackwardClockDoesNotLatchTheSnapshotStale() {
        // A timezone/NTP correction can move `now` behind `lastLoadedAt`. A naive `elapsed >=`
        // comparison would then suppress every navigation reload until real time caught up.
        XCTAssertTrue(TrendsRefreshPolicy.shouldReload(reason: .appeared,
                                                       lastLoadedAt: t0,
                                                       now: t0.addingTimeInterval(-3600)))
    }

    func testMinIntervalIsBoundedByTheRingEpochCadence() {
        // The documented rationale: a suppressed reload can be behind by at most ONE 150 s epoch.
        XCTAssertLessThanOrEqual(TrendsRefreshPolicy.minInterval, 150)
        XCTAssertGreaterThan(TrendsRefreshPolicy.minInterval, 0)
    }
}

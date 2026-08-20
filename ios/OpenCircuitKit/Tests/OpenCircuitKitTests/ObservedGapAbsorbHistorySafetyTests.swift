// DOES ENABLING THE OBSERVED-GAP GUARD REWRITE ALREADY-STORED NIGHTS?
//
// The guard (`BulkSleep.observedGapAbsorbCoverageCut`, now 0.65 = ON) moves a night's in-bed START
// later by ~2 h on the nights it fires. Every stored night is upserted through
// `LocalStore.saveSleepSummary`, so the release either heals history retroactively or leaves it
// alone — and which one it is changes the release decision. This pins the answer.
//
// WHAT THIS TEST PROVES, and what it does NOT. `LocalStore` lives in the app target and cannot be
// instantiated here (its tests are container-lifetime dead — see the project memory). What IS pure
// and testable is the two decisions that gate the write, and they are the whole mechanism:
//
//   1. WHICH ROW is found — `SleepNightKey.night(inBedStart:inBedEnd:)`, the upsert key.
//   2. WHETHER IT IS OVERWRITTEN — `SleepSummaryMerge.shouldReplace(...)`, fed a `sameCoverage`
//      computed at `LocalStore.swift:1498-1500` as "BOTH in-bed edges within one 150 s epoch".
//
// The `sameCoverage` predicate is RESTATED here (`sameCoverageAsLocalStoreComputesIt`) rather than
// called, because it is inline in the app target. If that line ever changes, this test keeps passing
// while production diverges — so the restatement is annotated with its exact source location and
// must be re-checked when `LocalStore` moves.
//
// The numbers are the MEASURED before/after for the two corpus nights the guard actually moves
// (`SleepBaselineTests`, corpus 2026-08-19): R3_2026-08-19 and R3_2026-08-12.

import XCTest
@testable import OpenCircuitKit

final class ObservedGapAbsorbHistorySafetyTests: XCTestCase {

    /// `LocalStore.swift:1498-1500`, restated. Both edges must be within one ring epoch.
    private func sameCoverageAsLocalStoreComputesIt(storedStart: Date, storedEnd: Date,
                                                    newStart: Date, newEnd: Date) -> Bool {
        let storedSpan = storedEnd > storedStart ? storedEnd.timeIntervalSince(storedStart) : 0
        let newSpan = newEnd > newStart ? newEnd.timeIntervalSince(newStart) : 0
        let epochTolerance = TimeInterval(BulkRecord.epochSeconds)
        return storedSpan > 0 && newSpan > 0
            && abs(storedStart.timeIntervalSince(newStart)) <= epochTolerance
            && abs(storedEnd.timeIntervalSince(newEnd)) <= epochTolerance
    }

    private func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)!
    }

    /// One measured night, off vs on.
    private struct Move {
        let id: String
        let storedStart: Date, storedEnd: Date, storedAsleepMin: Int
        let newStart: Date, newEnd: Date, newAsleepMin: Int
    }

    private var measuredMoves: [Move] {
        [
            // R3_2026-08-19 (the owner's night). in-bed start 20:24:34 -> 22:18:36, end unchanged.
            Move(id: "R3_2026-08-19",
                 storedStart: date("2026-08-18T20:24:34-04:00"),
                 storedEnd:   date("2026-08-19T09:12:41-04:00"), storedAsleepMin: 713,
                 newStart:    date("2026-08-18T22:18:36-04:00"),
                 newEnd:      date("2026-08-19T09:12:41-04:00"), newAsleepMin: 648),
            // R3_2026-08-12. in-bed start 22:51:56 -> 01:17:50 — this one CROSSES MIDNIGHT, which is
            // exactly the shape that used to alias the upsert key.
            Move(id: "R3_2026-08-12",
                 storedStart: date("2026-08-11T22:51:56-04:00"),
                 storedEnd:   date("2026-08-12T09:23:20-04:00"), storedAsleepMin: 540,
                 newStart:    date("2026-08-12T01:17:50-04:00"),
                 newEnd:      date("2026-08-12T09:23:20-04:00"), newAsleepMin: 468),
        ]
    }

    /// THE KEY IS INVARIANT. `SleepNightKey` anchors on `inBedEnd`, and this guard only ever moves
    /// `inBedStart` — so a re-drain lands on the SAME stored row and cannot insert a duplicate night,
    /// even when the corrected start crosses midnight.
    func testGuardNeverChangesTheNightKey() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        for m in measuredMoves {
            let before = SleepNightKey.night(inBedStart: m.storedStart, inBedEnd: m.storedEnd, calendar: cal)
            let after = SleepNightKey.night(inBedStart: m.newStart, inBedEnd: m.newEnd, calendar: cal)
            XCTAssertEqual(before, after,
                           "\(m.id): the guard moved the upsert key — a corrected night would be "
                           + "INSERTED alongside the stored one instead of merging with it")
        }
    }

    /// THE STORED NIGHT IS KEPT. `sameCoverage` is false (the start moved far more than one epoch),
    /// so `shouldReplace` judges on time asleep — and the guard only reduces it.
    func testAlreadyStoredNightsAreMergeProtectedAndKeepTheirValues() {
        for m in measuredMoves {
            let sameCoverage = sameCoverageAsLocalStoreComputesIt(
                storedStart: m.storedStart, storedEnd: m.storedEnd,
                newStart: m.newStart, newEnd: m.newEnd)
            XCTAssertFalse(sameCoverage,
                           "\(m.id): if this were true, shouldReplace would short-circuit to REPLACE "
                           + "and the release WOULD rewrite stored history")

            let replace = SleepSummaryMerge.shouldReplace(
                storedInBed: m.storedEnd.timeIntervalSince(m.storedStart),
                newInBed: m.newEnd.timeIntervalSince(m.newStart),
                storedAsleep: TimeInterval(m.storedAsleepMin) * 60,
                newAsleep: TimeInterval(m.newAsleepMin) * 60,
                sameCoverage: sameCoverage)
            XCTAssertFalse(replace,
                           "\(m.id): the stored night must be KEPT (.keptFullerStoredNight); the fix "
                           + "applies to nights staged from now on, it does not rewrite history")
        }
    }

    /// THE LOAD-BEARING PRECONDITION, STATED AS AN ASSERTION. The protection above holds only because
    /// the guard reduces asleep time. If a future change made it ADD sleep, `shouldReplace` would flip
    /// to REPLACE and stored nights WOULD be rewritten. Measured on the corpus: 2 of 2 moving nights
    /// reduce asleep, 0 increase it.
    func testProtectionDependsOnTheGuardOnlyEverReducingAsleep() {
        for m in measuredMoves {
            XCTAssertLessThan(m.newAsleepMin, m.storedAsleepMin,
                              "\(m.id): the guard increased asleep time — re-check the merge policy, "
                              + "because that case is NOT merge-protected")
        }
        // Demonstrate the flip explicitly, so the dependency is visible rather than implied.
        let m = measuredMoves[0]
        XCTAssertTrue(SleepSummaryMerge.shouldReplace(
            storedInBed: m.storedEnd.timeIntervalSince(m.storedStart),
            newInBed: m.newEnd.timeIntervalSince(m.newStart),
            storedAsleep: TimeInterval(m.storedAsleepMin) * 60,
            newAsleep: TimeInterval(m.storedAsleepMin + 1) * 60,
            sameCoverage: false),
            "sanity: MORE asleep does replace — which is why the reduction above is load-bearing")
    }
}

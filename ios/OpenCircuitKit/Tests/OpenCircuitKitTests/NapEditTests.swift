import XCTest
@testable import OpenCircuitKit

/// Tests for the manual nap edit/add validation (#nap-parity). Anchored to LOCAL start-of-day so the
/// daytime gate (which reads local wall-clock via SleepWindow.isOvernightBlock) is deterministic
/// regardless of the machine's timezone.
final class NapEditTests: XCTestCase {

    /// `at(14)` = 2 pm local today; `at(2)` = 2 am; `at(-1)` = 11 pm yesterday.
    private func at(_ hoursFromMidnight: Double) -> Date {
        Calendar.current.startOfDay(for: Date()).addingTimeInterval(hoursFromMidnight * 3600)
    }
    private func win(_ a: Double, _ b: Double) -> NapEdit.Window { .init(start: at(a), end: at(b)) }

    func testValidDaytimeNap() {
        XCTAssertNil(NapEdit.validate(win(14, 14.75)))
        XCTAssertTrue(NapEdit.isValid(win(14, 14.75)))
    }

    func testEndNotAfterStart() {
        XCTAssertEqual(NapEdit.validate(win(14, 14)), .endNotAfterStart)
        XCTAssertEqual(NapEdit.validate(win(15, 14)), .endNotAfterStart)
    }

    func testTooShort() {
        XCTAssertEqual(NapEdit.validate(win(14, 14.0 + 10.0/60.0)), .tooShort(minMinutes: 15))
    }

    func testExactMinimumAllowed() {
        XCTAssertNil(NapEdit.validate(win(14, 14.25)))   // exactly 15 min
    }

    func testTooLong() {
        XCTAssertEqual(NapEdit.validate(win(13, 20)), .tooLong(maxHours: 6))   // 7 h
    }

    func testRejectsOvernightNap() {
        // A 2:00–2:30 am block, no night/overlap conflict → rejected as not daytime.
        XCTAssertEqual(NapEdit.validate(win(2, 2.5)), .notDaytime)
    }

    func testRejectsFutureNap() {
        // now = 1 pm; a 2:00–2:30 pm nap ends in the future.
        XCTAssertEqual(NapEdit.validate(win(14, 14.5), now: at(13)), .inFuture)
        // now = 3 pm; the same nap is in the past → valid.
        XCTAssertNil(NapEdit.validate(win(14, 14.5), now: at(15)))
    }

    func testRejectsOverlapWithNight() {
        // Night 11 pm → 7 am; a 6:00–6:30 am nap overlaps it (reported as overlap, not "not daytime").
        let night = DateInterval(start: at(-1), end: at(7))
        XCTAssertEqual(NapEdit.validate(win(6, 6.5), night: night), .overlapsNight)
        // A 2 pm nap doesn't overlap that night.
        XCTAssertNil(NapEdit.validate(win(14, 14.5), night: night))
    }

    func testRejectsOverlapWithAnotherNap() {
        let other = [DateInterval(start: at(14), end: at(15))]
        XCTAssertEqual(NapEdit.validate(win(14.5, 15.5), otherNaps: other), .overlapsNap)
        XCTAssertNil(NapEdit.validate(win(15, 15.5), otherNaps: other))   // adjacent, no overlap
    }

    func testEditingAnExistingNapExcludesItselfFromOverlap() {
        XCTAssertNil(NapEdit.validate(win(14, 15.5), otherNaps: []))
    }
}

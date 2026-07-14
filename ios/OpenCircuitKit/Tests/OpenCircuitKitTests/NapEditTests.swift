import XCTest
@testable import OpenCircuitKit

/// Tests for the manual nap edit/add validation (#176 nap parity). Fixed anchor, no wall-clock.
final class NapEditTests: XCTestCase {

    private let ref = Date(timeIntervalSince1970: 1_700_000_000)
    private func at(_ h: Double) -> Date { ref.addingTimeInterval(h * 3600) }
    private func win(_ a: Double, _ b: Double) -> NapEdit.Window { .init(start: at(a), end: at(b)) }

    func testValidDaytimeNap() {
        // A 45-min afternoon nap, no night conflict.
        XCTAssertNil(NapEdit.validate(win(14, 14.75)))
        XCTAssertTrue(NapEdit.isValid(win(14, 14.75)))
    }

    func testEndNotAfterStart() {
        XCTAssertEqual(NapEdit.validate(win(14, 14)), .endNotAfterStart)
        XCTAssertEqual(NapEdit.validate(win(15, 14)), .endNotAfterStart)
    }

    func testTooShort() {
        // 10 min < 15 min floor.
        XCTAssertEqual(NapEdit.validate(win(14, 14.0 + 10.0/60.0)), .tooShort(minMinutes: 15))
    }

    func testExactMinimumAllowed() {
        XCTAssertNil(NapEdit.validate(win(14, 14.25)))   // exactly 15 min
    }

    func testTooLong() {
        // 7 h > 6 h cap → a night, not a nap.
        XCTAssertEqual(NapEdit.validate(win(13, 20)), .tooLong(maxHours: 6))
    }

    func testRejectsOverlapWithNight() {
        // Night 23:00→07:00 (crossing into next day via absolute times); a "nap" at 06:00→06:30 overlaps.
        let night = DateInterval(start: at(-1), end: at(7))   // e.g. 23:00 prev → 07:00
        XCTAssertEqual(NapEdit.validate(win(6, 6.5), night: night), .overlapsNight)
        // A 14:00 nap does NOT overlap that night.
        XCTAssertNil(NapEdit.validate(win(14, 14.5), night: night))
    }

    func testRejectsOverlapWithAnotherNap() {
        let other = [DateInterval(start: at(14), end: at(15))]
        XCTAssertEqual(NapEdit.validate(win(14.5, 15.5), otherNaps: other), .overlapsNap)
        // Adjacent (no overlap) is allowed.
        XCTAssertNil(NapEdit.validate(win(15, 15.5), otherNaps: other))
    }

    func testEditingAnExistingNapExcludesItselfFromOverlap() {
        // Editing the 14:00–15:00 nap to 14:00–15:30: pass only the OTHER naps (none), so no overlap.
        XCTAssertNil(NapEdit.validate(win(14, 15.5), otherNaps: []))
    }
}

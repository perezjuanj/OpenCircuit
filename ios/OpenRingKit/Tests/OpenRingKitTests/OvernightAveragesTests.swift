import XCTest
@testable import OpenRingKit

// The HRV-mismatch fix (Vitals 86 ms vs Sleep 64 ms): both surfaces now resolve a night's HRV
// to the SAME overnight MEAN via this helper, never the single newest epoch.
final class OvernightAveragesTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 0)

    func testMeanIsOvernightMeanNotLastEpoch() {
        let win = DateInterval(start: t0, duration: 8 * 3600)
        let points = [
            OvernightAverages.Point(value: 60, start: t0.addingTimeInterval(600)),
            OvernightAverages.Point(value: 62, start: t0.addingTimeInterval(3600)),
            OvernightAverages.Point(value: 48, start: t0.addingTimeInterval(5 * 3600)),
            OvernightAverages.Point(value: 86, start: win.end.addingTimeInterval(-300)),  // last epoch
        ]
        let mean = OvernightAverages.mean(points, window: win)!
        XCTAssertEqual(Int(mean.rounded()), 64, "(60+62+48+86)/4 = 64 — the canonical overnight mean")
        let lastEpoch = points.max { $0.start < $1.start }!.value
        XCTAssertEqual(Int(lastEpoch), 86, "what the Vitals row used to show")
        XCTAssertNotEqual(Int(mean.rounded()), Int(lastEpoch), "the regression class this fix closes")
    }

    func testMeanExcludesOutOfWindow() {
        let win = DateInterval(start: t0, duration: 3600)
        let points = [
            OvernightAverages.Point(value: 50, start: t0.addingTimeInterval(60)),
            OvernightAverages.Point(value: 70, start: t0.addingTimeInterval(7200)),  // outside window
        ]
        XCTAssertEqual(OvernightAverages.mean(points, window: win), 50)
    }

    func testMeanInclusiveOfWindowEndpoints() {
        let win = DateInterval(start: t0, end: t0.addingTimeInterval(3600))
        let points = [
            OvernightAverages.Point(value: 40, start: t0),                          // == start
            OvernightAverages.Point(value: 80, start: t0.addingTimeInterval(3600)), // == end
        ]
        XCTAssertEqual(OvernightAverages.mean(points, window: win), 60)
    }

    func testMeanNilWhenEmptyOrNoneInWindow() {
        let win = DateInterval(start: t0, duration: 3600)
        XCTAssertNil(OvernightAverages.mean([], window: win))
        XCTAssertNil(OvernightAverages.mean(
            [OvernightAverages.Point(value: 99, start: t0.addingTimeInterval(99_999))], window: win))
    }
}

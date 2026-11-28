import XCTest
import SwiftUI
import OpenCircuitKit
@testable import OpenCircuit

/// SYNTHETIC-ONLY (#399 review NIT 2). Every Your Numbers tile fills the height its grid row
/// offers, so a two-line Steps comparison beside any neighbour — a metric tile or the strap's Stress
/// or PAI tile, in any Edit Today order — leaves the row level. A tile that only took its natural
/// height would sit short, top-aligned, under a taller neighbour.
@MainActor
final class TodayTileRowFillTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_790_762_400)
    private let width: CGFloat = 180
    private let offered: CGFloat = 1_000

    /// The tile's height when the row offers `offered`, and its own natural height.
    private func heights<V: View>(_ view: V) -> (filled: CGFloat, natural: CGFloat) {
        let filled = UIHostingController(rootView: view)
            .sizeThatFits(in: CGSize(width: width, height: offered)).height
        let natural = UIHostingController(rootView: view.fixedSize(horizontal: false, vertical: true))
            .sizeThatFits(in: CGSize(width: width, height: offered)).height
        return (filled, natural)
    }

    private func assertFillsRow<V: View>(_ view: V, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let h = heights(view)
        XCTAssertGreaterThan(h.natural, 0, name, file: file, line: line)
        XCTAssertLessThan(h.natural, offered / 2, "\(name): natural height is a tile's, not the row's", file: file, line: line)
        XCTAssertEqual(h.filled, offered, accuracy: 1, "\(name) fills the row's height", file: file, line: line)
    }

    func testMetricTileFillsItsRow() {
        let pts = (-8 ... 0).map { TrendsEngine.DailyPoint(date: now.addingTimeInterval(Double($0) * 86_400), steps: 8_000) }
        let tile = TodayTiles.build(.steps, points: pts, restingHR: [], tempUnit: .celsius, now: now)
        assertFillsRow(MetricTileView(tile: tile), "Steps")
    }

    func testStrapStressTileFillsItsRow() {
        let stress = StrapStressTile(latest: HelioReading(value: 40, at: now.addingTimeInterval(-600)),
                                     today: .empty, day: DayTimeline.dayInterval(now))
        assertFillsRow(StrapStressTileView(tile: stress), "Stress")
    }

    func testStrapPAITileFillsItsRow() {
        let pai = StrapPAIReading(latest: HelioReading(value: 72, at: now.addingTimeInterval(-3_600)))
        assertFillsRow(StrapPAITileView(reading: pai), "PAI")
    }
}

import XCTest
@testable import OpenCircuit

/// #372: two Helio Straps nearby advertise the same name; the key tells them apart.
final class HelioStrapSearchTests: XCTestCase {
    private let a = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private let b = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!

    func testOnlyAForegroundConnectWithNoBackgroundRunPassesAWrongKeyOn() {
        XCTAssertTrue(HelioStrapSearch.passesWrongKeyOn(appIsActive: true, backgroundRunActive: false))
        XCTAssertFalse(HelioStrapSearch.passesWrongKeyOn(appIsActive: false, backgroundRunActive: false),
                       "a background connect can't search: decision 7 as before")
        XCTAssertFalse(HelioStrapSearch.passesWrongKeyOn(appIsActive: true, backgroundRunActive: true))
        XCTAssertFalse(HelioStrapSearch.passesWrongKeyOn(appIsActive: false, backgroundRunActive: true))
    }

    func testARefusingStrapIsSkippedUntilTheConnectEnds() {
        var search = HelioStrapSearch()
        XCTAssertFalse(search.isPassingOver)
        XCTAssertFalse(search.skips(a))

        search.refusedBy(a)
        XCTAssertTrue(search.isPassingOver, "the next strap is saved only once it accepts the key")
        XCTAssertTrue(search.skips(a))
        XCTAssertFalse(search.skips(b), "another strap is still tried")

        search.refusedBy(a)
        XCTAssertEqual(search.refused, [a], "one entry per strap")

        search.reset()
        XCTAssertFalse(search.isPassingOver)
        XCTAssertFalse(search.skips(a), "a new connect tries every strap again")
    }

    func testRunningOutGoesBackToTheFirstRefusingStrap() {
        var search = HelioStrapSearch()
        XCTAssertNil(search.ranOut(), "nothing refused: a plain not found")

        search.refusedBy(a)
        search.refusedBy(b)
        XCTAssertEqual(search.ranOut(), a)
        XCTAssertFalse(search.isPassingOver, "running out ends the connect")
        XCTAssertNil(search.ranOut())
    }
}

import XCTest
@testable import OpenCircuit

final class HelioSetupCopyTests: XCTestCase {
    /// The snippet the "Copy key snippet" button copies must be the guide's Method 1 snippet, byte for byte.
    func testKeySnippetIsInTheKeyGuideExactly() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let doc = try String(contentsOf: repo.appendingPathComponent("docs/HELIO_KEY_EXTRACTION.md"), encoding: .utf8)
        XCTAssertFalse(HelioKeySnippet.text.isEmpty)
        XCTAssertTrue(doc.contains(HelioKeySnippet.text), "the guide's snippet and HelioKeySnippet.text drifted")
        XCTAssertTrue(doc.contains("```javascript\n" + HelioKeySnippet.text + "\n```"), "the snippet is the whole code block")
    }

    func testStrapFirstStepsUseTheSetupVariant() {
        let steps = ActiveDeviceChoice.helioStrap.firstSteps
        XCTAssertEqual(steps, [HelioStatus.keyOriginCopy, HelioStatus.dontUnpairCopy, HelioStatus.zeppCoexistCopy])
        XCTAssertFalse(steps.contains(HelioStatus.zeppBluetoothCopy))
        XCTAssertTrue(HelioStatus.zeppCoexistCopy.contains("Zepp can stay installed"))
        XCTAssertFalse(HelioStatus.zeppCoexistCopy.contains("delete the Zepp app"))
    }

    func testBusyAndNotFoundStatusesKeepTheDirectInstruction() {
        let busy = HelioStatus.from(connection: .connected, phase: .strapBusy, hasKey: true, keyRejected: false, hasSavedStrap: true)
        let notFound = HelioStatus.from(connection: .notFound, phase: nil, hasKey: true, keyRejected: false, hasSavedStrap: true)
        for status in [busy, notFound] {
            XCTAssertTrue(status.detail?.contains("turn off Bluetooth for Zepp") == true)
        }
    }
}

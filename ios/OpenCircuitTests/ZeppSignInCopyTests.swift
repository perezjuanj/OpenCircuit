import XCTest
import ZeppAccountKit
@testable import OpenCircuit

/// The optional Zepp account key lookup: the account-type limit is stated wherever the button is,
/// and every failure points at the fallback.
final class ZeppSignInCopyTests: XCTestCase {

    func testTheLimitNamesEmailAndPasswordAndTheSocialSignIns() {
        let limit = ZeppSignInCopy.accountLimit
        XCTAssertTrue(limit.contains("email and password"))
        for provider in ["Google", "Apple"] { XCTAssertTrue(limit.contains(provider), provider) }
        XCTAssertTrue(limit.contains("Troubleshooting"), "the limit points at the fallback section")
    }

    func testThePrivacyLineSaysOnceNotSavedAndSignedOut() {
        let text = ZeppSignInCopy.privacy
        for fact in ["straight from this phone to Zepp", "once", "doesn't save them", "signs out", "Syncing never contacts Zepp"] {
            XCTAssertTrue(text.contains(fact), fact)
        }
    }

    func testTheSetupScreenNoLongerClaimsNothingEverReachesZepp() {
        XCTAssertFalse(HelioSetupView.noServerNote.contains("Nothing is sent to Zepp"))
        XCTAssertTrue(HelioSetupView.noServerNote.contains("Syncing sends nothing to Zepp"))
        XCTAssertTrue(HelioSetupView.noServerNote.contains(ZeppSignInCopy.buttonTitle), "names the one exception")
    }

    func testEveryErrorHasItsOwnMessageAndTheAccountOnesPointAtTheFallback() {
        let errors: [ZeppAccountError] = [.credentialsRejected, .noKeyOnAccount, .network, .unexpectedResponse(step: "login")]
        let messages = errors.map(ZeppSignInCopy.message(for:))
        XCTAssertEqual(Set(messages).count, errors.count)
        XCTAssertTrue(ZeppSignInCopy.message(for: ZeppAccountError.credentialsRejected).contains("Google, Apple"))
        XCTAssertTrue(ZeppSignInCopy.message(for: ZeppAccountError.credentialsRejected).contains("Troubleshooting"))
        XCTAssertTrue(ZeppSignInCopy.message(for: ZeppAccountError.unexpectedResponse(step: "tokens")).contains("Troubleshooting"))
        XCTAssertTrue(ZeppSignInCopy.mayStopWorking.contains("Troubleshooting"))
        XCTAssertTrue(ZeppSignInCopy.message(for: ZeppAccountError.noKeyOnAccount).contains("Pair the strap"))
        XCTAssertEqual(ZeppSignInCopy.message(for: URLError(.badURL)),
                       ZeppSignInCopy.message(for: ZeppAccountError.unexpectedResponse(step: "x")), "unknown errors read as unexpected")
    }

    /// The computer route is small print under Troubleshooting, not in Before you start or the Key section.
    func testTheTroubleshootingCopyCarriesTheComputerRoute() {
        XCTAssertTrue(HelioSetupView.troubleshootingIntro.contains("Google, Apple"))
        XCTAssertTrue(HelioSetupView.troubleshootingIntro.contains("computer"))
        XCTAssertTrue(HelioSetupView.snippetNote.contains("watchface.zepp.com"))
        XCTAssertFalse(HelioSetupView.keyStorageNote.contains("Spaces, colons"), "paste hints moved to Troubleshooting")
        XCTAssertTrue(HelioSetupView.pasteNote.contains("0x"))
    }

    func testTheDeviceRowShowsOnlyTheAddressEnding() {
        let strap = ZeppAccountDevice(deviceSource: ZeppAccountDevice.helioStrapSource, macAddress: "AA:BB:CC:DD:EE:FF",
                                      isActive: true, authKeyHex: "00112233445566778899aabbccddeeff")
        XCTAssertEqual(ZeppSignInCopy.deviceName(strap), "Amazfit Helio Strap")
        XCTAssertEqual(ZeppSignInCopy.deviceDetail(strap), "Address ending EE:FF · in use in Zepp")
        XCTAssertFalse(ZeppSignInCopy.deviceDetail(strap).contains("0011"))
    }
}

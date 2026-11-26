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

    // MARK: which device's key is used (shared by the setup screen and onboarding's sheet)

    private func device(_ source: Int?, _ suffix: String) -> ZeppAccountDevice {
        ZeppAccountDevice(deviceSource: source, macAddress: "AA:BB:CC:DD:\(suffix)", isActive: false,
                          authKeyHex: String(repeating: "0", count: 32))
    }

    func testOneDeviceOrOneStrapAmongSeveralIsUsedWithoutAsking() {
        let strap = device(ZeppAccountDevice.helioStrapSource, "00:01")
        let watch = device(1, "00:02")
        XCTAssertEqual(ZeppSignInCopy.pick(from: [strap]), .use(strap))
        XCTAssertEqual(ZeppSignInCopy.pick(from: [watch, strap]), .use(strap), "the strap, not the first device")
    }

    func testTwoStrapsOrNoStrapAmongSeveralAsks() {
        let a = device(ZeppAccountDevice.helioStrapSource, "00:01")
        let b = device(ZeppAccountDevice.helioStrapSource, "00:02")
        let watch = device(1, "00:03"), band = device(2, "00:04")
        XCTAssertEqual(ZeppSignInCopy.pick(from: [a, b]), .ask([a, b]))
        XCTAssertEqual(ZeppSignInCopy.pick(from: [watch, band]), .ask([watch, band]), "never another device's key silently")
    }

    // MARK: onboarding's strap sheet shows one way

    func testTheOnboardingSheetShowsOnlyTheSignInAndPointsAtTroubleshooting() {
        let shown = [HelioKeySheetCopy.intro, HelioKeySheetCopy.troubleshootingNote, ZeppSignInCopy.accountLimitShort,
                     ZeppSignInCopy.pairFirst]
        for text in shown {
            for fallback in ["computer", "snippet", "console", "paste", "Paste"] {
                XCTAssertFalse(text.contains(fallback), "\(fallback) in: \(text)")
            }
        }
        XCTAssertTrue(ZeppSignInCopy.accountLimitShort.contains("Troubleshooting"))
        XCTAssertTrue(ZeppSignInCopy.accountLimitShort.contains("email and password"))
        XCTAssertEqual(HelioSetupView.beforeYouStart,
                       [HelioStatus.keyOriginCopy, HelioStatus.dontUnpairCopy, HelioStatus.zeppCoexistCopy])
    }
}

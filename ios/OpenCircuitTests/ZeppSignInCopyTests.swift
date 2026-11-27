import XCTest
import ZeppAccountKit
import ZeppKit
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

    private func device(_ source: Int?, _ suffix: String, key: Character = "0", active: Bool = false) -> ZeppAccountDevice {
        ZeppAccountDevice(deviceSource: source, macAddress: "AA:BB:CC:DD:\(suffix)", isActive: active,
                          authKeyHex: String(repeating: key, count: 32))
    }

    private let strapSource = ZeppAccountDevice.helioStrapSource

    func testOneStrapIsUsedWithoutAskingWhereverItIsListed() {
        let strap = device(strapSource, "00:01", key: "a")
        let watch = device(1, "00:02", key: "b"), band = device(2, "00:03", key: "c")
        XCTAssertEqual(ZeppSignInCopy.pick(from: [strap]), .use(strap))
        XCTAssertEqual(ZeppSignInCopy.pick(from: [watch, strap]), .use(strap), "the strap, not the first device")
        XCTAssertEqual(ZeppSignInCopy.pick(from: [watch, band, strap]), .use(strap))
        XCTAssertEqual(ZeppSignInCopy.pick(from: [strap, strap]), .use(strap), "an exact duplicate is still one strap")
    }

    /// The case the old rule got wrong: an account whose only keyed device is a watch (the strap not
    /// paired yet, or listed without a key) handed the watch's key to the strap without a question.
    func testASingleDeviceThatIsNotAStrapAsksInsteadOfBeingUsed() {
        let watch = device(1, "00:02", key: "b", active: true)
        let unknown = device(nil, "00:03", key: "c")
        XCTAssertEqual(ZeppSignInCopy.pick(from: [watch]), .ask([watch]))
        XCTAssertEqual(ZeppSignInCopy.pick(from: [unknown]), .ask([unknown]), "no product code is not a strap")
        XCTAssertEqual(ZeppSignInCopy.pick(from: [watch, unknown]), .ask([watch, unknown]))
    }

    func testTwoStrapsAskAmongTheStrapsOnly() {
        let a = device(strapSource, "00:01", key: "a"), b = device(strapSource, "00:02", key: "b")
        let watch = device(1, "00:03", key: "c")
        XCTAssertEqual(ZeppSignInCopy.pick(from: [a, b]), .ask([a, b]))
        XCTAssertEqual(ZeppSignInCopy.pick(from: [watch, a, b]), .ask([a, b]), "a watch's key can't be the strap's")
    }

    /// Re-pairing can leave two entries for one strap. Same address, different keys: there is no way to
    /// know which is current, so ask; never keep whichever came first.
    func testOneStrapListedTwiceWithDifferentKeysAsks() {
        let old = device(strapSource, "EE:FF", key: "a"), current = device(strapSource, "EE:FF", key: "b", active: true)
        XCTAssertEqual(ZeppSignInCopy.pick(from: [old, current]), .ask([old, current]))
        XCTAssertEqual(ZeppSignInCopy.deviceDetail(current), "Address ending EE:FF · in use in Zepp", "the rows differ")
    }

    func testTheQuestionSaysWhichCaseItIs() {
        let a = device(strapSource, "00:01", key: "a"), b = device(strapSource, "00:02", key: "b")
        let watch = device(1, "00:03", key: "c")
        XCTAssertEqual(ZeppSignInCopy.pickHeader(for: [a, b]), ZeppSignInCopy.severalStrapsHeader)
        XCTAssertEqual(ZeppSignInCopy.pickFooter(for: [a, b]), ZeppSignInCopy.severalStrapsFooter)
        XCTAssertEqual(ZeppSignInCopy.pickHeader(for: [watch]), ZeppSignInCopy.noStrapHeader)
        XCTAssertTrue(ZeppSignInCopy.noStrapFooter.contains("only if you're sure"))
        XCTAssertTrue(ZeppSignInCopy.noStrapFooter.contains("pair it in the Zepp app"))
        XCTAssertFalse(ZeppSignInCopy.noStrapHeader.contains("More than one"), "one watch isn't 'more than one device'")
    }

    // MARK: sign-in → decision, end to end through ZeppAccountKeyLookup (scripted Zepp, no network)

    private let strapKey = "0123456789abcdef0123456789abcdef"
    private let watchKey = "fedcba9876543210fedcba9876543210"

    private func lookUp(_ items: [[String: Any]]) async throws -> ZeppSignInCopy.Pick {
        try await ZeppSignInCopy.lookUp(ZeppAccountKeyLookup(transport: FakeZepp(items: items)),
                                        email: "me@example.com", password: "pw")
    }

    private func item(_ source: Int?, _ mac: String, key: String?, active: Int = 0) -> [String: Any] {
        var info: [String: Any] = [:]
        if let key { info["auth_key"] = key }
        let text = String(data: try! JSONSerialization.data(withJSONObject: info), encoding: .utf8)!
        var out: [String: Any] = ["macAddress": mac, "activeStatus": active, "additionalInfo": text]
        if let source { out["deviceSource"] = source }
        return out
    }

    func testTheStrapsKeyIsTheOneHandedOnWhenTheAccountListsAWatchFirst() async throws {
        let pick = try await lookUp([item(1, "11:22:33:44:55:66", key: "0x" + watchKey.uppercased(), active: 1),
                                     item(strapSource, "AA:BB:CC:DD:EE:FF", key: "0x" + strapKey)])
        guard case .use(let chosen) = pick else { return XCTFail("expected the strap, got \(pick)") }
        XCTAssertEqual(chosen.authKeyHex, strapKey)
        XCTAssertNotEqual(chosen.authKeyHex, watchKey)
        // What the sheets hand to saveKeyAndUseStrap is accepted unchanged by the key store's parser.
        XCTAssertEqual(HelioKeyText.normalized(chosen.authKeyHex), strapKey)
        XCTAssertEqual(HelioKeyText.parse(chosen.authKeyHex), ZeppAuthKey(hex: strapKey))
    }

    func testAKeylessStrapNextToAKeyedWatchAsksRatherThanUsingTheWatch() async throws {
        let pick = try await lookUp([item(strapSource, "AA:BB:CC:DD:EE:FF", key: nil),
                                     item(1, "11:22:33:44:55:66", key: watchKey, active: 1)])
        guard case .ask(let devices) = pick else { return XCTFail("used a key without asking: \(pick)") }
        XCTAssertEqual(devices.map(\.authKeyHex), [watchKey])
        XCTAssertEqual(ZeppSignInCopy.pickHeader(for: devices), ZeppSignInCopy.noStrapHeader)
    }

    func testAnAccountWithOnlyAWatchAsks() async throws {
        let pick = try await lookUp([item(1, "11:22:33:44:55:66", key: watchKey, active: 1)])
        XCTAssertEqual(pick.usedKey, nil)
    }

    func testTwoStrapsWithEmptyAddressesAskWithBothRows() async throws {
        let pick = try await lookUp([item(strapSource, "", key: strapKey), item(strapSource, "", key: watchKey)])
        guard case .ask(let devices) = pick else { return XCTFail("expected a question, got \(pick)") }
        XCTAssertEqual(devices.map(\.authKeyHex), [strapKey, watchKey], "both rows stay, in Zepp's order")
    }

    func testNoKeyedDeviceIsTheNoKeyError() async {
        do {
            _ = try await lookUp([item(strapSource, "AA:BB:CC:DD:EE:FF", key: nil)])
            XCTFail("expected noKeyOnAccount")
        } catch {
            XCTAssertEqual(error as? ZeppAccountError, .noKeyOnAccount)
        }
    }

    private func codeOnly(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }   // code only
            .joined(separator: "\n")
    }

    /// The app has one sign-in sheet and it decides only through `lookUp`, so a future edit can't give
    /// one screen a looser rule.
    func testTheOneSheetDecidesThroughTheSharedLookUp() throws {
        let sheet = try codeOnly("OpenCircuit/Onboarding/OCStepHelioKey.swift")
        XCTAssertTrue(sheet.contains("ZeppSignInCopy.lookUp(lookup"))
        XCTAssertFalse(sheet.contains("devicesWithKeys("), "reads devices outside lookUp")
        XCTAssertFalse(sheet.contains("pick(from:"), "decides outside lookUp")
        XCTAssertFalse(sheet.contains("id: \\.macAddress"), "keys rows by address")
    }

    /// The setup screen opens the same sheet as onboarding (Afsal's design), and no second sign-in
    /// UI is left anywhere in the app.
    func testTheSetupScreenOpensTheSameSheetAndNoOtherSignInExists() throws {
        let setup = try codeOnly("OpenCircuit/Helio/HelioSetupView.swift")
        XCTAssertTrue(setup.contains("HelioKeySheet("), "setup screen presents the strap key sheet")
        XCTAssertTrue(setup.contains("entry: .setupScreen"))
        for path in ["OpenCircuit/Helio/HelioSetupView.swift", "OpenCircuit/Helio/ZeppSignInCopy.swift",
                     "OpenCircuit/Dashboard/DemoData.swift", "OpenCircuit/OnboardingView.swift"] {
            let code = try codeOnly(path)
            XCTAssertFalse(code.contains("ZeppSignInSheet"), "the old sheet is back in \(path)")
            XCTAssertFalse(code.contains("devicesWithKeys("), "\(path) signs in on its own")
        }
    }

    func testFromTheSetupScreenTheSheetOpensOnSignInAndPointsAtThatScreen() {
        XCTAssertEqual(HelioKeySheet.startMode(.setupScreen, requested: .choose), .signIn)
        XCTAssertEqual(HelioKeySheet.startMode(.onboarding, requested: .choose), .choose)
        XCTAssertEqual(HelioKeySheet.startMode(.onboarding, requested: .signIn), .signIn)
        XCTAssertEqual(HelioKeySheet.accountLimit(for: .setupScreen), ZeppSignInCopy.accountLimit)
        XCTAssertTrue(HelioKeySheet.accountLimit(for: .setupScreen).contains("strap's setup screen"))
        XCTAssertEqual(HelioKeySheet.accountLimit(for: .onboarding), ZeppSignInCopy.accountLimitShort)
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

private extension ZeppSignInCopy.Pick {
    var usedKey: String? { if case .use(let d) = self { return d.authKeyHex }; return nil }
}

/// Zepp's four requests, answered by path. Only the device list varies.
private struct FakeZepp: ZeppHTTPTransport {
    /// The device list as JSON, so the transport stays Sendable.
    private let list: Data
    init(items: [[String: Any]]) { list = try! JSONSerialization.data(withJSONObject: ["items": items]) }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        func reply(_ code: Int, _ body: Any? = nil, headers: [String: String] = [:]) throws -> (Data, HTTPURLResponse) {
            let data = try body.map { try JSONSerialization.data(withJSONObject: $0) } ?? Data()
            return (data, HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers)!)
        }
        switch url.path {
        case "/v2/registrations/tokens":
            return try reply(303, headers: ["Location": "https://example.invalid/ok?access=ACC&refresh=REF"])
        case "/v2/client/login":
            return try reply(200, ["token_info": ["login_token": "LT", "app_token": "AT", "user_id": "42"]])
        case "/users/42/devices":
            return (list, HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!)
        default:
            return try reply(200, [String: Any]())
        }
    }
}

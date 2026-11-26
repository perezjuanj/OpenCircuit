import Foundation
import XCTest
@testable import ZeppAccountKit

/// Records every request and answers from a script, one closure per call.
final class ScriptedTransport: ZeppHTTPTransport, @unchecked Sendable {
    typealias Reply = (URLRequest) throws -> (Data, HTTPURLResponse)
    private let lock = NSLock()
    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []

    init(_ replies: [Reply]) { self.replies = replies }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let reply: Reply? = lock.withLock {
            requests.append(request)
            return replies.isEmpty ? nil : replies.removeFirst()
        }
        guard let reply else { throw URLError(.cannotConnectToHost) }
        return try reply(request)
    }

    var paths: [String] { lock.withLock { requests.map { $0.url?.path ?? "" } } }
}

private func response(_ request: URLRequest, _ status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
    HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
}

private func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }

private let helioKey = "00112233445566778899aabbccddeeff"
private let otherKey = "ffeeddccbbaa99887766554433221100"

private func device(source: Int, mac: String, active: Int, key: String?) -> [String: Any] {
    var info: [String: Any] = ["productId": "x"]
    if let key { info["auth_key"] = key }
    return ["deviceSource": source, "macAddress": mac, "activeStatus": active,
            "additionalInfo": String(data: json(info), encoding: .utf8)!]
}

private let tokensOK: ScriptedTransport.Reply = { request in
    (Data(), response(request, 303, headers: ["Location": "https://example.invalid/success?access=ACC&refresh=REF&country_code=US"]))
}
private let loginOK: ScriptedTransport.Reply = { request in
    (json(["token_info": ["login_token": "LT", "app_token": "AT", "user_id": 1234567890]]), response(request, 200))
}
private let logoutOK: ScriptedTransport.Reply = { request in (json(["result": "ok"]), response(request, 200)) }

final class ZeppAccountKeyLookupTests: XCTestCase {

    private func lookup(_ transport: ScriptedTransport) -> ZeppAccountKeyLookup {
        ZeppAccountKeyLookup(transport: transport, makeUUID: { "uuid-1" }, makeAppID: { "42" })
    }

    // MARK: Wire format, pinned against huami-token's Python (urlencode + pycryptodome)

    func testFormEncodingMatchesPythonUrlencode() {
        let fields = [("emailOrPhone", "a.b+c@example.com"), ("password", "p@ss wörd&=%/~"), ("token", "access"), ("token", "refresh")]
        XCTAssertEqual(ZeppForm.encode(fields),
                       "emailOrPhone=a.b%2Bc%40example.com&password=p%40ss+w%C3%B6rd%26%3D%25%2F~&token=access&token=refresh")
    }

    func testPayloadCipherMatchesPycryptodome() {
        let plain = "emailOrPhone=a.b%2Bc%40example.com&password=p%40ss+w%C3%B6rd%26%3D%25%2F~&token=access&token=refresh"
        let expected = "1752cfe5b7b35554ba0dc2f8e0ba1aa665d2cba064ba57dfa6d2b634b8f8fc106f1d798bda5e1856599f133fd89d7c01"
            + "e5155de0a8cc7f1ff48c3d2e6f9956397ea8b8a9a1ea356f343ff3a79d66a98ec29ab91ba77aff0dbf345d5706ec2dcc"
            + "d21c1cdb213bc460a5beb68664b571cd"
        let cipher = ZeppPayloadCipher.encrypt(Data(plain.utf8))
        XCTAssertEqual(cipher.map { $0.map { String(format: "%02x", $0) }.joined() }, expected)
        XCTAssertEqual(cipher.flatMap(ZeppPayloadCipher.decrypt).flatMap { String(data: $0, encoding: .utf8) }, plain)
    }

    func testKeyNormalization() {
        XCTAssertEqual(ZeppAccountKeyLookup.normalizedKey("0x" + helioKey.uppercased()), helioKey)
        XCTAssertEqual(ZeppAccountKeyLookup.normalizedKey(" \(helioKey)\n"), helioKey)
        XCTAssertNil(ZeppAccountKeyLookup.normalizedKey("0x" + String(helioKey.dropLast(2))))
        XCTAssertNil(ZeppAccountKeyLookup.normalizedKey("??"))
        XCTAssertNil(ZeppAccountKeyLookup.normalizedKey(String(helioKey.dropLast()) + "g"))
    }

    // MARK: The whole sequence

    func testSignsInReadsKeysAndSignsOut() async throws {
        let transport = ScriptedTransport([tokensOK, loginOK, { request in
            (json(["items": [
                device(source: 1, mac: "11:22:33:44:55:66", active: 0, key: otherKey),
                device(source: 2, mac: "AA:AA:AA:AA:AA:AA", active: 1, key: nil),
                device(source: ZeppAccountDevice.helioStrapSource, mac: "AA:BB:CC:DD:EE:FF", active: 1, key: "0x" + helioKey),
            ]]), response(request, 200))
        }, logoutOK])

        let devices = try await lookup(transport).devicesWithKeys(email: "  me@example.com ", password: "secret pw")

        // The keyless device is dropped; the Helio Strap sorts first.
        XCTAssertEqual(devices.map(\.authKeyHex), [helioKey, otherKey])
        XCTAssertTrue(devices[0].isHelioStrap)
        XCTAssertEqual(devices[0].macSuffix, "EE:FF")
        XCTAssertEqual(transport.paths, ["/v2/registrations/tokens", "/v2/client/login", "/users/1234567890/devices", "/v1/client/logout"])

        let tokens = transport.requests[0]
        XCTAssertEqual(tokens.httpMethod, "POST")
        XCTAssertEqual(tokens.value(forHTTPHeaderField: "x-hm-ekv"), "1")
        let form = tokens.httpBody.flatMap(ZeppPayloadCipher.decrypt).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        XCTAssertTrue(form.hasPrefix("emailOrPhone=me%40example.com&state=REDIRECTION&client_id=HuaMi&password=secret+pw&"), form)
        XCTAssertTrue(form.contains("&token=access&token=refresh&"))

        let login = String(data: transport.requests[1].httpBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(login.hasPrefix("code=ACC&device_id=uuid-1&"), login)
        XCTAssertTrue(login.contains("grant_type=access_token"))

        let list = transport.requests[2]
        XCTAssertEqual(list.httpMethod, "GET")
        XCTAssertEqual(list.value(forHTTPHeaderField: "apptoken"), "AT")
        let query = URLComponents(url: list.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.filter { $0.name == "userid" }.map(\.value), ["1234567890"])
        XCTAssertEqual(query.filter { $0.name == "enableMultiDeviceOnMultiType" }.count, 2)

        let logout = String(data: transport.requests[3].httpBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertEqual(logout, "login_token=LT&os_verison=vnull")
    }

    func testATokenRedirectWithoutTokensIsRejectedCredentials() async {
        let transport = ScriptedTransport([{ request in
            (Data(), response(request, 303, headers: ["Location": "https://example.invalid/fail?error=0106"]))
        }])
        await assertThrows(.credentialsRejected, try await lookup(transport).devicesWithKeys(email: "me@example.com", password: "x"))
        XCTAssertEqual(transport.paths, ["/v2/registrations/tokens"], "no login, nothing else sent")
    }

    func testA4xxOnTheTokenStepIsRejectedCredentials() async {
        let transport = ScriptedTransport([{ request in (Data(), response(request, 401)) }])
        await assertThrows(.credentialsRejected, try await lookup(transport).devicesWithKeys(email: "me@example.com", password: "x"))
    }

    func testEmptyCredentialsSendNothing() async {
        let transport = ScriptedTransport([])
        await assertThrows(.credentialsRejected, try await lookup(transport).devicesWithKeys(email: "  ", password: "x"))
        await assertThrows(.credentialsRejected, try await lookup(transport).devicesWithKeys(email: "me@example.com", password: ""))
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testAnAccountWithNoKeysStillSignsOut() async {
        let transport = ScriptedTransport([tokensOK, loginOK, { request in
            (json(["items": [device(source: 2, mac: "AA:AA:AA:AA:AA:AA", active: 1, key: nil)]]), response(request, 200))
        }, logoutOK])
        await assertThrows(.noKeyOnAccount, try await lookup(transport).devicesWithKeys(email: "me@example.com", password: "x"))
        XCTAssertEqual(transport.paths.last, "/v1/client/logout")
    }

    func testAFailedDeviceListStillSignsOut() async {
        let transport = ScriptedTransport([tokensOK, loginOK, { request in (Data(), response(request, 500)) }, logoutOK])
        await assertThrows(.unexpectedResponse(step: "devices"),
                           try await lookup(transport).devicesWithKeys(email: "me@example.com", password: "x"))
        XCTAssertEqual(transport.paths.count, 4)
        XCTAssertEqual(transport.paths.last, "/v1/client/logout")
    }

    func testALoginWithoutTokensIsUnexpected() async {
        let transport = ScriptedTransport([tokensOK, { request in (json(["error_code": "0117"]), response(request, 200)) }])
        await assertThrows(.unexpectedResponse(step: "login"),
                           try await lookup(transport).devicesWithKeys(email: "me@example.com", password: "x"))
    }

    func testNoConnectionIsANetworkError() async {
        let transport = ScriptedTransport([{ _ in throw URLError(.notConnectedToInternet) }])
        await assertThrows(.network, try await lookup(transport).devicesWithKeys(email: "me@example.com", password: "x"))
    }

    func testAFailedLogoutDoesNotLoseTheKey() async throws {
        let transport = ScriptedTransport([tokensOK, loginOK, { request in
            (json(["items": [device(source: ZeppAccountDevice.helioStrapSource, mac: "AA:BB:CC:DD:EE:FF", active: 1, key: helioKey)]]),
             response(request, 200))
        }, { _ in throw URLError(.timedOut) }])
        let devices = try await lookup(transport).devicesWithKeys(email: "me@example.com", password: "x")
        XCTAssertEqual(devices.map(\.authKeyHex), [helioKey])
    }

    // MARK: Hygiene

    func testADeviceNeverReflectsItsKey() {
        let value = ZeppAccountDevice(deviceSource: ZeppAccountDevice.helioStrapSource, macAddress: "AA:BB:CC:DD:EE:FF",
                                      isActive: true, authKeyHex: helioKey)
        var dumped = ""
        dump(value, to: &dumped)
        for text in [String(describing: value), String(reflecting: value), "\(value)", dumped] {
            XCTAssertFalse(text.contains(helioKey), text)
            XCTAssertFalse(text.contains("AA:BB:CC:DD"), "the full address stays out too: \(text)")
        }
    }

    /// The module never logs: no print, NSLog, os_log or Logger anywhere in its sources.
    func testTheModuleHasNoLoggingCalls() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/ZeppAccountKit")
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let code = try String(contentsOf: file, encoding: .utf8)
                .split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            for call in ["print(", "NSLog(", "os_log(", "Logger(", "debugPrint(", "import os"] {
                XCTAssertFalse(code.contains(call), "\(file.lastPathComponent) contains \(call)")
            }
        }
    }

    // MARK: Live (opt-in)

    /// Against the real Zepp servers, only when `ZEPP_LIVE_DIR` names a 0700 directory holding
    /// `email` and `password` files, and `ZEPP_LIVE_KEY_FILE` the key to compare with. Prints nothing
    /// but counts and whether the key matched.
    func testLiveLookupAgainstZepp() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["ZEPP_LIVE_DIR"], let keyFile = env["ZEPP_LIVE_KEY_FILE"] else {
            throw XCTSkip("set ZEPP_LIVE_DIR and ZEPP_LIVE_KEY_FILE to run against Zepp")
        }
        let email = try String(contentsOfFile: dir + "/email", encoding: .utf8)
        let password = try String(contentsOfFile: dir + "/password", encoding: .utf8)
        let expected = ZeppAccountKeyLookup.normalizedKey(try String(contentsOfFile: keyFile, encoding: .utf8))
        let devices = try await ZeppAccountKeyLookup().devicesWithKeys(email: email, password: password)
        XCTAssertFalse(devices.isEmpty)
        XCTAssertTrue(devices[0].isHelioStrap, "the strap sorts first")
        XCTAssertEqual(devices[0].authKeyHex, expected, "the account's key is the one the strap accepts")
        // The app uses a key without asking only when exactly one Helio Strap is listed
        // (ZeppSignInCopy.pick): this account must be that case, with no other strap's key to confuse.
        XCTAssertEqual(devices.filter(\.isHelioStrap).count, 1, "exactly one strap on the account")
        XCTAssertEqual(devices.filter { $0.authKeyHex == expected }.count, 1, "the strap's key belongs to it alone")
        // A made-up account must come back as rejected credentials, not as an unexpected response.
        do {
            _ = try await ZeppAccountKeyLookup().devicesWithKeys(email: "nobody-\(UUID().uuidString.prefix(8))@example.com",
                                                                  password: "not-a-real-password-1")
            XCTFail("a made-up account signed in")
        } catch let error as ZeppAccountError {
            XCTAssertEqual(error, .credentialsRejected)
        }
    }

    // MARK: Helpers

    private func assertThrows<T>(_ expected: ZeppAccountError, _ body: @autoclosure () async throws -> T,
                                 file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as ZeppAccountError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected error type \(error)", file: file, line: line)
        }
    }
}

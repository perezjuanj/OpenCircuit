// The optional in-app key lookup for the Amazfit Helio Strap: sign in to the user's own Zepp
// account once, read the strap's auth key from the account's device list, sign out.
//
// Ported to Swift from huami-token (https://codeberg.org/argrento/huami-token), MIT License,
// Copyright (c) 2020-2025 Kirill Snezhko, with the author's permission. The full notice is in
// docs/THIRD_PARTY_NOTICES.md. The request sequence, endpoints, headers and the payload cipher
// below are huami-token's `zepp.py` / `constants.py` (amazfit method, `--bt_keys`).
//
// Rules for this file (docs/HELIO_KEY_EXTRACTION.md, "In the app"):
// - It is the ONLY code in OpenCircuit that contacts a vendor server, and only when the person
//   taps the button. Syncing never comes through here.
// - Nothing is logged, printed or persisted: not the email, the password, the tokens or the key.
//   The caller gets the key back and decides what to save (the Keychain).
// - Email + password accounts only. Zepp accounts made with Google, Apple or another sign-in have
//   no password this call can use.

import Foundation
import CommonCrypto

/// One device on the Zepp account that carries a usable auth key.
public struct ZeppAccountDevice: Equatable, Sendable, CustomStringConvertible, CustomReflectable {
    /// Zepp's product code for the device (`deviceSource`).
    public let deviceSource: Int?
    /// The device's Bluetooth address as Zepp stored it, e.g. `AA:BB:CC:DD:EE:FF`.
    public let macAddress: String
    /// Zepp marks the device in use on the account.
    public let isActive: Bool
    /// The 32 lowercase hex characters, no `0x`.
    public let authKeyHex: String

    public init(deviceSource: Int?, macAddress: String, isActive: Bool, authKeyHex: String) {
        self.deviceSource = deviceSource
        self.macAddress = macAddress
        self.isActive = isActive
        self.authKeyHex = authKeyHex
    }

    /// `deviceSource` of the Helio Strap (seen on a real account and in Zepp's own firmware-history URL).
    public static let helioStrapSource = 10_289_411

    public var isHelioStrap: Bool { deviceSource == Self.helioStrapSource }

    /// The last two bytes of the address, for telling devices apart without showing the whole thing.
    public var macSuffix: String {
        let parts = macAddress.split(separator: ":")
        return parts.count >= 2 ? parts.suffix(2).joined(separator: ":") : macAddress
    }

    // The key never shows up in a description, interpolation or dump.
    public var description: String {
        "ZeppAccountDevice(source: \(deviceSource.map(String.init) ?? "nil"), mac: …\(macSuffix), active: \(isActive), key: <redacted>)"
    }

    public var customMirror: Mirror {
        Mirror(self, children: ["deviceSource": deviceSource as Any, "macSuffix": macSuffix, "isActive": isActive],
               displayStyle: .struct)
    }
}

public enum ZeppAccountError: Error, Equatable, Sendable {
    /// Zepp turned the email and password down (or the account has no password: a Google/Apple login).
    case credentialsRejected
    /// Signed in, but no device on the account has a key (the strap was never paired in Zepp).
    case noKeyOnAccount
    /// No connection, or the request timed out.
    case network
    /// Zepp answered in a shape this code doesn't know. `step` names the request.
    case unexpectedResponse(step: String)
}

/// Sends one request and returns the response WITHOUT following redirects (the token step answers
/// 303 and the tokens are in its `Location`).
public protocol ZeppHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct ZeppAccountKeyLookup: Sendable {
    private let transport: ZeppHTTPTransport
    private let makeUUID: @Sendable () -> String
    private let makeAppID: @Sendable () -> String

    public init(transport: ZeppHTTPTransport = URLSessionZeppTransport(),
                makeUUID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
                makeAppID: @escaping @Sendable () -> String = { String(UInt64.random(in: 0...UInt64.max)) }) {
        self.transport = transport
        self.makeUUID = makeUUID
        self.makeAppID = makeAppID
    }

    /// Signs in, reads every device that has a key, signs out (best effort, also after a failure).
    /// The result is sorted: Helio Strap first, then devices Zepp marks in use.
    public func devicesWithKeys(email: String, password: String) async throws -> [ZeppAccountDevice] {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, !password.isEmpty else { throw ZeppAccountError.credentialsRejected }
        let access = try await accessToken(email: email, password: password)
        let session = try await login(accessToken: access)
        let result: Result<[ZeppAccountDevice], Error>
        do {
            result = .success(try await devices(session: session))
        } catch {
            result = .failure(error)
        }
        await logout(session: session)
        let devices = try result.get()
        guard !devices.isEmpty else { throw ZeppAccountError.noKeyOnAccount }
        return devices.sorted { lhs, rhs in
            if lhs.isHelioStrap != rhs.isHelioStrap { return lhs.isHelioStrap }
            return lhs.isActive && !rhs.isActive
        }
    }

    // MARK: - Steps (huami-token `ZeppSession` / `ZeppClient`)

    struct Session { let loginToken: String; let appToken: String; let userID: String }

    /// Step 1: the encrypted credential exchange. Zepp answers 303 with the tokens in the query.
    func accessToken(email: String, password: String) async throws -> String {
        let fields: [(String, String)] = [
            ("emailOrPhone", email),
            ("state", "REDIRECTION"),
            ("client_id", "HuaMi"),
            ("password", password),
            ("redirect_uri", "https://s3-us-west-2.amazonaws.com/hm-registration/successsignin.html"),
            ("region", "us-west-2"),
            ("token", "access"),
            ("token", "refresh"),
            ("country_code", "US"),
        ]
        let plain = Data(ZeppForm.encode(fields).utf8)
        guard let body = ZeppPayloadCipher.encrypt(plain) else { throw ZeppAccountError.unexpectedResponse(step: "tokens") }
        var request = URLRequest(url: ZeppEndpoints.tokens)
        request.httpMethod = "POST"
        request.httpBody = body
        ZeppEndpoints.tokenHeaders.forEach { request.setValue($0.1, forHTTPHeaderField: $0.0) }

        let (_, response) = try await send(request)
        guard response.statusCode == 303 else {
            if (400..<500).contains(response.statusCode) { throw ZeppAccountError.credentialsRejected }
            throw ZeppAccountError.unexpectedResponse(step: "tokens")
        }
        guard let location = response.value(forHTTPHeaderField: "Location"),
              let items = URLComponents(string: location)?.queryItems else {
            throw ZeppAccountError.unexpectedResponse(step: "tokens")
        }
        let access = items.first { $0.name == "access" }?.value
        let refresh = items.first { $0.name == "refresh" }?.value
        guard let access, !access.isEmpty, let refresh, !refresh.isEmpty else {
            // A wrong password redirects too, with an error instead of tokens.
            throw ZeppAccountError.credentialsRejected
        }
        return access
    }

    /// Step 2: trade the access token for the app token and the user id.
    func login(accessToken: String) async throws -> Session {
        let fields: [(String, String)] = [
            ("code", accessToken),
            ("device_id", makeUUID()),
            ("device_model", "android_phone"),
            ("app_version", "9.12.5"),
            ("dn", "api-mifit.zepp.com,api-user.zepp.com,api-mifit.zepp.com,api-watch.zepp.com,app-analytics.zepp.com,auth.zepp.com,api-analytics.zepp.com"),
            ("third_name", "huami"),
            ("source", "com.huami.watch.hmwatchmanager:9.12.5:151689"),
            ("app_name", "com.huami.midong"),
            ("country_code", "US"),
            ("grant_type", "access_token"),
            ("allow_registration", "false"),
            ("lang", "en"),
            ("countryState", "US-NY"),
        ]
        var request = URLRequest(url: ZeppEndpoints.login)
        request.httpMethod = "POST"
        request.httpBody = Data(ZeppForm.encode(fields).utf8)
        ZeppEndpoints.loginHeaders.forEach { request.setValue($0.1, forHTTPHeaderField: $0.0) }

        let (data, response) = try await send(request)
        guard response.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let info = json["token_info"] as? [String: Any],
              let loginToken = info["login_token"] as? String, !loginToken.isEmpty,
              let appToken = info["app_token"] as? String, !appToken.isEmpty,
              let userID = Self.string(info["user_id"]), !userID.isEmpty else {
            throw ZeppAccountError.unexpectedResponse(step: "login")
        }
        return Session(loginToken: loginToken, appToken: appToken, userID: userID)
    }

    /// Step 3: the account's devices. The key is `additionalInfo` (a JSON string) → `auth_key`.
    func devices(session: Session) async throws -> [ZeppAccountDevice] {
        let requestID = makeUUID()
        let query: [(String, String)] = [
            ("enableMultiDeviceOnMultiType", "true"),
            ("enableMultiDeviceOnMultiType", "true"),
            ("channel", ZeppEndpoints.channel),
            ("country", "US"),
            ("cv", "151689_9.12.5"),
            ("device", "android_32"),
            ("device_type", "android_phone"),
            ("enableMultiDevice", "true"),
            ("lang", "en_US"),
            ("timezone", "Europe/London"),
            ("v", "2.0"),
            ("r", requestID),
            ("r", requestID),
            ("userid", session.userID),
            ("appid", makeAppID()),
        ]
        guard let base = ZeppEndpoints.devices(userID: session.userID),
              let url = URL(string: base.absoluteString + "?" + ZeppForm.encode(query)) else {
            throw ZeppAccountError.unexpectedResponse(step: "devices")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        ZeppEndpoints.deviceHeaders.forEach { request.setValue($0.1, forHTTPHeaderField: $0.0) }
        request.setValue(makeUUID(), forHTTPHeaderField: "x-request-id")
        request.setValue(session.appToken, forHTTPHeaderField: "apptoken")

        let (data, response) = try await send(request)
        guard response.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ZeppAccountError.unexpectedResponse(step: "devices")
        }
        let items = json["items"] as? [[String: Any]] ?? []
        return items.compactMap(Self.device(from:))
    }

    /// Step 4: end the session Zepp just opened. Failures are ignored: the key is already read.
    func logout(session: Session) async {
        var request = URLRequest(url: ZeppEndpoints.logout)
        request.httpMethod = "POST"
        request.httpBody = Data(ZeppForm.encode([("login_token", session.loginToken), ("os_verison", "vnull")]).utf8)
        ZeppEndpoints.logoutHeaders.forEach { request.setValue($0.1, forHTTPHeaderField: $0.0) }
        _ = try? await transport.send(request)
    }

    // MARK: - Helpers

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await transport.send(request)
        } catch is URLError {
            throw ZeppAccountError.network
        }
    }

    static func device(from item: [String: Any]) -> ZeppAccountDevice? {
        guard let infoText = item["additionalInfo"] as? String,
              let infoData = infoText.data(using: .utf8),
              let info = try? JSONSerialization.jsonObject(with: infoData) as? [String: Any],
              let rawKey = info["auth_key"] as? String,
              let key = normalizedKey(rawKey) else { return nil }
        return ZeppAccountDevice(deviceSource: (item["deviceSource"] as? NSNumber)?.intValue,
                                 macAddress: item["macAddress"] as? String ?? "",
                                 isActive: ((item["activeStatus"] as? NSNumber)?.intValue ?? 0) != 0,
                                 authKeyHex: key)
    }

    /// `0x` + 32 hex or bare 32 hex → 32 lowercase hex; anything else → nil.
    static func normalizedKey(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasPrefix("0x") { text.removeFirst(2) }
        guard text.count == 32, text.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { return nil }
        return text
    }

    private static func string(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }
}

// MARK: - Wire details

enum ZeppEndpoints {
    static let tokens = URL(string: "https://api-user-us2.zepp.com/v2/registrations/tokens")!
    static let login = URL(string: "https://api-mifit-us2.zepp.com/v2/client/login")!
    static let logout = URL(string: "https://api-mifit-us2.zepp.com/v1/client/logout")!
    static func devices(userID: String) -> URL? {
        guard let id = userID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
        return URL(string: "https://api-mifit.zepp.com/users/\(id)/devices")
    }

    static let channel = "a100900101016"
    private static let zeppUserAgent = "Zepp/9.12.5 (Pixel 4; Android 12; Density/2.75)"

    // `accept-encoding` is left to URLSession, which then also decompresses.
    static let tokenHeaders: [(String, String)] = [
        ("app_name", "com.huami.midong"), ("appname", "com.huami.midong"), ("cv", "151689_9.12.5"), ("v", "2.0"),
        ("appplatform", "android_phone"), ("vb", "202509151347"), ("vn", "9.12.5"), ("user-agent", zeppUserAgent),
        ("x-hm-ekv", "1"), ("content-type", "application/x-www-form-urlencoded; charset=UTF-8"),
    ]
    static let loginHeaders: [(String, String)] = [
        ("app_name", "com.huami.webapp"), ("appname", "com.huami.webapp"), ("origin", "https://user.zepp.com"),
        ("referer", "https://user.zepp.com/"),
        ("user-agent", "Mozilla/5.0 (X11; Linux x86_64; rv:133.0) Gecko/20100101 Firefox/133.0"),
        ("content-type", "application/x-www-form-urlencoded; charset=UTF-8"),
        ("accept", "application/json, text/plain, */*"), ("accept-language", "en-US,en;q=0.5"),
    ]
    static let deviceHeaders: [(String, String)] = [
        ("hm-privacy-diagnostics", "false"), ("country", "US"), ("appplatform", "android_phone"),
        ("hm-privacy-ceip", "true"), ("timezone", "Europe/London"), ("channel", channel), ("vb", "202509151347"),
        ("cv", "151689_9.12.5"), ("appname", "com.huami.midong"), ("v", "2.0"), ("vn", "9.12.5"),
        ("lang", "en_US"), ("user-agent", zeppUserAgent),
    ]
    static let logoutHeaders: [(String, String)] = [
        ("app_name", "com.huami.midong"), ("hm-privacy-ceip", "false"), ("accept-language", "en-US"),
        ("appname", "com.huami.midong"), ("cv", "151689_9.12.5"), ("v", "2.0"), ("appplatform", "android_phone"),
        ("vb", "202509151347"), ("vn", "9.12.5"), ("user-agent", zeppUserAgent),
        ("content-type", "application/x-www-form-urlencoded; charset=UTF-8"),
    ]
}

/// `application/x-www-form-urlencoded` the way Python's `urlencode` writes it (`quote_plus`):
/// letters, digits and `_.-~` stay, a space becomes `+`, everything else is `%XX` of its UTF-8.
enum ZeppForm {
    private static let unreserved = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-~".utf8)

    static func escape(_ text: String) -> String {
        var out = ""
        for byte in text.utf8 {
            if unreserved.contains(byte) {
                out.append(Character(UnicodeScalar(byte)))
            } else if byte == 0x20 {
                out.append("+")
            } else {
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    static func encode(_ fields: [(String, String)]) -> String {
        fields.map { "\(escape($0.0))=\(escape($0.1))" }.joined(separator: "&")
    }
}

/// The token request's body cipher: AES-128-CBC, PKCS#7, with the fixed key and IV the Zepp app
/// uses (huami-token `ZEPP_ENCRYPTION_PARAMS`). It obscures the form; TLS is what protects it.
enum ZeppPayloadCipher {
    static let key = Array("xeNtBVqzDc6tuNTh".utf8)
    static let iv = Array("MAAAYAAAAAAAAABg".utf8)

    static func encrypt(_ plain: Data) -> Data? { crypt(plain, operation: CCOperation(kCCEncrypt)) }
    static func decrypt(_ cipher: Data) -> Data? { crypt(cipher, operation: CCOperation(kCCDecrypt)) }

    private static func crypt(_ input: Data, operation: CCOperation) -> Data? {
        var output = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
        var written = 0
        let status = input.withUnsafeBytes { inBuffer in
            CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                    key, key.count, iv, inBuffer.baseAddress, input.count,
                    &output, output.count, &written)
        }
        guard status == CCCryptorStatus(kCCSuccess) else { return nil }
        return Data(output.prefix(written))
    }
}

import SwiftUI
import ZeppAccountKit

/// Copy for the optional Zepp account key lookup (`ZeppAccountKit`). The account-type limit is the
/// load-bearing line: Zepp accounts made with Google, Apple or another sign-in have no password the
/// lookup can use, so every account error points at the setup screen's Troubleshooting section.
enum ZeppSignInCopy {
    static let buttonTitle = "Get the key from my Zepp account"
    static let title = "Zepp Account"
    static let signInButton = "Sign in and get the key"

    static let accountLimit = "Works only if you sign in to Zepp with an email and password. If your Zepp account "
        + "uses Google, Apple, Facebook or another sign-in, this can't sign in: see Troubleshooting at the bottom "
        + "of the strap's setup screen."
    /// The same limit where Troubleshooting is at the bottom of the same sheet (the sheet opened from
    /// onboarding; from the setup screen it uses `accountLimit`).
    static let accountLimitShort = "Works only if you sign in to Zepp with an email and password. If your Zepp account "
        + "uses Google, Apple, Facebook or another sign-in, this can't sign in: see Troubleshooting at the bottom."
    static let pairFirst = "Pair the strap in the Zepp app first. The key only exists after pairing."
    static let privacy = "Your email and password go straight from this phone to Zepp, once, to read the strap's key. "
        + "OpenCircuit doesn't save them and signs out of Zepp right after. Syncing never contacts Zepp."
    static let mayStopWorking = "This uses the same sign-in as the Zepp app. If Zepp changes it, it can stop "
        + "working; Troubleshooting on the setup screen has another way."
    static let severalStrapsHeader = "More than one Helio Strap on this account"
    static let severalStrapsFooter = "Pick the strap you're setting up. The address ending is shown so you can tell "
        + "them apart."
    static let noStrapHeader = "No Helio Strap on this account"
    static let noStrapFooter = "None of these is marked as a Helio Strap. Pick one only if you're sure it's your "
        + "strap. If the strap isn't here, pair it in the Zepp app, then try again. A wrong key is refused by the "
        + "strap, and OpenCircuit tells you."

    /// The question's header and footer: several straps, or no strap among the account's devices.
    static func pickHeader(for devices: [ZeppAccountDevice]) -> String {
        devices.contains(where: \.isHelioStrap) ? severalStrapsHeader : noStrapHeader
    }

    static func pickFooter(for devices: [ZeppAccountDevice]) -> String {
        devices.contains(where: \.isHelioStrap) ? severalStrapsFooter : noStrapFooter
    }

    static func message(for error: Error) -> String {
        switch error as? ZeppAccountError {
        case .credentialsRejected?:
            return "Zepp didn't accept that email and password. If you sign in to Zepp with Google, Apple or "
                + "another account, see Troubleshooting on the setup screen."
        case .noKeyOnAccount?:
            return "Signed in, but no device on this Zepp account has a key. Pair the strap in the Zepp app, "
                + "then try again."
        case .network?:
            return "Couldn't reach Zepp. Check the connection and try again."
        case .unexpectedResponse?, nil:
            return "Zepp answered in a way OpenCircuit doesn't understand. Zepp may have changed its sign-in; "
                + "see Troubleshooting on the setup screen."
        }
    }

    /// Which of the account's devices gives the strap's key. Only an unambiguous Helio Strap is used
    /// without a question: exactly one strap once exact duplicates are dropped. Two or more straps ask
    /// among the straps only; no strap at all asks among everything, even when the account has just one
    /// other device (a watch's key never goes to the strap on its own). Used by the app's one sign-in
    /// sheet (`HelioKeySheet`, from onboarding and the setup screen) through `lookUp`.
    enum Pick: Equatable {
        case use(ZeppAccountDevice)
        case ask([ZeppAccountDevice])
    }

    static func pick(from devices: [ZeppAccountDevice]) -> Pick {
        var unique: [ZeppAccountDevice] = []
        for device in devices where !unique.contains(device) { unique.append(device) }
        let straps = unique.filter(\.isHelioStrap)
        if straps.count == 1 { return .use(straps[0]) }
        return .ask(straps.isEmpty ? unique : straps)
    }

    /// Sign in, read the account's keys, decide. `HelioKeySheet` calls this and nothing else, so the
    /// rule above is the only way a key from the account reaches `saveKeyAndUseStrap`.
    static func lookUp(_ lookup: ZeppAccountKeyLookup, email: String, password: String) async throws -> Pick {
        let result = pick(from: try await lookup.devicesWithKeys(email: email, password: password))
        if case .ask(let devices) = result, devices.isEmpty { throw ZeppAccountError.noKeyOnAccount }
        return result
    }

    static func deviceName(_ device: ZeppAccountDevice) -> String {
        device.isHelioStrap ? "Amazfit Helio Strap" : "Other Amazfit device"
    }

    static func deviceDetail(_ device: ZeppAccountDevice) -> String {
        "Address ending \(device.macSuffix)" + (device.isActive ? " · in use in Zepp" : "")
    }
}

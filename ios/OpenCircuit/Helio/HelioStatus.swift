import Foundation

/// What the strap's connection is doing, in plain language (decision 7's key states included).
/// One mapping for the Today card, the setup screen and the device screen, so they never disagree.
struct HelioStatus: Equatable {
    enum Tone: Equatable { case neutral, working, good, attention }

    /// The key states of decision 7, plus the connection's.
    enum Kind: Equatable {
        case bluetoothOff, bluetoothDenied
        case notSetUp, keyNeeded
        case searching, notFound, connecting, authenticating, settingUp
        case keyRejected, strapBusy, unsupported
        case syncing, ready, disconnected
    }

    let kind: Kind
    let title: String
    let detail: String?
    let tone: Tone

    /// Link to the key guide (docs/HELIO_KEY_EXTRACTION.md), for the key states.
    static let keyGuideURL = URL(string: "https://github.com/perezjuanj/OpenCircuit/blob/master/docs/HELIO_KEY_EXTRACTION.md")!

    /// Where the key comes from (`docs/HELIO_KEY_EXTRACTION.md`: Zepp's servers create it at pairing;
    /// it's copied out of the Zepp account on a computer). One constant for the setup screen's "Before
    /// you start" and onboarding's first steps, so the two can't fork (review-256 F1, F9).
    static let keyOriginCopy = "The strap talks only to an app that knows its 16-byte key. Zepp's servers create the "
        + "key once, when you pair the strap in the Zepp app; you copy it from your Zepp account on a computer. "
        + "OpenCircuit never signs in to Zepp."

    /// Decision 6's coexistence copy, verbatim.
    static let dontUnpairCopy = "Don't unpair the strap in the Zepp app; unpairing makes the key stop working."
    static let zeppBluetoothCopy = "To let OpenCircuit connect, turn off Bluetooth for Zepp (Settings ▸ Zepp ▸ Bluetooth) or delete the Zepp app."

    /// - Parameters:
    ///   - connection: `HelioConnection.state`.
    ///   - phase: the live session's phase, nil without a session.
    ///   - hasKey / keyRejected: from the key store.
    ///   - hasSavedStrap: a strap was connected on this phone before.
    static func from(connection: HelioConnection.State, phase: HelioSession.Phase?, hasKey: Bool,
                     keyRejected: Bool, hasSavedStrap: Bool, endedBusy: Bool = false) -> HelioStatus {
        switch connection {
        case .bluetoothOff:
            return .init(kind: .bluetoothOff, title: "Bluetooth is off",
                         detail: "Turn Bluetooth on to reach the strap.", tone: .attention)
        case .bluetoothDenied:
            return .init(kind: .bluetoothDenied, title: "Bluetooth not allowed",
                         detail: "Allow OpenCircuit in Settings ▸ Privacy & Security ▸ Bluetooth.", tone: .attention)
        case .searching:
            return .init(kind: .searching, title: "Looking for the strap…",
                         detail: "Keep it close to the phone. " + zeppBluetoothCopy, tone: .working)
        case .notFound:
            return .init(kind: .notFound, title: "No Helio Strap found",
                         detail: "Make sure it's charged and nearby. " + zeppBluetoothCopy, tone: .attention)
        case .connecting:
            return .init(kind: .connecting, title: "Connecting…",
                         detail: "The phone reconnects whenever the strap is in range.", tone: .working)
        case .idle:
            if !hasSavedStrap && !hasKey {
                return .init(kind: .notSetUp, title: "Not set up", detail: "Add the strap's key to connect.", tone: .neutral)
            }
            if keyRejected { return rejected }
            if !hasKey { return keyNeeded }
            if endedBusy { return busy }
            return .init(kind: .disconnected, title: "Not connected", detail: nil, tone: .neutral)
        case .connected:
            break
        }
        switch phase {
        case nil, .starting?:
            return .init(kind: .connecting, title: "Connecting…", detail: nil, tone: .working)
        case .keyless?:
            return keyNeeded
        case .keyRejected?:
            return rejected
        case .authenticating?:
            return .init(kind: .authenticating, title: "Checking the key…", detail: nil, tone: .working)
        case .strapBusy?:
            return busy
        case .unsupported?:
            return .init(kind: .unsupported, title: "Not supported",
                         detail: "This device doesn't offer what OpenCircuit needs.", tone: .attention)
        case .settingUp?:
            return .init(kind: .settingUp, title: "Connected, getting ready…", detail: nil, tone: .working)
        case .syncing?:
            return .init(kind: .syncing, title: "Syncing history…", detail: nil, tone: .working)
        case .ready?:
            return .init(kind: .ready, title: "Connected", detail: nil, tone: .good)
        }
    }

    static let busy = HelioStatus(
        kind: .strapBusy, title: "Strap busy",
        detail: "Another phone or app seems to hold the strap. " + zeppBluetoothCopy, tone: .attention)

    static let keyNeeded = HelioStatus(
        kind: .keyNeeded, title: "Key needed",
        detail: "Without the key the strap shares only live heart rate, and only if its Heart Rate Broadcast setting is on in the Zepp app.",
        tone: .attention)

    static let rejected = HelioStatus(
        kind: .keyRejected, title: "Key rejected",
        detail: "The strap refused the saved key. It stops working after the strap is unpaired in Zepp or reset. Get the key again and replace it.",
        tone: .attention)
}

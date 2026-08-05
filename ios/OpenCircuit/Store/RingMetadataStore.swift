import Foundation
import OpenCircuitKit

// The last connected ring's IDENTITY, cached so an export taken while the ring is DISCONNECTED can
// still name the device the data came from — which is the common case: people sit down to export at a
// desk, not with the ring streaming. `RingSession.firmwareInfo` only exists for the lifetime of a
// connection, so without this cache the export's device fields would be blank most of the time.
//
// UserDefaults-backed, deliberately NOT SwiftData: four short strings with no schema and no
// relationships, mirroring ObservabilityStore / EpochArchiveStore — and therefore zero migration risk
// for an existing store (cf. #21).
//
// PRIVACY — HARD RULE: no MAC-derived byte is stored here and none ever leaves this app. An export is
// a file the user hands to third parties (the diagnostics export already redacts the MAC by default,
// `RingSession.frameCaptureReport(redactMAC:)`), and a MAC is a stable hardware identifier that tells
// a reader nothing about the health data. The CoreBluetooth peripheral UUID is used instead: it is
// per-install, and it is already the key this app scopes per-ring state with (EpochArchiveStore).
//
// The rule needs enforcing, not just asserting: `firmware.mac` is never read here, AND the incoming
// model name is reduced to its family by `modelFamily` — the advertised name it comes from carries
// the last two MAC bytes in its trailing suffix, so caching it verbatim would have leaked them.

/// What we know about the ring that produced the stored data. Empty strings mean "never read" — the
/// DIS characteristics arrive asynchronously, so a field can legitimately be unknown.
struct RingMetadataSnapshot: Equatable {
    /// Model FAMILY only ("RingConn Gen2"), never the advertised name's MAC suffix — see
    /// `RingMetadataStore.modelFamily`.
    var modelName: String = ""
    var version: String = ""
    /// Human-readable generation label ("Gen 2", "Gen 3", …). Empty when the firmware prefix didn't
    /// match a known generation — never the literal "Unknown", so a consumer can't print a guess.
    var generation: String = ""
    /// CoreBluetooth peripheral UUID. NOT the MAC (see the privacy note above).
    var identifier: String = ""
}

struct RingMetadataStore {
    private let defaults: UserDefaults
    init(_ defaults: UserDefaults = .standard) { self.defaults = defaults }

    private enum Key {
        static let modelName = "ring.meta.modelName"
        static let version = "ring.meta.version"
        static let generation = "ring.meta.generation"
        static let identifier = "ring.meta.identifier"
    }

    func load() -> RingMetadataSnapshot {
        RingMetadataSnapshot(modelName: defaults.string(forKey: Key.modelName) ?? "",
                             version: defaults.string(forKey: Key.version) ?? "",
                             generation: defaults.string(forKey: Key.generation) ?? "",
                             identifier: defaults.string(forKey: Key.identifier) ?? "")
    }

    /// Cache the identity of the ring currently connected on `identifier`.
    ///
    /// Reads EXACTLY three fields off `firmware` — model, version, generation. `firmware.mac` is
    /// never touched; keeping the extraction in one place is what makes that auditable.
    ///
    /// Field merge rule: DIS characteristics are read one at a time, so an empty incoming field means
    /// "not read yet", not "cleared" — for the SAME ring we keep what an earlier read established. A
    /// DIFFERENT identifier replaces the whole record instead, so one ring's firmware can never be
    /// reported under another ring's identifier (#multi-ring).
    func record(from firmware: FirmwareInfo, identifier: String) {
        let previous = load()
        let sameRing = !identifier.isEmpty && identifier == previous.identifier
        func merged(_ incoming: String, _ existing: String) -> String {
            if !incoming.isEmpty { return incoming }
            return sameRing ? existing : ""
        }
        let generation = firmware.generation == .unknown ? "" : firmware.generation.rawValue
        defaults.set(merged(Self.modelFamily(firmware.modelName), previous.modelName),
                     forKey: Key.modelName)
        defaults.set(merged(firmware.version, previous.version), forKey: Key.version)
        defaults.set(merged(generation, previous.generation), forKey: Key.generation)
        defaults.set(identifier, forKey: Key.identifier)
    }

    /// The model FAMILY, with the advertised name's MAC suffix removed.
    ///
    /// `FirmwareInfo.modelName` is seeded from `CBPeripheral.name` (RingSession's `init`) and no DIS
    /// Model-Number characteristic ever replaces it, so what arrives here is always the ADVERTISED
    /// name — and that name ends in the last two MAC bytes: "RingConn Gen2-03AD" for the ring whose
    /// MAC is F8:79:99:F7:03:AD (🟢 docs/PROTOCOL.md:55, corroborated by an FR05.008 Gen 3 capture,
    /// FirmwareInfo.swift:6). Caching it whole put two stable hardware-identifier bytes into
    /// UserDefaults and then into every export file, while the export screen tells the user the
    /// ring's MAC is never included. Strip it HERE, at the one write site, so the suffix never
    /// reaches storage either.
    ///
    /// Only a trailing `-` followed by exactly four hex digits is removed — that is the shape the
    /// suffix has. Any other name (a model string with a hyphen in it, a future DIS value) is left
    /// untouched rather than guessed at.
    static func modelFamily(_ advertisedName: String) -> String {
        guard let dash = advertisedName.lastIndex(of: "-") else { return advertisedName }
        let suffix = advertisedName[advertisedName.index(after: dash)...]
        guard suffix.count == 4, suffix.allSatisfy(\.isHexDigit) else { return advertisedName }
        return String(advertisedName[..<dash])
    }
}

// Firmware version parsing + generation detection for the device-info screen (#79).
// The RingConn firmware prefix encodes the hardware generation (pp.txt:97512-97514):
//   FR01 → Gen 1
//   FR02 → Gen 2
//   FR04 → Gen 2 Air
//
// `hasFirmwareMismatch`: the version is non-empty AND doesn't start with the pinned
// string — a mismatch means we reverse-engineered on a different FW build and certain
// packet offsets may differ. Non-alarming: the ring still operates; it's a transparency
// note for technical users.

import Foundation

// MARK: - Generation

/// Hardware generation derived from the DIS Firmware-Revision-String prefix.
public enum RingGeneration: String, Equatable, Sendable {
    case gen1    = "Gen 1"
    case gen2    = "Gen 2"
    case gen2Air = "Gen 2 Air"
    case unknown = "Unknown"
}

// MARK: - FirmwareInfo

/// Collects the Device Information Service fields from a connected ring (#79).
/// Populated incrementally as each DIS characteristic is read (GATT reads arrive
/// asynchronously); unread fields stay at their empty defaults.
public struct FirmwareInfo: Equatable, Sendable {
    public var version: String = ""
    public var modelName: String = ""
    public var manufacturer: String = ""
    public var hardwareRevision: String?
    /// Ring MAC recovered from the System ID (0x2A23) characteristic (§1).
    public var mac: String?

    /// The FW version this build was reverse-engineered and tested against.
    public static let pinnedVersion = "FR02.018"

    /// True when a version string is known AND doesn't start with the pinned version.
    /// Non-empty guard prevents false positives before the DIS read completes.
    public var hasFirmwareMismatch: Bool {
        !version.isEmpty && !version.hasPrefix(Self.pinnedVersion)
    }

    /// Generation decoded from the four-character FW prefix (FR01/FR02/FR04).
    public var generation: RingGeneration {
        if version.hasPrefix("FR01") { return .gen1 }
        if version.hasPrefix("FR02") { return .gen2 }
        if version.hasPrefix("FR04") { return .gen2Air }
        return .unknown
    }

    public init(version: String = "", modelName: String = "",
                manufacturer: String = "", hardwareRevision: String? = nil,
                mac: String? = nil) {
        self.version = version
        self.modelName = modelName
        self.manufacturer = manufacturer
        self.hardwareRevision = hardwareRevision
        self.mac = mac
    }
}

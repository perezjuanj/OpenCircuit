// Firmware version parsing + generation detection for the device-info screen (#79).
// The RingConn firmware prefix encodes the hardware generation (pp.txt:97512-97514):
//   FR01 → Gen 1
//   FR02 → Gen 2
//   FR04 → Gen 2 Air
//   FR05 → Gen 3   (model "RingConn Gen3-C384", confirmed from an FR05.008 capture)
//
// Gen 3 note: an overnight FR05.008 / Gen3-C384 capture decodes byte-for-byte with the
// Gen-2 schemas — the 0x10/0x87 status descriptor (battery/temp/voltage/steps/case) and
// the 0x4c history epoch (HR/HRV/RR/SpO2, 0x96 counter step) are unchanged, and the
// decoded overnight SpO2 nadir matched the official app's reported low. So Gen 3 is
// labelled here for the device-info screen; no decode path branches on generation.
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
    case gen3    = "Gen 3"
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

    /// Generation decoded from the four-character FW prefix (FR01/FR02/FR04/FR05).
    public var generation: RingGeneration {
        if version.hasPrefix("FR01") { return .gen1 }
        if version.hasPrefix("FR02") { return .gen2 }
        if version.hasPrefix("FR04") { return .gen2Air }
        if version.hasPrefix("FR05") { return .gen3 }
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

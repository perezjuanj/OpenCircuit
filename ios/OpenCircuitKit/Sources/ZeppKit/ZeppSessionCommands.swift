// Post-auth session commands and live-data parsers (ZEPP_PROTOCOL.md §5, §7): battery, the
// HEALTH settings that decide what the strap records, heart-rate control, and the standard
// Heart Rate Measurement / Battery Level characteristics. Builders return message payloads;
// the caller sends them to the named endpoint through `ZeppLink`.

import Foundation

// MARK: - Device info (endpoint 0x0043, §5.3)

/// The hardware and firmware versions from a device-info reply. The serial number and the PnP ID
/// are personal identifiers: the parser steps over them and never stores them.
public struct ZeppDeviceInfo: Equatable {
    public static let request: [UInt8] = [0x01]

    /// The reply's u64 flags word (which fields are present).
    public let flags: UInt64
    /// nil when the flags don't announce it, or when `isAmbiguous`.
    public let hardwareVersion: String?
    public let firmwareVersion: String?
    /// The bit-0 blob's prefix widths (in bytes) under which the whole reply parsed. `[0]` when
    /// bit 0 is clear. Worth recording on hardware: it settles the SPEC-GAP below.
    public let blobPrefixWidths: [Int]
    /// More than one prefix width parsed and they locate different versions, so none is reported.
    public let isAmbiguous: Bool

    /// Reply `02 01`, u64 LE flags, then by flag bit: 0 a length-prefixed blob, 1 the serial number
    /// (NUL-terminated), 2 the hardware version, 3 the firmware version (both NUL-terminated),
    /// 4 a 7-byte PnP ID. nil for any other header or when no reading of the fields works.
    ///
    /// SPEC-GAP: §5.3 doesn't give the width of bit 0's length prefix, and the Helio's flags set
    /// bit 0. ZeppKit tries 1, 2 and 4 bytes (u8/u16/u32 LE). A width counts only if every field
    /// the flags announce up to the PnP ID parses: strings NUL-terminated, valid UTF-8, with no
    /// control characters, and the PnP ID complete. The versions are reported only when all the
    /// widths that count agree on them; otherwise the reply is ambiguous and none is reported.
    public static func parse(_ payload: [UInt8]) -> ZeppDeviceInfo? {
        guard payload.count >= 10, payload[0] == 0x02, payload[1] == 0x01 else { return nil }
        var header = ZeppByteReader(payload, offset: 2)
        guard let flags = header.u64() else { return nil }
        let widths = flags & 0x01 == 0 ? [0] : [1, 2, 4]
        var readings = [(width: Int, hardware: String?, firmware: String?)]()
        for width in widths {
            if let fields = versions(payload, flags: flags, blobPrefixWidth: width) {
                readings.append((width, fields.hardware, fields.firmware))
            }
        }
        guard let first = readings.first else { return nil }
        let agree = readings.allSatisfy { $0.hardware == first.hardware && $0.firmware == first.firmware }
        return ZeppDeviceInfo(flags: flags, hardwareVersion: agree ? first.hardware : nil,
                              firmwareVersion: agree ? first.firmware : nil,
                              blobPrefixWidths: readings.map(\.width), isAmbiguous: !agree)
    }

    private static func versions(_ payload: [UInt8], flags: UInt64, blobPrefixWidth: Int)
        -> (hardware: String?, firmware: String?)? {
        var reader = ZeppByteReader(payload, offset: 10)
        if flags & 0x01 != 0 {
            let length: Int?
            switch blobPrefixWidth {
            case 1: length = reader.u8().map(Int.init)
            case 2: length = reader.u16().map(Int.init)
            default: length = reader.u32().map(Int.init)
            }
            guard let length, reader.skip(length) else { return nil }
        }
        // The serial number is read only to find where it ends; it is dropped here.
        if flags & 0x02 != 0, printableString(&reader) == nil { return nil }
        var hardware: String?
        var firmware: String?
        if flags & 0x04 != 0 {
            guard let value = printableString(&reader) else { return nil }
            hardware = value
        }
        if flags & 0x08 != 0 {
            guard let value = printableString(&reader) else { return nil }
            firmware = value
        }
        // The PnP ID must fit; its bytes are not kept.
        if flags & 0x10 != 0, !reader.skip(7) { return nil }
        return (hardware, firmware)
    }

    /// Strict: NUL-terminated, valid UTF-8, no control characters.
    private static func printableString(_ reader: inout ZeppByteReader) -> String? {
        guard let end = reader.bytes[reader.offset...].firstIndex(of: 0),
              let raw = reader.take(end - reader.offset), reader.skip(1),
              let text = String(bytes: raw, encoding: .utf8),
              text.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) else { return nil }
        return text
    }
}

// MARK: - Battery (endpoint 0x0029, §5.3)

public struct ZeppBatteryStatus: Equatable {
    /// Percent, 0–100.
    public let level: Int
    /// nil when the charging byte is neither `00` nor `01`.
    public let isCharging: Bool?
    /// When the strap was last charged, if the reply carries a valid date.
    public let lastCharge: Date?
    /// Level at the last charge, percent, if present and 0–100.
    public let lastChargeLevel: Int?

    public static let request: [UInt8] = [0x03]

    /// Reply `04` + 20 bytes. Offsets are relative to the full reply: `[2]` level, `[3]` charging,
    /// `[11..18]` last-charge date (u16 year, month, day, h, m, s, i8 quarter-hour offset), `[20]`
    /// last-charge level. nil unless it starts with `04` and has a 0–100 level.
    public static func parse(_ payload: [UInt8]) -> ZeppBatteryStatus? {
        guard payload.count >= 4, payload[0] == 0x04, payload[2] <= 100 else { return nil }
        let charging: Bool?
        switch payload[3] {
        case 0x00: charging = false
        case 0x01: charging = true
        default: charging = nil
        }
        let lastCharge = payload.count >= 19 ? ZeppFetchTimestamp.decode(payload[11..<19]) : nil
        var lastLevel: Int?
        if payload.count >= 21, payload[20] <= 100 { lastLevel = Int(payload[20]) }
        return ZeppBatteryStatus(level: Int(payload[2]), isCharging: charging,
                                 lastCharge: lastCharge, lastChargeLevel: lastLevel)
    }
}

// MARK: - Heart-rate control (endpoint 0x001D, §7.1)

public enum ZeppHeartRateControl {
    public static let start: [UInt8] = [0x04, 0x01]
    /// Must be re-sent every second to keep the stream running.
    public static let keepRunning: [UInt8] = [0x04, 0x02]
    public static let stop: [UInt8] = [0x04, 0x00]

    public enum Event: Equatable {
        /// `05 <status>`; `00` observed as success.
        case controlReply(status: UInt8)
        /// `06 01`.
        case fellAsleep
        /// `06 00`.
        case wokeUp
    }

    public static func parse(_ payload: [UInt8]) -> Event? {
        guard payload.count >= 2 else { return nil }
        switch (payload[0], payload[1]) {
        case (0x05, let status): return .controlReply(status: status)
        case (0x06, 0x01): return .fellAsleep
        case (0x06, 0x00): return .wokeUp
        default: return nil
        }
    }
}

// MARK: - Standard GATT live data (§7.1, §7.3)

/// A Heart Rate Measurement (`0x2A37`) notification, per the Bluetooth Heart Rate Service spec.
public struct ZeppHeartRateMeasurement: Equatable {
    public let beatsPerMinute: Int
    /// nil when the sensor does not report contact.
    public let sensorContact: Bool?
    public let energyExpendedKilojoules: Int?
    /// RR intervals in seconds (wire unit 1/1024 s).
    public let rrIntervals: [Double]

    public static func parse(_ bytes: [UInt8]) -> ZeppHeartRateMeasurement? {
        var reader = ZeppByteReader(bytes)
        guard let flags = reader.u8() else { return nil }
        let bpm: Int
        if flags & 0x01 != 0 {
            guard let value = reader.u16() else { return nil }
            bpm = Int(value)
        } else {
            guard let value = reader.u8() else { return nil }
            bpm = Int(value)
        }
        let contactSupported = flags & 0x04 != 0
        let contact: Bool? = contactSupported ? (flags & 0x02 != 0) : nil
        var energy: Int?
        if flags & 0x08 != 0 {
            guard let value = reader.u16() else { return nil }
            energy = Int(value)
        }
        var rr = [Double]()
        if flags & 0x10 != 0 {
            while reader.remaining >= 2, let value = reader.u16() {
                rr.append(Double(value) / 1024)
            }
        }
        return ZeppHeartRateMeasurement(beatsPerMinute: bpm, sensorContact: contact,
                                        energyExpendedKilojoules: energy, rrIntervals: rr)
    }
}

public enum ZeppBatteryLevelCharacteristic {
    /// `0x2A19`: one byte, 0–100.
    public static func parse(_ bytes: [UInt8]) -> Int? {
        guard let level = bytes.first, level <= 100 else { return nil }
        return Int(level)
    }
}

// MARK: - Config (endpoint 0x000A, §5.5)
//
// Reads, plus a validated single-argument write builder for the haptic alerts (§13.4, §15.3). This
// file never decides to write: `ZeppHapticAlertSettings` only builds a write for a value the strap
// itself offered.

public enum ZeppConfigValue: Hashable {
    case bool(Bool)
    case byte(UInt8)
    case byteList([UInt8])
    case short(Int16)
    case shortList([Int16])
    case int(Int32)
    case string(String)
    case hourMinute(hour: UInt8, minute: UInt8)
    /// Milliseconds since 1970.
    case timestamp(Int64)
    case unboundedInt(Int32)
}

/// The constraint bytes a read with include-constraints `01` carries after an entry's value (§5.5
/// table, placed after the value by §13.4).
public enum ZeppConfigConstraint: Equatable {
    /// byte (`0x10`) and byte list (`0x11`): the values the strap accepts.
    case allowedValues([UInt8])
    /// short (`0x01`).
    case shortRange(min: Int16, max: Int16)
    /// short list (`0x02`).
    case shortList(minCount: UInt8, maxCount: UInt8, min: Int16, max: Int16)
    /// int (`0x03`).
    case intRange(min: Int32, max: Int32)
    /// string (`0x20`).
    case maxLength(UInt8)
    /// string list (`0x21`).
    case stringChoices(maxLength: UInt8, choices: [String])
}

public struct ZeppConfigEntry: Equatable {
    public let argument: UInt8
    /// The value's case also names the wire type (`.bool` = `0x0b`, `.byte` = `0x10`, …).
    public let value: ZeppConfigValue
    /// nil when the read did not include constraints, or the type carries none.
    public var constraint: ZeppConfigConstraint? = nil
}

public struct ZeppConfigReadReply: Equatable {
    public let group: UInt8
    public let groupVersion: UInt8
    public let entries: [ZeppConfigEntry]
    /// True when parsing stopped early (an unknown type code or a truncated entry): `entries`
    /// holds what was parsed before that point (§5.5).
    public let isPartial: Bool
    /// The reply's include-constraints byte was `01`.
    public var includesConstraints: Bool = false
}

/// Config capabilities reply (§5.5): `02`, u8 service version, u8 group count, group ids.
public struct ZeppConfigCapabilities: Equatable {
    public let serviceVersion: UInt8
    public let groups: [UInt8]

    /// §5.5: service versions up to 3 are understood.
    public var isVersionUnderstood: Bool { serviceVersion <= 3 }

    /// Request payload: `01`.
    public static let request: [UInt8] = [0x01]

    /// nil unless it starts with `02` and holds every group id it announces.
    public static func parse(_ payload: [UInt8]) -> ZeppConfigCapabilities? {
        var reader = ZeppByteReader(payload)
        guard reader.u8() == 0x02, let version = reader.u8(), let count = reader.u8(),
              let groups = reader.take(Int(count)) else { return nil }
        return ZeppConfigCapabilities(serviceVersion: version, groups: groups)
    }
}

public enum ZeppConfig {

    /// The HEALTH settings group.
    public static let healthGroup: UInt8 = 0x08

    public enum HealthArgument {
        public static let heartRateMonitoring: UInt8 = 0x01
        /// "Active HR monitoring": raises the HR sampling rate during detected activity. It does NOT
        /// gate recording: on the Helio it read off while every minute of a 12 h activity fetch
        /// carried a heart rate (§5.5). Informational only.
        public static let heartRateDuringActivity: UInt8 = 0x04
        /// "Share HR with third parties" (🔴, §5.5). NOT Heart Rate Broadcast, which is `0x83`.
        public static let heartRateSharing: UInt8 = 0x05
        public static let highAccuracySleep: UInt8 = 0x11
        public static let sleepBreathingQuality: UInt8 = 0x12
        public static let stressMonitoring: UInt8 = 0x13
        public static let allDaySpO2: UInt8 = 0x31
        /// Heart Rate Broadcast (Zepp's switch, formerly "Heart Rate Push"), bool: live heart rate to
        /// other apps and devices (🟢 §5.5, §18.9). Not a recording switch.
        public static let heartRateBroadcast: UInt8 = 0x83
    }

    /// The HEALTH arguments whose off state means a fetch type comes back empty.
    public static let recordingArguments: [UInt8] = [
        HealthArgument.heartRateMonitoring, HealthArgument.heartRateSharing,
        HealthArgument.highAccuracySleep, HealthArgument.sleepBreathingQuality,
        HealthArgument.stressMonitoring, HealthArgument.allDaySpO2,
    ]

    /// HEALTH arguments read for information only: they change how the strap samples, not whether
    /// it records.
    public static let informationalArguments: [UInt8] = [HealthArgument.heartRateDuringActivity]

    /// What to read from HEALTH after auth: the recording switches plus the informational settings,
    /// in the order HelioVerify already sent on hardware (§10.1 item 8).
    public static let healthReadArguments: [UInt8] = [
        HealthArgument.heartRateMonitoring, HealthArgument.heartRateDuringActivity,
        HealthArgument.heartRateSharing, HealthArgument.highAccuracySleep,
        HealthArgument.sleepBreathingQuality, HealthArgument.stressMonitoring,
        HealthArgument.allDaySpO2,
    ]

    /// `03`, include-constraints `00`, group, arg count, args.
    /// SPEC-GAP: arg count `00` "asks for all args" is 🔴; ZeppKit always names the arguments.
    public static func readRequest(group: UInt8, arguments: [UInt8]) -> [UInt8] {
        readRequest(group: group, arguments: arguments, includeConstraints: false)
    }

    /// `03`, include-constraints (`01`/`00`), group, arg count, args (§5.5, example H in §13.4).
    public static func readRequest(group: UInt8, arguments: [UInt8], includeConstraints: Bool) -> [UInt8] {
        [0x03, includeConstraints ? 0x01 : 0x00, group, UInt8(clamping: arguments.count)] + arguments
    }

    /// `05`, group, group version, `00`, entry count, entries (value only, no constraints). One
    /// message per group (§5.5). Only bool and byte values are encoded: the only types ZeppKit writes
    /// (§13.4's alert thresholds and switches). nil for any other value type or an empty list.
    public static func writeRequest(group: UInt8, groupVersion: UInt8,
                                    entries: [(argument: UInt8, value: ZeppConfigValue)]) -> [UInt8]? {
        guard !entries.isEmpty, entries.count <= Int(UInt8.max) else { return nil }
        var out: [UInt8] = [0x05, group, groupVersion, 0x00, UInt8(entries.count)]
        for entry in entries {
            switch entry.value {
            case .bool(let on): out += [entry.argument, 0x0b, on ? 0x01 : 0x00]
            case .byte(let value): out += [entry.argument, 0x10, value]
            default: return nil
            }
        }
        return out
    }

    /// Write ack `06 <status>`: the status byte, or nil when the payload is not a write ack.
    public static func parseWriteAck(_ payload: [UInt8]) -> UInt8? {
        guard payload.count >= 2, payload[0] == 0x06 else { return nil }
        return payload[1]
    }

    /// Reply: `04`, status (`01` ok), group, group version, includes-constraints, entry count,
    /// entries. nil unless the header is intact and the status is `01`.
    public static func parseReadReply(_ payload: [UInt8]) -> ZeppConfigReadReply? {
        var reader = ZeppByteReader(payload)
        guard reader.u8() == 0x04, reader.u8() == 0x01,
              let group = reader.u8(), let version = reader.u8(),
              let constraintsByte = reader.u8(), let count = reader.u8() else { return nil }
        let withConstraints = constraintsByte == 0x01
        var entries = [ZeppConfigEntry]()
        for _ in 0..<Int(count) {
            guard let entry = parseEntry(&reader, withConstraints: withConstraints) else {
                return ZeppConfigReadReply(group: group, groupVersion: version, entries: entries, isPartial: true,
                                           includesConstraints: withConstraints)
            }
            entries.append(entry)
        }
        return ZeppConfigReadReply(group: group, groupVersion: version, entries: entries, isPartial: false,
                                   includesConstraints: withConstraints)
    }

    private static func parseEntry(_ r: inout ZeppByteReader, withConstraints: Bool) -> ZeppConfigEntry? {
        guard let argument = r.u8(), let type = r.u8() else { return nil }
        let value: ZeppConfigValue
        var constraint: ZeppConfigConstraint?
        // Constraint bytes follow the value (§13.4, filling in where §5.5 was silent).
        switch type {
        case 0x0b:
            guard let raw = r.u8(), raw <= 1 else { return nil }
            value = .bool(raw == 1)
        case 0x10:
            guard let raw = r.u8() else { return nil }
            if withConstraints {
                guard let n = r.u8(), let allowed = r.take(Int(n)) else { return nil }
                constraint = .allowedValues(allowed)
            }
            value = .byte(raw)
        case 0x11:
            guard let n = r.u8(), let list = r.take(Int(n)) else { return nil }
            if withConstraints {
                guard let m = r.u8(), let allowed = r.take(Int(m)) else { return nil }
                constraint = .allowedValues(allowed)
            }
            value = .byteList(list)
        case 0x01:
            guard let raw = r.i16() else { return nil }
            if withConstraints {
                guard let min = r.i16(), let max = r.i16() else { return nil }
                constraint = .shortRange(min: min, max: max)
            }
            value = .short(raw)
        case 0x02:
            guard let n = r.u8() else { return nil }
            var list = [Int16]()
            for _ in 0..<Int(n) {
                guard let item = r.i16() else { return nil }
                list.append(item)
            }
            if withConstraints {
                guard let minCount = r.u8(), let maxCount = r.u8(), let min = r.i16(), let max = r.i16() else { return nil }
                constraint = .shortList(minCount: minCount, maxCount: maxCount, min: min, max: max)
            }
            value = .shortList(list)
        case 0x03:
            guard let raw = r.i32() else { return nil }
            if withConstraints {
                guard let min = r.i32(), let max = r.i32() else { return nil }
                constraint = .intRange(min: min, max: max)
            }
            value = .int(raw)
        case 0x20:
            guard let text = r.nulTerminatedString() else { return nil }
            if withConstraints {
                guard let maxLength = r.u8() else { return nil }
                constraint = .maxLength(maxLength)
            }
            value = .string(text)
        case 0x21:
            guard let text = r.nulTerminatedString() else { return nil }
            if withConstraints {
                guard let maxLength = r.u8(), let n = r.u8() else { return nil }
                var choices = [String]()
                for _ in 0..<Int(n) {
                    guard let choice = r.nulTerminatedString() else { return nil }
                    choices.append(choice)
                }
                constraint = .stringChoices(maxLength: maxLength, choices: choices)
            }
            value = .string(text)
        case 0x30:
            guard let hour = r.u8(), let minute = r.u8() else { return nil }
            value = .hourMinute(hour: hour, minute: minute)
        case 0x40:
            guard let raw = r.i64() else { return nil }
            value = .timestamp(raw)
        case 0x50:
            guard let raw = r.i32() else { return nil }
            value = .unboundedInt(raw)
        default:
            // No length field: an unknown type makes the rest unparseable (§5.5).
            return nil
        }
        return ZeppConfigEntry(argument: argument, value: value, constraint: constraint)
    }
}

/// The HEALTH switches that decide what the strap RECORDS (§5.5), read after auth so the user can
/// be warned instead of silently fetching nothing, plus the settings that only change how it
/// samples (`informational`).
public struct ZeppHealthSettings: Equatable {
    /// `00` off, `ff` automatic, `N` every N minutes; nil when not reported.
    public let heartRateMonitoring: UInt8?
    /// Arg `0x04`, "Active HR monitoring": a sampling boost during activity, not a recording switch
    /// (§5.5). Never warned about; see `informational`.
    public let heartRateDuringActivity: Bool?
    public let heartRateSharing: Bool?
    public let highAccuracySleep: Bool?
    public let sleepBreathingQuality: Bool?
    public let stressMonitoring: Bool?
    public let allDaySpO2: Bool?

    public init(_ reply: ZeppConfigReadReply) {
        func bool(_ arg: UInt8) -> Bool? {
            for entry in reply.entries where entry.argument == arg {
                if case .bool(let v) = entry.value { return v }
            }
            return nil
        }
        var monitoring: UInt8?
        for entry in reply.entries where entry.argument == ZeppConfig.HealthArgument.heartRateMonitoring {
            if case .byte(let v) = entry.value { monitoring = v }
        }
        heartRateMonitoring = monitoring
        heartRateDuringActivity = bool(ZeppConfig.HealthArgument.heartRateDuringActivity)
        heartRateSharing = bool(ZeppConfig.HealthArgument.heartRateSharing)
        highAccuracySleep = bool(ZeppConfig.HealthArgument.highAccuracySleep)
        sleepBreathingQuality = bool(ZeppConfig.HealthArgument.sleepBreathingQuality)
        stressMonitoring = bool(ZeppConfig.HealthArgument.stressMonitoring)
        allDaySpO2 = bool(ZeppConfig.HealthArgument.allDaySpO2)
    }

    /// One line per recording switch that is OFF, naming what will come back empty. Settings the
    /// strap did not report are not warned about (unknown is not off).
    public var warnings: [String] {
        var out = [String]()
        if heartRateMonitoring == 0x00 { out.append("all-day heart-rate monitoring is off: activity HR, resting/max HR and HRV may be empty") }
        if heartRateSharing == false { out.append("heart-rate sharing with third parties (HEALTH 05) is off; what it controls is unconfirmed, and it is not Heart Rate Broadcast (HEALTH 83)") }
        if highAccuracySleep == false { out.append("high-accuracy sleep monitoring is off: sleep staging may be missing") }
        if sleepBreathingQuality == false { out.append("sleep breathing-quality monitoring is off: sleep SpO2 / respiratory rate may be empty") }
        if stressMonitoring == false { out.append("stress monitoring is off: stress (auto) will be empty") }
        if allDaySpO2 == false { out.append("all-day SpO2 monitoring is off: automatic SpO2 will be empty") }
        return out
    }

    /// One line per reported setting that changes how the strap samples but not what it records.
    /// Not warnings: either value is fine.
    public var informational: [String] {
        var out = [String]()
        if let on = heartRateDuringActivity {
            out.append("Active HR monitoring (sampling boost during activity): \(on ? "on" : "off")")
        }
        return out
    }
}

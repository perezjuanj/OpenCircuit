// BulkSleep.swift — decoder for 0x4c bulk activity/sleep page records.
//
// PROTOCOL.md §5.3 (FW FR02.018, 🟢 confirmed structure):
//   Page:   [0]=0x4c · [1]=0x00 · [2]=remaining-record countdown · body=6×23-byte records · [last]=XOR
//   Record: [0]=0x0c · [1:4]=BE counter (+0x96/rec in cursor space) · [8]=subtype tag (idle: 0x12/0x13)
//           · [10:15]=baseline 0x01×5 · [15:22]=7-byte payload (zero idle, dense worn) · [22]=flags
//   Idle template (🟢): bytes[4:8]=05 00 0c 00, bytes[9]=0x0a, bytes[10:15]=0x01×5, bytes[15:22]=0x00×7
//
// Payload semantics (HR, HRV, SpO2 byte positions) are 🔴 unconfirmed — ground-truth
// capture needed (PROTOCOL.md §6, item 2: "one fully app-logged night"). Nothing
// here is invented; fields are scaffolded with explicit 🔴 tags and conservative
// validity guards until captures decode them.
//
// Fix (#39): layout is determined by the confirmed idle-template check, NOT by
// whether bytes[9] falls in a SpO2 range. The old approach (checking 87–99 as the
// layout gate) would silently drop any epoch with SpO2 < 87 — exactly the
// desaturation events clinically important for sleep-apnea screening.

import Foundation

// MARK: - Layout

/// Layout of a single 0x4c record.
/// Discrimination strategy: idle is detected via the confirmed 🟢 idle template;
/// everything else is provisionally sleepVitals until activityPayload can be
/// distinguished (pending a capture that isolates activity epochs, 🔴).
public enum BulkLayout: Equatable, Sendable {
    /// Unworn / no measurement. Template confirmed 🟢 (PROTOCOL.md §5.3).
    case idle
    /// Worn + sleep vitals (HR, HRV, SpO2). Byte positions within payload 🔴.
    case sleepVitals
    /// Worn + activity epoch. Not yet distinguishable from sleepVitals (🔴, pending capture).
    case activityPayload
    /// Corrupt / length mismatch.
    case unknown
}

// MARK: - BulkRecord

/// One decoded 23-byte record from a 0x4c bulk sleep/activity page.
public struct BulkRecord: Equatable, Sendable {

    /// The raw 23-byte record exactly as received (including the 0x0c delimiter).
    public let bytes: [UInt8]

    /// Classified layout for this record.
    public let layout: BulkLayout

    // MARK: Initialiser

    /// Parse a 23-byte 0x4c record. Returns nil if the length or delimiter is wrong.
    public init?(_ bytes: [UInt8]) {
        guard bytes.count == 23, bytes[0] == 0x0c else { return nil }
        self.bytes = bytes
        self.layout = BulkRecord.detectLayout(bytes)
    }

    // MARK: Layout detection

    /// Determine layout using the idle-template check (🟢), NOT the SpO2 value (#39 fix).
    private static func detectLayout(_ b: [UInt8]) -> BulkLayout {
        guard b.count == 23 else { return .unknown }

        if isIdleTemplate(b) { return .idle }

        // TODO(#39 / 🔴): distinguish .activityPayload from .sleepVitals once a
        // daytime-activity capture decodes the discriminating bytes. For now every
        // non-idle record is treated as sleepVitals so desaturation epochs are not
        // silently discarded.
        return .sleepVitals
    }

    /// Idle-template check. All conditions confirmed 🟢 (PROTOCOL.md §5.3).
    ///
    /// Template: bytes[4:8]=05 00 0c 00, bytes[9]=0x0a,
    ///           bytes[10:15]=0x01×5, bytes[15:22]=0x00×7.
    ///
    /// Subtype tag bytes[8]=0x12 or 0x13 is characteristic of idle but is NOT
    /// included as a strict gate here — the payload-zero check is sufficient and
    /// more robust (the tag could add a future variant without breaking detection).
    static func isIdleTemplate(_ b: [UInt8]) -> Bool {
        guard b.count == 23 else { return false }
        // bytes[4:8] = 05 00 0c 00
        guard b[4] == 0x05, b[5] == 0x00, b[6] == 0x0c, b[7] == 0x00 else { return false }
        // bytes[9] = 0x0a
        guard b[9] == 0x0a else { return false }
        // bytes[10:15] = 0x01×5
        guard b[10] == 0x01, b[11] == 0x01, b[12] == 0x01, b[13] == 0x01, b[14] == 0x01 else { return false }
        // bytes[15:22] = 0x00×7
        for i in 15..<22 {
            guard b[i] == 0x00 else { return false }
        }
        return true
    }

    // MARK: Metric properties (layout-gated)

    // ⚠️ All byte positions below are 🔴 provisional. The idle template at bytes[9]=0x0a
    // vs a non-zero value when worn suggests bytes[9] holds SpO2 (fits 87–99 for healthy
    // sleep, 70–99 pathological). HR and HRV positions in the 7-byte payload [15:22]
    // are entirely unconfirmed. Treat these as scaffolding until §6 item 2 is captured.

    /// Heart rate in bpm, or nil if not sleepVitals or byte is implausible.
    /// 🔴 Byte position provisional: bytes[15] (first byte of the 7-B payload).
    public var heartRateBPM: Int? {
        guard layout == .sleepVitals else { return nil }
        let bpm = Int(bytes[15])
        return (30...250).contains(bpm) ? bpm : nil   // plausible HR band
    }

    /// HRV (RMSSD, ms), or nil if not sleepVitals or byte is implausible.
    /// 🔴 Byte position provisional: bytes[16] (second byte of the 7-B payload).
    public var hrvRMSSD: Int? {
        guard layout == .sleepVitals else { return nil }
        let ms = Int(bytes[16])
        return ms > 0 ? ms : nil
    }

    /// SpO2 in whole-number percent (70–100), or nil if not sleepVitals.
    ///
    /// 🟡 Byte position: bytes[9] — idle template has 0x0a (10) here; non-idle worn
    /// records have values consistent with SpO2 (PROTOCOL.md §5.3 idle contrast).
    ///
    /// #39 fix: this property's value is GUARDED to 70–100 but the validity band
    /// does NOT gate layout detection. A 75% SpO2 epoch (apnea event) is still
    /// recognised as sleepVitals by detectLayout() and returns SpO2 here.
    public var spo2Percent: Int? {
        guard layout == .sleepVitals else { return nil }
        let raw = Int(bytes[9])
        // Guard to physiologically plausible SpO2 range (70–100).
        // Lower bound 70 catches severe desaturation; HealthKit accepts 0…1 fraction
        // so the caller divides by 100 before writing. Values below 70 or above 100
        // are sensor artefacts (ring not settled) — return nil rather than a bogus value.
        return (70...100).contains(raw) ? raw : nil
    }

    // MARK: Sync cursor

    /// Big-endian 3-byte counter from bytes[1:4], in the 0x96-step cursor space.
    /// 🟢 Structure confirmed; wall-clock mapping requires a §6 item 3 capture.
    public var counter: UInt32 {
        UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
    }
}

// MARK: - Page parsing

/// Parse a complete 0x4c page payload (after the 3-byte page header) into records.
///
/// `pageBody` should be the bytes between the page header ([0]=0x4c [1]=0x00 [2]=countdown)
/// and the trailing XOR byte. Each record is 23 bytes; incomplete trailing bytes are ignored.
///
/// ⚠️ Charging / off-wrist note (#41):
/// Idle records dominate when the ring is on the charger — the ring reads as perfectly
/// still in the gravity stream AND produces idle-layout 0x4c records with zero payload.
/// Motion-based sleep detection must be gated on wear state (temperature heuristic in
/// SleepDetection.swift) so charger epochs are not classified as sleep. The per-epoch
/// idle layout here is a secondary signal; the primary filter lives in WearDetection.
/// TODO(#41 protocol): also gate on the 0x10/0x87 descriptor charging-flag byte once
/// the BLE RingSession lane investigates the 0x10/0x87 [2] state enum (PROTOCOL.md §5.4).
public func parseBulkSleepPage(_ pageBody: [UInt8]) -> [BulkRecord] {
    let recordSize = 23
    var records: [BulkRecord] = []
    var offset = 0
    while offset + recordSize <= pageBody.count {
        let slice = Array(pageBody[offset..<(offset + recordSize)])
        if let rec = BulkRecord(slice) { records.append(rec) }
        offset += recordSize
    }
    return records
}

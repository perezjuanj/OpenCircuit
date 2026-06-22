import XCTest
@testable import OpenCircuitKit

/// Guard rail for the channel-`0x03` all-day drain (the fix for stale daytime SpO₂): its daytime
/// epochs must reach Apple Health as SpO₂/HR SAMPLES, but must NOT pollute sleep staging — a periodic
/// daytime SpO₂ reading (which decodes with the sleep-vitals layout) can never become "sleep".
/// The overnight scope gate in `latestNightRecords` is what keeps the two apart.
final class AllDayChannelTests: XCTestCase {
    let base = Date(timeIntervalSince1970: 1_780_000_000)   // ~2026, comfortably after syncEpoch

    /// Build one 23-byte 0x4c record. `spo2Byte` at `[8]`: a sleep-vitals SpO₂ value (0x57–0x63) makes
    /// it an SpO₂-bearing epoch; the `0x12` activity tag makes it an awake/activity epoch (no SpO₂).
    private func record(at date: Date, hr: UInt8, spo2Byte: UInt8, still: Bool) -> BulkRecord {
        let counter = UInt32(Int(date.timeIntervalSince1970) - Command.syncEpoch)
        var b = [UInt8](repeating: 0, count: BulkRecord.length)
        b[0] = UInt8((counter >> 24) & 0xff); b[1] = UInt8((counter >> 16) & 0xff)
        b[2] = UInt8((counter >> 8) & 0xff);  b[3] = UInt8(counter & 0xff)
        b[4] = hr
        b[8] = spo2Byte
        if still { for k in 10 ..< 15 { b[k] = 1 } }          // still baseline
        else { b[10] = 8; b[11] = 12; b[12] = 20; b[13] = 6; b[14] = 10 }   // elevated motion (moving)
        return BulkRecord(b)!
    }

    /// Local midnight + `hour`:`min` on the day containing `base`.
    private func at(_ hour: Int, _ min: Int = 0) -> Date {
        let cal = Calendar.current
        return cal.date(byAdding: .minute, value: hour * 60 + min, to: cal.startOfDay(for: base))!
    }

    func testDaytimeAllDaySpo2ReachesSamplesButNotSleep() {
        var union: [BulkRecord] = []
        // Channel 0x00 — a real overnight night: ~4 h of still sleep-vitals epochs, 01:00–05:00 local
        // (overnight in every timezone, so `isOvernightBlock` passes regardless of CI locale).
        let sleepStart = at(1)
        for i in 0 ..< 96 {
            union.append(record(at: sleepStart.addingTimeInterval(Double(i) * 150),
                                hr: 55, spo2Byte: 0x62, still: true))
        }
        // Channel 0x03 — awake/all-day: 14:00–15:00 activity HR (moving), with a periodic SpO₂=98
        // reading every ~10 min (every 4th 2.5-min epoch), exactly as the captures show.
        let dayStart = at(14)
        for i in 0 ..< 24 {
            let t = dayStart.addingTimeInterval(Double(i) * 150)
            let isSpo2Epoch = (i % 4 == 0)
            union.append(record(at: t, hr: 75,
                                spo2Byte: isSpo2Epoch ? 0x62 : 0x12, still: isSpo2Epoch))
        }

        // 1) The daytime SpO₂ surfaces as SpO₂ samples → it will mirror to Apple Health.
        let samples = BulkSleep.samples(from: union)
        let daySpo2 = samples.filter { $0.kind == .spo2 && $0.start >= dayStart }
        XCTAssertEqual(daySpo2.count, 6, "one daytime SpO₂ reading per ~10 min reaches samples")
        XCTAssertTrue(daySpo2.allSatisfy { $0.value > 0.95 && $0.value <= 1.0 },
                      "daytime SpO₂ value decodes to ~98 %")

        // 2) Sleep staging scopes to the OVERNIGHT night only — the daytime epochs are excluded, so a
        // daytime SpO₂/still reading can never be staged as sleep.
        let nightRecords = BulkSleep.latestNightRecords(from: union)
        XCTAssertFalse(nightRecords.isEmpty)
        XCTAssertTrue(nightRecords.allSatisfy { $0.date() < at(12) },
                      "daytime channel-0x03 epochs must not enter the staged night")
        let segs = BulkSleep.sleepSegments(from: nightRecords)
        XCTAssertFalse(segs.isEmpty, "the overnight night is still detected")
        XCTAssertTrue(segs.allSatisfy { $0.end <= at(12) },
                      "no sleep segment lands in the daytime window")
    }
}

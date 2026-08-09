import XCTest
@testable import OpenCircuitKit

/// #195 — the two `0x4c` record facts settled from the wire in PROTOCOL.md §5.3:
///   • `[8] == 0x11` is a THIRD "no SpO2 here" sentinel (the ring's "nothing measured" block
///     terminator), while `0x00`/`0x0a`/`0x0e` are NOT and must keep falling through to
///     `.sleepVitals` (#39);
///   • `[15:23)` is five 12-bit big-endian magnitudes, nibble-packed, plus a 4-bit `info` flag.
///
/// The decode assertions are KNOWN-ANSWER tests over hand-built bytes: the nibbles are chosen so
/// that the field order, the nibble order inside a field, the field WIDTH and the flag's position
/// are each pinned by a value that no other packing can produce. No real capture bytes are needed
/// and none are used.
final class BulkRecordTailAndSentinelTests: XCTestCase {

    /// A 23-byte record with a controllable head and `[15:23)` block.
    /// `[0:4]` counter, `[4:8]` = HR/HRV/conf/RR, `[8]` the SpO2-or-sentinel byte, `[9]` = 0x0a,
    /// `[10:15]` motion, `[15:23)` the tail block under test.
    private func record(counter: UInt32 = 0x0c22a16b,
                        head: [UInt8] = [60, 50, 9, 120],
                        spo2Byte: UInt8,
                        motion: [UInt8] = [1, 1, 1, 1, 1],
                        tail: [UInt8]) -> BulkRecord {
        precondition(head.count == 4 && motion.count == 5 && tail.count == 8)
        var b: [UInt8] = [UInt8(counter >> 24), UInt8((counter >> 16) & 0xff),
                          UInt8((counter >> 8) & 0xff), UInt8(counter & 0xff)]
        b += head
        b += [spo2Byte, 0x0a]
        b += motion
        b += tail
        return BulkRecord(b)!
    }

    // MARK: - [15:23) — five 12-bit big-endian magnitudes + a 4-bit info flag

    func testActivityMagnitudesAreFiveTwelveBitBigEndianFieldsWithTheFlagLast() {
        // Nibbles 1 2 3 | 4 5 6 | 7 8 9 | A B C | D E F | 5  →  bytes 12 34 56 78 9A BC DE F5.
        // Every field is distinct and none is a palindrome, so a reversed nibble order, a
        // one-nibble phase shift, or a leading flag all produce different numbers.
        let r = record(spo2Byte: 97, tail: [0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF5])
        XCTAssertEqual(r.activityMagnitudes, [0x123, 0x456, 0x789, 0xABC, 0xDEF])
        XCTAssertEqual(r.activityInfoNibble, 0x5, "info is the LOW nibble of [22], not the high one")
    }

    func testActivityMagnitudesAreTwelveBitsWideNotSixteen() {
        // All-ones tail: a 12-bit field saturates at 4095. A 16-bit read would give 65535, and a
        // byte read would give 255.
        let r = record(spo2Byte: 97, tail: [UInt8](repeating: 0xFF, count: 8))
        XCTAssertEqual(r.activityMagnitudes, [4095, 4095, 4095, 4095, 4095])
        XCTAssertEqual(r.activityInfoNibble, 0xF)
    }

    func testTheFlagNibbleIsNotStolenFromTheLastMagnitude() {
        // Only [22] is set, to 0xA5. The high nibble belongs to magnitude 4, the low one is `info`.
        let r = record(spo2Byte: 97, tail: [0, 0, 0, 0, 0, 0, 0, 0xA5])
        XCTAssertEqual(r.activityMagnitudes, [0, 0, 0, 0, 0x00A])
        XCTAssertEqual(r.activityInfoNibble, 0x5)
    }

    func testActivityMagnitudesSeeMovementTheByteAlignedTailPredicateCannot() {
        // 🟢 THE 13.0 % CASE. `[15:20]` covers magnitudes 0–2 and only the top nibble of
        // magnitude 3, so movement recorded in magnitudes 3/4 (bytes 19-low…22-high) is invisible
        // to the legacy predicate. 253 of the 1950 corpus epochs it calls quiet are exactly this.
        let r = record(spo2Byte: 97, tail: [0, 0, 0, 0, 0, 0x0F, 0xF0, 0x00])
        XCTAssertTrue(r.motionIntensityTailIsZero, "[15:20] really is all zero here")
        XCTAssertEqual(r.activityMagnitudes, [0, 0, 0, 0x00F, 0xF00])
        XCTAssertFalse(r.activityMagnitudesAreZero, "the correct decode sees magnitudes 3 and 4")
    }

    func testLegacyTailPredicateIsNotRedefined() {
        // Three shipped calibrations are fitted to the byte-aligned population, so the old
        // predicate must keep its exact `[15:20]` window even where the correct decode disagrees.
        let quietUnderBoth = record(spo2Byte: 97, tail: [0, 0, 0, 0, 0, 0, 0, 0x04])
        XCTAssertTrue(quietUnderBoth.motionIntensityTailIsZero)
        XCTAssertTrue(quietUnderBoth.activityMagnitudesAreZero, "the info nibble is not a magnitude")

        let movingInsideTheWindow = record(spo2Byte: 97, tail: [0, 0, 0x10, 0, 0, 0, 0, 0])
        XCTAssertFalse(movingInsideTheWindow.motionIntensityTailIsZero)
        XCTAssertFalse(movingInsideTheWindow.activityMagnitudesAreZero)
    }

    // MARK: - [8] == 0x11, the third "no SpO2 here" sentinel

    func testZero11IsASentinelNotAnSpO2Reading() {
        // The corpus shape: 13 of 13 carry [4] == 0x04 (the ring's "<30 = PR unmeasured"), 12 of
        // 13 the whole dead head, and every one sits at the tail of a contiguous run.
        let r = record(head: [0x04, 0, 0, 0], spo2Byte: 0x11,
                       motion: [0x8a, 0x8a, 0x8a, 0x8a, 0x8a],
                       tail: [0, 0, 0, 0, 0, 0, 0, 0x04])
        XCTAssertEqual(r.layout, .activity, "0x11 is a sentinel, not a 17 % saturation")
        XCTAssertNil(r.spo2Percent)
        XCTAssertNil(r.heartRate, "[4] == 0x04 is below LiveHR.validBPM")
    }

    func testZero11DoesNotEmitSleepVitalsHRVOrRespiratoryRate() {
        // The one corpus 0x11 record that carries non-zero [5]/[7]. Before #195 it reached the
        // strict sleep-vitals accessors — an HRV and an RR on an epoch whose own HR is unmeasured.
        let r = record(head: [0x04, 0x2f, 0x03, 0x7d], spo2Byte: 0x11,
                       motion: [0x31, 0x2c, 0x9c, 0xa1, 0x19],
                       tail: [0x6b, 0xa2, 0x2c, 0x00, 0x01, 0xdf, 0x0f, 0x64])
        XCTAssertEqual(r.layout, .activity)
        XCTAssertNil(r.hrvRMSSD, "strict sleep-vitals HRV must not come off a sentinel epoch")
        XCTAssertNil(r.respiratoryRate)
    }

    func testOtherImpossibleSpO2BytesStaySleepVitals() {
        // 🟢 The wire says these are the OPPOSITE shape: 12 of the 16 sit in an SpO2 slot with an
        // activity epoch on both sides and 14 of 16 carry a plausible head. They are sleep-vitals
        // epochs whose SpO2 byte failed — the case #39's fall-through exists for.
        for sentinelCandidate in [UInt8(0x00), 0x0a, 0x0e] {
            let r = record(head: [91, 27, 9, 120], spo2Byte: sentinelCandidate,
                           motion: [0x14, 0x14, 0x14, 0x14, 0x14],
                           tail: [0, 0, 0, 0, 0, 0, 0, 0x04])
            XCTAssertEqual(r.layout, .sleepVitals, "0x\(String(sentinelCandidate, radix: 16)) is NOT a sentinel")
            XCTAssertEqual(r.heartRate, 91)
            XCTAssertEqual(r.hrvRMSSD, 27)
            XCTAssertNil(r.spo2Percent, "the impossible value is still range-guarded away")
        }
    }

    func testGenuineDesaturationBelow87PercentSurvives() {
        // #39's whole point: 0x50 = 80 % is a real, clinically interesting reading, not a tag.
        let r = record(head: [58, 61, 9, 121], spo2Byte: 0x50,
                       tail: [0, 0, 0, 0, 0, 0, 0, 0x04])
        XCTAssertEqual(r.layout, .sleepVitals)
        XCTAssertEqual(r.spo2Percent, 80)
        XCTAssertEqual(r.hrvRMSSD, 61)
    }

    // MARK: - Interaction with the #191 SpO2-cadence wake locator

    func testZero11BreaksTheSpO2CadenceInsteadOfExtendingIt() {
        // The ring alternates sleepVitals/activity 1:1 while it measures sleep. A 0x11 record read
        // as `.sleepVitals` looks like the next SpO2 read and EXTENDS the trusted run past the
        // point the ring actually stopped; read as the sentinel it is, two consecutive no-SpO2
        // epochs are the violation they really are.
        // Every 0x11 in the corpus is preceded by an ACTIVITY epoch, so this is the real shape.
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let times = (0 ..< 5).map { t0.addingTimeInterval(Double($0 * BulkRecord.epochSeconds)) }
        let dead = record(head: [0x04, 0, 0, 0], spo2Byte: 0x11,
                          motion: [0x8a, 0x8a, 0x8a, 0x8a, 0x8a],
                          tail: [0, 0, 0, 0, 0, 0, 0, 0x04])
        let layouts: [BulkRecord.Layout] = [.sleepVitals, .activity, .sleepVitals, .activity,
                                            dead.layout]
        let steps = SleepStaging.cadenceSteps(times: times, layouts: layouts)
        XCTAssertEqual(Array(steps.dropFirst().prefix(3)), [.alternating, .alternating, .alternating])
        XCTAssertEqual(steps[4], .violation, "activity → 0x11 is two no-SpO2 epochs in a row")
    }
}

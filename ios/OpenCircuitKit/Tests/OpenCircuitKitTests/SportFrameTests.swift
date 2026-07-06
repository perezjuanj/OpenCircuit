import XCTest
@testable import OpenCircuitKit

/// Ground-truth checks for the native sport-mode decode (#90), using a REAL captured 0x4e frame.
final class SportFrameTests: XCTestCase {

    /// Real yoga-workout frame captured 2026-07-06 (FR02.018): HR 0x4b=75, steps 0x00=0.
    /// XOR trailer 0x71 verified. `4e 0c 40 78 f2 4b 00 00 ce 7c 00 00 71`
    func testDecodesRealYogaFrame() {
        let frame: [UInt8] = [0x4e, 0x0c, 0x40, 0x78, 0xf2, 0x4b,
                              0x00, 0x00, 0xce, 0x7c, 0x00, 0x00, 0x71]
        let s = SportFrame.decode(frame)
        XCTAssertEqual(s?.hr, 75)
        XCTAssertEqual(s?.steps, 0)
        XCTAssertEqual(s?.cursor, 0x0c4078f2)
    }

    /// A walking interval: HR 90, 17 steps in the window (hand-built, valid XOR = 0x05).
    func testDecodesSteps() {
        let frame: [UInt8] = [0x4e, 0x00, 0x00, 0x00, 0x00, 0x5a,
                              0x11, 0x00, 0x00, 0x00, 0x00, 0x00, 0x05]
        let s = SportFrame.decode(frame)
        XCTAssertEqual(s?.hr, 90)
        XCTAssertEqual(s?.steps, 17)
    }

    /// A bad XOR trailer must be rejected (never fabricate a sample from a corrupt frame).
    func testRejectsBadChecksum() {
        var frame: [UInt8] = [0x4e, 0x0c, 0x40, 0x78, 0xf2, 0x4b,
                              0x00, 0x00, 0xce, 0x7c, 0x00, 0x00, 0x71]
        frame[12] = 0x00   // corrupt the trailer
        XCTAssertNil(SportFrame.decode(frame))
    }

    /// Non-sport opcodes and warm-up HR: opcode gate returns nil; a sub-band HR yields nil HR but
    /// still surfaces steps (steps aren't gated on HR).
    func testOpcodeAndHRBandGates() {
        XCTAssertNil(SportFrame.decode([0x15, 0x00, 0x4b, 0x0a, 0xb0, 0xd0]))  // wrong opcode
        // HR byte 8 (warm-up sentinel, < minValidBPM) → hr nil, steps=3. XOR of first 12 = 0x?? ...
        let warm: [UInt8] = [0x4e, 0x00, 0x00, 0x00, 0x00, 0x08, 0x03,
                             0x00, 0x00, 0x00, 0x00, 0x00, 0x4e ^ 0x08 ^ 0x03]
        let s = SportFrame.decode(warm)
        XCTAssertNotNil(s)
        XCTAssertNil(s?.hr)
        XCTAssertEqual(s?.steps, 3)
    }

    /// The sport commands must be the exact captured bytes.
    func testSportCommandBytes() {
        XCTAssertEqual(Command.sportStart(0x02), [0x06, 0x03, 0x02, 0x04, 0x00])  // outdoor walk
        XCTAssertEqual(Command.sportStart(0x07), [0x06, 0x03, 0x07, 0x04, 0x00])  // yoga
        XCTAssertEqual(Command.sportStop, [0x06, 0x00, 0x00])
        XCTAssertEqual(Command.sportStreamAck, [0xCE, 0x00, 0x00])
        XCTAssertEqual(Command.findRingLight, [0x20, 0x01, 0x00])
        XCTAssertEqual(Command.findRingLightOff, [0x20, 0x00, 0x00])   // 🟡 probable off (on/off convention)
        XCTAssertEqual(Command.findRingSearch, [0x24, 0x01, 0x00])
        XCTAssertEqual(Command.findRingSearchStop, [0x24, 0x00, 0x00]) // 🟡 probable
        XCTAssertEqual(Command.airplaneModeOn, [0x08, 0x04, 0x00])
    }

    /// SportType byte mapping matches the captured enum (0x01..0x07).
    func testSportTypeBytes() {
        XCTAssertEqual(SportType.outdoorRunning.rawValue, 0x01)
        XCTAssertEqual(SportType.outdoorWalking.rawValue, 0x02)
        XCTAssertEqual(SportType.indoorRunning.rawValue,  0x03)
        XCTAssertEqual(SportType.outdoorCycling.rawValue, 0x04)
        XCTAssertEqual(SportType.indoorCycling.rawValue,  0x05)
        XCTAssertEqual(SportType.indoorRowing.rawValue,   0x06)
        XCTAssertEqual(SportType.yoga.rawValue,           0x07)
    }
}

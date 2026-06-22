import XCTest
@testable import OpenCircuitKit

// Fixtures are REAL frames pulled from the FR02.018 reference capture
// (desktop/captures/btsnoop_hci.log) — not hand-authored. They mirror the
// self-checks in framing.py so the Swift port is provably byte-identical.
final class FrameTests: XCTestCase {

    func hex(_ s: String) -> [UInt8] {
        var out = [UInt8](); var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!); i = j
        }
        return out
    }

    // Real validated notify frames (opcode → full hex) from the capture.
    let realFrames = [
        "8100b031", "82000082", "860086", "1500080ab0a7",
        "874e0400000000fd00fd00000000100c0b9e44",
        "104e0100000000fd00fd00000000100c0bffb7",
    ]

    func testXorTrailerValidatesResponses() {
        // XOR trailer applies to RESPONSES: 81^00^b0 = 31.
        XCTAssertEqual(Frame.xorTrailer([0x81, 0x00, 0xB0]), 0x31)
    }

    func testCommandsAreVerbatimNotChecksummed() {
        // The real poll is 95 00 00 (NOT the GB-guessed XOR'd 95 00 95).
        XCTAssertEqual(Command.poll, [0x95, 0x00, 0x00])
        XCTAssertNotEqual(Command.poll.last, Frame.xorTrailer([0x95, 0x00]))
        XCTAssertEqual(Command.syncAll, [0x02, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x01, 0x00])
    }

    func testRealFramesValidate() {
        for f in realFrames {
            XCTAssertTrue(Frame.isValid(hex(f)), "should validate: \(f)")
        }
    }

    func testCorruptedFrameRejected() {
        var bad = hex("8100b031"); bad[1] ^= 0xFF
        XCTAssertFalse(Frame.isValid(bad))
        XCTAssertNil(Frame.parse(bad))
        XCTAssertFalse(Frame.isValid([]))
        XCTAssertFalse(Frame.isValid([0x81]))
    }

    func testResponseIDRule() {
        // response = command XOR 0x80, across all 8 confirmed commands.
        let pairs: [(UInt8, UInt8)] = [
            (0x01, 0x81), (0x02, 0x82), (0x06, 0x86), (0x07, 0x87),
            (0x95, 0x15), (0xC7, 0x47), (0xCC, 0x4C), (0xD0, 0x50),
        ]
        for (cmd, resp) in pairs {
            XCTAssertEqual(Frame.responseID(cmd), resp)
            XCTAssertEqual(Frame.responseID(resp), cmd) // involutive
        }
    }

    func testParseSplitsOpcodeBodyTrailer() {
        let p = Frame.parse(hex("8100b031"))
        XCTAssertEqual(p, Frame.Parsed(opcode: 0x81, body: [0x00, 0xB0], trailer: 0x31))
    }

    func testLiveHRStartSequenceShape() {
        // Verified live order: status, status1, syncAll, liveHRMode, fetch.
        XCTAssertEqual(Command.liveHRStart.first, [0x01, 0x00, 0x00])
        XCTAssertEqual(Command.liveHRStart.last, [0x07, 0x00, 0x00])
        XCTAssertTrue(Command.liveHRStart.contains(Command.syncAll))
    }

    func testSyncCursorBuilder() {
        // cursor = unix − 1577793600, big-endian; matches a captured cursor.
        XCTAssertEqual(Command.syncSince(unixSeconds: Command.syncEpoch + 0x0c2298c3),
                       [0x02, 0x00, 0x0c, 0x22, 0x98, 0xc3, 0x00, 0x01, 0x00])
        // floors negative cursors to 0.
        XCTAssertEqual(Array(Command.syncSince(unixSeconds: 0)[2...5]), [0, 0, 0, 0])
    }

    func testSyncUpToNowOpensAtNowNotSyncAll() {
        // History sync opens at cursor ≈ now (the official app's behaviour, §3) — NEVER syncAll
        // (0xFFFFFFFF, a far-future cursor that returns an empty backlog and dropped sleep/HRV/RR).
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let open = Command.syncUpToNow(now: now)
        XCTAssertEqual(open, Command.syncSince(unixSeconds: 1_750_000_000))
        XCTAssertNotEqual(open, Command.syncAll)
        XCTAssertNotEqual(Array(open[2...5]), [0xFF, 0xFF, 0xFF, 0xFF], "cursor must be ≈now, not 0xFFFFFFFF")
        XCTAssertEqual(Array(open[0...1]), [0x02, 0x00])
        XCTAssertEqual(Array(open[6...8]), [0x00, 0x01, 0x00])
    }

    func testSyncOpenChannelSelectorLandsAtByte6() {
        // The channel selector (#99: 0x00 sleep, 0x03 all-day) is byte[6] of the 0x02 open — the
        // whole all-day-SpO₂ drain depends on 0x03 landing exactly there. Default stays 0x00.
        XCTAssertEqual(Command.syncChannelSleep, 0x00)
        XCTAssertEqual(Command.syncChannelAllDay, 0x03)
        let sleep = Command.syncSince(unixSeconds: Command.syncEpoch + 0x0c2298c3)
        XCTAssertEqual(sleep[6], 0x00, "default channel is the sleep log")
        let allDay = Command.syncSince(unixSeconds: Command.syncEpoch + 0x0c2298c3,
                                       channel: Command.syncChannelAllDay)
        XCTAssertEqual(allDay, [0x02, 0x00, 0x0c, 0x22, 0x98, 0xc3, 0x03, 0x01, 0x00])
        // Only byte[6] differs between the two channel opens at the same cursor.
        XCTAssertEqual(Array(allDay[0...5]), Array(sleep[0...5]))
        XCTAssertEqual(Array(allDay[7...8]), Array(sleep[7...8]))
        XCTAssertEqual(Command.syncUpToNow(now: Date(timeIntervalSince1970: 1_750_000_000),
                                           channel: Command.syncChannelAllDay)[6], 0x03)
    }

    func testLiveHRDecode() {
        // Real 0x15 frame from the capture: byte[2] = 0x5B = 91 bpm.
        XCTAssertEqual(LiveHR.decode(hex("15005b0ab0f4")), 91)
        XCTAssertNil(LiveHR.decode([]))
    }
}

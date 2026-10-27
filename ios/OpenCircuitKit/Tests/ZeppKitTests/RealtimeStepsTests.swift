// The realtime step stream's messages (ZEPP_PROTOCOL.md §7.2, §16.2 row 5), from synthetic frames
// built from the spec's layout: `07` + 13 bytes, steps = u16 LE at offset 1 of the 13; the ack
// `06 <status> <enabled>`.

import XCTest
@testable import ZeppKit

final class RealtimeStepsTests: XCTestCase {

    /// `07`, then 13 body bytes with `steps` at body offset 1 (payload offset 2) and filler elsewhere.
    private func frame(steps: UInt16, filler: UInt8 = 0xAA, bodyLength: Int = 13) -> [UInt8] {
        var body = [UInt8](repeating: filler, count: bodyLength)
        if bodyLength >= 3 {
            body[1] = UInt8(steps & 0xff)
            body[2] = UInt8(steps >> 8)
        }
        return [0x07] + body
    }

    func testTheCommandsAreFiveOneOnAndFiveZeroOff() {
        XCTAssertEqual(ZeppRealtimeSteps.enable, [0x05, 0x01])
        XCTAssertEqual(ZeppRealtimeSteps.disable, [0x05, 0x00])
    }

    func testAStepFrameReadsTheCounterAsU16LittleEndianAtBodyOffsetOne() {
        let cases: [(UInt16, String)] = [(0, "zero"), (1, "one"), (1_000, "low and high byte"),
                                         (0x1234, "byte order"), (UInt16.max, "u16 max")]
        for (steps, label) in cases {
            XCTAssertEqual(ZeppRealtimeSteps.parse(frame(steps: steps)), .steps(steps), label)
        }
        // The filler around the counter (body offsets 0 and 3…12) never leaks into it.
        XCTAssertEqual(ZeppRealtimeSteps.parse(frame(steps: 500, filler: 0xFF)), .steps(500))
        XCTAssertEqual(ZeppRealtimeSteps.parse(frame(steps: 500, filler: 0x00)), .steps(500))
    }

    func testAShortStepFrameIsRefusedAndALongerOneReadsByTheSameLayout() {
        XCTAssertNil(ZeppRealtimeSteps.parse(frame(steps: 500, bodyLength: 12)))
        XCTAssertNil(ZeppRealtimeSteps.parse([0x07]))
        XCTAssertEqual(ZeppRealtimeSteps.parse(frame(steps: 500, bodyLength: 16)), .steps(500))
    }

    func testTheAckCarriesItsStatusAndEnabledBytesUninterpreted() {
        XCTAssertEqual(ZeppRealtimeSteps.parse([0x06, 0x01, 0x01]), .ack(status: 0x01, enabled: 0x01))
        XCTAssertEqual(ZeppRealtimeSteps.parse([0x06, 0x01, 0x00]), .ack(status: 0x01, enabled: 0x00))
        XCTAssertEqual(ZeppRealtimeSteps.parse([0x06, 0x02]), .ack(status: 0x02, enabled: nil))
        XCTAssertNil(ZeppRealtimeSteps.parse([0x06]))
    }

    func testAnyOtherOpcodeOrAnEmptyPayloadIsNotAStepMessage() {
        XCTAssertNil(ZeppRealtimeSteps.parse([]))
        XCTAssertNil(ZeppRealtimeSteps.parse([0x05, 0x01]))
        XCTAssertNil(ZeppRealtimeSteps.parse([0x08] + [UInt8](repeating: 0, count: 13)))
    }
}

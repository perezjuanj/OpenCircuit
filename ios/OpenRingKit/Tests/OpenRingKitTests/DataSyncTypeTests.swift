import XCTest
@testable import OpenRingKit

// #99 — sync-open `byte[6]` (DataSyncType) selector probe. These cover the PURE pieces: the
// command builder (exact wire bytes), the candidate sweep set, the opcode classifier, and the
// report summarizer. The on-device behaviour (which selector returns all-day HR/SpO₂) is NOT
// testable here — that's the capture the probe exists to gather.

final class DataSyncTypeTests: XCTestCase {

    // The control selector (0x00) must reproduce the normal history open byte-for-byte, so the
    // probe's baseline is identical to a real sync and any difference is purely the selector byte.
    func testSelector0MatchesNormalSyncOpen() {
        let t = 1_800_000_000
        XCTAssertEqual(DataSyncProbe.syncOpen(unixSeconds: t, selector: 0x00),
                       Command.syncSince(unixSeconds: t))
    }

    // Frame shape: 02 00 <cursor BE4> <selector> 01 00. Selector lands at byte[6]; trailer 01 00.
    func testSyncOpenLayout() {
        let t = Command.syncEpoch + 0x0C2298C3   // → cursor 0c 22 98 c3 (a real captured cursor)
        let frame = DataSyncProbe.syncOpen(unixSeconds: t, selector: 0x0a)
        XCTAssertEqual(frame, [0x02, 0x00, 0x0c, 0x22, 0x98, 0xc3, 0x0a, 0x01, 0x00])
        XCTAssertEqual(frame[6], 0x0a, "selector must be byte[6]")
    }

    // Pre-2020 clocks clamp to 0 (not a wrapped negative) — fails safe like Command.syncSince.
    func testCursorClampsBelowEpoch() {
        let frame = DataSyncProbe.syncOpen(unixSeconds: 0, selector: 0x0b)
        XCTAssertEqual(Array(frame[2...5]), [0x00, 0x00, 0x00, 0x00])
        XCTAssertEqual(frame[6], 0x0b)
    }

    // The sweep must include the two controls, the old (inconclusive) sweep values, and — the
    // whole point of re-running it — the off_2c ring-data group the old sweep never tried.
    func testCandidateSetCoverage() {
        let bytes = Set(DataSyncProbe.candidates.map(\.byte))
        XCTAssertTrue(bytes.isSuperset(of: [0x00, 0x03]), "must keep both observed controls")
        XCTAssertTrue(bytes.isSuperset(of: [0x0a, 0x0b]), "must add off_2c hr/spo2 (the prime new candidates)")
        XCTAssertTrue(bytes.isSuperset(of: [0x0c, 0x0d]), "must add the rest of the off_2c group")
        // No duplicate selectors (each is probed once).
        XCTAssertEqual(bytes.count, DataSyncProbe.candidates.count)
    }

    func testFrameClassification() {
        XCTAssertEqual(ProbeFrameClass(opcode: 0x82), .syncOpenAck)
        XCTAssertEqual(ProbeFrameClass(opcode: 0x4c), .historyPage)
        XCTAssertEqual(ProbeFrameClass(opcode: 0x47), .historyPage)
        XCTAssertEqual(ProbeFrameClass(opcode: 0x50), .endOfHistory)
        XCTAssertEqual(ProbeFrameClass(opcode: 0x10), .descriptor)
        XCTAssertEqual(ProbeFrameClass(opcode: 0x15), .liveSample)
        XCTAssertEqual(ProbeFrameClass(opcode: 0x81), .authChallenge)
        XCTAssertEqual(ProbeFrameClass(opcode: 0x11), .heartbeat)
        // A hypothetical dedicated HrSync opcode would land in .unknown — the signal we hunt for.
        XCTAssertEqual(ProbeFrameClass(opcode: 0x4d), .unknown)
    }

    func testResultRecordingAndNovelty() {
        var control = SelectorProbeResult(selector: 0x00, label: "control")
        control.record([0x82, 0x00, 0x00, 0x82])           // ACK
        control.record([0x4c, 0x00, 0x06, 0x00])           // sleep page
        control.record([0x50, 0x00, 0x00])                 // end-of-history
        XCTAssertTrue(control.sawAck)
        XCTAssertEqual(control.opcodes, [0x82, 0x4c, 0x50])
        XCTAssertEqual(control.frameCount, 3)

        var hr = SelectorProbeResult(selector: 0x0a, label: "off_2c hr")
        hr.record([0x82, 0x00, 0x00, 0x82])                // ACK
        hr.record([0x4d, 0x00, 0xAA, 0xBB])                // a NEW opcode not in control
        XCTAssertEqual(hr.novelOpcodes(vsControl: control.opcodes), [0x4d])

        // A selector that only reproduces the control's opcodes has no novelty.
        XCTAssertTrue(control.novelOpcodes(vsControl: control.opcodes).isEmpty)
    }

    func testSampleFramesCapped() {
        var r = SelectorProbeResult(selector: 0x0b, label: "x")
        for _ in 0..<(SelectorProbeResult.sampleCap + 5) { r.record([0x4c, 0x00, 0x00]) }
        XCTAssertEqual(r.sampleFrames.count, SelectorProbeResult.sampleCap)
        XCTAssertEqual(r.frameCount, SelectorProbeResult.sampleCap + 5, "count keeps climbing past the sample cap")
    }

    func testSummarizeFlagsNovelCandidates() {
        var control = SelectorProbeResult(selector: 0x00, label: "control")
        control.record([0x82, 0x00, 0x00, 0x82]); control.record([0x4c, 0x00, 0x06, 0x00])
        var hr = SelectorProbeResult(selector: 0x0a, label: "off_2c hr")
        hr.record([0x82, 0x00, 0x00, 0x82]); hr.record([0x4d, 0x00, 0x00, 0x00])
        let report = DataSyncProbe.summarize([control, hr])
        XCTAssertTrue(report.contains("0x0a"), "hot candidate listed")
        XCTAssertTrue(report.contains("NOVEL"), "novel opcode flagged")
        XCTAssertTrue(report.contains("unknown→candidate-stream"),
                      "a novel unknown opcode must be classified as the decode target (ProbeFrameClass wired in)")
    }

    func testDescribeOpcodeUsesClassifier() {
        XCTAssertEqual(DataSyncProbe.describeOpcode(0x4d), "4d(unknown→candidate-stream)")
        XCTAssertEqual(DataSyncProbe.describeOpcode(0x4c), "4c(historyPage)")
    }
}

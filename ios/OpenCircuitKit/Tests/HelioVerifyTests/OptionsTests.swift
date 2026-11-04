// HelioVerify's write gating at option-parse time (adapted from the #221 review's options probe,
// which compiled a verbatim copy of `parseOptions`; the parser is now tested directly). Nothing here
// touches Bluetooth or a strap.

import XCTest
@testable import HelioVerify
import ZeppKit

final class OptionsTests: XCTestCase {

    private let key = ["--key-file", "/nonexistent/test.key"]

    private func accepted(_ args: [String], file: StaticString = #filePath, line: UInt = #line) -> Options? {
        do {
            return try parseOptions(args)
        } catch {
            XCTFail("rejected \(args): \(error)", file: file, line: line)
            return nil
        }
    }

    private func assertRejected(_ args: [String], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try parseOptions(args), "accepted \(args)", file: file, line: line) { error in
            guard case OptionsError.invalid = error else {
                return XCTFail("\(args): \(error), not a usage error", file: file, line: line)
            }
        }
    }

    func testReadOnlyModesAreAcceptedAndNeverSetTheClock() {
        for extra in [[], ["--find"], ["--find", "60"], ["--vibrate"], ["--alerts"], ["--alarms"],
                      ["--find", "5", "--vibrate", "--alerts", "--alarms", "--trace"]] {
            let o = accepted(key + extra)
            XCTAssertEqual(o?.setTime, false, "\(extra)")
            XCTAssertEqual(o?.allowWrite, false, "\(extra)")
        }
    }

    func testAlarmWritesNeedAllowWriteAndSetTheClockFirst() {
        assertRejected(key + ["--set-alarm", "07:00"])
        assertRejected(key + ["--delete-alarm", "3"])
        assertRejected(key + ["--set-alarm", "07:00", "--alarms"])
        XCTAssertEqual(accepted(key + ["--set-alarm", "07:00", "--allow-write"])?.setTime, true)
        XCTAssertEqual(accepted(key + ["--delete-alarm", "3", "--allow-write"])?.setTime, true)
        assertRejected(key + ["--set-alarm", "07:00", "--delete-alarm", "3", "--allow-write"])
        assertRejected(["--set-alarm", "07:00", "--allow-write"])
        assertRejected(key + ["--allow-write"])
        assertRejected(key + ["--allow-write", "--alarms"])
    }

    /// #221 review S1: the clock write was the one strap write outside --allow-write, and adding
    /// --allow-write to it was rejected.
    func testSetTimeNeedsAllowWrite() {
        assertRejected(key + ["--set-time"])
        assertRejected(key + ["--set-time", "--alarms"])
        assertRejected(key + ["--set-time", "--find"])
        XCTAssertThrowsError(try parseOptions(key + ["--set-time"])) {
            XCTAssertEqual($0 as? OptionsError, .invalid("--set-time writes the strap's clock: add --allow-write to confirm"))
        }
        XCTAssertEqual(accepted(key + ["--set-time", "--allow-write"])?.setTime, true)
        XCTAssertEqual(accepted(key + ["--set-time", "--allow-write", "--alarms"])?.setTime, true)
        XCTAssertEqual(accepted(key + ["--set-time", "--allow-write", "--find"])?.setTime, true)
        // An alarm write sets the clock with or without --set-time.
        XCTAssertEqual(accepted(key + ["--set-time", "--set-alarm", "07:00", "--allow-write"])?.setTime, true)
        // Without a key there is no auth, so no clock set: refused rather than silently skipped.
        assertRejected(["--set-time", "--allow-write"])
    }

    func testAllowWriteAloneNamesEveryWriteItApplies() {
        XCTAssertThrowsError(try parseOptions(key + ["--allow-write"])) {
            XCTAssertEqual($0 as? OptionsError, .invalid("--allow-write only applies to --set-time / --set-alarm / --delete-alarm / --set-config / --config-probe / --workout-test"))
        }
    }

    /// A strap workout is a write: starting or ending one needs the key and --allow-write, runs alone,
    /// and a raw start must be a start request (opcode 02). The status read needs only the key.
    func testWorkoutModesAreGatedAndRunAlone() {
        assertRejected(["--workout-test", "60"])
        assertRejected(key + ["--workout-test", "60"])
        assertRejected(key + ["--workout-end-only"])
        assertRejected(key + ["--allow-write", "--workout-test", "60", "--find", "2"])
        assertRejected(key + ["--allow-write", "--workout-test", "60", "--set-time"])
        assertRejected(key + ["--allow-write", "--workout-test", "60", "--workout-start-hex", "0134"])
        assertRejected(key + ["--allow-write", "--workout-test", "60", "--workout-start-hex", "02e"])
        assertRejected(key + ["--allow-write", "--workout-test", "60", "--workout-end", "maybe"])
        assertRejected(["--workout-status"])
        if let o = accepted(key + ["--allow-write", "--workout-test", "45", "--workout-end", "discard",
                                   "--workout-start-hex", "0211000001", "--workout-baseline", "3"]) {
            XCTAssertEqual(o.workoutSeconds, 45)
            XCTAssertEqual(o.workoutEnd, .discard)
            XCTAssertEqual(o.workoutStartBytes, [0x02, 0x11, 0x00, 0x00, 0x01])
            XCTAssertEqual(o.workoutBaseline, 3)
            XCTAssertTrue(o.writesWorkout)
        }
        if let o = accepted(key + ["--workout-status"]) {
            XCTAssertTrue(o.runsWorkout)
            XCTAssertFalse(o.writesWorkout)
        }
        if let o = accepted(key + ["--allow-write", "--workout-test", "30"]) {
            XCTAssertEqual(o.workoutEnd, .save)
            XCTAssertNil(o.workoutStartBytes)
        }
    }

    /// HelioVerify's timers are dispatch timers on the main queue (Foundation Timers never fire under
    /// dispatchMain()). This only shows the helper fires once; XCTest's wait spins the run loop, so it
    /// can't tell the two kinds apart.
    func testMainTimerFiresWithoutARunLoopTimer() {
        let fired = expectation(description: "fired")
        let t = mainTimer(every: nil, after: 0.05) { fired.fulfill() }
        wait(for: [fired], timeout: 2)
        t.cancel()
    }

    func testArgumentValidation() {
        for extra in [["--find", "0"], ["--find", "61"], ["--find", "nan"], ["--find", "inf"],
                      ["--delete-alarm", "10", "--allow-write"], ["--delete-alarm", "-1", "--allow-write"],
                      ["--set-alarm", "24:00", "--allow-write"], ["--set-alarm", "7:5", "--allow-write"],
                      ["--set-alarm", "07:30,once,mon", "--allow-write"]] {
            assertRejected(key + extra)
        }
        XCTAssertEqual(accepted(key + ["--set-alarm", "07:30,", "--allow-write"])?.setTime, true)
        let alarm = accepted(key + ["--set-alarm", "07:30,mon+wed", "--allow-write"])?.setAlarm
        XCTAssertEqual(alarm?.hour, 7)
        XCTAssertEqual(alarm?.minute, 30)
    }

    func testHelpIsNotAUsageError() {
        XCTAssertThrowsError(try parseOptions(["--help"])) { XCTAssertEqual($0 as? OptionsError, .help) }
        XCTAssertThrowsError(try parseOptions(key + ["-h"])) { XCTAssertEqual($0 as? OptionsError, .help) }
    }

    /// #221 review N1, F1, F3: the help must say which flags write, that alarm writes set the
    /// clock, and that a keyed run without a control flag sends the read-only device-info request.
    func testHelpTextIsAccurateAboutWrites() {
        let help = usage.split(separator: "\n").map(String.init)
        func block(_ flag: String) -> String {
            guard let start = help.firstIndex(where: { $0.hasPrefix("  \(flag)") }) else { return "" }
            var lines = [help[start]]
            for line in help[(start + 1)...] {
                guard line.hasPrefix("                      ") else { break }
                lines.append(line)
            }
            return lines.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        }
        XCTAssertTrue(block("--set-time").contains("needs --allow-write"))
        XCTAssertTrue(block("--delete-alarm").contains("Sets the strap's clock first"))
        XCTAssertTrue(block("--set-alarm").contains("Sets the strap's clock first"))
        let allowWrite = block("--allow-write")
        for flag in ["--set-time", "--set-alarm", "--delete-alarm", "--allow-delete"] {
            XCTAssertTrue(allowWrite.contains(flag), "--allow-write help does not mention \(flag)")
        }
        XCTAssertFalse(allowWrite.contains("Without it nothing is written"))
        let flat = usage.replacingOccurrences(of: "\n", with: " ")
        XCTAssertTrue(flat.contains("With --key-file and no control flag"))
        XCTAssertTrue(flat.contains("read-only device-info request (01 on endpoint 0x0043)"))
        XCTAssertTrue(block("--find").contains("SIGTERM or SIGHUP"))
        XCTAssertTrue(flat.contains("143 terminated (SIGTERM)"))
        XCTAssertTrue(flat.contains("129 hung up (SIGHUP)"))
    }

    // MARK: Strap settings (#228, #229, #230)

    func testSettingsReadIsReadOnly() {
        let o = accepted(key + ["--settings"])
        XCTAssertEqual(o?.settings, true)
        XCTAssertEqual(o?.allowWrite, false)
        XCTAssertEqual(o?.writesConfig, false)
        XCTAssertEqual(o?.hasControls, true)
        assertRejected(["--settings"])
    }

    func testConfigWritesNeedAllowWriteOnePerRun() {
        assertRejected(key + ["--set-config", "stressMonitoring=off"])
        assertRejected(key + ["--config-probe", "a"])
        assertRejected(["--set-config", "stressMonitoring=off", "--allow-write"])
        let o = accepted(key + ["--set-config", "stressMonitoring=off", "--allow-write"])
        XCTAssertEqual(o?.setConfig?.setting, .stressMonitoring)
        XCTAssertEqual(o?.setConfig?.value, .bool(false))
        XCTAssertEqual(o?.setTime, false, "a config write doesn't set the clock")
        XCTAssertEqual(accepted(key + ["--config-probe", "b", "--allow-write"])?.configProbe, .childWhileParentOff)
        assertRejected(key + ["--config-probe", "d", "--allow-write"])
        assertRejected(key + ["--set-config", "stressMonitoring=off", "--config-probe", "a", "--allow-write"])
        assertRejected(key + ["--set-config", "stressMonitoring=off", "--set-alarm", "07:00", "--allow-write"])
    }

    func testSettingSpecs() {
        func spec(_ text: String) -> ZeppConfigValue? { parseSettingSpec(text)?.value }
        XCTAssertEqual(spec("heartRateMonitoring=continuous"), .byte(0xfe), "§17.9: fe, never 00")
        XCTAssertEqual(spec("heartRateMonitoring=smart"), .byte(0xff))
        XCTAssertEqual(spec("heartRateMonitoring=10"), .byte(10))
        XCTAssertEqual(spec("highHeartRateAlert=120"), .byte(120))
        XCTAssertEqual(spec("lowSpO2Alert=off"), .byte(0))
        XCTAssertEqual(spec("workoutDetectionSensitivity=standard"), .byte(1))
        XCTAssertEqual(spec("relaxReminder=on"), .bool(true))
        XCTAssertNil(spec("relaxReminder=120"))
        XCTAssertNil(spec("highHeartRateAlert=smart"))
        XCTAssertNil(spec("heartRatePush=on"), "not offered")
        XCTAssertNil(spec("workoutCategories=1"), "WORKOUT 40 is never written")
        XCTAssertNil(spec("highHeartRateAlert=300"))
    }
}

// ZeppSettingsEditor (#228, #229, #230): the §17.8 config write sequence as a pure machine; the
// spec's worked examples I, J, K (§17.10–§17.12) and M (§19.4); example I's encrypted write on the
// wire; then the editor over the simulated strap's real chunking and encryption. Every value and
// allowed list is made up.
//
// The examples' WRITES are reproduced byte for byte. Their reads are too, except example K's: the
// editor's pre-read and re-read for the high-HR alert also ask for arg `01` (§17.7's SPEC-GAP, see
// `ZeppSetting.requirement`), so it sends `03 01 08 02 01 02` where K shows `03 01 08 01 02`.

import XCTest
@testable import ZeppKit
import ZeppKitTesting

/// A read reply with constraints included, built from entries.
private func reply(group: UInt8 = 0x08, version: UInt8 = 0x03, _ entries: [[UInt8]]) -> [UInt8] {
    [0x04, 0x01, group, version, 0x01, UInt8(entries.count)] + entries.flatMap { $0 }
}

private func byteEntry(_ arg: UInt8, _ value: UInt8, allowed: [UInt8]) -> [UInt8] {
    [arg, 0x10, value, UInt8(allowed.count)] + allowed
}

private func boolEntry(_ arg: UInt8, _ on: Bool) -> [UInt8] { [arg, 0x0b, on ? 0x01 : 0x00] }

/// Made-up HEALTH settings: HR smart; active HR off; sleep on; breathing off; stress on; SpO₂ off;
/// high HR off (allowed 0/100/110/120); low HR off (0/40/45/50); relax off; low SpO₂ off (0/80/85/90).
private struct Health {
    var heartRate: UInt8 = 0xff
    var activeHR = false
    var sleep = true
    var breathing = false
    var stress = true
    var spo2 = false
    var highHR: UInt8 = 0
    var highHRAllowed: [UInt8] = [0, 100, 110, 120]
    var relax = false
    /// Heart Rate Broadcast (`83`); nil = the strap doesn't report it.
    var broadcast: Bool? = nil
    var version: UInt8 = 0x03

    /// The entry for one arg, as the strap would send it.
    func entry(_ arg: UInt8) -> [UInt8] {
        switch arg {
        case 0x01: return byteEntry(0x01, heartRate, allowed: [0x00, 0xff, 0xfe, 0x01, 0x05, 0x0a, 0x1e])
        case 0x04: return boolEntry(0x04, activeHR)
        case 0x11: return boolEntry(0x11, sleep)
        case 0x12: return boolEntry(0x12, breathing)
        case 0x13: return boolEntry(0x13, stress)
        case 0x31: return boolEntry(0x31, spo2)
        case 0x02: return byteEntry(0x02, highHR, allowed: highHRAllowed)
        case 0x03: return byteEntry(0x03, 0, allowed: [0, 40, 45, 50])
        case 0x14: return boolEntry(0x14, relax)
        case 0x32: return byteEntry(0x32, 0, allowed: [0, 80, 85, 90])
        case 0x83: return broadcast.map { boolEntry(0x83, $0) } ?? []
        default: return []
        }
    }

    /// The reply to a read of `arguments`, in that order.
    func reply(_ arguments: [UInt8]) -> [UInt8] {
        ZeppKitTests.reply(version: version, arguments.map(entry).filter { !$0.isEmpty })
    }

    var full: [UInt8] { reply(ZeppSettingsEditor.groupArguments(0x08)) }
}

private let configCaps = ZeppConfigCapabilities(serviceVersion: 3, groups: [0x00, 0x0b, 0x08, 0x09, 0x0a])
private let t0 = date(1_790_764_496)

private func editor(_ capabilities: ZeppControlCapabilities = ControlsFixtures.strapCapabilities(),
                    configCapabilities: ZeppConfigCapabilities? = configCaps) -> ZeppSettingsEditor {
    ZeppSettingsEditor(capabilities: capabilities, configCapabilities: configCapabilities)
}

/// An editor that has read HEALTH (`health`) and, when given, WORKOUT.
private func readEditor(_ health: Health = Health(), workout: [UInt8]? = nil) throws -> ZeppSettingsEditor {
    var e = editor()
    _ = try e.read(groups: [0x08], now: t0)
    _ = e.receive(health.full, now: t0)
    if let workout {
        _ = try e.read(groups: [0x09], now: t0)
        _ = e.receive(workout, now: t0)
    }
    XCTAssertTrue(e.hasRead(group: 0x08))
    return e
}

private func payloads(_ out: ZeppSettingsEditor.Output) -> [[UInt8]] {
    out.messages.map { msg in
        XCTAssertEqual(msg.endpoint, ZeppEndpoint.config)
        return msg.payload
    }
}

final class SettingsTests: XCTestCase {

    // MARK: Requests and the snapshot

    func testRequestsAndWhatIsNeverOffered() {
        XCTAssertEqual(ZeppSettingsEditor.readRequest(group: 0x08), hex("03 01 08 0b 01 04 11 12 13 31 02 03 14 32 83"))
        XCTAssertEqual(ZeppSettingsEditor.readRequest(group: 0x09), hex("03 01 09 03 40 41 42"), "worked example M's read")
        XCTAssertEqual(ZeppSettingsEditor.familyRequest(.lowSpO2Alert), hex("03 01 08 02 31 32"), "worked example J's read")
        XCTAssertEqual(ZeppSettingsEditor.familyRequest(.heartRateMonitoring), hex("03 01 08 01 01"), "worked example I's read")
        XCTAssertEqual(ZeppSettingsEditor.familyRequest(.relaxReminder), hex("03 01 08 02 13 14"))
        let arguments = ZeppSetting.allCases.map { ($0.group, $0.argument) }
        XCTAssertFalse(arguments.contains { $0 == (0x08, 0x05) }, "HEALTH 05 (sharing with third parties) is unsettled (§5.5)")
        XCTAssertFalse(arguments.contains { $0 == (0x09, 0x40) }, "categories are never written (§19.3)")
        XCTAssertFalse(arguments.contains { $0.0 == 0x08 && [0x41, 0x51].contains($0.1) }, "inactivity and goal alerts stay out")
        XCTAssertEqual(Set(ZeppSetting.measurement + ZeppSetting.alerts + ZeppSetting.workoutDetection + ZeppSetting.broadcast),
                       Set(ZeppSetting.allCases))
    }

    func testSnapshotKeepsOnlyWellTypedSettingsAndApplies17_7() throws {
        let e = try readEditor()
        let s = e.snapshot
        XCTAssertEqual(s.entries.count, 10)
        XCTAssertEqual(s.options(.heartRateMonitoring), [0x00, 0xff, 0xfe, 0x01, 0x05, 0x0a, 0x1e].map(ZeppConfigValue.byte))
        XCTAssertEqual(s.availability(.relaxReminder), .available, "stress is on")
        XCTAssertEqual(s.availability(.lowSpO2Alert), .needs(.allDaySpO2), "all-day SpO₂ is off")
        XCTAssertEqual(s.availability(.highHeartRateAlert), .available)

        // All-day HR reported off: activity monitoring and the HR alerts need it not off.
        var off = Health()
        off.heartRate = 0x00
        let o = try readEditor(off).snapshot
        XCTAssertEqual(o.availability(.activeHeartRateMonitoring), .needs(.heartRateMonitoring))
        XCTAssertEqual(o.availability(.highHeartRateAlert), .needs(.heartRateMonitoring))
        XCTAssertEqual(o.availability(.stressMonitoring), .available, "§17.7: stress doesn't depend on the interval")

        // A strap that doesn't report arg 01 (Gadgetbridge hides it on the Helio): no HR dependency.
        var bare = editor()
        _ = try bare.read(groups: [0x08], now: t0)
        _ = bare.receive(reply([byteEntry(0x02, 0, allowed: [0, 100]), boolEntry(0x04, false)]), now: t0)
        XCTAssertEqual(bare.snapshot.availability(.highHeartRateAlert), .available)
        XCTAssertEqual(bare.snapshot.availability(.activeHeartRateMonitoring), .available)
        XCTAssertEqual(bare.snapshot.availability(.heartRateMonitoring), .notReported, "no arg 01, no control")

        // Wrong type, an empty allowed list (shown, nothing offered), a duplicate arg.
        var odd = editor()
        _ = try odd.read(groups: [0x08], now: t0)
        _ = odd.receive(reply([[0x13, 0x10, 0x01, 0x02, 0x00, 0x01], byteEntry(0x02, 0, allowed: []),
                               boolEntry(0x11, true), boolEntry(0x11, false), boolEntry(0x14, true)]), now: t0)
        XCTAssertEqual(odd.snapshot.availability(.stressMonitoring), .notReported)
        XCTAssertEqual(odd.snapshot.availability(.highAccuracySleep), .notReported)
        XCTAssertEqual(odd.snapshot.options(.highHeartRateAlert), [], "§17.6: an empty allowed list: don't write")
        XCTAssertThrowsError(try odd.change(.init(setting: .highHeartRateAlert, from: .byte(0), to: .byte(0x64)), now: t0))
        XCTAssertEqual(odd.snapshot.availability(.relaxReminder), .needs(.stressMonitoring),
                       "a parent the strap didn't report is not 'on'")
    }

    func testUndescribedGroupVersionsAreReadOnly() throws {
        var v4 = Health()
        v4.version = 4
        var e = try readEditor(v4)
        XCTAssertEqual(e.snapshot.value(.stressMonitoring), .bool(true), "the value is still shown")
        XCTAssertEqual(e.snapshot.availability(.stressMonitoring), .readOnly)
        XCTAssertThrowsError(try e.change(.init(setting: .stressMonitoring, from: .bool(true), to: .bool(false)), now: t0)) {
            XCTAssertEqual($0 as? ZeppSettingsEditor.Error, .readOnly(.stressMonitoring))
        }
        var w2 = editor()
        _ = try w2.read(groups: [0x09], now: t0)
        _ = w2.receive(reply(group: 0x09, version: 0x02, [boolEntry(0x41, false)]), now: t0)
        XCTAssertEqual(w2.snapshot.availability(.workoutDetectionAlert), .readOnly, "the spec describes WORKOUT v1 only")
    }

    // MARK: Worked examples (§17.10–§17.12, §19.4)

    func testWorkedExampleI() throws {
        // Invented reply: HR smart; 9 allowed: off, smart, continuous, 1, 5, 10, 15, 30, 60 min.
        let read = hex("04 01 08 03 01 01 01 10 ff 09 00 ff fe 01 05 0a 0f 1e 3c")
        var e = editor()
        _ = try e.read(groups: [0x08], now: t0)
        _ = e.receive(read, now: t0)
        XCTAssertTrue(e.snapshot.options(.heartRateMonitoring).contains(.byte(0xfe)), "§17.9: continuous is fe")
        let change = ZeppSettingsEditor.Change(setting: .heartRateMonitoring, from: .byte(0xff), to: .byte(0x0a))
        XCTAssertEqual(payloads(try e.change(change, now: t0)), [hex("03 01 08 01 01")])
        XCTAssertEqual(payloads(e.receive(read, now: t0)), [hex("05 08 03 00 01 01 10 0a")])
        var out = e.receive(hex("06 01"), now: t0)
        XCTAssertEqual(payloads(out), [hex("03 01 08 01 01")])
        out = e.receive(hex("04 01 08 03 01 01 01 10 0a 09 00 ff fe 01 05 0a 0f 1e 3c"), now: t0)
        guard case .writeChecked(let check)? = out.events.first else { return XCTFail("\(out.events)") }
        XCTAssertTrue(check.tookChange)
        XCTAssertEqual(check.readBack, .byte(0x0a))
    }

    func testContinuousIsWrittenAsFE() throws {
        var e = try readEditor()
        _ = try e.change(.init(setting: .heartRateMonitoring, from: .byte(0xff), to: .byte(0xfe)), now: t0)
        XCTAssertEqual(payloads(e.receive(Health().reply([0x01]), now: t0)), [hex("05 08 03 00 01 01 10 fe")],
                       "never Gadgetbridge's 00 (off)")
    }

    func testWorkedExampleIEncryptedOnTheWire() throws {
        let write = hex("05 08 03 00 01 01 10 0a")
        var crypto = try ZeppSessionCrypto(sessionKey: SpecC.sessionKey, sequenceSeed: 0x2933_d235)
        XCTAssertEqual(crypto.messageKey(handle: 0x07), hex("8b 42 69 01 24 95 28 ac 74 c9 06 a7 ca da e9 f8"))
        XCTAssertEqual(ZeppCRC32.checksum(hex("05 08 03 00 01 01 10 0a 35 d2 33 29")), 0x6e18_eeb8)
        let ciphertext = hex("4f 4a df 2a 4a 15 fd 33 64 35 03 94 64 75 56 75")
        XCTAssertEqual(try crypto.seal(write, handle: 0x07), ciphertext)
        XCTAssertEqual(crypto.nextSequence, 0x2933_d236)

        // As the 7th message of a connection: two plaintext auth messages, then four encrypted ones.
        func transport(_ maxWriteLength: Int) throws -> ZeppChunkedTransport {
            var t = ZeppChunkedTransport(maxWriteLength: maxWriteLength)
            _ = try t.encode(endpoint: ZeppEndpoint.authentication, payload: [0x00])
            _ = try t.encode(endpoint: ZeppEndpoint.authentication, payload: [0x00])
            t.install(session: try ZeppSessionCrypto(sessionKey: SpecC.sessionKey, sequenceSeed: SpecC.sequenceSeed))
            for _ in 0..<4 { _ = try t.encode(endpoint: ZeppEndpoint.config, payload: [0x01]) }
            XCTAssertEqual(t.session?.nextSequence, 0x2933_d235)
            return t
        }
        var wide = try transport(244)
        XCTAssertEqual(try wide.encode(endpoint: ZeppEndpoint.config, payload: write),
                       [hex("03 0f 00 07 00 08 00 00 00 0a 00") + ciphertext])
        var narrow = try transport(20)
        XCTAssertEqual(try narrow.encode(endpoint: ZeppEndpoint.config, payload: write), [
            hex("03 09 00 07 00 08 00 00 00 0a 00 4f 4a df 2a 4a 15 fd 33 64"),
            hex("03 0e 00 07 01 35 03 94 64 75 56 75"),
        ])
    }

    func testWorkedExampleJ() throws {
        let first = hex("04 01 08 03 01 02 31 0b 00 32 10 00 04 00 50 55 5a")
        var e = editor()
        _ = try e.read(groups: [0x08], now: t0)
        _ = e.receive(first, now: t0)
        // The 90 % alert is refused on the phone: needs arg 31 on.
        XCTAssertThrowsError(try e.change(.init(setting: .lowSpO2Alert, from: .byte(0), to: .byte(0x5a)), now: t0)) {
            XCTAssertEqual($0 as? ZeppSettingsEditor.Error, .prerequisiteOff(.lowSpO2Alert, needs: .allDaySpO2))
        }
        XCTAssertFalse(e.isBusy)
        // All-day SpO₂ on: one write, the parent only.
        _ = try e.change(.init(setting: .allDaySpO2, from: .bool(false), to: .bool(true)), now: t0)
        XCTAssertEqual(payloads(e.receive(first, now: t0)), [hex("05 08 03 00 01 31 0b 01")])
        _ = e.receive(hex("06 01"), now: t0)
        _ = e.receive(hex("04 01 08 03 01 01 31 0b 01"), now: t0)
        XCTAssertEqual(e.snapshot.availability(.lowSpO2Alert), .available)
        // Then, as a separate user action, the 90 % alert.
        XCTAssertEqual(payloads(try e.change(.init(setting: .lowSpO2Alert, from: .byte(0), to: .byte(0x5a)), now: t0)),
                       [hex("03 01 08 02 31 32")])
        XCTAssertEqual(payloads(e.receive(hex("04 01 08 03 01 02 31 0b 01 32 10 00 04 00 50 55 5a"), now: t0)),
                       [hex("05 08 03 00 01 32 10 5a")])
    }

    func testWorkedExampleK() throws {
        let read = hex("04 01 08 03 01 01 02 10 78 07 00 64 6e 78 82 8c 96")
        var e = editor()
        _ = try e.read(groups: [0x08], now: t0)
        _ = e.receive(read, now: t0)
        XCTAssertThrowsError(try e.change(.init(setting: .highHeartRateAlert, from: .byte(0x78), to: .byte(0x7d)), now: t0)) {
            XCTAssertEqual($0 as? ZeppSettingsEditor.Error, .valueNotAllowed(.highHeartRateAlert, .byte(0x7d)))
        }
        let change = ZeppSettingsEditor.Change(setting: .highHeartRateAlert, from: .byte(0x78), to: .byte(0x82))
        // NOT example K's `03 01 08 01 02`: the editor adds the parent arg `01` (§17.7 SPEC-GAP). This
        // strap doesn't report `01`, so the HR requirement doesn't apply and the write is K's.
        XCTAssertEqual(payloads(try e.change(change, now: t0)), [hex("03 01 08 02 01 02")])
        XCTAssertEqual(payloads(e.receive(read, now: t0)), [hex("05 08 03 00 01 02 10 82")])
        var out = e.receive(hex("06 02"), now: t0)
        XCTAssertEqual(out.events, [.writeNotAcknowledged(change, .status(0x02))])
        XCTAssertEqual(payloads(out), [hex("03 01 08 02 01 02")], "re-read (K: 03 01 08 01 02, see above), never retry")
        out = e.receive(read, now: t0)
        guard case .writeChecked(let check)? = out.events.first else { return XCTFail("\(out.events)") }
        XCTAssertFalse(check.tookChange)
        XCTAssertEqual(check.readBack, .byte(0x78), "show \"the strap kept 120 bpm\"")
        XCTAssertEqual(out.messages, [])
        // Turning the alert off is the documented write.
        _ = try e.change(.init(setting: .highHeartRateAlert, from: .byte(0x78), to: .byte(0x00)), now: t0)
        XCTAssertEqual(payloads(e.receive(read, now: t0)), [hex("05 08 03 00 01 02 10 00")])
    }

    func testWorkedExampleM() throws {
        var e = editor()
        XCTAssertEqual(payloads(try e.read(groups: [0x09], now: t0)), [hex("03 01 09 03 40 41 42")])
        let read = hex("04 01 09 01 01 02 41 0b 00 42 10 00 03 00 01 02")
        _ = e.receive(read, now: t0)
        XCTAssertEqual(e.snapshot.options(.workoutDetectionSensitivity), [.byte(0), .byte(1), .byte(2)])
        _ = try e.change(.init(setting: .workoutDetectionSensitivity, from: .byte(0), to: .byte(1)), now: t0)
        XCTAssertEqual(payloads(e.receive(read, now: t0)), [hex("05 09 01 00 01 42 10 01")], "WORKOUT v1 echoed")
        _ = e.receive(hex("06 01"), now: t0)
        _ = e.receive(hex("04 01 09 01 01 01 42 10 01 03 00 01 02"), now: t0)
        _ = try e.change(.init(setting: .workoutDetectionAlert, from: .bool(false), to: .bool(true)), now: t0)
        XCTAssertEqual(payloads(e.receive(hex("04 01 09 01 01 01 41 0b 00"), now: t0)), [hex("05 09 01 00 01 41 0b 01")])
        _ = e.receive(hex("06 01"), now: t0)
        let out = e.receive(hex("04 01 09 01 01 01 41 0b 01"), now: t0)
        guard case .writeChecked(let check)? = out.events.first else { return XCTFail("\(out.events)") }
        XCTAssertTrue(check.tookChange)
        XCTAssertEqual(e.snapshot.value(.workoutDetectionSensitivity), .byte(1))
    }

    func testCategoriesAreReadNeverOffered() throws {
        var e = editor()
        _ = try e.read(groups: [0x09], now: t0)
        _ = e.receive(hex("04 01 09 01 01 03 40 11 02 01 03 02 01 03 41 0b 00 42 10 01 03 00 01 02"), now: t0)
        XCTAssertEqual(e.snapshot.entries.keys.map(\.argument).sorted(), [0x41, 0x42])
    }

    // MARK: §17.4, §17.5

    func testAChangeReadsTheFamilyFirstWritesOneEntryThenReReads() throws {
        var e = try readEditor()
        let change = ZeppSettingsEditor.Change(setting: .relaxReminder, from: .bool(false), to: .bool(true))
        XCTAssertEqual(payloads(try e.change(change, now: t0)), [hex("03 01 08 02 13 14")])
        XCTAssertEqual(e.changeInFlight, change)
        XCTAssertThrowsError(try e.read(groups: [0x09], now: t0)) {
            XCTAssertEqual($0 as? ZeppSettingsEditor.Error, .busy, "§17.4: no interleaved reads of other groups")
        }
        XCTAssertEqual(payloads(e.receive(Health().reply([0x13, 0x14]), now: t0)), [hex("05 08 03 00 01 14 0b 01")])
        var out = e.receive([0x06, 0x01], now: t0)
        XCTAssertEqual(out.events, [.writeAcknowledged(change)])
        var after = Health()
        after.relax = true
        out = e.receive(after.reply([0x13, 0x14]), now: t0)
        guard case .writeChecked(let check)? = out.events.first else { return XCTFail("\(out.events)") }
        XCTAssertTrue(check.tookChange)
        XCTAssertFalse(check.groupVersionChanged)
        XCTAssertFalse(e.isBusy)
    }

    func testAnAckWithTheOldValueOnReReadIsNotTaken() throws {
        var e = try readEditor()
        let change = ZeppSettingsEditor.Change(setting: .highAccuracySleep, from: .bool(true), to: .bool(false))
        _ = try e.change(change, now: t0)
        _ = e.receive(Health().reply([0x11]), now: t0)
        _ = e.receive([0x06, 0x01], now: t0)
        let out = e.receive(Health().reply([0x11]), now: t0)
        guard case .writeChecked(let check)? = out.events.first else { return XCTFail("\(out.events)") }
        XCTAssertNil(check.failure)
        XCTAssertFalse(check.tookChange, "§17.4 (c)")
        XCTAssertEqual(check.readBack, .bool(true))
    }

    func testAReReadMissingTheSettingHidesItForTheConnection() throws {
        var e = try readEditor()
        let change = ZeppSettingsEditor.Change(setting: .stressMonitoring, from: .bool(true), to: .bool(false))
        _ = try e.change(change, now: t0)
        _ = e.receive(Health().reply([0x13]), now: t0)
        _ = e.receive([0x06, 0x01], now: t0)
        let out = e.receive(reply([]), now: t0)
        guard case .writeChecked(let check)? = out.events.first else { return XCTFail("\(out.events)") }
        XCTAssertNil(check.readBack)
        XCTAssertEqual(e.snapshot.availability(.stressMonitoring), .notReported)
        // A later read that reports it again doesn't bring it back this connection.
        _ = try e.read(groups: [0x08], now: t0)
        _ = e.receive(Health().full, now: t0)
        XCTAssertEqual(e.snapshot.availability(.stressMonitoring), .notReported)
        XCTAssertTrue(e.snapshot.hidden.contains(.stressMonitoring))

        // A changed type does the same.
        var f = try readEditor()
        _ = try f.change(.init(setting: .highAccuracySleep, from: .bool(true), to: .bool(false)), now: t0)
        _ = f.receive(Health().reply([0x11]), now: t0)
        _ = f.receive([0x06, 0x01], now: t0)
        _ = f.receive(reply([[0x11, 0x10, 0x00, 0x02, 0x00, 0x01]]), now: t0)
        XCTAssertEqual(f.snapshot.availability(.highAccuracySleep), .notReported)
    }

    func testAVersionChangeUnderAWriteFreezesTheGroupAndReReadsIt() throws {
        var e = try readEditor()
        let change = ZeppSettingsEditor.Change(setting: .allDaySpO2, from: .bool(false), to: .bool(true))
        _ = try e.change(change, now: t0)
        _ = e.receive(Health().reply([0x31]), now: t0)
        _ = e.receive([0x06, 0x01], now: t0)
        var v2 = Health()
        v2.version = 2
        v2.spo2 = true
        let out = e.receive(v2.reply([0x31]), now: t0)
        guard case .writeChecked(let check)? = out.events.first else { return XCTFail("\(out.events)") }
        XCTAssertTrue(check.groupVersionChanged)
        XCTAssertEqual(payloads(out), [ZeppSettingsEditor.readRequest(group: 0x08)], "re-read the whole group")
        _ = e.receive(v2.full, now: t0)
        XCTAssertEqual(e.snapshot.availability(.stressMonitoring), .readOnly, "no more writes to HEALTH this connection")
        XCTAssertThrowsError(try e.change(.init(setting: .stressMonitoring, from: .bool(true), to: .bool(false)), now: t0))
    }

    func testNothingTheUserDidNotChangeOrTheStrapDoesNotOfferIsSent() throws {
        var e = try readEditor()
        func refuses(_ change: ZeppSettingsEditor.Change, _ expected: ZeppSettingsEditor.Error, line: UInt = #line) {
            XCTAssertThrowsError(try e.change(change, now: t0), line: line) {
                XCTAssertEqual($0 as? ZeppSettingsEditor.Error, expected, line: line)
            }
            XCTAssertFalse(e.isBusy, line: line)
        }
        refuses(.init(setting: .stressMonitoring, from: .bool(true), to: .bool(true)), .unchanged(.stressMonitoring))
        refuses(.init(setting: .highHeartRateAlert, from: .byte(0), to: .byte(125)), .valueNotAllowed(.highHeartRateAlert, .byte(125)))
        refuses(.init(setting: .stressMonitoring, from: .bool(true), to: .byte(0)), .valueNotAllowed(.stressMonitoring, .byte(0)))
        refuses(.init(setting: .lowSpO2Alert, from: .byte(0), to: .byte(90)), .prerequisiteOff(.lowSpO2Alert, needs: .allDaySpO2))
        refuses(.init(setting: .workoutDetectionAlert, from: .bool(false), to: .bool(true)), .notRead)

        var fresh = editor()
        XCTAssertThrowsError(try fresh.change(.init(setting: .stressMonitoring, from: .bool(true), to: .bool(false)), now: t0)) {
            XCTAssertEqual($0 as? ZeppSettingsEditor.Error, .notRead, "§17.3: no read in this connection → read first")
        }
    }

    func testAValueChangedOnTheStrapOrAParentTurnedOffMeanwhileIsNotWritten() throws {
        var e = try readEditor()
        let change = ZeppSettingsEditor.Change(setting: .stressMonitoring, from: .bool(true), to: .bool(false))
        _ = try e.change(change, now: t0)
        var meanwhile = Health()
        meanwhile.stress = false
        var out = e.receive(meanwhile.reply([0x13]), now: t0)
        XCTAssertEqual(out.messages, [])
        XCTAssertEqual(out.events.last, .changedOnStrap(change, current: .bool(false)))
        XCTAssertEqual(e.snapshot.value(.stressMonitoring), .bool(false), "the screen shows the strap's value")

        var f = try readEditor()
        let relax = ZeppSettingsEditor.Change(setting: .relaxReminder, from: .bool(false), to: .bool(true))
        _ = try f.change(relax, now: t0)
        out = f.receive(meanwhile.reply([0x13, 0x14]), now: t0)
        XCTAssertEqual(out.messages, [])
        XCTAssertEqual(out.events.last, .refused(relax, .prerequisiteOff(.relaxReminder, needs: .stressMonitoring)))

        var g = try readEditor()
        let high = ZeppSettingsEditor.Change(setting: .highHeartRateAlert, from: .byte(0), to: .byte(120))
        _ = try g.change(high, now: t0)
        var narrower = Health()
        narrower.highHRAllowed = [0, 100, 110]
        out = g.receive(narrower.reply([0x01, 0x02]), now: t0)
        XCTAssertEqual(out.messages, [])
        XCTAssertEqual(out.events.last, .refused(high, .valueNotAllowed(.highHeartRateAlert, .byte(120))))
    }

    func testTurningAParentOffWritesOnlyTheParentAndKeepsTheChildVisible() throws {
        var health = Health()
        health.relax = true
        var e = try readEditor(health)
        _ = try e.change(.init(setting: .stressMonitoring, from: .bool(true), to: .bool(false)), now: t0)
        XCTAssertEqual(payloads(e.receive(health.reply([0x13]), now: t0)), [hex("05 08 03 00 01 13 0b 00")])
        _ = e.receive([0x06, 0x01], now: t0)
        health.stress = false
        _ = e.receive(health.reply([0x13]), now: t0)
        XCTAssertEqual(e.snapshot.value(.relaxReminder), .bool(true), "the child's stored value stays visible")
        XCTAssertEqual(e.snapshot.availability(.relaxReminder), .needs(.stressMonitoring), "shown inactive")
    }

    func testTimeoutsAndALateAck() throws {
        var e = try readEditor()
        let change = ZeppSettingsEditor.Change(setting: .highAccuracySleep, from: .bool(true), to: .bool(false))
        _ = try e.change(change, now: t0)
        _ = e.receive(Health().reply([0x11]), now: t0)
        XCTAssertEqual(e.tick(now: t0.addingTimeInterval(4)), .init(), "not yet")
        var out = e.tick(now: t0.addingTimeInterval(5))
        XCTAssertEqual(payloads(out), [hex("03 01 08 01 11")])
        XCTAssertEqual(out.events, [.writeNotAcknowledged(change, .noAck)])
        XCTAssertEqual(e.receive([0x06, 0x01], now: t0), .init(), "a late 06 is ignored")
        out = e.tick(now: t0.addingTimeInterval(10))
        XCTAssertEqual(out.events, [.writeUnverified(change, failure: .noAck, .timedOut)])
        XCTAssertEqual(out.messages, [])
        // review-240b S-1: a re-read that never answered keeps the last READ value, so the row stays.
        XCTAssertEqual(e.snapshot.value(.highAccuracySleep), .bool(true), "the last read value, not the written one")
        XCTAssertEqual(e.readFailures[0x08], .timedOut)

        var f = try readEditor()
        _ = try f.change(change, now: t0)
        out = f.tick(now: t0.addingTimeInterval(5))
        XCTAssertEqual(out.messages, [])
        XCTAssertEqual(out.events, [.readFailed(group: 0x08, .timedOut), .refused(change, .notRead)])
    }

    func testGroupReadsQueueAndGates() throws {
        var e = editor()
        XCTAssertEqual(payloads(try e.read(groups: [0x08, 0x09], now: t0)), [ZeppSettingsEditor.readRequest(group: 0x08)])
        XCTAssertEqual(payloads(e.receive(Health().full, now: t0)), [ZeppSettingsEditor.readRequest(group: 0x09)])
        let out = e.receive(hex("04 00 09"), now: t0)
        XCTAssertEqual(out.events, [.readFailed(group: 0x09, .malformed)])
        XCTAssertEqual(e.readFailures[0x09], .malformed)

        let noConfig = ControlsFixtures.strapCapabilities(ControlsFixtures.bareServices)
        var n = editor(noConfig)
        XCTAssertThrowsError(try n.read(groups: [0x08], now: t0)) {
            XCTAssertEqual($0 as? ZeppControlError, .unsupported(.hapticAlerts, .endpointNotListed(ZeppEndpoint.config)))
        }
        for caps in [nil, ZeppConfigCapabilities(serviceVersion: 3, groups: [0x00, 0x0a]),
                     ZeppConfigCapabilities(serviceVersion: 4, groups: [0x08])] {
            var g = editor(configCapabilities: caps)
            XCTAssertFalse(g.isOffered(group: 0x08))
            XCTAssertThrowsError(try g.read(groups: [0x08], now: t0)) {
                XCTAssertEqual($0 as? ZeppSettingsEditor.Error, .groupNotOffered(0x08))
            }
        }
        let healthOnly = editor(configCapabilities: ZeppConfigCapabilities(serviceVersion: 3, groups: [0x08]))
        XCTAssertFalse(healthOnly.isOffered(group: 0x09))
        XCTAssertFalse(editor(ControlsFixtures.strapCapabilities(authenticated: false)).isOffered(group: 0x08))
        XCTAssertFalse(editor(ControlsFixtures.strapCapabilities(model: nil)).isOffered(group: 0x08))
    }

    func testGarbageNeverProducesAWrite() throws {
        var bytes = TestBytes(seed: 228)
        for _ in 0..<2000 {
            var e = try readEditor()
            if bytes.int(0...1) == 0 { _ = try e.read(groups: [0x08], now: t0) }
            var payload = bytes.bytes(bytes.int(0...40))
            if !payload.isEmpty, bytes.int(0...1) == 0 { payload[0] = [0x04, 0x06][bytes.int(0...1)] }
            let out = e.receive(payload, now: t0)
            XCTAssertFalse(out.messages.contains { $0.payload.first == 0x05 }, "only a user change can lead to a write")
        }
    }

    // MARK: Over the link

    func testOverTheEncryptedLinkWithTheSimulatedStrap() throws {
        let device = FakeZeppDevice(authKey: hex("00112233445566778899aabbccddeeff"), privateKey: SpecC.strapDrawnPrivate,
                                    random: SpecC.strapRandom, writeLength: 20)
        device.services = ControlsFixtures.controlServices
        device.configCapabilitiesReply = hex("02 03 05 00 0b 08 09 0a")
        var health = Health()
        func serve() {
            device.configReplies[ZeppSettingsEditor.readRequest(group: 0x08)] = health.full
            device.configReplies[ZeppSettingsEditor.familyRequest(.stressMonitoring)] = health.reply([0x13])
        }
        serve()
        device.onConfigWrite = { write in
            if write == hex("05 08 03 00 01 13 0b 00") { health.stress = false }
            serve()
        }
        var link = ZeppLink(authKey: SpecC.authKey, random: .system, maxWriteLength: 20)
        XCTAssertEqual(pump(&link, device, link.startAuthentication().writes), [.authenticated])
        var list: ZeppServicesList?
        for case .message(let m) in pump(&link, device, try link.send(endpoint: ZeppEndpoint.servicesList,
                                                                       payload: ZeppServicesList.request)) {
            list = ZeppServicesList.parse(m.payload)
        }
        link.apply(servicesList: try XCTUnwrap(list))
        var e = ZeppSettingsEditor(capabilities: ZeppControlCapabilities(model: .helioStrap, isAuthenticated: true, services: list))
        var events: [ZeppSettingsEditor.Event] = []
        func run(_ messages: [ZeppControlMessage]) throws {
            var queue = messages
            while !queue.isEmpty {
                let next = queue.removeFirst()
                for case .message(let reply) in pump(&link, device, try link.send(endpoint: next.endpoint, payload: next.payload)) {
                    XCTAssertTrue(reply.wasEncrypted, "config is encrypted on the Helio (§17.1)")
                    if reply.payload.first == 0x02 {
                        e.noteConfigCapabilities(ZeppConfigCapabilities.parse(reply.payload))
                        continue
                    }
                    let out = e.receive(reply.payload, now: t0)
                    events += out.events
                    queue += out.messages
                }
            }
        }
        try run([ZeppControlMessage(endpoint: ZeppEndpoint.config, payload: ZeppConfigCapabilities.request)])
        XCTAssertTrue(e.isOffered(group: 0x08))
        try run(try e.read(groups: [0x08], now: t0).messages)
        XCTAssertEqual(device.configWrites, [], "reading writes nothing")
        try run(try e.change(.init(setting: .stressMonitoring, from: .bool(true), to: .bool(false)), now: t0).messages)
        XCTAssertEqual(device.configWrites, [hex("05 08 03 00 01 13 0b 00")], "exactly one write, one entry")
        guard case .writeChecked(let check)? = events.last else { return XCTFail("\(events)") }
        XCTAssertTrue(check.tookChange)
        XCTAssertEqual(e.snapshot.availability(.relaxReminder), .needs(.stressMonitoring))
        XCTAssertEqual(device.failures, [])
    }
}

import XCTest
import OpenCircuitKit
import ZeppKit
@testable import OpenCircuit

// The strap's settings in the app (#228, #229, #230): `HelioSession` drives `ZeppSettingsEditor`
// against the simulated strap (`FakeZeppDevice`), including review-240's probes of a sync or
// backgrounding that lands between the tap and the write. Every key and setting is made up.

private let keyHex = "00112233445566778899aabbccddeeff"

/// The endpoints a Helio lists (§3.5), config encrypted.
private let services: [(endpoint: UInt16, flag: UInt8)] = [
    (0x0000, 0), (0x000A, 1), (0x000F, 0), (0x001A, 1), (0x0029, 0), (0x0043, 0), (0x0047, 0), (0x0082, 0),
]

/// The strap's HEALTH and WORKOUT settings, made up: HR smart; active HR off; sleep on; breathing on;
/// stress on; SpO₂ off; high HR off (0/100/110/120); low HR off (0/40/45/50); relax off; low SpO₂ off
/// (0/80/85/90); workout alert off; sensitivity standard (high/standard/low).
private final class StrapSettings {
    var stress = true
    var spo2 = false
    var highHR: UInt8 = 0
    var workoutAlert = false

    func entry(_ group: UInt8, _ arg: UInt8) -> [UInt8]? {
        switch (group, arg) {
        case (0x08, 0x01): return [0x01, 0x10, 0xff, 0x04, 0x00, 0xff, 0x05, 0x0a]
        case (0x08, 0x04): return [0x04, 0x0b, 0x00]
        case (0x08, 0x11): return [0x11, 0x0b, 0x01]
        case (0x08, 0x12): return [0x12, 0x0b, 0x01]
        case (0x08, 0x13): return [0x13, 0x0b, stress ? 0x01 : 0x00]
        case (0x08, 0x31): return [0x31, 0x0b, spo2 ? 0x01 : 0x00]
        case (0x08, 0x02): return [0x02, 0x10, highHR, 0x04, 0, 100, 110, 120]
        case (0x08, 0x03): return [0x03, 0x10, 0x00, 0x04, 0, 40, 45, 50]
        case (0x08, 0x14): return [0x14, 0x0b, 0x00]
        case (0x08, 0x32): return [0x32, 0x10, 0x00, 0x04, 0, 80, 85, 90]
        case (0x09, 0x41): return [0x41, 0x0b, workoutAlert ? 0x01 : 0x00]
        case (0x09, 0x42): return [0x42, 0x10, 0x01, 0x03, 0x00, 0x01, 0x02]
        default: return nil
        }
    }

    /// Answers `03 01 <group> <n> <args…>` with the args it has (HEALTH v3, WORKOUT v1).
    func answer(_ request: [UInt8]) -> [UInt8]? {
        guard request.count >= 4, request[0] == 0x03, request[1] == 0x01 else { return nil }
        let group = request[2]
        let entries = request.dropFirst(4).compactMap { entry(group, $0) }
        return [0x04, 0x01, group, group == 0x08 ? 0x03 : 0x01, 0x01, UInt8(entries.count)] + entries.flatMap { $0 }
    }

    /// Applies a write the way a strap that takes it would.
    func apply(_ write: [UInt8]) {
        switch Array(write.dropFirst(5)) {
        case [0x31, 0x0b, 0x01]: spo2 = true
        case [0x13, 0x0b, 0x00]: stress = false
        case [0x41, 0x0b, 0x01]: workoutAlert = true
        default: break
        }
    }
}

@MainActor
private final class SettingsTransport: HelioTransport {
    let device: FakeZeppDevice
    weak var session: HelioSession?
    var available = Set(ZeppCharacteristic.allCases).subtracting([.firmwareRevision, .currentTime])
    var maxWriteLength = 244
    private var inbox: [(ZeppCharacteristic, [UInt8]?, Bool)] = []

    init(device: FakeZeppDevice) { self.device = device }

    func has(_ characteristic: ZeppCharacteristic) -> Bool { available.contains(characteristic) }
    func canNotify(_ characteristic: ZeppCharacteristic) -> Bool {
        has(characteristic) && ![ZeppCharacteristic.hardwareRevision, .firmwareRevision, .currentTime].contains(characteristic)
    }
    func write(_ write: ZeppWrite) {
        for n in device.phoneWrote(write) { inbox.append((n.characteristic, n.bytes, false)) }
    }
    func setNotify(_ characteristic: ZeppCharacteristic, enabled: Bool) { inbox.append((characteristic, nil, enabled)) }
    func read(_ characteristic: ZeppCharacteristic) {
        if characteristic == .batteryLevel { inbox.append((characteristic, [64], false)) }
    }
    func drain() {
        var guardCount = 0
        while !inbox.isEmpty, guardCount < 100_000 {
            guardCount += 1
            let (characteristic, bytes, enabled) = inbox.removeFirst()
            if let bytes {
                session?.received(characteristic, bytes)
            } else {
                session?.notificationStateChanged(characteristic, enabled: enabled, failed: false)
            }
        }
    }
}

@MainActor
private final class Keys: HelioKeyStoring {
    var text: String?
    var isRejected = false
    init(_ text: String?) { self.text = text }
    func load() -> ZeppAuthKey? { text.flatMap(HelioKeyText.parse) }
    func save(pasted text: String) throws -> Bool { self.text = text; return true }
    func forget() { text = nil }
    func markRejected() { isRejected = true }
}

/// A sink that stores nothing: these tests only need a sync to be running.
@MainActor
private final class NullSink: HelioHistorySink {
    func fetchCursors(timeline: SyncDeviceID, now: Date) -> [ZeppFetchType: Date] { [:] }
    func notBefore(timeline: SyncDeviceID, now: Date) -> Date? { nil }
    func beginSync(timeline: SyncDeviceID, now: Date) {}
    func persist(_ round: ZeppFetchRound, timeline: SyncDeviceID, now: Date) -> Bool { true }
    func finishSync(timeline: SyncDeviceID, now: Date) -> HelioSyncResult { HelioSyncResult() }
}

@MainActor
final class HelioSettingsTests: XCTestCase {
    private let strapID = "5B1E4C2A-0000-4000-8000-0000000000B2"
    private var now = Date(timeIntervalSince1970: 1_789_905_600)
    private var strap = StrapSettings()

    override func setUp() {
        super.setUp()
        strap = StrapSettings()
    }

    private func makeStrap() -> FakeZeppDevice {
        let device = FakeZeppDevice(authKey: ZeppHex.bytes(keyHex)!, privateKey: Array(UInt8(0x81)...UInt8(0x98)),
                                    random: Array(UInt8(0xf0)...UInt8(0xff)), writeLength: 244)
        device.services = services
        device.deviceInfoReply = [0x02, 0x01, 0x0c, 0, 0, 0, 0, 0, 0, 0] + Array("9.9.9.9".utf8) + [0] + Array("1.2.3.4".utf8) + [0]
        device.configCapabilitiesReply = [0x02, 0x03, 0x05, 0x00, 0x0b, 0x08, 0x09, 0x0a]
        device.configReadHandler = { [strap = self.strap] in strap.answer($0) }
        return device
    }

    private func connect(_ device: FakeZeppDevice, key: String? = keyHex,
                         sink: (any HelioHistorySink)? = nil) -> (HelioSession, SettingsTransport) {
        let transport = SettingsTransport(device: device)
        let keys = Keys(key)
        let session = HelioSession(transport: transport, identityID: strapID, key: keys.load(), keyStore: keys, sink: sink,
                                   findState: HelioFindState(), clock: { [unowned self] in self.now },
                                   autoTick: false, autoSyncOnConnect: false)
        transport.session = session
        session.start()
        transport.drain()
        return (session, transport)
    }

    func testConnectingWritesNoSettingAndReadsNoneUntilAScreenAsks() {
        let device = makeStrap()
        let (session, _) = connect(device)
        XCTAssertEqual(session.phase, .ready)
        XCTAssertEqual(device.configWrites, [], "§15.1: nothing is written at setup")
        XCTAssertTrue(session.canChangeStrapSettings)
        XCTAssertEqual(session.settingsEditor?.hasRead(group: 0x08), false)
    }

    func testReadingShowsTheStrapsValuesAndFeedsTheRecordingWarnings() throws {
        let device = makeStrap()
        let (session, transport) = connect(device)
        session.readStrapSettings(groups: [0x08])
        transport.drain()
        let config = try XCTUnwrap(session.settingsEditor?.snapshot)
        XCTAssertEqual(config.value(.heartRateMonitoring), .byte(0xff))
        XCTAssertEqual(config.availability(.lowSpO2Alert), .needs(.allDaySpO2))
        XCTAssertEqual(session.recordingWarnings, ["All-day SpO₂ is off, so automatic SpO₂ readings will be empty."])
        XCTAssertEqual(HelioSettingsDisplayCache.entry(strap: strapID)?.snapshot, config, "kept for display only")
        XCTAssertEqual(device.configWrites, [])
    }

    func testOneChangeWritesOneArgThenShowsTheReRead() throws {
        let device = makeStrap()
        device.onConfigWrite = { [strap = self.strap] in strap.apply($0) }
        let (session, transport) = connect(device)
        session.readStrapSettings(groups: [0x08])
        transport.drain()
        XCTAssertNil(session.changeStrapSetting(.allDaySpO2, from: .bool(false), to: .bool(true)))
        transport.drain()
        XCTAssertEqual(device.configWrites, [[0x05, 0x08, 0x03, 0x00, 0x01, 0x31, 0x0b, 0x01]])
        XCTAssertEqual(session.settingsNotice?.text, "Saved on the strap.")
        XCTAssertEqual(session.settingsEditor?.snapshot.value(.allDaySpO2), .bool(true))
        XCTAssertEqual(session.settingsEditor?.snapshot.availability(.lowSpO2Alert), .available)
        XCTAssertEqual(session.recordingWarnings, [], "the warning follows the strap's new value")
    }

    func testARejectedWriteShowsTheStrapsActualValueAndSaysSo() throws {
        let device = makeStrap()
        device.configWriteAckStatus = 0x02
        let (session, transport) = connect(device)
        session.readStrapSettings(groups: [0x08])
        transport.drain()
        XCTAssertNil(session.changeStrapSetting(.highHeartRateAlert, from: .byte(0), to: .byte(110)))
        transport.drain()
        XCTAssertEqual(device.configWrites.count, 1, "never retried")
        XCTAssertEqual(session.settingsEditor?.snapshot.value(.highHeartRateAlert), .byte(0), "the re-read value")
        XCTAssertEqual(session.settingsNotice?.text,
                       "The strap didn't take the change. Its current value is shown. Nothing was retried.")
    }

    func testAValueChangedElsewhereIsNotOverwritten() throws {
        let device = makeStrap()
        let (session, transport) = connect(device)
        session.readStrapSettings(groups: [0x08])
        transport.drain()
        strap.highHR = 120   // changed in Zepp
        XCTAssertNil(session.changeStrapSetting(.highHeartRateAlert, from: .byte(0), to: .byte(110)))
        transport.drain()
        XCTAssertEqual(device.configWrites, [])
        XCTAssertEqual(session.settingsEditor?.snapshot.value(.highHeartRateAlert), .byte(120))
        XCTAssertTrue(session.settingsNotice?.text.contains("changed on the strap") == true)
    }

    func testRefusedChangesSendNothing() throws {
        let device = makeStrap()
        let (session, transport) = connect(device)
        session.readStrapSettings(groups: [0x08])
        transport.drain()
        XCTAssertEqual(session.changeStrapSetting(.lowSpO2Alert, from: .byte(0), to: .byte(90)), "Needs all-day SpO₂ on. Turn it on in Measurement.")
        XCTAssertEqual(session.changeStrapSetting(.highHeartRateAlert, from: .byte(0), to: .byte(105)),
                       "The strap doesn't allow that value.")
        XCTAssertEqual(session.changeStrapSetting(.stressMonitoring, from: .bool(true), to: .bool(true)),
                       "That's already the strap's setting.")
        transport.drain()
        XCTAssertEqual(device.configWrites, [])
    }

    func testWorkoutDetectionWritesOnlyTheAlertOrTheSensitivity() throws {
        let device = makeStrap()
        device.onConfigWrite = { [strap = self.strap] in strap.apply($0) }
        let (session, transport) = connect(device)
        session.readStrapSettings(groups: [ZeppConfig.workoutGroup])
        transport.drain()
        let snapshot = try XCTUnwrap(session.settingsEditor?.snapshot)
        XCTAssertEqual(snapshot.value(.workoutDetectionSensitivity), .byte(1))
        XCTAssertNil(session.changeStrapSetting(.workoutDetectionAlert, from: .bool(false), to: .bool(true)))
        transport.drain()
        XCTAssertEqual(device.configWrites, [[0x05, 0x09, 0x01, 0x00, 0x01, 0x41, 0x0b, 0x01]], "WORKOUT v1 echoed, one entry")
        XCTAssertEqual(session.settingsNotice?.text, "Saved on the strap.")
        XCTAssertFalse(device.configWrites.contains { $0.count > 5 && $0[1] == 0x09 && $0[5] == 0x40 }, "categories never written")
    }

    func testNoChangeDuringAHistoryFetch() throws {
        let device = makeStrap()
        let sink = NullSink()
        let (session, transport) = connect(device, sink: sink)
        session.readStrapSettings(groups: [0x08])
        transport.drain()
        session.syncHistory(manual: true)   // notify-enable is queued, not drained: the sync stays open
        XCTAssertEqual(session.phase, .syncing)
        XCTAssertTrue(session.canReadStrapSettings)
        XCTAssertFalse(session.canChangeStrapSettings, "§17.8 step 1")
        XCTAssertEqual(session.changeStrapSetting(.stressMonitoring, from: .bool(true), to: .bool(false)),
                       "Settings can be changed when the sync finishes.")
        XCTAssertEqual(device.configWrites, [])
    }

    func testAKeylessStrapOffersNoChanges() {
        let device = makeStrap()
        let (session, transport) = connect(device, key: nil)
        XCTAssertEqual(session.phase, .keyless)
        XCTAssertFalse(session.canReadStrapSettings)
        session.readStrapSettings(groups: [0x08])
        XCTAssertNotNil(session.changeStrapSetting(.stressMonitoring, from: .bool(true), to: .bool(false)))
        transport.drain()
        XCTAssertEqual(device.configWrites, [])
        let reason = HelioSettingsCopy.blockedReason(status: HelioStatus.keyNeeded, canChange: false, offered: nil)
        XCTAssertEqual(reason, "Add the strap's key to change its settings.")
    }

    func testEveryStatusExplainsItselfAndOnlyAUsableSessionUnblocks() {
        let kinds: [HelioStatus] = [HelioStatus.busy, .keyNeeded, .rejected,
                                    HelioStatus(kind: .disconnected, title: "Not connected", detail: nil, tone: .neutral),
                                    HelioStatus(kind: .settingUp, title: "", detail: nil, tone: .working)]
        for status in kinds {
            XCTAssertNotNil(HelioSettingsCopy.blockedReason(status: status, canChange: false, offered: nil))
        }
        let ready = HelioStatus(kind: .ready, title: "Connected", detail: nil, tone: .good)
        XCTAssertNil(HelioSettingsCopy.blockedReason(status: ready, canChange: true, offered: true))
        XCTAssertEqual(HelioSettingsCopy.blockedReason(status: ready, canChange: false, offered: false),
                       "The strap didn't offer these settings on this connection.")
        XCTAssertTrue(HelioSettingsCopy.blockedReason(status: HelioStatus.busy, canChange: false, offered: nil)!
            .contains("Another phone or app"))
    }

    func testCopyNamesValuesTheWayTheStrapMeansThem() {
        XCTAssertEqual(HelioSettingsCopy.value(.byte(0xff), for: .heartRateMonitoring), "Smart")
        XCTAssertEqual(HelioSettingsCopy.value(.byte(0), for: .heartRateMonitoring), "Off")
        XCTAssertEqual(HelioSettingsCopy.value(.byte(10), for: .heartRateMonitoring), "Every 10 min")
        XCTAssertEqual(HelioSettingsCopy.value(.byte(120), for: .highHeartRateAlert), "Above 120 bpm")
        XCTAssertEqual(HelioSettingsCopy.value(.byte(45), for: .lowHeartRateAlert), "Below 45 bpm")
        XCTAssertEqual(HelioSettingsCopy.value(.byte(90), for: .lowSpO2Alert), "Below 90 %")
        XCTAssertEqual(HelioSettingsCopy.needs(.stressMonitoring), "Needs stress monitoring on. Turn it on in Measurement.")
        XCTAssertNil(HelioSettingsCopy.offConsequence(.activeHeartRateMonitoring, .bool(false)),
                     "§5.5: it doesn't gate recording, so off is never a warning")
        XCTAssertTrue(HelioSettingsCopy.explanation(.activeHeartRateMonitoring).contains("doesn't decide whether heart rate is recorded"))
        XCTAssertTrue(HelioSettingsCopy.alertsHeader.contains("OpenCircuit isn't notified"), "§20.1")
        XCTAssertTrue(HelioSettingsCopy.workoutHeader.contains("asks you to review each one"), "decision 91: strap records are imported for review")
        XCTAssertFalse(HelioSettingsCopy.workoutHeader.contains("doesn't import"), "#226 shipped the import")
        XCTAssertTrue(HelioSettingsCopy.workoutHeader.contains("battery"), "§19.3")
        XCTAssertEqual(HelioSettingsCopy.value(.byte(0xfe), for: .heartRateMonitoring), "Continuous")
        XCTAssertEqual(HelioSettingsCopy.value(.byte(0), for: .workoutDetectionSensitivity), "High")
        XCTAssertEqual(HelioSettingsCopy.value(.byte(1), for: .workoutDetectionSensitivity), "Standard")
        for setting in ZeppSetting.allCases {
            let text = HelioSettingsCopy.explanation(setting)
            if ZeppSetting.measurement.contains(setting) {
                XCTAssertFalse(text.contains { $0.isASCII && $0.isNumber }, "battery cost in words: no invented figures")
            }
            XCTAssertFalse(text.unicodeScalars.contains { $0.properties.isEmojiPresentation }, "no emoji")
        }
    }

    // MARK: review-240: the write itself is gated, not only the tap (§17.8 step 1)

    /// S1: a sync (pull-to-refresh, "Sync now", #225's wake or BGTask run) that starts while a
    /// change's pre-read is in flight. The write must not go out during the fetch.
    func testASyncStartingMidChangeLetsNoWriteOut() {
        let device = makeStrap()
        let (session, transport) = connect(device, sink: NullSink())
        session.readStrapSettings(groups: [0x08])
        transport.drain()
        var phaseAtWrite: HelioSession.Phase?
        device.onConfigWrite = { [unowned session] _ in phaseAtWrite = session.phase }
        XCTAssertNil(session.changeStrapSetting(.stressMonitoring, from: .bool(true), to: .bool(false)))
        session.syncHistory(manual: false)
        XCTAssertEqual(session.phase, .syncing, "a sync never waits on the settings editor")
        transport.drain()
        XCTAssertEqual(device.configWrites, [], "a config write went out with phase \(String(describing: phaseAtWrite))")
        XCTAssertEqual(session.settingsNotice?.text, "Not saved: a sync started. Try again when it finishes.")
        XCTAssertEqual(session.settingsNotice?.setting, .stressMonitoring)
        XCTAssertEqual(session.settingsEditor?.isBusy, false)
        XCTAssertEqual(session.settingsEditor?.snapshot.value(.stressMonitoring), .bool(true), "the last read value stays")
    }

    /// S2: the app goes to the background while a change's pre-read is in flight.
    func testBackgroundingMidChangeLetsNoWriteOut() {
        let device = makeStrap()
        let (session, transport) = connect(device)
        session.readStrapSettings(groups: [0x08])
        transport.drain()
        XCTAssertNil(session.changeStrapSetting(.stressMonitoring, from: .bool(true), to: .bool(false)))
        session.appDidEnterBackground()
        transport.drain()
        XCTAssertEqual(device.configWrites, [], "a config write went out after appDidEnterBackground")
        XCTAssertTrue(session.settingsNotice?.text.contains("background") == true)
        // And a tap from the background is refused outright.
        XCTAssertFalse(session.canChangeStrapSettings)
        XCTAssertEqual(session.changeStrapSetting(.stressMonitoring, from: .bool(true), to: .bool(false)),
                       "Settings can be changed with the app open.")
        // Back in front, the same change goes out.
        session.appDidBecomeActive()
        XCTAssertNil(session.changeStrapSetting(.stressMonitoring, from: .bool(true), to: .bool(false)))
        transport.drain()
        XCTAssertEqual(device.configWrites, [[0x05, 0x08, 0x03, 0x00, 0x01, 0x13, 0x0b, 0x00]])
    }

    /// Two quick taps before any reply: one write. A re-read that disagrees never says "saved", and a
    /// change built on the stale screen value writes nothing.
    func testTwoQuickTapsWriteOnce() {
        let device = makeStrap()
        let (session, transport) = connect(device)
        session.readStrapSettings(groups: [0x08])
        transport.drain()
        XCTAssertNil(session.changeStrapSetting(.stressMonitoring, from: .bool(true), to: .bool(false)))
        XCTAssertEqual(session.changeStrapSetting(.highHeartRateAlert, from: .byte(0), to: .byte(110)),
                       "Another change is still being saved.")
        transport.drain()
        XCTAssertEqual(device.configWrites, [[0x05, 0x08, 0x03, 0x00, 0x01, 0x13, 0x0b, 0x00]])
        XCTAssertNotEqual(session.settingsNotice?.text, "Saved on the strap.", "the fake strap didn't apply it")
        XCTAssertNil(session.changeStrapSetting(.stressMonitoring, from: .bool(false), to: .bool(true)))
        transport.drain()
        XCTAssertEqual(device.configWrites.count, 1, "stale from: nothing written")
    }

    /// The re-read times out after a `06 01`: never "saved".
    func testAReReadTimeoutNeverSaysSaved() {
        let device = makeStrap()
        let (session, transport) = connect(device)
        session.readStrapSettings(groups: [0x08])
        transport.drain()
        var reads = 0
        device.configReadHandler = { [strap = self.strap] request in
            reads += 1
            return reads == 1 ? strap.answer(request) : []   // the strap never answers the re-read
        }
        XCTAssertNil(session.changeStrapSetting(.stressMonitoring, from: .bool(true), to: .bool(false)))
        transport.drain()
        XCTAssertEqual(device.configWrites.count, 1)
        now = now.addingTimeInterval(6)
        session.tick(now: now)
        transport.drain()
        XCTAssertNotEqual(session.settingsNotice?.text, "Saved on the strap.")
        XCTAssertEqual(session.settingsEditor?.isBusy, false)
    }

    /// N2: a notice belongs to its setting, and a fresh read clears it.
    func testANoticeIsKeyedToItsSettingAndAFreshReadClearsIt() {
        let device = makeStrap()
        device.onConfigWrite = { [strap = self.strap] in strap.apply($0) }
        let (session, transport) = connect(device)
        session.readStrapSettings(groups: [0x08])
        transport.drain()
        XCTAssertNil(session.changeStrapSetting(.allDaySpO2, from: .bool(false), to: .bool(true)))
        transport.drain()
        let notice = session.settingsNotice
        XCTAssertEqual(notice?.text, "Saved on the strap.")
        XCTAssertEqual(notice?.belongs(to: ZeppSetting.measurement), true)
        XCTAssertEqual(notice?.belongs(to: ZeppSetting.workoutDetection), false, "not shown on another screen")
        XCTAssertEqual(notice?.belongs(to: ZeppSetting.alerts), false)
        session.readStrapSettings(groups: [0x08])
        XCTAssertNil(session.settingsNotice, "a fresh read clears the last outcome")
    }

    /// N-a: with a switch that reads off and an allowed list that can't turn it on (empty, or off
    /// only), the card must not point at Measurement: the row there is a disabled control.
    func testTheTodayCardNeverPointsAtARowThatCannotTurnTheSwitchOn() {
        for allowed in [[UInt8](), [0x00]] {
            let device = makeStrap()
            // All-day HR reads off with `allowed`; every other recording switch on, so it is the only
            // warning. No arg 04, so the §17.7 HR requirement doesn't apply to anything here.
            device.configReadHandler = { request in
                guard request.count >= 4, request[0] == 0x03, request[1] == 0x01, request[2] == 0x08 else { return nil }
                let hr: [UInt8] = [0x01, 0x10, 0x00, UInt8(allowed.count)] + allowed
                return [0x04, 0x01, 0x08, 0x03, 0x01, 0x05] + hr
                    + [0x11, 0x0b, 0x01, 0x12, 0x0b, 0x01, 0x13, 0x0b, 0x01, 0x31, 0x0b, 0x01]
            }
            let (session, transport) = connect(device)
            session.readStrapSettings(groups: [0x08])
            transport.drain()
            let snapshot = try! XCTUnwrap(session.settingsEditor?.snapshot)
            XCTAssertEqual(snapshot.value(.heartRateMonitoring), .byte(0), "allowed \(allowed)")
            XCTAssertEqual(session.recordingWarnings.count, 1, "allowed \(allowed): the all-day HR warning shows")
            // The same condition the row uses to enable its control.
            let rowCanTurnItOn = snapshot.availability(.heartRateMonitoring) == .available
                && snapshot.options(.heartRateMonitoring).contains { $0 != .byte(0) }
            XCTAssertFalse(rowCanTurnItOn, "allowed \(allowed)")
            XCTAssertFalse(session.canFixRecordingWarningsHere,
                           "allowed \(allowed): the card must not send the user to a row that can't turn it on")
        }
    }

    /// S-1: a re-read that never answers after `06 01` leaves the row visible, with the last READ
    /// value (never the written one) and the "couldn't be read back" notice. It must not say "Saved".
    func testAReReadThatNeverAnswersKeepsTheRowWithItsLastReadValue() {
        let device = makeStrap()
        device.onConfigWrite = { [strap = self.strap] in strap.apply($0) }
        let (session, transport) = connect(device)
        session.readStrapSettings(groups: [0x08])
        transport.drain()
        XCTAssertEqual(session.settingsEditor?.snapshot.value(.stressMonitoring), .bool(true))
        // Set BEFORE the change: the fake answers a read synchronously inside the write, so the
        // pre-read is call 1 and the re-read is call 2, which the strap leaves unanswered ([]).
        var reads = 0
        device.configReadHandler = { [strap = self.strap] request in
            reads += 1
            return reads == 1 ? strap.answer(request) : []
        }
        XCTAssertNil(session.changeStrapSetting(.stressMonitoring, from: .bool(true), to: .bool(false)))
        transport.drain()
        XCTAssertEqual(reads, 2, "the pre-read was answered and the re-read was not")
        XCTAssertEqual(device.configWrites.count, 1)
        now = now.addingTimeInterval(6)
        session.tick(now: now)
        transport.drain()

        let snapshot = try! XCTUnwrap(session.settingsEditor?.snapshot)
        XCTAssertEqual(snapshot.value(.stressMonitoring), .bool(true),
                       "the row stays, with the last READ value, never the written one")
        XCTAssertEqual(snapshot.availability(.stressMonitoring), .available)
        XCTAssertFalse(snapshot.hidden.contains(.stressMonitoring))
        XCTAssertEqual(session.settingsEditor?.readFailures[0x08], .timedOut)
        XCTAssertEqual(session.settingsNotice?.text,
                       "The strap confirmed the change, but the setting couldn't be read back. Reopen this screen to check.")
        XCTAssertNotEqual(session.settingsNotice?.text, "Saved on the strap.")
        XCTAssertEqual(session.settingsEditor?.isBusy, false)
    }

    /// The other half of §17.5: a re-read that ANSWERS without the entry still hides it.
    func testAReReadThatAnswersWithoutTheSettingStillHidesIt() {
        let device = makeStrap()
        let (session, transport) = connect(device)
        session.readStrapSettings(groups: [0x08])
        transport.drain()
        var reads = 0
        device.configReadHandler = { [strap = self.strap] request in
            reads += 1
            // The re-read answers, well-formed and with constraints, but with no entries at all.
            return reads == 1 ? strap.answer(request) : [0x04, 0x01, 0x08, 0x03, 0x01, 0x00]
        }
        XCTAssertNil(session.changeStrapSetting(.stressMonitoring, from: .bool(true), to: .bool(false)))
        transport.drain()
        let snapshot = try! XCTUnwrap(session.settingsEditor?.snapshot)
        XCTAssertNil(snapshot.value(.stressMonitoring), "§17.5: missing on an answered re-read → hidden")
        XCTAssertEqual(snapshot.availability(.stressMonitoring), .notReported)
        XCTAssertTrue(snapshot.hidden.contains(.stressMonitoring))
        XCTAssertNotEqual(session.settingsNotice?.text, "Saved on the strap.")
    }

    /// N3: the Today card points at Measurement only when that screen can change the switches now.
    func testTheTodayCardPointsAtMeasurementOnlyWhenItCanFixIt() {
        strap.spo2 = false
        let device = makeStrap()
        let (session, transport) = connect(device)
        XCTAssertFalse(session.canFixRecordingWarningsHere, "not read yet: unknown, so not claimed")
        session.readStrapSettings(groups: [0x08])
        transport.drain()
        XCTAssertTrue(session.canFixRecordingWarningsHere)
        session.appDidEnterBackground()
        XCTAssertFalse(session.canFixRecordingWarningsHere)
        let (keyless, _) = connect(makeStrap(), key: nil)
        XCTAssertFalse(keyless.canFixRecordingWarningsHere)
    }

    /// N1, N4: an inactive child reads as text, and an all-day HR byte outside §17.9 isn't guessed.
    func testInactiveValuesAndUnknownIntervals() {
        XCTAssertEqual(HelioSettingsCopy.inactiveValue(.bool(true), for: .relaxReminder, availability: .needs(.stressMonitoring)),
                       "On (inactive: needs stress monitoring on)")
        XCTAssertEqual(HelioSettingsCopy.inactiveValue(.byte(110), for: .highHeartRateAlert, availability: .needs(.heartRateMonitoring)),
                       "Above 110 bpm (inactive: needs all-day heart rate on)")
        XCTAssertEqual(HelioSettingsCopy.inactiveValue(.bool(false), for: .stressMonitoring, availability: .readOnly), "Off (read-only)")
        XCTAssertEqual(HelioSettingsCopy.value(.byte(0x78), for: .heartRateMonitoring), "Every 120 min")
        XCTAssertEqual(HelioSettingsCopy.value(.byte(0x79), for: .heartRateMonitoring), "Unknown (0x79)")
        XCTAssertEqual(HelioSettingsCopy.value(.byte(0xfd), for: .heartRateMonitoring), "Unknown (0xfd)")
    }
}

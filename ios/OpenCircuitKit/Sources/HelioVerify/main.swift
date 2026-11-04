// HelioVerify — macOS CoreBluetooth check against a real Amazfit Helio Strap / Ring (#215).
//
// Thin glue only: it moves bytes between CoreBluetooth and ZeppKit's pure state machines
// (`ZeppLink`, `ZeppHistoryFetch`) and prints what they decide. The auth key is never printed or
// logged, nor are the strap's serial number and PnP ID. `--trace` prints the history fetch's
// control bytes and each data packet's length and counter, never a data payload. The history fetch acks `03 09` (keep on strap) unless
// `--allow-delete` AND `--out` are both given; then a round is delete-acked only if its transfer
// done carried a matching CRC, and only after its raw bytes are written to `--out` (a regular file)
// and flushed to the drive with F_FULLFSYNC.
//
// Device controls (`--find`, `--vibrate`, `--alarms`, `--set-alarm`, `--delete-alarm`, `--alerts`)
// live in Controls.swift; strap settings (`--settings`, `--set-config`, `--config-probe`) in
// Settings.swift. Every write of strap settings (`--set-time`, and the alarm writes, which
// set the clock first) needs `--allow-write`; dropping fetched data needs `--allow-delete`.

import CoreBluetooth
import Foundation
import ZeppKit

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(code)
}

/// Parses the command line, or prints why not (or the help) and exits.
func parseCommandLine() -> Options {
    do {
        return try parseOptions(Array(CommandLine.arguments.dropFirst()))
    } catch OptionsError.help {
        print(usage)
        exit(0)
    } catch OptionsError.invalid(let message) {
        fail(message)
    } catch {
        fail("\(error)")
    }
}

/// Reads and parses the key file. Never echoes its contents, even on error.
func loadKey(_ path: String) -> ZeppAuthKey {
    guard let data = FileManager.default.contents(atPath: path),
          let text = String(data: data, encoding: .utf8) else { fail("cannot read --key-file") }
    guard let key = ZeppAuthKey(hex: text) else {
        fail("--key-file must hold exactly 32 hex digits (optionally 0x-prefixed); contents not shown")
    }
    return key
}

// MARK: - Verifier

@available(macOS 10.15.4, *)
final class HelioVerifier: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {

    enum Step: String {
        case scanning, connecting, discovering, readingBasics, liveHR, enablingChunked, authenticating,
             servicesList, deviceInfo, battery, setTime, config, authedHR, enablingFetch, fetching, controls, done
    }

    let options: Options
    let key: ZeppAuthKey?
    var central: CBCentralManager!
    var peripheral: CBPeripheral?
    var characteristics: [ZeppCharacteristic: CBCharacteristic] = [:]
    var step = Step.scanning
    var pendingServices = 0
    var pendingReads = Set<ZeppCharacteristic>()
    var pendingNotify = Set<ZeppCharacteristic>()
    var link: ZeppLink?
    var services: ZeppServicesList?
    var fetch: ZeppHistoryFetch?
    var writeQueue: [ZeppWrite] = []
    var hrTimer: DispatchSourceTimer?
    var outHandle: FileHandle?
    var roundsDelivered = 0
    var isFinishing = false
    // Device controls (Controls.swift).
    var model: ZeppDeviceModel?
    var controlCapabilities = ZeppControlCapabilities.disconnected
    var find = ZeppFindDevice()
    var alarmEditor: ZeppAlarmEditor?
    var controlTasks: [ControlTask] = []
    var controlWait: ControlWait?
    var controlWaitToken = 0
    var controlTimer: DispatchSourceTimer?
    var configCapabilities: ZeppConfigCapabilities?
    // Strap settings (Settings.swift).
    var settingsEditor: ZeppSettingsEditor?
    var settingsSteps: [SettingsStep] = []
    var rawGroupQueue: [UInt8] = []
    var rawGroupInFlight: UInt8?
    var probeRun: ProbeRun?
    // Workout-mode test (Workout.swift).
    var workout = WorkoutTestState()
    var endStage = 0
    /// DIS 0x2A27, to cross-check the device-info hardware version.
    var disHardwareRevision: String?

    init(options: Options, key: ZeppAuthKey?) {
        self.options = options
        self.key = key
        super.init()
        if let path = options.outPath {
            switch OutFile.open(path) {
            case .success(let handle): outHandle = handle
            case .failure(let problem): fail(problem.description)
            }
        }
        central = CBCentralManager(delegate: self, queue: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + options.timeoutSeconds) { [weak self] in
            self?.finish("timed out in step '\(self?.step.rawValue ?? "?")'", code: 3)
        }
    }

    func log(_ message: String) { print(message) }

    func finish(_ message: String? = nil, code: Int32 = 0) {
        guard !isFinishing else { return }
        isFinishing = true
        if let message { log(code == 0 ? message : "FAILED: \(message)") }
        hrTimer?.cancel()
        controlTimer?.cancel()
        if var fetch, fetch.phase != .finished && fetch.phase != .idle {
            // Never leave the strap mid-round; the abort ack is always 03 09 (keep).
            perform(fetch.abort())
            self.fetch = fetch
        }
        try? outHandle?.close()
        // Never leave the strap buzzing: pair a running find or buzz with its stop, and give the
        // write a moment to go out before disconnecting.
        let stoppingFind = stopFindBeforeExit()
        let endingWorkout = endWorkoutBeforeExit()
        workout.keepAliveTimer?.cancel()
        workout.endTimer?.cancel()
        workout.hrKeepAlive?.cancel()
        let stopping = stoppingFind || endingWorkout
        let central: CBCentralManager? = self.central
        let peripheral = self.peripheral
        DispatchQueue.main.asyncAfter(deadline: .now() + (stopping ? 0.5 : 0)) {
            if let peripheral { central?.cancelPeripheralConnection(peripheral) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(code) }
        }
    }

    // MARK: Central

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            log("scanning for Amazfit Helio devices…")
            central.scanForPeripherals(withServices: nil, options: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + options.scanSeconds) { [weak self] in
                guard let self, self.step == .scanning else { return }
                self.finish("no Amazfit Helio device found in \(Int(self.options.scanSeconds)) s", code: 5)
            }
        case .unauthorized:
            finish("Bluetooth permission denied: allow your terminal in System Settings › Privacy & Security › Bluetooth", code: 2)
        case .poweredOff, .unsupported:
            finish("Bluetooth is off or unsupported", code: 2)
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard step == .scanning else { return }
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        guard let model = ZeppDeviceModel.match(advertisedName: name) else { return }
        if let wanted = options.name, wanted != name { return }
        log("found \(model.rawValue) (\"\(name)\", RSSI \(RSSI)); connecting")
        self.model = model
        central.stopScan()
        step = .connecting
        self.peripheral = peripheral
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        step = .discovering
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        finish("connect failed: \(error?.localizedDescription ?? "unknown")", code: 3)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard step != .done else { return }
        if find.isBuzzing {
            find.connectionLost()
            log("WARNING: the link dropped while the strap was buzzing; it may keep vibrating until its own timeout. Run --find 1 to send a stop.")
        }
        if workout.running {
            log("WARNING: the link dropped while a strap workout was running; run with --workout-end-only to end it.")
            workout.phase = .ended  // no link: finish() cannot send the end
        }
        finish("disconnected in step '\(step.rawValue)': \(error?.localizedDescription ?? "no error")", code: 3)
    }

    // MARK: Discovery

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let found = peripheral.services ?? []
        pendingServices = found.count
        for service in found { peripheral.discoverCharacteristics(nil, for: service) }
        if found.isEmpty { finish("no GATT services", code: 3) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for characteristic in service.characteristics ?? [] {
            // Discover by UUID across ALL services (§2).
            for known in ZeppCharacteristic.allCases where CBUUID(string: known.uuidString) == characteristic.uuid {
                characteristics[known] = characteristic
            }
        }
        pendingServices -= 1
        guard pendingServices == 0 else { return }
        let names = ZeppCharacteristic.allCases.filter { characteristics[$0] != nil }.map(\.rawValue)
        log("characteristics found: \(names.joined(separator: ", "))")
        readBasics()
    }

    // MARK: Unauthenticated basics

    func readBasics() {
        step = .readingBasics
        for wanted in [ZeppCharacteristic.batteryLevel, .firmwareRevision, .hardwareRevision] {
            if let c = characteristics[wanted] {
                pendingReads.insert(wanted)
                peripheral?.readValue(for: c)
            }
        }
        if characteristics[.batteryLevel] == nil { log("battery: 0x2A19 not exposed (use the battery endpoint after auth)") }
        if pendingReads.isEmpty { afterBasics() }
    }

    func afterBasics() {
        if key != nil {
            enableChunked()
        } else {
            listenToStandardHR(then: { [weak self] in self?.finish("done (no key: history fetch skipped)") })
        }
    }

    func listenToStandardHR(then next: @escaping () -> Void) {
        guard options.hrSeconds > 0, let c = characteristics[.heartRateMeasurement] else {
            if characteristics[.heartRateMeasurement] == nil { log("live HR: 0x2A37 not exposed") }
            next()
            return
        }
        step = step == .readingBasics ? .liveHR : .authedHR
        log("listening to live HR for \(options.hrSeconds) s…")
        peripheral?.setNotifyValue(true, for: c)
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(options.hrSeconds)) { [weak self] in
            self?.peripheral?.setNotifyValue(false, for: c)
            next()
        }
    }

    // MARK: Authenticated session

    func enableChunked() {
        guard let key, let read = characteristics[.chunkedRead], characteristics[.chunkedWrite] != nil else {
            finish("chunked characteristics …0016/…0017 not found", code: 3)
            return
        }
        step = .enablingChunked
        var newLink = ZeppLink(authKey: key)
        if let peripheral { newLink.setMaxWriteLength(peripheral.maximumWriteValueLength(for: .withoutResponse)) }
        link = newLink
        pendingNotify = [.chunkedRead]
        peripheral?.setNotifyValue(true, for: read)
        if let write = characteristics[.chunkedWrite], write.properties.contains(.notify) {
            pendingNotify.insert(.chunkedWrite)
            peripheral?.setNotifyValue(true, for: write)
        }
    }

    func startAuth() {
        step = .authenticating
        log("authenticating…")
        guard var link else { return }
        let out = link.startAuthentication()
        self.link = link
        handle(out)
    }

    func send(_ endpoint: UInt16, _ payload: [UInt8]) {
        guard var link else { return }
        do {
            let writes = try link.send(endpoint: endpoint, payload: payload)
            self.link = link
            enqueue(writes)
        } catch {
            finish("cannot send to endpoint 0x\(String(format: "%04x", endpoint)): \(error)", code: 3)
        }
    }

    func handle(_ out: ZeppLink.Output) {
        enqueue(out.writes)
        for event in out.events {
            switch event {
            case .authenticated:
                log("authenticated")
                step = .servicesList
                send(ZeppEndpoint.servicesList, ZeppServicesList.request)
            case .authenticationFailed(.wrongAuthKey):
                finish("the strap rejected the key (10 05 25): re-extract it (unpairing in Zepp or a reset invalidates it)", code: 4)
            case .authenticationFailed(let failure):
                finish("authentication failed: \(failure) (another central, e.g. the Zepp app, may hold the strap)", code: 4)
            case .message(let message):
                handleMessage(message)
            case .droppedChunk(let reason):
                log("dropped chunk: \(reason)")
            case .undecryptable(let endpoint):
                log("could not decrypt a message on endpoint 0x\(String(format: "%04x", endpoint))")
            case .deviceChunkAck:
                break
            }
        }
    }

    func handleMessage(_ message: ZeppMessage) {
        if message.wasEncrypted, message.trailerCRCMatches != nil {
            log("  (encrypted reply on 0x\(String(format: "%04x", message.endpoint)): device trailer CRC \(message.trailerCRCMatches == true ? "matches" : "does NOT match") our layout)")
        }
        switch (step, message.endpoint) {
        case (.servicesList, ZeppEndpoint.servicesList):
            guard let list = ZeppServicesList.parse(message.payload) else {
                finish("malformed services list", code: 3)
                return
            }
            services = list
            link?.apply(servicesList: list)
            printServices(list)
            requestDeviceInfo()
        case (.deviceInfo, ZeppEndpoint.deviceInfo):
            printDeviceInfo(message.payload)
            requestBattery()
        case (.battery, ZeppEndpoint.battery):
            if let battery = ZeppBatteryStatus.parse(message.payload) {
                let charging = battery.isCharging.map { $0 ? "charging" : "not charging" } ?? "charging state unknown"
                log("battery (endpoint): \(battery.level) %, \(charging)")
            } else {
                log("battery (endpoint): unparseable reply")
            }
            afterBattery()
        case (.setTime, ZeppEndpoint.time):
            log(ZeppTimeCommand.isSuccessReply(message.payload) ? "time set" : "time set: unexpected reply")
            alarmEditor?.noteTimeSetReply(message.payload)
            readConfig()
        case (.config, ZeppEndpoint.config):
            if let reply = ZeppConfig.parseReadReply(message.payload) {
                let settings = ZeppHealthSettings(reply)
                log("HEALTH settings (group version \(reply.groupVersion))\(reply.isPartial ? ", partial" : "")")
                for warning in settings.warnings { log("  WARNING: \(warning)") }
                if settings.warnings.isEmpty { log("  no recording switch reported off") }
                for line in settings.informational { log("  \(line)") }
            } else {
                log("HEALTH settings: unreadable reply")
            }
            afterConfig()
        case (_, ZeppEndpoint.heartRate):
            if let event = ZeppHeartRateControl.parse(message.payload) { log("HR endpoint: \(event)") }
        case (_, ZeppEndpoint.findDevice):
            performFind(find.receive(message.payload, now: Date()))
        case (_, ZeppEndpoint.alarms):
            receiveAlarmMessage(message.payload)
        case (_, workoutEndpoint):
            receiveWorkout(message.payload)
        case (.controls, ZeppEndpoint.config):
            receiveAlertsMessage(message.payload)
        case (.fetching, ZeppEndpoint.activityFetch):
            if options.trace { log("  " + ZeppFetchTrace.control(message.payload, outgoing: false, channel: "0x004b")) }
            feedFetchControl(message.payload)
        default:
            log("message on endpoint 0x\(String(format: "%04x", message.endpoint)) (\(message.payload.count) B) ignored in step '\(step.rawValue)'")
        }
    }

    /// §5.3 device info, when the strap lists endpoint 0x0043. Only the versions are printed.
    func requestDeviceInfo() {
        guard services?.contains(ZeppEndpoint.deviceInfo) == true else {
            log("device info: 0x0043 not in the services list; skipped")
            return requestBattery()
        }
        step = .deviceInfo
        send(ZeppEndpoint.deviceInfo, ZeppDeviceInfo.request)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.step == .deviceInfo else { return }
            self.log("device info: no reply in 5 s; skipped")
            self.requestBattery()
        }
    }

    func printDeviceInfo(_ payload: [UInt8]) {
        guard let info = ZeppDeviceInfo.parse(payload) else {
            return log("device info: unparseable reply (\(payload.count) B)")
        }
        let widths = info.blobPrefixWidths.map { "\($0) B" }.joined(separator: ", ")
        let blob = info.flags & 0x01 == 0 ? "no bit-0 blob" : "bit-0 blob prefix width(s) that parse: \(widths)"
        let detail = "flags 0x\(String(info.flags, radix: 16)), \(blob)"
        if info.isAmbiguous {
            return log("device info: versions ambiguous, the parsing widths disagree (\(detail))")
        }
        // A mis-located field could shift the serial number into a version (the SPEC-GAP in
        // ZeppDeviceInfo.parse). If DIS gave a hardware revision and this one differs, print neither.
        if let dis = disHardwareRevision, let hardware = info.hardwareVersion, dis != hardware {
            return log("device info: hardware version differs from DIS 0x2A27, so the fields may be misaligned; versions withheld (\(detail))")
        }
        log("device info: hardware \(info.hardwareVersion ?? "not reported"), firmware \(info.firmwareVersion ?? "not reported") (\(detail))")
    }

    func requestBattery() {
        guard services?.contains(ZeppEndpoint.battery) == true else {
            log("battery (endpoint): 0x0029 not in the services list; skipped")
            return afterBattery()
        }
        step = .battery
        send(ZeppEndpoint.battery, ZeppBatteryStatus.request)
    }

    func afterBattery() {
        guard options.setTime else { return readConfig() }
        step = .setTime
        let now = Date()
        if services?.contains(ZeppEndpoint.time) == true {
            send(ZeppEndpoint.time, ZeppTimeCommand.setTime(now, timeZone: .current))
        } else if let c = characteristics[.currentTime] {
            write(ZeppWrite(.currentTime, ZeppTimeCommand.currentTimeBytes(now, timeZone: .current)), to: c)
            log("time set via 0x2A2B")
            readConfig()
        } else {
            log("time set: no time endpoint and no 0x2A2B; skipped")
            readConfig()
        }
    }

    func readConfig() {
        guard services?.contains(ZeppEndpoint.config) == true else {
            log("HEALTH settings: config endpoint 0x000A not in the services list; skipped")
            return afterConfig()
        }
        step = .config
        send(ZeppEndpoint.config, ZeppConfig.readRequest(group: ZeppConfig.healthGroup,
                                                          arguments: ZeppConfig.healthReadArguments))
    }

    /// Controls replace live HR and the history fetch when any control flag is given.
    func afterConfig() {
        if options.runsWorkout { return startWorkoutTest() }
        options.hasControls ? startControls() : startAuthedHR()
    }

    func startAuthedHR() {
        step = .authedHR
        guard options.hrSeconds > 0, characteristics[.heartRateMeasurement] != nil else { return enableFetch() }
        guard services?.contains(ZeppEndpoint.heartRate) == true else {
            log("HR endpoint 0x001D not in the services list; listening to 0x2A37 without starting it")
            return listenToStandardHR { [weak self] in self?.enableFetch() }
        }
        send(ZeppEndpoint.heartRate, ZeppHeartRateControl.start)
        hrTimer = mainTimer(every: 1, after: 1) { [weak self] in
            self?.send(ZeppEndpoint.heartRate, ZeppHeartRateControl.keepRunning)
        }
        listenToStandardHR { [weak self] in
            guard let self else { return }
            self.hrTimer?.cancel()
            self.send(ZeppEndpoint.heartRate, ZeppHeartRateControl.stop)
            self.enableFetch()
        }
    }

    // MARK: History fetch (Path A: …0004 / …0005)

    func enableFetch() {
        guard let control = characteristics[.activityControl], let data = characteristics[.activityData] else {
            finish("activity characteristics …0004/…0005 not found (Path B is not wired in HelioVerify)", code: 3)
            return
        }
        step = .enablingFetch
        pendingNotify = [.activityControl, .activityData]
        peripheral?.setNotifyValue(true, for: control)
        peripheral?.setNotifyValue(true, for: data)
    }

    func startFetch() {
        step = .fetching
        let now = Date()
        let since = Date(timeIntervalSince1970: floor((now.timeIntervalSince1970 - options.sinceHours * 3600) / 60) * 60)
        let policy: ZeppAckPolicy = options.allowDelete ? .deleteAfterDurableCommit : .keepOnDevice
        log("fetching \(options.types.map(\.displayName).joined(separator: ", ")) since \(ZeppRoundSummary.iso(since)); ack policy: \(policy == .keepOnDevice ? "KEEP on strap (03 09)" : "delete CRC-verified rounds after a durable write (03 01)")")
        var machine = ZeppHistoryFetch(plan: options.types.map { ($0, since) }, now: now,
                                       configuration: .init(ackPolicy: policy))
        let actions = machine.start()
        fetch = machine
        perform(actions)
    }

    func feedFetchControl(_ bytes: [UInt8]) {
        guard var machine = fetch else { return }
        let actions = machine.receiveControl(bytes)
        fetch = machine
        perform(actions)
    }

    func perform(_ actions: [ZeppHistoryFetch.Action]) {
        for action in actions {
            switch action {
            case .sendControl(let bytes):
                if options.trace { log("  " + ZeppFetchTrace.control(bytes, outgoing: true)) }
                if let c = characteristics[.activityControl] { write(ZeppWrite(.activityControl, bytes), to: c) }
            case .roundReady(let round):
                roundsDelivered += 1
                log("  " + ZeppRoundSummary.describe(round))
                let durable = persist(round)
                guard var machine = fetch else { continue }
                let next = machine.commit(roundID: round.id, durable: durable)
                fetch = machine
                perform(next)
            case .roundFailed(let type, let failure):
                log("  \(type.displayName): round failed (\(failure)); acked 03 09 where a round was open")
            case .noData(let type):
                log("  \(type.displayName): nothing since the cursor")
            case .finished:
                disableFetchNotifications()
                step = .done
                finish("done: \(roundsDelivered) round(s) fetched")
            }
        }
    }

    /// Appends the round to --out and flushes it to the drive (F_FULLFSYNC). Returns true only when
    /// both succeeded.
    func persist(_ round: ZeppFetchRound) -> Bool {
        guard let handle = outHandle else { return false }
        let line: [String: Any] = [
            "type": String(format: "%02x", round.type.rawValue),
            "since": round.since.timeIntervalSince1970,
            "start": round.start.timeIntervalSince1970,
            "crcVerified": round.crcVerified,
            "dataHex": ZeppHex.string(round.rawData),
        ]
        do {
            var data = try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])
            data.append(0x0A)
            try handle.write(contentsOf: data)
            try OutFile.synchronize(handle)
            return true
        } catch {
            log("  could not persist the round (\(error)); it stays on the strap")
            return false
        }
    }

    func disableFetchNotifications() {
        for wanted in [ZeppCharacteristic.activityControl, .activityData] {
            if let c = characteristics[wanted] { peripheral?.setNotifyValue(false, for: c) }
        }
    }

    // MARK: Writes (queued for write-without-response flow control)

    func enqueue(_ writes: [ZeppWrite]) {
        for w in writes {
            guard let c = characteristics[w.characteristic] else { continue }
            write(w, to: c)
        }
    }

    func write(_ w: ZeppWrite, to c: CBCharacteristic) {
        writeQueue.append(w)
        flushWrites()
    }

    // SPEC-GAP: which write types `…0016` and `…0004` accept is a §10 capture item; write without
    // response when the characteristic offers it, else with response.
    func flushWrites() {
        guard let peripheral else { return }
        while let next = writeQueue.first, let c = characteristics[next.characteristic] {
            let withoutResponse = c.properties.contains(.writeWithoutResponse)
            if withoutResponse && !peripheral.canSendWriteWithoutResponse { return }
            writeQueue.removeFirst()
            peripheral.writeValue(Data(next.bytes), for: c, type: withoutResponse ? .withoutResponse : .withResponse)
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        flushWrites()
    }

    // MARK: Notifications and reads

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard let which = known(characteristic), pendingNotify.contains(which) else { return }
        if let error {
            finish("enabling notifications on \(which.rawValue) failed: \(error.localizedDescription)", code: 3)
            return
        }
        pendingNotify.remove(which)
        guard pendingNotify.isEmpty else { return }
        switch step {
        case .enablingChunked: startAuth()
        case .enablingFetch: startFetch()
        default: break
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let which = known(characteristic) else { return }
        defer {
            if step == .readingBasics, pendingReads.remove(which) != nil, pendingReads.isEmpty { afterBasics() }
        }
        guard error == nil, let value = characteristic.value else { return }
        let bytes = [UInt8](value)
        switch which {
        case .batteryLevel:
            if let level = ZeppBatteryLevelCharacteristic.parse(bytes) { log("battery (0x2A19): \(level) %") }
        case .firmwareRevision:
            log("firmware: \(String(decoding: bytes, as: UTF8.self))")
        case .hardwareRevision:
            let revision = String(decoding: bytes, as: UTF8.self)
            disHardwareRevision = revision.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
            log("hardware: \(revision)")
        case .heartRateMeasurement:
            if let hr = ZeppHeartRateMeasurement.parse(bytes), options.runsWorkout {
                noteStandardHR(hr.beatsPerMinute)
            } else if let hr = ZeppHeartRateMeasurement.parse(bytes) {
                let rr = hr.rrIntervals.isEmpty ? "" : ", \(hr.rrIntervals.count) RR interval(s)"
                log("  live HR: \(hr.beatsPerMinute) bpm\(rr)")
            }
        case .chunkedRead, .chunkedWrite:
            guard var link else { return }
            let out = link.receive(bytes)
            self.link = link
            handle(out)
        case .activityControl:
            if options.trace { log("  " + ZeppFetchTrace.control(bytes, outgoing: false)) }
            feedFetchControl(bytes)
        case .activityData:
            if options.trace { log("  " + ZeppFetchTrace.dataPacket(bytes)) }
            guard var machine = fetch else { return }
            let actions = machine.receiveData(bytes)
            fetch = machine
            perform(actions)
        case .currentTime:
            break
        }
    }

    func known(_ characteristic: CBCharacteristic) -> ZeppCharacteristic? {
        characteristics.first { $0.value === characteristic }?.key
    }
}

// MARK: - Main

// Before anything is printed: a dead stdout pipe must not kill the run before the find stop.
StopSignals.ignoreBrokenPipe()
let options = parseCommandLine()
let key = options.keyFile.map(loadKey)
if options.allowDelete {
    print("WARNING: --allow-delete: CRC-verified rounds durably written to --out will be DROPPED from the strap (ack 03 01).")
}
if options.writesAlarms {
    print("NOTE: this run WRITES the strap's alarms (--allow-write), and sets its clock first.")
} else if options.setTime {
    print("NOTE: this run WRITES the strap's clock (--set-time --allow-write).")
}
if #available(macOS 10.15.4, *) {
    let verifier = HelioVerifier(options: options, key: key)
    // Ctrl-C, SIGTERM and SIGHUP must not leave the strap buzzing: finish() sends the stop first.
    let stopSources = StopSignals.install { number in
        verifier.finish(StopSignals.reason(number), code: StopSignals.exitCode(number))
    }
    withExtendedLifetime((verifier, stopSources)) { dispatchMain() }
} else {
    fail("HelioVerify needs macOS 10.15.4 or newer")
}

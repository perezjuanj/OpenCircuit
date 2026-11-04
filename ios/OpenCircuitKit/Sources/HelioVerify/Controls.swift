// HelioVerify device controls (#215 phase 1b): find my strap, the short buzz, the alarm list and one
// alarm write, and a read-only look at the haptic alert settings.
//
// Thin glue: ZeppKit decides what the strap supports (`ZeppControlCapabilities`), what may be sent
// (`ZeppFindDevice`, `ZeppAlarmEditor`, `ZeppHapticAlertSettings`) and when a find stops. This file
// only runs the requested steps in order and prints what happened, raw bytes included, so a first
// keyed run can promote the spec's §10 items 13-20.

import CoreBluetooth
import Foundation
import ZeppKit

/// One requested control step, run in this order.
enum ControlTask: Equatable {
    case findCapabilities
    case alerts
    case settings
    case alarms
    case find(seconds: Double)
    case buzz
}

/// What the running step is waiting for.
enum ControlWait: Equatable {
    case findCapabilities
    case configCapabilities
    case configRead(group: UInt8)
    case settings
    case alarms
    case find
    case buzz
}

@available(macOS 10.15.4, *)
extension HelioVerifier {

    /// §10 item 20: HEALTH's alert args and SOUND & VIBRATION's two args, read with constraints.
    static let healthAlertArguments: [UInt8] = [0x02, 0x03, 0x14, 0x32, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x51]
    static let soundAndVibrationGroup: UInt8 = 0x03
    static let soundAndVibrationArguments: [UInt8] = [0x09, 0x12]

    // MARK: Services list

    /// Prints every endpoint with its encryption flag, then which controls the strap supports.
    func printServices(_ list: ZeppServicesList) {
        log("services list (\(list.entries.count) endpoints):")
        for entry in list.entries {
            let name = ZeppEndpoint.displayName(entry.endpoint) ?? "(not in the spec's table)"
            let flag: String
            switch entry.encrypted {
            case true?: flag = "encrypted"
            case false?: flag = "plaintext"
            case nil:
                let effective = link?.transport.isEncrypted(endpoint: entry.endpoint) == true
                flag = "flag not 00/01, default applies: \(effective ? "encrypted" : "plaintext")"
            }
            log("  0x\(hex16(entry.endpoint))  \(name.padding(toLength: 20, withPad: " ", startingAt: 0))  \(flag)")
        }
        controlCapabilities = ZeppControlCapabilities(model: model, isAuthenticated: link?.isAuthenticated == true,
                                                      services: list)
        alarmEditor = ZeppAlarmEditor(capabilities: controlCapabilities)
        log("controls:")
        for control in ZeppControl.allCases {
            var line = describe(controlCapabilities.support(control))
            if control == .vibrationPatterns {
                line += list.contains(ZeppEndpoint.vibrationPatterns) ? " (0x0018 listed)" : " (0x0018 not listed)"
            }
            log("  \(label(control).padding(toLength: 19, withPad: " ", startingAt: 0)) \(line)")
        }
    }

    // MARK: Sequencing

    func startControls() {
        step = .controls
        var tasks = [ControlTask]()
        if options.findSeconds != nil || options.vibrate { tasks.append(.findCapabilities) }
        if options.alerts { tasks.append(.alerts) }
        if options.settings || options.writesConfig { tasks.append(.settings) }
        if options.listAlarms || options.writesAlarms { tasks.append(.alarms) }
        if let seconds = options.findSeconds { tasks.append(.find(seconds: seconds)) }
        if options.vibrate { tasks.append(.buzz) }
        controlTasks = tasks
        controlTimer = mainTimer(every: 0.1, after: 0.1) { [weak self] in
            self?.tickControls()
        }
        nextControl()
    }

    func nextControl() {
        guard !isFinishing else { return }
        controlWait = nil
        controlWaitToken += 1
        guard !controlTasks.isEmpty else {
            controlTimer?.cancel()
            step = .done
            return finish("done: controls finished")
        }
        switch controlTasks.removeFirst() {
        case .findCapabilities: startFindCapabilities()
        case .alerts: startAlerts()
        case .settings: startSettings()
        case .alarms: startAlarms()
        case .find(let seconds): startFind(seconds: seconds)
        case .buzz: startBuzz()
        }
    }

    /// Marks what the step waits for; `onTimeout` runs only if that same wait is still open.
    @discardableResult
    func beginWait(_ wait: ControlWait, timeout: Double? = nil, onTimeout: (() -> Void)? = nil) -> Int {
        controlWaitToken += 1
        let token = controlWaitToken
        controlWait = wait
        if let timeout, let onTimeout {
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, self.controlWaitToken == token, !self.isFinishing else { return }
                onTimeout()
            }
        }
        return token
    }

    /// Moves on a second after the current wait ends, so late strap messages still get printed.
    func nextControlSoon() {
        let token = controlWaitToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.controlWaitToken == token else { return }
            self.nextControl()
        }
    }

    func tickControls() {
        let now = Date()
        performFind(find.tick(now: now))
        if var editor = alarmEditor {
            let out = editor.tick(now: now)
            alarmEditor = editor
            performAlarm(out)
        }
        tickSettings()
    }

    func sendControl(_ messages: [ZeppControlMessage]) {
        for message in messages {
            log("  0x\(hex16(message.endpoint)) → \(spaced(message.payload))")
            send(message.endpoint, message.payload)
        }
    }

    // MARK: Find device and buzz

    func startFindCapabilities() {
        // Always hand the machine this connection's capabilities: it sends nothing when unsupported,
        // and a later start then fails with the right reason.
        let out = find.connected(controlCapabilities)
        guard controlCapabilities.isSupported(.findDevice) else {
            log("find device: \(describe(controlCapabilities.support(.findDevice))); nothing sent")
            return nextControl()
        }
        log("find device: asking for its capabilities (01)")
        beginWait(.findCapabilities, timeout: 3) { [weak self] in
            self?.log("find device: no capabilities reply in 3 s; one-shot emulation")
            self?.nextControl()
        }
        performFind(out)
    }

    func startFind(seconds: Double) {
        do {
            let out = try find.start(now: Date())
            let mode = find.mode == .continuous ? "continuous" : "one-shot emulation"
            log("find device: START, \(mode); stopping in \(format(seconds)) s")
            let token = beginWait(.find)
            performFind(out)
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                guard let self, self.controlWaitToken == token, self.find.isBuzzing else { return }
                self.log("find device: STOP after \(format(seconds)) s")
                self.performFind(self.find.stop())
            }
        } catch {
            log("find device: not started: \(describeControlError(error))")
            nextControl()
        }
    }

    func startBuzz() {
        do {
            let out = try find.buzz(now: Date())
            log("buzz: START, then STOP after \(format(find.configuration.buzzLength)) s")
            beginWait(.buzz)
            performFind(out)
            if let deadline = find.nextDeadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + deadline.timeIntervalSinceNow) { [weak self] in
                    self?.tickControls()
                }
            }
        } catch {
            log("buzz: not sent: \(describeControlError(error))")
            nextControl()
        }
    }

    func performFind(_ out: ZeppFindDevice.Output) {
        sendControl(out.messages)
        for event in out.events {
            switch event {
            case .capabilities(let version?):
                let mode = version >= 2 ? "continuous: one 03 until 06" : "one-shot: 03 again 10 s after each 04"
                log("find device: version \(version) (\(mode))")
                if controlWait == .findCapabilities { nextControl() }
            case .capabilities(nil):
                log("find device: malformed capabilities reply; one-shot emulation")
                if controlWait == .findCapabilities { nextControl() }
            case .startAcknowledged:
                log("find device: the strap acknowledged the start (04)")
            case .stopped(let reason):
                log("find device: stopped (\(reason))")
                if controlWait == .find || controlWait == .buzz { nextControlSoon() }
            case .owedStopSent:
                log("find device: sent the stop owed since the link dropped")
            case .findPhoneRequested:
                log("find phone: the strap asked the phone to ring (11); answered 12 01")
            case .findPhoneMode(let mode):
                log("find phone: mode \(mode)")
            case .findPhoneEnded:
                log("find phone: ended")
            }
        }
    }

    /// Sends the stop for a running find or buzz before exiting. Returns true when one went out.
    func stopFindBeforeExit() -> Bool {
        guard find.isBuzzing, link?.isAuthenticated == true else { return false }
        log("find device: STOP before exiting")
        let out = find.stop()
        sendControl(out.messages)
        return !out.messages.isEmpty
    }

    // MARK: Alarms

    func startAlarms() {
        guard var editor = alarmEditor, controlCapabilities.isSupported(.alarms) else {
            log("alarms: \(describe(controlCapabilities.support(.alarms))); nothing sent")
            return nextControl()
        }
        do {
            let out = try editor.read(now: Date())
            alarmEditor = editor
            log("alarms: reading the list")
            beginWait(.alarms)
            performAlarm(out)
        } catch {
            log("alarms: not read: \(describeControlError(error))")
            nextControl()
        }
    }

    func receiveAlarmMessage(_ payload: [UInt8]) {
        log("  0x000f ← \(spaced(payload))")
        guard var editor = alarmEditor else { return }
        let out = editor.receive(payload, now: Date())
        alarmEditor = editor
        performAlarm(out)
    }

    func performAlarm(_ out: ZeppAlarmEditor.Output) {
        sendControl(out.messages)
        for event in out.events {
            switch event {
            case .listRead(let alarms):
                printAlarms(alarms, title: options.writesAlarms ? "alarms before" : "alarms on the strap")
                if controlWait == .alarms { writeAlarmIfAsked() }
            case .listUnreadable(let error):
                log("alarms: couldn't read the list (\(error)); nothing written")
                if controlWait == .alarms { nextControl() }
            case .changedOnStrap:
                log("alarms: the strap says its alarms changed (0f)")
            case .writeAcknowledged(let write):
                log("alarms: the strap acknowledged \(describe(write)); reading the list back")
            case .writeFailed(let write, let failure):
                log("alarms: \(describe(write)) FAILED (\(failure)); not retried")
                if controlWait == .alarms { nextControl() }
            case .writeChecked(let check):
                printAlarms(check.list, title: "alarms after")
                log("alarms: slot \(check.write.slot) \(check.slotMatches ? "reads back as written" : "does NOT read back as written"); "
                    + "other slots \(check.otherSlotsUnchanged ? "unchanged" : "CHANGED")")
                if controlWait == .alarms { nextControl() }
            case .writeUnverified(let write, let error):
                log("alarms: \(describe(write)) was acknowledged but the list could not be read back (\(error))")
                if controlWait == .alarms { nextControl() }
            }
        }
    }

    /// One write, only when asked, and only through the editor's §15.2 checks.
    func writeAlarmIfAsked() {
        guard options.writesAlarms, var editor = alarmEditor else { return nextControl() }
        do {
            let out: ZeppAlarmEditor.Output
            if let spec = options.setAlarm {
                let slot = editor.freeSlots.first.map { "slot \($0)" } ?? "no free slot"
                log("alarms: WRITING one new alarm (\(slot)): \(String(format: "%02d:%02d", spec.hour, spec.minute)) \(spec.days.summary), enabled")
                out = try editor.add(hour: spec.hour, minute: spec.minute, days: spec.days, now: Date())
            } else if let slot = options.deleteAlarmSlot {
                log("alarms: DELETING slot \(slot)")
                out = try editor.delete(slot: slot, now: Date())
            } else {
                return nextControl()
            }
            alarmEditor = editor
            performAlarm(out)
        } catch {
            log("alarms: nothing written: \(describeControlError(error))")
            nextControl()
        }
    }

    func printAlarms(_ alarms: [ZeppAlarm], title: String) {
        guard !alarms.isEmpty else { return log("\(title): none (the strap returned an empty list)") }
        log("\(title) (\(alarms.count)):")
        for alarm in alarms {
            let raw = "flags \(hex8(alarm.rawFlags ?? 0)), tail \(spaced(alarm.unknownTail))"
            log("  \(alarm.summary)   [\(raw)]")
        }
        let used = Set(alarms.map(\.slot))
        let free = (0..<ZeppAlarm.slotCount).filter { !used.contains($0) }.map(String.init)
        log("  free slots: \(free.isEmpty ? "none" : free.joined(separator: " "))")
    }

    // MARK: Haptic alerts (read-only)

    func startAlerts() {
        guard controlCapabilities.isSupported(.hapticAlerts) else {
            log("haptic alerts: \(describe(controlCapabilities.support(.hapticAlerts))); nothing sent")
            return nextControl()
        }
        log("haptic alerts: reading the config capabilities (read-only)")
        beginWait(.configCapabilities, timeout: 5) { [weak self] in
            self?.log("haptic alerts: no config capabilities reply in 5 s")
            self?.nextControl()
        }
        sendControl([ZeppControlMessage(endpoint: ZeppEndpoint.config, payload: ZeppConfigCapabilities.request)])
    }

    func readConfigGroup(_ group: UInt8, arguments: [UInt8]) {
        beginWait(.configRead(group: group), timeout: 5) { [weak self] in
            self?.log("config group 0x\(hex8(group)): no reply in 5 s")
            self?.afterConfigGroup(group)
        }
        let payload = ZeppConfig.readRequest(group: group, arguments: arguments, includeConstraints: true)
        sendControl([ZeppControlMessage(endpoint: ZeppEndpoint.config, payload: payload)])
    }

    func receiveAlertsMessage(_ payload: [UInt8]) {
        // Settings print their own summaries (Settings.swift).
        if controlWait == .settings { return receiveSettingsMessage(payload) }
        log("  0x000a ← \(spaced(payload))")
        switch controlWait {
        case .configCapabilities?:
            guard let caps = ZeppConfigCapabilities.parse(payload) else {
                log("config: unparseable capabilities reply")
                return nextControl()
            }
            configCapabilities = caps
            log("config: service version \(caps.serviceVersion)\(caps.isVersionUnderstood ? "" : " (NOT understood, > 3)"), "
                + "groups \(caps.groups.map(hex8).joined(separator: " "))")
            guard caps.groups.contains(ZeppConfig.healthGroup) else {
                log("haptic alerts: HEALTH (0x08) not listed; none offered")
                return afterConfigGroup(ZeppConfig.healthGroup)
            }
            readConfigGroup(ZeppConfig.healthGroup, arguments: Self.healthAlertArguments)
        case .configRead(let group)?:
            guard let reply = ZeppConfig.parseReadReply(payload), reply.group == group else {
                log("config group 0x\(hex8(group)): unreadable reply (status not 01, wrong group, or truncated)")
                return afterConfigGroup(group)
            }
            log("config group 0x\(hex8(group)) version \(reply.groupVersion)\(reply.isPartial ? " (partial: an unknown type stopped parsing)" : ""):")
            for entry in reply.entries { log("  arg 0x\(hex8(entry.argument)) = \(entry.value)\(entry.constraint.map { ", allowed \($0)" } ?? "")") }
            if group == ZeppConfig.healthGroup {
                let settings = ZeppHapticAlertSettings(capabilities: controlCapabilities, configCapabilities: configCapabilities,
                                                       healthReply: reply)
                for alert in ZeppHapticAlert.allCases {
                    guard let setting = settings.setting(alert) else {
                        log("  \(label(alert)): not offered (not reported with the expected type and allowed values)")
                        continue
                    }
                    let allowed = setting.allowedValues.map { " (allowed: \($0.map { $0 == 0 ? "off" : String($0) }.joined(separator: " ")))" } ?? ""
                    log("  \(label(alert)): \(describe(setting.value, alert: alert))\(allowed)")
                }
            }
            afterConfigGroup(group)
        default:
            log("config: reply ignored (nothing asked)")
        }
    }

    func afterConfigGroup(_ group: UInt8) {
        if group == ZeppConfig.healthGroup, configCapabilities?.groups.contains(Self.soundAndVibrationGroup) == true {
            return readConfigGroup(Self.soundAndVibrationGroup, arguments: Self.soundAndVibrationArguments)
        }
        nextControl()
    }

    // MARK: Formatting

    func label(_ control: ZeppControl) -> String {
        switch control {
        case .findDevice: return "find device"
        case .buzz: return "buzz"
        case .findPhone: return "find phone"
        case .alarms: return "alarms"
        case .vibrationPatterns: return "vibration patterns"
        case .hapticAlerts: return "haptic alerts"
        }
    }

    func label(_ alert: ZeppHapticAlert) -> String {
        switch alert {
        case .highHeartRate: return "high heart-rate alert"
        case .lowHeartRate: return "low heart-rate alert"
        case .relaxReminder: return "relax reminder"
        case .lowSpO2: return "low SpO2 alert"
        }
    }

    func describe(_ value: ZeppConfigValue, alert: ZeppHapticAlert) -> String {
        switch value {
        case .bool(let on): return on ? "on" : "off"
        case .byte(0): return "off"
        case .byte(let n): return alert == .lowSpO2 ? "\(n) %" : "\(n) bpm"
        default: return "\(value)"
        }
    }

    func describe(_ support: ZeppControlSupport) -> String {
        switch support {
        case .supported: return "supported"
        case .unsupported(.notHelioStrap): return "unsupported (not an Amazfit Helio Strap)"
        case .unsupported(.notAuthenticated): return "unsupported (not authenticated)"
        case .unsupported(.noServicesList): return "unsupported (no services list)"
        case .unsupported(.endpointNotListed(let endpoint)): return "unsupported (0x\(hex16(endpoint)) not in the services list)"
        case .unsupported(.notInV1): return "not exposed in v1"
        }
    }

    func describe(_ write: ZeppAlarmEditor.Write) -> String {
        switch write {
        case .set(let alarm): return "the write of slot \(alarm.slot)"
        case .delete(let slot): return "the delete of slot \(slot)"
        }
    }

    func describeControlError(_ error: Error) -> String {
        switch error {
        case ZeppControlError.unsupported(_, let reason):
            return describe(.unsupported(reason))
        case ZeppFindDevice.Error.alreadyActive:
            return "a find or buzz is already running"
        case let error as ZeppAlarmEditor.Error:
            switch error {
            case .busy: return "another alarm read or write is in flight"
            case .listMalformedThisConnection(let problem):
                return "the strap returned a malformed alarm list (\(problem)); alarms are off for this connection"
            case .listNotRead: return "no well-formed alarm list was read on this connection"
            case .listChangedOnStrap: return "the strap's alarms changed since the read (0f); run again"
            case .timeNotSet: return "the strap's clock was not confirmed set on this connection (needs endpoint 0x0047 and a 06 01 reply)"
            case .noFreeSlot: return "the strap already has 10 alarms"
            case .slotEmpty(let slot): return "slot \(slot) holds no alarm"
            case .smartWakeNotOffered: return "smart wake is not offered in v1"
            case .invalidAlarm(let problem): return "invalid alarm (\(problem))"
            }
        default:
            return "\(error)"
        }
    }
}

func hex8(_ value: UInt8) -> String { String(format: "%02x", value) }
func hex16(_ value: UInt16) -> String { String(format: "%04x", value) }
func spaced(_ bytes: [UInt8]) -> String { bytes.isEmpty ? "(empty)" : bytes.map(hex8).joined(separator: " ") }
func format(_ seconds: Double) -> String {
    seconds == seconds.rounded() ? String(Int(seconds)) : String(format: "%.1f", seconds)
}

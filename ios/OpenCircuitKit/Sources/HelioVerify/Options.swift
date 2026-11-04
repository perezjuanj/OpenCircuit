// HelioVerify's command line: the options, the help text and the parser. Kept out of main.swift so
// the parser is testable (main.swift's top-level code starts Bluetooth).

import Foundation
import ZeppKit

struct Options {
    var keyFile: String?
    var allowDelete = false
    var outPath: String?
    var name: String?
    var scanSeconds: Double = 30
    var hrSeconds = 15
    var sinceHours: Double = 24
    var types: [ZeppFetchType] = [.activity, .hrv, .spo2, .temperature, .restingHeartRate,
                                  .sleepRespiratoryRate, .sleepSession]
    var setTime = false
    var timeoutSeconds: Double = 300
    var trace = false
    // Device controls (Controls.swift).
    var findSeconds: Double?
    var vibrate = false
    var listAlarms = false
    var setAlarm: (hour: UInt8, minute: UInt8, days: ZeppAlarmDays)?
    var deleteAlarmSlot: UInt8?
    var allowWrite = false
    var alerts = false
    // Strap settings (Settings.swift, ZEPP_PROTOCOL.md §17, §19).
    var settings = false
    var setConfig: (setting: ZeppSetting, value: ZeppConfigValue)?
    var configProbe: ConfigProbe?
    // Workout-mode test (Workout.swift, #358).
    var workoutSeconds: Double?
    var workoutEnd = WorkoutEnd.save
    var workoutBaseline: Double = 20
    var workoutStartBytes: [UInt8]?
    var workoutEndOnly = false
    var workoutStatus = false
    var writesWorkout: Bool { workoutSeconds != nil || workoutEndOnly }
    var runsWorkout: Bool { writesWorkout || workoutStatus }

    var writesAlarms: Bool { setAlarm != nil || deleteAlarmSlot != nil }
    var writesConfig: Bool { setConfig != nil || configProbe != nil }
    /// Any control flag: the run does the controls instead of live HR and the history fetch.
    var hasControls: Bool { findSeconds != nil || vibrate || listAlarms || writesAlarms || alerts || settings || writesConfig }
}

let usage = """
HelioVerify — check an Amazfit Helio Strap / Ring over Bluetooth LE (macOS).

USAGE
  swift run HelioVerify [options]

Without a key: scans, connects, reads the standard battery level (if the strap exposes 0x2A19)
and firmware/hardware revision, and listens to standard heart-rate notifications (0x2A37; needs
the strap's Heart Rate Broadcast setting on: HEALTH 0x83, set in the Zepp app).

With --key-file and no control flag: also authenticates, prints the services list, sends the
read-only device-info request (01 on endpoint 0x0043) and prints the hardware and firmware
versions from it (never the serial number), reads battery over the battery endpoint, reads the
HEALTH settings (warns about switches that stop recording), streams live HR, and runs a
NON-DESTRUCTIVE history fetch (ack 03 09: the strap keeps everything), printing summaries. No
strap setting is changed and no data is dropped unless a write flag below is given.

OPTIONS
  --key-file <path>   File holding the 16-byte auth key as 32 hex digits (optional 0x prefix).
                      The key is never printed or logged.
  --types <list>      Comma-separated fetch types in hex (default 01,49,25,2e,3a,38,48).
                      Known: 01 02 0d 12 13 25 26 2e 38 3a 3d 48 49.
  --since-hours <h>   Fetch history from this many hours ago (default 24).
  --hr-seconds <n>    How long to listen to live HR (default 15; 0 skips it).
  --name <name>       Only connect to a device advertising exactly this name.
  --scan-seconds <n>  Give up scanning after n seconds (default 30).
  --timeout <n>       Abort the whole run after n seconds (default 300).
  --set-time          WRITES STRAP STATE; needs --allow-write. Sets the strap's clock to this
                      Mac's time and zone after auth (off by default). The strap stamps its later
                      history with this clock.
  --trace             Print every history-fetch control message both ways as hex, and each data
                      packet's length and counter byte (never its payload).
  --out <path>        Append each fetched round (raw hex + metadata, JSON lines) to this file and
                      flush it to the drive (F_FULLFSYNC). Must be a regular file (not /dev/null).
                      The file holds REAL HEALTH DATA: keep it out of git.
  --allow-delete      DESTRUCTIVE. Ack 03 01 ("saved, drop it from the strap") for each round
                      whose CRC matched, but only after it is durably written to --out. A round
                      without a CRC is kept (03 09). Requires --key-file and --out.
  --help              Show this help.

WORKOUT MODE TEST (#358; needs --key-file and --allow-write)
  --workout-test <s>  STARTS THE STRAP'S OWN WORKOUT (pickleball by default) after a standard live HR
                      baseline, prints the strap's 1/s workout frames next to 0x2A37, then ends it.
                      The workout is always ended on exit, Ctrl-C, SIGTERM, SIGHUP or timeout.
  --workout-baseline <s>  Seconds of 0x2A37 before the start (default 20).
  --workout-end save|discard  End with 03 04 (saved, default) or 03 05 (not saved).
  --workout-start-hex <hex>   Raw start request instead of pickleball (must start 02).
  --workout-status    Read-only: ask the strap whether a workout is running.
  --workout-end-only  End a workout a crashed run left running (uses the saved start time).

DEVICE CONTROLS (Helio Strap only; all need --key-file)
  Any of these runs the controls INSTEAD of live HR and the history fetch. After auth the strap's
  services list is printed with each endpoint's encryption, then which controls it supports; the
  read-only device-info, battery and HEALTH settings reads above still run before the controls. A
  control the strap does not list is reported as unsupported and nothing is sent for it.
  --find [n]          Find my strap: start "find device", stop it after n seconds (default 10,
                      max 60). A stop is also sent on Ctrl-C, SIGTERM or SIGHUP (a closed
                      terminal), on timeout and before exiting.
  --vibrate           One short buzz: find-device start, then stop 500 ms later. There is no
                      dedicated vibrate opcode (ZEPP_PROTOCOL.md §13.2).
  --alerts            Read-only: the config capabilities and the strap's haptic alert settings
                      (high/low HR, low SpO2, relax reminder), with the values it allows.
  --alarms            Read-only: list the alarms on the strap.
  --set-alarm HH:MM[,days]
                      WRITES STRAP STATE; needs --allow-write. Adds one enabled alarm in the lowest
                      free slot (never overwrites or deletes another), printing the list before and
                      after. days: once (default), daily, weekdays, weekend, or mon..sun joined by
                      ',' or '+', e.g. 07:30,mon,wed,fri. Sets the strap's clock first (alarms fire
                      in strap-local time), even if no alarm ends up written.
  --delete-alarm <n>  WRITES STRAP STATE; needs --allow-write. Deletes the alarm in slot n (0-9),
                      e.g. the one --set-alarm made. Prints the list before and after. Sets the
                      strap's clock first, like --set-alarm, even if the slot is empty and nothing
                      is deleted.
  --settings          Read-only: the config capabilities, every listed group read with arg count
                      00 (each group's version and the arg and type codes present, never their
                      values), then the HEALTH and WORKOUT settings OpenCircuit offers, with the
                      strap's values and allowed values (ZEPP_PROTOCOL.md §10 item 25, first part).
  --set-config <setting>=<value>
                      WRITES STRAP STATE; needs --allow-write. Changes ONE setting through the
                      app's own write path (§17.8): read it and its parent with constraints,
                      validate against the strap's allowed values, write one entry echoing the
                      version read, wait 5 s for 06, re-read and print the strap's value. Nothing
                      is sent if the value is invalid or already set. Settings: \(settingNames).
                      Values: on/off for switches; off, smart, continuous or minutes for
                      heartRateMonitoring; high, standard or low for workoutDetectionSensitivity;
                      otherwise a number (bpm or %), 0 = off.
  --config-probe <a|b|c>
                      WRITES STRAP STATE; needs --allow-write. One of §10 item 25's rejection probes,
                      each sent raw (the app would refuse it), then re-read, and the strap's previous
                      value written back if the strap took the probe:
                        a  a high-HR alert value (HEALTH 02) outside the strap's allowed list;
                        b  relax reminder (14) on while stress monitoring (13) reads off. Skipped
                           unless stress reads off and relax reads off; turn stress off first with
                           --set-config stressMonitoring=off, and back on afterwards;
                        c  relax reminder written with its CURRENT value but version byte + 1.
  --allow-write       Confirms the writes that change strap settings: --set-time (the clock),
                      --set-alarm and --delete-alarm (which also set the clock), --set-config and
                      --config-probe. Each of those needs it, and it is refused on its own. Without
                      it no setting is changed.
                      Dropping fetched data from the strap has its own flag, --allow-delete.

EXIT CODES
  0 ok · 1 usage · 2 Bluetooth unavailable · 3 timeout · 4 auth failed · 5 no device found
  129 hung up (SIGHUP) · 130 interrupted (Ctrl-C) · 143 terminated (SIGTERM)
"""

/// Why the command line was not accepted; main.swift prints it and exits.
enum OptionsError: Error, Equatable {
    /// `--help`: print `usage` and exit 0.
    case help
    /// A usage error: print the message and exit 1.
    case invalid(String)
}

/// Parses HelioVerify's arguments (without the program name). Pure: no I/O, no exit, so the write
/// gating below is unit-tested (HelioVerifyTests).
func parseOptions(_ args: [String]) throws -> Options {
    func fail(_ message: String) -> OptionsError { .invalid(message) }
    var o = Options()
    var i = 0
    func value(_ flag: String) throws -> String {
        i += 1
        guard i < args.count else { throw fail("\(flag) needs a value") }
        return args[i]
    }
    func number(_ flag: String) throws -> Double {
        guard let n = Double(try value(flag)), n >= 0 else { throw fail("\(flag) needs a non-negative number") }
        return n
    }
    while i < args.count {
        switch args[i] {
        case "--help", "-h":
            throw OptionsError.help
        case "--key-file": o.keyFile = try value("--key-file")
        case "--allow-delete": o.allowDelete = true
        case "--out": o.outPath = try value("--out")
        case "--name": o.name = try value("--name")
        case "--scan-seconds": o.scanSeconds = try number("--scan-seconds")
        case "--hr-seconds": o.hrSeconds = Int(try number("--hr-seconds"))
        case "--since-hours": o.sinceHours = try number("--since-hours")
        case "--timeout": o.timeoutSeconds = try number("--timeout")
        case "--set-time": o.setTime = true
        case "--trace": o.trace = true
        case "--find":
            // Optional value: `--find` alone buzzes for 10 s.
            if i + 1 < args.count, let n = Double(args[i + 1]) {
                i += 1
                guard n > 0, n <= ZeppFindDevice.Configuration.maxFindDuration else { throw fail("--find takes a number of seconds above 0 and at most 60") }
                o.findSeconds = n
            } else {
                o.findSeconds = 10
            }
        case "--vibrate": o.vibrate = true
        case "--alarms": o.listAlarms = true
        case "--alerts": o.alerts = true
        case "--settings": o.settings = true
        case "--set-config":
            let spec = try value("--set-config")
            guard let parsed = parseSettingSpec(spec) else {
                throw fail("--set-config takes <setting>=<value>, e.g. stressMonitoring=on or highHeartRateAlert=120 (see --help)")
            }
            o.setConfig = parsed
        case "--config-probe":
            guard let probe = ConfigProbe(rawValue: try value("--config-probe")) else {
                throw fail("--config-probe takes a, b or c (see --help)")
            }
            o.configProbe = probe
        case "--allow-write": o.allowWrite = true
        case "--workout-test": o.workoutSeconds = try number("--workout-test")
        case "--workout-baseline": o.workoutBaseline = try number("--workout-baseline")
        case "--workout-end-only": o.workoutEndOnly = true
        case "--workout-status": o.workoutStatus = true
        case "--workout-end":
            guard let end = WorkoutEnd(rawValue: try value("--workout-end")) else { throw fail("--workout-end takes save or discard") }
            o.workoutEnd = end
        case "--workout-start-hex":
            let text = try value("--workout-start-hex")
            guard text.count % 2 == 0, text.count >= 2, let bytes = Optional(stride(from: 0, to: text.count, by: 2).compactMap({ i -> UInt8? in
                let s = text.index(text.startIndex, offsetBy: i); return UInt8(text[s..<text.index(s, offsetBy: 2)], radix: 16) })),
                  bytes.count == text.count / 2, bytes.first == 0x02 else { throw fail("--workout-start-hex takes hex bytes starting 02, e.g. 02e30001010200000002") }
            o.workoutStartBytes = bytes
        case "--set-alarm":
            guard let alarm = parseAlarmSpec(try value("--set-alarm")) else {
                throw fail("--set-alarm takes HH:MM[,days], e.g. 06:30 or 07:30,weekdays or 08:00,mon+wed")
            }
            o.setAlarm = alarm
        case "--delete-alarm":
            guard let slot = UInt8(try value("--delete-alarm")), slot < ZeppAlarm.slotCount else {
                throw fail("--delete-alarm takes a slot number 0-9")
            }
            o.deleteAlarmSlot = slot
        case "--types":
            let list = try value("--types").split(separator: ",")
            o.types = try list.map { code in
                let trimmed = code.trimmingCharacters(in: .whitespaces).lowercased()
                let digits = trimmed.hasPrefix("0x") ? String(trimmed.dropFirst(2)) : trimmed
                guard let raw = UInt8(digits, radix: 16), let type = ZeppFetchType(rawValue: raw) else {
                    throw fail("unknown fetch type '\(code)'")
                }
                return type
            }
        default:
            throw fail("unknown option '\(args[i])' (see --help)")
        }
        i += 1
    }
    if o.allowDelete && (o.keyFile == nil || o.outPath == nil) {
        throw fail("--allow-delete requires --key-file and --out: data is only dropped from the strap after it is durably saved")
    }
    if o.hasControls && o.keyFile == nil {
        throw fail("--find, --vibrate, --alerts, --settings and the alarm and config flags need --key-file: the strap only takes them after auth")
    }
    if o.setTime && o.keyFile == nil {
        throw fail("--set-time needs --key-file: the clock is set after auth")
    }
    if o.writesAlarms && !o.allowWrite {
        throw fail("--set-alarm and --delete-alarm write the strap's alarms: add --allow-write to confirm")
    }
    if o.setTime && !o.allowWrite {
        throw fail("--set-time writes the strap's clock: add --allow-write to confirm")
    }
    if o.writesConfig && !o.allowWrite {
        throw fail("--set-config and --config-probe write the strap's settings: add --allow-write to confirm")
    }
    if o.writesWorkout && (o.keyFile == nil || !o.allowWrite) {
        throw fail("--workout-test and --workout-end-only start or end a workout on the strap: they need --key-file and --allow-write")
    }
    if o.workoutStatus && o.keyFile == nil { throw fail("--workout-status needs --key-file") }
    if o.runsWorkout && (o.hasControls || o.setTime) {
        throw fail("--workout-test runs alone: drop the control and settings flags")
    }
    if o.allowWrite && !o.writesAlarms && !o.setTime && !o.writesConfig && !o.writesWorkout {
        throw fail("--allow-write only applies to --set-time / --set-alarm / --delete-alarm / --set-config / --config-probe / --workout-test")
    }
    if o.setAlarm != nil && o.deleteAlarmSlot != nil {
        throw fail("one alarm write per run: use --set-alarm or --delete-alarm, not both")
    }
    if [o.writesAlarms, o.setConfig != nil, o.configProbe != nil].filter({ $0 }).count > 1 {
        throw fail("one write per run: --set-alarm/--delete-alarm, --set-config and --config-probe exclude each other")
    }
    // Alarm edits need the strap's clock set on this connection (ZEPP_PROTOCOL.md §14).
    if o.writesAlarms { o.setTime = true }
    return o
}

/// `HH:MM` or `HH:MM,days` (days per `ZeppAlarmDays(list:)`; omitted = once).
func parseAlarmSpec(_ text: String) -> (hour: UInt8, minute: UInt8, days: ZeppAlarmDays)? {
    let parts = text.split(separator: ",", maxSplits: 1).map(String.init)
    guard let time = parts.first else { return nil }
    let hm = time.split(separator: ":", omittingEmptySubsequences: false)
    guard hm.count == 2, (1...2).contains(hm[0].count), hm[1].count == 2,
          hm.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
          let hour = UInt8(hm[0]), let minute = UInt8(hm[1]), hour < 24, minute < 60 else { return nil }
    var days = ZeppAlarmDays.once
    if parts.count == 2 {
        guard let parsed = ZeppAlarmDays(list: parts[1]) else { return nil }
        days = parsed
    }
    return (hour, minute, days)
}

/// §10 item 25's three rejection probes (Settings.swift).
enum ConfigProbe: String, Equatable {
    /// a: a high-HR alert value outside the strap's allowed list.
    case outsideAllowedList = "a"
    /// b: relax reminder on while stress monitoring reads off.
    case childWhileParentOff = "b"
    /// c: the relax reminder's current value, with the version byte one more than the version read.
    case versionPlusOne = "c"
}

/// The `--set-config` setting names.
let settingNames = ZeppSetting.allCases.map(\.rawValue).joined(separator: ", ")

/// `<setting>=<value>` for `--set-config`; nil for an unknown setting or a value it can't take.
/// Only the shape is checked here: whether the strap allows the value is checked against its own
/// allowed list after the read (§17.6).
func parseSettingSpec(_ text: String) -> (setting: ZeppSetting, value: ZeppConfigValue)? {
    let parts = text.split(separator: "=", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
    guard parts.count == 2, let setting = ZeppSetting(rawValue: parts[0]) else { return nil }
    let word = parts[1].lowercased()
    if setting.isSwitch {
        switch word {
        case "on", "1", "true": return (setting, .bool(true))
        case "off", "0", "false": return (setting, .bool(false))
        default: return nil
        }
    }
    switch (setting, word) {
    case (_, "off"): return (setting, .byte(0x00))
    // §17.9: ff smart, fe continuous (never Gadgetbridge's 00).
    case (.heartRateMonitoring, "smart"): return (setting, .byte(0xff))
    case (.heartRateMonitoring, "continuous"): return (setting, .byte(0xfe))
    case (.workoutDetectionSensitivity, "high"): return (setting, .byte(0x00))
    case (.workoutDetectionSensitivity, "standard"): return (setting, .byte(0x01))
    case (.workoutDetectionSensitivity, "low"): return (setting, .byte(0x02))
    default: break
    }
    if word.hasPrefix("0x"), let byte = UInt8(word.dropFirst(2), radix: 16) { return (setting, .byte(byte)) }
    if let byte = UInt8(word) { return (setting, .byte(byte)) }
    return nil
}

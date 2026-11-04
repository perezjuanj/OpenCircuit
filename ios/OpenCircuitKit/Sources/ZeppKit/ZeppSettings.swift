// The strap's own settings, read and changed one at a time (ZEPP_PROTOCOL.md §17; #228 measurement,
// #229 workout detection, #230 alerts).
//
// Config writes are PERSISTENT and some change what the strap RECORDS (§15.1, §5.5).
// `ZeppSettingsEditor` therefore follows §17.8 for every user edit, and nothing else ever writes:
//   1. preconditions: authenticated, 0x000A listed, the group in this connection's config
//      capabilities, no other config traffic in flight, the group read in this connection;
//   2. read the arg and every parent (§17.7) with constraints;
//   3. validate: the arg is present with the type this spec gives it, the group version is one the
//      spec describes (§17.3), the value passes §17.6, the parents allow it (§17.7);
//   4. write ONE entry: version as read, type as read, the value;
//   5. wait up to 5 s for `06` (§17.4);
//   6. re-read (§17.5) and show the strap's value as the truth.
// A non-`01` status, no `06`, and `06 01` with the old value on re-read all mean "the strap did not
// take the change" (§17.4): the re-read value is shown and nothing is retried. A late `06` is ignored.
// It never writes at session setup, never writes a value the user didn't change, never writes a
// parent as a side effect of a child, and never writes WORKOUT `40` (§19.3).

import Foundation

/// The settings OpenCircuit may change. Each is offered only when the strap reported it, with the
/// type below, in a constraints-included read on this connection (§14, §17.1).
///
/// Left out on purpose:
/// - HEALTH `05` (share heart rate with third parties, 🔴 §5.5): what it controls is unsettled. It is
///   not Heart Rate Broadcast, which is `83` (🟢 §18.9) and is offered below.
/// - HEALTH `41`–`46`, `51` (inactivity and goal alerts): whether they buzz on the Helio is 🔴
///   (§13.4, §20). Goals `52`–`57` are never written (§15.1).
/// - WORKOUT `40` (detection categories): never written on the Helio, even if reported (§19.3).
/// - A workout-detection on/off switch: no arg is known (🔴 §19.2, §10 item 27).
public enum ZeppSetting: String, CaseIterable, Equatable, Hashable {
    // HEALTH (`08`), §5.5, §13.4, §17.9
    /// Byte (`10`): `00` off, `ff` smart, `fe` continuous, `01`–`78` every N minutes (§17.9).
    case heartRateMonitoring
    /// Bool: the vendor's "Active heart rate monitoring" (Gadgetbridge: "activity monitoring"). It
    /// raises the sampling rate during detected activity and does NOT gate recording (🟢 §5.5).
    case activeHeartRateMonitoring
    /// Bool: high-accuracy sleep monitoring.
    case highAccuracySleep
    /// Bool: sleep breathing quality; sleep SpO₂ (fetch type `0x26`) needs it (§17.7).
    case sleepBreathingQuality
    /// Bool: stress monitoring.
    case stressMonitoring
    /// Bool: all-day SpO₂ monitoring.
    case allDaySpO2
    /// Byte threshold, bpm; `00` = off (§13.4).
    case highHeartRateAlert
    /// Byte threshold, bpm; `00` = off (§13.4).
    case lowHeartRateAlert
    /// Bool: the relax (stress) reminder.
    case relaxReminder
    /// Byte threshold, %; `00` = off.
    case lowSpO2Alert
    // WORKOUT (`09`), §19.1
    /// Bool: alert when a workout is detected (on the Helio 🔴 probably a buzz).
    case workoutDetectionAlert
    /// Byte: detection sensitivity, `00` high, `01` standard, `02` low; the allowed list decides.
    case workoutDetectionSensitivity
    // HEALTH (`08`) again, §5.5, §18.9 (#359, decision 89g)
    /// Bool: Heart Rate Broadcast (Zepp's switch, formerly "Heart Rate Push"): live heart rate to gym
    /// equipment, other apps and devices. Read `03 00 08 01 83`, written `05 08 <v> 00 01 83 0b <00|01>`.
    case heartRateBroadcast

    /// The recording and sampling settings (#228), in display order.
    public static let measurement: [ZeppSetting] = [
        .heartRateMonitoring, .activeHeartRateMonitoring, .highAccuracySleep, .sleepBreathingQuality,
        .stressMonitoring, .allDaySpO2,
    ]

    /// The strap's own haptic alerts (#230), in display order.
    public static let alerts: [ZeppSetting] = [.highHeartRateAlert, .lowHeartRateAlert, .lowSpO2Alert, .relaxReminder]

    /// Workout detection (#229): the alert and the sensitivity only, as Gadgetbridge ships for the
    /// Helio (§19.2).
    public static let workoutDetection: [ZeppSetting] = [.workoutDetectionAlert, .workoutDetectionSensitivity]

    /// Heart Rate Broadcast (#359, decision 89g): its own switch on the strap settings screen.
    public static let broadcast: [ZeppSetting] = [.heartRateBroadcast]

    public var group: UInt8 {
        switch self {
        case .workoutDetectionAlert, .workoutDetectionSensitivity: return ZeppConfig.workoutGroup
        default: return ZeppConfig.healthGroup
        }
    }

    public var argument: UInt8 {
        switch self {
        case .heartRateMonitoring: return ZeppConfig.HealthArgument.heartRateMonitoring
        case .activeHeartRateMonitoring: return ZeppConfig.HealthArgument.heartRateDuringActivity
        case .highAccuracySleep: return ZeppConfig.HealthArgument.highAccuracySleep
        case .sleepBreathingQuality: return ZeppConfig.HealthArgument.sleepBreathingQuality
        case .stressMonitoring: return ZeppConfig.HealthArgument.stressMonitoring
        case .allDaySpO2: return ZeppConfig.HealthArgument.allDaySpO2
        case .highHeartRateAlert: return 0x02
        case .lowHeartRateAlert: return 0x03
        case .relaxReminder: return 0x14
        case .lowSpO2Alert: return 0x32
        case .workoutDetectionAlert: return 0x41
        case .workoutDetectionSensitivity: return 0x42
        case .heartRateBroadcast: return ZeppConfig.HealthArgument.heartRateBroadcast
        }
    }

    /// true for a bool (`0b`) switch, false for a byte (`10`) with an allowed list (§17.6).
    public var isSwitch: Bool {
        switch self {
        case .heartRateMonitoring, .highHeartRateAlert, .lowHeartRateAlert, .lowSpO2Alert, .workoutDetectionSensitivity:
            return false
        default:
            return true
        }
    }

    /// What this setting needs from another (§17.7).
    public var requirement: ZeppSettingRequirement? {
        switch self {
        case .relaxReminder: return .init(parent: .stressMonitoring, condition: .on, onlyIfReported: false)
        case .lowSpO2Alert: return .init(parent: .allDaySpO2, condition: .on, onlyIfReported: false)
        // SPEC-GAP: §17.7 ties "activity monitoring" (`04`) and the HR alerts to all-day HR not off,
        // but says Gadgetbridge never greys the HR alerts out on a display-less strap whose HR is
        // always on, and worked example K applies no dependency on the Helio. Conservative reading:
        // when the strap reports arg `01` and it reads off, these are unavailable; when the strap
        // doesn't report `01` at all (Gadgetbridge hides it on the Helio, 🔴 §17.9), no dependency.
        case .activeHeartRateMonitoring, .highHeartRateAlert, .lowHeartRateAlert:
            return .init(parent: .heartRateMonitoring, condition: .notOff, onlyIfReported: true)
        // SPEC-GAP: §17.7 says the WORKOUT detection args need "workout detection on", but no
        // on/off arg is known (§19.2): nothing to check, and nothing is invented.
        default: return nil
        }
    }

    /// The settings whose requirement names this one.
    public var dependents: [ZeppSetting] {
        Self.allCases.filter { $0.requirement?.parent == self }
    }
}

/// §17.7: a child setting and the parent state it needs.
public struct ZeppSettingRequirement: Equatable {
    public enum Condition: Equatable {
        /// The parent is a switch that reads on.
        case on
        /// The parent is a byte that doesn't read `00` (off).
        case notOff
    }

    public let parent: ZeppSetting
    public let condition: Condition
    /// The requirement applies only when the strap reports the parent (see the SPEC-GAP above).
    public let onlyIfReported: Bool
}

extension ZeppConfig {
    /// The WORKOUT settings group (§19.1).
    public static let workoutGroup: UInt8 = 0x09

    /// The group versions whose args the spec describes (§17.3): writes only go to these.
    public static func describedVersions(group: UInt8) -> ClosedRange<UInt8>? {
        switch group {
        case healthGroup: return 1...3
        case workoutGroup: return 1...1
        default: return nil
        }
    }
}

/// What the strap reported for the settings, merged over this connection's reads. The strap's
/// values, for display and validation: never "the setting" on the phone's side.
public struct ZeppSettingsSnapshot: Equatable {

    public struct Entry: Equatable {
        /// The value; its case is the type code the strap reported (§17.3: written back as read).
        public let value: ZeppConfigValue
        /// A byte setting's allowed values, exactly as the strap listed them; nil for a switch.
        public let allowedValues: [UInt8]?
    }

    public enum Availability: Equatable {
        case available
        /// Not reported with the expected type in this connection: hide it.
        case notReported
        /// The group's version isn't one the spec describes, or it changed under a write in this
        /// connection (§17.3, §17.5): show the value, never write it.
        case readOnly
        /// The parent doesn't allow it (§17.7): show it disabled, with its stored value and why.
        case needs(ZeppSetting)
    }

    public private(set) var entries: [ZeppSetting: Entry] = [:]
    /// The version from the latest read reply for each group in this connection (§17.3).
    public private(set) var groupVersions: [UInt8: UInt8] = [:]
    /// Settings a re-read showed missing or retyped: unsupported for the rest of the connection (§17.5).
    public private(set) var hidden: Set<ZeppSetting> = []
    /// Groups whose version changed under a write: no more writes this connection (§17.5).
    public private(set) var frozenGroups: Set<UInt8> = []

    public init() {}

    /// Merges a constraints-included read reply that asked for `requested` arg codes.
    public mutating func merge(_ reply: ZeppConfigReadReply, requested: [UInt8]) {
        groupVersions[reply.group] = reply.groupVersion
        for setting in ZeppSetting.allCases where setting.group == reply.group && requested.contains(setting.argument) {
            guard !hidden.contains(setting) else { continue }
            let matches = reply.entries.filter { $0.argument == setting.argument }
            var parsed: Entry?
            if matches.count == 1, let entry = matches.first {
                switch (setting.isSwitch, entry.value, entry.constraint) {
                case (true, .bool, _):
                    parsed = Entry(value: entry.value, allowedValues: nil)
                case (false, .byte, .allowedValues(let allowed)?):
                    // An empty allowed list gives no basis for a value (§17.6): shown, never offered.
                    parsed = Entry(value: entry.value, allowedValues: allowed)
                default:
                    parsed = nil
                }
            }
            if let parsed {
                entries[setting] = parsed
            } else {
                // Missing or retyped. Once seen this connection, it stays hidden (§17.5).
                if entries[setting] != nil { hidden.insert(setting) }
                entries[setting] = nil
            }
        }
    }

    /// The strap answered the re-read with something unparseable, so what it holds is unknown: show
    /// nothing stale for this setting until the next read of its group re-merges it. NOT used for a
    /// re-read that never answered (review-240b S-1), and not for one that answered without the entry
    /// (that is `merge`'s §17.5 path, which also hides it for the connection).
    public mutating func forget(_ setting: ZeppSetting) {
        entries[setting] = nil
    }

    public mutating func freeze(group: UInt8) {
        frozenGroups.insert(group)
    }

    public func value(_ setting: ZeppSetting) -> ZeppConfigValue? { entries[setting]?.value }

    public func isOn(_ setting: ZeppSetting) -> Bool? {
        if case .bool(let on)? = value(setting) { return on }
        return nil
    }

    /// The group was read in this connection, at a version the spec describes, and not frozen.
    public func isWritable(group: UInt8) -> Bool {
        guard let version = groupVersions[group], let described = ZeppConfig.describedVersions(group: group) else { return false }
        return described.contains(version) && !frozenGroups.contains(group)
    }

    /// The values the user may pick: off/on for a switch, the strap's allowed list (in its order)
    /// for a byte. Empty when the strap didn't report the setting.
    public func options(_ setting: ZeppSetting) -> [ZeppConfigValue] {
        guard let entry = entries[setting] else { return [] }
        if let allowed = entry.allowedValues { return allowed.map(ZeppConfigValue.byte) }
        return [.bool(false), .bool(true)]
    }

    public func availability(_ setting: ZeppSetting) -> Availability {
        guard entries[setting] != nil else { return .notReported }
        guard isWritable(group: setting.group) else { return .readOnly }
        if let requirement = setting.requirement, !isSatisfied(requirement) { return .needs(requirement.parent) }
        return .available
    }

    private func isSatisfied(_ requirement: ZeppSettingRequirement) -> Bool {
        guard let value = value(requirement.parent) else { return requirement.onlyIfReported }
        switch requirement.condition {
        case .on: return value == .bool(true)
        case .notOff: return value != .byte(0)
        }
    }

    /// Throws unless `value` is one the strap offers for `setting` and the setting may be written.
    public func validate(_ setting: ZeppSetting, _ value: ZeppConfigValue) throws {
        switch availability(setting) {
        case .available: break
        case .notReported: throw ZeppSettingsEditor.Error.notReported(setting)
        case .readOnly: throw ZeppSettingsEditor.Error.readOnly(setting)
        case .needs(let parent): throw ZeppSettingsEditor.Error.prerequisiteOff(setting, needs: parent)
        }
        guard options(setting).contains(value) else { throw ZeppSettingsEditor.Error.valueNotAllowed(setting, value) }
    }
}

/// The §17.8 sequence as a pure state machine, one per connection. Every message it returns goes to
/// the config endpoint (0x000A); feed it every decoded config payload that isn't a session-setup
/// reply, and call `tick(now:)` at `nextDeadline`. One config exchange is in flight at a time.
public struct ZeppSettingsEditor {

    public struct Configuration: Equatable {
        /// How long to wait for a read reply or a write ack: 5 s (§17.4).
        public var replyTimeout: TimeInterval

        public init(replyTimeout: TimeInterval = 5) {
            self.replyTimeout = replyTimeout
        }
    }

    /// The args a group's full read asks for, in order.
    /// HEALTH: every HEALTH setting above. WORKOUT: `40 41 42` as in worked example M (§19.4); `40` is
    /// read but never modelled or written.
    public static func groupArguments(_ group: UInt8) -> [UInt8] {
        let settings = ZeppSetting.allCases.filter { $0.group == group }.map(\.argument)
        return group == ZeppConfig.workoutGroup ? [0x40] + settings : settings
    }

    /// The full read of a group, with constraints: HEALTH `03 01 08 0b 01 04 11 12 13 31 02 03 14 32 83`,
    /// WORKOUT `03 01 09 03 40 41 42`.
    public static func readRequest(group: UInt8) -> [UInt8] {
        ZeppConfig.readRequest(group: group, arguments: groupArguments(group), includeConstraints: true)
    }

    /// §17.8 step 2: the setting's parent (whether or not the strap reports it), then the setting.
    public static func familyArguments(_ setting: ZeppSetting) -> [UInt8] {
        (setting.requirement.map { [$0.parent.argument] } ?? []) + [setting.argument]
    }

    public static func familyRequest(_ setting: ZeppSetting) -> [UInt8] {
        ZeppConfig.readRequest(group: setting.group, arguments: familyArguments(setting), includeConstraints: true)
    }

    public enum ReadFailure: Swift.Error, Equatable {
        case timedOut
        /// Not a well-formed `04 01` reply for the group, with constraints included.
        case malformed
    }

    /// One user edit of one setting: the value the user saw, and the one they picked.
    public struct Change: Equatable {
        public let setting: ZeppSetting
        public let from: ZeppConfigValue
        public let to: ZeppConfigValue

        public init(setting: ZeppSetting, from: ZeppConfigValue, to: ZeppConfigValue) {
            self.setting = setting
            self.from = from
            self.to = to
        }
    }

    public enum WriteFailure: Equatable {
        /// `06` with a status other than `01` (nil: the status byte was missing), §17.4 (a).
        case status(UInt8?)
        /// No `06` in 5 s, §17.4 (b).
        case noAck
    }

    /// The re-read after a write, acknowledged or not (§17.5).
    public struct WriteCheck: Equatable {
        public let change: Change
        /// nil when the strap acknowledged `06 01`.
        public let failure: WriteFailure?
        /// The strap's value for the setting now; nil when the re-read no longer reports it (it is
        /// hidden for the rest of the connection).
        public let readBack: ZeppConfigValue?
        /// The re-read's group version differed from the one written: no more writes to the group
        /// this connection, and the whole group is being re-read (§17.5).
        public let groupVersionChanged: Bool
        /// The strap now holds the requested value.
        public var matches: Bool { readBack == change.to }
        /// §17.4: only `06 01` AND the new value on re-read count as taken. Anything else, including
        /// `06 01` with the old value (c), is "the strap did not take the change".
        public var tookChange: Bool { failure == nil && matches }
    }

    public enum Event: Equatable {
        case read(group: UInt8)
        case readFailed(group: UInt8, ReadFailure)
        /// The fresh read before the write found a different value than the user saw: nothing written.
        case changedOnStrap(Change, current: ZeppConfigValue?)
        /// The fresh read before the write made the change invalid: nothing written.
        case refused(Change, Error)
        case writeAcknowledged(Change)
        /// The write failed; a re-read is under way.
        case writeNotAcknowledged(Change, WriteFailure)
        case writeChecked(WriteCheck)
        /// The re-read after the write failed: the strap's value is unknown.
        case writeUnverified(Change, failure: WriteFailure?, ReadFailure)
    }

    public enum Error: Swift.Error, Equatable {
        /// A read or write is in flight (§17.4: one config exchange at a time).
        case busy
        /// The config capabilities (§5.5) weren't read on this connection, the service version
        /// isn't understood, or the group isn't listed.
        case groupNotOffered(UInt8)
        /// The group hasn't been read in this connection (§17.3: read first).
        case notRead
        /// The strap didn't report this setting with the expected type: never write it (§14).
        case notReported(ZeppSetting)
        /// The group's version isn't one the spec describes, or changed under a write (§17.3, §17.5).
        case readOnly(ZeppSetting)
        /// `from` equals `to`: the user changed nothing, so nothing is written.
        case unchanged(ZeppSetting)
        /// Not one of the strap's allowed values (§17.6).
        case valueNotAllowed(ZeppSetting, ZeppConfigValue)
        /// The parent doesn't allow it (§17.7).
        case prerequisiteOff(ZeppSetting, needs: ZeppSetting)
    }

    public struct Output: Equatable {
        public var messages: [ZeppControlMessage] = []
        public var events: [Event] = []
    }

    private enum Pending: Equatable {
        case none
        case reading(group: UInt8, arguments: [UInt8], deadline: Date)
        case preReading(Change, deadline: Date)
        case writing(Change, version: UInt8, deadline: Date)
        case verifying(Change, version: UInt8, failure: WriteFailure?, deadline: Date)
    }

    public let capabilities: ZeppControlCapabilities
    public let configuration: Configuration
    public private(set) var configCapabilities: ZeppConfigCapabilities?
    public private(set) var snapshot = ZeppSettingsSnapshot()
    /// The last read failure per group; cleared by a good read of that group.
    public private(set) var readFailures: [UInt8: ReadFailure] = [:]
    private var pending: Pending = .none
    private var readQueue: [UInt8] = []

    public init(capabilities: ZeppControlCapabilities, configCapabilities: ZeppConfigCapabilities? = nil,
                configuration: Configuration = Configuration()) {
        self.capabilities = capabilities
        self.configCapabilities = configCapabilities
        self.configuration = configuration
    }

    /// The config capabilities reply of this connection (§5.5).
    public mutating func noteConfigCapabilities(_ capabilities: ZeppConfigCapabilities?) {
        configCapabilities = capabilities
    }

    /// §17.8 step 1 for the group: the config endpoint is listed (the `.hapticAlerts` control is that
    /// endpoint's gate), and this connection's config capabilities list the group at an understood
    /// service version.
    public func isOffered(group: UInt8) -> Bool {
        guard capabilities.isSupported(.hapticAlerts), let configCapabilities else { return false }
        return configCapabilities.isVersionUnderstood && configCapabilities.groups.contains(group)
    }

    /// The group was read in this connection.
    public func hasRead(group: UInt8) -> Bool { snapshot.groupVersions[group] != nil }

    public var isBusy: Bool { pending != .none }

    /// The change being read, written or checked, for the UI's "Saving…".
    public var changeInFlight: Change? {
        switch pending {
        case .none, .reading: return nil
        case .preReading(let change, _), .writing(let change, _, _), .verifying(let change, _, _, _): return change
        }
    }

    public var nextDeadline: Date? {
        switch pending {
        case .none: return nil
        case .reading(_, _, let deadline), .preReading(_, let deadline), .writing(_, _, let deadline),
             .verifying(_, _, _, let deadline):
            return deadline
        }
    }

    // MARK: Inputs

    /// Reads every listed group of `groups` in full, with constraints, one after another. Read-only.
    /// A group already queued or being read is not asked twice.
    public mutating func read(groups: [UInt8], now: Date) throws -> Output {
        try capabilities.require(.hapticAlerts)
        let offered = groups.filter { isOffered(group: $0) }
        guard !offered.isEmpty else { throw Error.groupNotOffered(groups.first ?? 0) }
        switch pending {
        case .none: break
        case .reading(let current, _, _):
            for group in offered where group != current && !readQueue.contains(group) { readQueue.append(group) }
            return Output()
        default:
            throw Error.busy
        }
        readQueue = Array(offered.dropFirst())
        return startRead(offered[0], now: now)
    }

    /// Starts one user edit: a fresh read of the setting and its parent first (§17.8 step 2); the
    /// write goes out only if that read still holds `change.from` and `change.to` passes §17.8 step 3.
    public mutating func change(_ change: Change, now: Date) throws -> Output {
        try capabilities.require(.hapticAlerts)
        guard isOffered(group: change.setting.group) else { throw Error.groupNotOffered(change.setting.group) }
        guard pending == .none else { throw Error.busy }
        guard change.from != change.to else { throw Error.unchanged(change.setting) }
        guard hasRead(group: change.setting.group) else { throw Error.notRead }
        // Checked against the last read too, so a value the UI never offered fails here, loudly.
        try snapshot.validate(change.setting, change.to)
        pending = .preReading(change, deadline: now.addingTimeInterval(configuration.replyTimeout))
        return Output(messages: [Self.message(Self.familyRequest(change.setting))])
    }

    /// A decoded payload from the config endpoint.
    ///
    /// `mayWrite` is the caller's §17.8 step 1 check made NOW, when a pre-read's reply would release
    /// the write: no history fetch running, the app in front. The tap's check is a round trip old by
    /// then; a sync or backgrounding in between ends the change with `.refused(change, .busy)` and
    /// nothing is sent (review-240 S1, S2).
    public mutating func receive(_ payload: [UInt8], now: Date, mayWrite: Bool = true) -> Output {
        switch payload.first {
        case 0x04: return receiveRead(payload, now: now, mayWrite: mayWrite)
        case 0x06: return receiveAck(ZeppConfig.parseWriteAck(payload), now: now)
        default: return Output()
        }
    }

    /// Call at (or after) `nextDeadline`.
    public mutating func tick(now: Date) -> Output {
        guard let deadline = nextDeadline, now >= deadline else { return Output() }
        switch pending {
        case .none:
            return Output()
        case .reading(let group, _, _):
            pending = .none
            readFailures[group] = .timedOut
            return Output(events: [.readFailed(group: group, .timedOut)]).merged(nextQueuedRead(now: now))
        case .preReading(let change, _):
            pending = .none
            readFailures[change.setting.group] = .timedOut
            return Output(events: [.readFailed(group: change.setting.group, .timedOut), .refused(change, .notRead)])
        case .writing(let change, let version, _):
            // §17.4 (b): no `06`. Re-read so the screen shows what the strap actually holds.
            return reRead(change, version: version, failure: .noAck, now: now)
        case .verifying(let change, _, let failure, _):
            // A re-read that never ANSWERED says nothing about the setting: keep the last READ value
            // (never the written one) and record the group's read as timed out, so the row stays
            // visible with "couldn't be read back" (review-240b S-1). §17.5's "missing or retyped →
            // hide" is for a re-read that answered, and only `merge` applies it.
            pending = .none
            readFailures[change.setting.group] = .timedOut
            return Output(events: [.writeUnverified(change, failure: failure, .timedOut)])
        }
    }

    // MARK: Steps

    private static func message(_ payload: [UInt8]) -> ZeppControlMessage {
        ZeppControlMessage(endpoint: ZeppEndpoint.config, payload: payload)
    }

    private mutating func startRead(_ group: UInt8, now: Date) -> Output {
        let arguments = Self.groupArguments(group)
        pending = .reading(group: group, arguments: arguments, deadline: now.addingTimeInterval(configuration.replyTimeout))
        return Output(messages: [Self.message(Self.readRequest(group: group))])
    }

    private mutating func nextQueuedRead(now: Date) -> Output {
        while !readQueue.isEmpty {
            let group = readQueue.removeFirst()
            if isOffered(group: group) { return startRead(group, now: now) }
        }
        return Output()
    }

    /// A read reply for `group`, or nil when it isn't one (status not `01`, wrong group, no constraints).
    private static func parse(_ payload: [UInt8], group: UInt8) -> ZeppConfigReadReply? {
        guard let reply = ZeppConfig.parseReadReply(payload), reply.group == group, reply.includesConstraints else { return nil }
        return reply
    }

    private mutating func receiveRead(_ payload: [UInt8], now: Date, mayWrite: Bool) -> Output {
        switch pending {
        case .reading(let group, let arguments, _):
            pending = .none
            guard let reply = Self.parse(payload, group: group) else {
                readFailures[group] = .malformed
                return Output(events: [.readFailed(group: group, .malformed)]).merged(nextQueuedRead(now: now))
            }
            snapshot.merge(reply, requested: arguments)
            readFailures[group] = nil
            return Output(events: [.read(group: group)]).merged(nextQueuedRead(now: now))
        case .preReading(let change, _):
            pending = .none
            let group = change.setting.group
            guard let reply = Self.parse(payload, group: group) else {
                readFailures[group] = .malformed
                return Output(events: [.readFailed(group: group, .malformed), .refused(change, .notRead)])
            }
            snapshot.merge(reply, requested: Self.familyArguments(change.setting))
            readFailures[group] = nil
            var events: [Event] = [.read(group: group)]
            guard mayWrite else {
                events.append(.refused(change, .busy))
                return Output(events: events)
            }
            let current = snapshot.value(change.setting)
            guard current == change.from else {
                events.append(.changedOnStrap(change, current: current))
                return Output(events: events)
            }
            do {
                try snapshot.validate(change.setting, change.to)
            } catch let error as Error {
                events.append(.refused(change, error))
                return Output(events: events)
            } catch {
                return Output(events: events)
            }
            // Version as read; the type is the read's (validate only passes a value of the same case).
            guard let version = snapshot.groupVersions[group],
                  let write = ZeppConfig.writeRequest(group: group, groupVersion: version,
                                                      entries: [(change.setting.argument, change.to)]) else {
                events.append(.refused(change, .valueNotAllowed(change.setting, change.to)))
                return Output(events: events)
            }
            pending = .writing(change, version: version, deadline: now.addingTimeInterval(configuration.replyTimeout))
            return Output(messages: [Self.message(write)], events: events)
        case .verifying(let change, let version, let failure, _):
            pending = .none
            let group = change.setting.group
            guard let reply = Self.parse(payload, group: group) else {
                snapshot.forget(change.setting)
                readFailures[group] = .malformed
                return Output(events: [.writeUnverified(change, failure: failure, .malformed)])
            }
            snapshot.merge(reply, requested: Self.familyArguments(change.setting))
            readFailures[group] = nil
            let versionChanged = reply.groupVersion != version
            let check = WriteCheck(change: change, failure: failure, readBack: snapshot.value(change.setting),
                                   groupVersionChanged: versionChanged)
            guard versionChanged else { return Output(events: [.writeChecked(check)]) }
            // §17.5: stop writing to the group this connection, and re-read the whole group.
            snapshot.freeze(group: group)
            return Output(events: [.writeChecked(check)]).merged(startRead(group, now: now))
        case .none, .writing:
            // SPEC-GAP: the strap is not known to send a read reply unasked. One that arrives unasked
            // (or after its read timed out) is ignored rather than standing in for a read.
            return Output()
        }
    }

    private mutating func receiveAck(_ status: UInt8?, now: Date) -> Output {
        // A `06` that isn't for the write in flight (late, after the timeout) is ignored (§17.4).
        guard case .writing(let change, let version, _) = pending else { return Output() }
        guard status == 0x01 else {
            return reRead(change, version: version, failure: .status(status), now: now)
        }
        pending = .verifying(change, version: version, failure: nil, deadline: now.addingTimeInterval(configuration.replyTimeout))
        return Output(messages: [Self.message(Self.familyRequest(change.setting))], events: [.writeAcknowledged(change)])
    }

    /// A failed write still ends in a re-read: the screen must show the strap's actual value. No retry.
    private mutating func reRead(_ change: Change, version: UInt8, failure: WriteFailure, now: Date) -> Output {
        pending = .verifying(change, version: version, failure: failure, deadline: now.addingTimeInterval(configuration.replyTimeout))
        return Output(messages: [Self.message(Self.familyRequest(change.setting))],
                      events: [.writeNotAcknowledged(change, failure)])
    }
}

private extension ZeppSettingsEditor.Output {
    func merged(_ other: ZeppSettingsEditor.Output) -> ZeppSettingsEditor.Output {
        ZeppSettingsEditor.Output(messages: messages + other.messages, events: events + other.events)
    }
}

extension ZeppHealthSettings {
    /// The recording switches from the settings the strap reported, so the recording warnings
    /// follow what the strap holds after a change. Heart-rate sharing (`05`) is not read: nil, never
    /// warned about.
    public init(_ snapshot: ZeppSettingsSnapshot) {
        if case .byte(let v)? = snapshot.value(.heartRateMonitoring) { heartRateMonitoring = v } else { heartRateMonitoring = nil }
        heartRateDuringActivity = snapshot.isOn(.activeHeartRateMonitoring)
        heartRateSharing = nil
        highAccuracySleep = snapshot.isOn(.highAccuracySleep)
        sleepBreathingQuality = snapshot.isOn(.sleepBreathingQuality)
        stressMonitoring = snapshot.isOn(.stressMonitoring)
        allDaySpO2 = snapshot.isOn(.allDaySpO2)
    }
}

// The strap's own workout mode on endpoint 0x0019 (ZEPP_PROTOCOL.md §18.9, route 2; #359, decision 89).
//
// Built from §18.9 alone: every phone → strap message there, the `10 <op> <status>` replies, the state
// reply and the `14` frames the strap sends once a second while a workout runs. Pure: builders and
// parsers, plus `ZeppWorkoutModeMachine`, the sequence as a state machine with no I/O and no clock of
// its own. The host (`HelioSession`) sends what it returns to 0x0019, feeds it every 0x0019 payload,
// calls `tick(now:)` and persists the marker on the events that ask for it.
//
// What the mode is for (89d): the strap measures better in it, and the standard `0x2A37` stream
// carries that (§18.9: the frames' HR equals `0x2A37` second for second). So heart rate keeps coming
// from `0x2A37` exactly as before; the frames only feed the swing count and the strap's kcal (89e).
//
// Rules the machine enforces (§18.9 "Rules for OpenCircuit", decision 89):
//   • never start without first reading `06 00` as idle, and never touch a running workout whose
//     start time isn't ours (89f);
//   • every end is `03 02` then `03 04`, even when already paused (89a), fallbacks included (89j:
//     `03 05` saves too on our strap, so its meaning is unknown and it is never sent; the builder
//     doesn't exist);
//   • any failure falls back to the phone-side workout, quietly (89c); a start that was accepted but
//     sent no frame is ended at about 15 s, under the length the strap or Zepp keeps (89j);
//   • the marker ("OpenCircuit started a strap workout") is set before `02` goes out and cleared only
//     once the strap is known not to hold our workout any more (89f);
//   • a pause, resume or End asked for while `06 00` is in flight is kept, and the reply is decided on
//     the marker as it is when the reply arrives (89o a);
//   • an unanswered `02` is never limbo (89p a): `06 00` goes out at once, and its "running, ours"
//     reply, a late `10 02 01` or any `14` frame is the same evidence: `03 01` with our start time,
//     then the stored End if there is one, else on as running. Idle → fallback; anything else →
//     fallback with the marker kept and flagged start-unconfirmed for the next connection;
//   • End is sticky (89p b): asked for in any phase, it is kept, and every "running, ours" conclusion
//     ends the workout instead of carrying on.
//   • the marker is persisted start-unconfirmed before `02` and the flag goes only with the ack of our
//     `03 01` or an exact-start `06 00` (89q a); a late `06 00` reply is still decided, and our
//     accepted `10 02` after a "foreign" read is still adopted (89q b, c), but never a frame then:
//     it may be the other workout's (89r a).

import Foundation
import OpenCircuitKit

// MARK: - Sports (decision 89b: the one table)

/// The strap's sport code for an OpenCircuit sport, and the exact start request.
public struct ZeppWorkoutSport: Equatable, Hashable, Sendable {
    public let code: UInt8
    /// `02 <code> …`: the 5-byte form, or the racket form Zepp sent for pickleball (§18.9).
    public let startRequest: [UInt8]
    /// Started and answered on our strap (§18.9: `02`, `34`, `11`, `e3`). The others are 🔴 and rely on
    /// the fallback (89c).
    public let isHardwareTested: Bool

    init(code: UInt8, startRequest: [UInt8]? = nil, isHardwareTested: Bool) {
        self.code = code
        self.startRequest = startRequest ?? [0x02, code, 0x00, 0x00, 0x01]
        self.isHardwareTested = isHardwareTested
    }

    /// Decision 89b. nil = no strap mode in this version: the outdoor sports (the strap sent no frame
    /// for an outdoor run without phone GPS, §18.9) stay phone-side exactly as before.
    public static func forSport(_ sport: WorkoutSportType) -> ZeppWorkoutSport? {
        switch sport {
        case .runningIndoor: return ZeppWorkoutSport(code: 0x02, isHardwareTested: true)
        case .strengthTraining: return ZeppWorkoutSport(code: 0x34, isHardwareTested: true)
        case .cyclingIndoor: return ZeppWorkoutSport(code: 0x08, isHardwareTested: false)
        case .rowing: return ZeppWorkoutSport(code: 0x17, isHardwareTested: false)
        case .yoga: return ZeppWorkoutSport(code: 0x3c, isHardwareTested: false)
        case .walkingIndoor: return ZeppWorkoutSport(code: 0x28, isHardwareTested: false)
        case .other: return ZeppWorkoutSport(code: 0x05, isHardwareTested: false)
        case .tennis: return ZeppWorkoutSport(code: 0x11, isHardwareTested: true)
        case .pickleball:
            // Byte for byte what Zepp sent (§18.9); the extra bytes are probably arm and racket options 🔴.
            return ZeppWorkoutSport(code: 0xe3, startRequest: [0x02, 0xe3, 0x00, 0x01, 0x01, 0x02, 0x00, 0x00, 0x00, 0x02],
                                    isHardwareTested: true)
        case .walkingOutdoor, .runningOutdoor, .cyclingOutdoor, .hiking: return nil
        }
    }
}

// MARK: - Phone → strap

public enum ZeppWorkoutCommand {
    public static let capabilityOpcode: UInt8 = 0x01
    public static let startOpcode: UInt8 = 0x02
    public static let controlOpcode: UInt8 = 0x03
    public static let stateOpcode: UInt8 = 0x06

    /// `01`, sent first. Its reply's fields after the status are unexplained 🔴.
    public static let capabilityQuery: [UInt8] = [0x01]
    /// `06 00`.
    public static let stateQuery: [UInt8] = [0x06, 0x00]
    /// `05`, about every 5 s while a workout runs. Not required (§18.9), so a missed one is never an error.
    public static let keepAlive: [UInt8] = [0x05]

    public enum Control: UInt8, Equatable, Sendable {
        case started = 0x01
        case pause = 0x02
        case resume = 0x03
        /// The only end the app sends (89j). §18.9's `03 05` is not built: on our strap it saved too.
        case end = 0x04
    }

    /// `03 01 06 00 00 00 <u32 start, Unix s> 00 00 00 00`: the start time the phone records.
    public static func started(startTime: UInt32) -> [UInt8] {
        [0x03, Control.started.rawValue] + ZeppLE.u32(6) + ZeppLE.u32(startTime) + [0x00, 0x00, 0x00, 0x00]
    }

    /// `03 <op> 04 00 00 00 <u32 active s>` for pause, resume and the two ends.
    public static func control(_ control: Control, activeSeconds: UInt32) -> [UInt8] {
        precondition(control != .started, "started carries a start time: use started(startTime:)")
        return [0x03, control.rawValue] + ZeppLE.u32(4) + ZeppLE.u32(activeSeconds)
    }

    /// Every end: pause first, then the end (§18.9, decision 89a), even when already paused.
    public static func end(activeSeconds: UInt32) -> [[UInt8]] {
        [control(.pause, activeSeconds: activeSeconds), control(.end, activeSeconds: activeSeconds)]
    }
}

// MARK: - Strap → phone

/// `10 <opcode> <status> …`: the strap's reply to a phone command. Status `01` = accepted (the only
/// status seen, §18.9).
public struct ZeppWorkoutReply: Equatable, Sendable {
    public let opcode: UInt8
    public let status: UInt8
    /// The bytes after the status.
    public let body: [UInt8]

    public var isAccepted: Bool { status == 0x01 }

    /// nil unless it starts `10` and carries an opcode and a status.
    public static func parse(_ payload: [UInt8]) -> ZeppWorkoutReply? {
        guard payload.count >= 3, payload[0] == 0x10 else { return nil }
        return ZeppWorkoutReply(opcode: payload[1], status: payload[2], body: Array(payload[3...]))
    }
}

/// The state reply to `06 00`.
public enum ZeppWorkoutState: Equatable, Sendable {
    /// `10 06 01 00 00`.
    case idle
    /// `10 06 01 00 01 <u32 start, Unix s> <u8 sport>`.
    case running(startTime: UInt32, sport: UInt8)
    /// A state reply this spec can't place (another status, another state byte, truncated). Never
    /// read as idle: nothing is started on it, and nothing on it is touched.
    case unknown

    /// nil unless the payload is a `10 06` reply.
    public static func parse(_ payload: [UInt8]) -> ZeppWorkoutState? {
        guard let reply = ZeppWorkoutReply.parse(payload), reply.opcode == ZeppWorkoutCommand.stateOpcode else { return nil }
        guard reply.isAccepted, reply.body.count >= 2, reply.body[0] == 0x00 else { return .unknown }
        switch reply.body[1] {
        case 0x00 where reply.body.count == 2:
            return .idle
        case 0x01:
            var reader = ZeppByteReader(reply.body, offset: 2)
            guard let start = reader.u32(), let sport = reader.u8() else { return .unknown }
            return .running(startTime: start, sport: sport)
        default:
            return .unknown
        }
    }
}

/// One second of the strap's workout (§18.9): `14 00 24 01 00 <fields> <u32 active s> <u8 HR>
/// <u32 kcal> <u8 avg HR> <u8 max HR> [<u16 swings>]`.
public struct ZeppWorkoutLiveFrame: Equatable, Sendable {
    public let fields: UInt8
    public let activeSeconds: UInt32
    /// Equals `0x2A37` in the same second (§18.9). Never used as a heart-rate source (89d).
    public let heartRate: UInt8
    /// The strap's own running total.
    public let kilocalories: UInt32
    public let averageHeartRate: UInt8
    public let maximumHeartRate: UInt8
    /// nil when the frame doesn't carry them (fields bit `0x08` clear, or a fields value the spec
    /// doesn't place).
    public let swings: UInt16?

    public init(fields: UInt8, activeSeconds: UInt32, heartRate: UInt8, kilocalories: UInt32, averageHeartRate: UInt8,
                maximumHeartRate: UInt8, swings: UInt16?) {
        self.fields = fields
        self.activeSeconds = activeSeconds
        self.heartRate = heartRate
        self.kilocalories = kilocalories
        self.averageHeartRate = averageHeartRate
        self.maximumHeartRate = maximumHeartRate
        self.swings = swings
    }
}

public enum ZeppWorkoutFrame: Equatable, Sendable {
    /// `14 00 26 01 00 <fields> <u32 start, Unix s> 00 …`, the first frame (zero-filled after the start).
    case first(startTime: UInt32)
    case live(ZeppWorkoutLiveFrame)
    /// A `14` message this spec can't place: it still says the strap is streaming, nothing more.
    case unknown

    /// The fields bit that adds the u16 swing count (🟡 §18.9: `0e` has swings, `06` doesn't).
    public static let swingsBit: UInt8 = 0x08
    /// The low bits of every fields value seen (`06`, `0e`): the base layout below.
    static let baseBits: UInt8 = 0x06

    /// nil unless the payload starts `14`. Truncated or unknown input is `.unknown`, never a trap.
    public static func parse(_ payload: [UInt8]) -> ZeppWorkoutFrame? {
        guard payload.first == 0x14 else { return nil }
        guard payload.count >= 6, payload[1] == 0x00, payload[3] == 0x01, payload[4] == 0x00 else { return .unknown }
        let fields = payload[5]
        var reader = ZeppByteReader(payload, offset: 6)
        switch payload[2] {
        case 0x26:
            guard let start = reader.u32() else { return .unknown }
            return .first(startTime: start)
        case 0x24:
            // SPEC-GAP: only `06` and `0e` are seen. Their low three bits are `110`; the fields are read
            // in that layout only, and the swings only with bit `0x08` on top of it. A value whose low
            // bits differ may move the fields, so nothing is placed from it (89e: ignore, never fail).
            // Higher bits are taken to add fields AFTER these (ignored).
            guard fields & 0x07 == baseBits,
                  let active = reader.u32(), let hr = reader.u8(), let kcal = reader.u32(),
                  let avg = reader.u8(), let max = reader.u8() else { return .unknown }
            var swings: UInt16?
            if fields & swingsBit != 0 { swings = reader.u16() }
            return .live(ZeppWorkoutLiveFrame(fields: fields, activeSeconds: active, heartRate: hr, kilocalories: kcal,
                                              averageHeartRate: avg, maximumHeartRate: max, swings: swings))
        default:
            return .unknown
        }
    }
}

// MARK: - The marker (decision 89f)

/// "OpenCircuit started a strap workout", persisted by the host (it must survive the process): set
/// before `02` goes out, cleared once the strap no longer holds that workout.
public struct ZeppWorkoutModeMarker: Codable, Equatable, Sendable {
    /// The start time sent in `03 01` (OpenCircuit's own start, Unix s).
    public var startTime: UInt32
    public var sportCode: UInt8
    /// OpenCircuit's active seconds as last recorded (heartbeat, pause, resume, end).
    public var activeSeconds: UInt32
    /// The pause state last SENT to the strap.
    public var strapPaused: Bool
    /// OpenCircuit's workout ended or was discarded: the strap is owed `03 02` + `03 04`.
    public var appEnded: Bool
    /// `02` went out but `03 01` (the only message carrying our start time) may not have reached the
    /// strap, so the strap may hold its own clock's start (89p a, c). Cleared only by an exact match.
    public var startUnconfirmed: Bool

    /// 89p (c): how far the strap's own start may sit from ours while the start is unconfirmed: its clock
    /// started the workout when our `02` arrived, and `02` can go out up to about 16 s after OpenCircuit's
    /// start (the `01` and `06 00` steps, 8 s each at worst), so inside +30 s the clock-skew tolerance is
    /// about 14 s (89r c).
    public static let unconfirmedStartWindow: ClosedRange<Int64> = -2...30

    public init(startTime: UInt32, sportCode: UInt8, activeSeconds: UInt32 = 0, strapPaused: Bool = false,
                appEnded: Bool = false, startUnconfirmed: Bool = false) {
        self.startTime = startTime
        self.sportCode = sportCode
        self.activeSeconds = activeSeconds
        self.strapPaused = strapPaused
        self.appEnded = appEnded
        self.startUnconfirmed = startUnconfirmed
    }

    private enum CodingKeys: String, CodingKey {
        case startTime, sportCode, activeSeconds, strapPaused, appEnded, startUnconfirmed
    }

    /// A marker persisted before the start-unconfirmed flag existed decodes with it off.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        startTime = try c.decode(UInt32.self, forKey: .startTime)
        sportCode = try c.decode(UInt8.self, forKey: .sportCode)
        activeSeconds = try c.decode(UInt32.self, forKey: .activeSeconds)
        strapPaused = try c.decode(Bool.self, forKey: .strapPaused)
        appEnded = try c.decode(Bool.self, forKey: .appEnded)
        startUnconfirmed = try c.decodeIfPresent(Bool.self, forKey: .startUnconfirmed) ?? false
    }

    /// 89p (c): the state reply describes THIS workout: running, our sport, and our start time, or,
    /// while the start is unconfirmed, a start within `unconfirmedStartWindow` of ours.
    public func isOurs(_ state: ZeppWorkoutState) -> Bool {
        guard case .running(let start, let sport) = state, sport == sportCode else { return false }
        if start == startTime { return true }
        guard startUnconfirmed else { return false }
        return Self.unconfirmedStartWindow.contains(Int64(start) - Int64(startTime))
    }

    /// 89p (b): this marker written over `persisted` of the same workout: an End already persisted
    /// stays, and the larger active seconds win. The pause state and the start-unconfirmed flag are
    /// this marker's (only the machine changes them). A persisted marker of another start is ignored.
    public func merged(over persisted: ZeppWorkoutModeMarker?) -> ZeppWorkoutModeMarker {
        guard let persisted, persisted.startTime == startTime else { return self }
        var out = self
        out.appEnded = appEnded || persisted.appEnded
        out.activeSeconds = max(activeSeconds, persisted.activeSeconds)
        return out
    }
}

// MARK: - The sequence

/// §18.9's sequence for one connection. Feed it every 0x0019 payload and tick it; send its messages
/// to 0x0019; persist the marker as its events say.
public struct ZeppWorkoutModeMachine: Equatable {

    public struct Configuration: Equatable {
        /// How long each reply may take: 8 s (§18.9's rule for the start reply, used for every step).
        public var replyTimeout: TimeInterval
        /// No `14` frame this long after `03 01`: the start is undone (89c).
        public var firstFrameTimeout: TimeInterval
        /// The `05` cadence (§18.9: about every 5 s).
        public var keepAliveInterval: TimeInterval

        public init(replyTimeout: TimeInterval = 8, firstFrameTimeout: TimeInterval = 15, keepAliveInterval: TimeInterval = 5) {
            self.replyTimeout = replyTimeout
            self.firstFrameTimeout = firstFrameTimeout
            self.keepAliveInterval = keepAliveInterval
        }
    }

    /// OpenCircuit's own workout as it is in this process right now (reconciliation, 89f).
    public struct Owner: Equatable, Sendable {
        public let startTime: UInt32
        public let activeSeconds: UInt32
        public let paused: Bool

        public init(startTime: UInt32, activeSeconds: UInt32, paused: Bool) {
            self.startTime = startTime
            self.activeSeconds = activeSeconds
            self.paused = paused
        }
    }

    public enum Step: String, Equatable, Sendable {
        case capability, state, start, started
    }

    /// Why the workout continues phone-side (89c). Control bytes and outcomes only, never values.
    public enum Fallback: Equatable, Sendable {
        /// No reply to the step within the reply timeout.
        case noReply(Step)
        /// The strap answered the step with another status.
        case refused(Step, status: UInt8)
        /// `06 00` didn't read idle (a workout of someone else's is running, or a state we can't place).
        case notIdle
        /// The start was accepted but no `14` frame came: ended at once (`03 02` + `03 04`, 89j).
        case noFrames
        /// The connection can't (no 0x0019, or another workout-mode exchange in progress).
        case unavailable
    }

    public enum Reconciliation: Equatable, Sendable {
        /// Ours, and OpenCircuit's workout is still running: carried on.
        case carriedOn
        /// Ours, and OpenCircuit's workout ended or was discarded: `03 02` + `03 04` sent.
        case endedForApp
        /// The strap is idle: the marker is cleared.
        case idle
        /// A workout that isn't ours is running: never touched; the marker is cleared.
        case foreign
        /// No usable reply: the marker stays for the next connection.
        case noReply
    }

    public enum Event: Equatable, Sendable {
        /// Persist this marker BEFORE sending the output's messages (it is set before `02`).
        case setMarker(ZeppWorkoutModeMarker)
        /// The pause state sent to the strap changed.
        case markStrapPaused(Bool)
        /// Clear the marker if it is still for this start time.
        case clearMarker(startTime: UInt32)
        /// The first `14` frame: the strap's workout mode is running.
        case running
        case unavailable(Fallback)
        case frame(ZeppWorkoutLiveFrame)
        /// The end's second `10 03 01`.
        case ended
        /// The end wasn't confirmed; the marker stays, so the next connection reconciles.
        case endUnconfirmed
        case reconciled(Reconciliation)
    }

    public struct Output: Equatable {
        /// Payloads for endpoint 0x0019, in order.
        public var messages: [[UInt8]] = []
        public var events: [Event] = []

        public init(messages: [[UInt8]] = [], events: [Event] = []) {
            self.messages = messages
            self.events = events
        }

        mutating func append(_ other: Output) {
            messages += other.messages
            events += other.events
        }
    }

    public enum Phase: Equatable {
        case idle
        case starting(Step, deadline: Date)
        /// `03 01` sent; waiting for the first `14` frame.
        case awaitingFrames(deadline: Date)
        case running
        /// The end went out; waiting for its replies.
        case ending(deadline: Date)
        /// Phone-side for the rest of this workout, on this connection.
        case fallback
        /// 89p (a): `02` went unanswered and `06 00` went out at once; its reply, a late `10 02 01` or
        /// a frame decides.
        case confirmingStart(deadline: Date)
        /// 89p (a): no usable answer to that `06 00`: phone-side, marker kept and flagged; a late
        /// `10 02 01` or a frame is still evidence that the strap runs ours.
        case startUnconfirmed
        /// `06 00` sent at connect for a persisted marker.
        case reconciling(deadline: Date)
        case done
    }

    public let configuration: Configuration
    public private(set) var phase: Phase = .idle
    /// The workout this connection drives (set at start or by a reconciliation that carried on).
    public private(set) var marker: ZeppWorkoutModeMarker?
    private var sport: ZeppWorkoutSport?
    private var owner: Owner?
    /// OpenCircuit's pause state while the start sequence runs; sent once `03 01` is out.
    private var appPaused = false
    private var appActiveSeconds: UInt32 = 0
    /// 89p (b): OpenCircuit's End, with its active seconds, once asked for in ANY phase. Sticky for the
    /// workout: every "running, ours" conclusion checks it (`pendingEnd`) before carrying on.
    private var endRequested: UInt32?

    /// The End to honour: the one asked for on this connection, or one the persisted marker carries.
    private var pendingEnd: UInt32? {
        if let endRequested { return endRequested }
        if let marker, marker.appEnded { return marker.activeSeconds }
        return nil
    }
    /// The `03 xx` commands awaiting their `10 03`, oldest first.
    private var pendingControls: [ZeppWorkoutCommand.Control] = []
    /// OpenCircuit's pause, resume and End asked for while `06 00` is in flight (89o a), in order,
    /// with the active seconds of each. Decided on when the reply arrives; never dropped.
    private enum Queued: Equatable {
        case pause(UInt32)
        case resume(UInt32)
        case end(UInt32)
    }
    private var queued: [Queued] = []
    /// 89r (a): a `06 00` reply during this start reported a running workout that isn't ours. From then
    /// on `14` frames may be that workout's, so they never prove our `02` started; only an accepted
    /// `10 02` (the strap's answer to OUR start request) does.
    private var foreignReadDuringStart = false
    private var keepAliveAt: Date?

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// The next time `tick(now:)` has something to do.
    public var nextDeadline: Date? {
        var deadlines: [Date] = []
        switch phase {
        case .starting(_, let deadline), .awaitingFrames(let deadline), .ending(let deadline),
             .reconciling(let deadline), .confirmingStart(let deadline):
            deadlines.append(deadline)
        case .idle, .running, .fallback, .startUnconfirmed, .done:
            break
        }
        if let keepAliveAt { deadlines.append(keepAliveAt) }
        return deadlines.min()
    }

    /// The strap's workout mode is starting or running for OpenCircuit on this connection.
    public var isActive: Bool {
        switch phase {
        case .starting, .awaitingFrames, .running, .confirmingStart, .startUnconfirmed: return true
        case .idle, .ending, .fallback, .reconciling, .done: return false
        }
    }

    // MARK: Inputs

    /// OpenCircuit's workout started: `01`, then `06 00` (89a). `startTime` is the start OpenCircuit
    /// records; the marker is set (with it) only once `06 00` reads idle, right before `02`.
    public mutating func start(_ sport: ZeppWorkoutSport, startTime: UInt32, now: Date) -> Output {
        switch phase {
        case .idle, .done, .fallback, .startUnconfirmed:
            // A previous workout's leftovers are settled by this start's own `06 00`.
            break
        case .starting, .awaitingFrames, .running, .ending, .reconciling, .confirmingStart:
            // Another exchange on 0x0019 is in progress (a previous end, or the connect's
            // reconciliation): this workout stays phone-side.
            return Output(events: [.unavailable(.unavailable)])
        }
        self.sport = sport
        marker = ZeppWorkoutModeMarker(startTime: startTime, sportCode: sport.code)
        appPaused = false
        appActiveSeconds = 0
        endRequested = nil
        foreignReadDuringStart = false
        pendingControls = []
        phase = .starting(.capability, deadline: now.addingTimeInterval(configuration.replyTimeout))
        return Output(messages: [ZeppWorkoutCommand.capabilityQuery])
    }

    /// OpenCircuit paused (`03 02` with its active seconds).
    public mutating func pause(activeSeconds: UInt32, now: Date) -> Output {
        setPaused(true, activeSeconds: activeSeconds)
    }

    /// OpenCircuit resumed (`03 03` with its active seconds).
    public mutating func resume(activeSeconds: UInt32, now: Date) -> Output {
        setPaused(false, activeSeconds: activeSeconds)
    }

    private mutating func setPaused(_ paused: Bool, activeSeconds: UInt32) -> Output {
        appPaused = paused
        appActiveSeconds = activeSeconds
        switch phase {
        case .awaitingFrames, .running:
            return sendPauseState(paused, activeSeconds: activeSeconds)
        case .reconciling:
            // 89o (a): kept for the reply, applied after a carry-on.
            queued.append(paused ? .pause(activeSeconds) : .resume(activeSeconds))
            return Output()
        default:
            // Before `03 01` it is sent once the start is confirmed; after a fallback, never.
            return Output()
        }
    }

    private mutating func sendPauseState(_ paused: Bool, activeSeconds: UInt32) -> Output {
        guard marker?.strapPaused != paused else { return Output() }
        marker?.strapPaused = paused
        let control: ZeppWorkoutCommand.Control = paused ? .pause : .resume
        pendingControls.append(control)
        return Output(messages: [ZeppWorkoutCommand.control(control, activeSeconds: activeSeconds)],
                      events: [.markStrapPaused(paused)])
    }

    /// OpenCircuit's workout ended (or was discarded): `03 02` then `03 04` with its final active
    /// seconds (89a, 89f). The marker stays until the second `10 03 01`.
    public mutating func end(activeSeconds: UInt32, now: Date) -> Output {
        appActiveSeconds = activeSeconds
        // 89p (b): kept whatever the phase, in the machine and in its marker (the host merges it, so a
        // persisted End is never overwritten).
        endRequested = activeSeconds
        if var mine = marker {
            mine.appEnded = true
            mine.activeSeconds = max(mine.activeSeconds, activeSeconds)
            marker = mine
        }
        switch phase {
        case .starting(.capability, _), .starting(.state, _), .starting(.started, _):
            // Nothing was started on the strap yet: stop here.
            phase = .done
            keepAliveAt = nil
            return Output()
        case .starting(.start, _), .confirmingStart, .startUnconfirmed:
            // `02` is out: the evidence that the strap runs ours (or the next connection) ends it.
            return Output()
        case .awaitingFrames, .running:
            return sendEnd(activeSeconds: activeSeconds, now: now)
        case .reconciling:
            // 89o (a): the reply decides; the End is kept for it.
            queued.append(.end(activeSeconds))
            return Output()
        case .idle, .ending, .fallback, .done:
            return Output()
        }
    }

    private mutating func sendEnd(activeSeconds: UInt32, now: Date) -> Output {
        keepAliveAt = nil
        pendingControls += [.pause, .end]
        phase = .ending(deadline: now.addingTimeInterval(configuration.replyTimeout))
        return Output(messages: ZeppWorkoutCommand.end(activeSeconds: activeSeconds))
    }

    /// At an authenticated connect with a persisted marker (89f): `06 00`, then carry on, end it for
    /// the app, or let go. `owner` is OpenCircuit's workout running in this process, if any.
    public mutating func reconcile(_ marker: ZeppWorkoutModeMarker, owner: Owner?, now: Date) -> Output {
        switch phase {
        case .idle, .done: break
        default: return Output()
        }
        if marker.startTime != self.marker?.startTime { endRequested = nil }
        self.marker = marker
        self.owner = owner
        pendingControls = []
        queued = []
        phase = .reconciling(deadline: now.addingTimeInterval(configuration.replyTimeout))
        return Output(messages: [ZeppWorkoutCommand.stateQuery])
    }

    /// 89o (a): the CURRENT persisted marker and owner, given by the host right before a 0x0019
    /// payload, so a `06 00` reply is decided on what is true when it arrives (an End, pause or resume
    /// recorded during the round trip), not on what was true when `06 00` went out. Only a marker of
    /// the same start time replaces the machine's copy.
    public mutating func noteCurrent(marker current: ZeppWorkoutModeMarker?, owner: Owner?) {
        switch phase {
        case .reconciling:
            if let current, current.startTime == marker?.startTime { marker = current }
            self.owner = owner
        case .starting(.start, _), .confirmingStart, .startUnconfirmed:
            // 89p (b): an End persisted by the recorder while this machine didn't hear it is honoured.
            if let current, let mine = marker, current.startTime == mine.startTime {
                marker = mine.merged(over: current)
            }
        default:
            break
        }
    }

    /// The link dropped: nothing more can be sent on this connection. The marker stays as persisted.
    public mutating func linkLost() {
        phase = .done
        keepAliveAt = nil
        pendingControls = []
    }

    /// One decoded 0x0019 payload.
    public mutating func receive(_ payload: [UInt8], now: Date) -> Output {
        if payload.first == 0x14 { return receiveFrame(payload, now: now) }
        guard let reply = ZeppWorkoutReply.parse(payload) else { return Output() }
        switch (phase, reply.opcode) {
        case (.starting(.capability, _), ZeppWorkoutCommand.capabilityOpcode):
            guard reply.isAccepted else { return fallBack(.refused(.capability, status: reply.status)) }
            phase = .starting(.state, deadline: now.addingTimeInterval(configuration.replyTimeout))
            return Output(messages: [ZeppWorkoutCommand.stateQuery])
        case (.starting(.state, _), ZeppWorkoutCommand.stateOpcode):
            guard ZeppWorkoutState.parse(payload) == .idle, let sport, let marker else {
                // 89f: a workout that isn't ours (or a state we can't place) is never touched, and
                // OpenCircuit doesn't start one of its own. No marker was set.
                self.marker = nil
                phase = .fallback
                return Output(events: [.unavailable(.notIdle)])
            }
            // 89q (a): persisted start-unconfirmed. Until the strap acks our `03 01` (or a `06 00` shows
            // our exact start), it may hold its own clock's start, so a link drop or a kill anywhere
            // in between leaves the next connection the [−2 s, +30 s] window (89p c).
            var flagged = marker
            flagged.startUnconfirmed = true
            self.marker = flagged
            phase = .starting(.start, deadline: now.addingTimeInterval(configuration.replyTimeout))
            return Output(messages: [sport.startRequest], events: [.setMarker(flagged)])
        case (.starting(.start, _), ZeppWorkoutCommand.startOpcode):
            guard reply.isAccepted, marker != nil else {
                // The strap said no: nothing is running for us.
                let start = self.marker?.startTime
                self.marker = nil
                phase = .fallback
                var out = Output(events: [.unavailable(.refused(.start, status: reply.status))])
                if let start { out.events.append(.clearMarker(startTime: start)) }
                return out
            }
            return adoptStart(now: now, frameArrived: false)
        case (.confirmingStart, ZeppWorkoutCommand.startOpcode), (.startUnconfirmed, ZeppWorkoutCommand.startOpcode):
            // 89p (a): a late `10 02 01` is the same "running, ours" evidence; a late refusal means
            // nothing of ours runs.
            guard reply.isAccepted else {
                let start = marker?.startTime
                marker = nil
                phase = .fallback
                var out = Output(events: [.unavailable(.refused(.start, status: reply.status))])
                if let start { out.events.append(.clearMarker(startTime: start)) }
                return out
            }
            return adoptStart(now: now, frameArrived: false)
        case (.confirmingStart, ZeppWorkoutCommand.stateOpcode), (.startUnconfirmed, ZeppWorkoutCommand.stateOpcode):
            // 89q (b): a late reply while the start is unconfirmed is decided like an on-time one.
            return startConfirmed(ZeppWorkoutState.parse(payload) ?? .unknown, now: now)
        case (.reconciling, ZeppWorkoutCommand.stateOpcode):
            return reconciled(ZeppWorkoutState.parse(payload) ?? .unknown, now: now)
        case (_, ZeppWorkoutCommand.controlOpcode):
            return receiveControlReply(reply, now: now)
        default:
            // A late or unasked reply changes nothing here (e.g. a `06 00` reply after the start was
            // already settled by a frame or a late `10 02 01`).
            return Output()
        }
    }

    /// 89p (a, b): evidence that the strap runs the workout OUR `02` started, before `03 01` went out
    /// (the `10 02 01`, on time or late, a `14` frame, or a `06 00` reply that is ours). `03 01` gives
    /// the strap our start time; then a stored End ends it at once, otherwise it goes on like any
    /// start (running if a frame came, else waiting for one, with the 15 s watchdog).
    private mutating func adoptStart(now: Date, frameArrived: Bool) -> Output {
        guard let marker else { return Output() }
        pendingControls.append(.started)
        var out = Output(messages: [ZeppWorkoutCommand.started(startTime: marker.startTime)])
        if let ending = pendingEnd {
            out.append(sendEnd(activeSeconds: ending, now: now))
            return out
        }
        keepAliveAt = now.addingTimeInterval(configuration.keepAliveInterval)
        if frameArrived {
            phase = .running
            out.events.append(.running)
        } else {
            phase = .awaitingFrames(deadline: now.addingTimeInterval(configuration.firstFrameTimeout))
        }
        if appPaused { out.append(sendPauseState(true, activeSeconds: appActiveSeconds)) }
        return out
    }

    /// 89p (a): the reply to the `06 00` sent at the start timeout.
    private mutating func startConfirmed(_ state: ZeppWorkoutState, now: Date) -> Output {
        guard var marker else { phase = .done; return Output() }
        switch state {
        case .running(let start, _) where marker.isOurs(state):
            var out = Output()
            if start == marker.startTime, marker.startUnconfirmed {
                marker.startUnconfirmed = false
                self.marker = marker
                out.events.append(.setMarker(marker))
            }
            out.append(adoptStart(now: now, frameArrived: false))
            return out
        case .idle:
            // Our `02` started nothing.
            phase = .fallback
            self.marker = nil
            return Output(events: [.unavailable(.noReply(.start)), .clearMarker(startTime: marker.startTime)])
        case .running:
            // Not ours: never touched. The marker stays (flagged) for the next connection's `06 00`,
            // and a late accepted `10 02` still proves our `02` started (89q c). Frames no longer do
            // (89r a): they may be this other workout's.
            foreignReadDuringStart = true
            phase = .startUnconfirmed
            return Output(events: [.unavailable(.notIdle)])
        case .unknown:
            phase = .startUnconfirmed
            return Output(events: [.unavailable(.noReply(.start))])
        }
    }

    private mutating func receiveControlReply(_ reply: ZeppWorkoutReply, now: Date) -> Output {
        guard !pendingControls.isEmpty else { return Output() }
        let control = pendingControls.removeFirst()
        if control == .started, reply.isAccepted, var marker, marker.startUnconfirmed {
            // 89q (a): the strap holds our start time now: the flag goes, persisted.
            marker.startUnconfirmed = false
            self.marker = marker
            return Output(events: [.setMarker(marker)])
        }
        guard case .ending = phase, control == .end else { return Output() }
        guard reply.isAccepted else {
            phase = .done
            return Output(events: [.endUnconfirmed])
        }
        phase = .done
        var out = Output(events: [.ended])
        if let start = marker?.startTime { out.events.append(.clearMarker(startTime: start)) }
        return out
    }

    private mutating func receiveFrame(_ payload: [UInt8], now: Date) -> Output {
        var out = Output()
        switch phase {
        case .awaitingFrames:
            phase = .running
            out.events.append(.running)
        case .starting(.start, _), .confirmingStart, .startUnconfirmed:
            // 89p (a): a frame after our `02` (the strap read idle just before it) is the strap
            // running ours, whatever happened to the `10 02 01`. 89r (a): unless a `06 00` already
            // reported another workout running: then the frame may be that one's, and proves nothing.
            guard !foreignReadDuringStart else { return out }
            out = adoptStart(now: now, frameArrived: true)
            guard phase == .running else { return out }
        case .running:
            break
        default:
            // Not a workout this connection drives: never forwarded.
            return out
        }
        if case .live(let frame)? = ZeppWorkoutFrame.parse(payload) { out.events.append(.frame(frame)) }
        return out
    }

    private mutating func reconciled(_ state: ZeppWorkoutState, now: Date) -> Output {
        let queued = self.queued
        self.queued = []
        guard let marker else { phase = .done; return Output() }
        // 89o (a): an End during the round trip counts as the app's End, with its seconds.
        let queuedEnd = queued.compactMap { item -> UInt32? in if case .end(let s) = item { return s }; return nil }.last
        let appEnded = marker.appEnded || queuedEnd != nil || endRequested != nil
        switch state {
        case .idle:
            phase = .done
            self.marker = nil
            return Output(events: [.reconciled(.idle), .clearMarker(startTime: marker.startTime)])
        case .running(let start, _) where marker.isOurs(state):
            var marker = marker
            var confirmed = Output()
            if start == marker.startTime, marker.startUnconfirmed {
                // 89p (b): only an exact match clears the flag.
                marker.startUnconfirmed = false
                self.marker = marker
                confirmed.events.append(.setMarker(marker))
            }
            if let owner, owner.startTime == marker.startTime, !appEnded {
                // 89f: OpenCircuit's workout is still running: carry on, keep-alive re-armed, the pause
                // and resume asked for during the round trip applied in order (89o a), then the
                // strap's pause state brought to the app's.
                phase = .running
                keepAliveAt = now.addingTimeInterval(configuration.keepAliveInterval)
                appPaused = owner.paused
                appActiveSeconds = owner.activeSeconds
                var out = confirmed
                out.events.append(.reconciled(.carriedOn))
                for item in queued {
                    switch item {
                    case .pause(let seconds): out.append(sendPauseState(true, activeSeconds: seconds))
                    case .resume(let seconds): out.append(sendPauseState(false, activeSeconds: seconds))
                    case .end: break
                    }
                }
                out.append(sendPauseState(owner.paused, activeSeconds: owner.activeSeconds))
                return out
            }
            // Ended or discarded, before or during the query (or the process that ran it is gone): end
            // it with the seconds OpenCircuit recorded.
            var out = confirmed
            out.events.append(.reconciled(.endedForApp))
            out.append(sendEnd(activeSeconds: queuedEnd ?? endRequested ?? marker.activeSeconds, now: now))
            return out
        case .running:
            // 89f: someone else's workout. Never touched; ours is no longer on the strap.
            phase = .done
            self.marker = nil
            return Output(events: [.reconciled(.foreign), .clearMarker(startTime: marker.startTime)])
        case .unknown:
            phase = .done
            return Output(events: [.reconciled(.noReply)])
        }
    }

    /// Call at (or after) `nextDeadline`.
    public mutating func tick(now: Date) -> Output {
        var out = Output()
        switch phase {
        case .starting(let step, let deadline) where now >= deadline:
            if step == .start {
                // 89p (a): `02` went out unanswered. No limbo: ask the strap at once. The marker is
                // flagged start-unconfirmed (and persisted) before the question goes out.
                phase = .confirmingStart(deadline: now.addingTimeInterval(configuration.replyTimeout))
                keepAliveAt = nil
                if var marker {
                    marker.startUnconfirmed = true
                    self.marker = marker
                    out.events.append(.setMarker(marker))
                }
                out.messages.append(ZeppWorkoutCommand.stateQuery)
            } else {
                out.append(fallBack(.noReply(step)))
            }
        case .awaitingFrames(let deadline) where now >= deadline:
            // 89c, 89j: accepted, but no frame: end it now (`03 02` + `03 04`), at about 15 s, under the
            // length the strap or Zepp keeps, so no empty workout is expected in Zepp.
            out.events.append(.unavailable(.noFrames))
            out.append(sendEnd(activeSeconds: appActiveSeconds, now: now))
        case .ending(let deadline) where now >= deadline:
            phase = .done
            out.events.append(.endUnconfirmed)
        case .reconciling(let deadline) where now >= deadline:
            phase = .done
            queued = []
            out.events.append(.reconciled(.noReply))
        case .confirmingStart(let deadline) where now >= deadline:
            // 89p (a): no answer: phone-side; the flagged marker waits for the next connection.
            phase = .startUnconfirmed
            out.events.append(.unavailable(.noReply(.start)))
        default:
            break
        }
        if let next = keepAliveAt, now >= next {
            switch phase {
            case .awaitingFrames, .running:
                keepAliveAt = now.addingTimeInterval(configuration.keepAliveInterval)
                out.messages.append(ZeppWorkoutCommand.keepAlive)
            default:
                keepAliveAt = nil
            }
        }
        return out
    }

    /// The active seconds OpenCircuit last recorded, used by an end the machine sends on its own
    /// (89c's no-frames end).
    public mutating func noteActiveSeconds(_ seconds: UInt32) {
        appActiveSeconds = seconds
    }

    /// A failure before `02` went out: nothing was started, no marker was set.
    private mutating func fallBack(_ reason: Fallback) -> Output {
        phase = .fallback
        marker = nil
        keepAliveAt = nil
        return Output(events: [.unavailable(reason)])
    }
}

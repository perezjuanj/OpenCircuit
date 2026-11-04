// HelioVerify's workout-mode test (#358): starts the strap's own workout from the Mac, prints the
// strap's 1/s workout frames next to the standard 0x2A37 live HR, then ends it.
//
// Endpoint 0x0019 messages, from the route-2 capture of Zepp 10.10.5 talking to our strap
// (2026-11-03, fw 3.25.0.3). Little-endian; every strap reply starts `10 <opcode> <status>`:
//   01                                         capability query   -> 10 01 01 …
//   06 00                                      state query        -> 10 06 01 00 00 (idle)
//   02 <sport> …                               start request      -> 10 02 01
//   03 01 06 00 00 00 <u32 unix start> 00×4    started            -> 10 03 01
//   03 02 04 00 00 00 <u32 active s>           pause              -> 10 03 01
//   03 03 04 00 00 00 <u32 active s>           resume             -> 10 03 01
//   03 04 04 00 00 00 <u32 active s>           end, workout saved (after a pause)
//   03 05 04 00 00 00 <u32 active s>           end, not saved (after a pause; meaning inferred)
//   05                                         keep-alive, every 5 s
// Strap -> phone while running, 1/s:
//   14 00 24 01 00 0e <u32 active s> <u8 HR> <u32 kcal> <u8 avg HR> <u8 max HR> <u16 swings>
//
// Safety: a running workout is always ended on the way out (finish(), Ctrl-C, SIGTERM, SIGHUP,
// timeout), like the find stop. The start time is saved to a file so `--workout-end-only` can end
// a workout a crashed run left behind.

import Foundation
import ZeppKit

enum WorkoutEnd: String { case save, discard }

struct WorkoutTestState {
    enum Phase { case idle, querying, checkingState, starting, confirming, running, ending, ended }
    var phase = Phase.idle
    var startedAt: Date?
    var lastActiveSeconds: UInt32 = 0
    var lastStandardHR: Int?
    var lastStandardHRAt: Date?
    var keepAliveTimer: DispatchSourceTimer?
    var endTimer: DispatchSourceTimer?
    var hrKeepAlive: DispatchSourceTimer?
    var framesSeen = 0
    var running: Bool { phase == .running || phase == .confirming || phase == .ending }
}

let workoutEndpoint: UInt16 = 0x0019
/// Pickleball, byte for byte as Zepp sent it (sport 0xe3 plus its racket-sport option bytes).
let pickleballStart: [UInt8] = [0x02, 0xe3, 0x00, 0x01, 0x01, 0x02, 0x00, 0x00, 0x00, 0x02]
let workoutStateFile = "/Users/aiprison/workspace/helio-captures/route2/workout-running.json"

func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 24 & 0xff)] }
func readLE32(_ b: [UInt8], _ at: Int) -> UInt32 {
    UInt32(b[at]) | UInt32(b[at + 1]) << 8 | UInt32(b[at + 2]) << 16 | UInt32(b[at + 3]) << 24
}

@available(macOS 10.15.4, *)
extension HelioVerifier {

    func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }

    func stamp() -> String {
        guard let s = workout.startedAt else { return "pre  " }
        return String(format: "+%3ds", Int(Date().timeIntervalSince(s)))
    }

    // MARK: Entry

    func startWorkoutTest() {
        step = .controls
        guard services?.contains(workoutEndpoint) == true else {
            return finish("workout: endpoint 0x0019 not in the services list", code: 3)
        }
        if options.workoutEndOnly { return startEndOnly() }
        if options.workoutStatus {
            workout.phase = .checkingState
            log("workout: state query (06 00), read-only")
            send(workoutEndpoint, [0x06, 0x00])
            return workoutTimeout(8, "no reply to the state query")
        }
        // Standard live HR first, so the baseline and the comparison use the same stream.
        if services?.contains(ZeppEndpoint.heartRate) == true, let c = characteristics[.heartRateMeasurement] {
            peripheral?.setNotifyValue(true, for: c)
            send(ZeppEndpoint.heartRate, ZeppHeartRateControl.start)
            workout.hrKeepAlive = mainTimer(every: 1, after: 1) { [weak self] in
                self?.send(ZeppEndpoint.heartRate, ZeppHeartRateControl.keepRunning)
            }
            log("workout: standard live HR (0x2A37) started; \(Int(options.workoutBaseline)) s baseline before the workout")
        } else {
            log("workout: 0x2A37 / 0x001D not available; no side-by-side comparison")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + options.workoutBaseline) { [weak self] in
            guard let self, !self.isFinishing else { return }
            self.workout.phase = .querying
            self.log("workout: capability query (01)")
            self.send(workoutEndpoint, [0x01])
            self.workoutTimeout(8, "no reply to the capability query")
        }
    }

    func workoutTimeout(_ seconds: Double, _ what: String) {
        let phase = workout.phase
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, !self.isFinishing, self.workout.phase == phase else { return }
            self.finish("workout: \(what) in \(Int(seconds)) s", code: 3)
        }
    }

    // MARK: Strap messages on 0x0019

    func receiveWorkout(_ p: [UInt8]) {
        if p.first == 0x14 { return receiveWorkoutFrame(p) }
        log("  0x0019 <- \(hex(p))")
        guard p.count >= 3, p[0] == 0x10 else { return }
        let op = p[1], ok = p[2] == 0x01
        switch (workout.phase, op) {
        case (.querying, 0x01):
            workout.phase = .checkingState
            send(workoutEndpoint, [0x06, 0x00])
            workoutTimeout(8, "no reply to the state query")
        case (.checkingState, 0x06) where options.workoutStatus:
            let idle = ok && p.count >= 5 && p[3] == 0 && p[4] == 0
            step = .done
            finish(idle ? "done: strap workout state idle (\(hex(p)))" : "strap workout state NOT idle: \(hex(p))", code: idle ? 0 : 3)
        case (.checkingState, 0x06):
            guard ok, p.count >= 5, p[3] == 0, p[4] == 0 else {
                return finish("workout: the strap does not report idle (\(hex(p))); a workout may already be running, so nothing was started", code: 3)
            }
            if options.workoutEndOnly { return sendEnd(reason: "end-only run") }
            workout.phase = .starting
            let start = options.workoutStartBytes ?? pickleballStart
            log("workout: start request \(hex(start))")
            send(workoutEndpoint, start)
            workoutTimeout(8, "no reply to the start request")
        case (.starting, 0x02):
            guard ok else { return finish("workout: start refused (\(hex(p)))", code: 3) }
            let now = Date()
            workout.startedAt = now
            workout.phase = .confirming
            saveRunningState(now)
            let ts = UInt32(now.timeIntervalSince1970)
            send(workoutEndpoint, [0x03, 0x01] + le32(6) + le32(ts) + [0x00, 0x00, 0x00, 0x00])
            workout.keepAliveTimer = mainTimer(every: 5, after: 5) { [weak self] in
                self?.send(workoutEndpoint, [0x05])
            }
            workoutTimeout(8, "no reply to 'started'")
        case (.confirming, 0x03):
            guard ok else { return finish("workout: 'started' refused (\(hex(p)))", code: 3) }
            workout.phase = .running
            log("workout: RUNNING for \(Int(options.workoutSeconds ?? 0)) s. Move now.")
            log("        time   std 0x2A37 | strap: HR   avg  max  kcal swings active")
            workout.endTimer = mainTimer(every: nil, after: options.workoutSeconds ?? 60) { [weak self] in
                self?.sendEnd(reason: "test time up")
            }
        case (.ending, 0x03):
            if workout.phase == .ending, endStage == 1 {
                endStage = 2
                let end: UInt8 = options.workoutEnd == .save ? 0x04 : 0x05
                send(workoutEndpoint, [0x03, end] + le32(4) + le32(workout.lastActiveSeconds))
                log("workout: end (03 \(String(format: "%02x", end)), \(options.workoutEnd.rawValue))")
            } else if endStage == 2 {
                workout.phase = .ended
                clearRunningState()
                log("workout: ended; checking the strap is idle again")
                send(workoutEndpoint, [0x06, 0x00])
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    self?.wrapUpWorkout()
                }
            }
        case (.ended, 0x06):
            log("workout: state after end \(p.count >= 5 && p[3] == 0 && p[4] == 0 ? "idle" : hex(p))")
        default:
            break
        }
    }

    /// `14 00 24 01 00 <fields>` live frames. Seen: fields `0e` (pickleball, 19 B, with u16 swings)
    /// and `06` (strength, 17 B, no swings), so bit `0x08` of byte 5 = swings present.
    func receiveWorkoutFrame(_ p: [UInt8]) {
        workout.framesSeen += 1
        if workout.framesSeen == 5 {
            log("workout: state query while running (06 00)")
            send(workoutEndpoint, [0x06, 0x00])
        }
        guard p.count >= 17, p[2] == 0x24 else { return log("  0x0019 <- \(hex(p))") }
        let active = readLE32(p, 6)
        workout.lastActiveSeconds = active
        let hr = p[10], kcal = readLE32(p, 11), avg = p[15], mx = p[16]
        let hasSwings = p[5] & 0x08 != 0 && p.count >= 19
        let swings = hasSwings ? UInt16(p[17]) | UInt16(p[18]) << 8 : 0
        if p.count != (hasSwings ? 19 : 17) { log("  0x0019 <- \(hex(p)) (unexpected length for fields \(String(format: "%02x", p[5])))") }
        var std = "   --"
        if let s = workout.lastStandardHR, let at = workout.lastStandardHRAt, Date().timeIntervalSince(at) < 3 {
            std = String(format: "%5d", s)
        }
        log("  \(stamp())   \(std)      |       \(String(format: "%3d  %3d  %3d  %4d  %5d  %5d", hr, avg, mx, kcal, swings, active))")
    }

    /// Called for every 0x2A37 notification while the workout test runs.
    func noteStandardHR(_ bpm: Int) {
        workout.lastStandardHR = bpm
        workout.lastStandardHRAt = Date()
        if !workout.running { log("  \(stamp())   \(String(format: "%5d", bpm))      | (no workout yet)") }
    }

    // MARK: Ending

    func sendEnd(reason: String) {
        guard workout.phase == .running || workout.phase == .confirming || options.workoutEndOnly else { return }
        workout.endTimer?.cancel()
        workout.phase = .ending
        endStage = 1
        log("workout: \(reason); pause (03 02) at \(workout.lastActiveSeconds) s active")
        send(workoutEndpoint, [0x03, 0x02] + le32(4) + le32(workout.lastActiveSeconds))
        workoutTimeout(8, "no reply while ending (run --workout-end-only to retry)")
    }

    func wrapUpWorkout() {
        workout.keepAliveTimer?.cancel()
        workout.hrKeepAlive?.cancel()
        send(ZeppEndpoint.heartRate, ZeppHeartRateControl.stop)
        if let c = characteristics[.heartRateMeasurement] { peripheral?.setNotifyValue(false, for: c) }
        step = .done
        finish("done: workout test finished (\(workout.framesSeen) strap workout frame(s))")
    }

    /// For finish(): a workout this run started must never be left running. Returns true when an
    /// end was sent (the caller waits a moment before disconnecting).
    func endWorkoutBeforeExit() -> Bool {
        guard workout.running, workout.phase != .ended else { return false }
        let end: UInt8 = options.workoutEnd == .save ? 0x04 : 0x05
        send(workoutEndpoint, [0x03, 0x02] + le32(4) + le32(workout.lastActiveSeconds))
        send(workoutEndpoint, [0x03, end] + le32(4) + le32(workout.lastActiveSeconds))
        send(ZeppEndpoint.heartRate, ZeppHeartRateControl.stop)
        log("workout: ended on exit (pause + 03 \(String(format: "%02x", end)))")
        workout.phase = .ended
        clearRunningState()
        return true
    }

    // MARK: End-only recovery

    func startEndOnly() {
        guard let data = FileManager.default.contents(atPath: workoutStateFile),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let start = obj["start"] as? Double else {
            return finish("workout: no saved workout start (\(workoutStateFile)); nothing to end", code: 3)
        }
        workout.startedAt = Date(timeIntervalSince1970: start)
        workout.lastActiveSeconds = UInt32(max(0, Date().timeIntervalSince1970 - start))
        workout.phase = .running
        log("workout: ending the workout a previous run started at \(Date(timeIntervalSince1970: start))")
        sendEnd(reason: "end-only run")
    }

    func saveRunningState(_ start: Date) {
        let obj: [String: Any] = ["start": start.timeIntervalSince1970]
        if let data = try? JSONSerialization.data(withJSONObject: obj) {
            FileManager.default.createFile(atPath: workoutStateFile, contents: data)
        }
    }

    func clearRunningState() { try? FileManager.default.removeItem(atPath: workoutStateFile) }
}

// Manual nap edit / add — RingConn parity (#176 → nap parity).
//
// RingConn's SleepNapModel carries an `isEdited` flag: the user can adjust an auto-detected nap's
// window or add one the ring missed. This is the pure, testable rule for a valid nap window — a
// daytime block of a sensible length that doesn't overlap the main night or another nap. The
// persistence (a separate overlay so re-detection can't clobber a manual nap) lives in the store.

import Foundation

public enum NapEdit {
    /// Shortest block that counts as a nap — the same 15 min the auto-detector + RingConn use.
    public static let minDuration: TimeInterval = NapDetection.minNapDuration
    /// A "nap" longer than this is a night, not a nap — reject it (the auto-detector's daytime gate
    /// keeps a real long sleep out; this bounds a MANUAL add so the user can't log a 10 h "nap").
    public static let maxDuration: TimeInterval = 6 * 3600

    public struct Window: Equatable, Sendable {
        public var start: Date
        public var end: Date
        public init(start: Date, end: Date) { self.start = start; self.end = end }
        public var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
    }

    public enum Invalid: Error, Equatable, Sendable {
        case endNotAfterStart
        case tooShort(minMinutes: Int)
        case tooLong(maxHours: Int)
        case notDaytime
        case inFuture
        case overlapsNight
        case overlapsNap
    }

    /// Validate a proposed nap window (edit or add). `night` is the main in-bed window to stay clear
    /// of (nil when unknown); `otherNaps` are the OTHER naps' windows (exclude the one being edited);
    /// `now` (when supplied) rejects a future-dated window. Returns nil when the window is a valid,
    /// non-overlapping DAYTIME nap. The daytime gate mirrors NapDetection's own overnight-block
    /// rejection, so the manual path can't log a nap in the middle of the night.
    public static func validate(_ w: Window, night: DateInterval? = nil,
                                otherNaps: [DateInterval] = [], now: Date? = nil) -> Invalid? {
        if w.end <= w.start { return .endNotAfterStart }
        if w.duration < minDuration { return .tooShort(minMinutes: Int(minDuration / 60)) }
        if w.duration > maxDuration { return .tooLong(maxHours: Int(maxDuration / 3600)) }
        if let now, w.end > now { return .inFuture }
        // Overlaps are the more actionable error near the night boundary, so check them BEFORE the
        // daytime gate (a nap that overlaps the night reports "overlaps your sleep", not "not daytime").
        if let n = night, w.start < n.end && w.end > n.start { return .overlapsNight }
        for o in otherNaps where w.start < o.end && w.end > o.start { return .overlapsNap }
        if SleepWindow.isOvernightBlock(start: w.start, end: w.end) { return .notDaytime }
        return nil
    }

    public static func isValid(_ w: Window, night: DateInterval? = nil,
                               otherNaps: [DateInterval] = [], now: Date? = nil) -> Bool {
        validate(w, night: night, otherNaps: otherNaps, now: now) == nil
    }
}

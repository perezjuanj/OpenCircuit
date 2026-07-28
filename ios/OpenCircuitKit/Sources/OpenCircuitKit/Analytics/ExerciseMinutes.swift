// Estimate Apple Exercise Time (elevated-HR minutes) from stored HR samples (#82).
//
// SCOPE — BASIC ESTIMATE ONLY.
// A basic threshold model: minutes where HR ≥ 50% of max HR (equivalent to brisk
// walking, Apple's own exercise definition). This estimate uses ONLY the decoded
// HR samples we have — sleep-window bulk epochs (0x4c[4], 🟢) and live monitoring
// readings — and EXCLUDES the overnight sleep window to avoid counting sleeping
// elevated HR as voluntary exercise.
//
// ⚠️ The FULL 4-level intensity mapping (Vigorous/Moderate/Low/Inactive minutes) is
// GATED on the *separate, still-uncaptured* 历史活动响应 activity record (#93,
// PROTOCOL.md §5.3.1) — NOT on 0x4c[15:22], which is just the tail of the
// already-decoded `acti_counts` intensity blob on the MEASUREMENT record we already
// have (a same-record "is it moving" signal, not 4 calibrated bands). Do not invent
// 4 intensity buckets from the basic HR threshold alone. This file is the
// basic-threshold placeholder until that capture (sync-open `byte[6]=0x02`, see
// `RingSession.probeActivityChannels`) lands and the bands can be calibrated against
// the app's own per-day readout.
//
// HealthKit target: `.appleExerciseTime` (written by HealthKitWriter as a delta,
// not stored as a ring sample in LocalStore).

import Foundation

public enum ExerciseMinutes {

    /// HR threshold for exercise: ≥ 50% of max HR (brisk-walking equivalent).
    /// NOTE: Full 4-level intensity (Vigorous/Moderate/Low/Inactive) follows the #93
    /// activity-record capture (PROTOCOL.md §5.3.1), not the current measurement record.
    public static func threshold(maxHR: Int) -> Int {
        return max(Int(Double(max(maxHR, 1)) * 0.5), 60)
    }

    /// Estimate exercise minutes as the total merged duration of elevated-HR intervals,
    /// excluding samples that fall inside a sleep window.
    ///
    /// Algorithm:
    /// 1. Filter to samples with HR ≥ threshold and outside the sleep window.
    /// 2. Map each sample to an interval. Samples with a real span (end > start) use it
    ///    directly. POINT samples (start == end) are ambiguous on the wire: a 0x4c bulk
    ///    sleep-vitals epoch genuinely spans `epochSeconds`, but a live-HR spot read
    ///    (RingSession persists these as point samples too) represents only an instant.
    ///    To keep the bulk-epoch behavior without letting one isolated non-exercise spot
    ///    read inflate the Apple Exercise ring by a full 2.5 min, a point sample gets the
    ///    full `epochSeconds` width ONLY when it is part of a run of ≥2 consecutive
    ///    elevated readings spaced within one epoch (back-to-back bulk epochs / sustained
    ///    elevated HR). An ISOLATED elevated point read gets only `pointSampleWidth`
    ///    (default 0 — a single spot read is not evidence of voluntary exercise).
    /// 3. Merge overlapping intervals so consecutive elevated epochs are counted once.
    /// 4. Return the sum of merged interval durations in minutes.
    ///
    /// ESTIMATE — based on available HR samples only. Accuracy improves after #93 decode.
    ///
    /// Defined as the total duration of `elevatedPieces` so the scalar the Apple Exercise ring
    /// writes and the per-piece slices the energy estimate prices can never drift apart. See
    /// `elevatedPieces` for the algorithm; this contract is unchanged.
    public static func estimate(
        hrSamples: [HRSample],
        maxHR: Int,
        sleepWindow: DateInterval? = nil,
        epochSeconds: TimeInterval = TimeInterval(BulkRecord.epochSeconds),
        pointSampleWidth: TimeInterval = 0
    ) -> Double {
        let seconds = elevatedPieces(hrSamples: hrSamples,
                                     maxHR: maxHR,
                                     sleepWindow: sleepWindow,
                                     epochSeconds: epochSeconds,
                                     pointSampleWidth: pointSampleWidth)
            .reduce(0.0) { $0 + $1.seconds }
        return seconds / 60.0
    }

    /// One disjoint slice of elevated-HR time, carrying the bpm that priced it.
    ///
    /// `estimate` collapses the day to a single duration, which forces any energy model built on
    /// it to price the whole day at ONE average HR. That average is what froze active energy for
    /// the rest of the day once the last bout ended, and what let an isolated spot read dilute a
    /// morning workout's price (tester, 2026-07-28). Pieces keep the time structure so each slice
    /// can be priced — and placed — on its own.
    public struct ElevatedPiece: Equatable, Sendable {
        public let start: Date
        public let end: Date
        public let bpm: Int

        public init(start: Date, end: Date, bpm: Int) {
            self.start = start
            self.end = end
            self.bpm = bpm
        }

        public var seconds: TimeInterval { Swift.max(0, end.timeIntervalSince(start)) }
    }

    /// The same elevated intervals `estimate` sums, emitted as NON-OVERLAPPING, chronologically
    /// ordered slices that each carry their own bpm. Filtering, point-sample widening and overlap
    /// collapse are identical to `estimate` — which is now defined in terms of this — so the two
    /// can never disagree about how much elevated time a day contains.
    ///
    /// Overlap rule: where two elevated samples cover the same instant, the EARLIER one keeps it
    /// (the later slice starts where the earlier ends). Total duration is therefore exactly the
    /// merged-union duration, and a live spot read landing inside a bulk epoch cannot add time.
    public static func elevatedPieces(
        hrSamples: [HRSample],
        maxHR: Int,
        sleepWindow: DateInterval? = nil,
        epochSeconds: TimeInterval = TimeInterval(BulkRecord.epochSeconds),
        pointSampleWidth: TimeInterval = 0
    ) -> [ElevatedPiece] {
        let thresh = threshold(maxHR: maxHR)
        let elevated = hrSamples
            .filter { s in
                s.bpm >= thresh
                    && (sleepWindow.map { !$0.contains(s.start) } ?? true)
            }
            .sorted { $0.start < $1.start }

        guard !elevated.isEmpty else { return [] }

        // Build intervals. Real-span samples use their own duration. A point sample gets a
        // full epoch only when it neighbours another elevated reading within one epoch
        // (a sustained run); an isolated point read gets only `pointSampleWidth`.
        let intervals: [(start: Date, end: Date, bpm: Int)] = elevated.enumerated().map { idx, s in
            let dur = s.end.timeIntervalSince(s.start)
            if dur > 0 { return (s.start, s.end, s.bpm) }
            let prevClose = idx > 0
                && s.start.timeIntervalSince(elevated[idx - 1].start) <= epochSeconds
            let nextClose = idx < elevated.count - 1
                && elevated[idx + 1].start.timeIntervalSince(s.start) <= epochSeconds
            let width = (prevClose || nextClose) ? epochSeconds : pointSampleWidth
            return (s.start, s.start.addingTimeInterval(width), s.bpm)
        }

        // Collapse overlaps by sweeping a cursor instead of merging into maximal runs: each
        // interval contributes only the part not already covered. The emitted slices therefore
        // tile exactly the same union the old merge produced (same total duration), but keep the
        // per-slice bpm the merge threw away.
        var pieces: [ElevatedPiece] = []
        var cursor: Date?
        for interval in intervals {
            let start = cursor.map { Swift.max(interval.start, $0) } ?? interval.start
            guard interval.end > start else { continue }  // fully covered, or zero-width
            pieces.append(ElevatedPiece(start: start, end: interval.end, bpm: interval.bpm))
            cursor = interval.end
        }
        return pieces
    }
}

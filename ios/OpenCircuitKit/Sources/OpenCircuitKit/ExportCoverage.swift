// Sampling-coverage measurement for the rich export (schema v3).
//
// WHAT THIS IS: a statement about the data WE HOLD over a window — "we have 312 of the 336
// epochs this window could contain, and the biggest hole is 47 minutes". It is NOT an estimate
// of what the ring recorded: the ring's own backlog is not observable from stored rows, and a
// missing stretch can equally mean the ring wasn't worn, wasn't drained yet, or the epochs were
// lost. Reporting it as a MEASUREMENT of our own holdings is the only honest framing, which is
// why `coverageFraction` is clamped and can never exceed 1.0 — a number above 1 would be
// claiming knowledge of a denominator we don't have.
//
// The default cadence is the ring's own 150 s epoch step (`BulkRecord.epochSeconds`, 🟢
// PROTOCOL.md §5.3), so "expected" counts epochs, not wall-clock guesses.

import Foundation

public enum ExportCoverage {

    /// A stretch of the window with no stored sample.
    public struct Gap: Equatable, Sendable {
        public let start: Date
        public let end: Date
        public init(start: Date, end: Date) {
            self.start = start; self.end = end
        }
        public var seconds: Double { end.timeIntervalSince(start) }
    }

    /// What we hold over `[windowStart, windowEnd]`.
    public struct Assessment: Equatable, Sendable {
        public let windowStart: Date
        public let windowEnd: Date
        /// `floor(window / cadence)`, never negative. 0 for a degenerate window.
        public let expectedSamples: Int
        /// Distinct in-window sample instants. Duplicates count once — two rows at the same
        /// instant cover the same epoch, and counting both would inflate coverage.
        public let observedSamples: Int
        /// `observed / expected`, clamped to 0…1; 0 when `expectedSamples == 0`.
        public let coverageFraction: Double
        /// Ascending, only holes STRICTLY longer than `minGap`.
        public let gaps: [Gap]
        /// Widest reported gap, 0 when there are none.
        public let longestGapSeconds: Double

        public init(windowStart: Date, windowEnd: Date, expectedSamples: Int,
                    observedSamples: Int, coverageFraction: Double,
                    gaps: [Gap], longestGapSeconds: Double) {
            self.windowStart = windowStart
            self.windowEnd = windowEnd
            self.expectedSamples = expectedSamples
            self.observedSamples = observedSamples
            self.coverageFraction = coverageFraction
            self.gaps = gaps
            self.longestGapSeconds = longestGapSeconds
        }
    }

    /// Measure coverage of `[from, to]` by `sampleTimes`.
    ///
    /// Tolerates unsorted input, duplicate timestamps, samples outside the window (ignored),
    /// an empty array, and `from > to` (degenerate — nothing is expected and nothing is a gap;
    /// reporting a gap for an inverted window would be inventing a hole).
    ///
    /// `minGap` defaults to two epochs: a single missed epoch is ordinary jitter in a drained
    /// stream, so flagging it would bury the real holes in noise.
    public static func assess(sampleTimes: [Date], from: Date, to: Date,
                              cadence: TimeInterval = TimeInterval(BulkRecord.epochSeconds),
                              minGap: TimeInterval = 2 * TimeInterval(BulkRecord.epochSeconds))
        -> Assessment {

        let span = to.timeIntervalSince(from)
        guard span > 0, cadence > 0 else {
            return Assessment(windowStart: from, windowEnd: to, expectedSamples: 0,
                              observedSamples: 0, coverageFraction: 0,
                              gaps: [], longestGapSeconds: 0)
        }

        let expected = max(0, Int((span / cadence).rounded(.down)))

        var inWindow: [Date] = []
        for t in sampleTimes.sorted() where t >= from && t <= to {
            if inWindow.last != t { inWindow.append(t) }   // input is sorted → dedupe adjacent
        }

        var gaps: [Gap] = []
        var cursor = from
        for t in inWindow {
            if t.timeIntervalSince(cursor) > minGap { gaps.append(Gap(start: cursor, end: t)) }
            cursor = t
        }
        if to.timeIntervalSince(cursor) > minGap { gaps.append(Gap(start: cursor, end: to)) }

        let fraction = expected > 0
            ? Swift.min(1.0, Swift.max(0.0, Double(inWindow.count) / Double(expected)))
            : 0
        return Assessment(windowStart: from, windowEnd: to,
                          expectedSamples: expected,
                          observedSamples: inWindow.count,
                          coverageFraction: fraction,
                          gaps: gaps,
                          longestGapSeconds: gaps.map(\.seconds).max() ?? 0)
    }
}

// AutomaticWorkoutDetection.swift — reconstruct potential workouts from the ring's
// store-and-forward sport stream (#179).
//
// RingConn's automatic recognition runs on the ring. Captures prove that `05 23 01/00 00` toggles
// it and channel 0x02 drains `0x4d` pages containing 10-second HR/step records. The official 4.2.1
// UI states that a continuous workout must last at least 10 minutes. No stable activity-type field
// exists in the captured records; walk/run can only be suggested from cadence, so the UI requires
// explicit type confirmation and leaves stationary activities unlabeled.

import Foundation

/// Decoder for a historical sport page (`0x4d`).
public enum HistoricalSportFrame {
    public static let opcode: UInt8 = 0x4d
    public static let recordLength = 11
    public static let intervalSeconds: TimeInterval = 10

    public struct Sample: Equatable, Codable, Sendable {
        /// End of the 10-second interval, in the ring's cursor space.
        public let cursor: UInt32
        public let heartRate: Int?
        public let steps: Int
        /// Five still-undecoded quality/perfusion bytes retained for future classifier RE.
        public let auxiliary: [UInt8]

        public init(cursor: UInt32, heartRate: Int?, steps: Int, auxiliary: [UInt8] = []) {
            self.cursor = cursor
            self.heartRate = heartRate
            self.steps = steps
            self.auxiliary = auxiliary
        }

        public var endDate: Date {
            Date(timeIntervalSince1970: TimeInterval(Command.syncEpoch) + TimeInterval(cursor))
        }
    }

    /// Decode all complete 11-byte records from one XOR-valid `0x4d` page.
    ///
    /// Byte 2 is a remaining-record/page countdown, not the number of records in this frame.
    /// The payload therefore runs from byte 3 through the byte before the XOR trailer.
    public static func decode(_ frame: [UInt8]) -> [Sample]? {
        guard frame.count >= 4,
              frame[0] == opcode,
              Frame.isValid(frame) else { return nil }

        let payload = Array(frame[3 ..< frame.count - 1])
        guard payload.count % recordLength == 0 else { return nil }

        return stride(from: 0, to: payload.count, by: recordLength).map { offset in
            let record = Array(payload[offset ..< offset + recordLength])
            let cursor = UInt32(record[0]) << 24
                | UInt32(record[1]) << 16
                | UInt32(record[2]) << 8
                | UInt32(record[3])
            let bpm = Int(record[4])
            return Sample(
                cursor: cursor,
                heartRate: LiveHR.validBPM.contains(bpm) ? bpm : nil,
                steps: Int(record[5]),
                auxiliary: Array(record[6 ..< recordLength])
            )
        }
    }
}

/// Reconstructs retroactive potential-workout periods from historical sport samples.
public enum AutomaticWorkoutDetector {
    public enum SuggestedKind: String, Equatable, Sendable {
        case walking
        case running
    }

    public struct Candidate: Equatable, Identifiable, Sendable {
        public let start: Date
        public let end: Date
        public let samples: [HistoricalSportFrame.Sample]
        public let suggestedKind: SuggestedKind?

        /// Stable across retransmitted and later pages because it is the first ring cursor in the
        /// bout, not an app-generated UUID or the still-growing end cursor.
        public var id: UInt32 { samples.first?.cursor ?? 0 }

        public var duration: TimeInterval { end.timeIntervalSince(start) }
        public var steps: Int { samples.reduce(0) { $0 + $1.steps } }
        public var averageHeartRate: Double? {
            let values = samples.compactMap(\.heartRate)
            guard !values.isEmpty else { return nil }
            return Double(values.reduce(0, +)) / Double(values.count)
        }
        public var maximumHeartRate: Int? { samples.compactMap(\.heartRate).max() }

        public init(start: Date,
                    end: Date,
                    samples: [HistoricalSportFrame.Sample],
                    suggestedKind: SuggestedKind?) {
            self.start = start
            self.end = end
            self.samples = samples
            self.suggestedKind = suggestedKind
        }
    }

    /// RingConn 4.2.1's documented minimum continuous recognition period.
    public static let minimumDuration: TimeInterval = 10 * 60

    /// Group ordered 10-second samples into workout candidates. The period begins one sample
    /// interval before the first record's end timestamp, preserving the automatic-detection lead-in
    /// instead of reporting the later sync/confirmation time.
    public static func detect(
        samples: [HistoricalSportFrame.Sample],
        minimumDuration: TimeInterval = minimumDuration,
        maximumGap: TimeInterval = 30,
        minimumCoverage: Double = 0.7
    ) -> [Candidate] {
        guard !samples.isEmpty, minimumDuration > 0 else { return [] }

        // A retransmitted page can repeat cursors. Prefer the duplicate with a valid HR reading,
        // then sort once so grouping is deterministic across page order.
        var unique: [UInt32: HistoricalSportFrame.Sample] = [:]
        for sample in samples {
            if unique[sample.cursor]?.heartRate == nil || sample.heartRate != nil {
                unique[sample.cursor] = sample
            }
        }
        let ordered = unique.values.sorted { $0.cursor < $1.cursor }
        guard let first = ordered.first else { return [] }

        var groups: [[HistoricalSportFrame.Sample]] = [[first]]
        for sample in ordered.dropFirst() {
            let previous = groups[groups.count - 1].last!
            let gap = sample.endDate.timeIntervalSince(previous.endDate)
            if gap > 0, gap <= maximumGap {
                groups[groups.count - 1].append(sample)
            } else {
                groups.append([sample])
            }
        }

        return groups.compactMap { group in
            guard let first = group.first, let last = group.last else { return nil }
            let start = first.endDate.addingTimeInterval(-HistoricalSportFrame.intervalSeconds)
            let end = last.endDate
            let duration = end.timeIntervalSince(start)
            let observed = Double(group.count) * HistoricalSportFrame.intervalSeconds
            guard duration >= minimumDuration,
                  observed / duration >= min(max(minimumCoverage, 0), 1) else { return nil }

            let stepRate = Double(group.reduce(0) { $0 + $1.steps }) / duration * 60
            // Type is only a suggestion: 0x4d exposes cadence but not the ring classifier's label.
            // Stationary/cycling/rowing/yoga/basketball candidates intentionally remain unlabeled.
            let kind: SuggestedKind? = stepRate >= 130 ? .running : (stepRate >= 45 ? .walking : nil)
            return Candidate(start: start, end: end, samples: group, suggestedKind: kind)
        }
    }
}

/// Pure state transition for the app's two-day detected-workout inbox. Keeping this out of
/// `RingSession` makes retransmission, retention, and reviewed-item behavior replay-testable without
/// CoreBluetooth or UserDefaults; the app layer only persists the returned normalized samples.
public enum AutomaticWorkoutInbox {
    public struct State: Equatable, Sendable {
        public let samples: [HistoricalSportFrame.Sample]
        public let candidates: [AutomaticWorkoutDetector.Candidate]

        public init(samples: [HistoricalSportFrame.Sample],
                    candidates: [AutomaticWorkoutDetector.Candidate]) {
            self.samples = samples
            self.candidates = candidates
        }
    }

    public static let retention: TimeInterval = 2 * 24 * 60 * 60

    /// Merge page retransmissions, prune expired records, reconstruct bouts, and suppress any bout
    /// whose stable first cursor was already saved/dismissed. Prefer a duplicate with valid HR.
    public static func rebuild(
        existing: [HistoricalSportFrame.Sample],
        incoming: [HistoricalSportFrame.Sample],
        resolvedStartCursors: Set<UInt32>,
        now: Date = Date(),
        retention: TimeInterval = retention
    ) -> State {
        var unique: [UInt32: HistoricalSportFrame.Sample] = [:]
        for sample in existing + incoming {
            if unique[sample.cursor]?.heartRate == nil || sample.heartRate != nil {
                unique[sample.cursor] = sample
            }
        }
        let cutoff = now.addingTimeInterval(-max(retention, 0))
        let retained = unique.values
            .filter { $0.endDate >= cutoff }
            .sorted { $0.cursor < $1.cursor }
        let candidates = AutomaticWorkoutDetector.detect(samples: retained)
            .filter { candidate in
                guard let startCursor = candidate.samples.first?.cursor else { return false }
                return !resolvedStartCursors.contains(startCursor)
            }
        return State(samples: retained, candidates: candidates)
    }
}

/// Converts a user-confirmed candidate into the same analytics payload used by a live workout.
/// HealthKit remains an app-layer concern; this preparation is pure and preserves only real ring HR.
public enum AutomaticWorkoutConfirmation {
    public struct Prepared: Equatable, Sendable {
        public let summary: WorkoutSummary
        public let heartRateSamples: [HRSample]

        public init(summary: WorkoutSummary, heartRateSamples: [HRSample]) {
            self.summary = summary
            self.heartRateSamples = heartRateSamples
        }
    }

    public static func prepare(
        candidate: AutomaticWorkoutDetector.Candidate,
        sport: WorkoutSportType,
        profile: UserProfile
    ) -> Prepared {
        let aggregator = WorkoutSessionAggregator(startDate: candidate.start, userAge: profile.age)
        for sample in candidate.samples {
            guard let bpm = sample.heartRate else { continue }
            aggregator.add(sample: HRSample(
                bpm: bpm,
                start: sample.endDate.addingTimeInterval(-HistoricalSportFrame.intervalSeconds),
                end: sample.endDate
            ))
        }
        let summary = aggregator.finalize(
            sport: sport,
            endDate: candidate.end,
            distanceMeters: nil,
            hasRoute: false,
            profile: profile,
            steps: candidate.steps > 0 ? candidate.steps : nil
        )
        return Prepared(summary: summary, heartRateSamples: aggregator.collectedSamples)
    }
}

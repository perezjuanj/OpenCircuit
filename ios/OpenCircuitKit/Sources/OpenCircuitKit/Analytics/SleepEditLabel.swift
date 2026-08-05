// Supervised labels harvested from the user's own sleep edits.
//
// WHY THIS EXISTS. Sleep staging has no ground truth in this project. `docs/RUNBOOK_SLEEP_GROUNDTRUTH.md`
// describes capturing RingConn's computed hypnogram via mitmproxy, which needs the vendor app, a
// proxy, and a re-capture every time the model changes. Meanwhile the app already collects a
// cheaper and more authoritative signal and then throws it away: every time someone corrects a
// night's bedtime or wake time, they are stating ground truth about their OWN sleep, and we know
// exactly what the detector said for the same night. That pair is a supervised label.
//
// It is a BIASED sample, and every consumer must treat it as one: people correct nights that look
// wrong and leave nights that look right, so the label set over-represents failures. That makes it
// good for measuring "how wrong are we when we are wrong" and for fitting a knob that must not make
// those cases worse — and useless as an estimate of overall accuracy. `agreementLabels` exists so a
// caller can deliberately include the nights a user looked at and did NOT change, when the UI can
// tell those apart; until it can, `bias` is the honest annotation.
//
// Pure Foundation, no HealthKit/SwiftData, so it unit-tests on the CLI.

import Foundation

/// One night where the detector's answer and the sleeper's answer are both known.
public struct SleepEditLabel: Equatable, Sendable {
    /// Local night key the pair belongs to.
    public let night: Date
    /// What the detector produced before the correction.
    public let recordedOnset: Date?
    public let recordedWake: Date?
    /// What the person who slept the night says actually happened.
    public let trueOnset: Date?
    public let trueWake: Date?

    public init(night: Date,
                recordedOnset: Date? = nil, recordedWake: Date? = nil,
                trueOnset: Date? = nil, trueWake: Date? = nil) {
        self.night = night
        self.recordedOnset = recordedOnset; self.recordedWake = recordedWake
        self.trueOnset = trueOnset; self.trueWake = trueWake
    }

    /// Signed onset error in MINUTES, detector minus truth. Positive = the detector called sleep
    /// onset LATER than it happened. `nil` when either side is missing.
    public var onsetErrorMinutes: Double? {
        guard let r = recordedOnset, let t = trueOnset else { return nil }
        return r.timeIntervalSince(t) / 60
    }

    /// Signed wake error in MINUTES, detector minus truth. Positive = the detector held the night
    /// open too long (the failure mode on a placeholder-flat motion channel).
    public var wakeErrorMinutes: Double? {
        guard let r = recordedWake, let t = trueWake else { return nil }
        return r.timeIntervalSince(t) / 60
    }

    /// True when this label carries at least one usable edge.
    public var isUsable: Bool { onsetErrorMinutes != nil || wakeErrorMinutes != nil }
}

public enum SleepEditLabels {
    /// Minimum correction, in minutes, for an edit to count as a label. Below this the "correction"
    /// is picker friction — the editor works in whole minutes and a user nudging a wheel by a minute
    /// or two is not asserting the detector was wrong. Deliberately small: the errors this exists to
    /// measure are tens of minutes.
    public static let minimumCorrectionMinutes: Double = 3

    /// Keep only labels that carry a real correction on at least one edge.
    public static func usable(_ labels: [SleepEditLabel],
                              minimumMinutes: Double = minimumCorrectionMinutes) -> [SleepEditLabel] {
        labels.filter { label in
            let onset = label.onsetErrorMinutes.map { abs($0) >= minimumMinutes } ?? false
            let wake = label.wakeErrorMinutes.map { abs($0) >= minimumMinutes } ?? false
            return onset || wake
        }
    }

    /// How the detector is doing on the labelled nights. Every field is `nil` when no label carries
    /// that edge, rather than 0 — "no evidence" and "no error" must not read the same.
    public struct Accuracy: Equatable, Sendable {
        public let count: Int
        /// Mean SIGNED error (minutes): the systematic bias. A detector that is late on every night
        /// shows a large positive mean, which a mean-ABSOLUTE error would hide.
        public let meanOnsetError: Double?
        public let meanWakeError: Double?
        /// Median ABSOLUTE error (minutes): typical magnitude, robust to one wild night.
        public let medianAbsOnsetError: Double?
        public let medianAbsWakeError: Double?
    }

    public static func accuracy(_ labels: [SleepEditLabel]) -> Accuracy {
        let onsets = labels.compactMap(\.onsetErrorMinutes)
        let wakes = labels.compactMap(\.wakeErrorMinutes)
        func mean(_ xs: [Double]) -> Double? { xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count) }
        func medianAbs(_ xs: [Double]) -> Double? {
            guard !xs.isEmpty else { return nil }
            let s = xs.map(abs).sorted()
            return s.count.isMultiple(of: 2)
                ? (s[s.count / 2 - 1] + s[s.count / 2]) / 2
                : s[s.count / 2]
        }
        return Accuracy(count: labels.count,
                        meanOnsetError: mean(onsets), meanWakeError: mean(wakes),
                        medianAbsOnsetError: medianAbs(onsets), medianAbsWakeError: medianAbs(wakes))
    }

    /// Whether there is enough evidence to FIT a staging knob against these labels. Deliberately
    /// conservative: this is the gate that decides when a default may move off a value chosen by
    /// hand, and the standing rule is that one night is never enough (change-control N8).
    ///
    /// 🟡 The bar itself is a judgement, not a measurement: 10 nights is roughly where a median
    /// stops being dominated by any single night. It is NOT a statistical guarantee, and it does
    /// not cure the selection bias described at the top of this file — it only says "enough to
    /// stop guessing", not "enough to be right".
    public static let minimumNightsToFit = 10

    public static func isFittable(_ labels: [SleepEditLabel]) -> Bool {
        usable(labels).count >= minimumNightsToFit
    }
}

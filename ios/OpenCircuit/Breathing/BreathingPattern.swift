// The pure model behind the guided breathing exercise: which patterns exist and, for any elapsed time
// since the start, which phase the person is in, how far through it, and how full the lungs are.
// A pure function of elapsed time (no timers), so the cue can never drift from the clock.
//
// Nothing here is stored or written to Apple Health.

import Foundation

/// One step of a breath: breathe in, hold full, breathe out, or hold empty.
enum BreathingPhaseKind: String, Equatable {
    case inhale, holdFull, exhale, holdEmpty

    var label: String {
        switch self {
        case .inhale: return "Breathe in"
        case .holdFull, .holdEmpty: return "Hold"
        case .exhale: return "Breathe out"
        }
    }
}

struct BreathingPhase: Equatable {
    let kind: BreathingPhaseKind
    /// Seconds, always > 0.
    let duration: TimeInterval
}

/// A repeating cycle of phases.
struct BreathingPattern: Equatable, Identifiable {
    let id: String
    let name: String
    /// One line under the name in the picker.
    let summary: String
    let phases: [BreathingPhase]

    /// A pattern is given as (in, hold, out, hold); a zero duration leaves that step out.
    init(id: String, name: String, summary: String,
         inhale: TimeInterval, holdFull: TimeInterval, exhale: TimeInterval, holdEmpty: TimeInterval) {
        self.id = id
        self.name = name
        self.summary = summary
        self.phases = [
            BreathingPhase(kind: .inhale, duration: inhale),
            BreathingPhase(kind: .holdFull, duration: holdFull),
            BreathingPhase(kind: .exhale, duration: exhale),
            BreathingPhase(kind: .holdEmpty, duration: holdEmpty),
        ].filter { $0.duration > 0 }
    }

    static let box = BreathingPattern(id: "box", name: "Box 4-4-4-4",
                                      summary: "In, hold, out, hold, four seconds each",
                                      inhale: 4, holdFull: 4, exhale: 4, holdEmpty: 4)
    static let fourSevenEight = BreathingPattern(id: "478", name: "4-7-8",
                                                 summary: "In for 4, hold for 7, out for 8",
                                                 inhale: 4, holdFull: 7, exhale: 8, holdEmpty: 0)
    static let coherent = BreathingPattern(id: "coherent", name: "Coherent 5.5",
                                           summary: "In for 5.5, out for 5.5, about 5.5 breaths a minute",
                                           inhale: 5.5, holdFull: 0, exhale: 5.5, holdEmpty: 0)

    static let all: [BreathingPattern] = [.box, .fourSevenEight, .coherent]

    static func pattern(id: String) -> BreathingPattern {
        all.first { $0.id == id } ?? .box
    }

    /// Seconds in one full cycle.
    var cycleDuration: TimeInterval { phases.reduce(0) { $0 + $1.duration } }

    /// Where the person is `elapsed` seconds after the start. Boundaries belong to the NEXT phase
    /// (box: 3.99 s is still breathing in, 4.0 s is the hold). Negative time clamps to 0.
    func position(at elapsed: TimeInterval) -> BreathingPosition {
        let t = max(0, elapsed)
        let cycle = cycleDuration
        let cycleIndex = Int((t / cycle).rounded(.down))
        let within = t - Double(cycleIndex) * cycle
        var start = 0.0
        for (i, phase) in phases.enumerated() {
            let end = start + phase.duration
            if within < end || i == phases.count - 1 {
                let into = min(max(within - start, 0), phase.duration)
                return BreathingPosition(cycle: cycleIndex, phaseIndex: i, kind: phase.kind,
                                         progress: into / phase.duration,
                                         remaining: phase.duration - into)
            }
            start = end
        }
        // Unreachable: `phases` is never empty for the shipped patterns.
        return BreathingPosition(cycle: cycleIndex, phaseIndex: 0, kind: .inhale, progress: 0, remaining: 0)
    }
}

/// A moment inside a pattern.
struct BreathingPosition: Equatable {
    let cycle: Int
    let phaseIndex: Int
    let kind: BreathingPhaseKind
    /// 0…1 through the current phase.
    let progress: Double
    /// Seconds left in the current phase.
    let remaining: TimeInterval

    /// Changes exactly when the phase changes, for the haptic.
    var phaseID: Int { cycle * 8 + phaseIndex }

    /// The countdown shown under the phase word: whole seconds, rounded up, so it never shows 0
    /// while the phase is still running.
    var countdown: Int { max(1, Int(remaining.rounded(.up))) }

    /// How full the lungs are, 0 (empty) … 1 (full): the circle's size. Eased so the circle slows
    /// at the ends of a breath.
    var fullness: Double {
        switch kind {
        case .inhale: return Self.ease(progress)
        case .holdFull: return 1
        case .exhale: return 1 - Self.ease(progress)
        case .holdEmpty: return 0
        }
    }

    private static func ease(_ x: Double) -> Double { x * x * (3 - 2 * x) }
}

/// How long a session runs.
enum BreathingLength: Int, CaseIterable, Identifiable {
    case one = 60, three = 180, five = 300

    var id: Int { rawValue }
    var seconds: TimeInterval { TimeInterval(rawValue) }
    var title: String { "\(rawValue / 60) min" }

    static func from(seconds: Int) -> BreathingLength { BreathingLength(rawValue: seconds) ?? .three }

    func isFinished(at elapsed: TimeInterval) -> Bool { elapsed >= seconds }
}

/// The heart-rate figures the end screen shows, from the readings this screen observed.
struct BreathingHeartRateSummary: Equatable {
    private(set) var start: Int?
    private(set) var end: Int?
    private(set) var lowest: Int?

    /// Record one settled live reading. Zero or negative values are not readings.
    mutating func record(_ bpm: Int) {
        guard bpm > 0 else { return }
        if start == nil { start = bpm }
        end = bpm
        lowest = min(lowest ?? bpm, bpm)
    }

    var hasReadings: Bool { start != nil }
}

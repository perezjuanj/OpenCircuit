// WIRE NAMES for `SleepConfidence.Assessment` — the strings a tester bundle and the data export
// carry, and nothing else.
//
// WHY THIS FILE EXISTS SEPARATELY FROM ANY UI COPY. This is instrumentation, landed deliberately
// AHEAD of the user-visible caveat it will eventually explain. The card change these verdicts were
// written for is PARKED: its central claim — "it never fires on a night we get right" — is not a
// measurement but the absence of one, because the corpus's only good labelled night
// (`R3_2026-08-15`) is silent purely because the capture file ends two minutes after the detected
// wake and the next record anywhere is 80.9 h later. On a real phone the archive is continuous, so
// that night gets a successor too and nothing in the corpus says which side of the cut it lands on.
//
// The way out is to collect the field from real devices first. So the verdicts ship into
// `sleepSessions[].edgeProvenance` and the diagnostics bundle now, the wearer sees nothing new, and
// in two weeks the question "on nights the wearer did NOT edit, how often does `wakeGapSeconds`
// exceed an hour?" is answerable from bundles instead of unanswerable from 21 nights.
//
// ⚠️ APPEND-ONLY. These are a wire format. Renaming one silently breaks every bundle already
// collected, and a rename is invisible at compile time on the reading side because the reader is a
// script, not Swift.
//
// Pure (no Apple frameworks) so it unit-tests on the CLI.

import Foundation

extension SleepConfidence {

    /// Short, stable identifier for a reason — for the diagnostics bundle and the data export, where
    /// a tester's file has to stay greppable across builds and no future analysis should key on a UI
    /// sentence.
    public static func exportName(_ reason: Reason) -> String {
        switch reason {
        case .noRecordingAfterWake:     return "noRecordingAfterWake"
        case .noRecordingBeforeBedtime: return "noRecordingBeforeBedtime"
        case .durationLikelyHigh:       return "durationLikelyHigh"
        }
    }

    /// Wire name for a leading-edge verdict. Same append-only contract.
    public static func exportName(_ verdict: BedtimeProvenance.Verdict) -> String {
        switch verdict {
        case .witnessed:          return "witnessed"
        case .resumedAfterGap:    return "resumedAfterGap"
        case .noPriorMeasurement: return "noPriorMeasurement"
        case .unknown:            return "unknown"
        }
    }

    /// Wire name for a trailing-edge verdict. Same append-only contract.
    public static func exportName(_ verdict: WakeProvenance.Verdict) -> String {
        switch verdict {
        case .witnessed:          return "witnessed"
        case .stoppedThenResumed: return "stoppedThenResumed"
        case .unknown:            return "unknown"
        }
    }

    /// The measured silence a verdict carries, in seconds, or nil when it carries none.
    /// `.witnessed` and `.unknown` genuinely have no gap — emitting 0 would claim we measured a
    /// continuous stream, which is the opposite of what `.unknown` means.
    public static func gapSeconds(_ verdict: BedtimeProvenance.Verdict) -> TimeInterval? {
        if case .resumedAfterGap(let g) = verdict { return g }
        return nil
    }

    /// The measured silence a trailing-edge verdict carries, in seconds, or nil.
    public static func gapSeconds(_ verdict: WakeProvenance.Verdict) -> TimeInterval? {
        if case .stoppedThenResumed(let g) = verdict { return g }
        return nil
    }
}

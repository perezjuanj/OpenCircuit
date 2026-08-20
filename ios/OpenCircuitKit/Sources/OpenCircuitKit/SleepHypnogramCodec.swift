// On-disk codec for a night's staged hypnogram (`StoredSleepSummary.hypnogramData`).
//
// WHY a hand-pinned byte format instead of a `Codable [SleepSegment]` column: `SleepSegment`
// is a live model type (Metrics.swift:84) that other work is free to refactor — adding a
// field or renaming `stage`'s raw values would silently change the encoding under every
// existing install, and nights already written would decode to garbage or to nothing at all.
// This format is deliberately narrow (three integers per segment), and a test pins its exact
// bytes, so a future `SleepSegment` change cannot invalidate stored nights without failing.
//
// Format: a JSON array of 3- OR 4-element integer arrays
//     [[startEpochSeconds, endEpochSeconds, stageCode], …]
//     [[startEpochSeconds, endEpochSeconds, stageCode, provenanceCode], …]
// with stageCode 0=inBed 1=awake 2=asleepCore 3=asleepDeep 4=asleepREM
// and provenanceCode 1=asserted 2=assertedOverMeasured 3=assertedCoverageUnknown
// (0 = measured, and it is OMITTED).
//
// ⚠️ THE FOURTH ELEMENT IS WRITTEN ONLY WHEN PROVENANCE IS NOT `.measured`. An all-measured night —
// which is every unedited night — therefore encodes to the IDENTICAL bytes it did before provenance
// existed, and an older build reading it back is unaffected. Only a night carrying user-asserted
// time grows a fourth element, and an older build's `triple.count == 3` guard would drop exactly
// those segments — which is the safe direction, since they are the ones it would otherwise
// mis-count as measured sleep.
//
// ⚠️ THE STAGE LOOKUP IS A DICTIONARY, NOT AN EXHAUSTIVE SWITCH (`codeForStage`, `:39`). That is
// why "time we did not measure" is a PROVENANCE and not a sixth `SleepStage`: a sixth case would
// compile clean here and its segments would silently vanish from the stored hypnogram while the
// night's MINUTES — computed from `Summary`, which switches exhaustively — still counted them, so
// the timeline and the totals would disagree with no error anywhere. See `SleepProvenance`.
//
// Robustness policy (this is stored user data — it must never trap and never invent):
//   • empty `Data`, non-JSON bytes, or JSON that isn't an array of integer arrays → `[]`
//   • a segment that isn't three or four integers, carries an unknown stage code, or is
//     reversed/zero-length → that ONE segment is dropped, the rest survive
//   • an UNKNOWN provenance code degrades to `.measured` rather than dropping the segment: losing a
//     minute of real sleep is worse than losing its label, and forward-compat is the whole point.
// `decode` never throws and never fabricates a segment that wasn't stored.

import Foundation

public enum SleepHypnogramCodec {

    /// Wire code for each stage. Stable — these integers are on disk in every install, so a
    /// case may be added but an existing pairing must never be renumbered.
    private static let codeForStage: [SleepStage: Int] = [
        .inBed: 0, .awake: 1, .asleepCore: 2, .asleepDeep: 3, .asleepREM: 4
    ]
    private static let stageForCode: [Int: SleepStage] = [
        0: .inBed, 1: .awake, 2: .asleepCore, 3: .asleepDeep, 4: .asleepREM
    ]

    /// Wire code for provenance. `.measured` is 0 and is never written — see the header.
    ///
    /// ⚠️ WHAT A DOWNGRADE DOES WITH CODE 3 (`.assertedCoverageUnknown`), stated precisely rather
    /// than optimistically. A build that shipped WITH provenance but without this case reads the
    /// 4-element row and maps the unrecognised code to `.measured` via the `?? .measured` below: it
    /// counts and publishes the span, which is what this build does too. A build that predates
    /// provenance entirely drops any 4-element row (its guard is `count == 3`), so the span vanishes
    /// from its TIMELINE while the row's stored MINUTES still include it. Both are display-side; in
    /// neither direction can "we cannot tell" become "nothing was recorded" and retract a user's
    /// sleep, which is the property that has to hold.
    private static let codeForProvenance: [SleepProvenance: Int] = [
        .measured: 0, .asserted: 1, .assertedOverMeasured: 2, .assertedCoverageUnknown: 3
    ]
    private static let provenanceForCode: [Int: SleepProvenance] = [
        0: .measured, 1: .asserted, 2: .assertedOverMeasured, 3: .assertedCoverageUnknown
    ]

    /// Encode segments to the stored form. Segments that `decode` would refuse (reversed or
    /// zero-length) are skipped rather than written: storing a segment we would not read back
    /// gives a night whose stored form disagrees with its loaded form.
    public static func encode(_ segments: [SleepSegment]) -> Data {
        let triples: [[Int]] = segments.compactMap { seg in
            guard let code = codeForStage[seg.stage] else { return nil }
            let start = Int(seg.start.timeIntervalSince1970.rounded())
            let end = Int(seg.end.timeIntervalSince1970.rounded())
            guard end > start else { return nil }
            // Omit the provenance element for `.measured` so an all-measured night's bytes are
            // unchanged from every build that shipped before provenance existed.
            let p = codeForProvenance[seg.provenance] ?? 0
            return p == 0 ? [start, end, code] : [start, end, code, p]
        }
        // JSONEncoder on `[[Int]]` is compact and key-free, so its output is fully determined
        // by the numbers themselves — no dictionary ordering to stabilise.
        return (try? JSONEncoder().encode(triples)) ?? Data()
    }

    /// Decode the stored form. Returns `[]` for anything it cannot read; drops individual
    /// malformed segments rather than discarding a whole night for one bad row.
    public static func decode(_ data: Data) -> [SleepSegment] {
        guard !data.isEmpty,
              let triples = try? JSONDecoder().decode([[Int]].self, from: data) else { return [] }
        return triples.compactMap { triple in
            guard triple.count == 3 || triple.count == 4,
                  let stage = stageForCode[triple[2]] else { return nil }
            let start = triple[0], end = triple[1]
            guard end > start else { return nil }
            // A 3-element row is a legacy (pre-provenance) segment: it was written by the staging
            // path or by an edit that had no coverage test, so `.measured` is the only honest
            // reading of what the row itself claims. Rows a MIGRATION knows to be edit output are
            // marked at the row level via `sleepBasis`, not here.
            let provenance = triple.count == 4
                ? (provenanceForCode[triple[3]] ?? .measured)
                : .measured
            return SleepSegment(start: Date(timeIntervalSince1970: TimeInterval(start)),
                                end: Date(timeIntervalSince1970: TimeInterval(end)),
                                stage: stage, provenance: provenance)
        }
    }
}

// On-disk codec for a night's staged hypnogram (`StoredSleepSummary.hypnogramData`).
//
// WHY a hand-pinned byte format instead of a `Codable [SleepSegment]` column: `SleepSegment`
// is a live model type (Metrics.swift:84) that other work is free to refactor — adding a
// field or renaming `stage`'s raw values would silently change the encoding under every
// existing install, and nights already written would decode to garbage or to nothing at all.
// This format is deliberately narrow (three integers per segment), and a test pins its exact
// bytes, so a future `SleepSegment` change cannot invalidate stored nights without failing.
//
// Format: a JSON array of 3-element integer arrays
//     [[startEpochSeconds, endEpochSeconds, stageCode], …]
// with stageCode 0=inBed 1=awake 2=asleepCore 3=asleepDeep 4=asleepREM.
// Empty hypnogram encodes to `[]`; an absent one is stored as empty `Data` (see `decode`).
//
// Robustness policy (this is stored user data — it must never trap and never invent):
//   • empty `Data`, non-JSON bytes, or JSON that isn't an array of integer arrays → `[]`
//   • a segment that isn't exactly three integers, carries an unknown stage code, or is
//     reversed/zero-length → that ONE segment is dropped, the rest survive
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

    /// Encode segments to the stored form. Segments that `decode` would refuse (reversed or
    /// zero-length) are skipped rather than written: storing a segment we would not read back
    /// gives a night whose stored form disagrees with its loaded form.
    public static func encode(_ segments: [SleepSegment]) -> Data {
        let triples: [[Int]] = segments.compactMap { seg in
            guard let code = codeForStage[seg.stage] else { return nil }
            let start = Int(seg.start.timeIntervalSince1970.rounded())
            let end = Int(seg.end.timeIntervalSince1970.rounded())
            guard end > start else { return nil }
            return [start, end, code]
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
            guard triple.count == 3, let stage = stageForCode[triple[2]] else { return nil }
            let start = triple[0], end = triple[1]
            guard end > start else { return nil }
            return SleepSegment(start: Date(timeIntervalSince1970: TimeInterval(start)),
                                end: Date(timeIntervalSince1970: TimeInterval(end)),
                                stage: stage)
        }
    }
}

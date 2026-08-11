import Foundation

/// Does the union of a diagnostics export's per-drain raw-record blobs actually cover the epochs the
/// app HOLDS? (#203)
///
/// ⚠️ THE CHECK THIS REPLACES WAS VACUOUS. `historySyncEvidence[].mergedRecordCount` and
/// `rawRecordBlobBase64` are built from the SAME `bulkRecords` array in the same call, so comparing
/// one against the other can never disagree — it says nothing about completeness. The evidence list
/// is also a bounded ring buffer (`ObservabilityStore.historySyncEvidenceLimit`), so epochs that
/// reached the app through a drain whose row has since been dropped appear in NO blob at all.
///
/// 🟢 MEASURED on a Gen-3 tester's export (FR05.010, build 39, Europe/Paris, 2026-08-10→11): the
/// blobs contain 367 records with an apparent 35-minute hole at 05:44:46 → 06:19:48, while the
/// export's own `samples` table carries HR + HRV + RR + SpO2 for 13 epochs INSIDE that hole, on the
/// exact 150 s cadence — epochs the app decoded, persisted and staged. Replaying the blobs alone
/// gave in-bed 470 / asleep 460 and a wake of 05:46:46; restoring those 13 epochs gives in-bed 522 /
/// asleep 511 / deep 75 / light 280 / REM 156 / awake 11 and a wake of 06:38:18 — the Sleep card's
/// numbers to the minute, all seven of them. So the "data hole" was in the DIAGNOSTIC, not in the
/// data, and a whole investigation was spent on a night the engine had staged deterministically.
///
/// Pure and Kit-side so the export can state its own completeness instead of leaving the reader to
/// assume it.
public enum ArchiveEvidenceCoverage {

    public struct Report: Equatable, Sendable {
        /// Distinct epochs in the app's own rolling archive — what staging actually ran on.
        public let archiveRecordCount: Int
        /// Distinct epochs recoverable from the union of the evidence blobs.
        public let evidenceRecordCount: Int
        /// Archive epoch counters that NO evidence blob carries: precisely what a replay from the
        /// blobs alone would be blind to. Ascending.
        public let missingFromEvidence: [UInt32]
        /// Longest run of consecutive missing epochs, in seconds — the size of the phantom "hole" a
        /// blob-only replay would see. 0 when nothing is missing.
        public let longestMissingRunSeconds: Int

        /// The blobs cover everything the app holds, so a replay from this export is faithful.
        public var isComplete: Bool { missingFromEvidence.isEmpty }
    }

    /// Compare what the app holds against what the export's blobs carry. Both inputs are deduped by
    /// epoch counter first — `EpochArchive.merge` dedups on the archive side and the blobs overlap
    /// whenever a drain re-hydrates banked records, so counting raw arrays would be wrong on both.
    public static func report(archive: [BulkRecord], evidence: [BulkRecord]) -> Report {
        let archiveCounters = Set(archive.map(\.counter))
        let evidenceCounters = Set(evidence.map(\.counter))
        let missing = archiveCounters.subtracting(evidenceCounters).sorted()
        return Report(archiveRecordCount: archiveCounters.count,
                      evidenceRecordCount: evidenceCounters.count,
                      missingFromEvidence: missing,
                      longestMissingRunSeconds: longestRunSeconds(missing))
    }

    /// Longest consecutive run in `counters`, measured in seconds. "Consecutive" means one epoch
    /// apart (`BulkRecord.epochSeconds`) with a tolerance, because the ring's cadence drifts a second
    /// or two between epochs (152 s intervals are common on Gen 3).
    private static func longestRunSeconds(_ counters: [UInt32]) -> Int {
        guard let first = counters.first else { return 0 }
        let tolerance = 10
        var best = BulkRecord.epochSeconds
        var runStart = first
        var previous = first
        for c in counters.dropFirst() {
            let step = Int(c) - Int(previous)
            if step <= BulkRecord.epochSeconds + tolerance {
                best = max(best, Int(c) - Int(runStart) + BulkRecord.epochSeconds)
            } else {
                runStart = c
            }
            previous = c
        }
        return best
    }
}

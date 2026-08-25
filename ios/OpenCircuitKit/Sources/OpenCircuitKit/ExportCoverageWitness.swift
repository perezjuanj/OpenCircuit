// WHICH INSTANTS THE EXPORT'S `coverageFraction` IS ALLOWED TO COUNT.
//
// `ExportCoverage.assess` answers "of the epochs this window could contain, how many do we hold?".
// It is only as honest as the timestamps it is fed, and this type picks those.
//
// THE DEFECT THIS EXISTS FOR (🟢 measured 2026-08-24 on a tester export, ring
// 6F627CA0…592C, night 2026-08-24, in-bed 20:31:42 → 04:40:38 −04:00).
// The witness used to be the persisted `heartRate` STORE ROWS alone. The store is not the record
// set staging runs on — it is that set after `SyncCursor.selectNew`, which is strictly
// forward-only. One live auto-measure sample stamped 23:14:00.580 therefore stranded every
// 21:22–23:14 epoch that the ring delivered AFTERWARDS, and the file published:
//
//     coverageFraction 0.7333, observedSamples 143, 4 gaps, longest 6851 s
//
// while the 30 h epoch archive held 205 heart-rate-bearing epochs across the same window with no
// hole at all. Three of the four "gaps" carried sub-second boundaries — the fingerprint of a live
// sample, not of a 150 s epoch stream. So the number was a statement about OUR CURSOR wearing the
// costume of a statement about the ring, on the one row a triager reads first.
//
// WHY THE ARCHIVE ALONE IS NOT THE ANSWER EITHER. `EpochArchive.retention` is ~30 h, so a night
// two days old is simply not in it, and an archive-only witness reports the whole night as a hole —
// the same retention-as-absence trap `MeasuredCoverage.trusted(for:)` was built to close. 🟢 On the
// same export, archive-only would have taken night 2026-08-23 from 0.9832 / one 602 s gap to
// 0.5798 / one 7701 s gap, and every second of that 7701 s "hole" is retention, not a recording
// failure.
//
// SO THE WITNESS IS THE UNION of the two, which is this codebase's existing GENEROSITY RULE
// (`MeasuredCoverage`, "coverage is always computed from the WIDEST record set available"): every
// instant in the union is one we genuinely hold, so the union can never invent coverage, and every
// gap it still reports is a gap under the app's own best case. It is also monotone against the old
// behaviour — coverage can only rise and gaps can only shrink — so no night that reported a real
// hole can have it papered over by this change. 🟢 On the two tester exports of 2026-08-24 the
// union moved exactly one of five nights (the one above, to 1.0000 / 0 gaps) and left the other
// four byte-identical, including a genuine 12907 s recording hole that stayed reported.

import Foundation

public enum ExportCoverageWitness {

    /// The instants `ExportCoverage.assess` should measure `[from, to]` over.
    ///
    /// - Parameters:
    ///   - archives: one entry per ring whose epoch archive is still on disk. NOT unioned across
    ///     rings — the archive is per-ring precisely because two rings' records must not be merged
    ///     into one corrupted timeline, so the archive with the MOST in-window measured epochs wins
    ///     and the rest are ignored. On the single-ring install that is every install in the field,
    ///     this reduces to "the archive". Ties keep the first entry, so a caller that passes a
    ///     stably ordered array (sorted by ring id) gets a stable answer.
    ///   - storedHeartRateTimes: the persisted `heartRate` sample instants for the window. Already
    ///     the OLD witness, kept in the union for the nights the archive has aged out of, and for
    ///     the live auto-measure instants that are real measurements the epoch stream never carries.
    ///
    /// Heart rate specifically, on BOTH sides — the witness the export already chose, for the
    /// reason it already gives. A `0x4c` record carries HR in exactly one byte, `[4]` (🟢
    /// `BulkRecord.heartRate`), so one HR instant IS one epoch we hold, while HRV/SpO₂/RR are
    /// sparser by layout and would under-report coverage that is genuinely complete. `heartRate`
    /// is also the accessor that already excludes the `.idle` (unworn/charging) template, which
    /// carries no measurement and must never be counted as coverage.
    ///
    /// Duplicates are not removed here; `ExportCoverage.assess` dedupes adjacent instants itself,
    /// and an epoch that also has a store row is the SAME instant, so it collapses there.
    public static func sampleTimes(archives: [[BulkRecord]],
                                   storedHeartRateTimes: [Date],
                                   from: Date,
                                   to: Date,
                                   epoch: Int = Command.syncEpoch) -> [Date] {
        guard to > from else { return storedHeartRateTimes }

        var best: [Date] = []
        for archive in archives {
            let inWindow = archive
                .filter { $0.heartRate != nil }
                .map { $0.date(epoch: epoch) }
                .filter { $0 >= from && $0 <= to }
            if inWindow.count > best.count { best = inWindow }
        }
        return best + storedHeartRateTimes
    }
}

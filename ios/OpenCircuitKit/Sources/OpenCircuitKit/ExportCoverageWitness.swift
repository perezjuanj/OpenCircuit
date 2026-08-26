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

        return bestArchiveTimes(archives, from: from, to: to, epoch: epoch) + storedHeartRateTimes
    }

    /// The heart-rate instants the single most-covering ring archive holds inside `[from, to]`.
    ///
    /// Extracted so `sampleTimes` (density INSIDE a window) and `edges` (distance to the nearest
    /// instant OUTSIDE an edge) cannot drift into two different ideas of "the archive", and in
    /// particular so the per-ring tie-break stays ONE rule with one description.
    private static func bestArchiveTimes(_ archives: [[BulkRecord]],
                                         from: Date, to: Date, epoch: Int) -> [Date] {
        var best: [Date] = []
        for archive in archives {
            let inWindow = archive
                .filter { $0.heartRate != nil }
                .map { $0.date(epoch: epoch) }
                .filter { $0 >= from && $0 <= to }
            if inWindow.count > best.count { best = inWindow }
        }
        return best
    }

    // MARK: - Edge probes (#198 / #204 follow-up)
    //
    // THE SAME DEFECT, ON THE THREE PROBES THE UNION ABOVE DID NOT REACH. `coverageFraction` was
    // fixed by unioning the archive in; `SleepConfidence.Coverage`'s three instants were left on
    // `LocalStore.latestSample(kind:before:)` / `earliestSample(kind:after:)`, which read the SAME
    // forward-only-cursor-filtered store rows, in three places at once (the export's
    // `edgeProvenance`, the Sleep card's bedtime hint, and the diagnostics bundle's `edges:` line).
    //
    // 🟢 MEASURED on the tester's night of 2026-08-25 (Gen 2 Air FR04.009, build 47): the export
    // published `bedtimeVerdict=resumedAfterGap`, `bedtimeGapSeconds=6641`,
    // `reasons=[noRecordingBeforeBedtime]` across 110 minutes the ring had recorded END TO END —
    // 162 consecutive epochs, none missing. 02:04:37 − 6641 s = 00:13:56, which is exactly the last
    // PERSISTED heart-rate row. The probe measured our cursor and printed it as a statement about
    // the ring — and the Sleep card renders that same verdict to the WEARER in plain English ("it
    // recorded nothing for 1h 51m before that. If you were already in bed, tap Edit to correct it").
    //
    // WHY THIS IS SAFE — THE UNION IS MONOTONE AT AN EDGE TOO, in the same direction as the
    // coverage union. `lastMeasurementBeforeStart` takes the LATER of the two candidates and
    // `firstMeasurementAfterEnd` the EARLIER, so both reported gaps can only SHRINK; every instant
    // offered is a record actually on disk, so no gap can be invented and no real hole papered over
    // — a hole the archive also has stays reported at its full width.

    /// The three acquisition instants a night's edge verdicts are computed from, plus a statement of
    /// which witness actually produced them.
    public struct Edges: Equatable, Sendable {

        /// The window these instants were probed around — carried so `coverage` cannot be built
        /// against a different pair than the one that was measured.
        public let inBedStart: Date
        public let inBedEnd: Date

        /// Latest heart-rate instant strictly BEFORE `inBedStart`, from store ∪ archive.
        public let lastMeasurementBeforeStart: Date?
        /// Earliest heart-rate instant strictly AFTER `inBedEnd`, from store ∪ archive.
        public let firstMeasurementAfterEnd: Date?
        /// Oldest heart-rate instant we hold at all, from store ∪ archive. Feeds the retention
        /// guards in `BedtimeProvenance.classify` / `WakeProvenance.classify` — see the note on
        /// `edges(archives:…)` for why unioning it cannot weaken them.
        public let earliestRetainedMeasurement: Date?

        /// Heart-rate-bearing archive epochs inside the probed window — the night itself plus one
        /// `widening` on each side — taken from the one ring archive that had the most of them.
        /// `0` means no archive could speak here and the three instants above ARE the store's own
        /// answers, unchanged.
        public let archiveEpochsInReach: Int

        /// True when the archive supplied an instant the store did not — i.e. without it this probe
        /// would have reported a WIDER gap, or no verdict at all.
        public let archiveMovedAnEdge: Bool

        /// The `SleepConfidence.Coverage` these instants describe.
        public var coverage: SleepConfidence.Coverage {
            SleepConfidence.Coverage(inBedStart: inBedStart,
                                     inBedEnd: inBedEnd,
                                     lastMeasurementBeforeStart: lastMeasurementBeforeStart,
                                     firstMeasurementAfterEnd: firstMeasurementAfterEnd,
                                     earliestRetainedMeasurement: earliestRetainedMeasurement)
        }

        /// One greppable token naming the witness that was ACTUALLY used, for a diagnostics line.
        ///
        /// This exists because the failure it reports is SILENT: when no archive is loaded, every
        /// probe here degenerates to the store-only behaviour that produced the 6641 s phantom gap,
        /// and nothing downstream looks any different. `store` on a night the archive should still
        /// cover is the tell.
        public var witnessDescription: String {
            guard archiveEpochsInReach > 0 else { return "store" }
            return "store+archive(\(archiveEpochsInReach)\(archiveMovedAnEdge ? ",moved" : ""))"
        }
    }

    /// Resolve a night's three edge instants from the store's answers UNIONED with the epoch archive.
    ///
    /// - Parameters:
    ///   - archives: one entry per ring, exactly as `sampleTimes` takes them and with the same
    ///     per-ring tie-break (most in-window epochs wins; never merged across rings).
    ///   - storedLastBeforeStart: `LocalStore.latestSample(kind: .heartRate, before: inBedStart)`.
    ///   - storedFirstAfterEnd: `LocalStore.earliestSample(kind: .heartRate, after: inBedEnd)`.
    ///   - storedEarliestRetained: `LocalStore.earliestSample(kind: .heartRate)`.
    ///   - widening: how far OUTSIDE the night the archive is allowed to answer from.
    ///
    /// HEART RATE ON BOTH SIDES, for the reason the file header already gives and that
    /// `BedtimeProvenance`/`WakeProvenance` repeat: HR is band-guarded to 30…220 bpm, so a charging
    /// or pocketed ring yields none, whereas a skin-temp or step row keeps arriving from a docked
    /// ring and would call a charge cycle "witnessed". `BulkRecord.heartRate` is also what excludes
    /// the `.idle` (unworn/charging) template on the archive side.
    ///
    /// ⚠️ WHY THE WIDENING IS `EpochArchive.retention` AND NOT A NUMBER CHOSEN HERE. These probes
    /// ask about instants OUTSIDE the night, so the archive has to be consulted outside it — but the
    /// archive can only honestly speak about a span it could have observed, and `EpochArchive.merge`
    /// prunes every record older than `retention` before its newest one (`EpochArchive.swift:27`,
    /// 30 h). A record further from an edge than that is therefore the archive's own PRUNING
    /// BOUNDARY rather than a neighbour of the edge, and treating it as "the ring resumed here"
    /// would report our retention as a recording gap — the exact retention-as-absence trap this
    /// file's header, `MeasuredCoverage.trusted(for:)` and `WakeProvenance`'s retention guard were
    /// each built to close. Concretely: on a night five days old the archive holds only the last
    /// 30 h, so `[start − 30 h, end + 30 h]` does not reach it at all and the store's answers stand
    /// untouched; on last night — the case the defect was measured on — the window covers the whole
    /// archive. Because the union is monotone, a LARGER widening could only shrink gaps further and
    /// a SMALLER one would silently discard evidence we hold; the archive's own horizon is the
    /// largest widening that is still a statement about records it could have made.
    ///
    /// ⚠️ THE RETENTION GUARDS ARE PRESERVED, NOT WEAKENED. `earliestRetainedMeasurement` is unioned
    /// with `min`, so it can only reach FURTHER BACK — and it only does so when the archive really
    /// holds a record that old, which is precisely the condition under which the night is inside our
    /// horizon and the guard is supposed to stand down. It is also probed through the SAME widened
    /// window as the other two, which is what keeps `BedtimeProvenance.noPriorMeasurement`
    /// unreachable from a real caller: any archive instant old enough to satisfy that branch's
    /// `earliest <= inBedStart - 30 min` is itself a measurement before the bedtime, so
    /// `lastMeasurementBeforeStart` is non-nil and the branch cannot be entered.
    public static func edges(archives: [[BulkRecord]],
                             storedLastBeforeStart: Date?,
                             storedFirstAfterEnd: Date?,
                             storedEarliestRetained: Date?,
                             inBedStart: Date,
                             inBedEnd: Date,
                             widening: TimeInterval = EpochArchive.retention,
                             epoch: Int = Command.syncEpoch) -> Edges {
        // Normalised so a caller with a degenerate or inverted window (the Sleep card probes the
        // leading edge alone and has no wake time on a legacy rollup) still gets a sane window
        // rather than an empty one.
        let low = min(inBedStart, inBedEnd).addingTimeInterval(-widening)
        let high = max(inBedStart, inBedEnd).addingTimeInterval(widening)
        let inReach = bestArchiveTimes(archives, from: low, to: high, epoch: epoch)

        // `max`/`min` over the two candidates: the union takes the CLOSEST instant on each side, so
        // each reported gap can only shrink. `compactMap` keeps a nil store answer from winning.
        let last = [storedLastBeforeStart, inReach.filter { $0 < inBedStart }.max()]
            .compactMap { $0 }.max()
        let first = [storedFirstAfterEnd, inReach.filter { $0 > inBedEnd }.min()]
            .compactMap { $0 }.min()
        let earliest = [storedEarliestRetained, inReach.min()].compactMap { $0 }.min()

        return Edges(inBedStart: inBedStart,
                     inBedEnd: inBedEnd,
                     lastMeasurementBeforeStart: last,
                     firstMeasurementAfterEnd: first,
                     earliestRetainedMeasurement: earliest,
                     archiveEpochsInReach: inReach.count,
                     archiveMovedAnEdge: last != storedLastBeforeStart
                        || first != storedFirstAfterEnd
                        || earliest != storedEarliestRetained)
    }
}

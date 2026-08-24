// A NIGHT SCORED AGAINST A SHORTER ARCHIVE MUST NOT KEEP A HOLE THE ARCHIVE HAS SINCE FILLED.
//
// 🟢 THE DEFECT, MEASURED (2026-08-24, Gen 2 Air FR04.009, ring …59F91, Europe/Paris — the tester
// who wrote "I got up to go to the bathroom, and the app assumed that I didn't go back to sleep").
// She corrected her wake at 06:50 local. At that instant the newest record in the epoch archive was
// 02:42:47, so `SleepEdit.recompute` scored the whole span after it as `.asserted` — "we can prove
// no records exist here" — and stored 14323 s of it under one `.asleepCore` label.
//
// Her export, pulled at 07:42 local (~50 min later), holds NINE further 0x4c records at 02:48:53 ·
// 02:51:23 · 02:53:53 · 02:56:23 · 02:58:53 · 03:01:23 · 03:03:53 · 03:06:23 · 03:08:53, delivered
// by drains at 04:53:46Z / 04:59:32Z / 05:08:00Z. Contiguous at the 150 s cadence, they merge into
// one span 02:48:53 → 03:11:23 — **1350 s of the "proven hole" was measurable data the app held
// under an hour after she saved.** (Re-derived from `epochArchive.recordsBase64` in
// `opencircuit-night-2026-08-24.json`; the same records bound the exported `coverage.gaps` pair
// 516 s / 12907 s, while the frozen `provenanceSummary` still reports one 14323 s
// `longestUnmeasuredGapSec`.)
//
// Nothing re-derived it. `HealthKitWriter.mirrorSettledNight` returns `.unchanged` for any
// `isManuallyEdited` row (correctly — that guard is what stops an ordinary re-drain overwriting her
// edit), and `LocalStore.pendingSleepEditHealthWrites` recovers coverage via
// `MeasuredCoverage.fromProvenanceLabels`, which by its own doc comment "can only repeat" a hole.
// So the label was frozen at the moment of Save, permanently, and the arrival of the records that
// disproved it changed nothing.
//
// WHAT THIS FILE DOES, AND THE ONE DIRECTION IT MOVES IN. Given a stored hypnogram and a FRESHER
// record set, it re-labels PROVEN-UNMEASURED spans that now have records under them — and nothing
// else. It never moves an edge, never changes a stage, never touches a span the user's edit placed,
// and can only ever move a label toward MORE measurement.
//
// ⚠️ THAT ASYMMETRY IS THE WHOLE SAFETY ARGUMENT, and it is deliberate. `MeasuredCoverage.trusted`
// exists because ABSENCE of records is only evidence when our record set could have held them —
// retention read as absence published 0.0 asleep-minutes to Apple Health where the shipped build
// published 403.0. This pass consumes PRESENCE only. Retention can delete records; it cannot invent
// them. So a records-present verdict needs no proof horizon, and because no label here can ever move
// toward "less measured", this pass cannot express a shrink at all — the 403→0 failure is not
// merely avoided, it is unreachable through this code.
//
// Pure (no Apple frameworks, no store) so it unit-tests on the CLI and the app and a test agree by
// construction.

import Foundation

public enum SleepProvenanceRederivation {

    /// Re-label a stored night's `.asserted` spans against a record set that has GROWN since they
    /// were scored. Extend-only: `.asserted` becomes `.assertedOverMeasured` exactly where records
    /// now exist, split at the coverage boundaries; every other segment is returned untouched.
    ///
    /// `.assertedOverMeasured` — not `.measured` — because the STAGE is still the wearer's: it is
    /// the label `SleepEdit.provenance(for: .measured)` would have produced had `recompute` run with
    /// today's archive, which is precisely the claim this function is making ("what the primary path
    /// would say now"). Getting it wrong in the other direction would erase the fact that she, not
    /// the ring, called this ground sleep.
    ///
    /// - Parameter coverage: a RAW (un-`trusted`) coverage built from record timestamps. Raw is
    ///   correct here and the guard would be meaningless: with `provenFrom == .distantPast`,
    ///   `partition` only ever answers `.measured` or `.unmeasured`, and only `.measured` changes
    ///   anything. A `trusted` set is still safe to pass — `.unknown` falls through the `default`
    ///   below and leaves the stored label exactly as it was.
    /// - Returns: the upgraded segments, or `nil` when NOTHING changed — so a caller persists (and
    ///   re-writes Apple Health) only on a real change, and a second run over the same archive is a
    ///   no-op rather than a churn.
    public static func upgraded(_ segments: [SleepSegment],
                                against coverage: MeasuredCoverage) -> [SleepSegment]? {
        guard !coverage.isEmpty else { return nil }
        var out: [SleepSegment] = []
        out.reserveCapacity(segments.count)
        var changed = false

        for segment in segments {
            guard segment.provenance.isProvenUnmeasured, segment.end > segment.start else {
                out.append(segment)
                continue
            }
            let pieces = coverage.partition(segment.start ..< segment.end)
            guard pieces.contains(where: { $0.ground == .measured }) else {
                out.append(segment)          // still a hole under today's records — leave it alone
                continue
            }
            changed = true
            // `partition` tiles the span exactly, so re-emitting the pieces preserves the segment's
            // start, end and stage to the second. No minute of the wearer's night can be dropped or
            // duplicated by this loop.
            for piece in pieces {
                let provenance: SleepProvenance
                switch piece.ground {
                case .measured:  provenance = .assertedOverMeasured
                case .unmeasured, .unknown: provenance = segment.provenance
                }
                out.append(SleepSegment(start: piece.range.lowerBound, end: piece.range.upperBound,
                                        stage: segment.stage, provenance: provenance))
            }
        }
        return changed ? out : nil
    }

    /// Asleep seconds this upgrade moves out of the asserted bucket — the quantity to breadcrumb, and
    /// the one a reviewer can check against a device export. 0 when nothing moved.
    ///
    /// Computed from the two breakdowns rather than from the diff so it can never disagree with the
    /// numbers the row will actually store.
    public static func upgradedAsleepSeconds(before: [SleepSegment],
                                             after: [SleepSegment]) -> TimeInterval {
        let b = SleepProvenanceBreakdown(segments: before)
        let a = SleepProvenanceBreakdown(segments: after)
        return max(0, b.assertedAsleep - a.assertedAsleep)
    }
}

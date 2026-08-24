// THE STAGING MONOTONICITY HARNESS — does ONE more epoch record ever DESTROY a staged night?
//
//   cd ios/OpenCircuitKit && \
//     OC_SLEEP_MONOTONICITY_CORPUS=<corpus-dir> swift test --filter SleepStagingMonotonicityTests
//
// WHY THIS EXISTS. Every other entry point in this harness stages each corpus night EXACTLY ONCE,
// from the whole .b64. That measures where staging puts the edges; it cannot see the failure class
// where the SAME night stages fine at one archive size and returns NOTHING at the next — which is
// what a wearer actually experiences, because the archive grows one drain at a time and the card is
// re-rendered from whatever the latest re-stage produced. A confirmed instance is in the corpus this
// was built on: `tester2-gen2-2026-08-24` stages a 463-minute night through the record at 04:45:11
// local and ZERO segments the moment the 04:47:41 record joins the archive.
//
// So this file replays each night at INCREASING record cutoffs — the archive as it stood after the
// first N records had been ingested — and reports staged asleep minutes as a function of N.
//
// ── WHAT IS ASSERTED, AND WHY IT IS NOT PLAIN MONOTONICITY ───────────────────────────────────────
// "Staged asleep minutes never decrease as records are added" is TOO STRONG, and asserting it would
// make this file fail for honest reasons. Three of them, all real in this pipeline and all three
// MEASURED on the corpus below rather than supposed:
//
//   1. A later record can legitimately REVEAL that earlier "sleep" was awake. The stage thresholds
//      in `SleepStaging` are PERCENTILES over the night's own distribution (deepHRPercentile /
//      remHRPercentile, `SleepStaging.Tuning`), so extending the window re-fits them over a
//      different sample. docs/SLEEP_REPLAY_HARNESS.md §7a measured REM RISING inside a strictly
//      SMALLER window for the same reason, in the other direction. Measured here: `tester1` and
//      `tester2` each take several −3 to −28 min steps mid-night and recover them a record later.
//   2. `EpochArchive.merge` prunes to the 30 h retention window relative to the NEWEST record, so a
//      growing prefix can drop records off the FRONT. That is production behaviour, not an artifact
//      of this sweep — the device archive does the same thing — but it means a prefix's union is not
//      a superset of the previous prefix's union once the span passes 30 h.
//   3. THE NIGHT ROLLS OVER. `BulkSleep.latestNightRecords` scopes to the most recent night, so the
//      moment the archive gains the FIRST record of the next night the staged minutes stop
//      describing last night at all. Measured on `tester1-gen2air-2026-08-24`: 485 min → 60 min in
//      one step at cutoff 704, when the 08-23 23:45:17 record arrived 14.6 h after the previous
//      night's in-bed end of 09:06:55. That is the largest decrease in the corpus and it is
//      completely correct behaviour.
//
// What is NOT explainable by any of those is a COLLAPSE: a staged night going to exactly ZERO with
// the SAME night still being the one in scope. Zero is not a re-fit and not a rollover — it is the
// overnight-envelope gate (`RingSession :1613`) returning `[]` for a night it accepted one record
// earlier, i.e. the whole night ceasing to exist. That is the property asserted here.
//
// Neither of the two numbers the collapse rule uses is a tolerance invented for this file; both are
// production constants, so "make the test pass by nudging the threshold" is not available:
//   • the floor is `ActivityPeriod.minSleepDuration` (60 min) — the pipeline's OWN definition of
//     "there is a stageable night here" (`BulkSleep.swift:972` filters night blocks by it), so a
//     prefix that staged at least that much had, by the pipeline's own judgement, a night;
//   • the rollover exemption is `BulkSleep.maxIntraNightGap` (6 h) — the pipeline's OWN definition
//     of "these records belong to DIFFERENT nights". A record inside that distance of the staged
//     in-bed end is the same night by the code's own rule, so a zero there is a deletion.
// Exempted rollovers are PRINTED, not silently dropped: read them before quoting a green run.
//
// ⚠️ The rollover exemption is UNEXERCISED on the corpus it was written against — measured: both
// nights report "0 exempted rollover(s)". `tester1`'s rollover is real but lands on 60 min rather
// than 0, so it never reaches the zero test at all; the exemption exists because that same rollover
// arriving one record earlier or later WOULD reach zero, not because a zero rollover was observed.
// Treat it as reasoned-from-the-constant, not measured, until a corpus night exercises it.
//
// Every decrease of ANY size is measured and printed regardless, so a "fix" that merely RESHUFFLES
// a collapse into a large-but-nonzero drop is visible in the table rather than hidden by the
// assertion. Read `worst drop` in the per-night summary before quoting this test as green.
//
// ⚠️ This test is EXPECTED TO FAIL on master as of 2026-08-24 — that is the point of it. Do not
// weaken the assertion to make it pass; the lane that fixes the collapse turns it green.

import XCTest
@testable import OpenCircuitKit

final class SleepStagingMonotonicityTests: XCTestCase {

    /// One replay of one prefix of one night's records.
    private struct Step {
        let cutoff: Int          // number of leading records fed in
        let lastRecord: Date?    // timestamp of the newest record in that prefix
        let unionCount: Int      // after EpochArchive.merge's 30 h retention prune
        let nightCount: Int      // after BulkSleep.latestNightRecords
        let asleepMin: Int
        let inBedStart: Date?
        let inBedEnd: Date?
    }

    /// What one step's DECREASE is.
    private enum Verdict {
        case none               // no decrease, or a decrease that stayed non-zero (a re-fit)
        case rollover           // went to zero, but the added record starts a DIFFERENT night
        case collapse           // went to zero with the same night still in scope — the defect
    }

    /// Sweep EVERY record index. Measured cost on the two-night corpus this was built against
    /// (784 + 707 records): 72 s for the pair, so there is no reason to stride and risk stepping
    /// OVER the single record that destroys a night. If a future corpus makes this too slow,
    /// stride — but say so in the printed header, because a stride turns "the first regressing
    /// record" into "the first regressing BLOCK of records".
    private static let stride = 1

    func testAddingOneRecordNeverDestroysAStagedNight() throws {
        let dir = try SleepReplay.requireCorpus(
            "OC_SLEEP_MONOTONICITY_CORPUS",
            purpose: "the staging MONOTONICITY sweep (SleepStagingMonotonicityTests)",
            consequence: "This is the only check in the repo that stages the same night more than "
                       + "once; unrun, nothing here can tell a fix for the collapse defect from a "
                       + "re-shuffle of it.")
        let nights = try SleepReplay.loadManifest(at: dir)

        print("\n=== SLEEP STAGING MONOTONICITY — \(dir.path)")
        print("=== \(nights.count) manifest row(s), stride \(Self.stride) record(s) per step")
        print("=== each step = SleepReplay.stage(records: <first N records>) at the shipped default "
              + "(observedGapAbsorbCoverageCut = \(BulkSleep.observedGapAbsorbCoverageCut))")
        print("=== collapse floor \(Int(ActivityPeriod.minSleepDuration / 60)) min "
              + "(ActivityPeriod.minSleepDuration) · rollover exemption "
              + "\(Int(BulkSleep.maxIntraNightGap / 3600)) h (BulkSleep.maxIntraNightGap)\n")

        var collapses: [String] = []
        var replayed = 0

        for night in nights {
            let records: [BulkRecord]
            do { records = try SleepReplay.loadRecords(night, in: dir) }
            catch SleepReplay.ReplayError.noRecords { continue }   // summary-only manifest row
            guard let anchor = records.first?.date() else { continue }
            replayed += 1

            let steps = try SleepReplay.withTimeZone(night.timeZone, at: anchor) {
                Swift.stride(from: Self.stride, through: records.count, by: Self.stride).map { n -> Step in
                    let prefix = Array(records.prefix(n))
                    let staged = SleepReplay.stage(
                        records: prefix,
                        temperatures: night.temperatures.map { TemperatureSample(time: $0.t, celsius: $0.c) },
                        deepHRBaseline: night.deepHRBaselineBPM)
                    let segs = staged.segments
                    return Step(cutoff: n,
                                lastRecord: prefix.last?.date(),
                                unionCount: staged.union.count,
                                nightCount: staged.nightRecords.count,
                                asleepMin: SleepStaging.summary(segs).minutes.asleep,
                                inBedStart: segs.map(\.start).min(),
                                inBedEnd: segs.map(\.end).max())
                }
            }

            report(night: night, records: records.count, steps: steps)
            collapses += findings(night: night, steps: steps)
        }

        XCTAssertGreaterThan(replayed, 0,
                             "no corpus night carried records — the sweep measured NOTHING and this "
                             + "green tick would be backed by zero replays")
        XCTAssertEqual(collapses, [],
                       "a staged night was DESTROYED by adding records to the archive:\n"
                       + collapses.joined(separator: "\n")
                       + "\n\nStaging returned segments at one archive size and NOTHING at the next, "
                       + "with the same night still in scope. On device this is a wearer whose night "
                       + "disappears from the card as the archive fills. Do NOT satisfy this by "
                       + "moving the floor or widening the rollover exemption — both are production "
                       + "constants. A fix has to KEEP the night, and the per-night table above says "
                       + "whether a candidate fixed it or only made the drop smaller.")
    }

    // MARK: - Classification

    /// Is this step's fall to zero the defect, or the next night arriving?
    ///
    /// `BulkSleep.maxIntraNightGap` is the pipeline's own answer to "same night or not": blocks
    /// further apart than this are different nights (`BulkSleep.swift:890`). So a record landing
    /// within that distance of the staged in-bed END belongs to the night that was just staged, and
    /// a zero there means that night was deleted rather than superseded.
    private func verdict(previous p: Step, current s: Step) -> Verdict {
        guard s.asleepMin == 0,
              p.asleepMin >= Int(ActivityPeriod.minSleepDuration / 60),
              let end = p.inBedEnd, let added = s.lastRecord else { return .none }
        return added.timeIntervalSince(end) > BulkSleep.maxIntraNightGap ? .rollover : .collapse
    }

    // MARK: - Reporting

    /// A row per CHANGE in staged asleep minutes, plus the first and last step. Printing all ~700
    /// steps per night would bury the two that matter.
    private func report(night: ReplayNight, records: Int, steps: [Step]) {
        let tz = night.timeZone
        print("--- \(night.id)   \(night.ring ?? "?")  build \(night.appBuild ?? "?")  "
              + "\(records) records, \(steps.count) replays")
        print("    cutoff  lastRecord        union  night  asleep   Δ   inBedStart     inBedEnd")

        func right(_ v: String, _ n: Int) -> String {
            v.count >= n ? v : String(repeating: " ", count: n - v.count) + v
        }
        func line(_ s: Step, _ delta: Int?, _ mark: String) {
            print("  \(mark)\(right(String(s.cutoff), 6))  "
                  + SleepReplay.clock(s.lastRecord, tz).padding(toLength: 16, withPad: " ", startingAt: 0)
                  + "  \(right(String(s.unionCount), 5))  \(right(String(s.nightCount), 5))  "
                  + "\(right(String(s.asleepMin), 6))  "
                  + right(delta.map { ($0 > 0 ? "+" : "") + String($0) } ?? "·", 5) + "  "
                  + SleepReplay.clock(s.inBedStart, tz).padding(toLength: 14, withPad: " ", startingAt: 0)
                  + " " + SleepReplay.clock(s.inBedEnd, tz))
        }

        var previous: Step?
        var worstDrop = 0
        var worstDropAt: Step?
        var firstDropAt: Step?
        var decreases = 0
        var rollovers = 0
        for (i, s) in steps.enumerated() {
            let delta = previous.map { s.asleepMin - $0.asleepMin }
            let call = previous.map { verdict(previous: $0, current: s) } ?? .none
            if call == .rollover { rollovers += 1 }
            if let d = delta, d < 0 {
                decreases += 1
                if firstDropAt == nil { firstDropAt = s }
                if -d > worstDrop { worstDrop = -d; worstDropAt = s }
            }
            let changed = delta.map { $0 != 0 } ?? true
            if changed || i == 0 || i == steps.count - 1 {
                let mark: String
                switch call {
                case .collapse: mark = "!! "
                case .rollover: mark = " ⟳ "
                case .none:     mark = (delta ?? 0) < 0 ? " ↓ " : "   "
                }
                line(s, delta, mark)
            }
            previous = s
        }
        func at(_ s: Step?) -> String {
            s.map { " at cutoff \($0.cutoff) (\(SleepReplay.clock($0.lastRecord, tz)))" } ?? ""
        }
        print("    peak asleep \(steps.map(\.asleepMin).max() ?? 0) min · "
              + "final \(steps.last?.asleepMin ?? 0) min · \(decreases) decreasing step(s) · "
              + "first drop\(at(firstDropAt)) · worst drop \(worstDrop) min\(at(worstDropAt)) · "
              + "\(rollovers) exempted rollover(s)")
        print("    ↓ = staged asleep minutes fell as records were ADDED.  ⟳ = fell to zero because "
              + "the NEXT night arrived (exempt, see the header).  !! = fell to zero with the same "
              + "night in scope — the collapse this file asserts against.\n")
    }

    /// Every collapse, rendered as the two archive states that bracket it so the failure names the
    /// offending record. Rollovers are reported in the table above and deliberately not returned.
    private func findings(night: ReplayNight, steps: [Step]) -> [String] {
        let tz = night.timeZone
        var out: [String] = []
        var previous: Step?
        for s in steps {
            defer { previous = s }
            guard let p = previous, verdict(previous: p, current: s) == .collapse else { continue }
            let gap = s.lastRecord.flatMap { added in p.inBedEnd.map { added.timeIntervalSince($0) } } ?? 0
            out.append("""
                  \(night.id): \(p.asleepMin) staged asleep minutes → 0 when the archive grew from \
                \(p.cutoff) to \(s.cutoff) records.
                    kept through  \(SleepReplay.clock(p.lastRecord, tz)) → in-bed \
                \(SleepReplay.clock(p.inBedStart, tz)) .. \(SleepReplay.clock(p.inBedEnd, tz)) \
                (union \(p.unionCount), night-scoped \(p.nightCount))
                    destroyed at  \(SleepReplay.clock(s.lastRecord, tz)) → staging returned NO \
                segments (union \(s.unionCount), night-scoped \(s.nightCount))
                    the added record sits \(Int(gap)) s past that in-bed end, well inside \
                BulkSleep.maxIntraNightGap (\(Int(BulkSleep.maxIntraNightGap)) s), so it is the SAME \
                night by the pipeline's own rule — not a rollover.
                """)
        }
        return out
    }
}

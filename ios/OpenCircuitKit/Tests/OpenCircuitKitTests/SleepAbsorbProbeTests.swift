// BACKWARD-CLUSTER-CHAIN PROBE — measure, on every corpus night, WHAT the backward absorb in
// `BulkSleep.latestNightRecords` (:1010-1015) actually bridges before changing it.
//
// WHY. Candidate 1 proposes declining the backward absorb when the bridged gap is FULL OF OBSERVED
// ACTIVE EPOCHS (Juan's 43-min evening gap) while keeping it for an EMPTY UNOBSERVED HOLE (the
// multi-drain stitch the chain exists for, `BulkSleep.swift:1005-1009`). Whether that is safe is an
// empirical question: if real nights are routinely stitched across DENSELY OBSERVED gaps (a genuine
// mid-night awakening with the ring on the finger), the rule would truncate them. This probe answers
// it from the corpus instead of from argument.
//
// It touches NO production source. It re-walks the same steps `latestNightRecords` does, using the
// public/@testable API, and prints one line per bridge. If the walk ever disagrees with production's
// own scoping, `testProbeAgreesWithProduction` fails — the probe is not allowed to drift.
//
//   cd ios/OpenCircuitKit && OC_SLEEP_CORPUS=<corpus-dir> swift test --filter SleepAbsorbProbeTests

import XCTest
@testable import OpenCircuitKit

final class SleepAbsorbProbeTests: XCTestCase {

    struct Bridge {
        var candidateStart: Date
        var candidateEnd: Date
        var gapSec: Double
        var recordsInGap: Int
        var expectedInGap: Double
        var coverage: Double
        var movedClusterStart: Bool
        var newClusterStart: Date
    }

    struct Walk {
        var anchorStart: Date
        var anchorEnd: Date
        var nightBlocks: Int
        var usedPass2: Bool
        var bridges: [Bridge]
        var clusterStartBeforeClip: Date
        var clusterStartAfterClip: Date
    }

    /// A transcription of `BulkSleep.latestNightRecords`'s pass-1/pass-2 + backward chain, with the
    /// per-bridge evidence exposed. Deliberately duplicated rather than refactored out of production
    /// so the baseline stays byte-identical while this runs.
    static func walk(_ records: [BulkRecord], temperatures: [TemperatureSample]) -> Walk? {
        let epoch = Command.syncEpoch
        let records = records.sorted { $0.counter < $1.counter }
        let periods = ActivityPeriod.detectFromMotion(
            BulkSleep.motionTimeline(from: records, epoch: epoch),
            temperatureSamples: temperatures,
            heartRateSamples: BulkSleep.heartRateTimeline(from: records, epoch: epoch),
            sleepVitalTimes: BulkSleep.sleepVitalTimeline(from: records, epoch: epoch))
        let sleepBlocks = periods.filter {
            $0.activity == .sleep && $0.duration > ActivityPeriod.minSleepDuration
        }
        var usedPass2 = false
        var nights = sleepBlocks.filter { SleepWindow.isOvernightBlock(start: $0.start, end: $0.end) }
        if nights.isEmpty {
            usedPass2 = true
            nights = sleepBlocks.filter {
                SleepWindow.isOvernightBlock(
                    start: $0.start, end: $0.end,
                    onsetIsUnobserved: BulkSleep.onsetIsUnobserved(
                        DateInterval(start: $0.start, end: max($0.end, $0.start)),
                        in: records, epoch: epoch))
            }
        }
        guard let anchor = nights.max(by: { $0.end < $1.end }) else { return nil }

        let times = records.map { $0.date(epoch: epoch) }
        var clusterStart = anchor.start
        var bridges: [Bridge] = []
        for p in nights.sorted(by: { $0.start > $1.start }) where p.end <= anchor.end {
            let gap = clusterStart.timeIntervalSince(p.end)
            guard gap <= BulkSleep.maxIntraNightGap else { continue }
            // Records strictly INSIDE the bridged gap (p.end, clusterStart).
            let inGap = times.filter { $0 > p.end && $0 < clusterStart }.count
            let expected = max(gap / Double(BulkRecord.epochSeconds), 0)
            let moved = min(clusterStart, p.start) < clusterStart
            let next = min(clusterStart, p.start)
            bridges.append(Bridge(candidateStart: p.start, candidateEnd: p.end,
                                  gapSec: gap, recordsInGap: inGap, expectedInGap: expected,
                                  coverage: expected > 0 ? Double(inGap) / expected : 1.0,
                                  movedClusterStart: moved, newClusterStart: next))
            clusterStart = next
        }
        let beforeClip = clusterStart
        let afterClip = max(clusterStart, anchor.end.addingTimeInterval(-BulkSleep.maxNightSpan))
        return Walk(anchorStart: anchor.start, anchorEnd: anchor.end, nightBlocks: nights.count,
                    usedPass2: usedPass2, bridges: bridges,
                    clusterStartBeforeClip: beforeClip, clusterStartAfterClip: afterClip)
    }

    func testProbeBackwardAbsorbAcrossCorpus() throws {
        guard let dir = SleepReplay.dir("OC_SLEEP_CORPUS") else {
            print("SKIP SleepAbsorbProbeTests — set OC_SLEEP_CORPUS to a corpus directory")
            return
        }
        let nights = try SleepReplay.loadManifest(at: dir)
        var lines: [String] = []
        lines.append("=== BACKWARD-CLUSTER-CHAIN PROBE ===")
        lines.append("cov = observed records in the bridged gap / expected at 150 s cadence")
        lines.append("")
        var firing = 0, movingBridges = 0
        var covOfMoving: [Double] = []
        for n in nights where !n.recordsFile.isEmpty {
            let recs = try SleepReplay.loadRecords(n, in: dir)
            let temps = n.temperatures.map { TemperatureSample(time: $0.t, celsius: $0.c) }
            let anchorInstant = recs.first?.date() ?? Date()
            try SleepReplay.withTimeZone(n.timeZone, at: anchorInstant) {
                guard let w = Self.walk(recs, temperatures: temps) else {
                    lines.append("\(n.id): no night block")
                    return
                }
                let tz = n.timeZone
                lines.append("\(n.id)  anchor \(SleepReplay.clock(w.anchorStart, tz)) -> "
                             + "\(SleepReplay.clock(w.anchorEnd, tz))  nightBlocks=\(w.nightBlocks)"
                             + (w.usedPass2 ? "  [pass2]" : ""))
                if w.bridges.isEmpty { lines.append("      (no backward bridge considered)") }
                for b in w.bridges {
                    firing += 1
                    if b.movedClusterStart {
                        movingBridges += 1
                        covOfMoving.append(b.coverage)
                    }
                    lines.append(String(format:
                        "      cand %@ -> %@  gap %6.1f min  recs %3d / %6.1f  cov %.3f  %@",
                        SleepReplay.clock(b.candidateStart, tz),
                        SleepReplay.clock(b.candidateEnd, tz),
                        b.gapSec / 60, b.recordsInGap, b.expectedInGap, b.coverage,
                        b.movedClusterStart
                            ? "MOVES clusterStart -> \(SleepReplay.clock(b.newClusterStart, tz))"
                            : "no-op"))
                }
                if w.clusterStartAfterClip != w.clusterStartBeforeClip {
                    lines.append("      head clip: \(SleepReplay.clock(w.clusterStartBeforeClip, tz))"
                                 + " -> \(SleepReplay.clock(w.clusterStartAfterClip, tz))")
                }
            }
        }
        lines.append("")
        lines.append("bridges considered \(firing); bridges that MOVED clusterStart \(movingBridges)")
        if !covOfMoving.isEmpty {
            let sorted = covOfMoving.sorted()
            lines.append(String(format: "coverage of MOVING bridges: min %.3f  median %.3f  max %.3f",
                                sorted.first!, sorted[sorted.count / 2], sorted.last!))
            lines.append("all coverages: " + sorted.map { String(format: "%.3f", $0) }.joined(separator: ", "))
        }
        let out = lines.joined(separator: "\n")
        print(out)
        if let path = ProcessInfo.processInfo.environment["OC_SLEEP_PROBE_OUT"], !path.isEmpty {
            try out.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    /// The probe must reproduce production's own night scoping, or its evidence is worthless.
    ///
    /// Compared against production AT CUT 0. `walk` deliberately transcribes the UNGUARDED backward
    /// chain — that is the whole point of the probe: it enumerates every bridge the chain *considers*
    /// and the coverage of each, which is the evidence the cut is chosen from. Comparing it against
    /// the guarded default would compare two different algorithms and the anti-drift guarantee would
    /// mean nothing. (Measured: at the shipped default this disagrees on exactly the 2 nights the
    /// guard moves, R3_2026-08-12 and R3_2026-08-19 — i.e. the intended behaviour change.)
    func testProbeAgreesWithProduction() throws {
        guard let dir = SleepReplay.dir("OC_SLEEP_CORPUS") else {
            print("SKIP — set OC_SLEEP_CORPUS")
            return
        }
        var checked = 0
        for n in try SleepReplay.loadManifest(at: dir) where !n.recordsFile.isEmpty {
            let recs = try SleepReplay.loadRecords(n, in: dir)
            let union = EpochArchive.merge(existing: [], incoming: recs)
            let temps = n.temperatures.map { TemperatureSample(time: $0.t, celsius: $0.c) }
            try SleepReplay.withTimeZone(n.timeZone, at: recs.first?.date() ?? Date()) {
                let prod = BulkSleep.latestNightRecords(from: union, temperatures: temps,
                                                        observedGapCoverageCut: 0)
                guard let w = Self.walk(union, temperatures: temps) else {
                    // No night: production returns the records unchanged.
                    XCTAssertEqual(prod.count, union.count, "\(n.id): no-night case must pass through")
                    return
                }
                // Reproduce the production slice from the walk (backward chain + head clip +
                // the morning-continuation absorb, which the walk does not model) — assert only
                // the LOWER edge, which is what this candidate touches.
                let lo = w.clusterStartAfterClip.addingTimeInterval(-30 * 60)
                let expectedLo = union.filter { $0.date() >= lo }.first?.date()
                XCTAssertEqual(prod.first?.date(), expectedLo,
                               "\(n.id): probe's cluster start disagrees with production's slice")
                checked += 1
            }
        }
        print("probe/production agreement checked on \(checked) night(s)")
    }
}

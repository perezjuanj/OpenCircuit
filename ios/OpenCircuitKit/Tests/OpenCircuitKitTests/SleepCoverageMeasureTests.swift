// COVERAGE MEASUREMENT — score `SleepConfidence.assess` against every staged night of a corpus,
// using the SHIPPED Swift, and print the before/after scoreboard in one run.
//
//   cd ios/OpenCircuitKit && \
//     OC_SLEEP_COVERAGE_CORPUS=<corpus-dir> \
//     swift test --filter SleepCoverageMeasureTests 2>&1 | sed -n '/SLEEP COVERAGE/,$p'
//
// Staging comes from `SleepReplay.measure` — the transcription documented at the top of
// SleepReplay.swift — so the detected windows here are the same ones `baseline.tsv` carries. Nothing
// in this file touches a production source.
//
// HOW THE ACQUISITION EVIDENCE IS BUILT, and the one place it differs from a device.
// A corpus night is a fixed noon-to-noon slice of ONE capture artifact; the device's store is
// continuous. So the "was there a record after the night ended?" question is answered against the
// RING-WIDE union of every .b64 for that ring, not just the night's own file. Presence in that union
// is proof the ring recorded then; ABSENCE is not proof of anything, because a different artifact
// may simply not cover those hours. A 12 h HORIZON encodes that: past it, the harness passes `nil`
// and the classifier answers `.unknown`, which is the honest verdict for "we cannot tell". On device
// there is no horizon — the archive is continuous — so the firing rates below are LOWER BOUNDS.
//
// ⚠️ An unset OC_SLEEP_COVERAGE_CORPUS SKIPS, it does not pass. Read the run summary for
// "1 test skipped"; a `passed` line means the corpus was really opened.

import XCTest
@testable import OpenCircuitKit

final class SleepCoverageMeasureTests: XCTestCase {

    /// Beyond this, the next record in the corpus belongs to a different capture artifact and its
    /// absence proves nothing about the ring. A property of the CORPUS, never of the classifier.
    private static let horizon: TimeInterval = 12 * 3600

    /// A night is BAD when its worst measured edge error is at least this. Same cut the campaign
    /// used, so the numbers here can be compared with it directly.
    private static let badEdgeMinutes = 60.0

    private struct Row {
        let id: String, ring: String, gen: String
        let labelled: Bool
        let worstErrMin: Double?
        let inBedMin: Int, efficiency: Double
        /// The night's totals in SECONDS, straight out of `SleepStaging.summary` — never
        /// reconstructed from the rounded minutes, or a night could cross a threshold on rounding.
        let asleepSec: TimeInterval, inBedSec: TimeInterval
        let coverage: SleepConfidence.Coverage
        let holeBefore: TimeInterval?, holeAfter: TimeInterval?
        let legacy: SleepConfidence.Level
    }

    func testMeasureCoverageAcrossCorpus() throws {
        guard let dir = SleepReplay.dir("OC_SLEEP_COVERAGE_CORPUS") else {
            throw XCTSkip("OC_SLEEP_COVERAGE_CORPUS unset — point it at a corpus directory. "
                          + "This is a SKIP, not a pass: nothing was measured.")
        }
        let manifestURL = dir.appendingPathComponent("manifest.json")
        let raw = try JSONSerialization.jsonObject(with: try Data(contentsOf: manifestURL))
        guard let root = raw as? [String: Any], let rawRows = root["nights"] as? [[String: Any]] else {
            return XCTFail("manifest.json has no `nights` array")
        }
        let nights = try SleepReplay.loadManifest(at: dir)
        XCTAssertEqual(nights.count, rawRows.count, "manifest row count changed under us")

        // --- ring-wide union of every record instant, per ring
        var union: [String: [Date]] = [:]
        for rawRow in rawRows {
            guard let file = rawRow["recordsFile"] as? String, !file.isEmpty,
                  let ring = rawRow["ringId"] as? String else { continue }
            let text = try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = Data(base64Encoded: text, options: .ignoreUnknownCharacters) else {
                return XCTFail("bad base64 in \(file)")
            }
            union[ring, default: []].append(contentsOf: EpochArchive.decode(data).map { $0.date() })
        }
        for k in union.keys { union[k] = Array(Set(union[k]!)).sorted() }

        // --- one row per staged night
        var rows: [Row] = []
        for (n, rawRow) in zip(nights, rawRows) where !n.recordsFile.isEmpty {
            let r = try SleepReplay.measure(n, in: dir)
            guard let start = r.inBedStart, let end = r.inBedEnd else { continue }
            guard let ring = rawRow["ringId"] as? String, let times = union[ring] else {
                return XCTFail("no ring union for \(n.id)")
            }

            // nearest record strictly outside each edge, withheld past the horizon
            let before = times.last { $0 < start }
            let after = times.first { $0 > end }
            let holeBefore = before.map { start.timeIntervalSince($0) }
            let holeAfter = after.map { $0.timeIntervalSince(end) }
            let usableBefore = (holeBefore.map { $0 <= Self.horizon } ?? false) ? before : nil
            let usableAfter = (holeAfter.map { $0 <= Self.horizon } ?? false) ? after : nil

            let coverage = SleepConfidence.Coverage(
                inBedStart: start,
                inBedEnd: end,
                lastMeasurementBeforeStart: usableBefore,
                firstMeasurementAfterEnd: usableAfter,
                // Withheld together with the predecessor: an undeterminable leading edge must read
                // `.unknown`, not `.noPriorMeasurement` (which the horizon would otherwise fake).
                earliestRetainedMeasurement: usableBefore == nil ? nil : times.first)

            let labelled = (rawRow["isLabelled"] as? Bool) ?? false
            let labStart = try SleepReplay.date(rawRow["editedInBedStart"] as? String)
            let labEnd = try SleepReplay.date(rawRow["editedInBedEnd"] as? String)
            func errMin(_ a: Date?, _ b: Date?) -> Double? {
                guard let a, let b else { return nil }
                return (a.timeIntervalSince(b) / 60).rounded()
            }
            let errs = [errMin(start, labStart), errMin(end, labEnd),
                        errMin(r.onset, n.label?.onset), errMin(r.wake, n.label?.wake)].compactMap { $0 }
            let summary = SleepStaging.summary(r.segments)      // RingSession :1876
            rows.append(Row(id: n.id, ring: ring,
                            gen: (rawRow["ringGeneration"] as? String) ?? "?",
                            labelled: labelled,
                            worstErrMin: errs.isEmpty ? nil : errs.map(abs).max(),
                            inBedMin: r.inBedMin, efficiency: r.efficiency,
                            asleepSec: summary.totalAsleep, inBedSec: summary.inBed,
                            coverage: coverage, holeBefore: holeBefore, holeAfter: holeAfter,
                            legacy: SleepConfidence.classify(summary)))
        }
        rows.sort { $0.id < $1.id }
        XCTAssertFalse(rows.isEmpty, "nothing staged — the measurement would be vacuous")

        // ---------------------------------------------------------------- report
        print("\n=== SLEEP COVERAGE — SleepConfidence.assess over \(dir.path)")
        print("=== \(rows.count) staged nights · materialGapSeconds "
              + "\(Int(WakeProvenance.materialGapSeconds)) · continuousTolerance "
              + "\(Int(WakeProvenance.continuousToleranceSeconds)) · horizon \(Int(Self.horizon / 3600)) h")

        print("\n--- TABLE 1: every staged night")
        print(pad("night", 16) + pad("gen", 11) + pad("lab", 4) + pad("worstErr", 9)
              + pad("inBed", 6) + pad("eff", 7) + pad("holeBefore", 11) + pad("holeAfter", 11)
              + pad("bedtime", 13) + pad("wake", 13) + pad("legacy", 10) + "reasons")
        for row in rows {
            let a = SleepConfidence.assess(asleep: row.asleepSec, inBed: row.inBedSec,
                                           coverage: row.coverage)
            print(pad(row.id, 16) + pad(row.gen, 11) + pad(row.labelled ? "Y" : "·", 4)
                  + pad(row.worstErrMin.map { String(format: "%.0f", $0) } ?? "—", 9)
                  + pad(String(row.inBedMin), 6)
                  + pad(String(format: "%.4f", row.efficiency), 7)
                  + pad(mins(row.holeBefore), 11) + pad(mins(row.holeAfter), 11)
                  + pad(short(row.coverage, verdict: a.bedtime), 13)
                  + pad(short(a.wake), 13)
                  + pad(row.legacy == .durationLikelyHigh ? "HIGH" : "·", 10)
                  + (a.reasons.isEmpty ? "—" : a.reasons.map(name).joined(separator: " + ")))
        }

        // ---- BEFORE / AFTER counts
        func assess(_ row: Row, cut: TimeInterval) -> SleepConfidence.Assessment {
            SleepConfidence.assess(asleep: row.asleepSec, inBed: row.inBedSec,
                                   coverage: row.coverage, materialGapSeconds: cut)
        }
        let before = rows.filter { $0.legacy == .durationLikelyHigh }
        let after = rows.filter { assess($0, cut: WakeProvenance.materialGapSeconds).flags }
        let acq = rows.filter { assess($0, cut: WakeProvenance.materialGapSeconds).hasAcquisitionReason }
        print("\n--- TABLE 2: how many nights say something")
        print("BEFORE  SleepConfidence.classify == .durationLikelyHigh : \(before.count)/\(rows.count)"
              + "  [\(before.map(\.id).joined(separator: ", "))]")
        print("AFTER   assess().flags (any reason at all)              : \(after.count)/\(rows.count)"
              + "  [\(after.map(\.id).joined(separator: ", "))]")
        print("        …of which ACQUISITION reasons                   : \(acq.count)/\(rows.count)"
              + "  [\(acq.map(\.id).joined(separator: ", "))]")

        // ---- what the CARD shows today, reproduced from the shipped guards rather than assumed.
        // `confidenceHint` (SleepCardView.swift:451-461) needs contiguity AND !isLikelyTruncated;
        // `bedtimeProvenanceHint` (:535-551) needs !isLikelyTruncated and renders EmptyView for
        // `.witnessed`/`.unknown`. `isLikelyTruncated` calls the real `SleepCaptureCoverage`.
        var cardDuration: [String] = [], cardBedtime: [String] = [], truncated: [String] = [],
            nonContiguous: [String] = []
        for row in rows {
            let a = assess(row, cut: WakeProvenance.materialGapSeconds)
            let wallSpan = row.coverage.inBedEnd.timeIntervalSince(row.coverage.inBedStart)
            let contiguous = row.inBedSec <= 0 || wallSpan <= row.inBedSec * 1.15
            // No corpus night carries a sleep schedule, which is exactly the device state for any
            // user who never set one — so nil, and `SleepCaptureCoverage` is asked, not assumed.
            let isTruncated = SleepCaptureCoverage.classify(capturedOnset: row.coverage.inBedStart,
                                                            capturedInBed: row.inBedSec,
                                                            scheduledBedtime: nil) == .likelyTruncated
            if isTruncated { truncated.append(row.id) }
            if !contiguous { nonContiguous.append(row.id) }
            if contiguous, !isTruncated, row.legacy == .durationLikelyHigh { cardDuration.append(row.id) }
            if !isTruncated, a.bedtime == .noPriorMeasurement { cardBedtime.append(row.id) }
            if !isTruncated, case .resumedAfterGap = a.bedtime { cardBedtime.append(row.id) }
        }
        let cardToday = Set(cardDuration).union(cardBedtime)
        print("\nCARD TODAY (shipped guards re-run, not assumed):")
        print("  confidenceHint fires        : \(cardDuration.count)/\(rows.count)  [\(cardDuration.joined(separator: ", "))]")
        print("  bedtimeProvenanceHint fires : \(cardBedtime.count)/\(rows.count)  [\(cardBedtime.sorted().joined(separator: ", "))]")
        print("  SleepCaptureCoverage == .likelyTruncated : \(truncated.count)/\(rows.count)")
        print("  contiguity guard fails      : \(nonContiguous.count)/\(rows.count)")
        print("  ⇒ SOME caveat today         : \(cardToday.count)/\(rows.count)")
        print("  ⇒ SOME caveat if the card renders assess().reasons instead : \(after.count)/\(rows.count)")
        let doubled = Set(rows.filter {
            let a = assess($0, cut: WakeProvenance.materialGapSeconds)
            return a.reasons.contains { if case .noRecordingBeforeBedtime = $0 { return true } else { return false } }
        }.map(\.id)).intersection(cardBedtime)
        print("  ⚠️ nights where the front-edge reason DOUBLES the shipped bedtime hint if both are"
              + " rendered: \(doubled.count)  [\(doubled.sorted().joined(separator: ", "))]")

        // ---- labelled cross-tab
        print("\n--- TABLE 3: the labelled nights (BAD = worst edge error >= \(Int(Self.badEdgeMinutes)) min)")
        print(pad("night", 16) + pad("worstErr", 9) + pad("verdict", 9)
              + pad("BEFORE", 8) + pad("AFTER-acq", 11) + "AFTER reasons")
        var tp = 0, fp = 0, fn = 0, beforeTP = 0, beforeFP = 0
        for row in rows where row.labelled {
            guard let err = row.worstErrMin else { continue }
            let bad = err >= Self.badEdgeMinutes
            let a = assess(row, cut: WakeProvenance.materialGapSeconds)
            let fires = a.hasAcquisitionReason
            if bad && fires { tp += 1 } else if !bad && fires { fp += 1 } else if bad { fn += 1 }
            if row.legacy == .durationLikelyHigh { bad ? (beforeTP += 1) : (beforeFP += 1) }
            print(pad(row.id, 16) + pad(String(format: "%.0f", err), 9) + pad(bad ? "BAD" : "GOOD", 9)
                  + pad(row.legacy == .durationLikelyHigh ? "HIGH" : "·", 8)
                  + pad(fires ? "FIRES" : "·", 11)
                  + (a.reasons.isEmpty ? "—" : a.reasons.map(name).joined(separator: " + ")))
        }
        print("BEFORE (durationLikelyHigh): TP \(beforeTP)  FP \(beforeFP)")
        print("AFTER  (acquisition)       : TP \(tp)  FP \(fp)  FN \(fn)")
        print("⚠️  every FP count here is out of ONE good labelled night. It is not a rate.")

        // ---- threshold sweep
        print("\n--- TABLE 4: materialGapSeconds sweep (acquisition firings)")
        print(pad("cut(min)", 10) + pad("fires/N", 10) + pad("lab TP", 8) + pad("lab FP", 8) + "nights")
        for cutMin in [0.0, 5.0, 6.0, 15.0, 30.0, 33.0, 45.0, 60.0, 120.0, 242.0, 300.0] {
            let cut = cutMin * 60
            let hit = rows.filter { assess($0, cut: cut).hasAcquisitionReason }
            let lab = hit.filter { $0.labelled }
            let t = lab.filter { ($0.worstErrMin ?? 0) >= Self.badEdgeMinutes }.count
            print(pad(String(format: "%.0f", cutMin), 10) + pad("\(hit.count)/\(rows.count)", 10)
                  + pad(String(t), 8) + pad(String(lab.count - t), 8)
                  + hit.map(\.id).joined(separator: ", "))
        }

        // ---- invariants
        for row in rows {
            let a = assess(row, cut: WakeProvenance.materialGapSeconds)
            XCTAssertEqual(a.level, row.legacy,
                           "\(row.id): coverage moved the legacy duration verdict")
            XCTAssertFalse(a.hasAcquisitionReason && a.reasons.contains(.durationLikelyHigh),
                           "\(row.id): opposite claims offered together")
            XCTAssertFalse(SleepConfidence.assess(asleep: row.asleepSec, inBed: row.inBedSec,
                                                  coverage: row.coverage,
                                                  materialGapSeconds: .infinity).hasAcquisitionReason,
                           "\(row.id): kill switch did not silence acquisition")
        }
        // The trap the campaign identified: a rule that fires everywhere is not a rule.
        XCTAssertLessThan(acq.count, rows.count / 2,
                          "an acquisition flag on half the corpus is noise, not information")
    }

    // MARK: formatting

    private func pad(_ s: String, _ w: Int) -> String {
        s.count >= w ? s + " " : s + String(repeating: " ", count: w - s.count)
    }
    /// Minutes, or `UNDET(…)` past the horizon — carrying the RAW distance so a reader can see that
    /// "undetermined" here means "the next capture artifact is days away", not "the ring was silent".
    private func mins(_ t: TimeInterval?) -> String {
        guard let t else { return "UNDET(none)" }
        return t > Self.horizon ? String(format: "UNDET(%.0fh)", t / 3600)
                                : String(format: "%.1f", t / 60)
    }
    private func short(_ v: WakeProvenance.Verdict) -> String {
        switch v {
        case .witnessed: return "witnessed"
        case .stoppedThenResumed(let g): return String(format: "stop %.0fm", g / 60)
        case .unknown: return "unknown"
        }
    }
    private func short(_ c: SleepConfidence.Coverage, verdict: BedtimeProvenance.Verdict) -> String {
        switch verdict {
        case .witnessed: return "witnessed"
        case .resumedAfterGap(let g): return String(format: "gap %.0fm", g / 60)
        case .noPriorMeasurement: return "noPrior"
        case .unknown: return "unknown"
        }
    }
    private func name(_ r: SleepConfidence.Reason) -> String {
        switch r {
        case .noRecordingAfterWake(_, let g): return String(format: "STOPPED@wake(%.0fm)", g / 60)
        case .noRecordingBeforeBedtime(_, let g): return String(format: "RESUMED@bed(%.0fm)", g / 60)
        case .durationLikelyHigh: return "durationLikelyHigh"
        }
    }
}

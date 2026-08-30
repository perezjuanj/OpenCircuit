// BASELINE EMITTER — run the replay harness over EVERY row of a corpus on unmodified master and
// write one machine-readable TSV. This is the scoreboard every candidate change is scored against,
// so it must be regenerable by one command and must contain no hand-entered number.
//
//   cd ios/OpenCircuitKit && \
//     OC_SLEEP_BASELINE_CORPUS=<corpus-dir> OC_SLEEP_BASELINE_OUT=<corpus-dir>/baseline.tsv \
//     swift test --filter SleepBaselineTests
//
// WHAT IT ADDS OVER `SleepReplayMeasureTests`. That entry point prints a fixed-width table for a
// human. This one emits every column an analysis needs — the manifest's own census fields
// (placeholder-motion share, layout counts, gaps, coverage, ring generation, firmware, label
// provenance) joined to the staged result — so that "is the blind motion channel what drives the
// big misses?" can be answered from a file instead of from a screenshot.
//
// PARITY. Staging comes from `SleepReplay.measure`, i.e. exactly the transcription documented at the
// top of SleepReplay.swift. NOTHING in this file touches a production source; it lives in the test
// target and reads the manifest JSON directly for the pass-through census columns.
//
// SUMMARY-ONLY ROWS ARE EMITTED TOO, with status=summaryOnly and empty staged columns but their
// STORED columns filled. They are what the app actually told 46 more nights' worth of users, and
// dropping them would silently narrow the baseline to the nights that happened to be exported
// within ~30 h. They must never be mixed into a "detected" aggregate — the status column is how.

import CryptoKit
import XCTest
@testable import OpenCircuitKit

/// THE PINNED GOLDEN — the only committed record of the number this campaign quotes.
///
/// Every honesty or staging change in this area ships with the claim *"no staged sleep number moved;
/// the scoreboard hash is unchanged"*. Until now that hash lived only in review notes:
/// `git grep ef5dc087` returned **nothing**, so a reader could not distinguish a re-derivation from
/// a re-typing, and a change that DID move the scoreboard would have been caught only by whoever
/// happened to remember the old value.
///
/// Both values were measured on 2026-08-20 in this repo, against the private corpus at
/// `desktop/captures/sleep-corpus` (gitignored — real tester health data, never committed):
///
///     shasum -a 256 desktop/captures/sleep-corpus/manifest.json
///     shasum -a 256 desktop/captures/sleep-corpus/baseline.tsv    # 74 lines: header + 73 rows
///
/// The manifest fingerprint is what makes the baseline hash meaningful: a hash naming no corpus is
/// unreproducible. `testEmitBaselineTSV` asserts the baseline hash **only** when the manifest it
/// just read matches the fingerprint recorded here; against any other corpus it prints both hashes
/// and asserts nothing, because it has nothing to compare against.
enum SleepBaselineGolden {
    /// sha256 of `manifest.json` for the corpus the baseline below was measured on.
    static let corpusManifestSHA256 = "63a07be8f28714b2c31a410c950dfb9c6f69b899097dccbc5f92f18b41061c0e"
    /// sha256 of the `baseline.tsv` this emitter produces from that corpus AT THE SHIPPED DEFAULT.
    ///
    /// ⚠️ 2026-08-22: this was `ef5dc087…a13e8f` and that was a real hash of the wrong thing. It is
    /// the scoreboard with `BulkSleep.observedGapAbsorbCoverageCut` **at 0 — the kill switch OFF**,
    /// which is what master `f042639` (build 45) did before the evening-absorb guard merged in
    /// `f790c19` (build 46). Pinned as the default, the golden failed on every correct run and
    /// passed only with the shipped behaviour disabled — a gate that is green exactly when the
    /// feature is off.
    ///
    /// Both values re-derived on 2026-08-22 against the same pinned corpus, on master `f790c19`:
    ///     OC_SLEEP_BASELINE_CORPUS=… swift test --filter SleepBaselineTests        → b1df0547…9bf148
    ///     OC_SLEEP_ABSORB_CUT=0 OC_SLEEP_BASELINE_CORPUS=… …                       → ef5dc087…a13e8f
    /// and the honesty stack reproduces `b1df0547` byte-for-byte, 73 rows × 57 columns, which is the
    /// evidence for "no staged sleep number moved".
    ///
    /// Keep BOTH written down. `docs/SLEEP_REPLAY_HARNESS.md` and `BulkSleep.swift`'s comment quote
    /// `ef5dc087` and are CORRECT — they are talking about the guard being off. Do not "fix" them.
    ///
    /// ⚠️ RE-PINNED 2026-08-29, DELIBERATELY, AND A STAGED NUMBER DID MOVE. Previous value
    /// `b1df05475ae15b243c35b8c25c6bd76888e596248f569160c3dba33bbb9bf148` (build 46 → 49).
    ///
    /// Cause: `BulkSleep.morningContinuationMaxGap` changed from a literal `30 * 60` to
    /// `ActivityPeriod.maxSleepPause` (60 min) — see that constant's doc for the full argument. The
    /// night-scoping PRE-FILTER was stricter about "same night" than `mainSleepBlock`, the function
    /// it feeds, so a 30–60 min morning pause deleted every record after it. Three tester reports on
    /// 2026-08-29 (two rings, two firmwares, all build 49) each had a wake of exactly
    /// `anchor.end + 30 min`.
    ///
    /// EXACTLY ONE of the 73 rows moved — `R2_2026-08-04`, and it is UNLABELLED, so this is not
    /// evidence either way about accuracy on it:
    ///     detInBedEnd  2026-08-04T07:36:34+02:00 → 08:21:36   (+45 min)
    ///     detWake      07:36:34 → 08:13:36 · detAsleepMin 408 → 435 · detAwakeMin 76 → 94
    ///     detRemMin 108 → 115 · detLightMin 250 → 270 · detEfficiency 0.8430 → 0.8223
    ///     nightScopedRecords 206 → 232
    /// Its wake was already `witnessed` (the stream ran continuously past it), so the extension sits
    /// over records we hold rather than over a hole. NO LABELLED NIGHT MOVED.
    static let baselineSHA256 = "58fef4b861246576b87a9881fc3ae6e89f04d9c97d5260b5c194232b16b8c6c5"

    /// The same scoreboard with the evening-absorb guard OFF (`OC_SLEEP_ABSORB_CUT=0`). Recorded so
    /// the two can never be mistaken for each other again.
    static let baselineSHA256AbsorbGuardOff =
        "ef5dc087a16f0461d14d656d2e3461cc479cceb85ef5d30f5e4dd741eaa13e8f"

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

final class SleepBaselineTests: XCTestCase {

    func testEmitBaselineTSV() throws {
        let dir = try SleepReplay.requireCorpus(
            "OC_SLEEP_BASELINE_CORPUS",
            purpose: "the scoreboard emitter (SleepBaselineTests)",
            consequence: "No baseline.tsv was written, so any sha256 you were about to quote as a "
                       + "byte-identity proof would be from a stale file.")
        let outPath = ProcessInfo.processInfo.environment["OC_SLEEP_BASELINE_OUT"]
            ?? dir.appendingPathComponent("baseline.tsv").path
        // CANDIDATE A/B. `OC_SLEEP_ABSORB_CUT` sets `BulkSleep.observedGapAbsorbCoverageCut` for this
        // run so the SAME scoreboard scores the candidate. UNSET = the shipped default = master, and
        // the emitted TSV is then byte-identical (proven: sha256 of the master-generated baseline).
        let absorbCut = (ProcessInfo.processInfo.environment["OC_SLEEP_ABSORB_CUT"]).flatMap(Double.init)
            ?? BulkSleep.observedGapAbsorbCoverageCut

        // --- raw manifest, for the census columns SleepReplay's model does not carry
        let manifestURL = dir.appendingPathComponent("manifest.json")
        let manifestData = try Data(contentsOf: manifestURL)
        let manifestHash = SleepBaselineGolden.sha256Hex(manifestData)
        let raw = try JSONSerialization.jsonObject(with: manifestData)
        guard let root = raw as? [String: Any], let rawRows = root["nights"] as? [[String: Any]] else {
            XCTFail("manifest.json has no `nights` array"); return
        }
        let nights = try SleepReplay.loadManifest(at: dir)
        XCTAssertEqual(nights.count, rawRows.count, "manifest row count changed under us")

        let columns = [
            // identity
            "night_id", "ringId", "ringGeneration", "firmware", "night", "timeZone", "appBuilds",
            "status",
            // input
            "recordsFile", "recordCount", "recordsLoaded", "recordsAfterRetention", "nightScopedRecords",
            "hasNightBytes", "recordCountInRecordedInBed", "recordCoverageOfRecordedInBed",
            "gapsOver6MinInWindow", "gapsOver6MinInRecordedInBed",
            "placeholderMotionShare", "placeholderMotionShareInRecordedInBed",
            "layoutSleepVitals", "layoutActivity",
            // detected (master staging, this run)
            "detInBedStart", "detInBedEnd", "detOnset", "detWake",
            "detInBedMin", "detAsleepMin", "detAwakeMin", "detDeepMin", "detRemMin", "detLightMin",
            "detEfficiency",
            // what the app stored at the time
            "storedInBedStart", "storedInBedEnd", "storedOnset", "storedWake",
            "storedAsleepMin", "storedAwakeMin", "storedEfficiency", "edgePrecision",
            "dStartVsStored", "dEndVsStored",
            // ground truth
            "isManuallyEdited", "editFlagProvenance", "isLabelled",
            "labelOnset", "labelWake", "labelInBedStart", "labelInBedEnd",
            "errOnset", "errWake", "errInBedStart", "errInBedEnd",
            // flags
            "flagEffOver097", "flagSpanOver12h", "flagStagedNothing",
        ]

        var lines = [columns.joined(separator: "\t")]
        var replayed = 0, summaryOnly = 0, failed = 0
        var failures: [String] = []

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        func isoStr(_ d: Date?, _ tz: TimeZone) -> String {
            guard let d else { return "" }
            iso.timeZone = tz
            return iso.string(from: d)
        }
        func num(_ v: Any?) -> String {
            guard let v else { return "" }
            // JSONSerialization hands booleans back as __NSCFBoolean, which ALSO casts cleanly to
            // Int (true -> 1) and to Double. Test the CoreFoundation type id first or every
            // true/false column silently ships as 1/0.
            if CFGetTypeID(v as CFTypeRef) == CFBooleanGetTypeID() {
                return (v as? Bool) == true ? "true" : "false"
            }
            switch v {
            case let i as Int: return String(i)
            case let d as Double: return String(format: "%.4f", d)
            case let s as String: return s
            default: return ""
            }
        }
        func signed(_ v: Int?) -> String { v.map(String.init) ?? "" }
        /// signed minutes, detected − reference (+ = we placed it LATE)
        func deltaMin(_ a: Date?, _ b: Date?) -> Int? {
            guard let a, let b else { return nil }
            return Int((a.timeIntervalSince(b) / 60).rounded())
        }

        for (n, rawRow) in zip(nights, rawRows) {
            precondition(n.id == "\(rawRow["ringId"] as? String ?? "")_\(rawRow["night"] as? String ?? "")"
                         || n.id == (rawRow["id"] as? String ?? ""),
                         "manifest row order changed — the census join would be wrong")
            let tz = n.timeZone
            var r: ReplayResult?
            var status = "replayed"
            if n.recordsFile.isEmpty {
                status = "summaryOnly"; summaryOnly += 1
            } else {
                do { r = try SleepReplay.measure(n, in: dir, observedGapCoverageCut: absorbCut); replayed += 1 }
                catch { status = "loadFailed"; failed += 1; failures.append("\(n.id): \(error)") }
            }

            let labelInBedStart = try SleepReplay.date(rawRow["editedInBedStart"] as? String)
            let labelInBedEnd = try SleepReplay.date(rawRow["editedInBedEnd"] as? String)
            let span = (r?.inBedStart).flatMap { s in (r?.inBedEnd).map { $0.timeIntervalSince(s) / 60 } }
            let stagedNothing = (r != nil && r?.inBedStart == nil)

            let cells: [String] = [
                n.id,
                num(rawRow["ringId"]), num(rawRow["ringGeneration"]), num(rawRow["firmware"]),
                num(rawRow["night"]), tz.identifier,
                (rawRow["appBuilds"] as? [Any])?.map { "\($0)" }.joined(separator: "/") ?? "",
                status,

                n.recordsFile, num(rawRow["recordCount"]),
                r.map { String($0.recordsLoaded) } ?? "",
                r.map { String($0.recordsAfterRetention) } ?? "",
                r.map { String($0.nightScopedRecords) } ?? "",
                num(rawRow["hasNightBytes"]), num(rawRow["recordCountInRecordedInBed"]),
                num(rawRow["recordCoverageOfRecordedInBed"]),
                String((rawRow["gapsOver6MinInWindow"] as? [Any])?.count ?? 0),
                String((rawRow["gapsOver6MinInRecordedInBed"] as? [Any])?.count ?? 0),
                num(rawRow["placeholderMotionShare"]),
                num(rawRow["placeholderMotionShareInRecordedInBed"]),
                num((rawRow["layoutCounts"] as? [String: Any])?["sleepVitals"]),
                num((rawRow["layoutCounts"] as? [String: Any])?["activity"]),

                isoStr(r?.inBedStart, tz), isoStr(r?.inBedEnd, tz),
                isoStr(r?.onset, tz), isoStr(r?.wake, tz),
                r.map { String($0.inBedMin) } ?? "", r.map { String($0.asleepMin) } ?? "",
                r.map { String($0.awakeMin) } ?? "", r.map { String($0.deepMin) } ?? "",
                r.map { String($0.remMin) } ?? "", r.map { String($0.lightMin) } ?? "",
                r.map { String(format: "%.4f", $0.efficiency) } ?? "",

                isoStr(n.stored.inBedStart, tz), isoStr(n.stored.inBedEnd, tz),
                isoStr(n.stored.sleepOnset, tz), isoStr(n.stored.sleepWake, tz),
                n.stored.asleepMin.map(String.init) ?? "", n.stored.awakeMin.map(String.init) ?? "",
                num(rawRow["efficiency"]), num(rawRow["edgePrecision"]),
                signed(r?.storedStartDeltaMin), signed(r?.storedEndDeltaMin),

                num(rawRow["isManuallyEdited"]), num(rawRow["editFlagProvenance"]),
                num(rawRow["isLabelled"]),
                isoStr(n.label?.onset, tz), isoStr(n.label?.wake, tz),
                isoStr(labelInBedStart, tz), isoStr(labelInBedEnd, tz),
                signed(deltaMin(r?.onset, n.label?.onset)),
                signed(deltaMin(r?.wake, n.label?.wake)),
                signed(deltaMin(r?.inBedStart, labelInBedStart)),
                signed(deltaMin(r?.inBedEnd, labelInBedEnd)),

                r.map { $0.efficiency > 0.97 ? "true" : "false" } ?? "",
                span.map { $0 > 12 * 60 ? "true" : "false" } ?? "",
                r == nil ? "" : (stagedNothing ? "true" : "false"),
            ]
            precondition(cells.count == columns.count, "column/cell mismatch on \(n.id)")
            lines.append(cells.map { $0.replacingOccurrences(of: "\t", with: " ") }.joined(separator: "\t"))
        }

        let tsv = lines.joined(separator: "\n") + "\n"
        try tsv.write(toFile: outPath, atomically: true, encoding: .utf8)
        let tsvHash = SleepBaselineGolden.sha256Hex(Data(tsv.utf8))
        // Both halves of this line are load-bearing and were added independently: the absorb-cut
        // label says WHICH staging produced the scoreboard (build 46's kill switch), and the hash
        // is what the pinned golden below compares against. Dropping either makes a baseline run
        // unattributable — do not "simplify" back to one print.
        print("\n=== SLEEP BASELINE — observedGapAbsorbCoverageCut = \(absorbCut)"
              + (absorbCut == BulkSleep.observedGapAbsorbCoverageCut ? " (shipped default)" : " (CANDIDATE)")
              + ", corpus \(dir.path)")
        print("=== \(nights.count) manifest rows: \(replayed) replayed, \(summaryOnly) summary-only, "
              + "\(failed) load failures")
        print("=== wrote \(lines.count - 1) rows x \(columns.count) columns -> \(outPath)")
        print("=== manifest sha256 \(manifestHash)")
        print("=== baseline sha256 \(tsvHash)")
        for f in failures { print("  LOAD FAILURE  " + f) }
        XCTAssertTrue(failures.isEmpty, "a corpus row failed to load — the baseline would be incomplete")
        XCTAssertGreaterThan(replayed, 0, "nothing was replayed at all")

        // THE PINNED COMPARISON. Only meaningful against the corpus the golden was measured on —
        // anyone else's corpus produces a different (and equally valid) scoreboard, so report rather
        // than fail. See `SleepBaselineGolden`.
        guard manifestHash == SleepBaselineGolden.corpusManifestSHA256 else {
            print("=== golden NOT CHECKED — this is a different corpus.")
            print("===   pinned manifest \(SleepBaselineGolden.corpusManifestSHA256)")
            print("===   this   manifest \(manifestHash)")
            print("===   pinned baseline \(SleepBaselineGolden.baselineSHA256) (not comparable)")
            return
        }
        // ⚠️ THE SUCCESS LINE IS GUARDED, AND IT HAS TO BE. `XCTAssertEqual` RECORDS a failure and
        // RETURNS — it does not abort — so an unconditional `print("golden MATCH")` after it emitted
        // the reassuring line on a run that had just failed the pin. 🟢 Reproduced 2026-08-24: a
        // staging change moved the scoreboard to 1b8aeeef…40fb5e, the test reported
        // "Executed 1 test, with 1 failure", and it STILL printed "golden MATCH — baseline.tsv is
        // byte-identical to the pinned scoreboard" underneath. Anyone grepping the output for
        // "golden" — which is exactly how this line is meant to be read — would have quoted a green
        // gate off a red run. That is the same failure shape as the corpus entry points that
        // "passed" while asserting nothing (docs/SLEEP_REPLAY_HARNESS.md §1).
        guard tsvHash == SleepBaselineGolden.baselineSHA256 else {
            XCTFail("THE SCOREBOARD MOVED. This is the pinned corpus (manifest \(manifestHash)) "
                    + "but the emitted baseline.tsv hashes to \(tsvHash), not the pinned "
                    + "\(SleepBaselineGolden.baselineSHA256). Either a staging number changed — "
                    + "in which case say so and re-pin deliberately — or the emitter's columns "
                    + "changed, in which case re-pin and note it. Do NOT quote 'hash unchanged' "
                    + "after seeing this.")
            print("=== golden MOVED — baseline.tsv is NOT the pinned scoreboard. See the failure above.")
            return
        }
        print("=== golden MATCH — baseline.tsv is byte-identical to the pinned scoreboard.")
    }
}

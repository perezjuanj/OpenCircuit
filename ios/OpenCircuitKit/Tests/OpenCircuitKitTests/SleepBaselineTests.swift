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

import XCTest
@testable import OpenCircuitKit

final class SleepBaselineTests: XCTestCase {

    func testEmitBaselineTSV() throws {
        let dir = try SleepReplay.requireCorpus(
            "OC_SLEEP_BASELINE_CORPUS",
            purpose: "the scoreboard emitter (SleepBaselineTests)",
            consequence: "No baseline.tsv was written, so any sha256 you were about to quote as a "
                       + "byte-identity proof would be from a stale file.")
        let outPath = ProcessInfo.processInfo.environment["OC_SLEEP_BASELINE_OUT"]
            ?? dir.appendingPathComponent("baseline.tsv").path

        // --- raw manifest, for the census columns SleepReplay's model does not carry
        let manifestURL = dir.appendingPathComponent("manifest.json")
        let raw = try JSONSerialization.jsonObject(with: try Data(contentsOf: manifestURL))
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
                do { r = try SleepReplay.measure(n, in: dir); replayed += 1 }
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

        try (lines.joined(separator: "\n") + "\n").write(toFile: outPath, atomically: true, encoding: .utf8)
        print("\n=== SLEEP BASELINE — master staging, corpus \(dir.path)")
        print("=== \(nights.count) manifest rows: \(replayed) replayed, \(summaryOnly) summary-only, "
              + "\(failed) load failures")
        print("=== wrote \(lines.count - 1) rows x \(columns.count) columns -> \(outPath)")
        for f in failures { print("  LOAD FAILURE  " + f) }
        XCTAssertTrue(failures.isEmpty, "a corpus row failed to load — the baseline would be incomplete")
        XCTAssertGreaterThan(replayed, 0, "nothing was replayed at all")
    }
}

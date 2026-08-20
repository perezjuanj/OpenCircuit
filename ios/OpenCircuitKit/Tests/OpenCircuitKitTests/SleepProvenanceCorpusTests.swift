// MEASURE THE PROVENANCE FIX ON THE WHOLE CORPUS — how many nights change, by how much, and what
// stops reaching Apple Health.
//
//   cd ios/OpenCircuitKit && \
//     OC_SLEEP_PROVENANCE_CORPUS=<corpus-dir> swift test --filter SleepProvenanceCorpusTests
//
// WHAT IT DOES. For every manifest row that carries raw bytes, it stages the night through the same
// transcription `SleepReplay` uses, then — for a row that also carries all three EDIT anchors — runs
// `SleepEdit.recompute` twice on identical inputs:
//     OFF: `coverage: nil`   the kill switch, i.e. exactly what master does
//     ON : `coverage: <the record set>`
// and reports the difference. The OFF arm is not decoration: the test ASSERTS the two arms emit the
// same spans and the same stages, so any reported change is a change of LABEL only. If the fix ever
// starts moving a boundary, this fails.
//
// COVERAGE IS BUILT FROM THE FULL RECORD UNION, NOT THE NIGHT SLICE. That is the most generous
// reading available to the app: every minute this reports as asserted is asserted under the app's
// own best case, so no number here can be an artifact of a narrow window.
//
// ⚠️ TWO CORPUS ROWS ARE MEASURED BUT MUST NOT BE COUNTED — `R1_2026-08-14` and `R1_2026-08-15`
// replay as fully invented, but their `.b64` holds NO records inside the app's own recorded in-bed
// window (`recordCoverageOfRecordedInBed == 0.0`) while the app's OWN export reported coverage 1.00
// and 0.974. The corpus input is provably not what the phone staged from, so those minutes are an
// artifact of the corpus, not evidence about those nights. The test prints them under DISCOUNTED and
// keeps them out of every total.

import XCTest
@testable import OpenCircuitKit

final class SleepProvenanceCorpusTests: XCTestCase {

    private struct Row {
        var id = ""
        var tz = TimeZone(identifier: "UTC")!
        var recordsFile = ""
        var isManuallyEdited = false
        var editInBedStart: Date?
        var editOnset: Date?
        var editWake: Date?
        var storedAsleepMin: Int?
        var storedEfficiency: Double?
        var recordCoverageOfRecordedInBed: Double?
        var appCoverageFraction: Double?
    }

    /// Rows whose corpus BYTES provably are not what the phone staged from. Measured, never counted.
    private static let discounted: Set<String> = ["R1_2026-08-14", "R1_2026-08-15"]

    func testMeasureProvenanceAcrossTheCorpus() throws {
        guard let dir = SleepReplay.dir("OC_SLEEP_PROVENANCE_CORPUS")
                ?? SleepReplay.dir("OC_SLEEP_BASELINE_CORPUS") else {
            throw XCTSkip("OC_SLEEP_PROVENANCE_CORPUS unset — point it at a corpus directory.")
        }

        let raw = try JSONSerialization.jsonObject(with:
            try Data(contentsOf: dir.appendingPathComponent("manifest.json")))
        guard let root = raw as? [String: Any], let rawRows = root["nights"] as? [[String: Any]] else {
            return XCTFail("manifest.json has no `nights` array")
        }

        var rows: [Row] = []
        for r in rawRows {
            var row = Row()
            row.id = (r["id"] as? String)
                ?? "\(r["ringId"] as? String ?? "")_\(r["night"] as? String ?? "")"
            if let name = (r["timeZone"] as? String) ?? (r["timeZoneIdentifier"] as? String),
               let z = TimeZone(identifier: name) { row.tz = z }
            else if let off = r["timeZoneOffsetSeconds"] as? Int,
                    let z = TimeZone(secondsFromGMT: off) { row.tz = z }
            row.recordsFile = (r["recordsFile"] as? String) ?? (r["records"] as? String) ?? ""
            row.isManuallyEdited = (r["isManuallyEdited"] as? Bool) ?? false
            row.editInBedStart = try SleepReplay.date(r["editedInBedStart"] as? String)
            row.editOnset = try SleepReplay.date(r["editedOnset"] as? String)
            row.editWake = try SleepReplay.date(r["editedWake"] as? String)
            row.storedAsleepMin = r["asleepMin"] as? Int
            row.storedEfficiency = r["efficiency"] as? Double
            row.recordCoverageOfRecordedInBed = r["recordCoverageOfRecordedInBed"] as? Double
            row.appCoverageFraction = r["appCoverageFraction"] as? Double
            rows.append(row)
        }

        print("\n=== SLEEP PROVENANCE — corpus \(dir.path)")
        print("=== \(rawRows.count) manifest rows; coverage from the FULL record union, epoch "
              + "\(Int(MeasuredCoverage.defaultEpochSeconds)) s\n")

        var withBytes = 0, staged = 0, replayableEdits = 0
        var nightsChanged = 0
        var totalAssertedAsleepMin = 0.0, totalAssertedAwakeMin = 0.0
        var discountedAssertedAsleepMin = 0.0
        var ordinaryPathAssertedAsleepMin = 0.0
        var lines: [String] = []

        let header = String(format: "%-16@ %7@ %8@ %9@ %9@ %8@ %8@ %8@",
                            "night" as NSString, "cover" as NSString, "displayed" as NSString,
                            "measured" as NSString, "asserted" as NSString,
                            "effOFF" as NSString, "effON" as NSString, "score" as NSString)
        lines.append(header)

        for row in rows where !row.recordsFile.isEmpty {
            withBytes += 1
            let night = try SleepReplay.loadManifest(at: dir).first { $0.id == row.id }
            guard let night else { continue }
            let records = try SleepReplay.loadRecords(night, in: dir)
            guard !records.isEmpty else { continue }

            let anchor = records.first?.date() ?? Date()
            let coverage = MeasuredCoverage(records: records)

            try SleepReplay.withTimeZone(row.tz, at: anchor) {
                let base = SleepReplay.stage(
                    records: records,
                    temperatures: night.temperatures.map { TemperatureSample(time: $0.t, celsius: $0.c) },
                    deepHRBaseline: night.deepHRBaselineBPM).segments
                if !base.isEmpty { staged += 1 }

                // --- ORDINARY (unedited) PATH: staging emits `.measured` only, so its asserted
                //     total is zero by construction. Recorded here so the claim is measured, not
                //     assumed — and so a future change to staging cannot quietly start asserting.
                if !base.isEmpty {
                    let ordinary = SleepProvenanceBreakdown(segments: base)
                    ordinaryPathAssertedAsleepMin += ordinary.assertedAsleep / 60
                }

                // --- EDIT PATH
                guard row.isManuallyEdited,
                      let b = row.editInBedStart, let o = row.editOnset, let w = row.editWake,
                      w > o, o >= b else { return }
                replayableEdits += 1

                let times = SleepEdit.Times(inBedStart: b, sleepOnset: o, sleepWake: w)
                let off = SleepEdit.recompute(baseSegments: base, times: times, coverage: nil)
                let on = SleepEdit.recompute(baseSegments: base, times: times, coverage: coverage)

                // THE LOAD-BEARING ASSERTION: the fix relabels, it never re-shapes. Compare the
                // total span per stage — the ON arm splits a fill into pieces, so segment counts
                // legitimately differ, but not one second may move between stages or vanish.
                func spanByStage(_ segs: [SleepSegment]) -> [SleepStage: TimeInterval] {
                    Dictionary(segs.map { ($0.stage, $0.duration) }, uniquingKeysWith: +)
                }
                let sOff = spanByStage(off), sOn = spanByStage(on)
                XCTAssertEqual(Set(sOff.keys), Set(sOn.keys), "\(row.id): a stage appeared or vanished")
                for (stage, secs) in sOff {
                    XCTAssertEqual(secs, sOn[stage] ?? -1, accuracy: 0.001,
                                   "\(row.id): \(stage) moved — the fix must relabel, not re-shape")
                }
                XCTAssertEqual(off.map(\.start).min(), on.map(\.start).min(), "\(row.id): night start moved")
                XCTAssertEqual(off.map(\.end).max(), on.map(\.end).max(), "\(row.id): night end moved")

                let bOff = SleepProvenanceBreakdown(segments: off)
                let bOn = SleepProvenanceBreakdown(segments: on)
                let assertedAsleepMin = bOn.assertedAsleep / 60
                let assertedAwakeMin = bOn.assertedAwake / 60

                if bOn.hasAssertedTime {
                    nightsChanged += 1
                    if Self.discounted.contains(row.id) {
                        discountedAssertedAsleepMin += assertedAsleepMin
                    } else {
                        totalAssertedAsleepMin += assertedAsleepMin
                        totalAssertedAwakeMin += assertedAwakeMin
                    }
                }

                func eff(_ b: SleepProvenanceBreakdown) -> String {
                    b.efficiency.map { String(format: "%.4f", $0) } ?? "withheld"
                }
                lines.append(String(
                    format: "%-16@ %6.3f %8.1f %9.1f %9.1f %8@ %8@ %8@%@",
                    row.id as NSString,
                    bOn.coverageFraction,
                    bOn.displayedAsleep / 60,
                    bOn.measuredAsleep / 60,
                    assertedAsleepMin,
                    eff(bOff) as NSString,
                    eff(bOn) as NSString,
                    (bOn.isScorable ? "keep" : "withheld") as NSString,
                    (Self.discounted.contains(row.id) ? "   DISCOUNTED" : "") as NSString))
            }
        }

        for l in lines { print(l) }
        print("""

        --- corpus shape
        rows with raw bytes ............ \(withBytes)
        of those, staged a night ....... \(staged)
        replayable edits (3 anchors) ... \(replayableEdits)

        --- what changes
        nights carrying ANY asserted time ......... \(nightsChanged) of \(withBytes)
        ordinary (unedited) staging path, asserted  \(String(format: "%.1f", ordinaryPathAssertedAsleepMin)) asleep-min TOTAL
        EDIT path asserted ASLEEP (counted) ....... \(String(format: "%.1f", totalAssertedAsleepMin)) min \
        = \(String(format: "%.2f", totalAssertedAsleepMin / 60)) h
        EDIT path asserted AWAKE  (counted) ....... \(String(format: "%.1f", totalAssertedAwakeMin)) min
        DISCOUNTED (corpus input != what staged) .. \(String(format: "%.1f", discountedAssertedAsleepMin)) min — NOT counted

        --- Apple Health
        every asserted-asleep minute above is on the write path today (HealthKitWriter :1585/:1598
        map EVERY segment 1:1 with no coverage filter). `[SleepSegment].measuredOnly` removes exactly
        \(String(format: "%.1f", totalAssertedAsleepMin)) asleep-minutes from it and keeps the .inBed claim.
        """)

        XCTAssertGreaterThan(withBytes, 0, "nothing was replayed at all")
    }
}

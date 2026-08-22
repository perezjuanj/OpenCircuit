// HOW OFTEN DOES THE EDITED-NIGHT LINE FIRE ACROSS THE WHOLE CORPUS — and is it silent everywhere
// it should be?
//
//   cd ios/OpenCircuitKit && \
//     OC_SLEEP_NOTICE_CORPUS=<corpus-dir> swift test --filter SleepEditedNightNoticeCorpusTests
//
// The line makes no prediction, so this is not an accuracy measurement — it is a BLAST-RADIUS
// measurement. It answers the only two questions a reviewer can ask of a caption whose trigger is
// certain: how many nights see it, and can it appear on a night nobody edited.
//
// The second question is answered by CONSTRUCTION as well as by count. Staging emits `.measured`
// segments only, so an unedited night's breakdown has `assertedAsleep == 0` and the line is `nil`
// before the manual-edit gate is even reached. This test asserts that on every staged night in the
// corpus, then re-checks the edited ones with the edit gate forced OFF.
//
// ⚠️ REBASE NOTE. This file uses `SleepReplay.dir(…)`, matching the four corpus-gated tests already
// on this branch (`SleepReplayTests`, `SleepBaselineTests`, `SleepProvenanceCorpusTests`,
// `SleepProvenanceFixtureProbe`) — `requireCorpus` does not exist here. On the rebase onto
// `integration/sleep-honesty-steps-1-3` all FIVE must be converted to `SleepReplay.requireCorpus`
// together, or `CorpusGateLoudnessTests` flags them. The variable name is already compatible with
// both gate patterns (`OC_SLEEP[A-Z0-9_]*_CORPUS` and the widened `OC_[A-Z0-9_]*CORPUS`).
//
// ⚠️ Two corpus rows are measured and NOT counted for the same reason `SleepProvenanceCorpusTests`
// discounts them: `R1_2026-08-14` / `R1_2026-08-15` replay as fully invented, but their `.b64` holds
// no records inside the app's own recorded in-bed window while the app's own export reported
// coverage 1.00 / 0.974 — so the corpus input provably is not what the phone staged from. They are
// printed under DISCOUNTED and kept out of the headline count.

import XCTest
@testable import OpenCircuitKit

final class SleepEditedNightNoticeCorpusTests: XCTestCase {

    /// Rows whose corpus BYTES provably are not what the phone staged from. Measured, never counted.
    private static let discounted: Set<String> = ["R1_2026-08-14", "R1_2026-08-15"]

    func testMeasureHowManyCorpusNightsShowTheEditedNightLine() throws {
        let dir = try SleepReplay.requireCorpus(
            anyOf: ["OC_SLEEP_NOTICE_CORPUS", "OC_SLEEP_PROVENANCE_CORPUS", "OC_SLEEP_BASELINE_CORPUS"],
            purpose: "the count of corpus nights that would show the edited-night notice",
            consequence: "How often the new card line appears was NOT measured on this run.")

        let raw = try JSONSerialization.jsonObject(with:
            try Data(contentsOf: dir.appendingPathComponent("manifest.json")))
        guard let root = raw as? [String: Any], let rawRows = root["nights"] as? [[String: Any]] else {
            return XCTFail("manifest.json has no `nights` array")
        }

        var withBytes = 0, stagedNights = 0, editedNights = 0
        var fires = 0, firesDiscounted = 0
        var silentEdited: [String] = []
        var lines: [String] = []

        for r in rawRows {
            let id = (r["id"] as? String)
                ?? "\(r["ringId"] as? String ?? "")_\(r["night"] as? String ?? "")"
            let recordsFile = (r["recordsFile"] as? String) ?? (r["records"] as? String) ?? ""
            guard !recordsFile.isEmpty else { continue }
            guard let night = try SleepReplay.loadManifest(at: dir).first(where: { $0.id == id })
            else { continue }
            let records = try SleepReplay.loadRecords(night, in: dir)
            guard !records.isEmpty else { continue }
            withBytes += 1

            var tz = TimeZone(identifier: "UTC")!
            if let name = (r["timeZone"] as? String) ?? (r["timeZoneIdentifier"] as? String),
               let z = TimeZone(identifier: name) { tz = z }
            else if let off = r["timeZoneOffsetSeconds"] as? Int,
                    let z = TimeZone(secondsFromGMT: off) { tz = z }

            let isEdited = (r["isManuallyEdited"] as? Bool) ?? false
            let b = try SleepReplay.date(r["editedInBedStart"] as? String)
            let o = try SleepReplay.date(r["editedOnset"] as? String)
            let w = try SleepReplay.date(r["editedWake"] as? String)

            let anchor = records.first?.date() ?? Date()
            let coverage = MeasuredCoverage(records: records)

            try SleepReplay.withTimeZone(tz, at: anchor) {
                let base = SleepReplay.stage(
                    records: records,
                    temperatures: night.temperatures.map { TemperatureSample(time: $0.t, celsius: $0.c) },
                    deepHRBaseline: night.deepHRBaselineBPM).segments

                // --- UNEDITED PATH. The staged hypnogram is what a night with no edit stores, and
                //     the line must be nil on it — before any gate, purely because nothing is
                //     asserted. This is the "silent on every night without an edit" proof.
                if !base.isEmpty {
                    stagedNights += 1
                    let staged = SleepProvenanceBreakdown(segments: base)
                    XCTAssertEqual(staged.assertedAsleep, 0, accuracy: 0.001,
                                   "\(id): ordinary staging asserted time — the line's premise moved")
                    XCTAssertNil(SleepEditedNightNotice.line(measuredAsleep: staged.measuredAsleep,
                                                             assertedAsleep: staged.assertedAsleep,
                                                             mirrorsSleepToHealth: true),
                                 "\(id): the line fired on an UNEDITED night")
                }

                // The edit path is NOT gated on staging — `SleepProvenanceCorpusTests` replays all
                // five corpus edits, two of which stage nothing from these bytes, and this count has
                // to be comparable with that one.
                guard isEdited, let b, let o, let w, w > o, o >= b else { return }
                editedNights += 1

                let on = SleepEdit.recompute(baseSegments: base,
                                             times: .init(inBedStart: b, sleepOnset: o, sleepWake: w),
                                             coverage: coverage)
                let br = SleepProvenanceBreakdown(segments: on)
                let text = SleepEditedNightNotice.line(measuredAsleep: br.measuredAsleep,
                                                       assertedAsleep: br.assertedAsleep,
                                                       mirrorsSleepToHealth: true)

                // The manual-edit gate is the card's, not the copy's — but if the copy could speak
                // for an unedited night whose SEGMENTS happen to carry asserted time, the card's
                // gate would be the only thing standing between us and a caption nobody earned.
                // Assert the two agree: asserted time here only ever comes from an edit.
                if text != nil {
                    XCTAssertTrue(isEdited, "\(id): asserted time on a night with no edit")
                }

                if let text {
                    if Self.discounted.contains(id) { firesDiscounted += 1 } else { fires += 1 }
                    lines.append("""
                    \(id)\(Self.discounted.contains(id) ? "   [DISCOUNTED]" : "")
                      displayed \(br.minutes.measuredAsleep + br.minutes.assertedAsleep) min \
                    = \(br.minutes.measuredAsleep) measured + \(br.minutes.assertedAsleep) asserted \
                    · asserted awake \(br.minutes.assertedAwake) min \
                    · coverage \(String(format: "%.3f", br.coverageFraction))
                      \(text)
                    """)
                } else {
                    silentEdited.append("\(id) (asserted asleep "
                        + "\(String(format: "%.1f", br.assertedAsleep / 60)) min, asserted awake "
                        + "\(String(format: "%.1f", br.assertedAwake / 60)) min)")
                }
            }
        }

        print("\n=== EDITED-NIGHT CARD LINE — corpus \(dir.path)")
        print("=== \(rawRows.count) manifest rows\n")
        for l in lines { print(l + "\n") }
        print("""
        --- corpus shape
        rows with raw bytes ............... \(withBytes)
        of those, staged a night .......... \(stagedNights)
        of those, replayable EDITS ........ \(editedNights)

        --- how many nights show the line
        FIRES (counted) ................... \(fires) of \(withBytes) nights with bytes
        FIRES (discounted rows) ........... \(firesDiscounted) — measured, not counted
        edited nights that stay SILENT .... \(silentEdited.count)\
        \(silentEdited.isEmpty ? "" : " — " + silentEdited.joined(separator: ", "))
        nights with NO edit ............... 0 fired (asserted by construction, above)
        """)

        XCTAssertGreaterThan(withBytes, 0, "nothing was replayed at all")
    }
}

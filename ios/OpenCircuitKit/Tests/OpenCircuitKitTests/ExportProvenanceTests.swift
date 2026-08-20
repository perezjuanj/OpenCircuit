// THE EXPORT MUST BE ABLE TO SAY WHICH MINUTES WERE MEASURED.
//
// Before this, no export surface could. Coverage was reported only as a night AGGREGATE, and the
// emitted hypnogram carried start/end/stage/durationSec and nothing else — so a consumer reading an
// edited night could not distinguish a 246-minute `asleepCore` block invented over a 2 %-covered
// hole from a real one. They serialised identically.
//
// The two things these tests exist to stop regressing:
//   1. a MEASURED night's JSON must be byte-for-byte what earlier schema-3 exports produced, so no
//      consumer breaks and no install rewrites its history;
//   2. `measuredEfficiency` must be OMITTED when withheld — never 0 (a real efficiency, and a live
//      sentinel at `LocalStore.swift:235`) and never a JSON null (which `JSONSerialization` would
//      refuse to encode, taking the whole export down with it).

import XCTest
@testable import OpenCircuitKit

final class ExportProvenanceTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private func at(_ m: Double) -> Date { t0.addingTimeInterval(m * 60) }

    private func json(_ hypnogram: [SleepSegment]) -> [String: Any] {
        let night = Calendar.current.startOfDay(for: t0)
        let summary = ExportEngine.SleepRow(
            night: night, asleepMin: 400, deepMin: 40, lightMin: 330, remMin: 30, awakeMin: 36,
            efficiency: 0.9, skinTempC: 0, sleepScore: 70, stressScore: 0)
        let session = ExportEngine.SleepSessionRow(
            sessionID: ExportEngine.sessionID(night: night), night: night,
            inBedStart: at(0), inBedEnd: at(439), sleepOnset: at(36), sleepWake: at(439),
            isManuallyEdited: true, hypnogram: hypnogram, summary: summary)
        let text = ExportEngine.toJSON(samples: [], sleep: [summary], daily: [],
                                       now: t0, sleepSessions: [session])
        guard let data = text?.data(using: String.Encoding.utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("export did not produce a JSON object — a nil/optional leaked into the dictionary")
            return [:]
        }
        return obj
    }

    private func firstSession(_ obj: [String: Any]) -> [String: Any] {
        ((obj["sleepSessions"] as? [[String: Any]]) ?? []).first ?? [:]
    }

    private var measuredNight: [SleepSegment] {
        [SleepSegment(start: at(0), end: at(439), stage: .inBed),
         SleepSegment(start: at(0), end: at(36), stage: .awake),
         SleepSegment(start: at(36), end: at(439), stage: .asleepCore)]
    }

    /// The 08-18 shape: a long asserted block over a hole, plus real measured sleep before it.
    private var partlyAssertedNight: [SleepSegment] {
        [SleepSegment(start: at(0), end: at(195), stage: .inBed),
         SleepSegment(start: at(195), end: at(439), stage: .inBed, provenance: .asserted),
         SleepSegment(start: at(0), end: at(36), stage: .awake, provenance: .assertedOverMeasured),
         SleepSegment(start: at(36), end: at(195), stage: .asleepCore),
         SleepSegment(start: at(195), end: at(439), stage: .asleepCore, provenance: .asserted)]
    }

    func testMeasuredNightEmitsNoProvenanceKeysAtAll() {
        let session = firstSession(json(measuredNight))
        let rows = (session["hypnogram"] as? [[String: Any]]) ?? []
        XCTAssertFalse(rows.isEmpty)
        for row in rows {
            XCTAssertNil(row["provenance"],
                         "a measured night's export must be unchanged for existing consumers")
        }
        XCTAssertNil(session["provenanceSummary"])
    }

    func testAssertedSegmentsAreLabelledInTheTimeline() {
        let session = firstSession(json(partlyAssertedNight))
        let rows = (session["hypnogram"] as? [[String: Any]]) ?? []
        let asserted = rows.filter { ($0["provenance"] as? String) == "asserted" }
        XCTAssertEqual(asserted.count, 1, "the invented block must be individually identifiable")
        XCTAssertEqual(asserted.first?["stage"] as? String, "asleepCore")
        XCTAssertEqual(asserted.first?["durationSec"] as? Double, 244 * 60)

        // A relabelled-but-measured span is distinguishable from an invented one.
        XCTAssertEqual(rows.filter { ($0["provenance"] as? String) == "assertedOverMeasured" }.count, 1)
    }

    func testProvenanceSummaryRollsTheSameFactUp() throws {
        let session = firstSession(json(partlyAssertedNight))
        let s = try XCTUnwrap(session["provenanceSummary"] as? [String: Any])
        XCTAssertEqual(s["assertedAsleepSec"] as? Double, 244 * 60)
        XCTAssertEqual(s["measuredAsleepSec"] as? Double, 159 * 60)
        XCTAssertEqual(s["coveredInBedSec"] as? Double, 195 * 60)
        XCTAssertEqual(try XCTUnwrap(s["coverageFraction"] as? Double), 195.0 / 439.0, accuracy: 1e-9)
        XCTAssertEqual(s["longestUnmeasuredGapSec"] as? Double, 244 * 60)
        XCTAssertEqual(s["scorable"] as? Bool, false)
    }

    func testWithheldEfficiencyIsOMITTEDNotZeroAndNotNull() throws {
        // Barely any covered ground -> the ratio is withheld. The key must simply not be there.
        let thin = [
            SleepSegment(start: at(0), end: at(5), stage: .inBed),
            SleepSegment(start: at(5), end: at(439), stage: .inBed, provenance: .asserted),
            SleepSegment(start: at(0), end: at(5), stage: .asleepCore),
            SleepSegment(start: at(5), end: at(439), stage: .asleepCore, provenance: .asserted),
        ]
        let obj = json(thin)                    // also proves JSONSerialization did not refuse it
        let s = try XCTUnwrap(firstSession(obj)["provenanceSummary"] as? [String: Any])
        XCTAssertNil(s["measuredEfficiency"], "withheld must be ABSENT, never 0 and never null")
        XCTAssertNotNil(s["coverageFraction"], "coverage is still stated — that is the honest part")
    }

    func testPublishedEfficiencyIsPresentWhenThereIsEnoughGround() throws {
        let session = firstSession(json(partlyAssertedNight))
        let s = try XCTUnwrap(session["provenanceSummary"] as? [String: Any])
        XCTAssertEqual(try XCTUnwrap(s["measuredEfficiency"] as? Double), 159.0 / 195.0,
                       accuracy: 1e-9)
    }
}

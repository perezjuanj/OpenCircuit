import XCTest
import OpenCircuitKit
@testable import OpenCircuit

// On-device sleep recap: the words it shows, the night it is built from, and the guarantee that it
// never reaches Apple's server-side model.

final class SleepRecapSourceTests: XCTestCase {

    func testFootnoteSaysOnDeviceAndNotMedicalAdvice() {
        let f = SleepRecapCopy.footnote
        XCTAssertTrue(f.contains("on this iPhone"))
        XCTAssertTrue(f.contains("Nothing is sent off your phone"))
        XCTAssertTrue(f.contains("Not medical advice"))
        XCTAssertTrue(f.contains("Apple Intelligence"))
    }

    /// The local-first promise rests on this: the recap must use the ON-DEVICE model only. iOS 27's
    /// `PrivateCloudComputeLanguageModel` runs on Apple's servers, so no app source may name it.
    func testNoAppSourceNamesTheServerModel() throws {
        let appDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("OpenCircuit")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: appDir, includingPropertiesForKeys: nil))
        var scanned = 0
        var hits: [String] = []
        for case let url as URL in files where url.pathExtension == "swift" {
            scanned += 1
            let code = try String(contentsOf: url, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            if code.contains("PrivateCloudCompute") { hits.append(url.lastPathComponent) }
        }
        XCTAssertGreaterThan(scanned, 100, "the scan must actually walk the app sources")
        XCTAssertEqual(hits, [])
    }

    /// The model call never logs: an error from it can quote the prompt, which is health data.
    func testTheRecapFileNeverLogs() throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("OpenCircuit/SleepRecapRow.swift")
        let code = try String(contentsOf: path, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        for banned in ["print(", "Logger", "os_log", "NSLog", "debugPrint", "PrivateCloudCompute"] {
            XCTAssertFalse(code.contains(banned), "SleepRecapRow.swift must not use \(banned)")
        }
        XCTAssertTrue(code.contains("SystemLanguageModel.default"))
    }

    /// The Today line says who wrote it whenever the model's text is on screen.
    func testTodayBriefBylineAndCacheRoundTrip() throws {
        XCTAssertEqual(TodayBriefCopy.byline, "Written on this iPhone by Apple Intelligence")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "TodayBriefCacheTests"))
        defaults.removePersistentDomain(forName: "TodayBriefCacheTests")
        XCTAssertNil(TodayBriefCache.load(defaults))
        TodayBriefCache.save(TodayBrief(prompt: "p", text: "t"), defaults)
        XCTAssertEqual(TodayBriefCache.load(defaults), TodayBrief(prompt: "p", text: "t"))
        defaults.removePersistentDomain(forName: "TodayBriefCacheTests")
    }

    /// The Today header never logs either: its prompt is health data.
    func testTheTodayHeaderNeverLogs() throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("OpenCircuit/Dashboard/TodaySynthesisHeader.swift")
        let code = try String(contentsOf: path, encoding: .utf8)
        for banned in ["print(", "Logger", "os_log", "NSLog", "debugPrint"] {
            XCTAssertFalse(code.contains(banned), "TodaySynthesisHeader.swift must not use \(banned)")
        }
        XCTAssertTrue(code.contains("TodaySynthesis.vetBrief"), "the brief is only shown after its vet")
    }

    func testAdapterUsesTheDisplayedNightAndOnlyItsOwnScore() {
        let key = Date(timeIntervalSince1970: 1_736_150_400)
        let summary = SleepStaging.Summary(inBed: 450 * 60, awake: 30 * 60, light: 240 * 60,
                                           deep: 70 * 60, rem: 110 * 60)
        let night = SleepCardView.Night(nightKey: key, summary: summary, inBedStart: nil, inBedEnd: nil,
                                        onset: nil, wake: nil, when: key, wakeKnown: false,
                                        isManuallyEdited: false, stageSource: .stored)
        let row = StoredSleepSummary(night: key)
        row.sleepScore = 77
        let n = SleepRecapAdapter.night(night, row: row)
        XCTAssertEqual(n.asleepMin, 420)
        XCTAssertEqual(n.inBedMin, 450)
        XCTAssertEqual(n.deepMin, 70)
        XCTAssertEqual(n.score, 77)

        // A stored row for a different night lends no score.
        let other = StoredSleepSummary(night: key.addingTimeInterval(-86_400))
        other.sleepScore = 90
        XCTAssertEqual(SleepRecapAdapter.night(night, row: other).score, 0)

        // Prior nights exclude the one on screen and empty rows, newest first.
        other.asleepMin = 400; other.lightMin = 250; other.deepMin = 60; other.remMin = 90
        let empty = StoredSleepSummary(night: key.addingTimeInterval(-2 * 86_400))
        row.asleepMin = 420
        let prior = SleepRecapAdapter.prior([empty, row, other], excluding: key)
        XCTAssertEqual(prior.map(\.asleepMin), [400])
        XCTAssertEqual(prior.first?.score, 90)

        // The render-path gate: three earlier nights with sleep, the one on screen not counted.
        XCTAssertFalse(SleepRecapAdapter.mayHaveBaseline([empty, row, other], excluding: key))
        let more = (3...4).map { d -> StoredSleepSummary in
            let r = StoredSleepSummary(night: key.addingTimeInterval(-Double(d) * 86_400)); r.asleepMin = 410; return r
        }
        XCTAssertTrue(SleepRecapAdapter.mayHaveBaseline([row, other] + more, excluding: key))
    }
}

import XCTest
@testable import OpenCircuitKit

/// Schema v3 is a strict SUPERSET of schema v2: every key v2 emitted still appears, at the same
/// path, with the same value. There is no dual emitter and no compatibility mode — this suite IS
/// the compatibility story. If `testSchemaV3IsAStrictSupersetOfSchemaV2` fails, a consumer built
/// against the old export just broke, and the fix is to put the new data in a NEW key, not to
/// relax the expectation.
final class ExportSchemaV3Tests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)   // 2023-11-14T22:13:20Z
    private let t1 = Date(timeIntervalSince1970: 1_700_003_600)   // +1 h
    private let night = Date(timeIntervalSince1970: 1_699_920_000)

    /// Top-level keys that carry no health rows and therefore need no provenance classification.
    private let nonDataKeys: Set<String> = [
        "schemaVersion", "exportedAt", "meta", "provenance", "units", "notes"
    ]

    // MARK: - Fixtures

    private var sampleRow: ExportEngine.SampleRow {
        ExportEngine.SampleRow(kind: "heartRate", start: t0, end: t1, value: 72)
    }

    private var sleepRow: ExportEngine.SleepRow {
        ExportEngine.SleepRow(
            night: night, asleepMin: 450, deepMin: 90, lightMin: 180,
            remMin: 120, awakeMin: 30, efficiency: 0.9375,
            inBedStart: t0, inBedEnd: t1, skinTempC: 36.5, sleepScore: 82, stressScore: 40,
            feelScore: 7, hrDeep: 55, hrLight: 60, hrRem: 64, hrAwake: 68,
            movementLevels: [0, 1, 2])
    }

    private var evidenceRow: ExportEngine.HistorySyncEvidenceRow {
        var trace = HistoryChannelTrace(label: "sleep", channel: 0x00, startedAt: t0)
        trace.finishedAt = t1
        trace.sawSyncAck = true
        trace.page4CCount = 1
        trace.endMarkerCount = 1
        trace.recordsAtStart = 2
        trace.recordsAtEnd = 8
        trace.exitReason = .endMarker
        return ExportEngine.HistorySyncEvidenceRow(
            capturedAt: t0, ringID: "ring-1", trigger: "manual",
            sleepCommitted: true, stagedSleepSegments: 4,
            mergedRecordCount: 8, historySampleCount: 10,
            rawRecordBlobBase64: "AQID", channels: [trace])
    }

    private var hypnogram: [SleepSegment] {
        [SleepSegment(start: t0, end: t0.addingTimeInterval(150), stage: .asleepCore),
         SleepSegment(start: t0.addingTimeInterval(150),
                      end: t0.addingTimeInterval(600), stage: .asleepDeep)]
    }

    /// The shape `SleepStaging.stageSegments` ACTUALLY returns: a whole-night `.inBed` envelope,
    /// then the stage segments tiling that same span (SleepStaging.swift:669-688). The stored blob
    /// carries it verbatim, so this is what `ExportBuilder` hands the serializer — the old fixture
    /// above (stages only) is the one shape the production path never produces.
    private var stagedNight: [SleepSegment] {
        let end = t0.addingTimeInterval(1_800)
        return [SleepSegment(start: t0, end: end, stage: .inBed),
                SleepSegment(start: t0, end: t0.addingTimeInterval(300), stage: .awake),
                SleepSegment(start: t0.addingTimeInterval(300),
                             end: t0.addingTimeInterval(900), stage: .asleepCore),
                SleepSegment(start: t0.addingTimeInterval(900),
                             end: t0.addingTimeInterval(1_500), stage: .asleepDeep),
                SleepSegment(start: t0.addingTimeInterval(1_500), end: end, stage: .awake)]
    }

    /// A night stitched from two fragments carries one `.inBed` envelope PER FRAGMENT
    /// (SleepStaging.swift:712-713), so the overlap is not one fixed row.
    private var stitchedNight: [SleepSegment] {
        let gap = t0.addingTimeInterval(3_600)
        return [SleepSegment(start: t0, end: t0.addingTimeInterval(600), stage: .inBed),
                SleepSegment(start: t0, end: t0.addingTimeInterval(600), stage: .asleepCore),
                SleepSegment(start: gap, end: gap.addingTimeInterval(600), stage: .inBed),
                SleepSegment(start: gap, end: gap.addingTimeInterval(600), stage: .asleepREM)]
    }

    private var metadata: ExportEngine.ExportMetadata {
        ExportEngine.ExportMetadata(
            exportedAt: t0, rangeStart: t0, rangeEnd: t1,
            appVersion: "1.0", appBuild: "37", deviceModel: "iPhone15,2", osVersion: "18.5",
            ringModel: "RingConn Gen2", ringFirmware: "FR02.018", ringGeneration: "Gen 2",
            ringIdentifier: "1E2E3E4E-0000-0000-0000-000000000001",
            timeZoneIdentifier: "Europe/Amsterdam", timeZoneOffsetSeconds: 3_600)
    }

    private func session(hypnogram: [SleepSegment] = [],
                         osa: ExportEngine.OSARow? = nil,
                         coverage: ExportCoverage.Assessment? = nil,
                         night nightDate: Date? = nil) -> ExportEngine.SleepSessionRow {
        let n = nightDate ?? night
        return ExportEngine.SleepSessionRow(
            sessionID: ExportEngine.sessionID(night: n), night: n,
            inBedStart: t0, inBedEnd: t1, sleepOnset: t0.addingTimeInterval(600),
            sleepWake: t1, isManuallyEdited: false,
            hypnogram: hypnogram, summary: sleepRow, osa: osa, coverage: coverage)
    }

    private func parsed(_ json: String?) -> [String: Any] {
        guard let json, let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("toJSON did not produce a JSON object")
            return [:]
        }
        return obj
    }

    // MARK: - 1. Superset lock

    func testSchemaV3IsAStrictSupersetOfSchemaV2() {
        let obj = parsed(ExportEngine.toJSON(
            samples: [sampleRow], sleep: [sleepRow],
            daily: [ExportEngine.DailyRow(day: night, steps: 8_000)],
            stepSamples: [ExportEngine.StepSampleRow(start: t0, end: t1, delta: 123)],
            naps: [ExportEngine.NapRow(start: t0, end: t1, asleepMin: 30, isLongNap: false)],
            daytimeTemperatures: [ExportEngine.DaytimeTemperatureRow(time: t0, celsius: 34.2)],
            historySyncEvidence: [evidenceRow], now: t0))

        // The one deliberate change from v2. Everything else below must be identical.
        XCTAssertEqual(obj["schemaVersion"] as? Int, 3)
        XCTAssertEqual(obj["exportedAt"] as? String, "2023-11-14T22:13:20.000Z")

        for key in ["samples", "sleep", "daily", "stepSamples", "naps",
                    "daytimeTemperatures", "historySyncEvidence"] {
            XCTAssertNotNil(obj[key] as? [[String: Any]], "v2 section '\(key)' disappeared")
        }

        let dayLabel = localDayLabel(night)
        assertElement(obj, "samples", equals: [
            "kind": "heartRate",
            "start": "2023-11-14T22:13:20.000Z",
            "end": "2023-11-14T23:13:20.000Z",
            "value": 72.0
        ])
        assertElement(obj, "sleep", equals: [
            "night": dayLabel,
            "asleepMin": 450, "deepMin": 90, "lightMin": 180, "remMin": 120, "awakeMin": 30,
            "efficiency": 0.9375,
            "inBedStart": "2023-11-14T22:13:20.000Z",
            "inBedEnd": "2023-11-14T23:13:20.000Z",
            "skinTempC": 36.5,
            "sleepScore": 82, "stressScore": 40, "feelScore": 7,
            "hrDeep": 55, "hrLight": 60, "hrRem": 64, "hrAwake": 68,
            "movementLevels": [0, 1, 2]
        ])
        assertElement(obj, "daily", equals: ["day": dayLabel, "steps": 8_000])
        assertElement(obj, "stepSamples", equals: [
            "start": "2023-11-14T22:13:20.000Z",
            "end": "2023-11-14T23:13:20.000Z",
            "delta": 123
        ])
        assertElement(obj, "naps", equals: [
            "start": "2023-11-14T22:13:20.000Z",
            "end": "2023-11-14T23:13:20.000Z",
            "asleepMin": 30, "isLongNap": false
        ])
        assertElement(obj, "daytimeTemperatures", equals: [
            "time": "2023-11-14T22:13:20.000Z", "celsius": 34.2
        ])
        assertElement(obj, "historySyncEvidence", equals: [
            "capturedAt": "2023-11-14T22:13:20.000Z",
            "ringID": "ring-1",
            "trigger": "manual",
            "sleepCommitted": true,
            "stagedSleepSegments": 4,
            "mergedRecordCount": 8,
            "historySampleCount": 10,
            "rawRecordBlobBase64": "AQID",
            "channels": [[
                "label": "sleep",
                "channel": 0,
                "startedAt": "2023-11-14T22:13:20.000Z",
                "finishedAt": "2023-11-14T23:13:20.000Z",
                "outcome": "complete",
                "sawSyncAck": true,
                "syncAckFlag": NSNull(),
                "page4CCount": 1,
                "page47Count": 0,
                "endMarkerCount": 1,
                "recordsAtStart": 2,
                "recordsAtEnd": 8,
                "recordsAdded": 6,
                "firstOpcode": NSNull(),
                "lastOpcode": NSNull(),
                "exitReason": "endMarker"
            ]]
        ])
    }

    func testV2CallSiteWithoutNewParametersStillEmitsEverySection() {
        // Signature compatibility: the pre-v3 call shape must still compile and still work.
        let obj = parsed(ExportEngine.toJSON(samples: [], sleep: [], daily: [], now: t0))
        for key in ["samples", "sleep", "daily", "stepSamples", "naps",
                    "daytimeTemperatures", "historySyncEvidence"] {
            XCTAssertEqual((obj[key] as? [[String: Any]])?.count, 0, "'\(key)' must still exist")
        }
        XCTAssertNil(obj["meta"], "meta must be absent when no metadata was supplied")
        XCTAssertNil(obj["sleepSessions"], "sleepSessions must be absent when empty")
    }

    // MARK: - 7. Metadata

    func testMetaBlockOmittedEntirelyWhenMetadataIsNil() {
        let obj = parsed(ExportEngine.toJSON(samples: [sampleRow], sleep: [], daily: [], now: t0))
        XCTAssertNil(obj["meta"])
    }

    func testMetaBlockCarriesEveryField() {
        let obj = parsed(ExportEngine.toJSON(samples: [], sleep: [], daily: [],
                                             now: t0, metadata: metadata))
        guard let meta = obj["meta"] as? [String: Any] else { return XCTFail("meta missing") }
        XCTAssertEqual(meta["schemaVersion"] as? Int, 3)
        XCTAssertEqual(meta["appVersion"] as? String, "1.0")
        XCTAssertEqual(meta["appBuild"] as? String, "37")
        XCTAssertEqual(meta["deviceModel"] as? String, "iPhone15,2")
        XCTAssertEqual(meta["osVersion"] as? String, "18.5")
        XCTAssertEqual(meta["ringModel"] as? String, "RingConn Gen2")
        XCTAssertEqual(meta["ringFirmware"] as? String, "FR02.018")
        XCTAssertEqual(meta["ringGeneration"] as? String, "Gen 2")
        XCTAssertEqual(meta["ringIdentifier"] as? String,
                       "1E2E3E4E-0000-0000-0000-000000000001")
        XCTAssertEqual(meta["timeZoneIdentifier"] as? String, "Europe/Amsterdam")
        XCTAssertEqual(meta["timeZoneOffsetSeconds"] as? Int, 3_600)
        XCTAssertEqual(meta["timestampPolicy"] as? String,
                       ExportEngine.timestampPolicyDescription)
        for key in ["exportedAt", "rangeStart", "rangeEnd"] {
            XCTAssertNotNil(meta[key] as? String, "\(key) missing from meta")
        }
    }

    func testMetadataCSVRoundTripsEveryField() {
        let csv = ExportEngine.metadataCSV(metadata)
        let records = ExportEngineTests.parseCSV(csv)
        XCTAssertEqual(records.first ?? [], ["field", "value"])

        var byField: [String: String] = [:]
        for record in records.dropFirst() where record.count == 2 { byField[record[0]] = record[1] }
        XCTAssertEqual(records.count - 1, byField.count, "duplicate or malformed metadata rows")

        // Field names must be the JSON keys, so the two views can be joined.
        let obj = parsed(ExportEngine.toJSON(samples: [], sleep: [], daily: [],
                                             now: t0, metadata: metadata))
        guard let meta = obj["meta"] as? [String: Any] else { return XCTFail("meta missing") }
        XCTAssertEqual(Set(byField.keys), Set(meta.keys),
                       "metadataCSV and the JSON meta block must name the same fields")

        XCTAssertEqual(byField["schemaVersion"], "3")
        XCTAssertEqual(byField["appVersion"], "1.0")
        XCTAssertEqual(byField["appBuild"], "37")
        XCTAssertEqual(byField["deviceModel"], "iPhone15,2")
        XCTAssertEqual(byField["osVersion"], "18.5")
        XCTAssertEqual(byField["ringModel"], "RingConn Gen2")
        XCTAssertEqual(byField["ringFirmware"], "FR02.018")
        XCTAssertEqual(byField["ringGeneration"], "Gen 2")
        XCTAssertEqual(byField["ringIdentifier"], "1E2E3E4E-0000-0000-0000-000000000001")
        XCTAssertEqual(byField["timeZoneIdentifier"], "Europe/Amsterdam")
        XCTAssertEqual(byField["timeZoneOffsetSeconds"], "3600")
        XCTAssertEqual(byField["timestampPolicy"], ExportEngine.timestampPolicyDescription)
        XCTAssertEqual(byField["exportedAt"], ExportEngine.offsetISO8601(t0))
    }

    func testMetadataCSVQuotesTheDeviceModelComma() {
        // "iPhone15,2" is the exact value that used to corrupt a row — it has a comma in it.
        let csv = ExportEngine.metadataCSV(metadata)
        XCTAssertTrue(csv.contains("deviceModel,\"iPhone15,2\""),
                      "deviceModel must be RFC-4180 quoted — got:\n\(csv)")
    }

    /// PRIVACY, the half this layer can actually enforce: the metadata block's FIELD SET is locked,
    /// so no MAC-carrying or device-name field can be added to the schema without failing here.
    ///
    /// The previous version of this test built an `ExportMetadata` by hand — a struct with no MAC
    /// field — and then asserted no MAC appeared. It could not fail. The real risk is upstream, in
    /// `ExportBuilder` populating `ringModel` from the ring's ADVERTISED name (whose trailing
    /// "-XXXX" is the last two MAC bytes); that path is pinned in the app target by
    /// `ExportBuilderTests.testTheExportMetadataStripsTheAdvertisedNamesMACSuffix`, which is where
    /// the stripping actually lives.
    func testMetadataFieldSetIsLockedAgainstAMACOrDeviceNameField() {
        let fields = Set(ExportEngineTests.parseCSV(ExportEngine.metadataCSV(metadata))
            .dropFirst().compactMap(\.first))
        XCTAssertEqual(fields, [
            "schemaVersion", "exportedAt", "rangeStart", "rangeEnd",
            "appVersion", "appBuild", "deviceModel", "osVersion",
            "ringModel", "ringFirmware", "ringGeneration", "ringIdentifier",
            "timeZoneIdentifier", "timeZoneOffsetSeconds", "timestampPolicy"
        ], """
        The metadata field set changed. If a field carrying a ring MAC or a user-assigned device \
        name was added, remove it — this file is one users hand to third parties. If the addition \
        is benign, add it here deliberately.
        """)
    }

    /// The detector the test above relies on is not vacuous: fed a metadata block that DOES carry a
    /// MAC, the same search finds it. Without this control a green "no MAC" assertion proves only
    /// that the search ran.
    func testTheMACSearchWouldActuallyCatchAMACIfOneWerePresent() {
        let clean = ExportEngine.metadataCSV(metadata)
        XCTAssertFalse(clean.contains("F8:79:99:F7:03:AD"))
        XCTAssertFalse(clean.contains("-03AD"))

        let poisoned = ExportEngine.ExportMetadata(
            exportedAt: t0, rangeStart: t0, rangeEnd: t1,
            ringModel: "RingConn Gen2-03AD",                       // the raw ADVERTISED name
            ringIdentifier: "F8:79:99:F7:03:AD")                   // a MAC in the id slot
        let poisonedCSV = ExportEngine.metadataCSV(poisoned)
        XCTAssertTrue(poisonedCSV.contains("F8:79:99:F7:03:AD"))
        XCTAssertTrue(poisonedCSV.contains("-03AD"),
                      "the serializer copies its inputs verbatim, so the MAC guarantee has to be "
                      + "made upstream — this test only proves the check can fail")
    }

    // MARK: - 6. Session + hypnogram CSV

    func testSleepSessionsCSVHeaderIsExactAndEmptyIsHeaderOnly() {
        let csv = ExportEngine.sleepSessionsCSV([])
        XCTAssertEqual(csv, "sessionID,night,inBedStart,inBedEnd,sleepOnset,sleepWake,isManuallyEdited,asleepMin,deepMin,lightMin,remMin,awakeMin,efficiency,sleepScore,stressScore,hypnogramSegments,osaAvgSpO2,osaMinSpO2,osaTimeBelow90Sec,osaODI,osaValidWindows,coverageFraction,expectedSamples,observedSamples,longestGapSeconds")
        XCTAssertFalse(csv.contains("\n"), "empty input is header-only")
    }

    func testSleepSessionsCSVWithoutOSAOrCoverageEmitsEmptyFieldsNotZeros() {
        let csv = ExportEngine.sleepSessionsCSV([session()])
        let records = ExportEngineTests.parseCSV(csv)
        XCTAssertEqual(records.count, 2)
        let row = records[1]
        XCTAssertEqual(row.count, 25)
        for index in 16 ... 24 {
            XCTAssertEqual(row[index], "",
                           "column \(index) must be EMPTY when absent — 0 is a real reading")
        }
        XCTAssertEqual(row[0], "night-\(localDayLabel(night))")
        XCTAssertEqual(row[1], localDayLabel(night))
        XCTAssertEqual(row[15], "",
                       "no stored timeline is an ABSENCE — 0 would claim we staged the night and "
                       + "found no stage blocks, which is a different fact")
    }

    // MARK: - hypnogramSegments: absence and zero must be different values
    //
    // `hypnogram == []` means NOT RECORDED (a night staged before the column existed). A night whose
    // stored blob holds only the `.inBed` envelope WAS recorded and partitions to no stage blocks.
    // Printing "0" for both made them indistinguishable in the one column a consumer would use to
    // decide whether a timeline is available at all — while the file's own notes promise otherwise.

    func testHypnogramSegmentsIsEmptyForANotRecordedTimelineAndZeroForAnEnvelopeOnlyNight() {
        let notRecorded = ExportEngineTests.parseCSV(
            ExportEngine.sleepSessionsCSV([session(hypnogram: [])]))[1]
        XCTAssertEqual(notRecorded[15], "", "no timeline recorded ⇒ EMPTY, never 0")

        let envelopeOnly = ExportEngineTests.parseCSV(
            ExportEngine.sleepSessionsCSV([
                session(hypnogram: [SleepSegment(start: t0, end: t1, stage: .inBed)])
            ]))[1]
        XCTAssertEqual(envelopeOnly[15], "0",
                       "a recorded timeline with no stage blocks IS a measured 0")
    }

    func testHypnogramJSONKeyIsAbsentWhenNotRecordedAndEmptyWhenRecordedWithNoStages() {
        let absent = parsed(ExportEngine.toJSON(samples: [], sleep: [], daily: [], now: t0,
                                                sleepSessions: [session(hypnogram: [])]))
        XCTAssertNil((absent["sleepSessions"] as? [[String: Any]])?.first?["hypnogram"],
                     "not recorded ⇒ omit the key, the same convention osa/coverage use")

        let recorded = parsed(ExportEngine.toJSON(
            samples: [], sleep: [], daily: [], now: t0,
            sleepSessions: [session(hypnogram: [SleepSegment(start: t0, end: t1, stage: .inBed)])]))
        let segments = (recorded["sleepSessions"] as? [[String: Any]])?.first?["hypnogram"]
        XCTAssertEqual((segments as? [[String: Any]])?.count, 0,
                       "recorded but no stage blocks ⇒ the key is present and empty")
    }

    func testSleepSessionsCSVWithOSAAndCoverage() {
        let coverage = ExportCoverage.assess(
            sampleTimes: (0 ..< 20).map { t0.addingTimeInterval(Double($0) * 150) },
            from: t0, to: t0.addingTimeInterval(24 * 150))
        let osa = ExportEngine.OSARow(avgSpO2: 95.4, minSpO2: 88.0,
                                      timeBelow90Sec: 312.5, odi: 4.25, validWindows: 96)
        let records = ExportEngineTests.parseCSV(
            ExportEngine.sleepSessionsCSV([session(hypnogram: hypnogram, osa: osa,
                                                   coverage: coverage)]))
        let row = records[1]
        XCTAssertEqual(row[15], "2", "two hypnogram segments")
        XCTAssertEqual(row[16], "95.40")
        XCTAssertEqual(row[17], "88.00")
        XCTAssertEqual(row[18], "312.5")
        XCTAssertEqual(row[19], "4.25")
        XCTAssertEqual(row[20], "96")
        XCTAssertEqual(row[21], String(format: "%.4f", coverage.coverageFraction))
        XCTAssertEqual(row[22], "24")
        XCTAssertEqual(row[23], "20")
        XCTAssertEqual(row[24], String(format: "%.1f", coverage.longestGapSeconds))
    }

    func testZeroValidWindowsIsTreatedAsNoAssessmentAtAll() {
        // A row of zeros from an undrained assessment is indistinguishable from a measured
        // perfect night — the serializer must drop it, not print it.
        let empty = ExportEngine.OSARow(avgSpO2: 0, minSpO2: 0, timeBelow90Sec: 0,
                                        odi: 0, validWindows: 0)
        let row = ExportEngineTests.parseCSV(
            ExportEngine.sleepSessionsCSV([session(osa: empty)]))[1]
        for index in 16 ... 20 {
            XCTAssertEqual(row[index], "", "OSA column \(index) must be empty, not 0")
        }
        let obj = parsed(ExportEngine.toJSON(samples: [], sleep: [], daily: [], now: t0,
                                             sleepSessions: [session(osa: empty)]))
        XCTAssertNil((obj["sleepSessions"] as? [[String: Any]])?.first?["osa"])
    }

    func testSleepSessionsCSVOrderingIsDeterministic() {
        let earlier = night
        let later = night.addingTimeInterval(86_400)
        let rows = [session(night: later), session(night: earlier)]
        let ids = ExportEngineTests.parseCSV(ExportEngine.sleepSessionsCSV(rows))
            .dropFirst().map { $0[0] }
        XCTAssertEqual(ids, [rows[0].sessionID, rows[1].sessionID],
                       "rows are emitted in the order given, never reordered")
    }

    func testHypnogramCSVHeaderAndEmptyInput() {
        XCTAssertEqual(ExportEngine.hypnogramCSV([]),
                       "sessionID,start,end,stage,durationSec")
    }

    func testHypnogramCSVEmitsOneRowPerSegmentAcrossSessions() {
        let a = session(hypnogram: hypnogram)
        let b = session(hypnogram: [SleepSegment(start: t1, end: t1.addingTimeInterval(300),
                                                 stage: .asleepREM)],
                        night: night.addingTimeInterval(86_400))
        let records = ExportEngineTests.parseCSV(ExportEngine.hypnogramCSV([a, b]))
        XCTAssertEqual(records.count, 4, "header + 2 + 1 segments")
        XCTAssertEqual(records[1][0], a.sessionID)
        XCTAssertEqual(records[1][3], "asleepCore")
        XCTAssertEqual(records[1][4], "150")
        XCTAssertEqual(records[2][3], "asleepDeep")
        XCTAssertEqual(records[2][4], "450")
        XCTAssertEqual(records[3][0], b.sessionID)
        XCTAssertEqual(records[3][3], "asleepREM")
        XCTAssertEqual(records[3][4], "300")
    }

    func testSessionWithNoHypnogramEmitsNoHypnogramRows() {
        XCTAssertEqual(ExportEngine.hypnogramCSV([session()]),
                       "sessionID,start,end,stage,durationSec")
    }

    // MARK: - The emitted hypnogram is a PARTITION, not a partition plus an umbrella
    //
    // `SleepStaging.stageSegments` returns an all-night `.inBed` segment OVERLAPPING every stage
    // segment. Emitted verbatim, `SUM(durationSec) GROUP BY sessionID` — the obvious consumer
    // query — returned exactly 2x the real in-bed time and `hypnogramSegments` over-counted the
    // stage blocks by one per stitched fragment.

    func testEmittedHypnogramCarriesNoOverlappingInBedEnvelope() {
        let rows = ExportEngineTests.parseCSV(
            ExportEngine.hypnogramCSV([session(hypnogram: stagedNight)])).dropFirst()
        XCTAssertEqual(rows.count, 4, "the 4 stage blocks, not 5 rows")
        XCTAssertFalse(rows.contains { $0[3] == "inBed" },
                       "the in-bed envelope is carried by inBedStart/inBedEnd, not as a segment")
    }

    func testEmittedHypnogramDurationsSumToTheInBedSpanNotDoubleIt() {
        let inBedSpan = 1_800.0   // stagedNight's envelope
        let rows = ExportEngineTests.parseCSV(
            ExportEngine.hypnogramCSV([session(hypnogram: stagedNight)])).dropFirst()
        let total = rows.compactMap { Double($0[4]) }.reduce(0, +)
        XCTAssertEqual(total, inBedSpan, accuracy: 0.001,
                       "summing durationSec must give the night, not twice the night")
    }

    func testEmittedHypnogramSegmentsDoNotOverlap() {
        for fixture in [stagedNight, stitchedNight] {
            let rows = ExportEngineTests.parseCSV(
                ExportEngine.hypnogramCSV([session(hypnogram: fixture)])).dropFirst()
            let spans = rows.map { ($0[1], $0[2]) }.sorted { $0.0 < $1.0 }
            for (a, b) in zip(spans, spans.dropFirst()) {
                XCTAssertLessThanOrEqual(a.1, b.0, "segments \(a) and \(b) overlap")
            }
        }
    }

    func testStitchedNightDropsEveryFragmentEnvelopeNotJustTheFirst() {
        let rows = ExportEngineTests.parseCSV(
            ExportEngine.hypnogramCSV([session(hypnogram: stitchedNight)])).dropFirst()
        XCTAssertEqual(rows.count, 2, "two fragments, two stage blocks, zero envelopes")
        XCTAssertEqual(rows.map { $0[3] }, ["asleepCore", "asleepREM"])
    }

    func testHypnogramSegmentCountExcludesTheEnvelopeInBothViews() {
        let row = ExportEngineTests.parseCSV(
            ExportEngine.sleepSessionsCSV([session(hypnogram: stagedNight)]))[1]
        XCTAssertEqual(row[15], "4", "hypnogramSegments counts stage blocks, not the envelope")

        let obj = parsed(ExportEngine.toJSON(samples: [], sleep: [], daily: [], now: t0,
                                             sleepSessions: [session(hypnogram: stagedNight)]))
        let segments = (obj["sleepSessions"] as? [[String: Any]])?.first?["hypnogram"]
            as? [[String: Any]]
        XCTAssertEqual(segments?.count, 4, "the JSON view must agree with the CSV count")
        XCTAssertFalse(segments?.contains { $0["stage"] as? String == "inBed" } ?? true)
    }

    /// A night whose stored blob is ONLY an envelope has no timeline to report, and the file's
    /// contract already says an empty hypnogram means NOT RECORDED.
    func testEnvelopeOnlyNightEmitsNoRowsRatherThanAnAllNightBar() {
        let envelopeOnly = [SleepSegment(start: t0, end: t1, stage: .inBed)]
        XCTAssertEqual(ExportEngine.hypnogramCSV([session(hypnogram: envelopeOnly)]),
                       "sessionID,start,end,stage,durationSec")
    }

    // MARK: - sleepSessions JSON

    func testSleepSessionsJSONOmittedWhenEmpty() {
        let obj = parsed(ExportEngine.toJSON(samples: [], sleep: [], daily: [], now: t0,
                                             sleepSessions: []))
        XCTAssertNil(obj["sleepSessions"])
    }

    func testSleepSessionJSONOmitsAbsentOSAAndCoverage() {
        let obj = parsed(ExportEngine.toJSON(samples: [], sleep: [], daily: [], now: t0,
                                             sleepSessions: [session()]))
        guard let sessions = obj["sleepSessions"] as? [[String: Any]], let s = sessions.first else {
            return XCTFail("sleepSessions missing")
        }
        XCTAssertNil(s["osa"], "absent OSA must be omitted, not zero-filled")
        XCTAssertNil(s["coverage"], "absent coverage must be omitted, not zero-filled")
        XCTAssertNil(s["hypnogram"], "a timeline that was never recorded must be omitted too")
        XCTAssertNotNil(s["summary"] as? [String: Any])
        XCTAssertEqual(s["sessionID"] as? String, "night-\(localDayLabel(night))")
    }

    func testSleepSessionJSONCarriesHypnogramOSAAndCoverage() {
        let coverage = ExportCoverage.assess(sampleTimes: [t0], from: t0,
                                             to: t0.addingTimeInterval(3_000))
        let osa = ExportEngine.OSARow(avgSpO2: 95.4, minSpO2: 88, timeBelow90Sec: 312.5,
                                      odi: 4.25, validWindows: 96)
        let obj = parsed(ExportEngine.toJSON(
            samples: [], sleep: [], daily: [], now: t0,
            sleepSessions: [session(hypnogram: hypnogram, osa: osa, coverage: coverage)]))
        guard let s = (obj["sleepSessions"] as? [[String: Any]])?.first else {
            return XCTFail("sleepSessions missing")
        }
        XCTAssertEqual((s["hypnogram"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(((s["hypnogram"] as? [[String: Any]])?.first?["stage"]) as? String,
                       "asleepCore")
        XCTAssertEqual((s["osa"] as? [String: Any])?["validWindows"] as? Int, 96)
        XCTAssertEqual((s["coverage"] as? [String: Any])?["observedSamples"] as? Int, 1)
        XCTAssertEqual((s["coverage"] as? [String: Any])?["expectedSamples"] as? Int, 20)
        XCTAssertEqual(((s["coverage"] as? [String: Any])?["gaps"] as? [[String: Any]])?.count, 1)
    }

    // MARK: - 8. Timestamp policy

    func testOffsetFormatterEmitsAUTCOffsetNotZ() {
        // Pinned zones, so the assertion cannot go vacuous on a UTC test machine.
        XCTAssertEqual(
            ExportEngine.offsetISO8601(t0, timeZone: TimeZone(identifier: "Europe/Amsterdam")!),
            "2023-11-14T23:13:20.000+01:00")
        XCTAssertEqual(
            ExportEngine.offsetISO8601(t0, timeZone: TimeZone(identifier: "Asia/Kolkata")!),
            "2023-11-15T03:43:20.000+05:30")
        for id in ["Europe/Amsterdam", "Asia/Kolkata", "America/New_York"] {
            let s = ExportEngine.offsetISO8601(t0, timeZone: TimeZone(identifier: id)!)
            XCTAssertFalse(s.hasSuffix("Z"), "\(id) must print an offset, not a UTC Z: \(s)")
        }
    }

    func testExistingSectionsKeepUTCZWhileNewSectionsCarryTheLocalOffset() {
        let obj = parsed(ExportEngine.toJSON(
            samples: [sampleRow], sleep: [sleepRow], daily: [], now: t0,
            metadata: metadata,
            sleepSessions: [session(hypnogram: hypnogram)]))

        // v2 sections: unchanged UTC bytes.
        XCTAssertEqual(obj["exportedAt"] as? String, "2023-11-14T22:13:20.000Z")
        XCTAssertEqual((obj["samples"] as? [[String: Any]])?.first?["start"] as? String,
                       "2023-11-14T22:13:20.000Z")
        XCTAssertEqual((obj["sleep"] as? [[String: Any]])?.first?["inBedStart"] as? String,
                       "2023-11-14T22:13:20.000Z")

        // v3 sections: the device's local offset policy.
        guard let s = (obj["sleepSessions"] as? [[String: Any]])?.first else {
            return XCTFail("sleepSessions missing")
        }
        XCTAssertEqual(s["inBedStart"] as? String, ExportEngine.offsetISO8601(t0))
        XCTAssertEqual((s["summary"] as? [String: Any])?["inBedStart"] as? String,
                       ExportEngine.offsetISO8601(t0))
        XCTAssertEqual((s["hypnogram"] as? [[String: Any]])?.first?["start"] as? String,
                       ExportEngine.offsetISO8601(t0))
        XCTAssertEqual((obj["meta"] as? [String: Any])?["exportedAt"] as? String,
                       ExportEngine.offsetISO8601(t0))
    }

    // MARK: The declared zone and the printed offsets can never disagree
    //
    // Both device-local formatters used to be `static let`, i.e. built ONCE PER PROCESS with the
    // `TimeZone.current` SNAPSHOT taken at first use. `ExportBuilder` reads the zone LIVE for
    // `meta.timeZoneOffsetSeconds`, so an app left resident across a flight or a DST boundary
    // declared one zone in `meta` and printed another in every v3 timestamp — in the export whose
    // entire selling point to the tester who asked for it is unambiguous timestamps.

    func testDeviceLocalOffsetsFollowALiveTimeZoneChange() {
        let original = NSTimeZone.default
        defer { NSTimeZone.default = original }

        NSTimeZone.default = TimeZone(identifier: "Europe/Amsterdam")!
        XCTAssertEqual(ExportEngine.offsetISO8601(t0), "2023-11-14T23:13:20.000+01:00")

        // Same process, same formatter cache, different zone.
        NSTimeZone.default = TimeZone(identifier: "Asia/Kolkata")!
        XCTAssertEqual(ExportEngine.offsetISO8601(t0), "2023-11-15T03:43:20.000+05:30",
                       "the offset formatter froze the zone it was first built with")
    }

    func testDeviceLocalDayLabelsFollowALiveTimeZoneChange() {
        let original = NSTimeZone.default
        defer { NSTimeZone.default = original }

        // 2023-11-14T22:13:20Z straddles the two zones' day boundary.
        NSTimeZone.default = TimeZone(identifier: "Europe/Amsterdam")!
        XCTAssertEqual(ExportEngine.sessionID(night: t0), "night-2023-11-14")

        NSTimeZone.default = TimeZone(identifier: "Asia/Kolkata")!
        XCTAssertEqual(ExportEngine.sessionID(night: t0), "night-2023-11-15",
                       "the yyyy-MM-dd formatter froze the zone it was first built with")
    }

    /// The export FILENAME's day stamp is the same live label as everything inside the file.
    /// `ExportBuilder` used to keep its own `static let` formatter for this, which snapshotted
    /// `TimeZone.current` once per process — so after a zone change the name on the file disagreed
    /// with the `night`/`day` labels within it, which is exactly what the doc comment promised
    /// could not happen. There must be ONE local-day source, and this pins it.
    func testFilenameDayStampFollowsTheSameLiveTimeZoneAsTheLabelsInsideTheFile() {
        let original = NSTimeZone.default
        defer { NSTimeZone.default = original }

        NSTimeZone.default = TimeZone(identifier: "Europe/Amsterdam")!
        XCTAssertEqual(ExportEngine.dayStamp(t0), "2023-11-14")
        XCTAssertEqual("night-" + ExportEngine.dayStamp(t0), ExportEngine.sessionID(night: t0))

        NSTimeZone.default = TimeZone(identifier: "Asia/Kolkata")!
        XCTAssertEqual(ExportEngine.dayStamp(t0), "2023-11-15",
                       "the filename day stamp froze the zone it was first built with")
        XCTAssertEqual("night-" + ExportEngine.dayStamp(t0), ExportEngine.sessionID(night: t0),
                       "filename stamp and session id must never describe different days")
    }

    /// The whole point: what `meta` DECLARES and what the file PRINTS come from one live source.
    func testDeclaredZoneAlwaysMatchesThePrintedOffsetAfterAZoneChange() {
        let original = NSTimeZone.default
        defer { NSTimeZone.default = original }

        // Four IANA zones spanning both signs and a half-hour offset. (No "UTC": Foundation
        // canonicalises it to "GMT", which would make the identifier assertion below test the
        // alias table rather than the export.)
        for id in ["Europe/Amsterdam", "Asia/Kolkata", "America/New_York", "Australia/Sydney"] {
            let zone = TimeZone(identifier: id)!
            NSTimeZone.default = zone
            // Metadata built with its DEFAULT zone arguments, exactly as `ExportEngine` intends.
            let live = ExportEngine.ExportMetadata(exportedAt: t0, rangeStart: t0, rangeEnd: t1)
            XCTAssertEqual(live.timeZoneIdentifier, id)
            XCTAssertEqual(live.timeZoneOffsetSeconds, zone.secondsFromGMT(),
                           "\(id): the declared offset must be this zone's, read live")

            // Every printed timestamp must be in the zone `meta` names. (The scalar
            // `timeZoneOffsetSeconds` is the offset at EXPORT time; a timestamp on the other side
            // of a DST boundary legitimately prints a different offset in the SAME zone, which is
            // why the invariant is the zone, not the number.)
            let declared = TimeZone(identifier: live.timeZoneIdentifier)!
            for date in [t0, t1, night] {
                XCTAssertEqual(ExportEngine.offsetISO8601(date),
                               ExportEngine.offsetISO8601(date, timeZone: declared),
                               "\(id): printed offsets must use the zone meta declares")
            }
        }
    }

    func testTimestampPolicyStatesBothConventions() {
        XCTAssertTrue(ExportEngine.timestampPolicyDescription.contains("UTC"))
        XCTAssertTrue(ExportEngine.timestampPolicyDescription.contains("'Z'"))
        XCTAssertTrue(ExportEngine.timestampPolicyDescription.contains("UTC offset"))
        XCTAssertTrue(ExportEngine.timestampPolicyDescription.contains("yyyy-MM-dd"))
    }

    // MARK: - 9. Provenance / units / notes

    func testEveryEmittedSectionIsClassifiedInProvenance() {
        let obj = parsed(ExportEngine.toJSON(
            samples: [sampleRow], sleep: [sleepRow],
            daily: [ExportEngine.DailyRow(day: night, steps: 8_000)],
            stepSamples: [ExportEngine.StepSampleRow(start: t0, end: t1, delta: 1)],
            naps: [ExportEngine.NapRow(start: t0, end: t1, asleepMin: 30, isLongNap: false)],
            daytimeTemperatures: [ExportEngine.DaytimeTemperatureRow(time: t0, celsius: 34.2)],
            historySyncEvidence: [evidenceRow], now: t0,
            metadata: metadata,
            sleepSessions: [session(hypnogram: hypnogram)]))

        guard let provenance = obj["provenance"] as? [String: String] else {
            return XCTFail("provenance block missing")
        }
        let emitted = Set(obj.keys).subtracting(nonDataKeys)
        XCTAssertFalse(emitted.isEmpty)
        for key in emitted {
            XCTAssertNotNil(provenance[key],
                            """
                            Section '\(key)' is emitted but has no provenance classification. \
                            Every data section must be labelled measured/derived/diagnostic — \
                            an unlabelled one reads as if the ring reported it.
                            """)
        }
        for (key, value) in provenance {
            XCTAssertTrue(["measured", "derived", "diagnostic"].contains(value),
                          "'\(key)' has unknown provenance '\(value)'")
        }
        XCTAssertEqual(provenance["samples"], "measured")
        XCTAssertEqual(provenance["stepSamples"], "measured")
        XCTAssertEqual(provenance["daytimeTemperatures"], "measured")
        XCTAssertEqual(provenance["sleep"], "derived")
        XCTAssertEqual(provenance["daily"], "derived")
        XCTAssertEqual(provenance["naps"], "derived")
        XCTAssertEqual(provenance["historySyncEvidence"], "diagnostic")
        // The load-bearing honesty claim: staging is OURS, coverage is a count of what we hold.
        XCTAssertEqual(provenance["sleepSessions.hypnogram"], "derived")
        XCTAssertEqual(provenance["sleepSessions.summary"], "derived")
        XCTAssertEqual(provenance["sleepSessions.osa"], "derived")
        XCTAssertEqual(provenance["sleepSessions.coverage"], "measured")
    }

    func testProvenanceOmitsSleepSessionSubKeysWhenNoSessionsAreEmitted() {
        let obj = parsed(ExportEngine.toJSON(samples: [], sleep: [], daily: [], now: t0))
        guard let provenance = obj["provenance"] as? [String: String] else {
            return XCTFail("provenance block missing")
        }
        XCTAssertNil(provenance["sleepSessions"])
        XCTAssertNil(provenance["sleepSessions.hypnogram"])
        let emitted = Set(obj.keys).subtracting(nonDataKeys)
        XCTAssertEqual(Set(provenance.keys), emitted,
                       "provenance must classify exactly the sections that were emitted")
    }

    /// The seven cross-checks that are NOT a restatement of the production map: each one is a fact
    /// about the data that would still be wrong if the code and the test were written together.
    /// (`spo2` vs `osaAvgSpO2` in particular: samples carry 0…1, the OSA figures carry percent.)
    func testUnitsGetTheAmbiguousFieldsRight() {
        let obj = parsed(ExportEngine.toJSON(samples: [], sleep: [], daily: [], now: t0))
        guard let units = obj["units"] as? [String: String] else {
            return XCTFail("units block missing")
        }
        XCTAssertEqual(units["spo2"], "fraction", "samples' SpO₂ is 0…1")
        XCTAssertEqual(units["osaAvgSpO2"], "percent", "OSA SpO₂ is a percentage — not the same")
        XCTAssertEqual(units["avgSpO2"], "percent", "…under the key the JSON osa object emits, too")
        XCTAssertEqual(units["osaODI"], "events/hour")
        XCTAssertEqual(units["odi"], "events/hour")
        XCTAssertEqual(units["coverageFraction"], "fraction")
        XCTAssertEqual(units["durationSec"], "s")
        XCTAssertEqual(units["efficiency"], "fraction")
        XCTAssertEqual(units["skinTempC"], "degC")
    }

    // MARK: - The `units` block's own completeness claim
    //
    // The old test looped `MetricKind.allCases` and asserted `units[kind.rawValue] == kind.unit` —
    // a verbatim restatement of the production loop, which cannot catch the thing the block exists
    // for: a NEW numeric field shipped with no unit. Nothing checked the block's own claim to cover
    // the file, and the claim was already false — the JSON `osa` object emits `avgSpO2`/`minSpO2`/
    // `timeBelow90Sec`/`odi` while `units` held only the `osa*` CSV column names, so a JSON consumer
    // resolving `units["odi"]` got nil.
    //
    // This walks the emitted JSON of a FULLY POPULATED export instead and demands that every
    // numeric leaf either has a unit or is an explicitly listed count/identifier.

    /// Keys whose numeric value expresses no physical quantity, so a unit would be an invention.
    /// Adding to this list is a deliberate act; forgetting a real quantity is not possible.
    private static let unitlessNumericKeys: Set<String> = [
        // Identifiers and versions.
        "schemaVersion", "channel", "firstOpcode", "lastOpcode", "syncAckFlag",
        // Plain counts of rows/pages/epochs — dimensionless by construction.
        "stagedSleepSegments", "mergedRecordCount", "historySampleCount",
        "page4CCount", "page47Count", "endMarkerCount",
        "recordsAtStart", "recordsAtEnd", "recordsAdded",
        "validWindows", "expectedSamples", "observedSamples",
        // `samples[].value`'s unit is per-ROW: it is `units[kind]` for that row's `kind`, which is
        // exactly why the sample units come from `MetricKind` rather than being restated.
        "value"
    ]

    func testEveryNumericLeafInTheJSONHasAUnitOrIsAnExplicitCount() {
        let coverage = ExportCoverage.assess(
            sampleTimes: (0 ..< 5).map { t0.addingTimeInterval(Double($0) * 150) },
            from: t0, to: t0.addingTimeInterval(3_000))
        let osa = ExportEngine.OSARow(avgSpO2: 95.4, minSpO2: 88, timeBelow90Sec: 312.5,
                                      odi: 4.25, validWindows: 96)
        let obj = parsed(ExportEngine.toJSON(
            samples: [sampleRow], sleep: [sleepRow],
            daily: [ExportEngine.DailyRow(day: night, steps: 8_000)],
            stepSamples: [ExportEngine.StepSampleRow(start: t0, end: t1, delta: 123)],
            naps: [ExportEngine.NapRow(start: t0, end: t1, asleepMin: 30, isLongNap: false)],
            daytimeTemperatures: [ExportEngine.DaytimeTemperatureRow(time: t0, celsius: 34.2)],
            historySyncEvidence: [evidenceRow], now: t0, metadata: metadata,
            sleepSessions: [session(hypnogram: stagedNight, osa: osa, coverage: coverage)]))

        guard let units = obj["units"] as? [String: String] else {
            return XCTFail("units block missing")
        }
        var numericKeys: Set<String> = []
        collectNumericKeys(obj, into: &numericKeys)
        // The walk must actually have found the interesting fields, or a silent shape change would
        // make this pass by visiting nothing.
        for expected in ["odi", "durationSec", "efficiency", "coverageFraction", "delta"] {
            XCTAssertTrue(numericKeys.contains(expected),
                          "the walk never reached '\(expected)' — fixture no longer populated?")
        }
        for key in numericKeys.sorted() {
            XCTAssertTrue(units[key] != nil || Self.unitlessNumericKeys.contains(key),
                          """
                          '\(key)' is emitted as a number with no entry in `units` and is not in \
                          this test's unitless allow-list. Give it a unit in ExportEngine.units, or \
                          — if it is genuinely a plain count or an identifier — add it to \
                          `unitlessNumericKeys` on purpose.
                          """)
        }
    }

    /// Recursively collect every key whose value is a number, EXCLUDING booleans (which
    /// `JSONSerialization` also hands back as `NSNumber`, so a plain `is NSNumber` test would
    /// demand a unit for `sleepCommitted`).
    private func collectNumericKeys(_ value: Any, into keys: inout Set<String>) {
        if let dict = value as? [String: Any] {
            for (key, child) in dict {
                if isNumber(child) { keys.insert(key) }
                collectNumericKeys(child, into: &keys)
            }
        } else if let array = value as? [Any] {
            for child in array { collectNumericKeys(child, into: &keys) }
        }
    }

    private func isNumber(_ value: Any) -> Bool {
        guard value is NSNumber else { return false }
        return CFGetTypeID(value as CFTypeRef) != CFBooleanGetTypeID()
    }

    func testNotesStateTheHonestCaveats() {
        let obj = parsed(ExportEngine.toJSON(samples: [], sleep: [], daily: [], now: t0))
        guard let notes = obj["notes"] as? [String: String] else {
            return XCTFail("notes block missing")
        }
        // Each of these is a claim we would otherwise be making silently.
        XCTAssertTrue(notes["hrvSDNN"]?.contains("RMSSD") == true)
        XCTAssertTrue(notes["hrvSDNN"]?.contains("BulkSleep.swift:107") == true,
                      "the RMSSD note must cite its source")
        XCTAssertTrue(notes["sleepStages"]?.contains("ESTIMATE") == true)
        XCTAssertTrue(notes["sleepStages"]?.contains("APPROXIMATION, NOT GROUND TRUTH") == true)
        XCTAssertTrue(notes["osa"]?.contains("±1%") == true)
        XCTAssertTrue(notes["osa"]?.contains("EXPERIMENTAL") == true)
        XCTAssertTrue(notes["skinTemperature"]?.contains("back-filled") == true)
        XCTAssertTrue(notes["coverage"]?.contains("not what the ring recorded") == true)
    }

    // MARK: - The honesty blocks reach BOTH formats
    //
    // CSV is the DEFAULT on the export screen (ExportView `format = .csv`). It used to carry no
    // provenance, no units and no notes at all, so the file most people actually hand to a clinician
    // showed the stage minutes, `osaODI` and an `hrvSDNN` column with nothing saying the stages are
    // an on-device estimate, that only the average SpO₂ is validated, or that `hrvSDNN` holds RMSSD
    // — while the screen told the user every section was labelled.

    private func csvTable(_ csv: String, expectedHeader: [String]) -> [String: String] {
        let records = ExportEngineTests.parseCSV(csv)
        XCTAssertEqual(records.first ?? [], expectedHeader)
        var out: [String: String] = [:]
        for record in records.dropFirst() where record.count == 2 { out[record[0]] = record[1] }
        XCTAssertEqual(records.count - 1, out.count, "duplicate or malformed rows in \(expectedHeader)")
        return out
    }

    func testProvenanceCSVClassifiesExactlyWhatTheJSONProvenanceDoes() {
        for includesSessions in [true, false] {
            let table = csvTable(ExportEngine.provenanceCSV(includesSleepSessions: includesSessions),
                                 expectedHeader: ["section", "provenance"])
            let obj = parsed(ExportEngine.toJSON(
                samples: [sampleRow], sleep: [sleepRow], daily: [], now: t0,
                sleepSessions: includesSessions ? [session(hypnogram: stagedNight)] : []))
            guard let json = obj["provenance"] as? [String: String] else {
                return XCTFail("provenance block missing")
            }
            XCTAssertEqual(table, json,
                           "the CSV and JSON provenance must come from one map, not two")
        }
    }

    func testUnitsAndNotesCSVMatchTheirJSONBlocks() {
        let obj = parsed(ExportEngine.toJSON(samples: [], sleep: [], daily: [], now: t0))
        XCTAssertEqual(csvTable(ExportEngine.unitsCSV(), expectedHeader: ["field", "unit"]),
                       obj["units"] as? [String: String])
        XCTAssertEqual(csvTable(ExportEngine.notesCSV(), expectedHeader: ["topic", "note"]),
                       obj["notes"] as? [String: String])
    }

    /// The caveats a clinician reading the file has to meet, in the format they are most likely to
    /// open. Each string is a claim the export would otherwise be making silently.
    func testNotesCSVCarriesTheCaveatsThatUsedToBeJSONOnly() {
        let notes = ExportEngine.notesCSV()
        for phrase in ["ON-DEVICE ESTIMATE", "APPROXIMATION, NOT GROUND TRUTH",
                       "EXPERIMENTAL", "±1%", "RMSSD", "not what the ring recorded"] {
            XCTAssertTrue(notes.contains(phrase),
                          "the CSV notes section must state: \(phrase)")
        }
    }

    /// Free text with commas and quotes in it is exactly what shifts a CSV row silently.
    func testNotesCSVStaysWellFormedDespiteCommasInEveryNote() {
        let records = ExportEngineTests.parseCSV(ExportEngine.notesCSV())
        for record in records.dropFirst() {
            XCTAssertEqual(record.count, 2, "a note leaked into extra columns: \(record)")
        }
    }

    func testCoverageNoteNamesLocalRetentionAsACause() {
        // A night older than the retention window has had its raw samples deleted by local
        // housekeeping; the export omits coverage there, and the note has to say so — the old text
        // listed only not-worn / not-drained / lost epochs, which reads as ring-side data loss.
        let obj = parsed(ExportEngine.toJSON(samples: [], sleep: [], daily: [], now: t0))
        let note = (obj["notes"] as? [String: String])?["coverage"] ?? ""
        XCTAssertTrue(note.contains("retention"), "coverage note must name local retention")
        XCTAssertTrue(note.contains("EMPTY"), "coverage note must say the fields are left empty")
    }

    /// The ring block is a snapshot of the LAST connected ring, and `StoredSleepSummary` carries no
    /// ring column — multi-ring is a shared timeline by design. Without this note the file silently
    /// asserts a provenance it cannot establish, in the one block whose whole job IS provenance.
    func testRingIdentityNoteRefusesToClaimPerNightRingProvenance() {
        let obj = parsed(ExportEngine.toJSON(samples: [], sleep: [], daily: [], now: t0))
        let note = (obj["notes"] as? [String: String])?["ringIdentity"] ?? ""
        XCTAssertTrue(note.contains("LAST RING THIS APP CONNECTED TO"))
        XCTAssertTrue(note.contains("historySyncEvidence[].ringID"),
                      "the note must point at the only per-capture ring attribution in the file")
    }

    func testHypnogramNoteStatesTheRowsArePartitioned() {
        let obj = parsed(ExportEngine.toJSON(samples: [], sleep: [], daily: [], now: t0))
        let note = (obj["notes"] as? [String: String])?["hypnogram"] ?? ""
        XCTAssertTrue(note.contains("PARTITION"))
        XCTAssertTrue(note.contains("inBedStart/inBedEnd"),
                      "the note must point at where the in-bed window actually lives")
    }

    // MARK: - sessionID

    func testSessionIDIsStableSortableAndMatchesTheNightLabel() {
        let id = ExportEngine.sessionID(night: night)
        XCTAssertEqual(id, "night-\(localDayLabel(night))")
        XCTAssertEqual(id, ExportEngine.sessionID(night: night), "must be stable")
        XCTAssertLessThan(ExportEngine.sessionID(night: night),
                          ExportEngine.sessionID(night: night.addingTimeInterval(86_400)),
                          "ids must sort chronologically as plain strings")
    }

    // MARK: - Helpers

    private func localDayLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f.string(from: date)
    }

    /// Whole-object comparison of a section's single element: locks both the key SET and every
    /// value, so an added or renamed key inside a v2 section fails here.
    private func assertElement(_ root: [String: Any], _ section: String,
                               equals expected: [String: Any],
                               file: StaticString = #filePath, line: UInt = #line) {
        guard let element = (root[section] as? [[String: Any]])?.first else {
            return XCTFail("section '\(section)' has no first element", file: file, line: line)
        }
        XCTAssertTrue(NSDictionary(dictionary: element).isEqual(to: expected),
                      """
                      Section '\(section)' changed shape or values.
                      expected: \(expected)
                      actual:   \(element)
                      """,
                      file: file, line: line)
    }
}

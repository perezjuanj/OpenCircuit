import SwiftData
import XCTest
import OpenCircuitKit
@testable import OpenCircuit

// `ExportBuilder` end-to-end over a real (in-memory) store — the three places the assembled file
// silently disagreed with what is on disk:
//
//   1. `.newSessions` consumed a night that could still GROW, and the forward-only watermark meant
//      the fuller version was never offered again (the automated archive kept the truncated one).
//   2. The hypnogram was re-fetched by day bucket, so a night staged in another timezone exported
//      as "no timeline recorded" while its blob sat intact on the row.
//   3. Coverage was measured for nights whose raw samples local housekeeping had already deleted,
//      reporting retention as data the ring never delivered.
@MainActor
final class ExportBuilderTests: XCTestCase {
    private let ref = Date(timeIntervalSince1970: 1_750_000_000)
    private var containers: [ModelContainer] = []

    override func tearDown() {
        containers.removeAll()
        super.tearDown()
    }

    private func at(_ hours: Double) -> Date { ref.addingTimeInterval(hours * 3600) }

    private func makeStore() throws -> LocalStore {
        let container = try ModelContainer(
            for: StoredSample.self, StoredCursor.self,
            StoredSleepSummary.self, StoredDaily.self, StoredNap.self,
            StoredPeriodEntry.self, StoredDaytimeTemp.self, StoredStepSample.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        containers.append(container)
        return LocalStore(container.mainContext)
    }

    /// Save a night the way `RingSession.persistSleepAndSteps` does — summary, window and hypnogram
    /// all derived from one segment array, in one call.
    @discardableResult
    private func save(_ segments: [SleepSegment], to store: LocalStore) throws -> StoredSleepSummary {
        let start = try XCTUnwrap(segments.map(\.start).min())
        let end = try XCTUnwrap(segments.map(\.end).max())
        let window = SleepStaging.sleepWindow(segments)
        var extras = LocalStore.SleepNightExtras()
        extras.hypnogram = segments
        try store.saveSleepSummary(SleepStaging.summary(segments), night: start,
                                   inBedStart: start, inBedEnd: end,
                                   sleepOnset: window?.onset ?? .distantPast,
                                   sleepWake: window?.wake ?? .distantPast,
                                   extras: extras)
        return try XCTUnwrap(store.sleepSummary(night: start))
    }

    /// A night in the shape `SleepStaging.stageSegments` produces: an `.inBed` envelope plus the
    /// stage blocks tiling it.
    private func night(from startHour: Double, to endHour: Double) -> [SleepSegment] {
        let mid = (startHour + endHour) / 2
        return [SleepSegment(start: at(startHour), end: at(endHour), stage: .inBed),
                SleepSegment(start: at(startHour), end: at(mid), stage: .asleepCore),
                SleepSegment(start: at(mid), end: at(endHour), stage: .asleepDeep)]
    }

    private func sessionRows(_ content: String) -> [[String]] {
        // The sleepSessions section, found by its header rather than by position so appending a
        // section elsewhere cannot silently repoint this at the wrong table.
        guard let section = content.components(separatedBy: "\n\n")
            .first(where: { $0.hasPrefix("sessionID,night,inBedStart") }) else { return [] }
        return section.split(separator: "\n").dropFirst()
            .map { $0.components(separatedBy: ",") }
    }

    // MARK: - 1. A night that grows after being exported

    func testANightThatGrowsAfterBeingExportedIsOfferedAgain() throws {
        let store = try makeStore()

        // 02:00 → 06:00 is all the ring had handed off by the morning drain.
        let row = try save(night(from: 2, to: 6), to: store)
        row.updatedAt = at(6.5)

        guard case .file(let first) = try ExportBuilder.build(store: store, mode: .newSessions,
                                                              format: .csv, now: at(7)) else {
            return XCTFail("the first run must produce a file")
        }
        XCTAssertEqual(first.sessionCount, 1)
        try ExportBuilder.commitWatermark(first, store: store)

        // Nothing changed since — the automation must not file the same night again.
        guard case .nothingNew = try ExportBuilder.build(store: store, mode: .newSessions,
                                                         format: .csv, now: at(8)) else {
            return XCTFail("an unchanged night must not be re-offered")
        }

        // 14:00: the ring hands off the rest of the night and the row is rewritten.
        try save(night(from: 2, to: 10), to: store)
        let grown = try XCTUnwrap(store.sleepSummary(night: at(2)))
        XCTAssertEqual(grown.asleepMin, 480, "the stored night really did grow")
        grown.updatedAt = at(14)

        guard case .file(let second) = try ExportBuilder.build(store: store, mode: .newSessions,
                                                               format: .csv, now: at(15)) else {
            return XCTFail("a night rewritten after its export MUST be offered again")
        }
        XCTAssertEqual(second.sessionCount, 1)
        XCTAssertTrue(second.content.contains("480"), "the file must carry the FULLER night")
        try ExportBuilder.commitWatermark(second, store: store)

        // …and exactly once. A night re-offered forever is its own defect.
        guard case .nothingNew = try ExportBuilder.build(store: store, mode: .newSessions,
                                                         format: .csv, now: at(16)) else {
            return XCTFail("the re-offered night must be consumed by its own export")
        }
    }

    func testAnUnchangedBacklogIsNotReOfferedEveryRun() throws {
        let store = try makeStore()
        let row = try save(night(from: 2, to: 6), to: store)
        row.updatedAt = at(6.5)

        guard case .file(let payload) = try ExportBuilder.build(store: store, mode: .newSessions,
                                                                format: .csv, now: at(7)) else {
            return XCTFail("expected a file")
        }
        try ExportBuilder.commitWatermark(payload, store: store)

        for hour in [8.0, 20.0, 44.0] {
            guard case .nothingNew = try ExportBuilder.build(store: store, mode: .newSessions,
                                                             format: .csv, now: at(hour)) else {
                return XCTFail("nothing changed at +\(hour)h; the file must not be rebuilt")
            }
        }
    }

    // MARK: - 2. The hypnogram must not depend on the exporting device's timezone

    func testExportedHypnogramSurvivesATimezoneChange() throws {
        let original = NSTimeZone.default
        defer { NSTimeZone.default = original }

        NSTimeZone.default = TimeZone(identifier: "Europe/Amsterdam")!
        let store = try makeStore()
        let row = try save(night(from: 2, to: 10), to: store)
        let bucket = row.night

        // The user flies west. `night` keeps the instant it was bucketed with in Amsterdam.
        NSTimeZone.default = TimeZone(identifier: "America/New_York")!

        // Precondition, NOT the thing under test: prove the day-bucket lookup really does miss in
        // the new zone, so the assertion below cannot pass vacuously.
        XCTAssertNotEqual(Calendar.current.startOfDay(for: bucket), bucket,
                          "fixture must straddle the two zones' day boundaries")
        XCTAssertTrue(store.hypnogram(night: bucket).isEmpty,
                      "the by-bucket lookup is the fragile path this export no longer uses")

        guard case .file(let payload) = try ExportBuilder.build(
            store: store,
            mode: .dateRange(start: at(-48), end: at(48)),
            format: .csv, now: at(12)) else { return XCTFail("expected a file") }

        let rows = sessionRows(payload.content)
        XCTAssertEqual(rows.count, 1, "the night itself is still in the file")
        XCTAssertEqual(rows[0][15], "2",
                       "hypnogramSegments must report the stored timeline, not 0 for 'not recorded'")
        XCTAssertTrue(payload.content.contains("asleepDeep"),
                      "the hypnogram section must still carry the stored segments")
    }

    // MARK: - 3. Coverage vs. local sample retention

    func testCoverageIsOmittedOnceTheRawSamplesHaveBeenPrunedAway() throws {
        let store = try makeStore()
        let now = at(0)
        let day = 24.0

        // An old night whose StoredSample rows local housekeeping has already deleted, and a recent
        // one whose rows are still there. Same shape, opposite side of the retention horizon.
        let oldStart = -(Double(LocalStore.sampleRetentionDays) + 30) * day
        try save(night(from: oldStart, to: oldStart + 8), to: store)

        let recentStart = -2 * day
        try save(night(from: recentStart, to: recentStart + 8), to: store)
        let hr = stride(from: 0.0, to: 8 * 3600, by: 150).map { offset -> QuantitySample in
            let t = at(recentStart).addingTimeInterval(offset)
            return QuantitySample(kind: .heartRate, start: t, end: t, value: 58)
        }
        _ = try store.ingest(hr)

        guard case .file(let payload) = try ExportBuilder.build(
            store: store,
            mode: .dateRange(start: at(oldStart - day), end: now),
            format: .csv, now: now) else { return XCTFail("expected a file") }

        let rows = sessionRows(payload.content)
        XCTAssertEqual(rows.count, 2)
        // coverageFraction / expectedSamples / observedSamples / longestGapSeconds
        for index in 21 ... 24 {
            XCTAssertEqual(rows[0][index], "",
                           """
                           Column \(index) of a night older than sampleRetentionDays must be EMPTY. \
                           A 0 there reports routine local housekeeping as a night the ring never \
                           delivered — and the file labels coverage 'measured'.
                           """)
        }
        XCTAssertNotEqual(rows[1][21], "", "a night inside the retention window still reports coverage")
        XCTAssertEqual(rows[1][23], "192", "…and reports the epochs it actually holds")

        // The stage minutes of the pruned night are untouched — only the coverage claim is dropped.
        XCTAssertEqual(rows[0][7], "480", "the old night still exports its summary")

        // …and the SAME hazard on the trailing edge. `earliestSample(after:)` for the pruned night
        // returns the recent night's first HR row — 28 days later — and an unguarded classifier
        // would export that as a 28-day silence, i.e. local housekeeping dressed as a hole in the
        // night. It must read `unknown` with no gap.
        //
        // TWO mechanisms now produce that, and this row is past BOTH: `sessionRow` short-circuits
        // the three edge probes for a night older than `retentionHorizon` (passing no coverage at
        // all — 0 fetches instead of 3), and `WakeProvenance.classify` guards on retention anyway
        // for the nights that do get probed. They agree by construction: `assess(coverage: nil)`
        // and a fully-pruned probe both yield unknown/unknown with the duration verdict intact.
        // The guard itself is asserted independently and without the short-circuit in the Kit
        // suite (`WakeProvenanceTests` "Retention", `SleepConfidenceCoverageTests` "Retention"), so
        // this assertion is the END-TO-END check, not the only cover for either mechanism.
        // (bedtimeVerdict, bedtimeGapSeconds, wakeVerdict, wakeGapSeconds, confidenceReasons)
        XCTAssertEqual(rows[0][27], "unknown",
                       "retention no longer reaches this night's end — we cannot judge it")
        XCTAssertEqual(rows[0][28], "", "…so there is no gap to report, and 0 would be a claim")
        XCTAssertFalse(rows[0][29].contains("noRecording"),
                       "no ACQUISITION caveat may come out of an unjudgeable night: \(rows[0][29])")
        // The DURATION verdict is unaffected, and must be: it reads the night's own two totals,
        // which retention does not touch. (This fixture's old night is 8 h at high efficiency, so
        // `durationLikelyHigh` is the correct — and only — thing left to say about it.)
        XCTAssertEqual(rows[0][29], "durationLikelyHigh")
    }

    /// The wake-edge caveat, end to end through the real store: a night, then FOUR HOURS with no
    /// heart-rate row, then the stream resumes. This is the `R2_2026-08-18` shape — the case every
    /// other coverage surface in the file is blind to, because `coverageFraction` counts only rows
    /// INSIDE a window that the records themselves defined.
    func testANightWhoseRecordingStoppedAtTheWakeExportsTheGapAndTheReason() throws {
        let store = try makeStore()
        let now = at(24)

        try save(night(from: 0, to: 6), to: store)
        // Continuous HR through the night (so the LEADING edge is witnessed and cannot be the thing
        // that fires), then nothing for 4 h, then the stream comes back.
        var hr = stride(from: -3_600.0, to: 6 * 3600, by: 150).map { offset -> QuantitySample in
            let t = at(0).addingTimeInterval(offset)
            return QuantitySample(kind: .heartRate, start: t, end: t, value: 58)
        }
        hr += stride(from: 10 * 3600.0, to: 12 * 3600.0, by: 150).map { offset -> QuantitySample in
            let t = at(0).addingTimeInterval(offset)
            return QuantitySample(kind: .heartRate, start: t, end: t, value: 70)
        }
        _ = try store.ingest(hr)

        guard case .file(let payload) = try ExportBuilder.build(
            store: store, mode: .dateRange(start: at(-24), end: now),
            format: .csv, now: now) else { return XCTFail("expected a file") }
        let row = try XCTUnwrap(sessionRows(payload.content).first)

        XCTAssertEqual(row[25], "witnessed", "the stream ran into the bedtime we print")
        XCTAssertEqual(row[27], "stoppedThenResumed")
        XCTAssertEqual(row[28], String(format: "%.1f", 4 * 3600.0),
                       "the gap is 06:00 → 10:00 — measured, not inferred")
        XCTAssertEqual(row[29], "noRecordingAfterWake",
                       "…and the file carries the reason the CLASSIFIER produced. Not a record of "
                       + "anything the wearer saw: no coverage caveat ships in this build, the card "
                       + "is deliberately parked, and this column is instrumentation collected "
                       + "ahead of it.")

        // The claim the whole feature rests on: coverage still calls this window complete.
        XCTAssertNotEqual(row[21], "", "coverage is reportable for this night")
        let fraction = try XCTUnwrap(Double(row[21]))
        XCTAssertGreaterThan(fraction, 0.95,
                             "coverageFraction sees a perfect night — which is exactly why the "
                             + "edge verdict had to be added: the hole starts AT the wake")
    }

    /// THE RETENTION SHORT-CIRCUIT, isolated from the classifier's own retention guard.
    ///
    /// Both nights below have their HR rows still present — nothing prunes an in-memory store — so
    /// `earliestSample(kind:)` reaches back before BOTH of them and `WakeProvenance`'s guard cannot
    /// fire for either. The only thing that can separate them is `sessionRow`'s horizon test. It
    /// must:
    ///   • probe the night inside the horizon and report its measured 4 h gap, and
    ///   • not probe the night outside it at all, reporting `unknown` with no gap — the same
    ///     "we do not vouch past retention" policy the coverage columns next door already apply,
    ///     and the reason a full 365-day export no longer runs up to 1005 main-actor fetches that
    ///     could only ever answer "unknown".
    /// The duration verdict is retention-independent and must survive on both.
    func testEdgeProbesAreSkippedPastTheRetentionHorizonAndKeptInsideIt() throws {
        let store = try makeStore()
        let now = at(0)
        let day = 24.0
        let horizon = -Double(LocalStore.sampleRetentionDays) * day

        // Two identically shaped nights straddling the horizon: 6 h in bed, then 4 h of silence,
        // then the stream resumes.
        for startHour in [horizon - 2 * day, horizon + 2 * day] {
            try save(night(from: startHour, to: startHour + 6), to: store)
            var hr = stride(from: -3_600.0, to: 6 * 3600, by: 150).map { offset -> QuantitySample in
                let t = at(startHour).addingTimeInterval(offset)
                return QuantitySample(kind: .heartRate, start: t, end: t, value: 58)
            }
            hr += stride(from: 10 * 3600.0, to: 12 * 3600.0, by: 150).map { offset -> QuantitySample in
                let t = at(startHour).addingTimeInterval(offset)
                return QuantitySample(kind: .heartRate, start: t, end: t, value: 70)
            }
            _ = try store.ingest(hr)
        }

        guard case .file(let payload) = try ExportBuilder.build(
            store: store, mode: .dateRange(start: at(horizon - 4 * day), end: now),
            format: .csv, now: now) else { return XCTFail("expected a file") }
        let rows = sessionRows(payload.content)
        XCTAssertEqual(rows.count, 2, "both nights are in the file; only the PROBE differs")

        // rows[0] is the older night — outside the horizon.
        XCTAssertEqual(rows[0][27], "unknown",
                       "a night past the retention horizon must not be probed; its edge verdict is "
                       + "the honest 'we cannot vouch', not a measurement of rows we only still "
                       + "hold because this store never prunes")
        XCTAssertEqual(rows[0][28], "", "…and no gap, because none was measured")

        // rows[1] is inside the horizon and must still be measured — without this the
        // short-circuit could be "skip everything" and every test above would stay green.
        XCTAssertEqual(rows[1][27], "stoppedThenResumed")
        XCTAssertEqual(rows[1][28], String(format: "%.1f", 4 * 3600.0))
        XCTAssertEqual(rows[1][29], "noRecordingAfterWake")

        // The duration verdict reads the night's own two totals and is untouched by retention, so
        // the skipped night keeps whatever the legacy classifier says about it — the skip removes
        // an ACQUISITION claim, never the night.
        XCTAssertEqual(rows[0][7], "360", "the skipped night still exports its summary")
    }

    // MARK: - 4. The DEFAULT format carries the honesty apparatus
    //
    // `ExportView` opens on CSV, so CSV is the file most people actually hand to a clinician. It
    // used to carry no provenance, no units and no notes at all — the three blocks were emitted only
    // by `toJSON` — while the screen told the user every section was labelled measured/derived/
    // diagnostic. A clinician read `osaODI` beside a validated `osaAvgSpO2`, and deep/REM minutes,
    // with nothing in the file distinguishing them.

    func testTheCSVExportCarriesProvenanceUnitsAndNotesJustLikeTheJSON() throws {
        let store = try makeStore()
        try save(night(from: 2, to: 10), to: store)
        let mode = ExportBuilder.Mode.dateRange(start: at(-24), end: at(24))

        for format in ExportBuilder.Format.allCases {
            guard case .file(let payload) = try ExportBuilder.build(store: store, mode: mode,
                                                                    format: format, now: at(12))
            else { return XCTFail("expected a file for \(format)") }

            for marker in ["provenance", "measured", "derived", "diagnostic",
                           "ON-DEVICE ESTIMATE", "EXPERIMENTAL", "RMSSD",
                           "not what the ring recorded"] {
                XCTAssertTrue(payload.content.contains(marker),
                              "the \(format.rawValue) export must state: \(marker)")
            }
        }
    }

    func testTheCSVExportNamesItsProvenanceUnitsAndNotesSections() throws {
        let store = try makeStore()
        try save(night(from: 2, to: 10), to: store)
        guard case .file(let payload) = try ExportBuilder.build(
            store: store, mode: .dateRange(start: at(-24), end: at(24)),
            format: .csv, now: at(12)) else { return XCTFail("expected a file") }

        let sections = payload.content.components(separatedBy: "\n\n")
        for header in ["section,provenance", "field,unit", "topic,note"] {
            XCTAssertTrue(sections.contains { $0.hasPrefix(header) },
                          "the CSV must carry a '\(header)' section")
        }
        // Appended, never interleaved: a consumer that indexes the v2 sections positionally must
        // still find `samples` first and `historySyncEvidence` seventh.
        XCTAssertTrue(sections[0].hasPrefix("kind,start,end,value"))
        XCTAssertTrue(sections[6].hasPrefix("capturedAt,ringID,trigger"))
    }

    // MARK: - 5. The main-actor work is BOUNDED
    //
    // `ExportBuilder` and `LocalStore` are both `@MainActor` and the build is synchronous. The raw
    // sample tables are already bounded by `LocalStore.sampleRetentionDays` (30) and the sync
    // evidence by `ObservabilityStore.historySyncEvidenceLimit` (24), but `StoredSleepSummary` is
    // kept LONG-TERM and each night decodes a hypnogram blob and emits a CSV row per segment — so
    // the per-night sections were the one part that grew without limit with install age, on the
    // main thread, in an app that has already shipped an 0x8BADF00D main-thread watchdog kill.
    // `maxExportDays` is the bound; these prove it holds and that nothing is silently lost to it.

    func testADateRangeLongerThanTheCapIsClampedToTheMostRecentWindow() throws {
        let store = try makeStore()
        let day = 24.0
        // One night well outside the cap, one just inside it.
        let oldStart = -Double(ExportBuilder.maxExportDays + 40) * day
        try save(night(from: oldStart, to: oldStart + 8), to: store)
        try save(night(from: -3 * day, to: -3 * day + 8), to: store)

        guard case .file(let payload) = try ExportBuilder.build(
            store: store,
            mode: .dateRange(start: at(-4_000 * day), end: at(0)),
            format: .csv, now: at(0)) else { return XCTFail("expected a file") }

        let ids = sessionRows(payload.content).map { $0[0] }
        XCTAssertEqual(ids, [ExportEngine.sessionID(night: at(-3 * day))],
                       "only the night inside the \(ExportBuilder.maxExportDays)-day window; the "
                       + "clamp moves the START forward, keeping the RECENT nights")
        XCTAssertNotNil(payload.rangeNotice,
                        "a file narrower than what was asked for must say so — silently covering "
                        + "less than requested is the worse failure")
    }

    func testADateRangeInsideTheCapIsNotClampedAndCarriesNoNotice() throws {
        let store = try makeStore()
        try save(night(from: -3 * 24, to: -3 * 24 + 8), to: store)

        guard case .file(let payload) = try ExportBuilder.build(
            store: store, mode: .dateRange(start: at(-30 * 24), end: at(0)),
            format: .csv, now: at(0)) else { return XCTFail("expected a file") }

        XCTAssertEqual(sessionRows(payload.content).count, 1)
        XCTAssertNil(payload.rangeNotice, "an ordinary range must not be annotated")
    }

    /// The `.newSessions` backlog drains FORWARD across runs. Trimming the NEWEST nights instead
    /// would leave the oldest ones behind a forward-only watermark permanently — the exact failure
    /// `.newSessions` exists to prevent.
    func testAnOversizedNewSessionsBacklogDrainsOldestFirstAcrossRuns() throws {
        let store = try makeStore()
        let day = 24.0
        let oldest = -Double(ExportBuilder.maxExportDays + 10) * day
        // `updatedAt` pinned into the fixture's own timeline: left at the real wall clock it would
        // sit far in the FUTURE of `now = at(0)` and every night would read as "changed since the
        // last export", which is a different mechanism than the one under test.
        let oldRow = try save(night(from: oldest, to: oldest + 8), to: store)
        oldRow.updatedAt = at(-1)
        let recentRow = try save(night(from: -2 * day, to: -2 * day + 8), to: store)
        recentRow.updatedAt = at(-1)

        guard case .file(let first) = try ExportBuilder.build(
            store: store, mode: .newSessions, format: .csv, now: at(0)) else {
            return XCTFail("expected a file")
        }
        XCTAssertEqual(first.sessionCount, 1, "only the oldest window fits")
        XCTAssertNotNil(first.rangeNotice)
        XCTAssertTrue(first.content.contains(ExportEngine.sessionID(night: at(oldest))),
                      "the OLDEST night must be the one exported, not the newest")
        try ExportBuilder.commitWatermark(first, store: store)

        // The next run picks up exactly where it left off — nothing was lost to the bound.
        guard case .file(let second) = try ExportBuilder.build(
            store: store, mode: .newSessions, format: .csv, now: at(0)) else {
            return XCTFail("the remainder of the backlog must still be offered")
        }
        XCTAssertEqual(second.sessionCount, 1)
        XCTAssertTrue(second.content.contains(ExportEngine.sessionID(night: at(-2 * day))))
        XCTAssertNil(second.rangeNotice, "the remainder fits, so no notice")
        try ExportBuilder.commitWatermark(second, store: store)

        guard case .nothingNew = try ExportBuilder.build(store: store, mode: .newSessions,
                                                         format: .csv, now: at(0)) else {
            return XCTFail("the backlog is drained; nothing may be re-offered forever")
        }
    }

    /// The bound must apply ONLY to the unexported backlog. Applying it across the CHANGED nights
    /// too deadlocks the mode: one repaired night from long ago puts the horizon in the past, trims
    /// away every recent night, advances no watermark (the night cursor is forward-only and that
    /// night is already behind it) — and the same file is re-offered forever while today's nights
    /// never export at all.
    func testAnAncientRepairedNightDoesNotStarveTodaysNightsOutOfTheExport() throws {
        let store = try makeStore()
        let day = 24.0

        // An old night, exported long ago.
        let ancient = -Double(ExportBuilder.maxExportDays + 200) * day
        let ancientRow = try save(night(from: ancient, to: ancient + 8), to: store)
        ancientRow.updatedAt = at(ancient + 9)
        guard case .file(let firstPass) = try ExportBuilder.build(
            store: store, mode: .newSessions, format: .csv, now: at(ancient + 10)) else {
            return XCTFail("expected a file")
        }
        try ExportBuilder.commitWatermark(firstPass, store: store)

        // Today's night arrives, and the diagnostics repair rewrites that ancient night.
        let recentRow = try save(night(from: -2 * day, to: -2 * day + 8), to: store)
        recentRow.updatedAt = at(-1)
        ancientRow.updatedAt = at(-1)

        guard case .file(let payload) = try ExportBuilder.build(
            store: store, mode: .newSessions, format: .csv, now: at(0)) else {
            return XCTFail("expected a file")
        }
        XCTAssertTrue(payload.content.contains(ExportEngine.sessionID(night: at(-2 * day))),
                      "today's night must be in the file, not starved by the repaired old one")
        XCTAssertTrue(payload.content.contains(ExportEngine.sessionID(night: at(ancient))),
                      "…and the repaired night is re-offered alongside it, as it always was")
        try ExportBuilder.commitWatermark(payload, store: store)

        guard case .nothingNew = try ExportBuilder.build(store: store, mode: .newSessions,
                                                         format: .csv, now: at(0)) else {
            return XCTFail("both nights were exported; nothing may be re-offered forever")
        }
    }

    // MARK: - 6. PRIVACY: the advertised name's MAC suffix must not reach the file
    //
    // The Kit cannot enforce this — `ExportEngine` copies whatever `ringModel` it is handed. The
    // guarantee lives HERE, where the value is sourced: `FirmwareInfo.modelName` is seeded from
    // `CBPeripheral.name`, and that advertised name ends in the last two bytes of the ring's MAC
    // ("RingConn Gen2-03AD" for MAC F8:79:99:F7:03:AD, 🟢 docs/PROTOCOL.md:55). The Kit-side test
    // that "asserted" this built a struct with no MAC field and could not fail.

    func testTheExportMetadataStripsTheAdvertisedNamesMACSuffix() throws {
        let suite = "test.ExportBuilderTests.ring"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        // Exactly what a real install caches: the ADVERTISED name, MAC suffix and all.
        RingMetadataStore(defaults).record(
            from: FirmwareInfo(version: "FR02.018", modelName: "RingConn Gen2-03AD",
                               manufacturer: "RingConn", hardwareRevision: "1.0",
                               mac: "F8:79:99:F7:03:AD"),
            identifier: "1E2E3E4E-0000-0000-0000-000000000001")

        let meta = ExportBuilder.metadata(rangeStart: at(0), rangeEnd: at(24), now: at(0),
                                          ring: RingMetadataStore(defaults).load())
        XCTAssertEqual(meta.ringModel, "RingConn Gen2",
                       "the model FAMILY reaches the file; the MAC-derived suffix does not")

        let csv = ExportEngine.metadataCSV(meta)
        XCTAssertFalse(csv.contains("F8:79:99:F7:03:AD"), "the MAC must never reach the file")
        XCTAssertFalse(csv.contains("03AD"),
                       "nor the two MAC bytes the advertised name carries")
        XCTAssertTrue(csv.contains("RingConn Gen2"), "…while the model family still does")
    }

    /// The negative control: fed the raw advertised name directly, the same search DOES find the
    /// suffix — so the assertions above are evidence that the stripping ran, not that the search
    /// looked in the wrong place.
    func testTheSuffixSearchWouldCatchAnUnstrippedAdvertisedName() {
        let unstripped = ExportBuilder.metadata(
            rangeStart: at(0), rangeEnd: at(24), now: at(0),
            ring: RingMetadataSnapshot(modelName: "RingConn Gen2-03AD", version: "FR02.018",
                                       generation: "Gen 2", identifier: "id"))
        XCTAssertTrue(ExportEngine.metadataCSV(unstripped).contains("03AD"))
    }
}

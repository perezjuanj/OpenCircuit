import SwiftData
import XCTest
import OpenCircuitKit
@testable import OpenCircuit

@MainActor
final class SleepEditStoreTests: XCTestCase {
    private let ref = Date(timeIntervalSince1970: 1_750_000_000)
    private var containers: [ModelContainer] = []

    override func tearDown() {
        containers.removeAll()
        super.tearDown()
    }

    private func at(_ hours: Double) -> Date {
        ref.addingTimeInterval(hours * 3600)
    }

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

    private func seed(_ store: LocalStore) throws {
        let summary = SleepStaging.Summary(inBed: 8 * 3600, awake: 30 * 60,
                                           light: 5 * 3600, deep: 90 * 60, rem: 60 * 60)
        try store.saveSleepSummary(summary, night: at(0), inBedStart: at(0), inBedEnd: at(8),
                                   sleepOnset: at(0.5), sleepWake: at(7.75))
    }

    func testFirstEditPersistsFlagOverlayAndImmutableRecordedAnchors() throws {
        let store = try makeStore()
        try seed(store)
        let edited = SleepEdit.Window(inBedStart: at(-1), inBedEnd: at(9))
        let segments = SleepEdit.recompute(
            baseSegments: [
                .init(start: at(0), end: at(8), stage: .inBed),
                .init(start: at(0), end: at(8), stage: .asleepCore),
            ], window: edited)
        let summary = SleepStaging.summary(segments)

        XCTAssertTrue(try store.applySleepEdit(night: at(0), editedWindow: edited,
                                                summary: summary,
                                                sleepOnset: at(-1), sleepWake: at(9)))
        let row = try XCTUnwrap(store.sleepSummary(night: at(0)))
        XCTAssertTrue(row.isManuallyEdited)
        XCTAssertEqual(row.editedInBedStart, at(-1))
        XCTAssertEqual(row.editedInBedEnd, at(9))
        XCTAssertEqual(row.inBedStart, at(0), "recorded anchors remain immutable")
        XCTAssertEqual(row.inBedEnd, at(8))
        XCTAssertEqual(row.sleepOnset, at(0.5))
        XCTAssertEqual(row.sleepWake, at(7.75))
        XCTAssertEqual(row.asleepMin, 10 * 60)
        XCTAssertEqual(row.efficiency, 1, accuracy: 0.0001)
        XCTAssertGreaterThan(row.sleepScore, 0)
    }

    func testResyncCannotOverwriteManualEditAndReeditKeepsOriginalBounds() throws {
        let store = try makeStore()
        try seed(store)
        let first = SleepEdit.Window(inBedStart: at(-1), inBedEnd: at(9))
        let firstSummary = SleepStaging.Summary(inBed: 10 * 3600, awake: 0,
                                                light: 10 * 3600, deep: 0, rem: 0)
        XCTAssertTrue(try store.applySleepEdit(night: at(0), editedWindow: first,
                                                summary: firstSummary,
                                                sleepOnset: at(-1), sleepWake: at(9)))

        // A later sync is ignored once the explicit persisted flag is set.
        let replacement = SleepStaging.Summary(inBed: 2 * 3600, awake: 0,
                                                light: 2 * 3600, deep: 0, rem: 0)
        try store.saveSleepSummary(replacement, night: at(0), inBedStart: at(3), inBedEnd: at(5))
        XCTAssertEqual(try store.sleepSummary(night: at(0))?.editedInBedStart, at(-1))

        let second = SleepEdit.Window(inBedStart: at(-2), inBedEnd: at(10))
        let secondSummary = SleepStaging.Summary(inBed: 12 * 3600, awake: 0,
                                                 light: 12 * 3600, deep: 0, rem: 0)
        XCTAssertTrue(try store.applySleepEdit(night: at(0), editedWindow: second,
                                                summary: secondSummary,
                                                sleepOnset: at(-2), sleepWake: at(10)))
        let row = try XCTUnwrap(store.sleepSummary(night: at(0)))
        XCTAssertEqual(row.sleepOnset, at(0.5))
        XCTAssertEqual(row.sleepWake, at(7.75))
        XCTAssertEqual(row.inBedStart, at(0))
        XCTAssertEqual(row.inBedEnd, at(8))
        XCTAssertEqual(row.editedInBedStart, at(-2))
        XCTAssertEqual(row.editedInBedEnd, at(10))
    }

    func testManualFlagIsNotInferredFromUncommittedOverlayDates() throws {
        let store = try makeStore()
        try seed(store)
        let row = try XCTUnwrap(store.sleepSummary(night: at(0)))
        row.editedInBedStart = at(-1)
        row.editedInBedEnd = at(9)
        XCTAssertFalse(row.isManuallyEdited)
    }

    func testThreeTimeEditPersistsBedtimeSeparatelyFromSleepWindow() throws {
        let store = try makeStore()
        try seed(store)
        let times = SleepEdit.Times(inBedStart: at(-0.5), sleepOnset: at(0.5), sleepWake: at(8))
        let segments = SleepEdit.recompute(baseSegments: [
            .init(start: at(0), end: at(8), stage: .inBed),
            .init(start: at(0.5), end: at(8), stage: .asleepCore),
        ], times: times)

        XCTAssertTrue(try store.applySleepEdit(night: at(0), times: times,
                                                summary: SleepStaging.summary(segments)))
        let row = try XCTUnwrap(store.sleepSummary(night: at(0)))
        XCTAssertEqual(row.sleepEditCurrentInBedStart, at(-0.5))
        XCTAssertEqual(row.sleepEditCurrentOnset, at(0.5))
        XCTAssertEqual(row.sleepEditCurrentWake, at(8))
        XCTAssertEqual(row.awakeMin, 60)
        XCTAssertEqual(row.asleepMin, 450)
    }

    func testVisuallyUnchangedRecordedWindowDoesNotBecomeManualEdit() throws {
        let store = try makeStore()
        try seed(store)
        let row = try XCTUnwrap(store.sleepSummary(night: at(0)))
        // The picker displays minute precision. Hidden seconds may change after interacting with it,
        // but returning to the same displayed minutes is still an unchanged edit.
        let unchanged = SleepEdit.Window(inBedStart: row.inBedStart.addingTimeInterval(10),
                                         inBedEnd: row.inBedEnd.addingTimeInterval(10))
        XCTAssertTrue(try store.applySleepEdit(night: at(0), editedWindow: unchanged,
                                                summary: row.asSummary,
                                                sleepOnset: row.sleepOnset,
                                                sleepWake: row.sleepWake))
        XCTAssertFalse(row.isManuallyEdited)
        XCTAssertEqual(row.editedInBedStart, .distantPast)
        XCTAssertEqual(row.editedInBedEnd, .distantPast)
    }

    func testLeadingHealthExtensionIsPendingRetryableAndIncrementalAcrossReedit() throws {
        let store = try makeStore()
        try seed(store)
        try store.markSleepWritten([
            .init(start: at(0), end: at(8), stage: .asleepCore)
        ])

        let first = SleepEdit.Window(inBedStart: at(-1), inBedEnd: at(9))
        let firstSummary = SleepStaging.Summary(inBed: 10 * 3600, awake: 0,
                                                light: 10 * 3600, deep: 0, rem: 0)
        XCTAssertTrue(try store.applySleepEdit(night: at(0), editedWindow: first,
                                                summary: firstSummary,
                                                sleepOnset: at(-1), sleepWake: at(9)))

        let pending = try store.pendingSleepEditHealthWrites()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].segments.map(\.stage), [.inBed, .asleepCore, .inBed, .asleepCore])
        XCTAssertEqual(pending[0].segments.first?.start, at(-1))
        XCTAssertEqual(pending[0].segments.first?.end, at(0))
        XCTAssertEqual(pending[0].segments[2].start, at(8))
        XCTAssertEqual(pending[0].segments[2].end, at(9))
        // Merely reading pending work does not mark it; a failed/denied write retries identically.
        XCTAssertEqual(try store.pendingSleepEditHealthWrites().first?.segments, pending[0].segments)

        try store.markSleepEditHealthWritten(night: pending[0].night, segments: pending[0].segments)
        XCTAssertTrue(try store.pendingSleepEditHealthWrites().isEmpty)
        XCTAssertTrue(try store.pendingHealthSleep([
            .init(start: at(8), end: at(9), stage: .asleepCore),
        ]).isEmpty, "successful manual-tail retry must advance the shared sleep cursor")

        let second = SleepEdit.Window(inBedStart: at(-2), inBedEnd: at(10))
        let secondSummary = SleepStaging.Summary(inBed: 12 * 3600, awake: 0,
                                                 light: 12 * 3600, deep: 0, rem: 0)
        XCTAssertTrue(try store.applySleepEdit(night: at(0), editedWindow: second,
                                                summary: secondSummary,
                                                sleepOnset: at(-2), sleepWake: at(10)))
        let incremental = try XCTUnwrap(store.pendingSleepEditHealthWrites().first)
        XCTAssertEqual(incremental.segments.first?.start, at(-2))
        XCTAssertEqual(incremental.segments.first?.end, at(-1),
                       "re-edit must append only the newly exposed bedtime slice")
    }

    // MARK: A WATERMARK IS A CLAIM ABOUT APPLE HEALTH
    //
    // The edit paths write `segments.healthPublishable` and pin the watermarks from THAT, never from
    // the proposed set: `pendingSleepEditHealthWrites` only ever offers ground BEFORE the leading
    // watermarks, so a watermark pinned over a span Health never received retires that span forever
    // — the sleep could not be added later even once records arrived to justify it.
    //
    // ⚠️ RE-BASELINED 2026-08-24. This pair used to pin the WITHHELD case: build 47 dropped an
    // asleep block over proven-empty ground, so the two sets differed and the leading block had to
    // stay offered. The maintainer reversed the withholding — asserted sleep is now published
    // tagged `HKMetadataKeyWasUserEntered` (`SleepHealthPublication`) — so today
    // `healthPublishable` returns everything and the two sets coincide. The withheld case is
    // therefore no longer constructible through this path, and asserting it would only pin a
    // fiction. What survives, and is pinned below, is the half that still bites: a block Health DID
    // receive must be watermarked and never offered twice, and the watermark must come from the
    // published set so the rule holds unchanged the day something is withheld again.

    func testTheAssertedLeadingExtensionIsWrittenWatermarkedAndNotOfferedTwice() throws {
        let store = try makeStore()
        try seed(store)
        try store.markSleepWritten([.init(start: at(0), end: at(8), stage: .asleepCore)])

        let times = SleepEdit.Times(inBedStart: at(-1), sleepOnset: at(-1), sleepWake: at(9))
        XCTAssertTrue(try store.applySleepEdit(
            night: at(0), times: times,
            summary: SleepStaging.Summary(inBed: 10 * 3600, awake: 0,
                                          light: 10 * 3600, deep: 0, rem: 0)))

        let proposed = try XCTUnwrap(store.pendingSleepEditHealthWrites().first).segments
        XCTAssertTrue(proposed.contains { $0.stage == .asleepCore && $0.start == at(-1) })

        // The leading hour holds no records, so that `asleepCore` block is the wearer's own account.
        // It is PUBLISHED — and tagged as hers at the write site.
        let assertedLeading = proposed.map { seg in
            seg.stage == .asleepCore && seg.start == at(-1) ? seg.withProvenance(.asserted) : seg
        }
        let published = assertedLeading.healthPublishable
        XCTAssertTrue(published.contains { $0.stage == .asleepCore && $0.start == at(-1) },
                      "precondition: the leading asleep block reaches Health")
        XCTAssertTrue(assertedLeading.healthUserEntered
            .contains { $0.stage == .asleepCore && $0.start == at(-1) },
                      "…as the wearer's entry, not as a measurement")
        XCTAssertTrue(assertedLeading.withheldSpans.isEmpty,
                      "nothing withheld ⇒ nothing may be spared from the cleanup delete")

        try store.markSleepEditHealthWritten(night: at(0), segments: published)

        XCTAssertNil(try store.pendingSleepEditHealthWrites().first,
                     "every offered span reached Health, so nothing may be offered again — "
                     + "re-offering it is how a night gets written to Health twice")
    }

    func testTheWatermarkStillComesFromTheWRITTENSetNotTheProposedOne() throws {
        // The rule, exercised directly: hand `markSleepEditHealthWritten` a set that is MISSING the
        // leading asleep block (what a future withholding rule would produce) and the block must
        // still be offered. This is the guard the pair above used to provide through the coverage
        // filter; with nothing withheld today it has to be stated explicitly or it is untested.
        let store = try makeStore()
        try seed(store)
        try store.markSleepWritten([.init(start: at(0), end: at(8), stage: .asleepCore)])
        let times = SleepEdit.Times(inBedStart: at(-1), sleepOnset: at(-1), sleepWake: at(9))
        XCTAssertTrue(try store.applySleepEdit(
            night: at(0), times: times,
            summary: SleepStaging.Summary(inBed: 10 * 3600, awake: 0,
                                          light: 10 * 3600, deep: 0, rem: 0)))
        let proposed = try XCTUnwrap(store.pendingSleepEditHealthWrites().first).segments

        let asIfWithheld = proposed.filter { !($0.stage == .asleepCore && $0.start == at(-1)) }
        try store.markSleepEditHealthWritten(night: at(0), segments: asIfWithheld)

        let after = try store.pendingSleepEditHealthWrites().first
        XCTAssertNotNil(after, "a span Health never received must still be offered")
        XCTAssertTrue(after?.segments.contains { $0.stage == .asleepCore && $0.start == at(-1) } ?? false,
                      "watermarking from the proposal would retire it permanently")
        XCTAssertFalse(after?.segments.contains { $0.stage == .inBed && $0.start == at(-1) } ?? true,
                       "the in-bed hour WAS written, so it must not be offered again")
    }

    // MARK: THE SECOND HEALTH PATH MUST STILL RECOGNISE A PROVEN HOLE AT THE FRONT OF A NIGHT
    //
    // `pendingSleepEditHealthWrites` is the app's SECOND, independent construction of Apple Health
    // sleep. It never calls `SleepEdit.recompute` and holds no record timestamps, so it recovers the
    // coverage decision from the row's stored PROVENANCE LABELS.
    //
    // 🟢 THE DEFECT THIS PINS. That label-derived set was being run through
    // `MeasuredCoverage.trusted(for:)`, whose proof horizon is "the first instant OUR OLDEST RECORD
    // covers". Fed labels instead of records, "our oldest record" resolves to "wherever the first
    // non-hole LABEL sits" — which by construction sits AFTER any hole at the START of a night. The
    // leading hole the primary path had PROVEN empty then came back `.unknown`, was tagged
    // `.assertedCoverageUnknown`, and PUBLISHED: the app went on writing sleep nobody measured
    // through the very path the fix existed to close.

    /// ⚠️ RE-BASELINED 2026-08-24. The LABEL half of this test is unchanged and is what it was
    /// really for: the second Health path must read the stored labels back and still see the leading
    /// hour as a PROVEN hole, never soften it to `.unknown` (that softening is the defect the
    /// header above describes, and `ProvenanceLabelCoverage` is what makes it uncompilable). What
    /// changed is the consequence: the hour is no longer withheld from Health, it is published as
    /// the wearer's own entry. So the assertion follows the label to its new destination — the
    /// offered sleep over the hole must be TAGGED, which fails both if it is missing and if it goes
    /// in as an unqualified measurement.
    func testALeadingPROVENHoleIsOfferedToAppleHealthOnlyAsTheWearersOwnEntry() throws {
        let store = try makeStore()
        try seed(store)
        try store.markSleepWritten([.init(start: at(0), end: at(8), stage: .asleepCore)])

        // The hypnogram the primary path stored for this edit: the wearer dragged bedtime back one
        // hour into ground the records PROVE holds nothing, over a night the ring did record.
        let hypnogram: [SleepSegment] = [
            .init(start: at(-1), end: at(0), stage: .inBed, provenance: .asserted),
            .init(start: at(-1), end: at(0), stage: .asleepCore, provenance: .asserted),
            .init(start: at(0), end: at(8), stage: .inBed),
            .init(start: at(0), end: at(8), stage: .asleepCore),
        ]
        let times = SleepEdit.Times(inBedStart: at(-1), sleepOnset: at(-1), sleepWake: at(8))
        XCTAssertTrue(try store.applySleepEdit(
            night: at(0), times: times,
            summary: SleepStaging.Summary(inBed: 9 * 3600, awake: 0,
                                          light: 9 * 3600, deep: 0, rem: 0),
            hypnogram: hypnogram))

        let offered = try XCTUnwrap(store.pendingSleepEditHealthWrites().first).segments
        let hole = at(-1) ..< at(0)
        let asleepStages: Set<SleepStage> = [.asleepCore, .asleepDeep, .asleepREM]

        // Precondition: this path really is proposing sleep across the hole (otherwise the
        // assertion below could pass for having proposed nothing at all).
        XCTAssertTrue(offered.contains { asleepStages.contains($0.stage)
                                         && $0.start < hole.upperBound && $0.end > hole.lowerBound },
                      "precondition: the second path proposes asleep time across the leading hour")

        // Every asleep sample over the PROVEN hole must be in the user-entered bucket — none may go
        // in as an unqualified measurement.
        for seg in offered.healthPublication.measured where asleepStages.contains(seg.stage) {
            XCTAssertFalse(seg.start < hole.upperBound && seg.end > hole.lowerBound,
                           "an UNTAGGED asleep sample over the PROVEN hole reaches Health: \(seg)")
        }
        XCTAssertTrue(offered.healthUserEntered.contains {
            asleepStages.contains($0.stage) && $0.start < hole.upperBound && $0.end > hole.lowerBound
        }, "the hour she asserted must reach Health, marked as entered by her")

        // …and the in-bed claim over the same hour is still published — in-bed is a statement about
        // where the body was and we hold no competing measurement — carrying her name like every
        // other span she asserted.
        XCTAssertTrue(offered.healthPublishable.contains { $0.stage == .inBed && $0.start == at(-1) },
                      "the wearer's in-bed claim must survive")
        XCTAssertTrue(offered.healthUserEntered.contains { $0.stage == .inBed && $0.start == at(-1) },
                      "…tagged, because over a proven hole the only source for it is her")
    }

    func testNormalFullNightWriteCoversLeadingEditWithoutSecondAppend() throws {
        let store = try makeStore()
        try seed(store)
        let edited = SleepEdit.Window(inBedStart: at(-1), inBedEnd: at(9))
        let summary = SleepStaging.Summary(inBed: 10 * 3600, awake: 0,
                                           light: 10 * 3600, deep: 0, rem: 0)
        XCTAssertTrue(try store.applySleepEdit(night: at(0), editedWindow: edited,
                                                summary: summary,
                                                sleepOnset: at(-1), sleepWake: at(9)))

        let full = [SleepSegment(start: at(-1), end: at(9), stage: .asleepCore)]
        try store.markSleepWritten(full)
        try store.markSleepEditHealthCovered(by: full)
        XCTAssertTrue(try store.pendingSleepEditHealthWrites().isEmpty)
        XCTAssertTrue(try store.pendingSleepEditHealthWrites().isEmpty)
    }
}

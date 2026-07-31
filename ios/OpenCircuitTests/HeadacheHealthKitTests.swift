import HealthKit
import XCTest
@testable import OpenCircuit

/// The headache log's HealthKit seam, over the PURE statics only — no live `HKHealthStore`, so
/// these run in the simulator where every type reports `.notDetermined` and no sample can be saved.
///
/// The headache entries are the ground-truth LABEL series for the (later) overnight-signals work:
/// a detector can only ever be validated against them. A label that reaches Apple Health with the
/// wrong severity, the wrong window, or the wrong TYPE is worse than a missing one — it is a
/// fabricated fact about the user that we would then evaluate ourselves against.
@MainActor
final class HeadacheHealthKitTests: XCTestCase {

    /// Fixed clock so "in the future" is unambiguous and nothing here depends on wall time.
    private let now = Date(timeIntervalSince1970: 1_785_000_000)

    private func hoursAgo(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }

    // MARK: Severity

    /// `StoredHeadacheEntry.severityRaw` uses `HKCategoryValueSeverity`'s raw values 1:1 precisely so
    /// this mapping is the identity function and cannot drift. The load-bearing half is the
    /// out-of-range case: an unknown value (an older/newer build, a corrupted row, a future UI that
    /// adds a level) must degrade to `.unspecified`, NEVER to a substantive severity. Silently
    /// promoting "I don't know" to "moderate" writes a clinical claim the user never made into their
    /// Health record — and then poisons the label series it becomes.
    ///
    /// MEASURED, and the reason this test can't be replaced by a code read: `HKCategoryValueSeverity`
    /// is imported as a NON-FROZEN Obj-C enum, so `init(rawValue:)` never returns nil —
    /// `HKCategoryValueSeverity(rawValue: -1)?.rawValue` is `-1`, not `nil` (verified against the
    /// iOS 26.5 SDK for -1, 5, 99 and `Int.max`). Any `?? .unspecified` fallback written against it
    /// is dead code, and the bad value reaches `HKCategorySample(type:value:)`, which raises the
    /// uncatchable `_HKObjectValidationFailureException: Value -1 is not compatible with type
    /// HKCategoryTypeIdentifierHeadache` — a crash on the flush path, the same shape as the #110 and
    /// build 17–22 menstrual-flow crash loops. The clamp must therefore be an explicit whitelist of
    /// the five known values.
    func testHeadacheSeverityMapping() throws {
        let onset = hoursAgo(3)
        let mapping: [(raw: Int, severity: HKCategoryValueSeverity)] = [
            (0, .unspecified), (1, .notPresent), (2, .mild), (3, .moderate), (4, .severe),
        ]
        for (raw, severity) in mapping {
            let sample = try XCTUnwrap(HealthKitWriter.headacheSamples(
                onset: onset, end: nil, severityRaw: raw, now: now).first)
            XCTAssertEqual(sample.value, severity.rawValue,
                           "severityRaw \(raw) must map 1:1 onto HKCategoryValueSeverity")
            XCTAssertEqual(sample.categoryType, HKCategoryType(.headache))
        }

        for raw in [-1, 5, 99, Int.max] {
            let sample = try XCTUnwrap(HealthKitWriter.headacheSamples(
                onset: onset, end: nil, severityRaw: raw, now: now).first)
            XCTAssertEqual(sample.value, HKCategoryValueSeverity.unspecified.rawValue,
                           "an out-of-range severity (\(raw)) must clamp to .unspecified")
            XCTAssertNotEqual(sample.value, HKCategoryValueSeverity.moderate.rawValue,
                              "an unknown severity must never be upgraded to a clinical one")
            XCTAssertNotEqual(sample.value, HKCategoryValueSeverity.mild.rawValue)
            XCTAssertNotEqual(sample.value, HKCategoryValueSeverity.severe.rawValue)
        }
    }

    // MARK: Sample windows

    /// Every window case. `HKHealthStore.save` REJECTS `endDate < startDate`, and a rejected save
    /// leaves the entry permanently pending (it retries and fails forever), so an inverted or
    /// future end must be clamped at the builder — but the entry must NOT be dropped, because the
    /// onset is a fact the user stated and discarding it would lose the label entirely.
    func testHeadacheSampleZeroLengthAndInterval() throws {
        let onset = hoursAgo(3)

        // Open headache: an onset with no resolution yet. A zero-length sample states exactly what
        // is known instead of inventing a duration.
        let open = try XCTUnwrap(HealthKitWriter.headacheSamples(
            onset: onset, end: nil, severityRaw: 3, now: now).first)
        XCTAssertEqual(open.startDate, onset)
        XCTAssertEqual(open.endDate, onset, "an unresolved headache must not be given a duration")

        // Resolved headache: the logged interval, verbatim.
        let resolvedEnd = onset.addingTimeInterval(90 * 60)
        let resolved = try XCTUnwrap(HealthKitWriter.headacheSamples(
            onset: onset, end: resolvedEnd, severityRaw: 2, now: now).first)
        XCTAssertEqual(resolved.startDate, onset)
        XCTAssertEqual(resolved.endDate, resolvedEnd)

        // End before onset (the user scrolled the end picker past the start): clamp, don't drop.
        let inverted = try XCTUnwrap(
            HealthKitWriter.headacheSamples(onset: onset, end: onset.addingTimeInterval(-3600),
                                            severityRaw: 4, now: now).first,
            "a nonsensical end must not discard the headache the user logged")
        XCTAssertEqual(inverted.startDate, onset)
        XCTAssertGreaterThanOrEqual(inverted.endDate, inverted.startDate,
                                    "HealthKit rejects endDate < startDate")

        // End in the future (an open headache flushed with a stale end, or a mis-set picker).
        let future = try XCTUnwrap(HealthKitWriter.headacheSamples(
            onset: onset, end: now.addingTimeInterval(2 * 3600), severityRaw: 3, now: now).first)
        XCTAssertEqual(future.endDate, now,
                       "Apple Health must never hold a headache that hasn't happened yet")

        // Invalid input: `StoredHeadacheEntry.onset` defaults to `.distantPast` for SwiftData
        // lightweight migration, so a row that never got a real onset must produce NOTHING rather
        // than a headache dated year 1 in the user's Health record.
        XCTAssertTrue(HealthKitWriter.headacheSamples(onset: .distantPast, end: nil,
                                                      severityRaw: 3, now: now).isEmpty,
                      "a defaulted/never-set onset must produce no sample")

        // A future onset, by contrast, is still the user's own statement and stays writable — its
        // end is just floored at the onset so the window can never invert.
        let ahead = now.addingTimeInterval(3600)
        let futureOnset = try XCTUnwrap(HealthKitWriter.headacheSamples(
            onset: ahead, end: ahead.addingTimeInterval(1800), severityRaw: 2, now: now).first)
        XCTAssertEqual(futureOnset.startDate, ahead)
        XCTAssertGreaterThanOrEqual(futureOnset.endDate, futureOnset.startDate)
    }

    // MARK: Flush accounting

    /// `FlushResult.wroteAnything` is a hand-maintained enumeration of every counter, so a new
    /// counter that isn't added to it makes a pass that DID write report "nothing written" — the
    /// status line then reads idle while headache labels are landing in Health.
    func testFlushResultCountsHeadacheAsWroteAnything() {
        var result = HealthKitWriter.FlushResult()
        XCTAssertFalse(result.wroteAnything)
        result.headacheEntries = 1
        XCTAssertTrue(result.wroteAnything,
                      "a flush that wrote only headache entries still wrote something")
    }

    // MARK: Name-collision guard

    /// `headacheSamples` and `menstrualFlowSamples` are adjacent `HKCategorySample` builders in the
    /// same type, both taking a start/end/level triple. A copy-paste between them would write a
    /// headache into the user's Cycle Tracking chart (or vice versa) — data that is wrong, private,
    /// and un-deletable by us once saved. Pin the type each builder emits, in both directions.
    func testMenstrualFlowSamplesNeverEmitHeadacheType() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = Date(timeIntervalSince1970: 1_752_192_000) // 2025-07-11 00:00:00 UTC

        let flow = HealthKitWriter.menstrualFlowSamples(start: day, end: day, flowLevelRaw: 2,
                                                        today: day, calendar: calendar)
        XCTAssertFalse(flow.isEmpty)
        for sample in flow {
            XCTAssertEqual(sample.categoryType, HKCategoryType(.menstrualFlow))
            XCTAssertNotEqual(sample.categoryType, HKCategoryType(.headache))
        }

        let headaches = HealthKitWriter.headacheSamples(onset: hoursAgo(2), end: hoursAgo(1),
                                                        severityRaw: 3, now: now)
        XCTAssertFalse(headaches.isEmpty)
        for sample in headaches {
            XCTAssertEqual(sample.categoryType, HKCategoryType(.headache))
            XCTAssertNotEqual(sample.categoryType, HKCategoryType(.menstrualFlow))
            XCTAssertNil(sample.metadata?[HKMetadataKeyMenstrualCycleStart],
                         "the cycle-start key belongs to menstrual flow only")
        }
    }

    // MARK: - Finalization (the open-headache rewrite regression)

    /// An OPEN headache must be FINALIZED. Review found that leaving it pending re-wrote a
    /// byte-identical zero-length sample on every flush — foreground activation, sync completion,
    /// every BLE wake-drain and BGTask — for the life of the entry. Each rewrite reopened the
    /// write-then-delete orphan window, and `wroteAnything` stayed permanently true so every
    /// background wake logged a Health write that carried no new information.
    ///
    /// The failure is invisible at runtime (the data stays correct; only the churn is wrong), which
    /// is exactly why it needs a test rather than a comment.
    func testOpenHeadacheIsSettledSoItIsNotRewrittenForever() {
        let now = Date(timeIntervalSince1970: 1_752_192_000)
        XCTAssertTrue(HealthKitWriter.headacheEntryIsSettled(end: nil, now: now),
                      "end == nil rebuilds an identical zero-length sample forever — finalize it")
    }

    func testPastEndIsSettled() {
        let now = Date(timeIntervalSince1970: 1_752_192_000)
        XCTAssertTrue(HealthKitWriter.headacheEntryIsSettled(end: now.addingTimeInterval(-3600),
                                                             now: now))
        XCTAssertTrue(HealthKitWriter.headacheEntryIsSettled(end: now, now: now),
                      "an end exactly at now is already clamped to itself — nothing left to move")
    }

    /// The ONE case that must stay pending: `headacheSamples` clamps a future end to `now`, so the
    /// correct sample really does change as time passes.
    func testFutureEndIsNotSettled() {
        let now = Date(timeIntervalSince1970: 1_752_192_000)
        XCTAssertFalse(HealthKitWriter.headacheEntryIsSettled(end: now.addingTimeInterval(3600),
                                                              now: now))
    }

    /// Ties the finalization rule to the thing it is a proxy for: if the rebuilt sample is
    /// identical, there is nothing to gain by staying pending. Pins that an open headache's sample
    /// really is time-invariant, so `headacheEntryIsSettled` returning true for it is justified
    /// rather than merely convenient.
    func testOpenHeadacheSampleIsIdenticalOnEveryRebuild() {
        let onset = Date(timeIntervalSince1970: 1_752_192_000)
        let first = HealthKitWriter.headacheSamples(onset: onset, end: nil, severityRaw: 2,
                                                    now: onset.addingTimeInterval(60))
        let muchLater = HealthKitWriter.headacheSamples(onset: onset, end: nil, severityRaw: 2,
                                                        now: onset.addingTimeInterval(86_400 * 30))
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(muchLater.count, 1)
        XCTAssertEqual(first[0].startDate, muchLater[0].startDate)
        XCTAssertEqual(first[0].endDate, muchLater[0].endDate,
                       "an open headache's sample must not drift with `now` — if it did, the "
                       + "finalize-immediately rule would be wrong")
        XCTAssertEqual(first[0].value, muchLater[0].value)
    }
}

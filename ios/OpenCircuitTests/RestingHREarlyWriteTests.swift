import XCTest
import OpenCircuitKit
@testable import OpenCircuit

/// SYNTHETIC-ONLY tests for decision 96 (#404): a day's resting HR reaches Apple Health once its night
/// is there, as a provisional sample replaced while its whole-bpm value changes, and final at the
/// 12 h cutoff. Drives the pure plan (`restingHRActions`) and the executor (`runRestingHRFlush`, the
/// body of `flushRestingHR`) against an in-memory Health store, so no HealthKit is involved. Every
/// `now` is injected; nothing reads the wall clock.
@MainActor
final class RestingHREarlyWriteTests: XCTestCase {

    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    /// Start of a fixed synthetic day (UTC).
    private let today = Date(timeIntervalSince1970: 1_790_726_400)
    private func day(_ offset: Int) -> Date { cal.date(byAdding: .day, value: offset, to: today)! }
    private func at(_ hours: Double, _ offset: Int = 0) -> Date { day(offset).addingTimeInterval(hours * 3600) }

    // MARK: Fixtures

    /// Asleep readings every 5 min from midnight to `until` h, all `bpm`: the sleep mean is `bpm`.
    private func night(_ day: Date, bpm: Int = 52, until hours: Double = 7) -> [HRSample] {
        stride(from: 0.0, to: hours * 3600, by: 300).map { HRSample(bpm: bpm, start: day.addingTimeInterval($0)) }
    }

    /// The night's asleep segment: 23:00 the evening before to 07:00.
    private func sleep(_ day: Date) -> [SleepSegment] {
        [SleepSegment(start: day.addingTimeInterval(-3600), end: day.addingTimeInterval(7 * 3600), stage: .asleepCore)]
    }

    /// Five awake spot reads ten minutes apart from 08:00: below `RestingHR.dayCoverage`.
    private func thinDay(_ day: Date) -> [HRSample] {
        (0..<5).map { HRSample(bpm: 80 + $0, start: day.addingTimeInterval(8 * 3600 + Double($0) * 600)) }
    }

    /// An in-memory Health store for this app's resting-HR samples.
    private final class FakeHealth {
        enum Op: Equatable { case save(Double), delete(UUID) }
        var live: [UUID: (day: Date, bpm: Double)] = [:]
        var ops: [Op] = []
        var failSaves = false
        var failDeletes = false
        var persisted: [HealthKitWriter.RestingHRWriteState] = []

        func save(_ bpm: Double, _ day: Date) throws -> UUID {
            if failSaves { throw CancellationError() }
            let id = UUID()
            live[id] = (day, bpm)
            ops.append(.save(bpm))
            return id
        }
        func delete(_ id: UUID) throws {
            if failDeletes { throw CancellationError() }
            live[id] = nil
            ops.append(.delete(id))
        }
        func samples(on day: Date) -> [Double] { live.values.filter { $0.day == day }.map(\.bpm) }
        /// Seeds a sample already in Health (a provisional one written by an earlier flush).
        func seed(_ bpm: Double, _ day: Date) -> HealthKitWriter.ProvisionalRestingHR {
            let id = UUID()
            live[id] = (day, bpm)
            return .init(day: day, bpm: bpm, uuid: id)
        }
    }

    private func flush(_ health: FakeHealth, hr: [HRSample] = [], reported: [HRSample] = [],
                       sleep: [SleepSegment] = [], state: HealthKitWriter.RestingHRWriteState,
                       now: Date, mirrored: Set<Date>? = nil,
                       calendar: Calendar? = nil) async -> (state: HealthKitWriter.RestingHRWriteState,
                                                            written: Int, failed: Bool) {
        let outcome = await HealthKitWriter.runRestingHRFlush(
            hr: hr, reported: reported, sleepSegments: sleep, state: state, now: now,
            calendar: calendar ?? cal, mirroredNights: mirrored ?? [today],
            save: { try health.save($0, $1) }, delete: { try health.delete($0) },
            persist: { health.persisted.append($0) })
        if let last = health.persisted.last { XCTAssertEqual(last, outcome.state, "the last persist is the outcome") }
        return outcome
    }

    private var afterYesterday: HealthKitWriter.RestingHRWriteState { .init(watermark: day(-1)) }

    // MARK: The early write (96a, 96b)

    func testAMirroredNightWithADeviceRecordIsWrittenEarlyWithThatValue() async {
        let health = FakeHealth()
        let reported = [HRSample(bpm: 57, start: at(5))]
        let r = await flush(health, hr: night(today), reported: reported, sleep: sleep(today),
                            state: afterYesterday, now: at(7.5))
        XCTAssertEqual(health.ops, [.save(57)])
        XCTAssertEqual(health.samples(on: today), [57])
        XCTAssertEqual(r.state.watermark, day(-1), "an early write never moves the watermark")
        XCTAssertEqual(r.state.provisional?.day, today)
        XCTAssertEqual(r.state.provisional?.bpm, 57)
        XCTAssertNotNil(r.state.provisional.flatMap { health.live[$0.uuid] }, "the record names the saved sample")
        XCTAssertEqual(r.written, 1)
        XCTAssertFalse(r.failed)
    }

    func testAMirroredNightWithoutADeviceRecordIsWrittenEarlyWithTheSleepMean() async {
        let health = FakeHealth()
        let r = await flush(health, hr: night(today, bpm: 53), sleep: sleep(today), state: afterYesterday, now: at(7.5))
        XCTAssertEqual(health.ops, [.save(53)])
        XCTAssertEqual(r.state.provisional?.bpm, 53)
        XCTAssertEqual(r.state.watermark, day(-1))
    }

    func testANightNotInHealthWaitsForTheCutoffAsBefore() async {
        let health = FakeHealth()
        let hr = night(today), s = sleep(today)
        let morning = await flush(health, hr: hr, sleep: s, state: afterYesterday, now: at(7.5), mirrored: [])
        XCTAssertTrue(health.ops.isEmpty)
        XCTAssertNil(morning.state.provisional)
        // A night mirrored for another day doesn't count.
        _ = await flush(health, hr: hr, sleep: s, state: afterYesterday, now: at(11.5), mirrored: [day(-1)])
        XCTAssertTrue(health.ops.isEmpty)
        // At the cutoff the finalized path writes it, and the watermark moves.
        let noon = await flush(health, hr: hr, sleep: s, state: morning.state, now: at(12), mirrored: [])
        XCTAssertEqual(health.ops, [.save(52)])
        XCTAssertEqual(noon.state.watermark, today)
        XCTAssertNil(noon.state.provisional)
        // Its plan is master's: no early action at all without a mirrored night.
        XCTAssertEqual(HealthKitWriter.restingHRActions(hr: hr, sleepSegments: s, lastWritten: day(-1),
                                                        now: at(7.5), calendar: cal), [])
    }

    func testAThinOrMissingValueIsNotWrittenEarly() async {
        let health = FakeHealth()
        let thin = await flush(health, hr: thinDay(today), state: afterYesterday, now: at(9))
        XCTAssertTrue(health.ops.isEmpty)
        XCTAssertNil(thin.state.provisional)
        let none = await flush(health, state: afterYesterday, now: at(9))
        XCTAssertTrue(health.ops.isEmpty)
        XCTAssertNil(none.state.provisional)
    }

    func testADayAtTheWatermarkIsNotWrittenEarly() async {
        let health = FakeHealth()
        let r = await flush(health, hr: night(today), sleep: sleep(today), state: .init(watermark: today), now: at(8))
        XCTAssertTrue(health.ops.isEmpty)
        XCTAssertNil(r.state.provisional)
    }

    func testOnlyTodayIsWrittenEarly() {
        // Tomorrow's records filed early (the noon rule) never make a provisional day of tomorrow.
        let reported = [HRSample(bpm: 60, start: at(13))]
        let actions = HealthKitWriter.restingHRActions(hr: night(today), reported: reported, sleepSegments: sleep(today),
                                                       lastWritten: day(-1), now: at(13.5), calendar: cal,
                                                       mirroredNights: [today, day(1)])
        XCTAssertEqual(actions, [.write(day: today, bpm: 52)])
    }

    // MARK: Replacement before the cutoff (96c)

    func testALaterRecordWithAnotherWholeBpmReplacesTheSampleSaveFirst() async {
        let health = FakeHealth()
        let old = health.seed(57, today)
        let reported = [HRSample(bpm: 57, start: at(5)), HRSample(bpm: 55, start: at(8))]
        let r = await flush(health, hr: night(today), reported: reported, sleep: sleep(today),
                            state: .init(watermark: day(-1), provisional: old), now: at(9))
        XCTAssertEqual(health.ops, [.save(55), .delete(old.uuid)], "save the new sample, then delete the old one")
        XCTAssertEqual(health.samples(on: today), [55])
        XCTAssertEqual(r.state.provisional?.bpm, 55)
        XCTAssertNotEqual(r.state.provisional?.uuid, old.uuid)
        XCTAssertEqual(r.state.watermark, day(-1))
        XCTAssertEqual(r.state.pendingDeletes, [])
        // The record named the new sample before the delete ran.
        XCTAssertEqual(health.persisted.first?.provisional?.bpm, 55)
    }

    func testTheSameWholeBpmNeitherWritesNorDeletes() async {
        // Sleep mean 54.4 against a recorded 54.2: the same day's value, no churn on a re-staged night.
        let hr = [54, 54, 54, 55, 55].enumerated().map { HRSample(bpm: $1, start: at(1 + Double($0) * 0.5)) }
        XCTAssertEqual(HealthKitWriter.restingHRWritePlan(hr: hr, sleepSegments: sleep(today), lastWritten: day(-1),
                                                          now: at(13), calendar: cal).first?.bpm ?? 0,
                       54.4, accuracy: 1e-9)
        let health = FakeHealth()
        let old = health.seed(54.2, today)
        let r = await flush(health, hr: hr, sleep: sleep(today), state: .init(watermark: day(-1), provisional: old), now: at(9))
        XCTAssertTrue(health.ops.isEmpty)
        XCTAssertEqual(r.state.provisional, old)
        XCTAssertEqual(r.written, 0)
    }

    func testAFailedReplacementSaveChangesNothingAndIsSurfaced() async {
        let health = FakeHealth()
        let old = health.seed(57, today)
        health.failSaves = true
        let reported = [HRSample(bpm: 55, start: at(8))]
        let r = await flush(health, hr: night(today), reported: reported, sleep: sleep(today),
                            state: .init(watermark: day(-1), provisional: old), now: at(9))
        XCTAssertTrue(r.failed)
        XCTAssertTrue(health.ops.isEmpty, "no delete after a failed save")
        XCTAssertEqual(health.samples(on: today), [57])
        XCTAssertEqual(r.state.provisional, old)
        XCTAssertEqual(r.state.pendingDeletes, [])
    }

    func testAFailedDeleteIsQueuedRetriedAndClearedOnSuccess() async {
        let health = FakeHealth()
        let old = health.seed(57, today)
        health.failDeletes = true
        let reported = [HRSample(bpm: 55, start: at(8))]
        let first = await flush(health, hr: night(today), reported: reported, sleep: sleep(today),
                                state: .init(watermark: day(-1), provisional: old), now: at(9))
        XCTAssertFalse(first.failed, "the new value is in Health")
        XCTAssertEqual(first.state.provisional?.bpm, 55)
        XCTAssertEqual(first.state.pendingDeletes, [.init(uuid: old.uuid, day: today)])
        // The next flush retries it first, still failing: kept, nothing else changes.
        let second = await flush(health, hr: night(today), reported: reported, sleep: sleep(today),
                                 state: first.state, now: at(9.5))
        XCTAssertEqual(second.state.pendingDeletes, [.init(uuid: old.uuid, day: today)])
        XCTAssertEqual(health.samples(on: today).sorted(), [55, 57])
        // Then it succeeds: removed from the queue, one sample left.
        health.failDeletes = false
        let third = await flush(health, hr: night(today), reported: reported, sleep: sleep(today),
                                state: second.state, now: at(10))
        XCTAssertEqual(health.ops.last, .delete(old.uuid))
        XCTAssertEqual(third.state.pendingDeletes, [])
        XCTAssertEqual(health.samples(on: today), [55])
    }

    func testAQueuedDeleteOlderThanSevenDaysIsDropped() async {
        let health = FakeHealth()
        let stale = PendingRestingHRDeleteFixture.entry(day: day(-8))
        let recent = PendingRestingHRDeleteFixture.entry(day: day(-7))
        health.failDeletes = true
        let r = await flush(health, state: .init(watermark: day(-1), pendingDeletes: [stale, recent]), now: at(9))
        XCTAssertEqual(r.state.pendingDeletes, [recent], "the stale entry is dropped, the recent one kept")
        health.failDeletes = false
        let next = await flush(health, state: r.state, now: at(9.5))
        XCTAssertEqual(health.ops, [.delete(recent.uuid)], "the stale entry is never retried")
        XCTAssertEqual(next.state.pendingDeletes, [])
    }

    // MARK: Finalization (96d)

    func testAnUnchangedProvisionalDayIsFinalizedInPlace() async {
        let health = FakeHealth()
        let old = health.seed(52.3, today)
        let r = await flush(health, hr: night(today), sleep: sleep(today),
                            state: .init(watermark: day(-1), provisional: old), now: at(12))
        XCTAssertTrue(health.ops.isEmpty, "no rewrite of an unchanged day")
        XCTAssertEqual(r.state.watermark, today)
        XCTAssertNil(r.state.provisional)
        XCTAssertEqual(health.samples(on: today), [52.3])
    }

    func testAChangedProvisionalDayIsReplacedThenFinalized() async {
        let health = FakeHealth()
        let old = health.seed(57, today)
        let reported = [HRSample(bpm: 54, start: at(10))]
        let r = await flush(health, hr: night(today), reported: reported, sleep: sleep(today),
                            state: .init(watermark: day(-1), provisional: old), now: at(12))
        XCTAssertEqual(health.ops, [.save(54), .delete(old.uuid)])
        XCTAssertEqual(r.state.watermark, today)
        XCTAssertNil(r.state.provisional)
        XCTAssertEqual(health.samples(on: today), [54])
    }

    func testAFailedFinalizingSaveKeepsTheProvisionalDay() async {
        let health = FakeHealth()
        let old = health.seed(57, today)
        health.failSaves = true
        let r = await flush(health, hr: night(today), reported: [HRSample(bpm: 54, start: at(10))],
                            sleep: sleep(today), state: .init(watermark: day(-1), provisional: old), now: at(12))
        XCTAssertTrue(r.failed)
        XCTAssertEqual(r.state, .init(watermark: day(-1), provisional: old))
        XCTAssertEqual(health.samples(on: today), [57])
    }

    func testAProvisionalDayWithNoValueNowKeepsItsSampleAndIsFinalized() async {
        let health = FakeHealth()
        let old = health.seed(52, today)
        // Thin readings only (the night's rows gone), and then none at all.
        let thin = await flush(health, hr: thinDay(today), state: .init(watermark: day(-1), provisional: old), now: at(12))
        XCTAssertTrue(health.ops.isEmpty)
        XCTAssertEqual(thin.state.watermark, today)
        XCTAssertNil(thin.state.provisional)
        let empty = await flush(health, state: .init(watermark: day(-1), provisional: old), now: at(12))
        XCTAssertTrue(health.ops.isEmpty)
        XCTAssertEqual(empty.state.watermark, today)
        XCTAssertNil(empty.state.provisional)
        XCTAssertEqual(health.samples(on: today), [52])
    }

    func testAProvisionalRecordAtOrBehindTheWatermarkIsClearedWithoutAWrite() async {
        let health = FakeHealth()
        let old = health.seed(52, day(-1))
        let r = await flush(health, hr: night(day(-1)), sleep: sleep(day(-1)),
                            state: .init(watermark: day(-1), provisional: old), now: at(9), mirrored: [])
        XCTAssertTrue(health.ops.isEmpty)
        XCTAssertNil(r.state.provisional)
        XCTAssertEqual(r.state.watermark, day(-1))
        XCTAssertEqual(HealthKitWriter.restingHRActions(hr: [], sleepSegments: [], lastWritten: day(-1), now: at(9),
                                                        calendar: cal, provisional: old), [.clearProvisional])
    }

    func testYesterdaysProvisionalDayIsFinalizedBeforeTodaysEarlyWrite() async {
        // The phone was off at yesterday's cutoff: the next flush finalizes yesterday first, then
        // writes today early, and the watermark stops on yesterday.
        let health = FakeHealth()
        let old = health.seed(55, day(-1))
        let hr = night(day(-1), bpm: 55) + night(today, bpm: 51)
        let r = await flush(health, hr: hr, sleep: sleep(day(-1)) + sleep(today),
                            state: .init(watermark: day(-2), provisional: old), now: at(8))
        XCTAssertEqual(health.ops, [.save(51)])
        XCTAssertEqual(r.state.watermark, day(-1))
        XCTAssertEqual(r.state.provisional?.day, today)
        XCTAssertEqual(health.samples(on: day(-1)), [55])
    }

    // MARK: Persistence (96b, 96c)

    func testTheStateRoundTripsAndAnUnreadableRecordCountsAsAbsent() throws {
        let suite = "RestingHREarlyWriteTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = HealthKitWriter.RestingHRWriteState(
            watermark: day(-1), provisional: .init(day: today, bpm: 52.5, uuid: UUID()),
            pendingDeletes: [.init(uuid: UUID(), day: day(-1))])
        HealthKitWriter.saveRestingHRState(state, defaults)
        XCTAssertEqual(HealthKitWriter.loadRestingHRState(defaults), state)
        // Cleared record and queue are removed, and the watermark never moves back.
        HealthKitWriter.saveRestingHRState(.init(watermark: day(-2)), defaults)
        XCTAssertEqual(HealthKitWriter.loadRestingHRState(defaults), .init(watermark: day(-1)))
        defaults.set(Data("not json".utf8), forKey: "hk.restingHR.provisional.v1")
        defaults.set(Data("[{}]".utf8), forKey: "hk.restingHR.pendingDeletes.v1")
        XCTAssertEqual(HealthKitWriter.loadRestingHRState(defaults), .init(watermark: day(-1)))
    }

    // MARK: Order inside one flush (96f)

    /// SOURCE-ORDER assertion (a hosted `flushToHealth` needs HealthKit share authorization, which a
    /// test host doesn't have): inside `flushToHealth`, both night mirrors are called before
    /// `flushRestingHR`, so the flush that writes the night can write the day's resting HR.
    func testTheNightMirrorRunsBeforeTheRestingHRFlush() throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("OpenCircuit/Health/HealthKitWriter.swift")
        let source = try String(contentsOf: path, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "func flushToHealth(store: LocalStore"))
        let rest = source[start.upperBound...]
        let end = try XCTUnwrap(rest.range(of: "\n    }\n"))
        let body = String(rest[..<end.lowerBound])
        func offset(_ call: String) throws -> Int {
            let r = try XCTUnwrap(body.range(of: call), "\(call) is called in flushToHealth")
            return body.distance(from: body.startIndex, to: r.lowerBound)
        }
        let rhr = try offset("await flushRestingHR(")
        XCTAssertLessThan(try offset("await mirrorSettledNight(local: store, segments: sleepSegments)"), rhr)
        XCTAssertLessThan(try offset("await mirrorStrapNight(local: store, segments: night)"), rhr)
        XCTAssertEqual(body.components(separatedBy: "flushRestingHR(").count, 2, "one resting-HR flush per pass")
    }
}

private enum PendingRestingHRDeleteFixture {
    static func entry(day: Date) -> HealthKitWriter.PendingRestingHRDelete { .init(uuid: UUID(), day: day) }
}

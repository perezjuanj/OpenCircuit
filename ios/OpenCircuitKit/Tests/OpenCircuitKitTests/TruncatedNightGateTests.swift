import XCTest
@testable import OpenCircuitKit

/// The TRUNCATED-NIGHT correction to the overnight gate.
///
/// A night can reach us as a TAIL only — a missed overnight drain, a re-pair, the ring off the finger
/// for the first half. The observed start is then LATER than the true onset, dragging the observed
/// midpoint towards morning, and the plain midpoint rule discards the whole night (blank Sleep card,
/// nothing in Apple Health).
///
/// 🟢 Measured on a real Gen 2 Air (FR04.009, model ...-AA55) archive whose night ended 08-02 11:21
/// local:
///
///     retained tail | in-bed envelope      | midpoint | plain rule
///      2.00 h       | 09:21 -> 11:21       | 10:21    | DISCARDED
///      3.00 h       | 08:21 -> 11:21       | 09:51    | DISCARDED
///      4.00 h       | 07:21 -> 11:21       | 09:21    | DISCARDED
///      4.75 h       | 06:36 -> 11:21       | 08:58    | pass
///      6.00 h       | 05:21 -> 11:21       | 08:21    | pass
///
/// THREE pieces, tested here in that order:
///   1. `SleepWindow.isOvernightBlock(start:end:onsetIsUnobserved:)` — pure date math, and NOT safe
///      alone (it is duration-blind; see `testDateMathAloneCannotRejectASedentaryMorning`).
///   2. `BulkSleep.onsetIsUnobserved(_:in:epoch:)` — the presumed data must genuinely be MISSING.
///   3. **The call site**, `BulkSleep.latestNightRecords` — the correction runs only when the plain
///      rule accepted nothing. Every defect this rework closed slipped through because 1 and 2 were
///      tested only in isolation, so the `MARK: call site` block below is the important half.
final class TruncatedNightGateTests: XCTestCase {

    /// Fixed UTC calendar for the PURE date-math tests, so the hour-of-day they read is deterministic
    /// in CI regardless of locale (same idiom as `SleepWindowTests`).
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return c
    }

    private func date(_ iso: String) throws -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return try XCTUnwrap(f.date(from: iso), "unparsable fixture date \(iso)")
    }

    /// The measured night's wake: 08-02 11:21.
    private func wake() throws -> Date { try date("2026-08-02T11:21:00Z") }

    /// A retained tail of `hours`, i.e. the night as the archive actually holds it.
    private func tail(_ hours: Double) throws -> (start: Date, end: Date) {
        let end = try wake()
        return (end.addingTimeInterval(-hours * 3600), end)
    }

    // MARK: - 1. pure date math — the measured table

    /// 2 h tail (09:21 → 11:21). Observed midpoint 10:21 → the plain rule DISCARDED the night; the
    /// presumed 7 h onset (04:21) gives midpoint 07:51 → accepted. This is the bug, fixed.
    func testTwoHourTailIsAcceptedWhenOnsetIsUnobserved() throws {
        let t = try tail(2.0)
        XCTAssertFalse(SleepWindow.isOvernightBlock(start: t.start, end: t.end, calendar: utc),
                       "precondition: the plain rule discards this night")
        XCTAssertTrue(SleepWindow.isOvernightBlock(start: t.start, end: t.end,
                                                   onsetIsUnobserved: true, calendar: utc),
                      "a 2 h tail whose onset was never recorded is still overnight")
    }

    /// 3 h tail (08:21 → 11:21), observed midpoint 09:51 → was discarded.
    func testThreeHourTailIsAcceptedWhenOnsetIsUnobserved() throws {
        let t = try tail(3.0)
        XCTAssertFalse(SleepWindow.isOvernightBlock(start: t.start, end: t.end, calendar: utc))
        XCTAssertTrue(SleepWindow.isOvernightBlock(start: t.start, end: t.end,
                                                   onsetIsUnobserved: true, calendar: utc))
    }

    /// 4 h tail (07:21 → 11:21), observed midpoint 09:21 → was discarded (the boundary case).
    func testFourHourTailIsAcceptedWhenOnsetIsUnobserved() throws {
        let t = try tail(4.0)
        XCTAssertFalse(SleepWindow.isOvernightBlock(start: t.start, end: t.end, calendar: utc))
        XCTAssertTrue(SleepWindow.isOvernightBlock(start: t.start, end: t.end,
                                                   onsetIsUnobserved: true, calendar: utc))
    }

    /// 4.75 h tail (06:36 → 11:21), observed midpoint 08:58 — which the plain rule already passed.
    /// Pin it: the correction must not disturb the cases that already worked.
    func testFullBufferTailPassedBeforeAndAfter() throws {
        let t = try tail(4.75)
        XCTAssertTrue(SleepWindow.isOvernightBlock(start: t.start, end: t.end, calendar: utc),
                      "midpoint 08:58 — the plain rule already accepted this")
        XCTAssertTrue(SleepWindow.isOvernightBlock(start: t.start, end: t.end,
                                                   onsetIsUnobserved: true, calendar: utc))
    }

    /// 6 h tail (05:21 → 11:21), observed midpoint 08:21 — accepted before and after.
    func testSixHourTailPassedBeforeAndAfter() throws {
        let t = try tail(6.0)
        XCTAssertTrue(SleepWindow.isOvernightBlock(start: t.start, end: t.end, calendar: utc))
        XCTAssertTrue(SleepWindow.isOvernightBlock(start: t.start, end: t.end,
                                                   onsetIsUnobserved: true, calendar: utc))
    }

    /// An afternoon nap (12:00 → 14:30): presumed onset 07:30, midpoint 11:00 → still REJECTED.
    func testAfternoonNapStillRejected() throws {
        let start = try date("2026-08-02T12:00:00Z")
        let end = try date("2026-08-02T14:30:00Z")
        XCTAssertFalse(SleepWindow.isOvernightBlock(start: start, end: end,
                                                    onsetIsUnobserved: true, calendar: utc),
                       "presumed start 07:30 → midpoint 11:00 is daytime")
    }

    /// An evening block (19:00 → 22:00, e.g. a movie): presumed onset 15:00, midpoint 18:30 → still
    /// REJECTED.
    func testEveningBlockStillRejected() throws {
        let start = try date("2026-08-02T19:00:00Z")
        let end = try date("2026-08-02T22:00:00Z")
        XCTAssertFalse(SleepWindow.isOvernightBlock(start: start, end: end,
                                                    onsetIsUnobserved: true, calendar: utc),
                       "presumed start 15:00 → midpoint 18:30 is evening, not night")
    }

    /// ⚠️ THE DATE MATH IS NOT A SAFETY GATE, and must never be treated as one. Once a block is
    /// shorter than the presumed span, `min(start, end - 7h)` IS `end - 7h`, so the block's own start
    /// and duration are ERASED and the rule degenerates to "accept iff the wake falls in
    /// [00:30, 12:30)". A 10:29 → 12:29 sedentary desk morning is therefore accepted BY THE
    /// ARITHMETIC. What rejects it is `BulkSleep.onsetIsUnobserved` (the presumed 6.5 h of data is
    /// not actually missing) and the two-pass filter at the call site. This test exists so nobody
    /// "hardens" the date math and deletes the real guards.
    func testDateMathAloneCannotRejectASedentaryMorning() throws {
        let start = try date("2026-08-02T10:29:00Z")
        let end = try date("2026-08-02T12:29:00Z")
        XCTAssertFalse(SleepWindow.isOvernightBlock(start: start, end: end, calendar: utc),
                       "observed midpoint 11:29 → the plain rule rejects it")
        XCTAssertTrue(SleepWindow.isOvernightBlock(start: start, end: end,
                                                   onsetIsUnobserved: true, calendar: utc),
                      "date math alone accepts it — which is exactly why the flag must be earned")
        // The date math is a function of `end` alone once the block is shorter than the presumed span.
        for durationMinutes in [61, 90, 120, 240] {
            let s = end.addingTimeInterval(-TimeInterval(durationMinutes * 60))
            XCTAssertTrue(SleepWindow.isOvernightBlock(start: s, end: end,
                                                       onsetIsUnobserved: true, calendar: utc),
                          "dur=\(durationMinutes)m: duration-blind by construction")
        }
    }

    /// ⚠️ REGRESSION GUARD for the design itself. An EARLY-EVENING-ONSET night (20:30 → 23:30) has
    /// observed midpoint 22:00 — accepted by the plain rule — but presumed-onset midpoint 20:00, which
    /// is NOT overnight. Judging the presumed midpoint ALONE (a plain substitution instead of the OR)
    /// would therefore REJECT a night the plain rule accepted, i.e. introduce exactly the blank-card
    /// bug this change exists to remove. A brute-force sweep found 7683 such (start, duration) pairs.
    func testEarlyEveningOnsetAtLeadingEdgeStillAccepted() throws {
        let start = try date("2026-08-01T20:30:00Z")
        let end = try date("2026-08-01T23:30:00Z")
        XCTAssertTrue(SleepWindow.isOvernightBlock(start: start, end: end, calendar: utc),
                      "precondition: the plain rule accepts this (midpoint 22:00)")
        XCTAssertFalse(SleepWindow.isOvernightBlock(
            start: end.addingTimeInterval(-SleepWindow.presumedTruncatedNightSpan),
            end: end, calendar: utc),
            "precondition: the PRESUMED-onset midpoint alone (20:00) would be rejected")
        XCTAssertTrue(SleepWindow.isOvernightBlock(start: start, end: end,
                                                   onsetIsUnobserved: true, calendar: utc),
                      "the OR keeps it accepted — a plain substitution would have regressed it")
    }

    /// NEVER LESS ACCEPTING: over a dense sweep of block starts/durations, the corrected form accepts
    /// everything the plain form accepts.
    func testNeverLessAcceptingThanThePlainRule() throws {
        let base = try date("2026-08-02T00:00:00Z")
        for startMinutes in stride(from: 0, to: 24 * 60, by: 7) {
            for durationMinutes in stride(from: 30, through: 12 * 60, by: 13) {
                let start = base.addingTimeInterval(TimeInterval(startMinutes * 60))
                let end = start.addingTimeInterval(TimeInterval(durationMinutes * 60))
                let plain = SleepWindow.isOvernightBlock(start: start, end: end, calendar: utc)
                let corrected = SleepWindow.isOvernightBlock(start: start, end: end,
                                                             onsetIsUnobserved: true, calendar: utc)
                if plain {
                    XCTAssertTrue(corrected,
                                  "start=\(startMinutes)m dur=\(durationMinutes)m: the correction must never reject what the plain rule accepted")
                }
            }
        }
    }

    /// IDENTITY WHEN THE ONSET WAS OBSERVED: with the flag false the corrected form is byte-identical
    /// to the plain form, for every start/duration. This is the whole no-regression guarantee.
    func testIdentityWhenOnsetWasObserved() throws {
        let base = try date("2026-08-02T00:00:00Z")
        for startMinutes in stride(from: 0, to: 24 * 60, by: 3) {
            for durationMinutes in stride(from: 30, through: 14 * 60, by: 11) {
                let start = base.addingTimeInterval(TimeInterval(startMinutes * 60))
                let end = start.addingTimeInterval(TimeInterval(durationMinutes * 60))
                XCTAssertEqual(
                    SleepWindow.isOvernightBlock(start: start, end: end,
                                                 onsetIsUnobserved: false, calendar: utc),
                    SleepWindow.isOvernightBlock(start: start, end: end, calendar: utc),
                    "start=\(startMinutes)m dur=\(durationMinutes)m must delegate unchanged")
            }
        }
    }

    /// A block ALREADY longer than the presumed span keeps its own (earlier) start — the `min`, not a
    /// `max`. A 10 h night 22:00 → 08:00 must not be re-judged as a 7 h night.
    func testLongBlockKeepsItsOwnStart() throws {
        let start = try date("2026-08-01T22:00:00Z")
        let end = try date("2026-08-02T08:00:00Z")
        XCTAssertEqual(SleepWindow.isOvernightBlock(start: start, end: end,
                                                    onsetIsUnobserved: true, calendar: utc),
                       SleepWindow.isOvernightBlock(start: start, end: end, calendar: utc),
                       "10 h > 7 h presumed span → the presumption is inert")
    }

    // MARK: - 2. the record-side predicate — BulkSleep.onsetIsUnobserved

    /// Records at the real 150 s cadence. `slots` supplies the primary motion channel `[10:15]` for
    /// epoch `i`; the default is a flat `1`, i.e. still.
    private func records(from start: Date, count: Int,
                         epoch: Int = Command.syncEpoch,
                         slots: (Int) -> [UInt8] = { _ in [UInt8](repeating: 1, count: 5) })
        -> [BulkRecord] {
        let base = UInt32(Int(start.timeIntervalSince1970) - epoch)
        return (0 ..< count).compactMap { i in
            let counter = base + UInt32(i * BulkRecord.epochSeconds)
            var b = [UInt8](repeating: 0, count: BulkRecord.length)
            b[0] = UInt8((counter >> 24) & 0xff); b[1] = UInt8((counter >> 16) & 0xff)
            b[2] = UInt8((counter >> 8) & 0xff);  b[3] = UInt8(counter & 0xff)
            b[4] = 60                                   // HR
            b[5] = 40                                   // HRV
            b[7] = 14                                   // RR
            b[8] = 96                                   // SpO2 % ⇒ .sleepVitals
            b[9] = 0x0b
            let m = slots(i)
            for k in 10 ..< 15 { b[k] = m[k - 10] }
            return BulkRecord(b)
        }
    }

    /// AWAKE epochs. ⚠️ A CONSTANT high motion value is NOT "moving": `ActivityPeriod` de-floors the
    /// channel against a rolling p10 (`motionAboveLocalFloor`), so a flat plateau at ANY level cancels
    /// to ~0 and reads STILL — the whole point of that de-flooring. Awake motion has to vary WITHIN the
    /// epoch (so the intra-epoch spread clears `motionStillThreshold`) and BETWEEN epochs (so the
    /// rolling floor cannot track it). An earlier revision's fixture wrote a flat 20 and silently
    /// produced a still block, which is what let a call-site test assert the wrong thing.
    private func awakeRecords(from start: Date, count: Int,
                              epoch: Int = Command.syncEpoch) -> [BulkRecord] {
        let shape: [UInt8] = [8, 62, 19, 77, 34]
        return records(from: start, count: count, epoch: epoch) { i in
            let lift = UInt8((i % 7) * 6)
            return (0 ..< 5).map { shape[($0 + i) % 5] &+ lift }
        }
    }

    /// Contiguous recording running INTO the onset ⇒ the onset WAS captured, so no presumption.
    func testContiguousRunBeforeOnsetMeansObserved() throws {
        let onset = try date("2026-08-02T09:21:00Z")
        let end = try date("2026-08-02T11:21:00Z")
        let before = records(from: onset.addingTimeInterval(-4 * 3600), count: 96)
        let block = records(from: onset, count: 48)
        XCTAssertFalse(BulkSleep.onsetIsUnobserved(DateInterval(start: onset, end: end),
                                                   in: before + block),
                       "the epoch immediately before the onset exists → the onset was captured")
    }

    /// A full day of YESTERDAY's epochs, a multi-hour HOLE, then the tail. The union minimum is a day
    /// before the night — which is why a "start == min(all records)" form no-ops on real devices; the
    /// HOLE is what this predicate looks for.
    func testHoleBeforeOnsetMeansUnobserved() throws {
        let onset = try date("2026-08-02T09:21:00Z")
        let end = try date("2026-08-02T11:21:00Z")
        // Yesterday 07:21 → 20:00, then nothing until the tail: a ~13.4 h hole (needed: 7 − 2 = 5 h).
        let yesterday = records(from: try date("2026-08-01T07:21:00Z"), count: 304)
        let block = records(from: onset, count: 48)
        let union = yesterday + block
        XCTAssertTrue(BulkSleep.onsetIsUnobserved(DateInterval(start: onset, end: end), in: union))
        XCTAssertTrue(SleepWindow.isOvernightBlock(
            start: onset, end: end,
            onsetIsUnobserved: BulkSleep.onsetIsUnobserved(DateInterval(start: onset, end: end),
                                                           in: union),
            calendar: utc))
    }

    /// No record at all before the block (first-ever sync, wiped archive) ⇒ an unbounded hole.
    func testNoRecordBeforeOnsetMeansUnobserved() throws {
        let onset = try date("2026-08-02T09:21:00Z")
        let end = try date("2026-08-02T11:21:00Z")
        XCTAssertTrue(BulkSleep.onsetIsUnobserved(DateInterval(start: onset, end: end),
                                                  in: records(from: onset, count: 48)))
    }

    /// ⚠️ THE CONDITION THAT REPLACED THE DISCREDITED SLEEP-VITALS SHARE. A late-morning doze behind a
    /// 600 s gap presumes ~6 h of a night that is demonstrably PRESENT in the archive, so the
    /// presumption is refused. 🟢 The 600 s figure is not invented: the 2F9F export of 2026-08-02 has a
    /// real record-run leading edge at 09:46:53 local behind exactly a 600 s gap.
    func testShortHoleCannotPresumeALongOnset() throws {
        let onset = try date("2026-08-02T10:29:00Z")
        let end = try date("2026-08-02T12:29:00Z")
        let before = run(onset.addingTimeInterval(-6 * 3600), endingBefore: onset, hole: 600)
        let block = records(from: onset, count: 48)
        let previous = try XCTUnwrap(before.map { $0.date() }.max())
        XCTAssertEqual(onset.timeIntervalSince(previous), 600, accuracy: 1,
                       "precondition: exactly a 600 s hole")
        XCTAssertFalse(BulkSleep.onsetIsUnobserved(DateInterval(start: onset, end: end),
                                                   in: before + block),
                       "a 2 h block presumes 5 h of absence; only 600 s is missing")
    }

    /// The requirement SCALES with how much the presumption claims: the same 3 h hole is enough for a
    /// 4 h tail (needs 7 − 4 = 3 h) and not enough for a 2 h tail (needs 5 h).
    func testRequiredHoleScalesWithTheTailLength() throws {
        let end = try date("2026-08-02T11:21:00Z")
        // The SAME 3 h hole is not enough for a 2 h tail (which claims 5 h is missing) and is enough
        // for a 4 h tail (which claims 3 h) — the requirement scales with what is being presumed.
        for (hours, holeIsEnough) in [(2.0, false), (4.0, true)] {
            let onset = end.addingTimeInterval(-hours * 3600)
            // One epoch past the requirement, because the predicate is strictly `>` — see
            // `testRequiredHoleIsStrictlyGreaterThanTheClaim` for the boundary itself.
            let hole = 3 * 3600 + Double(BulkRecord.epochSeconds)
            let before = run(onset.addingTimeInterval(-27 * 3600), endingBefore: onset, hole: hole)
            let previous = try XCTUnwrap(before.map { $0.date() }.max())
            XCTAssertEqual(onset.timeIntervalSince(previous), hole, accuracy: 1,
                           "precondition: the same hole for both tails")
            XCTAssertEqual(BulkSleep.onsetIsUnobserved(DateInterval(start: onset, end: end),
                                                       in: before),
                           holeIsEnough,
                           "\(hours) h tail claims \(7 - hours) h is missing; ~3 h is available")
        }
    }

    /// The comparison is strictly `>`, not `>=`. That matters at the OTHER end of the scale: review
    /// measured two REAL 450 s gaps on a worn ring (08-01 18:26:33 → 18:34:03 and 08-02 06:31:48 →
    /// 06:39:18), exactly `onsetContiguityGap`, so a `>=` would treat ordinary worn-ring jitter as
    /// missing data. Pin both sides of the boundary.
    func testRequiredHoleIsStrictlyGreaterThanTheClaim() throws {
        let end = try date("2026-08-02T11:21:00Z")
        let onset = end.addingTimeInterval(-4 * 3600)          // claims exactly 3 h is missing
        for (hole, expected) in [(3 * 3600.0, false),
                                 (3 * 3600.0 + Double(BulkRecord.epochSeconds), true)] {
            let before = run(onset.addingTimeInterval(-27 * 3600), endingBefore: onset, hole: hole)
            XCTAssertEqual(BulkSleep.onsetIsUnobserved(DateInterval(start: onset, end: end),
                                                       in: before),
                           expected,
                           "a hole of exactly the claim is NOT enough; one epoch more is")
        }
    }

    /// A record run from `start` whose LAST epoch sits exactly `hole` seconds before `onset`.
    private func run(_ start: Date, endingBefore onset: Date, hole: TimeInterval) -> [BulkRecord] {
        let last = onset.addingTimeInterval(-hole)
        let n = Int(last.timeIntervalSince(start)) / BulkRecord.epochSeconds + 1
        return records(from: last.addingTimeInterval(-Double((n - 1) * BulkRecord.epochSeconds)),
                       count: max(1, n))
    }

    /// The constants are load-bearing; assert them so a change is a deliberate, test-visible act.
    func testConstants() {
        XCTAssertEqual(SleepWindow.presumedTruncatedNightSpan, 7 * 3600)
        XCTAssertEqual(BulkSleep.onsetContiguityGap, 450)
    }

    // MARK: - 3. THE CALL SITE — BulkSleep.latestNightRecords
    //
    // ⚠️ All four majors of the previous revision were call-site defects that the isolated tests
    // above could not see. These are the tests that matter.
    //
    // `latestNightRecords` reads `Calendar.current` (there is no calendar to inject), so the fixtures
    // are built from `Calendar.current` too — that makes the LOCAL WALL CLOCK exact in every CI
    // timezone, which is precisely what the gate reads. `date(bySettingHour:...)` is used rather than
    // hour arithmetic so a DST transition cannot shift the constructed wall clock.

    private var localCalendar: Calendar { .current }

    /// Local wall clock `hour:minute`, `dayOffset` days from a fixed reference day.
    private func local(_ dayOffset: Int, _ hour: Int, _ minute: Int = 0) throws -> Date {
        let cal = localCalendar
        let reference = Date(timeIntervalSince1970: 1_780_000_000)
        let day = try XCTUnwrap(cal.date(byAdding: .day, value: dayOffset,
                                         to: cal.startOfDay(for: reference)))
        let t = try XCTUnwrap(cal.date(bySettingHour: hour, minute: minute, second: 0, of: day))
        XCTAssertEqual(cal.component(.hour, from: t), hour, "fixture wall clock must be exact")
        return t
    }

    /// Still (asleep-looking) epochs spanning `from` → `to` at the 150 s cadence.
    private func still(_ from: Date, _ to: Date) -> [BulkRecord] {
        let n = Int(to.timeIntervalSince(from)) / BulkRecord.epochSeconds
        return records(from: from, count: max(0, n))
    }

    /// Moving (awake) epochs spanning `from` → `to`. See `awakeRecords` for why these cannot be flat.
    private func moving(_ from: Date, _ to: Date) -> [BulkRecord] {
        let n = Int(to.timeIntervalSince(from)) / BulkRecord.epochSeconds
        return awakeRecords(from: from, count: max(0, n))
    }

    /// The fixture itself is load-bearing, so pin it: `moving` must detect as ACTIVE and `still` as
    /// SLEEP. Without this, a fixture regression turns the call-site tests below into tautologies.
    ///
    /// ⚠️ Assert on `ActivityPeriod.detectFromMotion` DIRECTLY, never through `latestNightRecords`.
    /// A first attempt at this test went through `latestNightRecords` and was VACUOUS — measured: it
    /// passed unchanged when `moving` was replaced by the discredited flat-`20` fixture, because a
    /// flat 04:00→09:00 run does become a sleep block but its 06:30 midpoint is accepted by the plain
    /// rule, so the scoped record count is the input either way. The detector output is the only
    /// signal that discriminates the two fixtures (measured: `.active` vs `.sleep`).
    func testFixturesProduceTheMotionTheyClaim() throws {
        func periods(_ r: [BulkRecord]) -> [ActivityPeriod] {
            ActivityPeriod.detectFromMotion(BulkSleep.motionTimeline(from: r),
                                            temperatureSamples: [],
                                            heartRateSamples: BulkSleep.heartRateTimeline(from: r),
                                            sleepVitalTimes: BulkSleep.sleepVitalTimeline(from: r))
        }
        let awake = periods(moving(try local(0, 4), try local(0, 9)))
        XCTAssertFalse(awake.isEmpty, "the awake fixture must produce periods at all")
        XCTAssertTrue(awake.allSatisfy { $0.activity != .sleep },
                      "awake fixtures must NOT detect as sleep — got \(awake.map(\.activity))")
        let asleep = periods(still(try local(-1, 23), try local(0, 6)))
        XCTAssertTrue(asleep.contains { $0.activity == .sleep },
                      "still fixtures must detect as sleep — got \(asleep.map(\.activity))")
        // The trap itself, pinned: a CONSTANT high motion value detects as SLEEP, not active. This
        // assertion is what proves the two above are not vacuous — it fails the moment `awakeRecords`
        // regresses to a flat shape, because then all three fixtures would agree.
        let flat = records(from: try local(0, 4), count: 120) { _ in [UInt8](repeating: 20, count: 5) }
        XCTAssertTrue(periods(flat).contains { $0.activity == .sleep },
                      "a flat motion plateau reads STILL after de-flooring — this is the trap")
    }

    /// 1. THE MOTIVATING BUG. Yesterday's epochs, a multi-hour hole, then a 2 h tail ending late
    /// morning. HEAD found no overnight block at all and fell through to "return the input unchanged",
    /// so the caller staged the whole archive and the Sleep card came up blank. The correction must
    /// recover the night AND scope to it.
    func testCallSiteRecoversATruncatedTail() throws {
        let yesterdayStart = try local(-1, 8)
        let yesterdayEnd = try local(-1, 18)
        let onset = try local(0, 9, 21)
        let wake = try local(0, 11, 21)
        let tailRecords = still(onset, wake)
        let union = moving(yesterdayStart, yesterdayEnd) + tailRecords

        let scoped = BulkSleep.latestNightRecords(from: union)

        XCTAssertLessThan(scoped.count, union.count,
                          "a night was found, so the input is scoped — not returned wholesale")
        XCTAssertEqual(scoped, tailRecords,
                       "exactly the truncated night is returned; yesterday is excluded")
    }

    /// 2. ⚠️ MONOTONICITY AT THE CALL SITE — the anchor-eviction and `maxNightSpan`-clipping majors.
    /// A REAL fully-observed night (21:00 → 05:00) PLUS a morning block (10:20 → 12:20) that WOULD
    /// qualify for the correction on its own (5 h 20 m hole ≥ the 5 h a 2 h block must show). The
    /// two-pass filter must never consult the correction here, so the result is byte-identical to
    /// HEAD's: the night, whole, with the morning block excluded.
    ///
    /// Under the single-filter form the morning block became the anchor and
    /// `clusterStart = max(clusterStart, anchor.end - maxNightSpan)` moved the 14 h floor from 15:00
    /// (D-1) to 22:20, so `lo` = 21:50 and the 21:00–21:50 HEAD of the real night was silently lost.
    func testCallSiteIsUnchangedWhenARealNightExists() throws {
        let nightStart = try local(-1, 21)
        let nightEnd = try local(0, 5)
        let morningStart = try local(0, 10, 20)
        let morningEnd = try local(0, 12, 20)
        let nightRecords = still(nightStart, nightEnd)
        let morningRecords = still(morningStart, morningEnd)
        let union = nightRecords + morningRecords

        // Precondition: the morning block WOULD pass the correction if it were ever consulted.
        XCTAssertTrue(BulkSleep.onsetIsUnobserved(DateInterval(start: morningStart, end: morningEnd),
                                                  in: union),
                      "precondition: a 5 h 20 m hole clears the 5 h a 2 h block must show")

        let scoped = BulkSleep.latestNightRecords(from: union)

        XCTAssertEqual(scoped, nightRecords,
                       "the real night is returned WHOLE and the morning block is excluded")
        // The head of the night specifically — this is what the anchor shift used to clip.
        let earliest = try XCTUnwrap(scoped.map { $0.date() }.min())
        XCTAssertEqual(earliest, nightStart, "the 21:00 head must not be clipped")
    }

    /// 3. A block behind only a SHORT hole (600 s) must NOT fire the correction. The archive plainly
    /// contains the hours the presumption would claim are missing.
    func testCallSiteDoesNotFireBehindAShortHole() throws {
        let morningEnd = try local(0, 12, 20)
        let morningStart = try local(0, 10, 20)
        let priorEnd = morningStart.addingTimeInterval(-600)
        let prior = moving(try local(0, 4), priorEnd)
        let block = still(morningStart, morningEnd)
        let union = prior + block

        XCTAssertFalse(BulkSleep.onsetIsUnobserved(DateInterval(start: morningStart, end: morningEnd),
                                                   in: union),
                       "precondition: only 600 s is missing, 5 h is claimed")

        let scoped = BulkSleep.latestNightRecords(from: union)
        XCTAssertEqual(scoped, union.sorted { $0.counter < $1.counter },
                       "no overnight block → HEAD's fallback: the input, unchanged")
    }

    /// 4. The SAME archive as test 1 but with CONTIGUOUS pre-onset records: the onset is in the data,
    /// so nothing is presumed and the result is HEAD's — the input returned unchanged.
    func testCallSiteIsUnchangedWhenPreOnsetRecordsAreContiguous() throws {
        let onset = try local(0, 9, 21)
        let wake = try local(0, 11, 21)
        // Awake, moving epochs running straight into the onset — no hole.
        let before = moving(try local(0, 4), onset)
        let union = before + still(onset, wake)

        XCTAssertFalse(BulkSleep.onsetIsUnobserved(DateInterval(start: onset, end: wake), in: union),
                       "precondition: recording runs into the onset")

        let scoped = BulkSleep.latestNightRecords(from: union)
        XCTAssertEqual(scoped, union.sorted { $0.counter < $1.counter },
                       "no overnight block → HEAD's fallback: the input, unchanged")
    }
}

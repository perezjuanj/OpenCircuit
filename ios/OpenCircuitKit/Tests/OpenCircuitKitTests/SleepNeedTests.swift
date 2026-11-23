import XCTest
@testable import OpenCircuitKit

// Sleep need, debt and bedtime (#382, decision 92i). Every fixture is synthetic and wholly in the
// past; the calendar and time zone are fixed and passed in, and nothing here reads the clock.
//
// Fixture week: Mon 2025-01-06 is day 0. Day 5 (Sat) and day 6 (Sun) are weekend days. A "night on
// day D" ends on day D at 07:00 local and began on day D-1 at 23:00.

final class SleepNeedTests: XCTestCase {

    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()

    private let workday = 420
    private let weekend = 480

    /// Local time on fixture day `day` (0 = Mon 2025-01-06), at hour:minute.
    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        var c = DateComponents()
        c.year = 2025; c.month = 1; c.day = 6 + day; c.hour = hour; c.minute = minute
        return cal.date(from: c)!
    }

    /// A night ending on `day`: in bed 23:00 the evening before, up at 07:00.
    private func night(_ day: Int, asleep: Int, onsetAfterMin: Int? = nil) -> SleepNeed.Night {
        let bed = at(day - 1, 23)
        return SleepNeed.Night(wake: at(day, 7), inBedStart: bed,
                               sleepOnset: onsetAfterMin.map { bed.addingTimeInterval(Double($0) * 60) },
                               asleepMin: asleep)
    }

    private func run(_ nights: [SleepNeed.Night], naps: [SleepNeed.Nap] = [], now: Date? = nil,
                     nextWake: Date? = nil, workdayGoal: Int? = nil, weekendGoal: Int? = nil)
        -> SleepNeed.Result {
        let lastWake = nights.map(\.wake).max() ?? at(0, 7)
        return SleepNeed.compute(.init(
            nights: nights, naps: naps, now: now ?? lastWake.addingTimeInterval(10 * 3600),
            workdayGoalMin: workdayGoal ?? workday, weekendGoalMin: weekendGoal ?? weekend,
            nextWake: nextWake, calendar: cal))
    }

    // MARK: Debt

    func testThreeShortWeekdayNightsCarryForward() {
        // Tue, Wed, Thu, each 60 short of 420: 33 -> 51.15 -> 61.13 (rounded 61).
        let r = run([night(1, asleep: 360), night(2, asleep: 360), night(3, asleep: 360)],
                    nextWake: at(4, 7))
        XCTAssertTrue(r.hasEnoughNights)
        XCTAssertEqual(r.nightsUsed, 3)
        XCTAssertEqual(r.debtMin, 61)
        XCTAssertEqual(r.goalMin, 420)                    // tonight ends on Friday
        XCTAssertEqual(r.needMin, 481)
    }

    func testFewerThanThreeKnownNightsShowNoDebt() {
        let two = run([night(1, asleep: 200), night(2, asleep: 200)], nextWake: at(3, 7))
        XCTAssertFalse(two.hasEnoughNights)
        XCTAssertEqual(two.debtMin, 0)
        XCTAssertEqual(two.nightsUsed, 0)
        XCTAssertEqual(two.knownNights, 2)
        XCTAssertEqual(two.needMin, 420)

        let three = run([night(1, asleep: 200), night(2, asleep: 200), night(3, asleep: 200)],
                        nextWake: at(4, 7))
        XCTAssertTrue(three.hasEnoughNights)
        XCTAssertGreaterThan(three.debtMin, 0)
    }

    func testAMissingNightIsSkippedNotZeroFilled() {
        // Nights on days 1, 3 and 4 only: day 2 has no row at all.
        let gap = run([night(1, asleep: 360), night(3, asleep: 360), night(4, asleep: 360)],
                      nextWake: at(5, 7))
        XCTAssertEqual(gap.knownNights, 3)
        XCTAssertEqual(gap.debtMin, 61)                   // the same three-night recurrence
    }

    func testAZeroMinuteRowIsUnknownLikeAMissingNight() {
        let withZeroRow = run([night(1, asleep: 360), night(2, asleep: 0), night(3, asleep: 360),
                               night(4, asleep: 360)], nextWake: at(5, 7))
        let withoutRow = run([night(1, asleep: 360), night(3, asleep: 360), night(4, asleep: 360)],
                             nextWake: at(5, 7))
        XCTAssertEqual(withZeroRow.knownNights, 3)
        XCTAssertEqual(withZeroRow.debtMin, withoutRow.debtMin)
        XCTAssertEqual(withZeroRow.debtMin, 61)
    }

    func testAnUnknownNightDoesNotCountTowardTheThreeNightMinimum() {
        let r = run([night(1, asleep: 360), night(2, asleep: 0), night(3, asleep: 360)], nextWake: at(4, 7))
        XCTAssertFalse(r.hasEnoughNights)
        XCTAssertEqual(r.debtMin, 0)
    }

    func testAnUnknownNightsNapsAreNotCredited() {
        // Day 2 is unknown, but a 90 min nap that day must not leak into any other night's credit.
        let naps = [SleepNeed.Nap(start: at(2, 14), asleepMin: 90)]
        let with = run([night(1, asleep: 360), night(2, asleep: 0), night(3, asleep: 360), night(4, asleep: 360)],
                       naps: naps, nextWake: at(5, 7))
        let without = run([night(1, asleep: 360), night(2, asleep: 0), night(3, asleep: 360), night(4, asleep: 360)],
                          nextWake: at(5, 7))
        // The nap starts after day 2's wake and before day 3's bed, so it belongs to day 2 (skipped).
        XCTAssertEqual(with.debtMin, without.debtMin)
    }

    func testOversleepingPaysDownToZeroAndNeverBelow() {
        // Short, then two long nights, then short again. The surplus must not be banked: the last short
        // night starts from 0, so the debt is the one-night value, not less.
        let r = run([night(1, asleep: 360), night(2, asleep: 600), night(3, asleep: 600), night(4, asleep: 360)],
                    nextWake: at(5, 7))
        XCTAssertEqual(r.debtMin, 33)                     // 0.55 * (420 - 360)
        let long = run([night(1, asleep: 600), night(2, asleep: 600), night(3, asleep: 600)], nextWake: at(4, 7))
        XCTAssertEqual(long.debtMin, 0)
        XCTAssertEqual(long.needMin, 420)                 // goal, not below it for a surplus
    }

    func testOversleepingPaysDownExistingDebtToZero() {
        // 33 min debt, then a night 27 min over (goal + debt = 453, asleep 480): clears to 0.
        let r = run([night(1, asleep: 360), night(2, asleep: 360), night(3, asleep: 600)], nextWake: at(4, 7))
        XCTAssertEqual(r.debtMin, 0)
    }

    func testTenMinuteFloorClearsJustUnder() {
        // The first two nights meet the goal; the third is 18 short: 0.55 * 18 = 9.9 -> cleared.
        let under = run([night(1, asleep: 420), night(2, asleep: 420), night(3, asleep: 402)], nextWake: at(4, 7))
        XCTAssertEqual(under.debtMin, 0)
        // 19 short: 10.45 -> kept (shown as 10).
        let over = run([night(1, asleep: 420), night(2, asleep: 420), night(3, asleep: 401)], nextWake: at(4, 7))
        XCTAssertEqual(over.debtMin, 10)
    }

    func testTheFloorClearsMidRecurrenceNotOnlyAtTheEnd() {
        // Night 3: 18 short -> 9.9 -> cleared to 0. Night 4: 10 short -> 0.55 * 10 = 5.5 -> cleared.
        // Without the mid-run clear it would carry 9.9 and end at 0.55 * (10 + 9.9) = 10.9 -> 11.
        let r = run([night(1, asleep: 420), night(2, asleep: 420), night(3, asleep: 402), night(4, asleep: 410)],
                    nextWake: at(5, 7))
        XCTAssertEqual(r.debtMin, 0)
    }

    func testDebtIsNotCapped() {
        // Steady state of a 300 min shortfall every night is 0.55 * (300 + d) = d, about 367 min. It is
        // shown whole; only need is bounded.
        let nights = (1...14).map { night($0, asleep: 120) }
        let r = run(nights, nextWake: at(15, 7), weekendGoal: 420)
        XCTAssertEqual(r.debtMin, 367)
    }

    // MARK: Window

    /// Fifteen known nights with unknown rows and missing days between them; the oldest has an enormous
    /// deficit that only matters if it is inside the window.
    private func gappedNights(knownCount: Int) -> [SleepNeed.Night] {
        var rows: [SleepNeed.Night] = []
        var day = 1
        for i in 0..<knownCount {
            rows.append(night(day, asleep: 120))
            day += 1
            if i % 2 == 0 { rows.append(night(day, asleep: 0)); day += 1 }   // an unknown row
            else { day += 1 }                                                 // no row at all
        }
        return rows
    }

    func testTheWindowIsFourteenKnownNightsEvenWithGapsBetweenThem() {
        let fifteen = run(gappedNights(knownCount: 15), nextWake: at(60, 7), weekendGoal: 420)
        XCTAssertEqual(fifteen.knownNights, 15)
        XCTAssertEqual(fifteen.nightsUsed, 14)
        let fourteen = run(gappedNights(knownCount: 14), nextWake: at(60, 7), weekendGoal: 420)
        XCTAssertEqual(fourteen.nightsUsed, 14)
        // The 14 known nights reach back over about 28 calendar days. Counting calendar nights or rows
        // would see only about 7 of them, and a debt of 361 rather than 367.
        XCTAssertEqual(fifteen.debtMin, 367)
        XCTAssertEqual(fourteen.debtMin, 367)
        let thirteen = run(gappedNights(knownCount: 13), nextWake: at(60, 7), weekendGoal: 420)
        XCTAssertEqual(thirteen.nightsUsed, 13)
    }

    func testTheOldestKnownNightsBeyondTheWindowAreIgnored() {
        // A 15th (oldest) night with a huge deficit changes nothing once 14 newer known nights exist.
        let newer = (2...15).map { night($0, asleep: 420) }
        let withOld = run([night(1, asleep: 1)] + newer, nextWake: at(16, 7))
        let without = run(newer, nextWake: at(16, 7))
        XCTAssertEqual(withOld.debtMin, without.debtMin)
        XCTAssertEqual(withOld.nightsUsed, 14)
        // At 14 known nights that same oldest night is inside the window and counts.
        let inside = run([night(1, asleep: 1)] + newer.dropLast(), nextWake: at(15, 7))
        XCTAssertEqual(inside.nightsUsed, 14)
    }

    func testTheGoalForEachNightIsTheWeekdayOrWeekendGoalOfTheDayItEnds() {
        // Nights ending Fri (420), Sat (480), Sun (480), asleep 420 each. Fri: 0. Sat: 0.55 * 60 = 33.
        // Sun: 0.55 * (480 + 33 - 420) = 51.15. If every night used the weekday goal the debt would be 0.
        let r = run([night(4, asleep: 420), night(5, asleep: 420), night(6, asleep: 420)], nextWake: at(7, 7))
        XCTAssertEqual(r.debtMin, 51)
        XCTAssertEqual(r.goalMin, 420)                    // tonight ends on Monday
    }

    func testTonightsGoalIsTheGoalOfTheDayTheNightEnds() {
        let nights = [night(3, asleep: 420), night(4, asleep: 420), night(5, asleep: 480)]
        // Woken Sat 07:00; now Sat afternoon; tonight ends Sunday -> weekend goal.
        XCTAssertEqual(run(nights, nextWake: at(6, 7)).goalMin, 480)
        // Friday evening: the night ends Saturday -> weekend goal.
        let fri = run([night(1, asleep: 420), night(2, asleep: 420), night(3, asleep: 420)],
                      now: at(4, 19), nextWake: at(5, 7))
        XCTAssertEqual(fri.goalMin, 480)
        // Sunday evening: the night ends Monday -> weekday goal.
        let sun = run([night(4, asleep: 420), night(5, asleep: 420), night(6, asleep: 420)],
                      now: at(6, 20), nextWake: at(7, 7))
        XCTAssertEqual(sun.goalMin, 420)
        // No wake time: the day after `now` decides. Friday evening -> Saturday.
        XCTAssertEqual(run([night(1, asleep: 420), night(2, asleep: 420), night(3, asleep: 420)],
                           now: at(4, 19), nextWake: nil).goalMin, 480)
    }

    // MARK: Naps credited to their night

    func testANapOnADayIsCreditedToTheNightThatEndedThatMorning() {
        // Night 2 is 120 short, but a 120 min nap that afternoon makes up for it.
        let nap = SleepNeed.Nap(start: at(2, 14), asleepMin: 120)
        let withNap = run([night(1, asleep: 420), night(2, asleep: 300), night(3, asleep: 420)],
                          naps: [nap], nextWake: at(4, 7))
        XCTAssertEqual(withNap.debtMin, 0)
        let without = run([night(1, asleep: 420), night(2, asleep: 300), night(3, asleep: 420)],
                          nextWake: at(4, 7))
        XCTAssertEqual(without.debtMin, Int((0.55 * 0.55 * 120).rounded()))   // 36 after one more night
    }

    func testNapCreditBoundariesAreExclusive() {
        let nights = [night(1, asleep: 420), night(2, asleep: 300), night(3, asleep: 420)]
        func debt(napStart: Date) -> Int {
            run(nights, naps: [.init(start: napStart, asleepMin: 120)], nextWake: at(4, 7)).debtMin
        }
        // Night 2 wakes 07:00 on day 2; night 3 goes to bed 23:00 on day 2.
        XCTAssertEqual(debt(napStart: at(2, 7, 1)), 0)                 // just after the wake: credited
        XCTAssertNotEqual(debt(napStart: at(2, 7)), 0)                 // exactly at the wake: not
        XCTAssertEqual(debt(napStart: at(2, 22, 59)), 0)               // just before the next bed: credited
        XCTAssertNotEqual(debt(napStart: at(2, 23)), 0)                // exactly at the next bed: not
    }

    func testTheMostRecentNightsFollowingNapsAreTonightsNotItsCredit() {
        // Naps after the last night's wake lower need; they are not also credited to that night.
        let nights = [night(1, asleep: 360), night(2, asleep: 360), night(3, asleep: 360)]
        let nap = SleepNeed.Nap(start: at(3, 13), asleepMin: 60)
        let with = run(nights, naps: [nap], nextWake: at(4, 7))
        let without = run(nights, nextWake: at(4, 7))
        XCTAssertEqual(with.debtMin, without.debtMin)
        XCTAssertEqual(with.napMin, 60)
        XCTAssertEqual(with.needMin, without.needMin - 60)
    }

    // MARK: Need, today's naps and the clamp

    func testTodaysNapsAreThoseAfterTheLastWakeAndBeforeNow() {
        let nights = [night(1, asleep: 420), night(2, asleep: 420), night(3, asleep: 420)]
        let now = at(3, 17)
        func nap(_ start: Date) -> Int {
            run(nights, naps: [.init(start: start, asleepMin: 40)], now: now, nextWake: at(4, 7)).napMin
        }
        XCTAssertEqual(nap(at(3, 7, 1)), 40)
        XCTAssertEqual(nap(at(3, 7)), 0)                  // starts exactly at the last wake: not today's
        XCTAssertEqual(nap(at(3, 16, 59)), 40)
        XCTAssertEqual(nap(at(3, 17)), 0)                 // starts exactly now: not yet
        XCTAssertEqual(nap(at(2, 15)), 0)                 // yesterday's nap (credited to its own night)
    }

    func testWithNoStoredNightTodayMeansAfterLocalMidnight() {
        let now = at(2, 15)
        func nap(_ start: Date) -> Int {
            SleepNeed.compute(.init(nights: [], naps: [.init(start: start, asleepMin: 25)], now: now,
                                    workdayGoalMin: workday, weekendGoalMin: weekend,
                                    nextWake: at(3, 7), calendar: cal)).napMin
        }
        XCTAssertEqual(nap(at(2, 0, 1)), 25)
        XCTAssertEqual(nap(at(2, 0)), 0)
        XCTAssertEqual(nap(at(1, 23, 59)), 0)
    }

    func testNeedIsGoalPlusDebtMinusNaps() {
        let nights = [night(1, asleep: 360), night(2, asleep: 360), night(3, asleep: 360)]
        let r = run(nights, naps: [.init(start: at(3, 13), asleepMin: 45)], nextWake: at(4, 7))
        XCTAssertEqual(r.unclampedNeedMin, 420 + 61 - 45)
        XCTAssertEqual(r.needMin, 436)
    }

    func testNeedFloorIsSixtyMinutesBelowTheGoal() {
        let nights = [night(1, asleep: 420), night(2, asleep: 420), night(3, asleep: 420)]
        func need(nap: Int) -> SleepNeed.Result {
            run(nights, naps: [.init(start: at(3, 13), asleepMin: nap)], nextWake: at(4, 7))
        }
        XCTAssertEqual(need(nap: 60).needMin, 360)        // exactly the floor
        XCTAssertEqual(need(nap: 59).needMin, 361)
        XCTAssertEqual(need(nap: 61).needMin, 360)        // clamped
        XCTAssertEqual(need(nap: 61).unclampedNeedMin, 359)
        XCTAssertEqual(need(nap: 300).needMin, 360)
    }

    func testNeedCeilingIsTwoHoursAboveTheGoal() {
        // 14 nights short by 300: debt 367, so the uncapped need is 787 and the ceiling holds it at 540.
        let hard = (1...14).map { night($0, asleep: 120) }
        let r = run(hard, nextWake: at(15, 7), weekendGoal: 420)
        XCTAssertEqual(r.unclampedNeedMin, r.goalMin + 367)
        XCTAssertEqual(r.needMin, r.goalMin + 120)
        // Either side of the ceiling: search the three-night shortfalls for the one whose uncapped need
        // lands exactly on goal + 120, and check that it and the next one up both stop there.
        var found = false
        for asleep in stride(from: 420, through: 0, by: -1) {
            let s = run([night(1, asleep: asleep), night(2, asleep: asleep), night(3, asleep: asleep)],
                        nextWake: at(4, 7))
            if s.unclampedNeedMin == s.goalMin + 120 {
                XCTAssertEqual(s.needMin, s.goalMin + 120)
                found = true
            }
            if s.unclampedNeedMin == s.goalMin + 121 {
                XCTAssertEqual(s.needMin, s.goalMin + 120)
            }
        }
        XCTAssertTrue(found)
    }

    func testNoEnoughNightsStillGivesNeedFromTheGoal() {
        let r = run([night(1, asleep: 100)], naps: [.init(start: at(1, 13), asleepMin: 30)], nextWake: at(2, 7))
        XCTAssertFalse(r.hasEnoughNights)
        XCTAssertEqual(r.needMin, 390)
    }

    // MARK: Onset latency

    private func latencyNights(_ minutes: [Int?]) -> [SleepNeed.Night] {
        minutes.enumerated().map { night($0.offset + 1, asleep: 420, onsetAfterMin: $0.element) }
    }

    func testLatencyDefaultsToFifteenWithFewerThanThreeRecordedNights() {
        let two = run(latencyNights([40, 40, nil, nil]), nextWake: at(5, 7))
        XCTAssertEqual(two.latencyMin, 15)
        XCTAssertTrue(two.latencyIsDefault)
        let three = run(latencyNights([40, 40, 40, nil]), nextWake: at(5, 7))
        XCTAssertEqual(three.latencyMin, 40)
        XCTAssertFalse(three.latencyIsDefault)
    }

    func testLatencyIsTheMedianAndAnEvenCountAveragesTheMiddlePair() {
        XCTAssertEqual(run(latencyNights([5, 50, 20]), nextWake: at(4, 7)).latencyMin, 20)
        XCTAssertEqual(run(latencyNights([10, 20, 30, 50]), nextWake: at(5, 7)).latencyMin, 25)
        XCTAssertEqual(run(latencyNights([10, 21, 30, 50]), nextWake: at(5, 7)).latencyMin, 26)   // 25.5 rounds up
    }

    func testLatencyIsClampedToZeroToSixtyMinutes() {
        XCTAssertEqual(run(latencyNights([90, 120, 75, 200]), nextWake: at(5, 7)).latencyMin, 60)
        XCTAssertEqual(run(latencyNights([60, 60, 60]), nextWake: at(4, 7)).latencyMin, 60)
        XCTAssertEqual(run(latencyNights([61, 61, 61]), nextWake: at(4, 7)).latencyMin, 60)
        XCTAssertEqual(run(latencyNights([0, 0, 0]), nextWake: at(4, 7)).latencyMin, 0)
    }

    func testLatencyIgnoresAnOnsetBeforeBedtimeAndUsesOnlyTheLatestFourteenNights() {
        // A night whose onset precedes its in-bed start is not a usable pair.
        var rows = latencyNights([30, 30, 30])
        rows[2].sleepOnset = rows[2].inBedStart.addingTimeInterval(-600)
        XCTAssertTrue(run(rows, nextWake: at(4, 7)).latencyIsDefault)         // only two usable pairs
        // 14 recent nights at 10 min, older ones at 60 min: the older ones fall outside the window.
        let older = (1...6).map { night($0, asleep: 420, onsetAfterMin: 60) }
        let recent = (7...20).map { night($0, asleep: 420, onsetAfterMin: 10) }
        XCTAssertEqual(run(older + recent, nextWake: at(21, 7)).latencyMin, 10)
    }

    // MARK: Bedtime

    func testNoWakeTimeMeansNoBedtimeButNeedAndDebtStay() {
        let r = run([night(1, asleep: 360), night(2, asleep: 360), night(3, asleep: 360)], nextWake: nil)
        XCTAssertNil(r.bedtime)
        XCTAssertNil(r.nextWake)
        XCTAssertEqual(r.debtMin, 61)
        XCTAssertEqual(r.needMin, 481)
    }

    func testBedtimeIsWakeMinusNeedMinusLatencyAndCanCrossMidnight() {
        // Need 420 (no debt) + 15 default latency before a 06:00 wake: 22:45 the evening before.
        let wake = at(4, 6)
        let r = run([night(1, asleep: 420), night(2, asleep: 420), night(3, asleep: 420)], nextWake: wake)
        XCTAssertEqual(r.bedtime, wake.addingTimeInterval(-435 * 60))
        XCTAssertEqual(cal.dateComponents([.day, .hour, .minute], from: r.bedtime!),
                       DateComponents(day: 9, hour: 22, minute: 45))
        // A 00:30 bedtime stays on the wake's own date.
        let early = at(4, 6, 30)
        let late = run([night(1, asleep: 420), night(2, asleep: 420), night(3, asleep: 420)],
                       naps: [.init(start: at(3, 13), asleepMin: 0)], nextWake: early,
                       workdayGoal: 300)
        XCTAssertEqual(cal.component(.hour, from: late.bedtime!), 1)           // 6:30 - 300 - 15 = 01:15
        XCTAssertEqual(cal.component(.day, from: late.bedtime!), 10)
    }

    func testBedtimeUsesTheClampedNeed() {
        let nights = (1...14).map { night($0, asleep: 120) }
        let wake = at(15, 7)
        let r = run(nights, nextWake: wake, weekendGoal: 420)
        XCTAssertEqual(r.bedtime, wake.addingTimeInterval(-Double(r.goalMin + 120 + 15) * 60))
    }

    // MARK: Daylight saving

    func testBedtimeAcrossTheSpringForwardNightIsElapsedTime() {
        // Sun 2025-03-09: clocks go 02:00 -> 03:00 in New York. Waking 07:00 after 8 h 30 m of need and
        // latency means bed at 21:30 on the Saturday wall clock, not 22:30: an hour is skipped overnight.
        var c = DateComponents(); c.year = 2025; c.month = 3; c.day = 9; c.hour = 7
        let wake = cal.date(from: c)!
        func nightEnding(_ d: Int) -> SleepNeed.Night {
            var w = DateComponents(); w.year = 2025; w.month = 3; w.day = d; w.hour = 7
            var s = DateComponents(); s.year = 2025; s.month = 3; s.day = d - 1; s.hour = 23
            return .init(wake: cal.date(from: w)!, inBedStart: cal.date(from: s)!, asleepMin: 420)
        }
        let r = SleepNeed.compute(.init(
            nights: [nightEnding(5), nightEnding(6), nightEnding(7)], naps: [],
            now: cal.date(from: { var n = DateComponents(); n.year = 2025; n.month = 3; n.day = 7; n.hour = 18; return n }())!,
            workdayGoalMin: 420, weekendGoalMin: 495, nextWake: wake, calendar: cal))
        XCTAssertEqual(r.goalMin, 495)                    // the night ends Sunday: weekend goal
        XCTAssertEqual(r.bedtime, wake.addingTimeInterval(-Double(495 + 15) * 60))
        let parts = cal.dateComponents([.day, .hour, .minute], from: r.bedtime!)
        XCTAssertEqual(parts.day, 8)
        XCTAssertEqual(parts.hour, 21)
        XCTAssertEqual(parts.minute, 30)
    }

    func testANightSpanningTheSpringForwardKeepsItsRecordedMinutes() {
        // Saturday night into Sunday 2025-03-09: the row's asleep minutes are what was stored (the
        // short wall-clock night is not re-derived from the times), and Sunday takes the weekend goal.
        func d(_ day: Int, _ h: Int) -> Date {
            var c = DateComponents(); c.year = 2025; c.month = 3; c.day = day; c.hour = h
            return cal.date(from: c)!
        }
        let dst = SleepNeed.Night(wake: d(9, 8), inBedStart: d(8, 23), asleepMin: 480)
        let r = SleepNeed.compute(.init(
            nights: [.init(wake: d(7, 7), inBedStart: d(6, 23), asleepMin: 420),
                     .init(wake: d(8, 7), inBedStart: d(7, 23), asleepMin: 480), dst],
            naps: [], now: d(9, 12), workdayGoalMin: 420, weekendGoalMin: 480, nextWake: d(10, 7), calendar: cal))
        XCTAssertEqual(r.debtMin, 0)                      // Sat 480 vs 480 and Sun 480 vs 480
        XCTAssertEqual(r.goalMin, 420)                    // tonight ends Monday
    }

    func testNextOccurrenceOfAClockTimeIsTheNextWallClockTimeAcrossDST() {
        // 06:30 wake, asked on Saturday 2025-03-08 noon: Sunday 06:30 EDT is 18 h 30 m of wall clock
        // away but only 17 h 30 m elapsed, because the clocks skip an hour. The calendar decides, not +24 h.
        func d(_ day: Int, _ h: Int, _ m: Int = 0) -> Date {
            var c = DateComponents(); c.year = 2025; c.month = 3; c.day = day; c.hour = h; c.minute = m
            return cal.date(from: c)!
        }
        let ref = d(1, 6, 30)
        let next = SleepNeed.nextOccurrence(clockTimeOf: ref, after: d(8, 12), calendar: cal)
        XCTAssertEqual(next, d(9, 6, 30))
        XCTAssertEqual(next!.timeIntervalSince(d(8, 12)), 17.5 * 3600)
        // Before the clock time on the same day: today.
        XCTAssertEqual(SleepNeed.nextOccurrence(clockTimeOf: ref, after: d(8, 5), calendar: cal), d(8, 6, 30))
        // Exactly at it: the next one, never now.
        XCTAssertEqual(SleepNeed.nextOccurrence(clockTimeOf: ref, after: d(8, 6, 30), calendar: cal), d(9, 6, 30))
    }
}

import Testing
import Foundation
@testable import OpenCircuitKit

/// The alarm's scheduling rules. Everything here is pure calendar arithmetic against a FIXED
/// calendar and explicit dates — no clock, no BLE — so a failure means the rule is wrong rather
/// than the environment being odd.
struct RingAlarmTests {

    /// UTC, Gregorian. Pinned so a machine in a different zone can't change what these tests mean.
    private static func calendar(_ identifier: String = "UTC") -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: identifier)!
        return c
    }

    private static func date(_ y: Int, _ m: Int, _ d: Int, _ hh: Int, _ mm: Int,
                             calendar: Calendar = calendar()) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: hh, minute: mm))!
    }

    // MARK: - Command bytes

    @Test func vibrateFrameMatchesTheConfirmedCapture() {
        // The exact frames the tester's Gen 3 buzzed on, 12/12. If this ever changes, the change
        // is wrong until a new capture says otherwise.
        #expect(Command.vibrate(.notification) == [0x0B, 0x03, 0x01, 0x64, 0x00])
        #expect(Command.vibrate(.long) == [0x0B, 0x03, 0x02, 0x64, 0x00])
    }

    @Test func onlyGen3ExposesTheMotor() {
        #expect(RingVibration.isSupported(.gen3))
        #expect(!RingVibration.isSupported(.gen2))
        #expect(!RingVibration.isSupported(.gen2Air))
        #expect(!RingVibration.isSupported(.gen1))
        // Fails CLOSED before the DIS firmware read lands, so the UI can't flash a control we
        // don't yet know is safe to offer.
        #expect(!RingVibration.isSupported(.unknown))
    }

    // MARK: - Firing

    @Test func firesOnceInsideTheGraceWindow() {
        let cal = Self.calendar()
        let alarm = RingAlarm(isEnabled: true, hour: 7, minute: 0)
        let scheduled = Self.date(2026, 9, 1, 7, 0)

        // 90 s of runtime after the alarm time: fire, and report the lateness truthfully.
        let d = RingAlarmSchedule.decide(alarm: alarm, now: Self.date(2026, 9, 1, 7, 1),
                                         lastHandledAt: nil, calendar: cal)
        #expect(d == .fire(scheduled: scheduled, lateBy: 60))

        // Having handled that occurrence, every later wake-up in the same morning is a no-op.
        // This is the property that stops a 60-second keepalive from buzzing the user 15 times.
        for minute in 1...14 {
            let again = RingAlarmSchedule.decide(alarm: alarm,
                                                 now: Self.date(2026, 9, 1, 7, minute),
                                                 lastHandledAt: scheduled, calendar: cal)
            #expect(again == .idle)
        }
    }

    @Test func pastTheGraceWindowItIsMissedNotDelivered() {
        let cal = Self.calendar()
        let alarm = RingAlarm(isEnabled: true, hour: 7, minute: 0)
        // 07:16 — the app finally got runtime, but waking someone 16 minutes late is worse than
        // not waking them, so this must be recorded rather than delivered.
        let d = RingAlarmSchedule.decide(alarm: alarm, now: Self.date(2026, 9, 1, 7, 16),
                                         lastHandledAt: nil, calendar: cal)
        #expect(d == .missed(scheduled: Self.date(2026, 9, 1, 7, 0)))
    }

    @Test func exactlyAtTheGraceBoundaryStillFires() {
        let cal = Self.calendar()
        let alarm = RingAlarm(isEnabled: true, hour: 7, minute: 0)
        let d = RingAlarmSchedule.decide(alarm: alarm, now: Self.date(2026, 9, 1, 7, 15),
                                         lastHandledAt: nil, calendar: cal)
        #expect(d == .fire(scheduled: Self.date(2026, 9, 1, 7, 0), lateBy: 15 * 60))
    }

    @Test func beforeTheAlarmTimeNothingHappens() {
        let cal = Self.calendar()
        let alarm = RingAlarm(isEnabled: true, hour: 7, minute: 0)
        // 06:59 on a day the alarm runs. The most recent occurrence is YESTERDAY 07:00, which was
        // already handled — the rule must not treat "yesterday" as due.
        let d = RingAlarmSchedule.decide(alarm: alarm, now: Self.date(2026, 9, 1, 6, 59),
                                         lastHandledAt: Self.date(2026, 8, 31, 7, 0), calendar: cal)
        #expect(d == .idle)
    }

    @Test func aDisabledAlarmNeverFires() {
        let cal = Self.calendar()
        let alarm = RingAlarm(isEnabled: false, hour: 7, minute: 0)
        #expect(RingAlarmSchedule.decide(alarm: alarm, now: Self.date(2026, 9, 1, 7, 1),
                                         lastHandledAt: nil, calendar: cal) == .idle)
    }

    // MARK: - Weekdays

    @Test func weekdaySelectionIsRespected() {
        let cal = Self.calendar()
        // 2026-09-01 is a Tuesday (weekday 3). Arm the alarm for Mondays only.
        #expect(cal.component(.weekday, from: Self.date(2026, 9, 1, 7, 0)) == 3)
        let mondayOnly = RingAlarm(isEnabled: true, hour: 7, minute: 0, weekdays: [2])

        // Tuesday 07:01 — the most recent MONDAY occurrence is 24 h back, far outside grace.
        let d = RingAlarmSchedule.decide(alarm: mondayOnly, now: Self.date(2026, 9, 1, 7, 1),
                                         lastHandledAt: Self.date(2026, 8, 31, 7, 0), calendar: cal)
        #expect(d == .idle)

        // The following Monday it fires.
        let onMonday = RingAlarmSchedule.decide(alarm: mondayOnly, now: Self.date(2026, 9, 7, 7, 1),
                                                lastHandledAt: Self.date(2026, 8, 31, 7, 0),
                                                calendar: cal)
        #expect(onMonday == .fire(scheduled: Self.date(2026, 9, 7, 7, 0), lateBy: 60))
    }

    @Test func anEmptyWeekdaySetMeansEveryDay() {
        let alarm = RingAlarm(isEnabled: true, hour: 7, minute: 0, weekdays: [])
        for weekday in 1...7 { #expect(alarm.repeats(onWeekday: weekday)) }
    }

    @Test func nextOccurrenceSkipsToday() {
        let cal = Self.calendar()
        let alarm = RingAlarm(isEnabled: true, hour: 7, minute: 0)
        // Asked at 07:30, "next" is tomorrow — not the one that already went off this morning.
        let next = RingAlarmSchedule.nextOccurrence(after: Self.date(2026, 9, 1, 7, 30),
                                                    alarm: alarm, calendar: cal)
        #expect(next == Self.date(2026, 9, 2, 7, 0))
    }

    // MARK: - Daylight saving

    /// The alarm must land on the wall clock the user set, not on a fixed 86 400 s offset. On
    /// 2026-11-01 US clocks go back an hour; a naive "yesterday = now − 86400" would slide a 07:00
    /// alarm to 06:00 and fire it an hour early.
    @Test func survivesAFallBackTransition() {
        let cal = Self.calendar("America/New_York")
        let alarm = RingAlarm(isEnabled: true, hour: 7, minute: 0)
        let now = Self.date(2026, 11, 1, 7, 1, calendar: cal)      // the morning clocks went back
        guard case .fire(let scheduled, let lateBy) =
                RingAlarmSchedule.decide(alarm: alarm, now: now, lastHandledAt: nil, calendar: cal)
        else { Issue.record("expected the alarm to fire"); return }
        #expect(lateBy == 60)
        // 07:00 local, whatever that is in absolute time today.
        let parts = cal.dateComponents([.hour, .minute], from: scheduled)
        #expect(parts.hour == 7)
        #expect(parts.minute == 0)
    }

    /// Spring forward: 02:30 does not exist on 2026-03-08 in New York. The alarm must resolve to a
    /// real instant rather than vanishing for the day.
    @Test func aNonexistentLocalTimeStillResolves() {
        let cal = Self.calendar("America/New_York")
        let alarm = RingAlarm(isEnabled: true, hour: 2, minute: 30)
        let now = Self.date(2026, 3, 8, 12, 0, calendar: cal)
        let occurrence = RingAlarmSchedule.mostRecentOccurrence(onOrBefore: now, alarm: alarm,
                                                                calendar: cal)
        #expect(occurrence != nil)
    }

    // MARK: - Clamps

    @Test func burstSettingsAreClamped() {
        var alarm = RingAlarm(isEnabled: true, burstCount: 99, burstSpacing: 0.1)
        #expect(alarm.clampedBurstCount == 10)
        #expect(alarm.clampedBurstSpacing == 2)
        alarm.burstCount = 0
        alarm.burstSpacing = 600
        #expect(alarm.clampedBurstCount == 1)
        #expect(alarm.clampedBurstSpacing == 30)
    }

    @Test func roundTripsThroughJSON() throws {
        // The config is persisted as JSON in UserDefaults; a decode failure would silently reset a
        // user's alarm to 07:00-disabled, which they would discover by oversleeping.
        let alarm = RingAlarm(isEnabled: true, hour: 6, minute: 45, weekdays: [2, 3, 4, 5, 6],
                              pattern: .long, burstCount: 4, burstSpacing: 6,
                              backupNotification: false)
        let data = try JSONEncoder().encode(alarm)
        #expect(try JSONDecoder().decode(RingAlarm.self, from: data) == alarm)
    }
}

/// The pre-alarm warm-up window — the cue that tells `RingSession` to start holding the BLE link
/// open so the buzz lands in seconds rather than on the ring's next spontaneous push.
struct RingAlarmWarmUpTests {

    private static func calendar() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private static func date(_ y: Int, _ m: Int, _ d: Int, _ hh: Int, _ mm: Int) -> Date {
        calendar().date(from: DateComponents(year: y, month: m, day: d, hour: hh, minute: mm))!
    }

    @Test func armsInsideTheWindowAndNotBefore() {
        let cal = Self.calendar()
        let alarm = RingAlarm(isEnabled: true, hour: 7, minute: 0)
        let target = Self.date(2026, 9, 1, 7, 0)

        // 06:54 — one minute too early. Holding the radio open longer than the problem needs is
        // the cost side of this feature, so the boundary matters.
        #expect(RingAlarmSchedule.warmUpTarget(alarm: alarm, now: Self.date(2026, 9, 1, 6, 54),
                                               calendar: cal) == nil)
        // 06:55 — exactly at the window edge.
        #expect(RingAlarmSchedule.warmUpTarget(alarm: alarm, now: Self.date(2026, 9, 1, 6, 55),
                                               calendar: cal) == target)
        #expect(RingAlarmSchedule.warmUpTarget(alarm: alarm, now: Self.date(2026, 9, 1, 6, 59),
                                               calendar: cal) == target)
    }

    @Test func neverArmsForADisabledAlarm() {
        #expect(RingAlarmSchedule.warmUpTarget(alarm: RingAlarm(isEnabled: false, hour: 7, minute: 0),
                                               now: Self.date(2026, 9, 1, 6, 58),
                                               calendar: Self.calendar()) == nil)
    }

    @Test func doesNotArmForADayTheAlarmSkips() {
        let cal = Self.calendar()
        // Mondays only; 2026-09-01 is a Tuesday, so the next occurrence is six days out.
        let alarm = RingAlarm(isEnabled: true, hour: 7, minute: 0, weekdays: [2])
        #expect(RingAlarmSchedule.warmUpTarget(alarm: alarm, now: Self.date(2026, 9, 1, 6, 58),
                                               calendar: cal) == nil)
        // On the Monday it arms as usual.
        #expect(RingAlarmSchedule.warmUpTarget(alarm: alarm, now: Self.date(2026, 9, 7, 6, 58),
                                               calendar: cal) == Self.date(2026, 9, 7, 7, 0))
    }

    @Test func stopsArmingOnceTheAlarmTimeHasPassed() {
        let cal = Self.calendar()
        let alarm = RingAlarm(isEnabled: true, hour: 7, minute: 0)
        // 07:01 — `nextOccurrence` has rolled to tomorrow, which is nowhere near its window, so the
        // hold releases instead of running all day.
        #expect(RingAlarmSchedule.warmUpTarget(alarm: alarm, now: Self.date(2026, 9, 1, 7, 1),
                                               calendar: cal) == nil)
    }
}

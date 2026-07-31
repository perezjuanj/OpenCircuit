import XCTest
@testable import OpenCircuitKit

/// SYNTHETIC-ONLY tests for the #183 morning overnight-signals notification: the per-DAY ledger,
/// the hard delivery window, quiet hours, suppression, the unlock floor, and the copy rule.
/// No real health value appears anywhere in this file.
///
/// These prove the notification FIRES WHEN IT SHOULD AND SAYS ONLY WHAT WE MEASURED. Nothing here
/// says the index predicts anything — it cannot, and the copy test is precisely the assertion that
/// the shipped words never claim otherwise.
final class HealthAlertsHeadacheTests: XCTestCase {

    /// A fixed UTC calendar, so "08:00" means 08:00 regardless of the machine running the suite —
    /// the delivery window and the `yyyymmdd` day key are both time-of-day sensitive.
    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }()

    private let tuning = HeadacheSignals.Tuning()

    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        cal.date(from: DateComponents(timeZone: cal.timeZone, year: 2026, month: 7,
                                      day: day, hour: hour, minute: minute))!
    }

    /// The shipped decision, with every gate defaulted to "would fire", so each test varies exactly
    /// one thing.
    private func candidates(enabled: Bool = true,
                            band: HeadacheSignals.Band? = .flagged,
                            suppressedBy: HeadacheSignals.Suppression? = nil,
                            frozenDayCount: Int = 30,
                            retired: Bool = false,
                            now: Date? = nil,
                            ledger: [HealthNotification: Int] = [:]) -> [HealthNotification] {
        HeadacheSignsNotifications.candidates(
            enabled: enabled, band: band, suppressedBy: suppressedBy,
            frozenDayCount: frozenDayCount, retired: retired, now: now ?? at(20, 8),
            lastNotifiedDay: ledger, tuning: tuning, calendar: cal)
    }

    private func dayKey(_ day: Int, _ hour: Int = 8) -> Int {
        HeadacheSignsNotifications.dayKey(for: at(day, hour), calendar: cal)
    }

    // MARK: - The happy path

    func testFlaggedMorningRaisesTheCandidate() {
        XCTAssertEqual(candidates(), [.headacheSigns])
    }

    // MARK: - Per-DAY ledger

    /// The load-bearing de-dupe. `evaluate` is polled several times an hour on every wake path, so
    /// the verdict must survive repeated passes and fire exactly ONCE for the day it describes.
    func testFiresAtMostOncePerCalendarDayAcrossRepeatedPasses() {
        var ledger: [HealthNotification: Int] = [:]
        var fires = 0
        // Eleven passes across one morning-to-evening, as the wake paths would produce them.
        for hour in [7, 8, 9, 10, 11, 12, 13, 14, 16, 18, 20] {
            let out = candidates(now: at(20, hour), ledger: ledger)
            if out.contains(.headacheSigns) {
                fires += 1
                ledger[.headacheSigns] = dayKey(20, hour)   // what the app marks after a post
            }
        }
        XCTAssertEqual(fires, 1, "a once-a-morning verdict must not re-fire after every sync")
        XCTAssertEqual(ledger[.headacheSigns], dayKey(20))
    }

    /// A fresh day re-arms it; a STALE ledger entry from an earlier day never blocks.
    func testANewCalendarDayReArmsTheLedger() {
        let ledger: [HealthNotification: Int] = [.headacheSigns: dayKey(20)]
        XCTAssertEqual(candidates(now: at(20, 15), ledger: ledger), [])
        XCTAssertEqual(candidates(now: at(21, 8), ledger: ledger), [.headacheSigns])
    }

    /// The ledger — not the shared 2 h anti-spam backoff — is what makes this once-a-morning. With
    /// only the backoff, the same verdict would re-appear every couple of hours all day: exactly
    /// the bug the #85 temp flags hit and documented at `TempFeverNotifications.freshForNight`.
    func testTheTwoHourBackoffAloneWouldNotDeDupeThisNotification() {
        let morning = at(20, 8)
        let afternoon = at(20, 14)                       // 6 h later — the backoff has long expired
        let gate = NotificationGate()
        XCTAssertTrue(gate.shouldFire(.headacheSigns, now: afternoon,
                                      lastFired: [.headacheSigns: morning],
                                      quietHours: QuietHours(enabled: false), calendar: cal),
                      "precondition: the rolling backoff would happily let it fire again")
        XCTAssertEqual(candidates(now: afternoon, ledger: [.headacheSigns: dayKey(20)]), [],
                       "the per-day ledger is what actually stops the repeat")
    }

    // MARK: - Band

    func testTypicalAndElevatedDaysNeverNotify() {
        XCTAssertEqual(candidates(band: .typical), [])
        XCTAssertEqual(candidates(band: .elevated), [])
        XCTAssertEqual(candidates(band: nil), [], "no frozen row for today ⇒ nothing to report")
    }

    // MARK: - The unlock floor

    /// The unlock is the NATURAL floor: below `minDaysForBanding` frozen days `HeadacheSignals.band`
    /// cannot produce a band at all, so there is nothing to notify about.
    func testBelowMinDaysForBandingNeverNotifies() {
        XCTAssertEqual(candidates(frozenDayCount: 0), [])
        XCTAssertEqual(candidates(frozenDayCount: tuning.minDaysForBanding - 1), [])
        XCTAssertEqual(candidates(frozenDayCount: tuning.minDaysForBanding), [.headacheSigns])
    }

    /// The floor and the band gate agree: at 20 prior indices the Kit's own banding refuses to
    /// return `.flagged` no matter how extreme the index, so the notification gate is not inventing
    /// a second, unrelated threshold.
    func testTheUnlockFloorMatchesWhereBandingItselfBegins() {
        let priors = Array(repeating: 0, count: tuning.minDaysForBanding - 1)
        XCTAssertEqual(HeadacheSignals.band(index: 100, priorIndices: priors, tuning: tuning), .typical)
        XCTAssertEqual(HeadacheSignals.band(index: 100, priorIndices: priors + [0], tuning: tuning), .flagged)
    }

    // MARK: - Opt-out and auto-retire

    func testDisabledOrRetiredNeverNotifies() {
        XCTAssertEqual(candidates(enabled: false), [])
        XCTAssertEqual(candidates(retired: true), [],
                       "the quality monitor switched it off for this user")
    }

    // MARK: - Suppression

    /// Suppression withholds the INTERRUPTION only. The score is still computed, still banded and
    /// still shown — a suppressed day is not a missing day, and treating it as one would put a hole
    /// in the very series the percentile budget is taken over.
    func testSuppressionWithholdsTheAlertButNeverTheScore() throws {
        guard case .scored(let plain) = HeadacheSignals.assess(scoringInput()),
              case .scored(let feverish) = HeadacheSignals.assess(scoringInput(fever: true)),
              case .scored(let logged) = HeadacheSignals.assess(scoringInput(alreadyLogged: true))
        else { return XCTFail("expected three scored days") }

        XCTAssertGreaterThan(plain.index, 0, "precondition: the fixture actually scores")
        XCTAssertEqual(feverish.index, plain.index, "fever must not move the number")
        XCTAssertEqual(logged.index, plain.index, "an already-logged headache must not move it either")
        XCTAssertEqual(feverish.band, plain.band)
        XCTAssertEqual(logged.band, plain.band)
        XCTAssertNil(plain.suppressedBy)
        XCTAssertEqual(feverish.suppressedBy, .fever)
        XCTAssertEqual(logged.suppressedBy, .headacheAlreadyLogged)

        // Only the notification is withheld.
        XCTAssertEqual(candidates(suppressedBy: .fever), [])
        XCTAssertEqual(candidates(suppressedBy: .headacheAlreadyLogged), [])
        XCTAssertEqual(candidates(suppressedBy: nil), [.headacheSigns])
    }

    // MARK: - Delivery window + quiet hours

    /// Quiet hours ship DISABLED, so the shared DND gate protects nothing overnight on a default
    /// install. This alert therefore carries its own hard window: a summary of a night that is
    /// already over has no business waking anyone at 04:00.
    func testHardDeliveryWindowKeepsItOutOfTheNight() {
        XCTAssertEqual(candidates(now: at(20, 3)), [])
        XCTAssertEqual(candidates(now: at(20, 6, 59)), [])
        XCTAssertEqual(candidates(now: at(20, 7)), [.headacheSigns], "window opens at 07:00")
        XCTAssertEqual(candidates(now: at(20, 20, 59)), [.headacheSigns])
        XCTAssertEqual(candidates(now: at(20, 21)), [], "window closes at 21:00")
        XCTAssertEqual(candidates(now: at(20, 23, 30)), [])
    }

    /// A verdict held back by the window is NOT lost: the ledger is still fresh, so the next
    /// evaluate pass inside the window delivers it.
    func testAVerdictHeldByTheWindowStillFiresLater() {
        XCTAssertEqual(candidates(now: at(20, 6)), [])
        XCTAssertEqual(candidates(now: at(20, 7, 30)), [.headacheSigns])
    }

    /// The user's own quiet hours still apply on top, through the ONE shared gate — including a
    /// window that overlaps the morning (someone who mutes 08:00–09:00).
    func testUserQuietHoursSuppressTheSurvivor() {
        let now = at(20, 8, 30)
        let quiet = QuietHours(enabled: true, startMinutes: 8 * 60, endMinutes: 9 * 60)
        let gate = NotificationGate()
        XCTAssertEqual(candidates(now: now), [.headacheSigns], "precondition: it is a candidate")
        XCTAssertEqual(gate.filter(candidates(now: now), now: now, lastFired: [:],
                                   quietHours: quiet, calendar: cal), [])
        // Outside the muted hour it survives the same gate.
        let later = at(20, 9, 30)
        XCTAssertEqual(gate.filter(candidates(now: later), now: later, lastFired: [:],
                                   quietHours: quiet, calendar: cal), [.headacheSigns])
    }

    // MARK: - Copy

    /// THE COPY RULE. The notification reports what we MEASURED; it never forecasts. The word
    /// "headache" must not appear at all — the user opted into a feature by that name, so the
    /// context is already theirs, and putting it in the alert turns a true measurement into a false
    /// prediction that is wrong about three times in four (`HeadacheSignals.swift` §1).
    func testCopyIsAMeasurementNeverAForecast() {
        let variants = [
            HeadacheSignsNotifications.copy(topSignals: [.restingHRDeviation, .sleepEfficiencyDrop]),
            HeadacheSignsNotifications.copy(topSignals: [.hrvDeviation]),
            HeadacheSignsNotifications.copy(topSignals: []),
        ]
        let banned = ["headache", "risk", "predict", "likely", "warning", "probab", "chance",
                      "score", "%", "will ", "may get", "expect", "forecast that"]
        for (title, body) in variants {
            let text = (title + " " + body).lowercased()
            for word in banned {
                XCTAssertFalse(text.contains(word), "banned copy '\(word)' in: \(title) / \(body)")
            }
            XCTAssertFalse(title.contains { $0.isNumber }, "no number belongs in the title")
            XCTAssertFalse(body.contains { $0.isNumber }, "no probability, percentage or score")
            XCTAssertTrue(text.contains("estimate"), "every sensor-derived alert says so")
        }
    }

    func testCopyNamesTheSignalsInPlainWords() {
        let (title, body) = HeadacheSignsNotifications.copy(
            topSignals: [.restingHRDeviation, .sleepEfficiencyDrop])
        XCTAssertEqual(title, "Last night was unusual for you")
        XCTAssertTrue(body.hasPrefix("Resting heart rate and sleep efficiency drifted furthest"),
                      "got: \(body)")
        // The analytic vocabulary never reaches the user.
        XCTAssertFalse(body.lowercased().contains("z-score"))
        XCTAssertFalse(body.lowercased().contains("arousal"))
        XCTAssertFalse(body.lowercased().contains("letdown"))
    }

    /// A row whose per-feature detail is unreadable still produces a TRUE sentence — just a less
    /// specific one. Naming a feature we cannot evidence would be worse than being vague.
    func testCopyFallsBackWhenNoSignalIsLegible() {
        let (_, body) = HeadacheSignsNotifications.copy(topSignals: [])
        XCTAssertTrue(body.hasPrefix("Several of your overnight signals drifted"), "got: \(body)")
    }

    /// THE TIMEFRAME FOLLOWS WHAT WAS NAMED. `arousalLetdown` is the one DAYTIME term — a fall in
    /// waking heart rate from the day before yesterday to yesterday — so a body that names it must
    /// not file it under "last night". A constant suffix made the one sentence this whole design
    /// rests on being literally true report a measurement of a night that term never looks at.
    func testTheTimeframeFollowsTheNamedSignals() {
        // The daytime term alone: no nightly claim anywhere in the body.
        let alone = HeadacheSignsNotifications.copy(topSignals: [.arousalLetdown]).body
        XCTAssertFalse(alone.lowercased().contains("last night"), "got: \(alone)")
        XCTAssertTrue(alone.contains("over the past two days"), "got: \(alone)")

        // A mixed pair, in EITHER ranking order: each signal carries its own period, and the
        // nightly one is still described as nightly.
        for pair: [HeadacheSignals.Feature] in [[.arousalLetdown, .sleepEfficiencyDrop],
                                                [.sleepEfficiencyDrop, .arousalLetdown]] {
            let body = HeadacheSignsNotifications.copy(topSignals: pair).body
            XCTAssertTrue(body.lowercased().contains("daytime heart rate over the past two days"),
                          "got: \(body)")
            XCTAssertTrue(body.lowercased().contains("sleep efficiency last night"), "got: \(body)")
        }

        // Two nightly signals keep the compact single-suffix sentence they always had.
        let nightly = HeadacheSignsNotifications.copy(topSignals: [.hrvDeviation,
                                                                   .restingHRDeviation]).body
        XCTAssertTrue(nightly.hasPrefix("Heart rate variability and resting heart rate drifted "
                                        + "furthest from your usual range last night"),
                      "got: \(nightly)")

        // Every nightly feature says so; the daytime one never does. Guards a future feature being
        // added without a decision about which period it belongs to.
        for feature in HeadacheSignals.Feature.allCases {
            let body = HeadacheSignsNotifications.copy(topSignals: [feature]).body
            XCTAssertEqual(body.contains("last night"), feature != .arousalLetdown,
                           "\(feature) is described over the wrong period: \(body)")
        }
    }

    /// A notification body that wraps to four lines is its own failure, so the honest per-signal
    /// timeframe must not have bought accuracy with length.
    func testEveryBodyStaysShortEnoughToRead() {
        var pairs: [[HeadacheSignals.Feature]] = [[]]
        for a in HeadacheSignals.Feature.allCases {
            pairs.append([a])
            for b in HeadacheSignals.Feature.allCases where b != a { pairs.append([a, b]) }
        }
        for signals in pairs {
            let body = HeadacheSignsNotifications.copy(topSignals: signals).body
            XCTAssertLessThanOrEqual(body.count, 200, "too long for a notification: \(body)")
        }
    }

    // MARK: - Which signals get named

    func testTopSignalsRanksByWeightedShareAndExcludesTheCalendarLookup() {
        let weighted: [HeadacheSignals.Feature: Double] = [
            .restingHRDeviation: 0.14,
            .sleepEfficiencyDrop: 0.18,
            .skinTempDeviation: 0.08,
            .perimenstrual: 0.20,          // heaviest, and deliberately never named
        ]
        XCTAssertEqual(HeadacheSignsNotifications.topSignals(weighted),
                       [.sleepEfficiencyDrop, .restingHRDeviation])
    }

    /// A feature that contributed nothing is not "what drifted furthest" — it must not be named.
    func testTopSignalsDropsZeroContributors() {
        XCTAssertEqual(HeadacheSignsNotifications.topSignals([.hrvDeviation: 0,
                                                              .scheduleShift: 0.08]),
                       [.scheduleShift])
        XCTAssertEqual(HeadacheSignsNotifications.topSignals([:]), [])
    }

    /// Equal shares break by declaration order, so the same morning always words itself the same
    /// way rather than shuffling with dictionary iteration order.
    func testTopSignalsTieBreakIsDeterministic() {
        let weighted: [HeadacheSignals.Feature: Double] = [.skinTempDeviation: 0.1,
                                                           .hrvDeviation: 0.1,
                                                           .scheduleShift: 0.1]
        for _ in 0..<25 {
            XCTAssertEqual(HeadacheSignsNotifications.topSignals(weighted, limit: 3),
                           [.hrvDeviation, .scheduleShift, .skinTempDeviation])
        }
    }

    // MARK: - Membership / keys

    func testNotificationSetAndCategoryAreRingFenced() {
        XCTAssertEqual(HeadacheSignsNotifications.notificationSet, [.headacheSigns])
        XCTAssertFalse(TempFeverNotifications.notificationSet.contains(.headacheSigns),
                       "must not join the temp family's per-night ledger / disclaimer branch")
        XCTAssertEqual(HeadacheSignsNotifications.categoryIdentifier, "headache.signs")
    }

    /// One implementation of the timezone-stable day key, shared with the #85 night ledger.
    func testDayKeyMatchesTheOneSharedImplementation() {
        XCTAssertEqual(HeadacheSignsNotifications.dayKey(for: at(20, 8), calendar: cal), 20_260_720)
        XCTAssertEqual(HeadacheSignsNotifications.dayKey(for: at(20, 8), calendar: cal),
                       TempFeverNotifications.dayKey(for: at(20, 20), calendar: cal))
    }

    // MARK: - Fixture

    /// One synthetic day that scores: every feature sits exactly on a flat baseline except sleep
    /// efficiency, which is 20 %-pt below it. Hand-computable — flat priors mean 1.4826·MAD == 0,
    /// so the divisor is the feature's own noise floor.
    private func scoringInput(fever: Bool = false,
                              alreadyLogged: Bool = false) -> HeadacheSignals.DayInput {
        func flat(_ value: Double) -> [Double] { Array(repeating: value, count: 14) }
        let day = at(20, 0)
        let now = at(20, 8)
        return HeadacheSignals.DayInput(
            day: day,
            now: now,
            lastRingDataAt: now.addingTimeInterval(-3600),
            restingHR: .init(today: 60, prior: flat(60)),
            hrvSDNN: .init(today: 50, prior: flat(50)),
            sleepEfficiencyPct: .init(today: 70, prior: flat(90)),
            sleepFragmentationMin: .init(today: 40, prior: flat(40)),
            sleepDurationMin: .init(today: 420, prior: flat(420)),
            skinTempOffsetC: 0,
            inBedStartMinutes: 23 * 60,
            priorInBedStartMinutes: Array(repeating: 23 * 60, count: 14),
            dayHRPrevious: 70,
            dayHRTwoDaysAgo: 70,
            dayHRPrior: flat(70),
            isPerimenstrual: false,
            sleepLikelyTruncated: false,
            feverSuspected: fever,
            headacheAlreadyLoggedToday: alreadyLogged,
            priorIndices: [])
    }
}

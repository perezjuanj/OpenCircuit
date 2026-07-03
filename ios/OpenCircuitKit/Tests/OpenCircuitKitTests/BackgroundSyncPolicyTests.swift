import XCTest
@testable import OpenCircuitKit

// BGTask aiming (#119): by day requests use the plain interval; near/inside the sleep window
// they aim at windowEnd − lead so the discretionary morning grant lands right after the night —
// the one moment a background run can pull the whole night in one pass.
final class BackgroundSyncPolicyTests: XCTestCase {

    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// A window 22:30 → 06:30 around a fixed reference day.
    private func window(endingMorningOf day: Date) -> DateInterval {
        DateInterval(start: day.addingTimeInterval(-(1.5 * 3600)),   // 22:30 the evening before
                     end: day.addingTimeInterval(6.5 * 3600))        // 06:30
    }

    /// Midnight UTC of an arbitrary fixed day.
    private var midnight: Date { Date(timeIntervalSince1970: 1_750_000_000 - 1_750_000_000.truncatingRemainder(dividingBy: 86_400)) }

    // MARK: aimedFireDate

    func testDaytimeUsesFallbackInterval() {
        let noon = midnight.addingTimeInterval(12 * 3600)
        let w = window(endingMorningOf: midnight.addingTimeInterval(86_400))   // tonight's window
        let aimed = BackgroundSyncPolicy.aimedFireDate(now: noon, sleepWindow: w, fallbackInterval: 900)
        XCTAssertEqual(aimed, noon.addingTimeInterval(900), "midday: plain interval, no morning aim")
    }

    func testInsideWindowAimsAtMorning() {
        let twoAM = midnight.addingTimeInterval(2 * 3600)
        let w = window(endingMorningOf: midnight)                              // ends 06:30 today
        let aimed = BackgroundSyncPolicy.aimedFireDate(now: twoAM, sleepWindow: w, fallbackInterval: 900)
        XCTAssertEqual(aimed, w.end.addingTimeInterval(-BackgroundSyncPolicy.morningLeadTime),
                       "mid-night submission aims at window end − lead, not now + 15 min")
    }

    func testShortlyBeforeBedAimsAtMorning() {
        let nine30PM = midnight.addingTimeInterval(-2.5 * 3600)                // 21:30, bed 22:30
        let w = window(endingMorningOf: midnight)
        let aimed = BackgroundSyncPolicy.aimedFireDate(now: nine30PM, sleepWindow: w, fallbackInterval: 900)
        XCTAssertEqual(aimed, w.end.addingTimeInterval(-BackgroundSyncPolicy.morningLeadTime),
                       "within 2 h of bed: a now+15 min request would fire mid-night and be wasted")
    }

    func testDeepInMorningLeadFallsBackToInterval() {
        let w = window(endingMorningOf: midnight)
        let justBeforeEnd = w.end.addingTimeInterval(-5 * 60)                  // inside the 10 min lead
        let aimed = BackgroundSyncPolicy.aimedFireDate(now: justBeforeEnd, sleepWindow: w, fallbackInterval: 900)
        XCTAssertEqual(aimed, justBeforeEnd.addingTimeInterval(900),
                       "aimed moment already behind us → plain interval, never a past date")
    }

    func testNoWindowUsesFallback() {
        let now = midnight.addingTimeInterval(12 * 3600)
        let aimed = BackgroundSyncPolicy.aimedFireDate(now: now, sleepWindow: nil, fallbackInterval: 3600)
        XCTAssertEqual(aimed, now.addingTimeInterval(3600))
    }

    func testWindowAlreadyOverUsesFallback() {
        let w = window(endingMorningOf: midnight)
        let eightAM = midnight.addingTimeInterval(8 * 3600)                    // window ended 06:30
        let aimed = BackgroundSyncPolicy.aimedFireDate(now: eightAM, sleepWindow: w, fallbackInterval: 900)
        XCTAssertEqual(aimed, eightAM.addingTimeInterval(900))
    }

    // MARK: relevantWindow

    func testEveningResolvesTonightsWindowNotThisMornings() {
        let eightPM = cal.date(bySettingHour: 20, minute: 0, second: 0,
                               of: Date(timeIntervalSince1970: 1_750_000_000))!
        let w = BackgroundSyncPolicy.relevantWindow(now: eightPM,
                                                    bedMinutes: 22 * 60 + 30,
                                                    wakeMinutes: 6 * 60 + 30,
                                                    calendar: cal)
        XCTAssertNotNil(w)
        XCTAssertGreaterThan(w!.end, eightPM, "the relevant window's end must still be ahead")
        XCTAssertLessThan(w!.end.timeIntervalSince(eightPM), 24 * 3600, "…and within the coming day")
    }

    func testMidNightResolvesTheWindowInProgress() {
        let twoAM = cal.date(bySettingHour: 2, minute: 0, second: 0,
                             of: Date(timeIntervalSince1970: 1_750_000_000))!
        let w = BackgroundSyncPolicy.relevantWindow(now: twoAM,
                                                    bedMinutes: 22 * 60 + 30,
                                                    wakeMinutes: 6 * 60 + 30,
                                                    calendar: cal)
        XCTAssertNotNil(w)
        XCTAssertTrue(w!.contains(twoAM), "2 AM sits inside the in-progress window")
    }

    func testDegenerateScheduleYieldsNilWindow() {
        XCTAssertNil(BackgroundSyncPolicy.relevantWindow(now: Date(timeIntervalSince1970: 1_750_000_000),
                                                         bedMinutes: 480, wakeMinutes: 480,
                                                         calendar: cal),
                     "bed == wake is degenerate — no window, callers fall back to the interval")
    }
}

// Background cap on the reconnect backoff (#119): the 30 s foreground damping dies mid-wait when
// backgrounded (the process suspends ~10 s after the disconnect wake), leaving no standing
// pending connect — so backgrounded waits are capped to fit inside an assertion.
final class ReconnectBackoffBackgroundCapTests: XCTestCase {

    func testForegroundDelaysUnchanged() {
        for attempt in 0...6 {
            XCTAssertEqual(ReconnectBackoff.delay(forAttempt: attempt, inBackground: false),
                           ReconnectBackoff.delay(forAttempt: attempt))
        }
    }

    func testBackgroundCapsAtEight() {
        XCTAssertEqual(ReconnectBackoff.delay(forAttempt: 1, inBackground: true), 1)
        XCTAssertEqual(ReconnectBackoff.delay(forAttempt: 2, inBackground: true), 5)
        XCTAssertEqual(ReconnectBackoff.delay(forAttempt: 3, inBackground: true),
                       ReconnectBackoff.backgroundDelayCap)
        XCTAssertEqual(ReconnectBackoff.delay(forAttempt: 99, inBackground: true),
                       ReconnectBackoff.backgroundDelayCap)
    }

    func testCapFitsInsideAnAssertionWindow() {
        // beginBackgroundTask grants ~30 s; the cap must leave real margin for the connect call.
        XCTAssertLessThanOrEqual(ReconnectBackoff.backgroundDelayCap, 10)
    }
}

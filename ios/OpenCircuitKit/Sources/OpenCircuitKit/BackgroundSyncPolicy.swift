// Where to AIM a BGTask request's `earliestBeginDate` (#119). iOS grants BGAppRefresh /
// BGProcessing runs at its own discretion — a couple a day is typical — so the one thing we
// control is WHERE the grant can land. A request that becomes eligible mid-night is wasted
// (the overnight-quiet gate means an in-window run does no drain), and each wasted grant
// deprioritizes the next. So: by day the tasks ask for the normal short interval (they're the
// assist leg for daytime steps/HR/RR freshness); once the upcoming sleep window is near — or
// we're already inside it — the request is aimed at just BEFORE the window's end, so the
// discretionary grant lands at the single most valuable moment: the morning drain, typically
// while the phone charges (when iOS is most generous).
//
// Pure (no Apple frameworks) so it unit-tests on the CLI, like the other policy enums.

import Foundation

public enum BackgroundSyncPolicy {

    /// How far before the sleep window's END the morning-aimed request becomes eligible: early
    /// enough to beat the user's wake-up, late enough that the night is over when it fires.
    public static let morningLeadTime: TimeInterval = 10 * 60

    /// Within this long BEFORE the window starts, a `now + interval` request would likely fire
    /// mid-night and be wasted — aim it at the morning instead.
    public static let preWindowAimThreshold: TimeInterval = 2 * 3600

    /// The sleep window a request submitted at `now` should aim around: tonight's (or the one in
    /// progress). Resolves the nightly window for "now" and "tomorrow" and keeps the first whose
    /// end is still ahead — `SleepWindow.interval(nightEndingNear:)` alone would hand back this
    /// MORNING's already-finished window for any evening `now`.
    public static func relevantWindow(now: Date,
                                      bedMinutes: Int,
                                      wakeMinutes: Int,
                                      calendar: Calendar = .current) -> DateInterval? {
        [now, now.addingTimeInterval(86_400)]
            .compactMap {
                SleepWindow.interval(bedMinutes: bedMinutes, wakeMinutes: wakeMinutes,
                                     nightEndingNear: $0, calendar: calendar)
            }
            .filter { now < $0.end }
            .min { $0.end < $1.end }
    }

    /// The `earliestBeginDate` to submit: `now + fallbackInterval` by day; the window's
    /// end − `morningLeadTime` when `now` is inside the window or within
    /// `preWindowAimThreshold` of its start. Falls back to the plain interval when the aimed
    /// moment is already behind us (submitting deep in the morning lead time) or there is no
    /// usable window.
    public static func aimedFireDate(now: Date,
                                     sleepWindow: DateInterval?,
                                     fallbackInterval: TimeInterval) -> Date {
        let fallback = now.addingTimeInterval(fallbackInterval)
        guard let window = sleepWindow, now < window.end else { return fallback }
        guard now >= window.start.addingTimeInterval(-preWindowAimThreshold) else { return fallback }
        let aimed = window.end.addingTimeInterval(-morningLeadTime)
        return aimed > now ? aimed : fallback
    }
}

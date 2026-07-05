// Pure, platform-agnostic "is last night actually last night?" date math.
//
// Two surfaces used to answer this question independently and could disagree:
//   • the Daily-Goals Sleep ring (GoalsCardView) credited the newest stored night as "today"
//     with NO recency guard, so a days-old night filled the ring (#147); and
//   • the Sleep card's missed-night banner (SleepCardView) fired every morning before the
//     first sync (false positive) and vanished every evening (the wake reference flipped to
//     tomorrow's wake) (#148).
//
// Both are the SAME underlying "recency" bug, so the decision lives here — one place, unit
// tested with `swift test`, no SwiftUI/SwiftData — and both cards call it so they can never
// disagree about what counts as last night or when it is genuinely missing.
//
// Invariant that ties the two together: whenever the banner reads `.missing`, the credit is
// withheld (empty ring). `.missing` requires the shown night did NOT end today, and the credit
// is granted ONLY when the shown night ended today, so the two are mutually exclusive by
// construction.

import Foundation

public enum MissedNight {

    /// What the UI should say about the currently-shown night's recency.
    public enum Status: Equatable {
        /// Nothing to flag: the shown night ended today, or it's too early / legacy to judge
        /// (mid-sleep before this morning's wake, or a rollup with no clock time).
        case ok
        /// Past this morning's wake with no night ending today, but no sync has completed since
        /// wake — last night may simply not have drained off the ring yet. Show a soft, neutral
        /// "not synced yet" note, NOT the alarming miss banner (#148 Bug 1).
        case notSyncedYet
        /// Past this morning's wake, a sync DID complete after wake, and still no night ending
        /// today — the night was genuinely missed. Show the honest orange banner (#148).
        case missing
    }

    // MARK: This morning's wake anchor

    /// This morning's wake instant — the wake of the sleep window we are currently in or have
    /// most recently passed, held FIXED at today's wake for the whole waking day.
    ///
    /// `SleepWindow.interval(nightEndingNear:)` returns the wake *nearest* `now`, which after the
    /// midpoint of the day (≈ wake + 12 h) flips to *tomorrow's* wake — that made the missed-night
    /// banner disappear every evening (#148 Bug 2). We instead anchor to the window whose bedtime
    /// we are already at/past: when `now` is before the nearest window's bedtime (evening, or a
    /// glance before tonight's bed) that nearest window is still in the FUTURE, so we step back a
    /// day to this morning's (already-past) wake. When `now` is at/after that bedtime — either
    /// mid-sleep (wake still ahead → `now <= wake`, no miss claimed) or during the day after the
    /// window ended — the nearest window's wake is the right reference.
    ///
    /// - Returns: `nil` only for a degenerate zero-length schedule (`bed == wake`).
    public static func morningWake(now: Date, bedMinutes: Int, wakeMinutes: Int,
                                   calendar: Calendar = .current) -> Date? {
        guard let near = SleepWindow.interval(bedMinutes: bedMinutes, wakeMinutes: wakeMinutes,
                                              nightEndingNear: now, calendar: calendar)
        else { return nil }
        // At/after the nearest window's bedtime → that window's wake is this morning's (it's
        // ahead only when we're mid-sleep, which the caller's `now > wake` gate handles).
        if now >= near.start { return near.end }
        // Before the nearest window's bedtime → it's a future night; step back one day so the
        // reference stays pinned to the wake we already passed this morning.
        return SleepWindow.interval(bedMinutes: bedMinutes, wakeMinutes: wakeMinutes,
                                    nightEndingNear: now.addingTimeInterval(-86_400),
                                    calendar: calendar)?.end
    }

    // MARK: Credit recency (#147 — Goals Sleep ring)

    /// The night's wake reference: its real wake time (`inBedEnd`) when known, else the
    /// start-of-day `night` key. A legacy rollup (`inBedEnd` == `.distantPast`) falls back to the
    /// key so it can't be credited on a later day.
    public static func nightWakeReference(inBedEnd: Date?, nightKey: Date) -> Date {
        inBedEnd ?? nightKey
    }

    /// Whether the shown night should count as "last night" for crediting — i.e. its wake ended
    /// today. This is the SAME "ended today" test the miss banner uses (via `nightWake`), so the
    /// two cards agree: a night ending today is credited AND never flagged missing; a night that
    /// did not end today is neither credited nor (when a post-wake sync landed) shown as recorded.
    public static func endedToday(inBedEnd: Date?, nightKey: Date,
                                  now: Date = Date(), calendar: Calendar = .current) -> Bool {
        calendar.isDate(nightWakeReference(inBedEnd: inBedEnd, nightKey: nightKey),
                        inSameDayAs: now)
    }

    // MARK: Missed-night status (#148 — Sleep card banner)

    /// Classify the shown night's recency for the Sleep card.
    ///
    /// - Parameters:
    ///   - nightWake: the shown night's actual wake (`inBedEnd`); `nil`/`wakeKnown == false` for a
    ///     legacy rollup with no clock time (never judged).
    ///   - wakeKnown: whether `nightWake` is a real wake instant.
    ///   - lastSyncAt: completion time of the most recent successful sync/drain (NOT a sample
    ///     timestamp — device timestamps can be 60+ min stale). `nil` when none is recorded.
    public static func status(now: Date, bedMinutes: Int, wakeMinutes: Int,
                              nightWake: Date?, wakeKnown: Bool,
                              lastSyncAt: Date?, calendar: Calendar = .current) -> Status {
        // Legacy rollup with no clock time — can't reason about it (mirror the app's guard).
        guard wakeKnown, let nightWake else { return .ok }
        guard let wake = morningWake(now: now, bedMinutes: bedMinutes,
                                     wakeMinutes: wakeMinutes, calendar: calendar) else { return .ok }
        // Not yet past this morning's wake (mid-sleep / early) — never claim a miss.
        guard now > wake else { return .ok }
        // The shown night already ended today → it IS last night; nothing to flag.
        guard !calendar.isDate(nightWake, inSameDayAs: now) else { return .ok }
        // Past wake with a stale night on screen. Only call it a genuine miss once a sync has
        // actually completed AFTER this morning's wake and still produced no night ending today;
        // otherwise last night may simply not have drained yet.
        if let lastSyncAt, lastSyncAt > wake { return .missing }
        return .notSyncedYet
    }

    /// Convenience: the honest orange "no sleep recorded" banner should show iff this is `true`.
    public static func isMissing(now: Date, bedMinutes: Int, wakeMinutes: Int,
                                 nightWake: Date?, wakeKnown: Bool,
                                 lastSyncAt: Date?, calendar: Calendar = .current) -> Bool {
        status(now: now, bedMinutes: bedMinutes, wakeMinutes: wakeMinutes,
               nightWake: nightWake, wakeKnown: wakeKnown,
               lastSyncAt: lastSyncAt, calendar: calendar) == .missing
    }
}

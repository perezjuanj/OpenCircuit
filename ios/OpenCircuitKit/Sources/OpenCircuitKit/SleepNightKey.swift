// The calendar day a night's summary is filed under — the single upsert key for
// `StoredSleepSummary` and for every night-scoped overlay derived from it.
//
// WHY THIS EXISTS. The key used to be `startOfDay(inBedSTART)`, which ALIASES: a bedtime after
// midnight keys to the WAKE day, a bedtime before midnight keys to the day BEFORE the wake day.
// Two consecutive nights therefore collapse onto ONE key whenever bedtime crosses midnight in
// opposite directions — and that is an ordinary sleep pattern, not a corner case.
//
// PROVEN byte-exact on a real device 2026-08-08:
//   night 08-06 → 08-07   bed 00:13:28 → wake 08:57:28   startOfDay(bed) = 2026-08-07
//   night 08-07 → 08-08   bed 23:56:00 → wake 09:45:00   startOfDay(bed) = 2026-08-07  ← collides
// The stored row for the first night carried `isManuallyEdited`, so `LocalStore.saveSleepSummary`
// took its preserve-the-user's-edit early return and dropped the second night entirely — no row,
// no log, no metric, and permanently, since every retry hits the same guard. On an UNEDITED pair
// the collision is worse rather than better: `SleepSummaryMerge` would have REPLACED the older
// night's row with the newer one.
//
// THE RULE: key on the day the sleep block ENDS on. A night is named for the morning you wake up
// into, which is both what the UI already implies and what `RingSession.restageNights` documented
// all along while the code did something else.
//
// Pure Foundation so it unit-tests on the CLI; the caller supplies the calendar (and therefore the
// time zone), exactly as the previous `Calendar.current.startOfDay` did.

import Foundation

public enum SleepNightKey {

    /// The night key for an in-bed window: the start of the day the window ENDS on.
    ///
    /// `inBedEnd` is the anchor because it is the only edge that is stable under a bedtime that
    /// straddles midnight. Falls back to `inBedStart` when the window is empty or inverted
    /// (`inBedEnd <= inBedStart`) — a degenerate row still needs SOME deterministic key, and
    /// start-anchoring it reproduces the historical behaviour for exactly the rows where there is
    /// no end to anchor to.
    public static func night(inBedStart: Date, inBedEnd: Date,
                             calendar: Calendar = .current) -> Date {
        let anchor = inBedEnd > inBedStart ? inBedEnd : inBedStart
        return calendar.startOfDay(for: anchor)
    }

    /// The night key for a staged hypnogram — the same rule applied to the segments' envelope.
    /// nil when there are no segments (there is no night to key).
    public static func night(for segments: [SleepSegment],
                             calendar: Calendar = .current) -> Date? {
        guard let start = segments.map(\.start).min(),
              let end = segments.map(\.end).max() else { return nil }
        return night(inBedStart: start, inBedEnd: end, calendar: calendar)
    }

    /// The key a stored row SHOULD have, or nil when it is already correct.
    ///
    /// Drives the one-shot re-key migration. Returning nil for an already-correct row is what makes
    /// the migration idempotent and keeps it from touching rows it does not need to move.
    public static func rekeyed(storedNight: Date, inBedStart: Date, inBedEnd: Date,
                               calendar: Calendar = .current) -> Date? {
        let correct = night(inBedStart: inBedStart, inBedEnd: inBedEnd, calendar: calendar)
        return correct == calendar.startOfDay(for: storedNight) ? nil : correct
    }
}

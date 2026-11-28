// Today's one Vitals Status computation (#396, decision 95a; replaces #395's hidden-card runner).
//
// The verdict feeds Recovery and the sentence's fever pair, so it must not depend on the Vitals Status
// card's row: a shown card below the fold is never built by the lazy list, a hidden one isn't drawn,
// and a moved one is built at a different time. `TodayVitalsRunner` is exactly one
// `VitalsStatusLoader` behind Today's content (outside the list), and the card only displays its report.
//
// Recovery shows a placeholder until the first complete report (local history and the Apple Health
// fallback both tried), so it doesn't show the two-factor value and then the three-factor one. If no
// complete report lands within `settleTimeout` of Today being on screen without a break, it settles with
// what it has (no verdict yet: the two-factor score, which a later verdict then replaces). Leaving Today
// cancels the wait and the reads without settling; both start again, from zero, when Today reappears.
//
// Decision 98: the verdict carries the nights its values come from (`VitalsVerdictNights`), and Recovery
// counts it only when every value is from the night of the sleep score (`RecoveryVitalsAge.match`).

import SwiftUI
import OpenCircuitKit

/// The Vitals Status verdict as Recovery reads it.
struct TodayVitals: Equatable {
    /// The report; nil while there isn't enough baseline history (or before the first one lands).
    var report: VitalsBaseline.Report?
    /// The first complete report has landed, or the wait timed out. Until then Recovery is pending.
    var settled: Bool
    /// The nights the report's values come from (decision 98). Nil with no report, or when they aren't known.
    var nights: VitalsVerdictNights? = nil

    /// Before the first report: Recovery waits.
    static let pending = TodayVitals(report: nil, settled: false)
    /// Settled with no verdict: Recovery is the two-factor score. Also what a caller without a loader passes.
    static let noVerdict = TodayVitals(report: nil, settled: true)

    /// Folds one loader result in. Once settled it stays settled; the report always follows the newest.
    func receiving(_ result: VitalsStatusLoader.Result) -> TodayVitals {
        TodayVitals(report: result.report, settled: settled || result.isComplete, nights: result.nights)
    }

    /// Settled by the wait running out: the same report with the same nights, so a verdict for last night is
    /// still counted at settle and the number doesn't move when the complete report brings the same verdict.
    func settledOnTimeout() -> TodayVitals {
        TodayVitals(report: report, settled: true, nights: nights)
    }
}

// MARK: - The verdict's night (decision 98)

/// A calendar date with no time of day and no time zone: the day a night is filed under (the morning it
/// ends on, as a night key). Worked out once in the calendar that made the date, so it compares the same
/// after a time-zone change.
struct NightDate: Comparable, Hashable, Sendable {
    let year: Int
    let month: Int
    let day: Int

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// The date `date` falls on in `calendar`.
    init(_ date: Date, calendar: Calendar) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year ?? 0, month: c.month ?? 0, day: c.day ?? 0)
    }

    static func < (a: NightDate, b: NightDate) -> Bool {
        (a.year, a.month, a.day) < (b.year, b.month, b.day)
    }
}

/// The nights a Vitals Status verdict's values come from: the oldest and the newest of them. One night
/// when every value agrees.
struct VitalsVerdictNights: Equatable, Sendable {
    let oldest: NightDate
    let newest: NightDate

    init(oldest: NightDate, newest: NightDate) {
        self.oldest = min(oldest, newest)
        self.newest = max(oldest, newest)
    }

    /// Every value from `night`.
    init(_ night: NightDate) { self.init(oldest: night, newest: night) }

    /// The nights of `days` (each a day a judged value comes from) in `calendar`; nil with none.
    init?(days: [Date], calendar: Calendar) {
        let nights = days.map { NightDate($0, calendar: calendar) }
        guard let oldest = nights.min(), let newest = nights.max() else { return nil }
        self.init(oldest: oldest, newest: newest)
    }
}

/// Whether Recovery may count a Vitals Status verdict (decision 98): only when it is for the same night as
/// the sleep score Recovery is built on. Pure: the calendar (and so the time zone) is passed in.
enum RecoveryVitalsAge {
    enum Match: Equatable, Sendable {
        /// Every value is from the sleep score's night: counted.
        case sameNight
        /// Every value is from before that night.
        case earlierNight
        /// Some values are from that night and some from before it.
        case partlyEarlierNight
        /// A value is from after that night, or the nights aren't known.
        case otherNight

        var isCounted: Bool { self == .sameNight }
    }

    /// `verdict`'s nights against the night key of the sleep score, read as a date in `calendar` (the
    /// calendar the verdict's own dates were read in, the one Today judges "last night" with).
    static func match(_ verdict: VitalsVerdictNights?, sleepNightKey: Date, calendar: Calendar) -> Match {
        guard let verdict else { return .otherNight }
        let night = NightDate(sleepNightKey, calendar: calendar)
        if verdict.newest > night { return .otherNight }
        if verdict.oldest == night { return .sameNight }
        return verdict.newest == night ? .partlyEarlierNight : .earlierNight
    }
}

/// Today's one `VitalsStatusLoader`, mounted as a background behind Today's content (never inside the
/// list), reporting every change of the verdict. Settles on the first complete report, or after
/// `settleTimeout` of uninterrupted time on screen without one.
struct TodayVitalsRunner: View {
    /// How long Recovery waits for a complete report before it settles with what it has.
    static var settleTimeout: Duration { .seconds(6) }

    let onChange: (TodayVitals) -> Void

    @State private var vitals = TodayVitals.pending

    var body: some View {
        VitalsStatusLoader { result in publish(vitals.receiving(result)) }
            .task {
                // A cancelled wait (Today left the screen) must not settle: it re-arms when Today reappears.
                guard (try? await Task.sleep(for: Self.settleTimeout)) != nil else { return }
                if !vitals.settled { publish(vitals.settledOnTimeout()) }
            }
    }

    private func publish(_ new: TodayVitals) {
        vitals = new
        onChange(new)
    }
}

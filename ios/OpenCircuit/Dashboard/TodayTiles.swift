// Today metric tiles (#216) — the model: turns a trends load into six tiles (HRV, resting HR,
// SpO₂, respiratory rate, skin temp, steps), each with its current value, a per-day series for the
// chart, and where the value sits against the user's own baseline. The Today grid builds it over
// the shared 14-day load; the per-metric detail chart builds it again over 14 or 30 days.
//
// Reads ONLY what `TrendsData` loaded from `LocalStore` (the same per-day rollups the Trends tab
// charts), plus the resting-HR series `TrendsData` derives with `RestingHR.dailyValues` — so a tile
// can never disagree with the Trends tab about the same day. Nothing is interpolated: a day without
// data is a gap in the chart, a metric without data says so.
//
// Which daily value each tile uses, and why:
//   HRV / SpO₂ / resp. rate — the OVERNIGHT average (`sleep*Avg`): the night is the one window the
//     ring samples consistently, so nights compare like-for-like; daytime values depend on activity.
//   Skin temp — the nightly value stored on the sleep summary (the Vitals Status source).
//   Resting HR — `RestingHR.dailyValues` over the window's HR (the Vitals Status derivation). A day
//     below `RestingHR.dayCoverage` has no value (#298), so before today has enough readings the
//     headline is the last day that has one, labelled with that day ("yesterday", "as of Mon 28").
//   Steps — today's running total as the headline; the TREND compares the last COMPLETE day, since
//     a partial day would always read "below usual" before evening. Its verdict is stated only when
//     that day is yesterday (`statedTrend`), and a line about yesterday under today's number names
//     the day and carries yesterday's own total (`deltaText`, #399).
//
// The "usual range" is `BaselineTrend.usualRange` — the same band that decides above / near / below —
// so the shaded band, its label and the arrow always agree.

import SwiftUI
import OpenCircuitKit

struct TodayTile: Identifiable {
    enum Metric: String, CaseIterable, Hashable {
        case hrv, restingHR, spo2, respiratoryRate, skinTemp, steps
    }

    let metric: Metric
    let title: String
    /// What the value is, in a few words ("overnight avg").
    let qualifier: String
    let icon: KeylineIcon
    let tint: Color
    /// Formatted current value, or nil when there's no data at all.
    let valueText: String?
    let unit: String
    /// The window's days, oldest first — the chart's x positions.
    let days: [Date]
    /// One slot per entry of `days`; nil = no data that day.
    let values: [Double?]
    /// The baseline comparison; nil when there's no data.
    let trend: BaselineTrend.Result?
    /// For steps, the trend is about yesterday, not today's partial total.
    let trendIsYesterday: Bool
    /// Day of the headline value.
    let valueDate: Date?
    /// Nightly metrics are keyed on the day the night ENDED (`SleepNightKey`), so "last night" is
    /// the one keyed today, and they say "last night" rather than "today".
    let isNightly: Bool
    /// Spoken form of the unit, for VoiceOver.
    let spokenUnit: String
    /// Formats a value in display units (no unit).
    let format: (Double) -> String
    /// Formats a signed difference in display units (no unit).
    let formatDelta: (Double) -> String

    var id: Metric { metric }

    // MARK: Display strings

    /// "last night" / "today" / "yesterday" / "as of Mon 28".
    func freshnessText(now: Date = Date(), calendar: Calendar = .current) -> String? {
        guard let valueDate else { return nil }
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let d = calendar.startOfDay(for: valueDate)
        if isNightly {
            return d >= today ? "last night" : "night to \(d.formatted(.dateTime.weekday(.abbreviated).day()))"
        }
        if d == today { return "today" }
        if d == yesterday { return "yesterday" }
        return "as of \(d.formatted(.dateTime.weekday(.abbreviated).day()))"
    }

    /// True when the headline value is older than the most recent day it could be from: for a
    /// nightly metric, anything but last night (keyed today); otherwise, older than yesterday.
    func isStale(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard let valueDate else { return false }
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? now
        return calendar.startOfDay(for: valueDate) < (isNightly ? today : yesterday)
    }

    /// The trend whose verdict the tile may state: the delta, its arrow, and VoiceOver's "above /
    /// within / below". nil while there's no judged baseline. Steps headline today's partial total
    /// but judge the last COMPLETE day, so they state a verdict only when that day is yesterday; an
    /// older day's verdict printed under today's number would read as a verdict on today.
    var statedTrend: BaselineTrend.Result? {
        guard let trend, trend.direction != nil else { return nil }
        return metric == .steps && !trendIsYesterday ? nil : trend
    }

    /// "+6 ms vs usual" / "Yesterday 7,375 · −625 vs usual" — nil when there's no verdict to state.
    var deltaText: String? {
        guard let trend = statedTrend, let d = trend.delta else { return nil }
        let unitPart = unit.isEmpty ? "" : " \(unit)"
        return Self.comparisonLine(valueDay: valueDate, judgedDay: trend.latest.date,
                                   judgedDayIsYesterday: trendIsYesterday,
                                   judgedValue: format(trend.latest.value) + unitPart,
                                   delta: formatDelta(d) + unitPart)
    }

    /// The rule for a tile's comparison line (#399): it is about the same day as the value above
    /// it. When the judged day is not the value's day (steps: today's running total over yesterday's
    /// verdict), the line names that day and carries its own figure, so "−625" never reads as a
    /// verdict on today's number. Days are start-of-day in the tile's calendar. nil when the judged
    /// day is neither the value's day nor yesterday: no line beats one about an unnamed day.
    static func comparisonLine(valueDay: Date?, judgedDay: Date, judgedDayIsYesterday: Bool,
                               judgedValue: String, delta: String) -> String? {
        let comparison = delta + " vs usual"
        if valueDay == judgedDay { return comparison }
        guard judgedDayIsYesterday else { return nil }
        return "Yesterday " + judgedValue + " · " + comparison
    }

    /// "Usual 44–50 ms", or the learning state while the baseline is thin.
    var rangeText: String {
        guard valueText != nil else { return "No data yet" }
        if let r = trend?.usualRange {
            return "Usual \(format(r.lowerBound))–\(format(r.upperBound))\(unit.isEmpty ? "" : " \(unit)")"
        }
        let need = BaselineTrend.defaultMinBaselineDays
        return "Learning your usual · \(min(trend?.baselineDays ?? 0, need))/\(need) days"
    }

    var accessibilityLabel: String {
        var parts = [title]
        if let valueText {
            parts.append("\(valueText) \(spokenUnit), \(qualifier)")
            if isStale(), let f = freshnessText() { parts.append(f) }
        } else {
            parts.append("no data yet")
        }
        if let trend = statedTrend, let direction = trend.direction, let d = trend.delta, let r = trend.usualRange {
            let who = valueDate != trend.latest.date ? "Yesterday was \(format(trend.latest.value)) \(spokenUnit),"
                : trendIsYesterday ? "Yesterday was" : "That's"
            let where_: String
            switch direction {
            case .above:  where_ = "above"
            case .within: where_ = "within"
            case .below:  where_ = "below"
            }
            parts.append("\(who) \(where_) your usual range of \(format(r.lowerBound)) to \(format(r.upperBound)) \(spokenUnit), \(formatDelta(d)) versus your average")
        } else if let r = trend?.usualRange {
            // A usual range, but no verdict to state about the headline (steps, yesterday missing).
            parts.append("Your usual range is \(format(r.lowerBound)) to \(format(r.upperBound)) \(spokenUnit)")
        } else if valueText != nil {
            parts.append("still learning your usual range")
        }
        parts.append("\(values.compactMap { $0 }.count) of the last \(values.count) days have data")
        return parts.joined(separator: ". ")
    }
}

enum TodayTiles {

    static let windowDays = TrendsData.lookbackDays

    /// Decision 29: which device each point belongs to, so a tile's "usual" compares the newest value
    /// only with the same device's earlier ones, and a device new to the person starts "Learning
    /// your usual". nil (the default, and every ring-only install): every point counts, as before.
    struct DeviceScope {
        let night: (Date) -> DeviceOwnershipLog.Family
        let day: (Date) -> DeviceOwnershipLog.Family

        /// The scope a trends load implies; nil when no switch is on record.
        static func from(_ trends: TrendsData) -> DeviceScope? {
            trends.ownership.isEmpty ? nil : DeviceScope(night: trends.nightOwner, day: trends.dayOwner)
        }

        /// `pts` from the newest point's device.
        static func sameDevice(_ pts: [BaselineTrend.Point], _ owner: ((Date) -> DeviceOwnershipLog.Family)?) -> [BaselineTrend.Point] {
            guard let owner, let newest = pts.max(by: { $0.date < $1.date }) else { return pts }
            let device = owner(newest.date)
            return pts.filter { owner($0.date) == device }
        }
    }

    /// Build all six tiles over the last `windowDays` days. `now`/`calendar` are injectable for
    /// tests and fixtures.
    static func build(points: [TrendsEngine.DailyPoint],
                      restingHR: [RestingHR.DailyValue],
                      tempUnit: TemperatureUnit,
                      windowDays: Int = windowDays,
                      now: Date = Date(),
                      calendar: Calendar = .current,
                      scope: DeviceScope? = nil) -> [TodayTile] {
        TodayTile.Metric.allCases.map {
            build($0, points: points, restingHR: restingHR, tempUnit: tempUnit,
                  windowDays: windowDays, now: now, calendar: calendar, scope: scope)
        }
    }

    /// Build one metric's tile.
    static func build(_ metric: TodayTile.Metric,
                      points: [TrendsEngine.DailyPoint],
                      restingHR: [RestingHR.DailyValue],
                      tempUnit: TemperatureUnit,
                      windowDays: Int = windowDays,
                      now: Date = Date(),
                      calendar: Calendar = .current,
                      scope: DeviceScope? = nil) -> TodayTile {
        let today = calendar.startOfDay(for: now)
        let days: [Date] = (0..<max(windowDays, 2)).reversed().compactMap {
            calendar.date(byAdding: .day, value: -$0, to: today)
        }
        let first = days.first ?? today
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today

        func series(_ pick: (TrendsEngine.DailyPoint) -> Double?) -> [BaselineTrend.Point] {
            let pts = points.compactMap { p -> BaselineTrend.Point? in
                guard let v = pick(p), v > 0, v.isFinite else { return nil }
                return BaselineTrend.Point(date: calendar.startOfDay(for: p.date), value: v)
            }
            .filter { $0.date >= first && $0.date <= today }
            return DeviceScope.sameDevice(pts, scope?.night)   // every series here is nightly
        }
        func slots(_ pts: [BaselineTrend.Point]) -> [Double?] {
            var byDay: [Date: Double] = [:]
            for p in pts { byDay[p.date] = p.value }
            return days.map { byDay[$0] }
        }

        let whole: (Double) -> String = { String(Int($0.rounded())) }
        let oneDecimal: (Double) -> String = { String(format: "%.1f", $0) }
        let signedWhole: (Double) -> String = { d in
            let r = Int(d.rounded()); return r > 0 ? "+\(r)" : r < 0 ? "−\(-r)" : "±0"
        }
        let signedOne: (Double) -> String = { d in
            let r = (d * 10).rounded() / 10
            return r > 0 ? String(format: "+%.1f", r) : r < 0 ? String(format: "−%.1f", -r) : "±0.0"
        }

        func nightly(_ title: String, _ qualifier: String, _ icon: KeylineIcon, _ tint: Color, _ unit: String,
                     spokenUnit: String, pts: [BaselineTrend.Point], floor: Double,
                     format: @escaping (Double) -> String, formatDelta: @escaping (Double) -> String,
                     isNightly: Bool = true) -> TodayTile {
            let trend = BaselineTrend.evaluate(pts, minAbsoluteDelta: floor)
            return TodayTile(metric: metric, title: title, qualifier: qualifier, icon: icon, tint: tint,
                             valueText: trend.map { format($0.latest.value) }, unit: unit,
                             days: days, values: slots(pts), trend: trend, trendIsYesterday: false,
                             valueDate: trend?.latest.date, isNightly: isNightly,
                             spokenUnit: spokenUnit, format: format, formatDelta: formatDelta)
        }

        switch metric {
        case .hrv:
            return nightly("HRV", "overnight avg", .activity, Theme.hrv, "ms", spokenUnit: "milliseconds",
                           pts: series(\.sleepHRVAvg), floor: 3, format: whole, formatDelta: signedWhole)
        case .restingHR:
            let pts = DeviceScope.sameDevice(restingHR
                .map { BaselineTrend.Point(date: calendar.startOfDay(for: $0.day), value: $0.bpm) }
                .filter { $0.value > 0 && $0.date >= first && $0.date <= today }, scope?.day)
            return nightly("Resting HR", "daily estimate", .heart, Theme.hr, "bpm", spokenUnit: "beats per minute",
                           pts: pts, floor: 2, format: whole, formatDelta: signedWhole, isNightly: false)
        case .spo2:
            return nightly("SpO₂", "overnight avg", .droplet, Theme.spo2, "%", spokenUnit: "percent",
                           pts: series { $0.sleepSpO2Avg.map { $0 * 100 } }, floor: 1,
                           format: whole, formatDelta: signedWhole)
        case .respiratoryRate:
            return nightly("Resp. rate", "overnight avg", .wind, Theme.rr, UnitsFormatter.respiratoryRateUnit,
                           spokenUnit: "breaths per minute", pts: series(\.sleepRRAvg), floor: 0.5,
                           format: oneDecimal, formatDelta: signedOne)
        case .skinTemp:
            // Converted to the user's unit BEFORE comparing, so the floor is in that unit too.
            let pts = series(\.skinTempC).map {
                BaselineTrend.Point(date: $0.date, value: tempUnit.convert(fromCelsius: $0.value))
            }
            return nightly("Skin temp", "overnight", .thermometer, Theme.temp, tempUnit.symbol,
                           spokenUnit: tempUnit == .fahrenheit ? "degrees Fahrenheit" : "degrees Celsius",
                           pts: pts, floor: tempUnit.convertDelta(fromCelsius: 0.3),
                           format: oneDecimal, formatDelta: signedOne)
        case .steps:
            // Headline = today's total; trend = the last complete day vs the days before it.
            // Steps are per day, not per night: their device is the day's owner (decision 29).
            let pts = DeviceScope.sameDevice(points.compactMap { p -> BaselineTrend.Point? in
                guard let v = p.steps.map(Double.init), v > 0, v.isFinite else { return nil }
                return BaselineTrend.Point(date: calendar.startOfDay(for: p.date), value: v)
            }
            .filter { $0.date >= first && $0.date <= today }, scope?.day)
            let trend = BaselineTrend.evaluate(pts.filter { $0.date < today }, minAbsoluteDelta: 1_000)
            let todaySteps = pts.first { $0.date == today }
            let headline = todaySteps ?? pts.max { $0.date < $1.date }
            let fmt: (Double) -> String = { Int($0.rounded()).formatted(.number) }
            let fmtDelta: (Double) -> String = { d in
                let r = Int(d.rounded())
                return r > 0 ? "+" + r.formatted(.number) : r < 0 ? "−" + (-r).formatted(.number) : "±0"
            }
            return TodayTile(metric: .steps, title: "Steps",
                             qualifier: todaySteps != nil ? "so far today" : "latest day",
                             icon: .route, tint: Theme.steps, valueText: headline.map { fmt($0.value) },
                             // Complete days only: today's still-growing total would plot as a cliff.
                             unit: "", days: days, values: slots(pts.filter { $0.date < today }), trend: trend,
                             trendIsYesterday: trend?.latest.date == yesterday,
                             valueDate: headline?.date, isNightly: false,
                             spokenUnit: "steps", format: fmt, formatDelta: fmtDelta)
        }
    }
}

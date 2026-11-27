// The Today synthesis line (#216): today's date at the top of the Today tab, and the inputs of the one
// plain-language sentence. The sentence is `TodaySynthesis.sentence` (OpenCircuitKit, unit-tested) and
// since decision 93 it sits inside Today's scores card, under the dials; this file only gathers its
// inputs from what the tab already holds, and draws the date.

import SwiftUI
import OpenCircuitKit

/// What Today's scores card is showing for Recovery, handed up so the synthesis line agrees with it.
struct ReadinessReport: Equatable {
    var readiness: TodaySynthesis.Readiness
    /// Last night's asleep minutes, when a night that ended today is stored.
    var lastNightAsleepMin: Int?
}

extension TodaySynthesis {
    /// Assemble the synthesis input from the Today tab's state.
    ///
    /// - `trends`: the shared two-week load (tiles are built from the same data).
    /// - `readiness`: what the scores card reported for Recovery; nil until it has.
    /// - `feverSuspected`: the Vitals Status card's own fever verdict; false until it has reported.
    ///   The only thing that lets this line pair skin temperature with resting HR as fever signs.
    /// - `lastSyncAt`: only used to tell "never had data" from "nothing in the last two weeks".
    static func input(trends: TrendsData, tiles: [TodayTile], readiness: ReadinessReport?,
                      feverSuspected: Bool = false, lastSyncAt: Date?, now: Date = Date()) -> Input {
        func direction(_ m: TodayTile.Metric) -> BaselineTrend.Direction? {
            guard let t = tiles.first(where: { $0.metric == m }), !t.isStale(now: now) else { return nil }
            return t.trend?.direction
        }
        // Usual sleep = the nights BEFORE the newest one, so last night isn't compared with itself, and
        // only the newest night's device's (decision 29; every night with an empty log).
        let scope = TodayTiles.DeviceScope.from(trends)
        let sleepPoints = trends.points.filter { ($0.sleepMinutes ?? 0) > 0 }
        let sameDevice = sleepPoints.last.map { newest in
            sleepPoints.filter { scope == nil || scope!.night($0.date) == scope!.night(newest.date) }
        } ?? []
        let nights = sameDevice.compactMap(\.sleepMinutes)
        let prior = nights.dropLast()
        let usualSleep = prior.isEmpty ? nil : Double(prior.reduce(0, +)) / Double(prior.count)
        // Nothing in the window but the app HAS synced before: the data is at least as old as the
        // window, which is exactly what the "more than two weeks old" wording says.
        let newest = trends.newestSampleAt
            ?? lastSyncAt.flatMap { _ in Calendar.current.date(byAdding: .day, value: -TrendsData.lookbackDays, to: now) }
        return Input(readiness: readiness?.readiness ?? .pending,
                     hrv: direction(.hrv), restingHR: direction(.restingHR), skinTemp: direction(.skinTemp),
                     feverSuspected: feverSuspected,
                     lastNightSleepMinutes: readiness?.lastNightAsleepMin, usualSleepMinutes: usualSleep,
                     newestDataAt: newest, now: now)
    }
}

/// Today's date above the scores card ("THURSDAY, NOVEMBER 26").
struct TodayDateRow: View {
    var date: Date = Date()

    var body: some View {
        Text(date.formatted(.dateTime.weekday(.wide).day().month(.wide)).uppercased())
            .font(.caption.weight(.semibold)).tracking(1.2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
            .accessibilityLabel("Today, \(date.formatted(.dateTime.weekday(.wide).day().month(.wide)))")
    }
}

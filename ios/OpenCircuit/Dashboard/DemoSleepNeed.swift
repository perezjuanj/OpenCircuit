// DEBUG SIMULATOR-ONLY (#382): a debt-heavy week plus a nap today, laid over the synthetic demo nights so
// the Sleep card's need line and its sheet can be reviewed by screenshot. Everything is generated here;
// none of it comes from a real wearer.
//
// `-OCDemoSleepNeed YES`, or `-OCDemoScreen sleep-need` (which also opens the sheet), shortens the seven
// most recent demo nights to 5 h 10 m ... 6 h 20 m asleep and adds a 40-minute nap that started after this
// morning's wake. Add `-sleepSchedule.enabled YES` for a schedule (bed 22:30, wake 06:30); without it the
// card shows need and debt but no bedtime.

#if DEBUG && targetEnvironment(simulator)
import SwiftData
import SwiftUI
import OpenCircuitKit

enum DemoSleepNeed {
    static var isRequested: Bool {
        let d = UserDefaults.standard
        return d.bool(forKey: "OCDemoSleepNeed") || d.string(forKey: "OCDemoScreen") == "sleep-need"
    }

    /// Asleep minutes for the seven most recent nights, oldest first.
    private static let week = [372, 330, 345, 310, 360, 335, 320]

    @MainActor
    static func applyIfRequested(_ context: ModelContext, now: Date) {
        guard DemoData.isRequested, isRequested else { return }
        var recent = FetchDescriptor<StoredSleepSummary>(sortBy: [SortDescriptor(\.night, order: .reverse)])
        recent.fetchLimit = week.count
        guard let rows = try? context.fetch(recent), rows.count == week.count else { return }
        for (row, asleep) in zip(rows.reversed(), week) {
            // The card's headline comes from the stage timeline when there is one, so drop it for these
            // nights and keep the stored minutes consistent with `asleepMin`.
            row.asleepMin = asleep
            row.deepMin = Int(Double(asleep) * 0.19)
            row.remMin = Int(Double(asleep) * 0.23)
            row.lightMin = asleep - row.deepMin - row.remMin
            row.awakeMin = max(0, Int(row.inBedEnd.timeIntervalSince(row.inBedStart) / 60) - asleep)
            row.hypnogramData = Data()
        }
        // A nap after this morning's wake and before now, so it counts toward today.
        if let wake = rows.first?.inBedEnd {
            let start = max(wake.addingTimeInterval(30 * 60), now.addingTimeInterval(-90 * 60))
            if start < now {
                context.insert(StoredNap(start: start, end: start.addingTimeInterval(45 * 60), asleepMin: 40))
            }
        }
        try? context.save()
    }
}

/// `-OCDemoScreen sleep-need`: the "How sleep need is worked out" sheet over the seeded demo week.
struct DemoSleepNeedSheet: View {
    @Query(sort: \StoredSleepSummary.night, order: .reverse) private var nights: [StoredSleepSummary]
    @Query private var naps: [StoredNap]
    @State private var result: (result: SleepNeed.Result, at: Date)?

    var body: some View {
        Group {
            if let result {
                SleepNeedView(result: result.result, computedAt: result.at)
            } else {
                ProgressView()
            }
        }
        .task(id: nights.count + naps.count) {
            let now = Date()
            result = (await SleepNeedAdapter.compute(nights: nights, naps: naps, now: now), now)
        }
    }
}
#endif

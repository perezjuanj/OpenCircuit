// WorkoutDetailContent.swift: what the workout history screens show, as pure functions (#293).
//
// The rule every function here keeps: a value the workout doesn't have is LEFT OUT, never shown as
// 0 or "--". A workout saved without heart rate has no heart-rate rows, no zones and no training
// load; one without a route has no distance, pace or map.
//
// No physiology of its own: zones are `HRZoneClassifier.timeInZonesHeld` with the workout's
// `TrainingLoad.zoneMaxHR`, and the load is `TrainingLoad.workoutLoad(hrSamples:age:sessionEnd:)`,
// exactly what the weekly load line scores the same workout with.

import Foundation
import HealthKit
import OpenCircuitKit

/// A pause or resume event on a saved workout (`HKWorkoutEvent`, reduced to what the arithmetic needs).
enum WorkoutPauseMarker: Equatable {
    case pause(Date)
    case resume(Date)

    var date: Date {
        switch self {
        case .pause(let d), .resume(let d): return d
        }
    }
}

enum WorkoutDetailContent {

    // MARK: Pauses

    /// The paused stretches: each pause up to the next resume. A pause never resumed lasts to the
    /// workout's end; a resume without a pause before it is ignored.
    static func pauses(_ markers: [WorkoutPauseMarker], end: Date) -> [DateInterval] {
        var result: [DateInterval] = []
        var openPause: Date?
        for marker in markers.sorted(by: { $0.date < $1.date }) {
            switch marker {
            case .pause(let d):
                if openPause == nil { openPause = d }
            case .resume(let d):
                if let start = openPause, d > start { result.append(DateInterval(start: start, end: d)) }
                openPause = nil
            }
        }
        if let start = openPause, end > start { result.append(DateInterval(start: start, end: end)) }
        return result
    }

    // MARK: Heart rate

    enum HeartRateSource: Equatable {
        /// Saved with the workout in Apple Health.
        case health
        /// None in Apple Health; OpenCircuit's own stored readings for the workout's window.
        case appHistory
        case none
    }

    /// Apple Health's heart rate for the workout when it has any; otherwise the app's stored readings
    /// inside the workout's window (asked for only then). Readings outside the window are dropped.
    static func heartRate(health: [HRSample], window: DateInterval,
                          appHistory: () -> [HRSample]) -> (samples: [HRSample], source: HeartRateSource) {
        let inWindow: (HRSample) -> Bool = { $0.start >= window.start && $0.start <= window.end && $0.bpm > 0 }
        let fromHealth = health.filter(inWindow)
        if !fromHealth.isEmpty { return (fromHealth.sorted { $0.start < $1.start }, .health) }
        let fromApp = appHistory().filter(inWindow)
        if !fromApp.isEmpty { return (fromApp.sorted { $0.start < $1.start }, .appHistory) }
        return ([], .none)
    }

    /// Time in each zone, or nil when no reading reached a zone (nothing to draw).
    static func zones(_ hr: [HRSample], age: Int, end: Date) -> WorkoutZoneBreakdown? {
        guard !hr.isEmpty else { return nil }
        let zones = HRZoneClassifier.timeInZonesHeld(hrSamples: hr, maxHR: TrainingLoad.zoneMaxHR(age: age),
                                                     sessionEnd: end)
        return zones.totalZoneSeconds > 0 ? zones : nil
    }

    // MARK: Device

    /// Which wearable recorded the workout. The strap's workouts name it (`HKDevice`, decision 11).
    /// The ring's are saved under the phone (`HKDevice.local()`), as is a strap workout saved before
    /// the strap had an identity, so for those the device that owned that time decides (decision 28).
    static func recordedWith(deviceName: String?, deviceManufacturer: String?,
                             owner: DeviceOwnershipLog.Family) -> String {
        if let name = deviceName, !name.isEmpty,
           let maker = deviceManufacturer, !maker.localizedCaseInsensitiveContains("apple") {
            return name
        }
        switch owner {
        case .ringConn: return "RingConn ring"
        case .zeppOS: return "Helio Strap"
        }
    }

    // MARK: Rows

    struct Row: Identifiable, Equatable {
        let title: String
        let value: String
        var caption: String?
        var id: String { title }
    }

    /// The summary rows, in order, holding only what the workout has.
    static func rows(_ item: WorkoutHistoryReader.Item, hr: [HRSample], age: Int,
                     unit: DistanceUnit, recordedWith: String) -> [Row] {
        var rows: [Row] = []
        let paused = item.pausedSeconds
        let moving = item.movingSeconds
        rows.append(Row(title: "Duration", value: duration(moving)))
        if paused >= 1 { rows.append(Row(title: "Paused", value: duration(paused))) }
        if let kcal = item.activeKcal, kcal > 0 {
            rows.append(Row(title: "Active energy", value: "\(Int(kcal.rounded())) kcal",
                            caption: "Estimated from heart rate or distance, not measured."))
        }
        if let avg = item.avgHR ?? mean(hr) { rows.append(Row(title: "Average heart rate", value: "\(avg) bpm")) }
        if let max = item.maxHR ?? hr.map(\.bpm).max() { rows.append(Row(title: "Maximum heart rate", value: "\(max) bpm")) }
        if let meters = item.distanceMeters, meters > 0 {
            rows.append(Row(title: "Distance", value: UnitsFormatter.distance(meters, unit: unit, fractionDigits: 2)))
            if let pace = paceOrSpeed(meters: meters, movingSeconds: moving,
                                      isCycling: item.activityType == .cycling, unit: unit) {
                rows.append(pace)
            }
        }
        if let load = TrainingLoad.workoutLoad(hrSamples: hr, age: age, sessionEnd: item.end) {
            rows.append(Row(title: "Training load", value: "\(Int(load.rounded()))",
                            caption: "Minutes in each heart-rate zone times the zone number (1 to 5)."))
        }
        rows.append(Row(title: "Recorded with", value: recordedWith))
        return rows
    }

    /// Average pace for foot sports, average speed for cycling, over the moving time.
    static func paceOrSpeed(meters: Double, movingSeconds: TimeInterval, isCycling: Bool,
                            unit: DistanceUnit) -> Row? {
        guard meters > 0, movingSeconds > 0 else { return nil }
        if isCycling {
            let perHour = unit == .metric ? meters / 1_000 : meters / 1_609.344
            let speed = perHour / (movingSeconds / 3600)
            return Row(title: "Average speed",
                       value: String(format: "%.1f %@", speed, unit == .metric ? "km/h" : "mph"))
        }
        return Row(title: "Average pace",
                   value: WorkoutTrainingMetricsSection.pace(meters / (movingSeconds / 60), unit: unit))
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let t = Int(seconds.rounded())
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        if h > 0 { return String(format: "%dh %02dm %02ds", h, m, s) }
        return String(format: "%dm %02ds", m, s)
    }

    private static func mean(_ hr: [HRSample]) -> Int? {
        guard !hr.isEmpty else { return nil }
        return Int((Double(hr.reduce(0) { $0 + $1.bpm }) / Double(hr.count)).rounded())
    }

    // MARK: History list

    struct MonthSection: Identifiable, Equatable {
        let month: Date
        let items: [WorkoutHistoryReader.Item]
        var id: Date { month }
    }

    /// The list's sections: one per calendar month, newest month first, newest workout first.
    static func monthSections(_ items: [WorkoutHistoryReader.Item],
                              calendar: Calendar = .current) -> [MonthSection] {
        let grouped = Dictionary(grouping: items) {
            calendar.dateInterval(of: .month, for: $0.start)?.start ?? $0.start
        }
        return grouped.keys.sorted(by: >).map { month in
            MonthSection(month: month, items: grouped[month]!.sorted { $0.start > $1.start })
        }
    }

    /// Append one page (fetched newest first, before the oldest item held) to the list.
    /// `reachedEnd` once a page comes back short: there is nothing older.
    static func appendPage(_ page: [WorkoutHistoryReader.Item], to items: [WorkoutHistoryReader.Item],
                           pageSize: Int) -> (items: [WorkoutHistoryReader.Item], reachedEnd: Bool) {
        let held = Set(items.map(\.id))
        let fresh = page.filter { !held.contains($0.id) }
        let merged = (items + fresh).sorted { $0.start > $1.start }
        return (merged, page.count < pageSize || fresh.isEmpty)
    }
}

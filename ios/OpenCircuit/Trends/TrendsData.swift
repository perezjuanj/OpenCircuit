// Shared trends data + reusable chart sections.
//
// Previously all ~18 daily-trend charts + the loader lived privately inside TrendsView. The tabbed
// UI distributes those charts across three tabs (Trends = all-day vitals, Sleep = sleep graphs,
// Activity = activity graphs), so the loader and the section views are extracted here and reused —
// one source of truth, so a Sleep-tab chart can never drift from the same metric on the Trends tab.
//
// Loading is a synchronous main-actor SwiftData read (ModelContext is already main-actor), the same
// as the original TrendsView.loadData; callers run it in `.task` and cache the result in @State.

import SwiftUI
import SwiftData
import OpenCircuitKit

// MARK: - Loaded data

/// The result of one trends load: per-day rollup points + the "recent readings" lists.
struct TrendsData {
    var points: [TrendsEngine.DailyPoint] = []
    var recentRows: [RecentMetricRow] = []

    static let lookbackDays = 14

    /// A per-metric "recent readings" list (newest first).
    struct RecentMetricRow: Identifiable {
        let metricKey: String
        let title: String
        let unit: String
        let color: Color
        let rows: [(time: Date, value: String)]
        var id: String { metricKey }
        var latest: (time: Date, value: String)? { rows.first }
    }

    // MARK: Sendable snapshot (so the heavy compute can run off the main actor)
    //
    // The SwiftData @Model rows can't cross actors, so `fetchInputs` extracts what the compute needs
    // into these value types on the main actor; `computePoints` then runs the per-day Calories loop on
    // a detached task, matching how Goals/Vitals/WellnessBalance cards avoid the scene-update watchdog.

    struct SleepRow: Sendable {
        let night: Date
        let asleepMin, sleepScore, stressScore: Int
        let skinTempC: Double
        let inBedStart, inBedEnd: Date
    }
    struct TempRow: Sendable { let time: Date; let celsius: Double }
    struct StepRow: Sendable { let start: Date; let end: Date; let delta: Int }

    struct Inputs: Sendable {
        var summaryByNight: [Date: SleepRow]
        var stepsByDay: [Date: Int]
        var hr, hrv, spo2, rr: [QuantitySample]
        var temps: [TempRow]
        var stepDeltas: [StepRow]
        var profile: UserProfile
        var tempUnitRaw: String
    }

    /// Load the last two weeks of trends. BOTH the fetch and the per-day rollup run off the main
    /// actor; only the cheap recent-readings rows (which build SwiftUI `Color`s) stay on main.
    ///
    /// 🟢 MEASURED 2026-08-14 on a real device (39,434 `StoredSample` rows): one call fetches
    /// **24,959 rows** over the 14-day window — daytime temps 8,988, HR 6,472, RR 3,648, HRV 2,530,
    /// SpO₂ 1,908, step deltas 1,413. That fetch used to run `@MainActor`, and `ContentView` drives
    /// it from three places (first `.task`, `scenePhase == .active`, and `syncing → false`), so a
    /// first open that also syncs paid ~75 k row materializations ON THE MAIN THREAD. That is the
    /// "app is extremely slow when you first open it and it syncs" report.
    ///
    /// `ModelContainer` is `Sendable`; the background `ModelContext` is created, used and destroyed
    /// entirely inside the detached task, and nothing but the `Sendable` `Inputs` snapshot crosses
    /// back — the same pattern `RollupBackup.exportBeforeWipe` already uses off the main context.
    /// The profile is read on the caller's actor (a handful of UserDefaults keys) and passed in, so
    /// the detached task touches nothing main-actor-isolated.
    ///
    /// One deliberate semantic change: a second context sees only what has been SAVED, not the main
    /// context's in-flight edits. That is correct for every caller here — `LocalStore.ingest`,
    /// `saveSleepSummary` and `applySleepEdit` all `context.save()` before returning, and the
    /// `.syncFinished` trigger fires after the commit — so nothing this reads can be stranded in an
    /// unsaved main-context change. A future caller that reloads trends mid-transaction would be
    /// the exception, and should save first rather than reach back onto the main actor.
    static func loadAsync(container: ModelContainer, tempUnitRaw: String) async -> TrendsData {
        let profile = await MainActor.run { HealthKitWriter.storedUserProfile() }
        let inputs = await Task.detached {
            fetchInputs(container: container, profile: profile, tempUnitRaw: tempUnitRaw)
        }.value
        let points = await Task.detached { computePoints(inputs) }.value
        let recentRows = await buildRecentMetricRows(inputs)
        return TrendsData(points: points, recentRows: recentRows)
    }

    /// Off-main fetch + extraction into the `Sendable` `Inputs` snapshot.
    ///
    /// Every descriptor comes from `LocalStore`'s `nonisolated static` builders — deliberately NOT
    /// hand-copied here — so this background read and the main-actor `LocalStore` methods can never
    /// diverge into fetching different row sets.
    nonisolated private static func fetchInputs(container: ModelContainer,
                                                profile: UserProfile,
                                                tempUnitRaw: String) -> Inputs {
        let context = ModelContext(container)
        let cal = Calendar.current
        let now = Date()
        let lookbackStart = cal.date(byAdding: .day, value: -lookbackDays, to: now) ?? now

        var summaryByNight: [Date: SleepRow] = [:]
        for s in (try? context.fetch(LocalStore.recentSleepSummariesDescriptor(limit: lookbackDays))) ?? [] {
            summaryByNight[cal.startOfDay(for: s.night)] = SleepRow(
                night: s.night, asleepMin: s.asleepMin, sleepScore: s.sleepScore,
                stressScore: s.stressScore, skinTempC: s.skinTempC,
                inBedStart: s.inBedStart, inBedEnd: s.inBedEnd)
        }
        var stepsByDay: [Date: Int] = [:]
        for d in (try? context.fetch(LocalStore.recentDailiesDescriptor(limit: lookbackDays))) ?? [] {
            stepsByDay[cal.startOfDay(for: d.day)] = d.steps
        }
        func samples(_ kind: MetricKind) -> [QuantitySample] {
            ((try? context.fetch(LocalStore.samplesDescriptor(kind: kind, from: lookbackStart, to: now))) ?? [])
                .compactMap(\.sample)
        }
        let temps = ((try? context.fetch(
            LocalStore.daytimeTemperaturesDescriptor(from: lookbackStart, to: now))) ?? [])
            .map { TempRow(time: $0.time, celsius: $0.celsius) }
        let stepDeltas = ((try? context.fetch(
            LocalStore.stepSamplesDescriptor(from: lookbackStart, to: now))) ?? [])
            .map { StepRow(start: $0.start, end: $0.end, delta: $0.delta) }
        return Inputs(summaryByNight: summaryByNight, stepsByDay: stepsByDay,
                      hr: samples(.heartRate), hrv: samples(.hrvSDNN),
                      spo2: samples(.spo2), rr: samples(.respiratoryRate),
                      temps: temps, stepDeltas: stepDeltas,
                      profile: profile, tempUnitRaw: tempUnitRaw)
    }

    /// Pure, off-main per-day rollup — the heavy loop (Calories.dailyEstimate × up to 14 days).
    nonisolated private static func computePoints(_ i: Inputs) -> [TrendsEngine.DailyPoint] {
        let cal = Calendar.current
        var daytimeTempsByDay: [Date: [Double]] = [:]
        for t in i.temps { daytimeTempsByDay[cal.startOfDay(for: t.time), default: []].append(t.celsius) }

        var vitalsDays: Set<Date> = []
        for s in i.hr + i.hrv + i.spo2 + i.rr { vitalsDays.insert(cal.startOfDay(for: s.start)) }
        let allDays = Set(i.summaryByNight.keys).union(i.stepsByDay.keys).union(vitalsDays)
            .union(daytimeTempsByDay.keys).sorted()

        return allDays.map { day -> TrendsEngine.DailyPoint in
            let s = i.summaryByNight[day]
            let window = (s?.inBedStart ?? .distantPast) > Date.distantPast
                ? DateInterval(start: s!.inBedStart, end: s!.inBedEnd) : nil
            let dayWindow = DateInterval(start: day, end: cal.date(byAdding: .day, value: 1, to: day) ?? day)

            func avg(_ samples: [QuantitySample], in w: DateInterval?, minVal: Double = 0) -> Double? {
                guard let w else { return nil }
                let vals = samples.filter { w.contains($0.start) && $0.value > minVal }.map(\.value)
                guard !vals.isEmpty else { return nil }
                return vals.reduce(0, +) / Double(vals.count)
            }

            let daySteps = i.stepsByDay[day]
            let dayHRSamples = i.hr.filter { dayWindow.contains($0.start) }
                .map { HRSample(bpm: Int($0.value), start: $0.start, end: $0.end) }
            // Per-snapshot step windows for THIS day, so active energy is attributed to when it was
            // earned (see `Calories.dailyEstimate`). A day with no step rows degrades to the
            // pre-attribution number automatically. NOTE: Trends recomputes history from stored
            // samples, so days that predate attribution now read higher here than the
            // activeEnergyBurned samples already sitting in Apple Health for those days —
            // `flushActiveCalories` only ever writes TODAY and never backfills. Trends is
            // internally consistent; Health keeps what it was given at the time.
            let dayStepWindows = i.stepDeltas
                .filter { $0.end >= day && $0.start < dayWindow.end }
                .map { StepWindow(start: $0.start, end: $0.end, delta: $0.delta) }
            let activityEstimate: Calories.DailyEstimate? =
                (daySteps != nil || !dayHRSamples.isEmpty)
                ? Calories.dailyEstimate(hrSamples: dayHRSamples, steps: daySteps ?? 0,
                                         profile: i.profile, sleepWindow: window,
                                         stepWindows: dayStepWindows, dayStart: day)
                : nil

            return TrendsEngine.DailyPoint(
                date:          day,
                steps:         daySteps,
                sleepMinutes:  (s?.asleepMin ?? 0) > 0 ? s?.asleepMin : nil,
                sleepScore:    (s?.sleepScore ?? 0) > 0 ? s?.sleepScore : nil,
                stressScore:   (s?.stressScore ?? 0) > 0 ? s?.stressScore : nil,
                skinTempC:     (s?.skinTempC ?? 0) > 0 ? s?.skinTempC : nil,
                dayTempC:      daytimeTempsByDay[day].flatMap { vals in
                    vals.isEmpty ? nil : vals.reduce(0, +) / Double(vals.count)
                },
                sleepHRAvg:    avg(i.hr, in: window, minVal: TrendsEngine.minValidHR),
                sleepHRVAvg:   avg(i.hrv, in: window),
                sleepSpO2Avg:  avg(i.spo2, in: window),
                sleepRRAvg:    avg(i.rr, in: window),
                dayHRAvg:      avg(i.hr, in: dayWindow, minVal: TrendsEngine.minValidHR),
                dayHRVAvg:     avg(i.hrv, in: dayWindow),
                daySpO2Avg:    avg(i.spo2, in: dayWindow),
                dayRRAvg:      avg(i.rr, in: dayWindow),
                activeEnergyKcal: activityEstimate?.activeKcal,
                distanceM:        daySteps.map { DistanceEstimate.meters(steps: $0) },
                exerciseMin:      activityEstimate?.elevatedMinutes
            )
        }
    }

    // MARK: Recent readings

    private static let recentRowsLimit = 12

    @MainActor
    private static func buildRecentMetricRows(_ i: Inputs) -> [RecentMetricRow] {
        let tempUnit = TemperatureUnit(rawValue: i.tempUnitRaw) ?? .celsius
        func recentRows(from samples: [QuantitySample], format: (QuantitySample) -> String) -> [(time: Date, value: String)] {
            Array(samples.suffix(recentRowsLimit).reversed()).map { (time: $0.start, value: format($0)) }
        }
        return [
            RecentMetricRow(metricKey: "steps", title: "Steps", unit: "", color: Theme.steps,
                rows: Array(i.stepDeltas.filter { $0.delta > 0 }.suffix(recentRowsLimit).reversed())
                    .map { (time: $0.end, value: "+\($0.delta) steps") }),
            RecentMetricRow(metricKey: "heartRate", title: "Heart Rate", unit: "bpm", color: Theme.hr,
                rows: recentRows(from: i.hr.filter { $0.value > TrendsEngine.minValidHR }) {
                    "\(Int($0.value.rounded())) bpm" }),
            RecentMetricRow(metricKey: "spo2", title: "SpO₂", unit: "%", color: Theme.spo2,
                rows: recentRows(from: i.spo2.filter { $0.value > 0 }) {
                    "\(Int(($0.value * 100).rounded())) %" }),
            RecentMetricRow(metricKey: "temperature", title: "Skin Temp", unit: tempUnit.symbol, color: Theme.temp,
                rows: Array(i.temps.filter { $0.celsius > 0 }.suffix(recentRowsLimit).reversed())
                    .map { (time: $0.time,
                            value: String(format: "%.1f \(tempUnit.symbol)", tempUnit.convert(fromCelsius: $0.celsius))) }),
            RecentMetricRow(metricKey: "hrv", title: "HRV", unit: "ms", color: Theme.hrv,
                rows: recentRows(from: i.hrv.filter { $0.value > 0 }) {
                    "\(Int($0.value.rounded())) ms" }),
            RecentMetricRow(metricKey: "rr", title: "Respiratory Rate", unit: UnitsFormatter.respiratoryRateUnit, color: Theme.rr,
                rows: recentRows(from: i.rr.filter { $0.value > 0 }) {
                    String(format: "%.1f \(UnitsFormatter.respiratoryRateUnit)", $0.value) })
        ].filter { !$0.rows.isEmpty }
    }
}

// MARK: - Reusable chart sections

/// All-day body vitals (HR / HRV / SpO₂ / RR / daytime skin temp) — the Trends tab's core.
struct AllDayVitalsSection: View {
    let points: [TrendsEngine.DailyPoint]
    let tempUnitRaw: String

    var body: some View {
        let avgs = TrendsEngine.rollingAverages(points)
        let tempUnit = TemperatureUnit(rawValue: tempUnitRaw) ?? .celsius
        VStack(spacing: 12) {
            MetricChartCard(title: "Heart Rate", unit: "bpm", color: Theme.hr,
                data: points.compactMap { p in p.dayHRAvg.flatMap { hr in hr > TrendsEngine.minValidHR ? (p.date, hr) : nil } },
                avg: avgs.dayHRAvg)
            MetricChartCard(title: "HRV (RMSSD est.)", unit: "ms", color: Theme.hrv,
                data: points.compactMap { p in p.dayHRVAvg.map { (p.date, $0) } },
                avg: avgs.dayHRVAvg)
            MetricChartCard(title: "SpO₂", unit: "%", color: Theme.spo2,
                data: points.compactMap { p in p.daySpO2Avg.map { (p.date, $0 * 100) } },
                avg: avgs.daySpO2Avg.map { $0 * 100 }, formatAvg: { String(format: "%.1f", $0) })
            MetricChartCard(title: "Respiratory Rate", unit: UnitsFormatter.respiratoryRateUnit, color: Theme.rr,
                data: points.compactMap { p in p.dayRRAvg.map { (p.date, $0) } },
                avg: avgs.dayRRAvg, formatAvg: { String(format: "%.1f", $0) })
            MetricChartCard(title: "Skin Temp (daytime)", unit: tempUnit.symbol, color: Theme.temp,
                data: points.compactMap { p in p.dayTempC.map { (p.date, tempUnit.convert(fromCelsius: $0)) } },
                avg: avgs.dayTempC.map { tempUnit.convert(fromCelsius: $0) }, formatAvg: { String(format: "%.1f", $0) })
        }
    }
}

/// Sleep graphs (score / stress / duration / nightly temp / sleep-window vitals) — the Sleep tab.
struct SleepTrendsSection: View {
    let points: [TrendsEngine.DailyPoint]
    let tempUnitRaw: String

    var body: some View {
        let avgs = TrendsEngine.rollingAverages(points)
        VStack(spacing: 12) {
            MetricChartCard(title: "Sleep Score", unit: "/100", color: Theme.sleep,
                data: points.compactMap { p in p.sleepScore.map { (p.date, Double($0)) } },
                avg: avgs.sleepScore)
            MetricChartCard(title: "Overnight Stress", unit: "/100", color: Theme.stress,
                data: points.compactMap { p in p.stressScore.map { (p.date, Double($0)) } },
                avg: avgs.stressScore)
            MetricChartCard(title: "Sleep Duration", unit: "h", color: Theme.accent,
                data: points.compactMap { p in p.sleepMinutes.map { (p.date, Double($0) / 60.0) } },
                avg: avgs.sleepMinutes.map { $0 / 60.0 }, formatAvg: { String(format: "%.1f", $0) })
            if avgs.skinTempC != nil {
                let tempUnit = TemperatureUnit(rawValue: tempUnitRaw) ?? .celsius
                MetricChartCard(title: "Skin Temp (nightly)", unit: tempUnit.symbol, color: Theme.temp,
                    data: points.compactMap { p in p.skinTempC.flatMap { t in t > 0 ? (p.date, tempUnit.convert(fromCelsius: t)) : nil } },
                    avg: avgs.skinTempC.map { tempUnit.convert(fromCelsius: $0) }, formatAvg: { String(format: "%.1f", $0) })
            }
            MetricChartCard(title: "Sleep-Window HR", unit: "bpm", color: Theme.hr,
                data: points.compactMap { p in p.sleepHRAvg.flatMap { hr in hr > TrendsEngine.minValidHR ? (p.date, hr) : nil } },
                avg: avgs.sleepHRAvg)
            MetricChartCard(title: "Sleep-Window HRV (RMSSD est.)", unit: "ms", color: Theme.hrv,
                data: points.compactMap { p in p.sleepHRVAvg.map { (p.date, $0) } },
                avg: avgs.sleepHRVAvg)
            MetricChartCard(title: "Sleep-Window SpO₂", unit: "%", color: Theme.spo2,
                data: points.compactMap { p in p.sleepSpO2Avg.map { (p.date, $0 * 100) } },
                avg: avgs.sleepSpO2Avg.map { $0 * 100 }, formatAvg: { String(format: "%.1f", $0) })
            MetricChartCard(title: "Sleep-Window RR", unit: UnitsFormatter.respiratoryRateUnit, color: Theme.rr,
                data: points.compactMap { p in p.sleepRRAvg.map { (p.date, $0) } },
                avg: avgs.sleepRRAvg, formatAvg: { String(format: "%.1f", $0) })
        }
    }
}

/// Activity graphs (steps / active energy / distance / exercise) — the Activity tab.
struct ActivityTrendsSection: View {
    let points: [TrendsEngine.DailyPoint]
    let distUnitRaw: String

    var body: some View {
        let avgs = TrendsEngine.rollingAverages(points)
        let distUnit = DistanceUnit(rawValue: distUnitRaw) ?? .metric
        VStack(spacing: 12) {
            MetricChartCard(title: "Daily Steps", unit: "", color: Theme.steps,
                data: points.compactMap { p in p.steps.map { (p.date, Double($0)) } },
                avg: avgs.steps, formatAvg: { "\(Int($0.rounded()).formatted())" }, clampsToData: false)
            MetricChartCard(title: "Active Energy (est.)", unit: "kcal", color: Theme.energy,
                data: points.compactMap { p in p.activeEnergyKcal.map { (p.date, $0) } },
                avg: avgs.activeEnergyKcal, clampsToData: false)
            MetricChartCard(title: "Distance (est.)", unit: distUnit.symbol, color: .indigo,
                data: points.compactMap { p in p.distanceM.map { (p.date, distUnit.convert(fromMeters: $0)) } },
                avg: avgs.distanceM.map { distUnit.convert(fromMeters: $0) }, formatAvg: { String(format: "%.1f", $0) }, clampsToData: false)
            MetricChartCard(title: "Exercise Time (est.)", unit: "min", color: .mint,
                data: points.compactMap { p in p.exerciseMin.map { (p.date, $0) } },
                avg: avgs.exerciseMin, clampsToData: false)
        }
    }
}

/// Recent per-metric readings list — the newest stored timestamped readings per metric.
struct RecentReadingsSection: View {
    let rows: [TrendsData.RecentMetricRow]

    var body: some View {
        VStack(spacing: 12) {
            ForEach(rows) { metric in
                card(metric)
            }
        }
    }

    private func card(_ metric: TrendsData.RecentMetricRow) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(metric.title.uppercased())
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    if let latest = metric.latest {
                        Text(latest.value).font(.title3.weight(.semibold)).foregroundStyle(metric.color)
                        Text(Self.timestamp.string(from: latest.time)).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("No readings").font(.subheadline).foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                if !metric.unit.isEmpty {
                    Text(metric.unit).font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                }
            }
            ForEach(Array(metric.rows.enumerated()), id: \.offset) { _, row in
                HStack {
                    Text(row.value).font(.subheadline.weight(.medium)).monospacedDigit()
                    Spacer()
                    Text(Self.timestamp.string(from: row.time)).font(.caption).foregroundStyle(.secondary)
                }
                if row.time != metric.rows.last?.time { Divider().opacity(0.3) }
            }
        }
        .ocCardSurface()
    }

    private static let timestamp: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
    }()
}

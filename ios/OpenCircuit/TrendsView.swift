// Rolling daily trends for every tracked metric (#74), plus a per-day time-of-day
// breakdown (`DayDetailView`, tap a day chip) for the continuously-monitored ones.
//
// SCOPE — AVAILABLE DATA ONLY.
// Shows trends for: all-day AND sleep-window HR / HRV / SpO₂ / RR, steps, active
// energy / distance / exercise minutes (estimates, same basis as HealthKitWriter),
// nightly AND daytime skin temp, sleep score, overnight stress score.
//
// All-day vitals use the SAME stored samples as the sleep-window figures, just over
// the whole calendar day rather than the night's in-bed window — HR is on every worn
// epoch (sleep AND activity), HRV/SpO₂/RR are on whichever epochs land .sleepVitals,
// which is not exclusively overnight (see BulkSleep.swift). Daytime skin temp comes
// from a SEPARATE table (`StoredDaytimeTemp`) kept apart from the nightly baseline and
// Apple Health — #41's guarantee (daytime readings must never skew the nightly
// cycle-tracking baseline) is unchanged; this is purely an additional, Trends-only view
// of the same live descriptor reads.
//
// Data loading: synchronous on-main-thread fetch from SwiftData (no background
// context needed; ModelContext is already main-actor). Computed in `.task` on
// first appearance and cached in @State.

import SwiftUI
import SwiftData
import Charts
import OpenCircuitKit

struct TrendsView: View {
    @Environment(\.scenePhase) private var scenePhase
    private struct RecentMetricRow: Identifiable {
        let metricKey: String
        let title: String
        let unit: String
        let color: Color
        let rows: [(time: Date, value: String)]

        var id: String { metricKey }
        var latest: (time: Date, value: String)? { rows.first }
    }

    @Environment(\.modelContext) private var modelContext
    @State private var points: [TrendsEngine.DailyPoint] = []
    @State private var recentMetricRows: [RecentMetricRow] = []
    @State private var loading = true
    // Display units (#83): values are stored in SI (°C, metres); only the display layer converts.
    @AppStorage("units.temperature") private var tempUnitRaw = TemperatureUnit.localeDefault.rawValue
    @AppStorage("units.distance") private var distUnitRaw = DistanceUnit.localeDefault.rawValue
    @State private var selectedDay: Date?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if loading {
                    ProgressView("Computing trends…")
                        .padding(.top, 40)
                } else if points.isEmpty {
                    emptyState
                } else {
                    availableMetricsNote
                    recentReadingsSection
                    dayPicker
                    let avgs = TrendsEngine.rollingAverages(points)
                    allDaySection(avgs: avgs)
                    sleepSection(avgs: avgs)
                    activitySection(avgs: avgs)
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Trends")
        .navigationDestination(item: $selectedDay) { day in DayDetailView(day: day) }
        .task { loadData() }
        .refreshable { loadData() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { loadData() }
        }
    }

    /// Tap a day to drill into its time-of-day breakdown (`DayDetailView`) — the bars above
    /// answer "how was this day on average"; this answers "WHEN during the day".
    private var dayPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(points.reversed(), id: \.date) { p in
                    Button { selectedDay = p.date } label: {
                        Text(p.date, format: .dateTime.weekday(.abbreviated).day())
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Capsule().fill(Color(.secondarySystemGroupedBackground)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Sections

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("No trend data yet")
                .font(.headline)
            Text("Sync from the ring a few times to build your history.")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 40)
    }

    private var availableMetricsNote: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            Text("Active Energy / Distance / Exercise Time are estimates derived from steps and heart rate, the same basis Apple Health writes use. Tap a day below to see a time-of-day breakdown.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
    }

    private var recentReadingsSection: some View {
        VStack(spacing: 12) {
            sectionHeader("Recent Readings")
            Text("Shows the newest stored timestamped readings per metric, including each step delta's own observation window.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(recentMetricRows) { metric in
                recentReadingsCard(metric)
            }
        }
    }

    private func allDaySection(avgs: TrendsEngine.RollingAverages) -> some View {
        VStack(spacing: 12) {
            sectionHeader("All-Day Vitals")

            chartCard(title: "Heart Rate", unit: "bpm",
                      color: .red,
                      data: points.compactMap { p in
                          p.dayHRAvg.flatMap { hr in hr > TrendsEngine.minValidHR ? (p.date, hr) : nil }
                      },
                      avg: avgs.dayHRAvg,
                      formatAvg: { "\(Int($0.rounded()))" })

            chartCard(title: "HRV (RMSSD est.)", unit: "ms",
                      color: .green,
                      data: points.compactMap { p in p.dayHRVAvg.map { (p.date, $0) } },
                      avg: avgs.dayHRVAvg,
                      formatAvg: { "\(Int($0.rounded()))" })

            chartCard(title: "SpO₂", unit: "%",
                      color: .cyan,
                      data: points.compactMap { p in p.daySpO2Avg.map { (p.date, $0 * 100) } },
                      avg: avgs.daySpO2Avg.map { $0 * 100 },
                      formatAvg: { String(format: "%.1f", $0) })

            chartCard(title: "Respiratory Rate", unit: UnitsFormatter.respiratoryRateUnit,
                      color: .teal,
                      data: points.compactMap { p in p.dayRRAvg.map { (p.date, $0) } },
                      avg: avgs.dayRRAvg,
                      formatAvg: { String(format: "%.1f", $0) })

            // Daytime skin temp is an absolute temperature — full convert (incl. +32 for °F), not
            // convertDelta (that's for the nightly baseline offset). Matches the nightly chart below.
            let tempUnit = TemperatureUnit(rawValue: tempUnitRaw) ?? .celsius
            chartCard(title: "Skin Temp (daytime)", unit: tempUnit.symbol,
                      color: .orange,
                      data: points.compactMap { p in p.dayTempC.map { (p.date, tempUnit.convert(fromCelsius: $0)) } },
                      avg: avgs.dayTempC.map { tempUnit.convert(fromCelsius: $0) },
                      formatAvg: { String(format: "%.1f", $0) })
        }
    }

    private func sleepSection(avgs: TrendsEngine.RollingAverages) -> some View {
        VStack(spacing: 12) {
            sectionHeader("Sleep")

            chartCard(title: "Sleep Score", unit: "/100",
                      color: .purple,
                      data: points.compactMap { p in p.sleepScore.map { (p.date, Double($0)) } },
                      avg: avgs.sleepScore,
                      formatAvg: { "\(Int($0.rounded()))" })

            chartCard(title: "Overnight Stress", unit: "/100",
                      color: .red,
                      data: points.compactMap { p in p.stressScore.map { (p.date, Double($0)) } },
                      avg: avgs.stressScore,
                      formatAvg: { "\(Int($0.rounded()))" })

            chartCard(title: "Sleep Duration", unit: "h",
                      color: .blue,
                      data: points.compactMap { p in
                          p.sleepMinutes.map { (p.date, Double($0) / 60.0) }
                      },
                      avg: avgs.sleepMinutes.map { $0 / 60.0 },
                      formatAvg: { String(format: "%.1f", $0) })

            if avgs.skinTempC != nil {
                // Absolute nightly temps → full conversion (`convert`, not `convertDelta`) into
                // the user's display unit; was hardcoded °C while Settings said °F (cf. #118).
                let tempUnit = TemperatureUnit(rawValue: tempUnitRaw) ?? .celsius
                chartCard(title: "Skin Temp (nightly)", unit: tempUnit.symbol,
                          color: .orange,
                          data: points.compactMap { p in
                              p.skinTempC.flatMap { t in
                                  t > 0 ? (p.date, tempUnit.convert(fromCelsius: t)) : nil
                              }
                          },
                          avg: avgs.skinTempC.map { tempUnit.convert(fromCelsius: $0) },
                          formatAvg: { String(format: "%.1f", $0) })
            }

            chartCard(title: "Sleep-Window HR", unit: "bpm",
                      color: .red,
                      data: points.compactMap { p in
                          p.sleepHRAvg.flatMap { hr in hr > TrendsEngine.minValidHR ? (p.date, hr) : nil }
                      },
                      avg: avgs.sleepHRAvg,
                      formatAvg: { "\(Int($0.rounded()))" })

            chartCard(title: "Sleep-Window HRV (RMSSD est.)", unit: "ms",
                      color: .green,
                      data: points.compactMap { p in p.sleepHRVAvg.map { (p.date, $0) } },
                      avg: avgs.sleepHRVAvg,
                      formatAvg: { "\(Int($0.rounded()))" })

            chartCard(title: "Sleep-Window SpO₂", unit: "%",
                      color: .cyan,
                      data: points.compactMap { p in p.sleepSpO2Avg.map { (p.date, $0 * 100) } },
                      avg: avgs.sleepSpO2Avg.map { $0 * 100 },
                      formatAvg: { String(format: "%.1f", $0) })

            chartCard(title: "Sleep-Window RR", unit: UnitsFormatter.respiratoryRateUnit,
                      color: .teal,
                      data: points.compactMap { p in p.sleepRRAvg.map { (p.date, $0) } },
                      avg: avgs.sleepRRAvg,
                      formatAvg: { String(format: "%.1f", $0) })
        }
    }

    private func activitySection(avgs: TrendsEngine.RollingAverages) -> some View {
        VStack(spacing: 12) {
            sectionHeader("Activity")
            chartCard(title: "Daily Steps", unit: "",
                      color: .green,
                      data: points.compactMap { p in p.steps.map { (p.date, Double($0)) } },
                      avg: avgs.steps,
                      formatAvg: { "\(Int($0.rounded()).formatted())" })

            chartCard(title: "Active Energy (est.)", unit: "kcal",
                      color: .orange,
                      data: points.compactMap { p in p.activeEnergyKcal.map { (p.date, $0) } },
                      avg: avgs.activeEnergyKcal,
                      formatAvg: { "\(Int($0.rounded()))" })

            let distUnit = DistanceUnit(rawValue: distUnitRaw) ?? .metric
            chartCard(title: "Distance (est.)", unit: distUnit.symbol,
                      color: .indigo,
                      data: points.compactMap { p in p.distanceM.map { (p.date, distUnit.convert(fromMeters: $0)) } },
                      avg: avgs.distanceM.map { distUnit.convert(fromMeters: $0) },
                      formatAvg: { String(format: "%.1f", $0) })

            chartCard(title: "Exercise Time (est.)", unit: "min",
                      color: .mint,
                      data: points.compactMap { p in p.exerciseMin.map { (p.date, $0) } },
                      avg: avgs.exerciseMin,
                      formatAvg: { "\(Int($0.rounded()))" })
        }
    }

    // MARK: - Chart card

    private func chartCard(
        title: String,
        unit: String,
        color: Color,
        data: [(Date, Double)],
        avg: Double?,
        formatAvg: (Double) -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let a = avg {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text("7d avg")
                            .font(.caption2).foregroundStyle(.tertiary)
                        Text("\(formatAvg(a))\(unit.isEmpty ? "" : " \(unit)")")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(color)
                    }
                }
            }
            if data.isEmpty {
                Text("No data in last 7 days")
                    .font(.caption).foregroundStyle(.tertiary)
                    .frame(height: 70, alignment: .center)
                    .frame(maxWidth: .infinity)
            } else {
                Chart(data, id: \.0) { (date, value) in
                    LineMark(
                        x: .value("Day", date, unit: .day),
                        y: .value(title, value)
                    )
                    .foregroundStyle(color)
                    .interpolationMethod(.catmullRom)
                    PointMark(
                        x: .value("Day", date, unit: .day),
                        y: .value(title, value)
                    )
                    .foregroundStyle(color)
                    .symbolSize(24)
                }
                .frame(height: 80)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day)) { v in
                        AxisValueLabel(format: .dateTime.weekday(.narrow))
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { _ in
                        AxisGridLine()
                        AxisValueLabel()
                    }
                }
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16)
            .fill(Color(.secondarySystemGroupedBackground)))
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func recentReadingsCard(_ metric: RecentMetricRow) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(metric.title.uppercased())
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if let latest = metric.latest {
                        Text(latest.value)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(metric.color)
                        Text(Self.recentTimestamp.string(from: latest.time))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No readings")
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                if !metric.unit.isEmpty {
                    Text(metric.unit)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }

            if metric.rows.isEmpty {
                Text("No readings in the recent lookback window")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(Array(metric.rows.enumerated()), id: \.offset) { _, row in
                    HStack {
                        Text(row.value)
                            .font(.subheadline.weight(.medium))
                            .monospacedDigit()
                        Spacer()
                        Text(Self.recentTimestamp.string(from: row.time))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if row.time != metric.rows.last?.time {
                        Divider().opacity(0.3)
                    }
                }
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16)
            .fill(Color(.secondarySystemGroupedBackground)))
    }

    // MARK: - Data loading

    @MainActor
    private func loadData() {
        let store = LocalStore(modelContext)
        let lookbackDays = 14
        let cal = Calendar.current
        let now = Date()
        let lookbackStart = cal.date(byAdding: .day, value: -lookbackDays, to: now) ?? now

        // Fetch sleep summaries (latest first → reverse for oldest-first points)
        let summaries = (try? store.recentSleepSummaries(limit: lookbackDays)) ?? []

        // Fetch daily step rollups (latest first)
        let dailies = (try? store.recentDailies(limit: lookbackDays)) ?? []
        var stepsByDay: [Date: Int] = [:]
        for d in dailies { stepsByDay[cal.startOfDay(for: d.day)] = d.steps }

        // Index summaries by start-of-day night.
        var summaryByNight: [Date: StoredSleepSummary] = [:]
        for s in summaries { summaryByNight[cal.startOfDay(for: s.night)] = s }

        // Pre-fetch all sleep-window vitals samples from the lookback window (one query per kind)
        // then filter per-night in memory — avoids N×4 queries.
        let hrSamples   = (try? store.samples(kind: .heartRate,       from: lookbackStart, to: now)) ?? []
        let hrvSamples  = (try? store.samples(kind: .hrvSDNN,         from: lookbackStart, to: now)) ?? []
        let spo2Samples = (try? store.samples(kind: .spo2,            from: lookbackStart, to: now)) ?? []
        let rrSamples   = (try? store.samples(kind: .respiratoryRate, from: lookbackStart, to: now)) ?? []
        let daytimeTemps = (try? store.daytimeTemperatures(from: lookbackStart, to: now)) ?? []
        let stepSamples = (try? store.stepSamples(from: lookbackStart, to: now)) ?? []
        recentMetricRows = buildRecentMetricRows(
            hrSamples: hrSamples,
            hrvSamples: hrvSamples,
            spo2Samples: spo2Samples,
            rrSamples: rrSamples,
            daytimeTemps: daytimeTemps,
            stepSamples: stepSamples
        )
        var daytimeTempsByDay: [Date: [Double]] = [:]
        for t in daytimeTemps { daytimeTempsByDay[cal.startOfDay(for: t.time), default: []].append(t.celsius) }

        // Profile for the same step/HR-derived activity ESTIMATES HealthKitWriter writes
        // (active energy, distance, exercise minutes) — so the trend matches Apple Health.
        let profile = HealthKitWriter.storedUserProfile()
        let maxHR = max(220 - profile.age, 1)

        // Build one point per day across the UNION of sleep-summary nights, daily-step days,
        // and any day with a vitals sample — so a chart renders even on a day with no overnight
        // sleep summary and no step rollup (e.g. only a couple of live HR readings). All keys
        // are start-of-day, so they align.
        var vitalsDays: Set<Date> = []
        for s in hrSamples + hrvSamples + spo2Samples + rrSamples {
            vitalsDays.insert(cal.startOfDay(for: s.start))
        }
        let allDays = Set(summaryByNight.keys).union(stepsByDay.keys).union(vitalsDays)
            .union(daytimeTempsByDay.keys).sorted()
        points = allDays.map { day in
            let s = summaryByNight[day]
            let window = (s?.inBedStart ?? .distantPast) > Date.distantPast
                ? DateInterval(start: s!.inBedStart, end: s!.inBedEnd) : nil
            let dayWindow = DateInterval(start: day, end: cal.date(byAdding: .day, value: 1, to: day) ?? day)

            func avg(_ samples: [QuantitySample], in w: DateInterval?, minVal: Double = 0) -> Double? {
                guard let w else { return nil }
                let vals = samples
                    .filter { w.contains($0.start) && $0.value > minVal }
                    .map(\.value)
                guard !vals.isEmpty else { return nil }
                return vals.reduce(0, +) / Double(vals.count)
            }

            let daySteps = stepsByDay[day]
            let dayHRSamples = hrSamples.filter { dayWindow.contains($0.start) }
                .map { HRSample(bpm: Int($0.value), start: $0.start, end: $0.end) }

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
                sleepHRAvg:    avg(hrSamples, in: window, minVal: TrendsEngine.minValidHR),
                sleepHRVAvg:   avg(hrvSamples, in: window),
                sleepSpO2Avg:  avg(spo2Samples, in: window),
                sleepRRAvg:    avg(rrSamples, in: window),
                dayHRAvg:      avg(hrSamples, in: dayWindow, minVal: TrendsEngine.minValidHR),
                dayHRVAvg:     avg(hrvSamples, in: dayWindow),
                daySpO2Avg:    avg(spo2Samples, in: dayWindow),
                dayRRAvg:      avg(rrSamples, in: dayWindow),
                activeEnergyKcal: daySteps.map { Calories.activeKcalFromSteps(steps: $0, profile: profile) },
                distanceM:        daySteps.map { DistanceEstimate.meters(steps: $0) },
                exerciseMin:      dayHRSamples.isEmpty ? nil : ExerciseMinutes.estimate(
                    hrSamples: dayHRSamples, maxHR: maxHR, sleepWindow: window
                )
            )
        }

        loading = false
    }

    private func buildRecentMetricRows(
        hrSamples: [QuantitySample],
        hrvSamples: [QuantitySample],
        spo2Samples: [QuantitySample],
        rrSamples: [QuantitySample],
        daytimeTemps: [StoredDaytimeTemp],
        stepSamples: [StoredStepSample]
    ) -> [RecentMetricRow] {
        let tempUnit = TemperatureUnit(rawValue: tempUnitRaw) ?? .celsius
        return [
            RecentMetricRow(
                metricKey: "steps",
                title: "Steps",
                unit: "",
                color: .mint,
                rows: Array(stepSamples
                    .filter { $0.delta > 0 }
                    .suffix(Self.recentRowsLimit)
                    .reversed())
                    .map { (time: $0.end, value: "+\($0.delta) steps") }
            ),
            RecentMetricRow(
                metricKey: "heartRate",
                title: "Heart Rate",
                unit: "bpm",
                color: .red,
                rows: recentRows(from: hrSamples.filter { $0.value > TrendsEngine.minValidHR }) {
                    "\(Int($0.value.rounded())) bpm"
                }
            ),
            RecentMetricRow(
                metricKey: "spo2",
                title: "SpO₂",
                unit: "%",
                color: .cyan,
                rows: recentRows(from: spo2Samples.filter { $0.value > 0 }) {
                    "\(Int(($0.value * 100).rounded())) %"
                }
            ),
            RecentMetricRow(
                metricKey: "temperature",
                title: "Skin Temp",
                unit: tempUnit.symbol,
                color: .orange,
                rows: Array(daytimeTemps
                    .filter { $0.celsius > 0 }
                    .suffix(Self.recentRowsLimit)
                    .reversed())
                    .map { (time: $0.time,
                            value: String(format: "%.1f \(tempUnit.symbol)", tempUnit.convert(fromCelsius: $0.celsius))) }
            ),
            RecentMetricRow(
                metricKey: "hrv",
                title: "HRV",
                unit: "ms",
                color: .green,
                rows: recentRows(from: hrvSamples.filter { $0.value > 0 }) {
                    "\(Int($0.value.rounded())) ms"
                }
            ),
            RecentMetricRow(
                metricKey: "rr",
                title: "Respiratory Rate",
                unit: UnitsFormatter.respiratoryRateUnit,
                color: .teal,
                rows: recentRows(from: rrSamples.filter { $0.value > 0 }) {
                    String(format: "%.1f \(UnitsFormatter.respiratoryRateUnit)", $0.value)
                }
            )
        ]
        .filter { !$0.rows.isEmpty }
    }

    private func recentRows(
        from samples: [QuantitySample],
        format: (QuantitySample) -> String
    ) -> [(time: Date, value: String)] {
        Array(samples.suffix(Self.recentRowsLimit).reversed())
            .map { (time: $0.start, value: format($0)) }
    }

    private static let recentRowsLimit = 12
    private static let recentTimestamp: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}

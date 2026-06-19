// 7-day rolling trends for available decoded metrics (#74).
//
// SCOPE — AVAILABLE DATA ONLY.
// Shows trends for: sleep-window HR / HRV / SpO₂ / RR, steps, nightly skin temp,
// sleep score, overnight stress score.
//
// ⚠️ Daytime/waking HR, HRV, SpO₂ aggregates are NOT shown — they need the
// undecoded activity-epoch [15:22] payload (#93). When that decode lands, those
// aggregates extend this view. Do NOT add daytime vitals charts here yet.
//
// Data loading: synchronous on-main-thread fetch from SwiftData (no background
// context needed; ModelContext is already main-actor). Computed in `.task` on
// first appearance and cached in @State.

import SwiftUI
import SwiftData
import Charts
import OpenCircuitKit

struct TrendsView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var points: [TrendsEngine.DailyPoint] = []
    @State private var loading = true

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
                    let avgs = TrendsEngine.rollingAverages(points)
                    sleepSection(avgs: avgs)
                    activitySection(avgs: avgs)
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("7-Day Trends")
        .task { loadData() }
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
            Text("Showing sleep-window vitals only. Daytime HR/HRV/SpO₂ trends follow the ring activity-payload decode (#93).")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
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
                chartCard(title: "Skin Temp (nightly)", unit: "°C",
                          color: .orange,
                          data: points.compactMap { p in
                              p.skinTempC.flatMap { t in t > 0 ? (p.date, t) : nil }
                          },
                          avg: avgs.skinTempC,
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

            chartCard(title: "Sleep-Window RR", unit: "brpm",
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
                    BarMark(
                        x: .value("Day", date, unit: .day),
                        y: .value(title, value)
                    )
                    .foregroundStyle(color.gradient)
                    .cornerRadius(3)
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

        // Build one point per day across the UNION of sleep-summary nights and daily-step days,
        // so the Activity/Steps chart renders from step history even on days with no overnight
        // sleep summary (e.g. the user wore the ring by day but not to bed). Both keys are
        // start-of-day, so they align.
        let allDays = Set(summaryByNight.keys).union(stepsByDay.keys).sorted()
        points = allDays.map { day in
            let s = summaryByNight[day]
            let window = (s?.inBedStart ?? .distantPast) > Date.distantPast
                ? DateInterval(start: s!.inBedStart, end: s!.inBedEnd) : nil

            func avg(_ samples: [QuantitySample], minVal: Double = 0) -> Double? {
                guard let w = window else { return nil }
                let vals = samples
                    .filter { w.contains($0.start) && $0.value > minVal }
                    .map(\.value)
                guard !vals.isEmpty else { return nil }
                return vals.reduce(0, +) / Double(vals.count)
            }

            return TrendsEngine.DailyPoint(
                date:          day,
                steps:         stepsByDay[day],
                sleepMinutes:  (s?.asleepMin ?? 0) > 0 ? s?.asleepMin : nil,
                sleepScore:    (s?.sleepScore ?? 0) > 0 ? s?.sleepScore : nil,
                stressScore:   (s?.stressScore ?? 0) > 0 ? s?.stressScore : nil,
                skinTempC:     (s?.skinTempC ?? 0) > 0 ? s?.skinTempC : nil,
                sleepHRAvg:    avg(hrSamples, minVal: TrendsEngine.minValidHR),
                sleepHRVAvg:   avg(hrvSamples),
                sleepSpO2Avg:  avg(spo2Samples),
                sleepRRAvg:    avg(rrSamples)
            )
        }

        loading = false
    }
}

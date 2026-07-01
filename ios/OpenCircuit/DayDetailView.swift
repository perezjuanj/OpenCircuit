// Intraday (time-of-day) breakdown for one calendar day (#74 follow-up).
//
// The daily Trends bars answer "how was this day, on average" — this view answers
// "WHEN during the day was each metric at what level": a true time-series, x-axis is
// the actual sample timestamp (not bucketed to a day), so HR/SpO2/HRV/RR/steps can be
// read off at any time of day. The night's in-bed window (if any) is shaded for
// context, since a dip often lines up with sleep rather than anything daytime.
//
// SCOPE — same samples already shown elsewhere; no new decode, no invented levels.
// The only "level" cue is each metric's own day average as a reference line — not a
// fabricated clinical threshold.

import SwiftUI
import SwiftData
import Charts
import OpenCircuitKit

struct DayDetailView: View {
    let day: Date
    @Environment(\.modelContext) private var modelContext
    @State private var hrSamples: [QuantitySample] = []
    @State private var hrvSamples: [QuantitySample] = []
    @State private var spo2Samples: [QuantitySample] = []
    @State private var rrSamples: [QuantitySample] = []
    @State private var daytimeTemps: [QuantitySample] = []
    @State private var stepsTotal: Int?
    @State private var stepSamples: [StoredStepSample] = []
    @State private var nightWindow: DateInterval?
    @State private var loading = true

    private static let dayTitle: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEEE, MMM d"; return f
    }()

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if loading {
                    ProgressView("Loading…").padding(.top, 40)
                } else if hrSamples.isEmpty && hrvSamples.isEmpty && spo2Samples.isEmpty
                    && rrSamples.isEmpty && daytimeTemps.isEmpty && stepsTotal == nil {
                    emptyState
                } else {
                    timeSeriesCard(title: "Heart Rate", unit: "bpm", color: .red,
                                  samples: hrSamples, minVal: TrendsEngine.minValidHR)
                    timeSeriesCard(title: "HRV (RMSSD est.)", unit: "ms", color: .green,
                                  samples: hrvSamples)
                    timeSeriesCard(title: "SpO₂", unit: "%", color: .cyan,
                                  samples: spo2Samples, scale: 100)
                    timeSeriesCard(title: "Respiratory Rate", unit: "brpm", color: .teal,
                                  samples: rrSamples)
                    timeSeriesCard(title: "Skin Temp", unit: "°C", color: .orange,
                                  samples: daytimeTemps)
                    stepsChartCard()
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(Self.dayTitle.string(from: day))
        .navigationBarTitleDisplayMode(.inline)
        .task { loadData() }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 44)).foregroundStyle(.secondary)
            Text("No readings this day").font(.headline)
        }
        .padding(.top, 40)
    }

    @ViewBuilder
    private func timeSeriesCard(
        title: String, unit: String, color: Color,
        samples: [QuantitySample], minVal: Double = 0, scale: Double = 1
    ) -> some View {
        let points = samples
            .filter { $0.value > minVal }
            .map { (time: $0.start, value: $0.value * scale) }
            .sorted { $0.time < $1.time }

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if let avg = points.isEmpty ? nil : points.map(\.value).reduce(0, +) / Double(points.count) {
                    Text("avg \(String(format: "%.1f", avg))\(unit.isEmpty ? "" : " \(unit)")")
                        .font(.caption.weight(.semibold)).foregroundStyle(color)
                }
            }
            if points.isEmpty {
                Text("No readings this day")
                    .font(.caption).foregroundStyle(.tertiary)
                    .frame(height: 90, alignment: .center)
                    .frame(maxWidth: .infinity)
            } else {
                Chart {
                    if let window = nightWindow {
                        RectangleMark(
                            xStart: .value("Sleep start", window.start),
                            xEnd: .value("Sleep end", window.end)
                        )
                        .foregroundStyle(Color.indigo.opacity(0.08))
                    }
                    ForEach(points, id: \.time) { p in
                        LineMark(x: .value("Time", p.time), y: .value(title, p.value))
                            .foregroundStyle(color)
                        PointMark(x: .value("Time", p.time), y: .value(title, p.value))
                            .foregroundStyle(color)
                            .symbolSize(18)
                    }
                }
                .frame(height: 90)
                .chartXScale(domain: day...(Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day))
                .chartXAxis {
                    AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.hour())
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

    /// Bucket timestamped step deltas to the hour each reading LANDED in (`end`), summed — each
    /// `StoredStepSample`'s own narrow `start`/`end` window is real (see `RingSession`), but
    /// bucketing to the hour keeps the chart readable rather than plotting one sliver per
    /// ~30-60 s descriptor poll.
    private func hourlyStepBuckets() -> [(hour: Date, steps: Int)] {
        let cal = Calendar.current
        var buckets: [Date: Int] = [:]
        for s in stepSamples where s.delta > 0 {
            let hour = cal.date(from: cal.dateComponents([.year, .month, .day, .hour], from: s.end)) ?? s.end
            buckets[hour, default: 0] += s.delta
        }
        return buckets.sorted { $0.key < $1.key }.map { (hour: $0.key, steps: $0.value) }
    }

    /// Steps as an hourly BAR chart (#steps-history) — a count metric reads naturally as bars
    /// (matching Apple Health's own Steps presentation), unlike the continuous line+point series
    /// the other vitals use above.
    @ViewBuilder
    private func stepsChartCard() -> some View {
        let points = hourlyStepBuckets()

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("STEPS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if let stepsTotal {
                    Text("\(stepsTotal) total")
                        .font(.caption.weight(.semibold)).foregroundStyle(.green)
                }
            }
            if points.isEmpty {
                Text("No readings this day")
                    .font(.caption).foregroundStyle(.tertiary)
                    .frame(height: 90, alignment: .center)
                    .frame(maxWidth: .infinity)
            } else {
                Chart {
                    if let window = nightWindow {
                        RectangleMark(
                            xStart: .value("Sleep start", window.start),
                            xEnd: .value("Sleep end", window.end)
                        )
                        .foregroundStyle(Color.indigo.opacity(0.08))
                    }
                    ForEach(points, id: \.hour) { hour, steps in
                        BarMark(x: .value("Hour", hour, unit: .hour), y: .value("Steps", steps))
                            .foregroundStyle(.green)
                    }
                }
                .frame(height: 90)
                .chartXScale(domain: day...(Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day))
                .chartXAxis {
                    AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.hour())
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

    @MainActor
    private func loadData() {
        let store = LocalStore(modelContext)
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: day)
        let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart

        hrSamples   = (try? store.samples(kind: .heartRate,       from: dayStart, to: dayEnd)) ?? []
        hrvSamples  = (try? store.samples(kind: .hrvSDNN,         from: dayStart, to: dayEnd)) ?? []
        spo2Samples = (try? store.samples(kind: .spo2,            from: dayStart, to: dayEnd)) ?? []
        rrSamples   = (try? store.samples(kind: .respiratoryRate, from: dayStart, to: dayEnd)) ?? []
        daytimeTemps = ((try? store.daytimeTemperatures(from: dayStart, to: dayEnd)) ?? [])
            .map { QuantitySample(kind: .temperature, start: $0.time, value: $0.celsius) }

        let dailies = (try? store.recentDailies(limit: 60)) ?? []
        stepsTotal = dailies.first { cal.isDate($0.day, inSameDayAs: dayStart) }?.steps
        stepSamples = (try? store.stepSamples(from: dayStart, to: dayEnd)) ?? []

        // Shade the night's in-bed window if this day is (or starts) a stored sleep night.
        let summaries = (try? store.recentSleepSummaries(limit: 60)) ?? []
        if let s = summaries.first(where: { cal.isDate($0.night, inSameDayAs: dayStart) }),
           s.inBedEnd > s.inBedStart {
            nightWindow = DateInterval(start: s.inBedStart, end: s.inBedEnd)
        }

        loading = false
    }
}

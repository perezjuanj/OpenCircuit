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
    // Display unit for skin temp: stored samples are °C, the chart converts (matches TrendsView #83).
    @AppStorage("units.temperature") private var tempUnitRaw = TemperatureUnit.localeDefault.rawValue

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
                    timeSeriesCard(title: "Respiratory Rate", unit: UnitsFormatter.respiratoryRateUnit,
                                  color: .teal, samples: rrSamples)
                    // Convert in the body (not at load) so switching the unit re-renders live; the
                    // card's `scale` is multiply-only and °F needs an offset, so convert upstream here.
                    let tempUnit = TemperatureUnit(rawValue: tempUnitRaw) ?? .celsius
                    timeSeriesCard(title: "Skin Temp", unit: tempUnit.symbol, color: .orange,
                                  samples: daytimeTemps.map {
                                      QuantitySample(kind: .temperature, start: $0.start,
                                                     value: tempUnit.convert(fromCelsius: $0.value))
                                  })
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

    /// The day's [start, start+1d) window — the fixed x-domain every intraday chart is scaled to.
    private var dayDomain: ClosedRange<Date> {
        let end = Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day
        return day...end
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
        IntradayChartCard(title: title, unit: unit, color: color, points: points,
                          domain: dayDomain, nightWindow: nightWindow)
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
    /// (matching Apple Health's own Steps presentation), unlike the continuous line series the other
    /// vitals use above.
    @ViewBuilder
    private func stepsChartCard() -> some View {
        IntradayStepsCard(buckets: hourlyStepBuckets(), total: stepsTotal,
                          domain: dayDomain, nightWindow: nightWindow)
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

// MARK: - Intraday cards

/// One intraday vital as a smooth, gradient-filled time series over a single day. Replaces the old
/// dense line+point cloud (a point per ~minute sample was unreadable): the line alone shows the
/// shape, and touch-to-scrub reads the exact value/time at any moment. The night in-bed window is
/// shaded but CLAMPED to the day's domain so it can't run off the right edge, and the plot is
/// clipped so nothing bleeds past the axes.
private struct IntradayChartCard: View {
    let title: String
    let unit: String
    let color: Color
    /// (time, value) sorted oldest→newest, already unit-converted.
    let points: [(time: Date, value: Double)]
    let domain: ClosedRange<Date>
    let nightWindow: DateInterval?

    @State private var selected: Date?

    private var average: Double? {
        points.isEmpty ? nil : points.map(\.value).reduce(0, +) / Double(points.count)
    }

    /// Clamp the y-axis to the data (+15% padding) so a tight vital isn't flattened by a 0 baseline.
    private var yDomain: ClosedRange<Double> {
        guard let lo = points.map(\.value).min(), let hi = points.map(\.value).max() else {
            return 0...1
        }
        if lo == hi { return (lo - 1)...(hi + 1) }
        let pad = (hi - lo) * 0.15
        return (lo - pad)...(hi + pad)
    }

    private var areaFloor: Double { yDomain.lowerBound }

    /// Night band, clamped to this day's window so a sleep window that crosses midnight can't draw
    /// past the right axis (the reported "blue shade runs off the right").
    private var clampedNight: (start: Date, end: Date)? {
        guard let w = nightWindow else { return nil }
        let s = max(w.start, domain.lowerBound)
        let e = min(w.end, domain.upperBound)
        return e > s ? (s, e) : nil
    }

    private var selectedPoint: (time: Date, value: Double)? {
        guard let selected else { return nil }
        return points.min {
            abs($0.time.timeIntervalSince(selected)) < abs($1.time.timeIntervalSince(selected))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if let sel = selectedPoint {
                    HStack(spacing: 4) {
                        Text(sel.time, format: .dateTime.hour().minute())
                            .font(.caption2).foregroundStyle(.tertiary)
                        Text("\(String(format: "%.1f", sel.value))\(unit.isEmpty ? "" : " \(unit)")")
                            .font(.caption.weight(.semibold)).foregroundStyle(color)
                    }
                } else if let average {
                    Text("avg \(String(format: "%.1f", average))\(unit.isEmpty ? "" : " \(unit)")")
                        .font(.caption.weight(.semibold)).foregroundStyle(color)
                }
            }
            if points.isEmpty {
                Text("No readings this day")
                    .font(.caption).foregroundStyle(.tertiary)
                    .frame(height: 110, alignment: .center)
                    .frame(maxWidth: .infinity)
            } else {
                chart.frame(height: 110)
            }
        }
        .ocCardSurface()
    }

    @ViewBuilder
    private var chart: some View {
        Chart {
            if let night = clampedNight {
                RectangleMark(xStart: .value("Sleep start", night.start),
                              xEnd: .value("Sleep end", night.end))
                    .foregroundStyle(Color.indigo.opacity(0.10))
            }
            ForEach(points, id: \.time) { p in
                AreaMark(x: .value("Time", p.time),
                         yStart: .value(title, areaFloor),
                         yEnd: .value(title, p.value))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(.linearGradient(
                        colors: [color.opacity(0.25), color.opacity(0.02)],
                        startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Time", p.time), y: .value(title, p.value))
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    .foregroundStyle(color)
            }
            if let sel = selectedPoint {
                RuleMark(x: .value("Time", sel.time))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .foregroundStyle(color.opacity(0.35))
                PointMark(x: .value("Time", sel.time), y: .value(title, sel.value))
                    .symbolSize(90).foregroundStyle(color)
            }
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: yDomain)
        .chartXSelection(value: $selected)
        .chartPlotStyle { $0.clipped() }
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

/// Hourly steps as a clipped bar chart with touch-to-read. Bars match Apple Health's Steps look; the
/// night band is clamped to the day so it can't overflow the right axis.
private struct IntradayStepsCard: View {
    let buckets: [(hour: Date, steps: Int)]
    let total: Int?
    let domain: ClosedRange<Date>
    let nightWindow: DateInterval?

    @State private var selected: Date?

    private var clampedNight: (start: Date, end: Date)? {
        guard let w = nightWindow else { return nil }
        let s = max(w.start, domain.lowerBound)
        let e = min(w.end, domain.upperBound)
        return e > s ? (s, e) : nil
    }

    private var selectedBucket: (hour: Date, steps: Int)? {
        guard let selected else { return nil }
        return buckets.min {
            abs($0.hour.timeIntervalSince(selected)) < abs($1.hour.timeIntervalSince(selected))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("STEPS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if let sel = selectedBucket {
                    HStack(spacing: 4) {
                        Text(sel.hour, format: .dateTime.hour())
                            .font(.caption2).foregroundStyle(.tertiary)
                        Text("\(sel.steps) steps").font(.caption.weight(.semibold)).foregroundStyle(.green)
                    }
                } else if let total {
                    Text("\(total) total").font(.caption.weight(.semibold)).foregroundStyle(.green)
                }
            }
            if buckets.isEmpty {
                Text("No readings this day")
                    .font(.caption).foregroundStyle(.tertiary)
                    .frame(height: 110, alignment: .center)
                    .frame(maxWidth: .infinity)
            } else {
                chart.frame(height: 110)
            }
        }
        .ocCardSurface()
    }

    @ViewBuilder
    private var chart: some View {
        Chart {
            if let night = clampedNight {
                RectangleMark(xStart: .value("Sleep start", night.start),
                              xEnd: .value("Sleep end", night.end))
                    .foregroundStyle(Color.indigo.opacity(0.10))
            }
            ForEach(buckets, id: \.hour) { hour, steps in
                BarMark(x: .value("Hour", hour, unit: .hour), y: .value("Steps", steps))
                    .foregroundStyle(.green)
            }
            if let sel = selectedBucket {
                RuleMark(x: .value("Hour", sel.hour, unit: .hour))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .foregroundStyle(Color.green.opacity(0.4))
            }
        }
        .chartXScale(domain: domain)
        .chartXSelection(value: $selected)
        .chartPlotStyle { $0.clipped() }
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

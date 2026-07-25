// Thin, app-facing wrappers for the "live / hero" charts.
//
//   • `LiveVitalsChart` — the real-time HR / SpO₂ line during an on-demand measurement or a workout —
//     uses liveline-swift (MIT): animated, momentum-colored SwiftUI-Canvas line built for streaming.
//   • `HeroSparkline` — the static two-week summary line at the top of a tab — uses Apple Swift
//     Charts. Its data is a paused snapshot (no live animation to gain from liveline), and Swift
//     Charts gives us a forgiving tap/drag hit area plus a fully custom scrub callout: a per-metric
//     label (not liveline's hard-coded "Value"), a readout positioned clear of the finger, and
//     per-metric decimals. It keeps the liveline look — smooth line + soft gradient fill.
//
// The dense historical daily-trend grids also use Swift Charts (see MetricChartCard / TrendsView).
// Keeping liveline behind `LiveVitalsChart` means the rest of the app never imports Liveline directly.

import SwiftUI
import Charts
import Liveline

// MARK: - Live streaming vitals line

/// A real-time line for a live vital (HR or SpO₂). Feed it a rolling buffer of recent
/// `LivelinePoint`s and the latest value; it renders the animated liveline line with a pulsing
/// endpoint and the big momentum-colored current value. Theme tracks the system color scheme so the
/// chart is light in light mode and dark in dark mode (liveline itself only has `.light`/`.dark`).
struct LiveVitalsChart: View {
    @Environment(\.colorScheme) private var scheme

    /// Rolling window of recent readings (see `LiveBuffer`). Passing the buffer (not raw points)
    /// keeps `LivelinePoint` — and the `import Liveline` — out of the app's view code.
    let buffer: LiveBuffer
    /// Metric accent (falls back to momentum coloring when `valueMomentumColor` is on).
    var color: Color = Theme.hr
    /// Visible time window in seconds.
    var window: TimeInterval = 90
    /// Suffix appended to the formatted value (e.g. "bpm", "%").
    var unit: String = ""
    /// Shown centered when there are no points yet (warm-up).
    var emptyText: String = "Waiting for a reading…"

    var body: some View {
        LivelineChart(
            data: buffer.points,
            value: buffer.latest,
            color: color,
            configuration: LivelineChartConfiguration(
                theme: scheme == .dark ? .dark : .light,
                window: window,
                grid: false,
                badge: true,
                fill: true,
                pulse: true,
                lineWidth: 3,
                scrub: false,                 // it's live — no historical scrubbing
                showValue: true,
                valueMomentumColor: true,     // rising = green, falling = red endpoint value
                emptyText: emptyText,
                formatValue: { v in
                    let n = Int(v.rounded())
                    return unit.isEmpty ? "\(n)" : "\(n) \(unit)"
                }
            )
        )
    }
}

// MARK: - Hero card + sparkline

/// The whole tab-hero card: accent section header, a big headline value, the summary sparkline, and
/// a caption. Tap or drag the sparkline to scrub — the **headline value reads out the touched day**
/// (Apple-Health style), so the read-out is a big number at the top of the card, never a pill under
/// the finger and never overlapping the line. When not scrubbing it shows the latest `value`.
struct HeroCard: View {
    let title: String
    let systemImage: String
    let tint: Color
    /// (date, value) oldest→newest.
    let points: [(Date, Double)]
    /// Latest headline value + its subtitle, shown when not scrubbing (e.g. "7.4" / "h asleep").
    let value: String
    let unit: String
    /// Scrub read-out: unit suffix (e.g. "h", "bpm"; empty for bare step counts) and decimals
    /// (1 for sleep hours → x.x, 0 for steps / bpm).
    var metricUnit: String = ""
    var metricDecimals: Int = 0

    @State private var selectedDate: Date?

    private var selectedPoint: (Date, Double)? {
        guard let selectedDate else { return nil }
        return points.min {
            abs($0.0.timeIntervalSince(selectedDate)) < abs($1.0.timeIntervalSince(selectedDate))
        }
    }

    private func numberString(_ v: Double) -> String {
        metricDecimals > 0
            ? v.formatted(.number.precision(.fractionLength(metricDecimals)))
            : Int(v.rounded()).formatted()
    }

    /// Subtitle while scrubbing: the metric unit + the touched day (e.g. "h · Jul 18", "steps · Jul 18").
    private func scrubSubtitle(_ date: Date) -> String {
        let day = date.formatted(.dateTime.month().day())
        return metricUnit.isEmpty ? day : "\(metricUnit) · \(day)"
    }

    var body: some View {
        OCCard {
            OCSectionHeader(title, systemImage: systemImage, tint: tint)
            if let sel = selectedPoint {
                OCHeroValue(value: numberString(sel.1), unit: scrubSubtitle(sel.0), tint: tint)
            } else {
                OCHeroValue(value: value, unit: unit, tint: tint)
            }
            HeroSparkline(points: points, color: tint, selectedDate: $selectedDate)
                .frame(height: 108)
            if let first = points.first?.0, let last = points.last?.0 {
                Text("\(first, format: .dateTime.month().day()) – \(last, format: .dateTime.month().day()) · tap the chart to read a day")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

/// The static two-week summary line, rendered with Swift Charts but styled to match the liveline look
/// (smooth line + soft gradient fill). Reports the scrubbed day via `selectedDate`; the owning
/// `HeroCard` turns that into the headline read-out. Tap or drag anywhere over the (108pt) plot.
struct HeroSparkline: View {
    /// Historical points, oldest → newest.
    let points: [(Date, Double)]
    var color: Color = Theme.accent
    @Binding var selectedDate: Date?

    init(points: [(Date, Double)], color: Color = Theme.accent, selectedDate: Binding<Date?>) {
        self.points = points
        self.color = color
        self._selectedDate = selectedDate
    }

    /// Clamp the y-axis to the data (+12% headroom) so the line uses the height without a 0 baseline
    /// flattening a tight metric. (No callout floats over the plot now, so no extra top room needed.)
    private var yDomain: ClosedRange<Double> {
        guard let lo = points.map(\.1).min(), let hi = points.map(\.1).max() else { return 0...1 }
        if lo == hi { return (lo - 1)...(hi + 1) }
        let pad = (hi - lo) * 0.12
        return (lo - pad)...(hi + pad)
    }

    private var areaFloor: Double { yDomain.lowerBound }

    /// Pad the x-domain a hair beyond the first/last day so the edge-day selection dot (and the line's
    /// round end-cap) isn't half-clipped by `.clipped()` at the plot edges.
    private var xDomain: ClosedRange<Date> {
        guard let first = points.first?.0, let last = points.last?.0 else {
            let now = Date(); return now...now.addingTimeInterval(1)
        }
        let pad = max(last.timeIntervalSince(first), 1) * 0.05
        return first.addingTimeInterval(-pad)...last.addingTimeInterval(pad)
    }

    private var selectedPoint: (Date, Double)? {
        guard let selectedDate else { return nil }
        return points.min {
            abs($0.0.timeIntervalSince(selectedDate)) < abs($1.0.timeIntervalSince(selectedDate))
        }
    }

    var body: some View {
        Chart {
            ForEach(points, id: \.0) { point in
                AreaMark(x: .value("Day", point.0),
                         yStart: .value("v", areaFloor),
                         yEnd: .value("v", point.1))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(.linearGradient(
                        colors: [color.opacity(0.30), color.opacity(0.02)],
                        startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Day", point.0), y: .value("v", point.1))
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .foregroundStyle(color)
            }
            // Scrub marker: vertical rule + emphasized dot at the touched day. The value itself reads
            // out in HeroCard's headline, so nothing floats over the line here.
            if let sel = selectedPoint {
                RuleMark(x: .value("Day", sel.0))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .foregroundStyle(color.opacity(0.35))
                PointMark(x: .value("Day", sel.0), y: .value("v", sel.1))
                    .symbolSize(80).foregroundStyle(color)
            }
        }
        .chartYScale(domain: yDomain)
        .chartXScale(domain: xDomain)
        .chartYAxis(.hidden)
        .chartXAxis(.hidden)
        .chartXSelection(value: $selectedDate)
        .chartPlotStyle { $0.clipped() }
    }
}

// MARK: - Rolling live-buffer helper

/// A fixed-capacity rolling buffer of live readings for `LiveVitalsChart`. A view accumulates
/// readings into this from `.onChange(of:)` of the session's live value; it keeps only the most
/// recent `capacity` points and stamps each with the current time. Value-typed and cheap to copy.
struct LiveBuffer {
    private(set) var points: [LivelinePoint] = []
    var capacity: Int = 120

    /// Append a reading stamped at `time` (default: now via the caller — no Date() here so callers
    /// stay in control of the clock). Trims to `capacity`.
    mutating func append(value: Double, at time: TimeInterval) {
        points.append(LivelinePoint(time: time, value: value))
        if points.count > capacity {
            points.removeFirst(points.count - capacity)
        }
    }

    mutating func reset() { points.removeAll(keepingCapacity: true) }

    var latest: Double { points.last?.value ?? 0 }
    var isEmpty: Bool { points.isEmpty }
}

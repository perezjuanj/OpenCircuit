// The restyled historical daily-trend card — the "history" half of the hybrid charting decision.
// Dense multi-day rollups stay on Apple Swift Charts (crisp discrete points, free axis handling),
// but wrapped in the shared OpenCircuit card look: rounded surface, section-accent title, a soft
// gradient area fill under a smooth line, an optional dashed 7-day-average reference line, and a
// value pill. One card type, reused by the Trends / Sleep / Activity tabs so every graph matches.

import SwiftUI
import Charts

/// A single labeled daily-trend chart. `data` is (day, value) oldest→newest.
struct MetricChartCard: View {
    let title: String
    var unit: String = ""
    var color: Color = Theme.accent
    /// (day, value) oldest→newest. Unlabeled to match the section builders' `compactMap` literals.
    let data: [(Date, Double)]
    var avg: Double? = nil
    var formatAvg: (Double) -> String = { "\(Int($0.rounded()))" }
    /// When true, the y-axis is not forced through zero — better for tightly-clustered vitals
    /// (HR, SpO₂, temp) where a 0-based axis would flatten the signal.
    var clampsToData: Bool = true

    /// Day under the user's finger while scrubbing (nil when not touching). Drives the marker + pill.
    @State private var selectedDate: Date?

    private var yDomain: ClosedRange<Double>? {
        guard clampsToData, let lo = data.map(\.1).min(), let hi = data.map(\.1).max() else {
            return nil
        }
        if lo == hi { return (lo - 1)...(hi + 1) }
        let pad = (hi - lo) * 0.15
        return (lo - pad)...(hi + pad)
    }

    /// Baseline the area fills DOWN to: the visible floor for clamped vitals, else 0 (zero-based for
    /// steps/energy/distance/exercise). Prevents the fill-to-off-screen-zero that caused the bleed.
    private var areaFloor: Double { yDomain?.lowerBound ?? 0 }

    /// The plotted point nearest the scrubbed day — what the marker + value pill read out.
    private var selectedPoint: (Date, Double)? {
        guard let selectedDate else { return nil }
        return data.min {
            abs($0.0.timeIntervalSince(selectedDate)) < abs($1.0.timeIntervalSince(selectedDate))
        }
    }

    private static let scrubDateFormat = Date.FormatStyle.dateTime.weekday(.abbreviated).month().day()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                // While scrubbing, the pill reads the touched day's value (Apple-Health style);
                // otherwise it shows the 7-day average. Keeping the readout in the header avoids
                // clipping a floating annotation on these short cards.
                if let sel = selectedPoint {
                    HStack(spacing: 4) {
                        Text(sel.0, format: Self.scrubDateFormat)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(unit.isEmpty ? formatAvg(sel.1) : "\(formatAvg(sel.1)) \(unit)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(color)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(color.opacity(0.12)))
                } else if let a = avg {
                    HStack(spacing: 4) {
                        Text("7d avg")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(unit.isEmpty ? formatAvg(a) : "\(formatAvg(a)) \(unit)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(color)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(color.opacity(0.12)))
                }
            }

            if data.isEmpty {
                Text("No data in the last 2 weeks")
                    .font(.caption).foregroundStyle(.tertiary)
                    .frame(height: 84, alignment: .center)
                    .frame(maxWidth: .infinity)
            } else {
                chart
                    .frame(height: 92)
            }
        }
        .ocCardSurface()
    }

    @ViewBuilder
    private var chart: some View {
        Chart {
            if let a = avg {
                RuleMark(y: .value("avg", a))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(color.opacity(0.35))
            }
            ForEach(data, id: \.0) { point in
                // Anchor the area's baseline to the VISIBLE floor (the clamped y-domain lower bound),
                // not the default y=0 — which, with a non-zero-based domain, sits far below the plot
                // and makes the fill spill past the axis. `.chartPlotStyle { clipped }` below is the
                // belt-and-suspenders clip so nothing renders outside the plot rect regardless.
                AreaMark(
                    x: .value("Day", point.0, unit: .day),
                    yStart: .value(title, areaFloor),
                    yEnd: .value(title, point.1)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(
                    .linearGradient(
                        colors: [color.opacity(0.28), color.opacity(0.02)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                LineMark(
                    x: .value("Day", point.0, unit: .day),
                    y: .value(title, point.1)
                )
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .foregroundStyle(color)
                PointMark(
                    x: .value("Day", point.0, unit: .day),
                    y: .value(title, point.1)
                )
                .symbolSize(18)
                .foregroundStyle(color)
            }

            // Scrub marker: a rule + emphasized dot at the day under the finger. The value itself is
            // read out in the card header (see body) so nothing floats off the top of a short chart.
            if let sel = selectedPoint {
                RuleMark(x: .value("Day", sel.0, unit: .day))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .foregroundStyle(color.opacity(0.35))
                PointMark(x: .value("Day", sel.0, unit: .day), y: .value(title, sel.1))
                    .symbolSize(90)
                    .foregroundStyle(color)
            }
        }
        .chartXSelection(value: $selectedDate)
        .modifier(OptionalYDomain(domain: yDomain))
        // Clip every mark to the plot rect so the area fill / catmull-rom overshoot can't bleed past
        // the axes and out of the card (the reported gradient-bleed bug).
        .chartPlotStyle { plot in plot.clipped() }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day)) { _ in
                AxisValueLabel(format: .dateTime.weekday(.narrow))
                    .font(.caption2)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.12))
                AxisValueLabel().font(.caption2)
            }
        }
    }
}

/// Applies a y-scale domain only when one is provided (Swift Charts has no "optional domain" API).
private struct OptionalYDomain: ViewModifier {
    let domain: ClosedRange<Double>?
    func body(content: Content) -> some View {
        if let domain {
            content.chartYScale(domain: domain)
        } else {
            content
        }
    }
}

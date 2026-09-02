// Goal-ring HISTORY — the past-days view of the four rings on the Goals card.
//
// The Goals card answers "how am I doing today". This answers "how have I been doing", as a
// scrollable strip of past days (one concentric four-ring glyph per day, newest on the right) plus
// two history charts. Every number here is DERIVED from data already stored — `TrendsData`
// computes `goalDays` in the same off-main pass as the trend points, and `GoalHistory` (Kit, unit
// tested) does the scoring. No new SwiftData model, no new column.
//
// HONESTY, STATED ON SCREEN (see `GoalHistory`'s header for the full reasoning):
//   • A past day is scored against the goals set RIGHT NOW — historical goals were never stored and
//     inventing them would be fabrication. The weekday/weekend split still follows the real date.
//   • A ring with no retained data is drawn as an empty dashed track and is NEVER counted as missed;
//     a day with nothing at all reads "no data".
//   • Today is marked partial: it is still accumulating, so it is never called a miss and never
//     breaks the streak.
//   • Active calories and elevated-HR minutes are the app's own ESTIMATEs (same basis as the Goals
//     card and Apple Health), not ring-reported values — labelled as such.

import SwiftUI
import OpenCircuitKit

// MARK: - Ring colours

enum GoalRingStyle {
    /// The ring colours, matching `GoalsCardView`'s four rings exactly so a day in the strip reads
    /// as the same ring the user saw on the Today card. Outermost first.
    static func color(_ ring: GoalHistory.Ring) -> Color {
        switch ring {
        case .steps:           return .green
        case .activeKcal:      return .orange
        case .activityMinutes: return .blue
        case .sleepMinutes:    return .purple
        }
    }

    static func label(_ ring: GoalHistory.Ring) -> String {
        switch ring {
        case .steps:           return "Steps"
        case .activeKcal:      return "Active kcal est."
        case .activityMinutes: return "Elevated HR est."
        case .sleepMinutes:    return "Sleep"
        }
    }

    /// Outermost → innermost, the order the glyph draws.
    static let drawOrder: [GoalHistory.Ring] = [.steps, .activeKcal, .activityMinutes, .sleepMinutes]

    static func format(_ ring: GoalHistory.Ring, _ value: Double) -> String {
        switch ring {
        case .steps:           return Int(value.rounded()).formatted()
        case .activeKcal:      return "\(Int(value.rounded()))"
        case .activityMinutes: return "\(Int(value.rounded()))m"
        case .sleepMinutes:    return durationText(Int(value.rounded()))
        }
    }

    static func durationText(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        if h > 0 && m > 0 { return "\(h)h\(m)m" }
        if h > 0 { return "\(h)h" }
        return "\(m)m"
    }
}

// MARK: - One day's concentric rings

/// A day's four goals as concentric rings, Apple-Activity style. A ring with no data is a dashed
/// empty track — never a full-width "0 %" arc, which would read as a failure the data can't support.
struct GoalRingsGlyph: View {
    let day: GoalHistory.Day
    var size: CGFloat = 34
    var lineWidth: CGFloat = 4
    var spacing: CGFloat = 1.5

    var body: some View {
        ZStack {
            ForEach(Array(GoalRingStyle.drawOrder.enumerated()), id: \.element) { index, ring in
                let inset = (lineWidth + spacing) * CGFloat(index)
                let present = day.present.contains(ring)
                let color = GoalRingStyle.color(ring)
                ZStack {
                    if present {
                        Circle().stroke(color.opacity(0.18), lineWidth: lineWidth)
                        Circle()
                            .trim(from: 0, to: day.fraction(for: ring))
                            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    } else {
                        Circle().stroke(Color.secondary.opacity(0.18),
                                        style: StrokeStyle(lineWidth: lineWidth, dash: [1.5, 2.5]))
                    }
                }
                .padding(inset)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spokenLabel(day))
    }

    static func spokenLabel(_ day: GoalHistory.Day) -> String {
        let date = day.date.formatted(.dateTime.weekday(.wide).month().day())
        guard day.hasData else { return "\(date), no data" }
        let metPhrase = day.isPartial && !day.closedAll
            ? "\(day.ringsMet) of 4 goals met so far"
            : "\(day.ringsMet) of 4 goals met"
        let rings = GoalRingStyle.drawOrder
            .filter { day.present.contains($0) }
            .map { "\(GoalRingStyle.label($0)) \(Int(day.fraction(for: $0) * 100)) percent" }
            .joined(separator: ", ")
        return "\(date), \(metPhrase), \(rings)"
    }
}

// MARK: - The history section

/// Horizontal strip of past days + a tap-to-inspect breakdown + the streak roll-up.
struct GoalRingsHistorySection: View {
    let days: [GoalHistory.Day]
    let summary: GoalHistory.Summary

    @State private var selected: Date?

    /// Newest first, so the strip reads right-to-left the way a "recent days" list should.
    private var ordered: [GoalHistory.Day] { days.reversed() }

    private var selectedDay: GoalHistory.Day? {
        guard let selected else { return days.last }
        return days.first { $0.date == selected }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            streakRow
            strip
            if let day = selectedDay { breakdown(day) }
            Text("Rings are scored against your CURRENT goals (weekday/weekend split follows each "
                 + "day's own date) — earlier goal settings were never stored, so changing a goal "
                 + "re-scores this history. A dashed ring means that metric has no retained data "
                 + "for that day; it is not counted as a missed goal. Active calories and elevated-"
                 + "HR minutes are on-device estimates.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ocCardSurface()
    }

    // MARK: Streak roll-up

    private var streakRow: some View {
        HStack(alignment: .center, spacing: 14) {
            stat(value: "\(summary.currentStreak)",
                 caption: summary.currentStreak == 1 ? "day streak" : "days streak",
                 tint: summary.currentStreak > 0 ? .green : .secondary)
            Divider().frame(height: 28)
            stat(value: "\(summary.daysAllClosed)", caption: "days all 4 closed", tint: .primary)
            Divider().frame(height: 28)
            stat(value: "\(summary.longestStreak)", caption: "best streak", tint: .primary)
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }

    private func stat(value: String, caption: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
            Text(caption).font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: The scrollable strip

    private var strip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(ordered) { day in
                    Button { selected = day.date } label: { chip(day) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 2)
        }
    }

    private func chip(_ day: GoalHistory.Day) -> some View {
        let isSelected = selectedDay?.date == day.date
        return VStack(spacing: 4) {
            GoalRingsGlyph(day: day)
            Text(day.date, format: .dateTime.weekday(.narrow))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(day.isPartial ? Color.accentColor : .secondary)
            Text(day.date, format: .dateTime.day())
                .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
        }
        .padding(.horizontal, 6).padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? Color.primary.opacity(0.07) : .clear))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(day.closedAll ? Color.green.opacity(0.45) : .clear, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: Selected-day breakdown

    @ViewBuilder
    private func breakdown(_ day: GoalHistory.Day) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(day.date, format: .dateTime.weekday(.wide).month(.abbreviated).day())
                    .font(.caption.weight(.semibold))
                if day.isPartial {
                    Text("today · still counting")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if day.hasData {
                    Text("\(day.ringsMet)/4")
                        .font(.caption.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(day.closedAll ? .green : .secondary)
                }
            }
            if day.hasData {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(GoalRingStyle.drawOrder, id: \.self) { ring in
                        ringDetail(day, ring)
                    }
                }
            } else {
                Text("No data retained for this day.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.top, 2)
    }

    private func ringDetail(_ day: GoalHistory.Day, _ ring: GoalHistory.Ring) -> some View {
        let present = day.present.contains(ring)
        let p = day.goalProgress(for: ring)
        let color = GoalRingStyle.color(ring)
        return VStack(spacing: 3) {
            ZStack {
                if present {
                    Circle().stroke(color.opacity(0.18), lineWidth: 5)
                    Circle().trim(from: 0, to: p.fraction)
                        .stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    if p.met {
                        Image(systemName: "checkmark").font(.caption2.weight(.bold)).foregroundStyle(color)
                    } else {
                        Text("\(Int(p.fraction * 100))%")
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Circle().stroke(Color.secondary.opacity(0.18),
                                    style: StrokeStyle(lineWidth: 5, dash: [2, 3]))
                    Text("—").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .frame(width: 40, height: 40)
            Text(present ? GoalRingStyle.format(ring, p.current) : "—")
                .font(.caption2.weight(.semibold)).monospacedDigit()
                .foregroundStyle(present && p.met ? color : .primary)
            Text(GoalRingStyle.label(ring))
                .font(.system(size: 9)).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text("/ \(GoalRingStyle.format(ring, p.goal))")
                .font(.system(size: 9)).foregroundStyle(.tertiary).monospacedDigit()
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(GoalRingStyle.label(ring))
        .accessibilityValue(present
            ? "\(GoalRingStyle.format(ring, p.current)) of \(GoalRingStyle.format(ring, p.goal)), "
              + (p.met ? "goal met" : "\(Int(p.fraction * 100)) percent")
            : "no data")
    }
}

// MARK: - Ring-completion charts

/// Goal-attainment history as charts, reusing the shared `MetricChartCard` so these read like every
/// other trend on the tab. Partial days are excluded from "Goals Closed" — a half-finished today
/// plotted as a low bar looks like a bad day rather than an unfinished one.
struct GoalRingsTrendsSection: View {
    let days: [GoalHistory.Day]

    var body: some View {
        let finished = days.filter { !$0.isPartial }
        VStack(spacing: 12) {
            MetricChartCard(title: "Goals Closed", unit: "of 4", color: .green,
                data: finished.filter(\.hasData).map { ($0.date, Double($0.ringsMet)) },
                avg: average(finished.filter(\.hasData).map { Double($0.ringsMet) }),
                formatAvg: { String(format: "%.1f", $0) }, clampsToData: false)
            MetricChartCard(title: "Goal Attainment", unit: "%", color: Theme.accent,
                data: finished.compactMap { d in d.attainment.map { (d.date, $0 * 100) } },
                avg: average(finished.compactMap { $0.attainment }).map { $0 * 100 },
                clampsToData: false)
        }
    }

    private func average(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
}

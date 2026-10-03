// Browse past nights (#216): a strip of the last 30 nights' sleep durations to pick from (tap a bar,
// or step with the arrows / swipe), and the chosen night's stages as a proper hypnogram.
//
// Reads only stored `StoredSleepSummary` rows — the same rows the Sleep card shows — and decodes the
// stored stage timeline with `SleepHypnogramCodec`, exactly as `SleepCardView` does. Honesty rules:
//   - a night with no stored timeline shows its stage TOTALS and says the timeline isn't stored,
//     rather than drawing an invented hypnogram;
//   - time the wearer entered (an edited night's asserted segments) is drawn faded and labelled, so
//     it never passes for something the ring measured;
//   - the "duration may read high" caveat is carried over from `SleepConfidence`.
// Stage colours are the Sleep card's own (Deep indigo, Light teal, REM purple, Awake orange); the
// chart itself is `SleepHypnogramChart`, shared with the Sleep card.

import SwiftUI
import SwiftData
import Charts
import OpenCircuitKit

struct SleepNightsBrowserView: View {
    @Query private var nights: [StoredSleepSummary]
    @State private var selected: Date?

    @ScaledMetric(relativeTo: .largeTitle) private var valueSize: CGFloat = 44

    init() {
        var d = FetchDescriptor<StoredSleepSummary>(sortBy: [SortDescriptor(\.night, order: .reverse)])
        d.fetchLimit = 30
        _nights = Query(d)
    }

    /// Nights with any sleep, oldest first.
    private var usable: [StoredSleepSummary] {
        nights.filter { $0.asleepMin > 0 }.reversed()
    }

    private var current: StoredSleepSummary? {
        let list = usable
        if let selected, let n = list.first(where: { $0.night == selected }) { return n }
        return list.last
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                if usable.isEmpty {
                    OCCard {
                        Text("No nights yet").font(.headline)
                        Text("Wear your device overnight and sync in the morning; each night will appear here.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                } else {
                    durationStrip
                    if let night = current {
                        NightDetail(night: night, valueSize: valueSize,
                                    canGoBack: index(of: night) > 0,
                                    canGoForward: index(of: night) < usable.count - 1,
                                    step: step)
                            .id(night.night)
                            .gesture(DragGesture(minimumDistance: 30).onEnded { g in
                                if g.translation.width < -60 { step(1) } else if g.translation.width > 60 { step(-1) }
                            })
                    }
                }
            }
            .padding(16)
            .containerRelativeFrame(.horizontal)
        }
        .background(Theme.pageBackground)
        .navigationTitle("Past Nights")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func index(of night: StoredSleepSummary) -> Int {
        usable.firstIndex(where: { $0.night == night.night }) ?? 0
    }

    private func step(_ by: Int) {
        guard let night = current else { return }
        let i = index(of: night) + by
        guard usable.indices.contains(i) else { return }
        selected = usable[i].night
    }

    // MARK: Duration strip

    private var durationStrip: some View {
        let list = usable
        let chosen = current?.night
        return OCCard(spacing: 8) {
            HStack {
                Text("ASLEEP · LAST \(list.count) NIGHTS").font(.caption.weight(.semibold)).tracking(1.0)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("tap a night").font(.caption2).foregroundStyle(.tertiary)
            }
            Chart(list, id: \.night) { n in
                BarMark(x: .value("Night", n.night, unit: .day),
                        y: .value("Hours asleep", Double(n.asleepMin) / 60))
                    .foregroundStyle(n.night == chosen ? Theme.sleep : Theme.sleep.opacity(0.35))
                    .cornerRadius(2)
            }
            .chartXSelection(value: Binding(
                get: { selected },
                set: { d in
                    guard let d else { return }
                    let cal = Calendar.current
                    if let hit = list.first(where: { cal.isDate($0.night, inSameDayAs: d) }) { selected = hit.night }
                }))
            .chartYAxis {
                AxisMarks(position: .trailing, values: [0, 4, 8]) { v in
                    AxisGridLine()
                    AxisValueLabel { if let h = v.as(Double.self) { Text("\(Int(h))h") } }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                }
            }
            .frame(height: 90)
            .accessibilityElement()
            .accessibilityLabel("Hours asleep over the last \(list.count) nights. Use the previous and next night buttons to choose a night.")
        }
    }
}

// MARK: - One night

private struct NightDetail: View {
    let night: StoredSleepSummary
    let valueSize: CGFloat
    let canGoBack: Bool
    let canGoForward: Bool
    let step: (Int) -> Void

    private var segments: [SleepSegment] { SleepHypnogramCodec.decode(night.hypnogramData) }
    private var hasClock: Bool { night.inBedEnd > night.inBedStart }

    var body: some View {
        let segs = segments
        VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
            header
            OCCard(spacing: 10) {
                Text("STAGES").font(.caption.weight(.semibold)).tracking(1.0).foregroundStyle(.secondary)
                if segs.isEmpty {
                    Text("This night's stage timeline isn't stored — only its totals are, shown below.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    SleepHypnogramChart(segments: segs)
                    if segs.contains(where: { $0.provenance != .measured }) {
                        Text("Faded blocks are time you entered when editing this night, not something your device measured.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                totals
            }
            if SleepConfidence.classify(night.asSummary) == .durationLikelyHigh {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    KeylineGlyph(.circleAlert, size: 13, relativeTo: .caption)
                    Text("A very still night with almost no detected wake — the time asleep may read high.")
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button { step(-1) } label: {
                    KeylineGlyph(.chevronLeft, size: 20, relativeTo: .headline).frame(width: 32, height: 32)
                }
                .disabled(!canGoBack)
                .accessibilityLabel("Previous night")
                Spacer()
                VStack(spacing: 1) {
                    Text(title).font(.headline)
                    if hasClock {
                        Text("\(night.inBedStart.formatted(date: .omitted, time: .shortened)) – \(night.inBedEnd.formatted(date: .omitted, time: .shortened)) in bed")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                Spacer()
                Button { step(1) } label: {
                    KeylineGlyph(.chevronRight, size: 20, relativeTo: .headline).frame(width: 32, height: 32)
                }
                .disabled(!canGoForward)
                .accessibilityLabel("Next night")
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(night.asleepMin / 60)").font(.system(size: valueSize, weight: .semibold, design: .rounded))
                Text("h").font(.title3.weight(.medium)).foregroundStyle(.secondary)
                Text("\(night.asleepMin % 60)").font(.system(size: valueSize, weight: .semibold, design: .rounded))
                Text("m asleep").font(.title3.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                if night.sleepScore > 0 {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text("\(night.sleepScore)").font(.system(.title2, design: .rounded).weight(.semibold))
                        Text("sleep score").font(.caption2).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .monospacedDigit()
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(night.asleepMin / 60) hours \(night.asleepMin % 60) minutes asleep"
                                + (night.sleepScore > 0 ? ", sleep score \(night.sleepScore)" : ""))
        }
        .ocCardSurface()
    }

    /// "Tue, Sep 29 → Wed, Sep 30" from the in-bed window; without one, the night key — which is
    /// the day the night ENDED (`SleepNightKey`) — as "Night to Wed, Sep 30".
    private var title: String {
        let f = Date.FormatStyle.dateTime.weekday(.abbreviated).month(.abbreviated).day()
        if hasClock { return night.inBedStart.formatted(f) + " → " + night.inBedEnd.formatted(f) }
        return "Night to " + night.night.formatted(f)
    }

    private var totals: some View {
        let rows: [(String, Int, Color)] = [
            ("Deep", night.deepMin, .indigo), ("Light", night.lightMin, .teal),
            ("REM", night.remMin, .purple), ("Awake", night.awakeMin, .orange),
        ]
        let total = max(rows.reduce(0) { $0 + $1.1 }, 1)
        return VStack(spacing: 6) {
            ForEach(rows, id: \.0) { name, mins, color in
                HStack(spacing: 8) {
                    Circle().fill(color).frame(width: 8, height: 8)
                    Text(name).font(.subheadline)
                    Spacer()
                    Text("\(mins / 60)h \(mins % 60)m").font(.subheadline.weight(.medium)).monospacedDigit()
                    Text("\(Int((Double(mins) / Double(total) * 100).rounded()))%")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        .frame(width: 38, alignment: .trailing)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.top, 4)
    }
}

// The Trends tab — all-day body-vital history (#74), plus a per-day time-of-day breakdown
// (`DayDetailView`, tap a day chip). Sleep and activity graphs moved to their own tabs; this tab
// focuses on the all-day vitals (HR / HRV / SpO₂ / RR / daytime skin temp) + recent readings.
//
// The heavy loading + the chart sections are shared with the Sleep/Activity tabs via `TrendsData`
// and the reusable section views, so a metric can never disagree between tabs. Loading is a
// synchronous main-actor SwiftData read, computed in `.task` and cached in @State.

import SwiftUI
import SwiftData
import OpenCircuitKit

struct TrendsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext

    @State private var data = TrendsData()
    @State private var loading = true
    @State private var selectedDay: Date?

    // Display units (#83): values are stored in SI; only the display layer converts. (This tab shows
    // all-day vitals + temp; the distance-bearing charts live on the Activity tab.)
    @AppStorage("units.temperature") private var tempUnitRaw = TemperatureUnit.localeDefault.rawValue

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.sectionSpacing) {
                if loading {
                    ProgressView("Computing trends…").padding(.top, 40)
                } else if data.points.isEmpty {
                    emptyState
                } else {
                    // Historical day picker pinned at the top — tap a day to drill into its
                    // time-of-day breakdown (DayDetailView).
                    OCSectionHeader("Daily Breakdown", systemImage: "calendar", tint: Theme.accent)
                    Text("Tap a day to see its time-of-day breakdown.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    dayPicker
                    hero
                    availableMetricsNote
                    OCSectionHeader("All-Day Vitals", systemImage: "waveform.path.ecg", tint: Theme.hr)
                    AllDayVitalsSection(points: data.points, tempUnitRaw: tempUnitRaw)
                    OCSectionHeader("Recent Readings", systemImage: "list.bullet.rectangle", tint: .secondary)
                    RecentReadingsSection(rows: data.recentRows)
                }
            }
            .padding()
        }
        .background(Theme.pageBackground)
        .navigationTitle("Trends")
        .navigationDestination(item: $selectedDay) { day in DayDetailView(day: day) }
        .task { await loadData() }
        .refreshable { await loadData() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await loadData() } }
        }
    }

    // MARK: - Hero

    @ViewBuilder
    private var hero: some View {
        let hrPts = data.points.compactMap { p in
            p.dayHRAvg.flatMap { hr in hr > TrendsEngine.minValidHR ? (p.date, hr) : nil }
        }
        if hrPts.count >= 2, let last = hrPts.last {
            HeroCard(title: "All-Day Heart Rate", systemImage: "heart.fill", tint: Theme.hr,
                     points: hrPts, value: "\(Int(last.1.rounded()))", unit: "bpm avg",
                     metricUnit: "bpm", metricDecimals: 0)
        }
    }

    // MARK: - Sections

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 44)).foregroundStyle(.secondary)
            Text("No trend data yet").font(.headline)
            Text("Sync from the ring a few times to build your history.")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 40)
    }

    private var availableMetricsNote: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            Text("All-day vitals use every worn epoch. Tap a day below for a time-of-day breakdown.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }

    /// Tap a day to drill into its time-of-day breakdown (`DayDetailView`).
    private var dayPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(data.points.reversed(), id: \.date) { p in
                    Button { selectedDay = p.date } label: {
                        Text(p.date, format: .dateTime.weekday(.abbreviated).day())
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(Capsule().fill(Theme.cardBackground))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    // MARK: - Data loading

    @MainActor
    private func loadData() async {
        data = await TrendsData.loadAsync(store: LocalStore(modelContext), tempUnitRaw: tempUnitRaw)
        loading = false
    }
}

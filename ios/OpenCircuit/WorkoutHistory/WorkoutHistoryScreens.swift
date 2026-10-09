// WorkoutHistoryScreens.swift: the full workout history and one workout's detail screen (#293).
//
// Both read OpenCircuit's OWN workouts back out of Apple Health, like the Recent Workouts card
// (see the header of `WorkoutHistoryView.swift`: no SwiftData model, no read-authorization request).
// What each screen shows is decided in `WorkoutDetailContent`; deletion is `WorkoutDeleter`.

import Charts
import MapKit
import SwiftUI
import HealthKit
import OpenCircuitKit

// MARK: - Full history

/// Every OpenCircuit workout, newest first, one section per month, loading the next page as the
/// last row appears. Swipe a row to delete it (behind the same confirmation as the detail screen).
struct WorkoutHistoryListView: View {
    /// Called after a deletion, so the card and the weekly load line re-query.
    var onWorkoutsChanged: () -> Void = {}

    static let pageSize = 30

    @AppStorage("units.distance") private var distUnitRaw = DistanceUnit.localeDefault.rawValue
    private var distanceUnit: DistanceUnit { DistanceUnit(rawValue: distUnitRaw) ?? .metric }

    @State private var items: [WorkoutHistoryReader.Item] = []
    @State private var reachedEnd = false
    @State private var loading = false
    @State private var loadedOnce = false
    @State private var pendingDelete: WorkoutHistoryReader.Item?
    @State private var deleting = false
    @State private var failure: String?
    @State private var failureTitle = "Workout not fully deleted"

    var body: some View {
        List {
            if loadedOnce && items.isEmpty {
                Text("No workouts recorded yet. Ones you record here are saved to Apple Health and listed back here.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(WorkoutDetailContent.monthSections(items)) { section in
                Section(section.month.formatted(.dateTime.month(.wide).year())) {
                    ForEach(section.items) { item in
                        NavigationLink {
                            WorkoutDetailView(item: item, onDeleted: { removed($0) })
                        } label: {
                            WorkoutHistoryRow(item: item, distanceUnit: distanceUnit)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button { pendingDelete = item } label: { Label("Delete", systemImage: "trash") }
                                .tint(.red)
                                .disabled(deleting)
                        }
                        .onAppear { if item.id == items.last?.id { Task { await loadMore() } } }
                    }
                }
            }
            if !reachedEnd {
                ProgressView().frame(maxWidth: .infinity)
                    .onAppear { Task { await loadMore() } }
            }
        }
        .navigationTitle("Workouts")
        .confirmationDialog(WorkoutDeleter.confirmationTitle,
                            isPresented: Binding(get: { pendingDelete != nil },
                                                 set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible,
                            presenting: pendingDelete) { item in
            Button("Delete Workout", role: .destructive) { Task { await delete(item) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(WorkoutDeleter.confirmationMessage)
        }
        .alert(failureTitle,
               isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }

    private func loadMore() async {
        guard !loading, !reachedEnd else { return }
        loading = true
        defer { loading = false; loadedOnce = true }
        let page = await WorkoutHistoryReader().workouts(startingBefore: items.last?.start,
                                                         limit: Self.pageSize)
        let merged = WorkoutDetailContent.appendPage(page, to: items, pageSize: Self.pageSize)
        items = merged.items
        reachedEnd = merged.reachedEnd
    }

    private func delete(_ item: WorkoutHistoryReader.Item) async {
        deleting = true
        defer { deleting = false }
        let outcome = await WorkoutDeleter(health: HealthKitWorkoutStore()).delete(item.deletionTarget)
        if outcome.removedWorkout { removed(item.id) }
        if let message = outcome.failureMessage {
            failureTitle = outcome.failureTitle
            failure = message
        }
    }

    private func removed(_ id: UUID) {
        items.removeAll { $0.id == id }
        onWorkoutsChanged()
    }
}

// MARK: - Detail

/// One workout: when, how long, energy (an estimate), heart rate with its chart and zones, distance
/// with pace or speed, the route, the device, and the training load. Only what the workout has.
struct WorkoutDetailView: View {
    let item: WorkoutHistoryReader.Item
    /// Called with the workout's id once it has been deleted.
    var onDeleted: (UUID) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @AppStorage("units.distance") private var distUnitRaw = DistanceUnit.localeDefault.rawValue
    private var distanceUnit: DistanceUnit { DistanceUnit(rawValue: distUnitRaw) ?? .metric }

    @State private var hr: [HRSample] = []
    @State private var hrSource: WorkoutDetailContent.HeartRateSource = .none
    @State private var route: [CLLocationCoordinate2D] = []
    @State private var loaded = false
    @State private var confirming = false
    @State private var deleting = false
    @State private var failure: String?
    @State private var failureTitle = "Workout not fully deleted"
    @State private var deleted = false

    private var age: Int { HealthKitWriter.storedUserProfile().age }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.sectionSpacing) {
                if deleted {
                    OCCard {
                        Text("This workout was deleted.").font(.subheadline).foregroundStyle(.secondary)
                    }
                } else {
                    header
                    summary
                    if loaded {
                        heartRateCard
                        zonesCard
                        routeCard
                    } else {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                    deleteButton
                }
            }
            .padding()
        }
        .background(Theme.pageBackground)
        .navigationTitle(WorkoutActivityDisplay.name(item.activityType))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .confirmationDialog(WorkoutDeleter.confirmationTitle, isPresented: $confirming,
                            titleVisibility: .visible) {
            Button("Delete Workout", role: .destructive) { Task { await delete() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(WorkoutDeleter.confirmationMessage)
        }
        .alert(failureTitle,
               isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }

    private var header: some View {
        OCCard {
            HStack(spacing: 12) {
                Image(systemName: WorkoutActivityDisplay.symbol(item.activityType))
                    .font(.title2).foregroundStyle(Theme.steps).frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.start.formatted(date: .complete, time: .omitted))
                        .font(.subheadline.weight(.semibold))
                    Text("\(item.start.formatted(date: .omitted, time: .shortened))–\(item.end.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var summary: some View {
        let recorder = WorkoutDetailContent.recordedWith(
            deviceName: item.deviceName, deviceManufacturer: item.deviceManufacturer,
            owner: LocalStore.ownershipLog().owner(at: item.start))
        return OCCard {
            ForEach(WorkoutDetailContent.rows(item, hr: hr, age: age, unit: distanceUnit,
                                              recordedWith: recorder)) { row in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(row.title).font(.subheadline)
                        Spacer()
                        Text(row.value).font(.subheadline.weight(.semibold)).monospacedDigit()
                    }
                    if let caption = row.caption {
                        Text(caption).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var heartRateCard: some View {
        if !hr.isEmpty {
            OCCard {
                OCSectionHeader("Heart Rate", systemImage: "heart.fill", tint: .red)
                Chart(hr, id: \.start) { sample in
                    LineMark(x: .value("Time", sample.start), y: .value("bpm", sample.bpm))
                        .foregroundStyle(.red)
                        .interpolationMethod(.monotone)
                }
                .chartXScale(domain: item.start...max(item.end, item.start.addingTimeInterval(1)))
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(height: 160)
                if hrSource == .appHistory {
                    Text("From OpenCircuit's stored readings: none were saved with this workout in Apple Health.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var zonesCard: some View {
        if let zones = WorkoutDetailContent.zones(hr, age: age, end: item.end) {
            OCCard {
                OCSectionHeader("Time in Heart-Rate Zones", systemImage: "chart.bar.fill", tint: .orange)
                ForEach(HRZone.allCases, id: \.rawValue) { zone in
                    ZoneBarRow(zone: zone, seconds: zones.seconds(in: zone), fraction: zones.fraction(in: zone))
                }
            }
        }
    }

    @ViewBuilder
    private var routeCard: some View {
        if route.count >= 2 {
            OCCard {
                OCSectionHeader("Route", systemImage: "map", tint: .blue)
                Map(initialPosition: .automatic) {
                    MapPolyline(coordinates: route).stroke(.blue, lineWidth: 4)
                }
                .frame(height: 240)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private var deleteButton: some View {
        Button(role: .destructive) { confirming = true } label: {
            Label(deleting ? "Deleting…" : "Delete Workout", systemImage: "trash")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(deleting)
    }

    private func load() async {
        guard !loaded else { return }
        let store = HealthKitWorkoutStore()
        let workout = try? await store.workout(item.id)
        var fromHealth: [HRSample] = []
        if let workout { fromHealth = await store.heartRate(of: workout) }
        let chosen = WorkoutDetailContent.heartRate(
            health: fromHealth, window: DateInterval(start: item.start, end: max(item.end, item.start)),
            appHistory: {
                guard let container = OpenCircuitApp.sharedContainer,
                      let rows = try? LocalStore(container.mainContext)
                        .ownedSamples(kind: .heartRate, from: item.start, to: item.end) else { return [] }
                return rows.map { HRSample(bpm: Int($0.value), start: $0.start, end: $0.end) }
            })
        hr = chosen.samples
        hrSource = chosen.source
        if let workout { route = await store.route(of: workout) }
        loaded = true
    }

    private func delete() async {
        deleting = true
        defer { deleting = false }
        let outcome = await WorkoutDeleter(health: HealthKitWorkoutStore()).delete(item.deletionTarget)
        if outcome.removedWorkout {
            deleted = true
            onDeleted(item.id)
        }
        if let message = outcome.failureMessage {
            // Stay on screen so the alert can be read; a deleted workout shows its "was deleted" state.
            failureTitle = outcome.failureTitle
            failure = message
            return
        }
        dismiss()
    }
}

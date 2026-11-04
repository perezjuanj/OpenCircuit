import CoreLocation
import HealthKit
import OpenCircuitKit
import XCTest
@testable import OpenCircuit

/// #365: an outdoor GPS workout reaches Apple Health with fine-grained distance and per-km /
/// per-mile segment events, written by the strap's real `save` through a recording builder (the
/// ring's `writeWorkout` makes the same `WorkoutRouteDetail` calls).
@MainActor
final class WorkoutRouteDetailTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    private final class Builder: StrapWorkoutBuilding {
        var samples: [HKSample] = []
        var eventCalls: [[HKWorkoutEvent]] = []
        var refuseSplitEvents = false
        var refuseBatchesLargerThan: Int?
        func beginCollection(at date: Date) async throws {}
        func addWorkoutEvents(_ events: [HKWorkoutEvent]) async throws {
            if refuseSplitEvents, events.contains(where: { $0.type == .segment }) { throw CocoaError(.validationInvalidDate) }
            eventCalls.append(events)
        }
        func addSamples(_ samples: [HKSample]) async throws {
            if let max = refuseBatchesLargerThan, samples.count > max { throw CocoaError(.validationInvalidDate) }
            self.samples += samples
        }
        func addMetadata(_ metadata: [String: Any]) async throws {}
        func endCollection(at date: Date) async throws {}
        func finishWorkout() async throws -> HKWorkout? { nil }

        func distance(_ id: HKQuantityTypeIdentifier) -> [HKQuantitySample] {
            samples.compactMap { $0 as? HKQuantitySample }.filter { $0.quantityType == HKQuantityType(id) }
        }
        var events: [HKWorkoutEvent] { eventCalls.flatMap { $0 } }
    }

    /// A straight run north at `speed` m/s, a fix every 2 s, from `from` to `to` seconds.
    private func route(from: TimeInterval, to: TimeInterval, speed: Double, startLat: Double = 25.7) -> [CLLocation] {
        stride(from: from, through: to, by: 2).map { s in
            CLLocation(coordinate: CLLocationCoordinate2D(latitude: startLat + (s - from) * speed / 111_000, longitude: -80.2),
                       altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: at(s))
        }
    }

    private func liveDistance(_ route: [CLLocation], pauses: [DateInterval]) -> Double {
        // What the live counter adds: every step except the first one after a resume.
        var total = 0.0
        for (a, b) in zip(route, route.dropFirst())
        where !pauses.contains(where: { $0.start < b.timestamp && $0.end > a.timestamp }) {
            total += b.distance(from: a)
        }
        return total
    }

    private func write(sport: WorkoutSportType = .runningOutdoor, route: [CLLocation], pauses: [DateInterval] = [],
                       end: TimeInterval, distance: Double? = nil) -> StrapWorkoutWrite {
        let meters = distance ?? liveDistance(route, pauses: pauses)
        let summary = WorkoutSummary(sport: sport, startDate: t0, endDate: at(end), avgHR: nil, maxHR: nil,
                                     estimatedActiveKcal: nil, zoneBreakdown: WorkoutZoneBreakdown(),
                                     distanceMeters: meters, hasRoute: true, hrSampleCount: 0)
        return StrapWorkoutWrite(summary: StrapWorkoutSummary(summary: summary, activeSeconds: end, pauses: pauses, gaps: []),
                                 samples: [], route: route,
                                 timeline: .timeline(for: .zeppOS(model: "Helio Strap"), identityID: "STRAP-A"))
    }

    private func save(_ w: StrapWorkoutWrite, _ builder: Builder) async {
        let writer = StrapWorkoutHealthWriter(isHealthDataAvailable: { true }, makeBuilder: { _, _ in builder })
        _ = await writer.save(w)
    }

    func testARunGetsFineDistanceThatAddsUpAndKmAndMileSegments() async {
        // 3 m/s for 1 200 s ≈ 3.6 km: 3 km splits and 2 mile splits.
        let w = write(route: route(from: 0, to: 1_200, speed: 3), end: 1_200)
        let builder = Builder()
        await save(w, builder)
        let distance = builder.distance(.distanceWalkingRunning)
        XCTAssertGreaterThan(distance.count, 50, "per ~15 s, not one sample for the whole workout")
        XCTAssertEqual(distance.reduce(0) { $0 + $1.quantity.doubleValue(for: .meter()) },
                       w.summary.summary.distanceMeters ?? 0, accuracy: 1e-6, "same total as before")
        XCTAssertTrue(distance.allSatisfy { $0.startDate >= t0 && $0.endDate <= at(1_200) && $0.endDate > $0.startDate })
        let segments = builder.events.filter { $0.type == .segment }
        XCTAssertEqual(segments.count, 3 + 2)
        XCTAssertEqual(segments.first?.dateInterval.start, t0, "the first split runs from the start")
        XCTAssertEqual(segments.first?.dateInterval.duration ?? 0, 1_000.0 / 3, accuracy: 3)
    }

    func testDistanceNeverSpansAPauseAndPausesStillWritten() async {
        let pause = DateInterval(start: at(401), end: at(700))
        let fixes = route(from: 0, to: 400, speed: 3) + route(from: 702, to: 1_200, speed: 3, startLat: 25.72)
        let builder = Builder()
        await save(write(route: fixes, pauses: [pause], end: 1_200), builder)
        let distance = builder.distance(.distanceWalkingRunning)
        XCTAssertFalse(distance.isEmpty)
        XCTAssertFalse(distance.contains { $0.startDate < pause.end && $0.endDate > pause.start })
        XCTAssertTrue(builder.events.contains { $0.type == .pause })
        XCTAssertTrue(builder.events.contains { $0.type == .resume })
    }

    func testARefusedSplitCallKeepsThePauseEvents() async {
        let pause = DateInterval(start: at(401), end: at(700))
        let fixes = route(from: 0, to: 400, speed: 3) + route(from: 702, to: 1_200, speed: 3, startLat: 25.72)
        let builder = Builder()
        builder.refuseSplitEvents = true
        await save(write(route: fixes, pauses: [pause], end: 1_200), builder)
        XCTAssertEqual(builder.events.map(\.type), [.pause, .resume])
    }

    func testARefusedDetailBatchFallsBackToTheOneSample() async {
        let w = write(route: route(from: 0, to: 600, speed: 3), end: 600)
        let builder = Builder()
        builder.refuseBatchesLargerThan = 1
        await save(w, builder)
        let distance = builder.distance(.distanceWalkingRunning)
        XCTAssertEqual(distance.count, 1, "never a workout left without its distance")
        XCTAssertEqual(distance.first?.startDate, t0)
    }

    func testARouteThatDoesNotAddUpWritesTheOneSampleAsBefore() async {
        let fixes = route(from: 0, to: 600, speed: 3)
        let builder = Builder()
        await save(write(route: fixes, end: 600, distance: liveDistance(fixes, pauses: []) + 50), builder)
        let distance = builder.distance(.distanceWalkingRunning)
        XCTAssertEqual(distance.count, 1)
        XCTAssertEqual(distance.first?.startDate, t0)
        XCTAssertEqual(distance.first?.endDate, at(600))
    }

    func testCyclingDetailGoesToCyclingDistance() async {
        let builder = Builder()
        await save(write(sport: .cyclingOutdoor, route: route(from: 0, to: 600, speed: 8), end: 600), builder)
        XCTAssertGreaterThan(builder.distance(.distanceCycling).count, 10)
        XCTAssertTrue(builder.distance(.distanceWalkingRunning).isEmpty)
    }

    func testAFixStampedBeforeStartIsClampedIntoTheWorkout() async {
        let fixes = route(from: -4, to: 600, speed: 3)
        let builder = Builder()
        await save(write(route: fixes, end: 600), builder)
        let distance = builder.distance(.distanceWalkingRunning)
        XCTAssertGreaterThan(distance.count, 1)
        XCTAssertTrue(distance.allSatisfy { $0.startDate >= t0 })
    }

    // MARK: The detail screen's splits

    func testDetailSplitRowsInTheUsersUnit() {
        let fixes = route(from: 0, to: 1_200, speed: 3)
        let item = WorkoutHistoryReader.Item(
            id: UUID(), activityType: .running, start: t0, end: at(1_200), activeKcal: nil,
            distanceMeters: liveDistance(fixes, pauses: []), avgHR: nil)
        let km = WorkoutDetailContent.splitRows(route: fixes, item: item, unit: .metric)
        XCTAssertEqual(km.prefix(3).map(\.label), ["Km 1", "Km 2", "Km 3"])
        XCTAssertTrue(km.first?.value.hasPrefix("5:3") == true && km.first?.value.hasSuffix(" /km") == true,
                      "≈ 3 m/s: \(km.first?.value ?? "nil")")
        XCTAssertEqual(km.last?.isPartial, true)
        let mi = WorkoutDetailContent.splitRows(route: fixes, item: item, unit: .imperial)
        XCTAssertEqual(mi.prefix(2).map(\.label), ["Mile 1", "Mile 2"])
        XCTAssertTrue(WorkoutDetailContent.splitRows(route: [], item: item, unit: .metric).isEmpty)
    }
}

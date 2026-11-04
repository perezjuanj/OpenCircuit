import CoreLocation
import HealthKit
import OpenCircuitKit
import XCTest
@testable import OpenCircuit

/// #365: an outdoor GPS workout reaches Apple Health with fine-grained distance and per-km /
/// per-mile segment events. `WorkoutRouteDetail.addDistance` is the one path both writers use (the
/// ring's `writeWorkout` and the strap's `save` each just call it); it is tested here directly and
/// through the strap's real `save` with a recording builder.
@MainActor
final class WorkoutRouteDetailTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    private final class Builder: StrapWorkoutBuilding {
        var samples: [HKSample] = []
        var eventCalls: [[HKWorkoutEvent]] = []
        var refuseSplitEvents = false
        var refuseBatchesLargerThan: Int?
        var refuseAllSamples = false
        func beginCollection(at date: Date) async throws {}
        func addWorkoutEvents(_ events: [HKWorkoutEvent]) async throws {
            if refuseSplitEvents, events.contains(where: { $0.type == .segment }) { throw CocoaError(.validationInvalidDate) }
            eventCalls.append(events)
        }
        func addSamples(_ samples: [HKSample]) async throws {
            if refuseAllSamples { throw CocoaError(.validationInvalidDate) }
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
        var segments: [HKWorkoutEvent] { events.filter { $0.type == .segment } }
    }

    /// The live counter, as both recorders run it: fixes in DELIVERY order, none kept while paused,
    /// and no step across a resume (`lastLocation = nil`). It notes leg starts the way the recorders
    /// do. Independent of the save's own rules, so a save that disagrees with it fails.
    private struct Counter {
        enum Event { case fix(CLLocation), pause, resume }
        var route: [CLLocation] = []
        var legStarts: [Int] = []
        var meters = 0.0
        private var last: CLLocation?
        private var paused = false
        init(_ events: [Event]) {
            for event in events {
                switch event {
                case .pause: paused = true
                case .resume: paused = false; last = nil
                case .fix(let location):
                    guard !paused else { continue }
                    if let last { meters += location.distance(from: last) } else { legStarts.append(route.count) }
                    last = location
                    route.append(location)
                }
            }
        }
    }

    private func fix(_ s: TimeInterval, northMeters: Double) -> CLLocation {
        CLLocation(coordinate: CLLocationCoordinate2D(latitude: 25.7 + northMeters / 111_000, longitude: -80.2),
                   altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: at(s))
    }

    /// A straight run north at `speed` m/s, a fix every 2 s, from `from` to `to` seconds.
    private func run(from: TimeInterval, to: TimeInterval, speed: Double, offset: Double = 0) -> [Counter.Event] {
        stride(from: from, through: to, by: 2).map { .fix(fix($0, northMeters: offset + ($0 - from) * speed)) }
    }

    private func write(_ counter: Counter, sport: WorkoutSportType = .runningOutdoor, pauses: [DateInterval] = [],
                       end: TimeInterval, distance: Double? = nil, legStarts: [Int]? = nil) -> StrapWorkoutWrite {
        let summary = WorkoutSummary(sport: sport, startDate: t0, endDate: at(end), avgHR: nil, maxHR: nil,
                                     estimatedActiveKcal: nil, zoneBreakdown: WorkoutZoneBreakdown(),
                                     distanceMeters: distance ?? counter.meters, hasRoute: true, hrSampleCount: 0)
        return StrapWorkoutWrite(summary: StrapWorkoutSummary(summary: summary, activeSeconds: end, pauses: pauses, gaps: []),
                                 samples: [], route: counter.route,
                                 timeline: .timeline(for: .zeppOS(model: "Helio Strap"), identityID: "STRAP-A"),
                                 routeLegStarts: legStarts ?? counter.legStarts)
    }

    private func save(_ w: StrapWorkoutWrite, _ builder: Builder) async {
        let writer = StrapWorkoutHealthWriter(isHealthDataAvailable: { true }, makeBuilder: { _, _ in builder })
        _ = await writer.save(w)
    }

    private func sum(_ samples: [HKQuantitySample]) -> Double {
        samples.reduce(0) { $0 + $1.quantity.doubleValue(for: .meter()) }
    }

    // MARK: Through the strap's save

    func testARunGetsFineDistanceThatAddsUpAndKmAndMileSegments() async {
        // 3 m/s for 1 200 s ≈ 3.6 km: 3 km splits and 2 mile splits.
        let counter = Counter(run(from: 0, to: 1_200, speed: 3))
        let builder = Builder()
        await save(write(counter, end: 1_200), builder)
        let distance = builder.distance(.distanceWalkingRunning)
        XCTAssertGreaterThan(distance.count, 50, "per ~15 s, not one sample for the whole workout")
        XCTAssertEqual(sum(distance), counter.meters, accuracy: 1e-6, "same total as the live counter")
        XCTAssertTrue(distance.allSatisfy { $0.startDate >= t0 && $0.endDate <= at(1_200) && $0.endDate > $0.startDate })
        XCTAssertEqual(builder.segments.count, 3 + 2)
        XCTAssertEqual(builder.segments.first?.dateInterval.start, t0, "the first split runs from the start")
        XCTAssertEqual(builder.segments.first?.dateInterval.duration ?? 0, 1_000.0 / 3, accuracy: 3)
    }

    func testDistanceNeverSpansAPauseAndPausesStillWritten() async {
        let pause = DateInterval(start: at(401), end: at(700))
        let counter = Counter(run(from: 0, to: 400, speed: 3) + [.pause, .resume]
                              + run(from: 702, to: 1_200, speed: 3, offset: 2_000))
        let builder = Builder()
        await save(write(counter, pauses: [pause], end: 1_200), builder)
        let distance = builder.distance(.distanceWalkingRunning)
        XCTAssertGreaterThan(distance.count, 1)
        XCTAssertEqual(sum(distance), counter.meters, accuracy: 1e-6)
        XCTAssertFalse(distance.contains { $0.startDate < pause.end && $0.endDate > pause.start })
        XCTAssertTrue(builder.events.contains { $0.type == .pause })
        XCTAssertTrue(builder.events.contains { $0.type == .resume })
    }

    /// Review SF1: fixes stamped across the pause edges but delivered after Resume. The recorder's
    /// leg marks replay the counter exactly, so a short run keeps its detail instead of falling back.
    func testFixesStampedAcrossThePauseEdgesStillReplayTheCounterExactly() async {
        // Lagging: delivered after Resume, stamped 0.4 s before it.
        let lag = Counter(run(from: 0, to: 100, speed: 3) + [.pause, .resume, .fix(fix(199.6, northMeters: 400))]
                          + run(from: 202, to: 300, speed: 3, offset: 406))
        // Stale: a 6 s pause, then a fix stamped before the pause delivered after Resume.
        let stale = Counter(run(from: 0, to: 100, speed: 3) + [.pause, .resume, .fix(fix(99.5, northMeters: 301))]
                            + run(from: 108, to: 300, speed: 3, offset: 320))
        for (counter, pause) in [(lag, DateInterval(start: at(100.5), end: at(200))),
                                 (stale, DateInterval(start: at(100.5), end: at(106.5)))] {
            let builder = Builder()
            await save(write(counter, pauses: [pause], end: 300), builder)
            let distance = builder.distance(.distanceWalkingRunning)
            XCTAssertGreaterThan(distance.count, 1, "detail kept: the marks match the counter")
            XCTAssertEqual(sum(distance), counter.meters, accuracy: 1e-6)
        }
    }

    func testARefusedSplitCallKeepsThePauseEvents() async {
        let pause = DateInterval(start: at(401), end: at(700))
        let counter = Counter(run(from: 0, to: 400, speed: 3) + [.pause, .resume]
                              + run(from: 702, to: 1_200, speed: 3, offset: 2_000))
        let builder = Builder()
        builder.refuseSplitEvents = true
        await save(write(counter, pauses: [pause], end: 1_200), builder)
        XCTAssertEqual(builder.events.map(\.type), [.pause, .resume])
        XCTAssertGreaterThan(builder.distance(.distanceWalkingRunning).count, 1, "the distance detail still landed")
    }

    func testARefusedDetailBatchFallsBackToTheOneSampleAndNoSplits() async {
        let counter = Counter(run(from: 0, to: 600, speed: 3))
        let builder = Builder()
        builder.refuseBatchesLargerThan = 1
        await save(write(counter, end: 600), builder)
        let distance = builder.distance(.distanceWalkingRunning)
        XCTAssertEqual(distance.count, 1, "never a workout left without its distance")
        XCTAssertEqual(distance.first?.startDate, t0)
        XCTAssertTrue(builder.segments.isEmpty, "no splits describing samples that aren't there")
    }

    func testARouteThatDoesNotAddUpWritesTheOneSampleAsBeforeAndNoSplits() async {
        let counter = Counter(run(from: 0, to: 1_200, speed: 3))
        let builder = Builder()
        await save(write(counter, end: 1_200, distance: counter.meters + 50), builder)
        let distance = builder.distance(.distanceWalkingRunning)
        XCTAssertEqual(distance.count, 1)
        XCTAssertEqual(distance.first?.startDate, t0)
        XCTAssertEqual(distance.first?.endDate, at(1_200))
        XCTAssertTrue(builder.segments.isEmpty)
    }

    func testCyclingDetailGoesToCyclingDistance() async {
        let builder = Builder()
        await save(write(Counter(run(from: 0, to: 600, speed: 8)), sport: .cyclingOutdoor, end: 600), builder)
        XCTAssertGreaterThan(builder.distance(.distanceCycling).count, 10)
        XCTAssertTrue(builder.distance(.distanceWalkingRunning).isEmpty)
    }

    func testAFixStampedBeforeStartIsClampedIntoTheWorkout() async {
        let counter = Counter(run(from: -4, to: 600, speed: 3))
        let builder = Builder()
        await save(write(counter, end: 600), builder)
        let distance = builder.distance(.distanceWalkingRunning)
        XCTAssertGreaterThan(distance.count, 1)
        XCTAssertTrue(distance.allSatisfy { $0.startDate >= t0 })
        XCTAssertEqual(sum(distance), counter.meters, accuracy: 1e-6)
    }

    // MARK: The shared path directly (what the ring's writeWorkout calls)

    private func addDistance(_ counter: Counter, meters: Double? = nil, end: TimeInterval,
                             _ builder: Builder) async -> Bool {
        await WorkoutRouteDetail.addDistance(
            meters: meters ?? counter.meters, type: HKQuantityType(.distanceWalkingRunning), route: counter.route,
            legStarts: counter.legStarts, pauses: [], start: t0, end: at(end),
            addSamples: { try await builder.addSamples($0) }, addEvents: { try await builder.addWorkoutEvents($0) })
    }

    func testTheSamplesAreScaledToTheWorkoutsExactDistance() async {
        let counter = Counter(run(from: 0, to: 300, speed: 3))
        let builder = Builder()
        let landed = await addDistance(counter, meters: counter.meters + 0.5, end: 300, builder)
        XCTAssertTrue(landed)
        XCTAssertGreaterThan(builder.distance(.distanceWalkingRunning).count, 1)
        XCTAssertEqual(sum(builder.distance(.distanceWalkingRunning)), counter.meters + 0.5, accuracy: 1e-6)
    }

    func testSplitEventsAreOneCallInStartOrderAndAlignWithTheSamples() async throws {
        let counter = Counter(run(from: 0, to: 2_400, speed: 3))   // ≈ 7.2 km
        let builder = Builder()
        _ = await addDistance(counter, end: 2_400, builder)
        XCTAssertEqual(builder.eventCalls.count, 1)
        let segments = builder.segments
        XCTAssertEqual(segments.map(\.dateInterval.start), segments.map(\.dateInterval.start).sorted())
        // The first km boundary sits where the written samples reach 1 000 m.
        let firstKm = try XCTUnwrap(segments.filter { $0.dateInterval.start == t0 }.map(\.dateInterval.end).min())
        let before = builder.distance(.distanceWalkingRunning).filter { $0.endDate <= firstKm }
        XCTAssertEqual(sum(before), 1_000, accuracy: 50, "within one ~16 s sample (≈ 48 m) of the boundary")
    }

    func testNothingLandedReportsFalseSoTheDayIsNotCredited() async {
        let builder = Builder()
        builder.refuseAllSamples = true
        let landed = await addDistance(Counter(run(from: 0, to: 600, speed: 3)), end: 600, builder)
        XCTAssertFalse(landed)
        XCTAssertTrue(builder.segments.isEmpty)
    }

    // MARK: The detail screen's splits

    func testDetailSplitRowsInTheUsersUnit() {
        let counter = Counter(run(from: 0, to: 1_200, speed: 3))
        let item = WorkoutHistoryReader.Item(
            id: UUID(), activityType: .running, start: t0, end: at(1_200), activeKcal: nil,
            distanceMeters: counter.meters, avgHR: nil)
        let km = WorkoutDetailContent.splitRows(route: counter.route, item: item, unit: .metric)
        XCTAssertEqual(km.prefix(3).map(\.label), ["Km 1", "Km 2", "Km 3"])
        XCTAssertTrue(km.first?.value.hasPrefix("5:3") == true && km.first?.value.hasSuffix(" /km") == true,
                      "≈ 3 m/s: \(km.first?.value ?? "nil")")
        XCTAssertEqual(km.last?.isPartial, true)
        let mi = WorkoutDetailContent.splitRows(route: counter.route, item: item, unit: .imperial)
        XCTAssertEqual(mi.prefix(2).map(\.label), ["Mile 1", "Mile 2"])
        XCTAssertTrue(WorkoutDetailContent.splitRows(route: [], item: item, unit: .metric).isEmpty)
    }
}

import BackgroundTasks
import XCTest
import OpenCircuitKit
@testable import OpenCircuit

final class BackgroundRefreshSchedulerTests: XCTestCase {
    func testRequestUsesExpectedIdentifierAndFifteenMinuteEarliestBeginDate() {
        let now = Date(timeIntervalSince1970: 1_000)
        let scheduler = BackgroundRefreshScheduler(
            scheduler: RecordingScheduler(),
            now: { now },
            window: { _ in nil }   // no sleep window in sight → plain interval
        )

        let request = scheduler.makeRequest()

        XCTAssertEqual(request.identifier, BackgroundRefreshScheduler.identifier)
        XCTAssertEqual(
            request.earliestBeginDate?.timeIntervalSince1970,
            now.addingTimeInterval(15 * 60).timeIntervalSince1970
        )
    }

    func testScheduleSubmitsRefreshRequest() {
        let recording = RecordingScheduler()
        let now = Date(timeIntervalSince1970: 2_000)
        let scheduler = BackgroundRefreshScheduler(
            scheduler: recording,
            now: { now },
            window: { _ in nil }
        )

        scheduler.schedule()

        XCTAssertEqual(recording.cancelledIdentifier, BackgroundRefreshScheduler.identifier)
        XCTAssertEqual(recording.submitted?.identifier, BackgroundRefreshScheduler.identifier)
        XCTAssertEqual(
            recording.submitted?.earliestBeginDate?.timeIntervalSince1970,
            now.addingTimeInterval(15 * 60).timeIntervalSince1970
        )
    }

    /// #119: a request submitted with the sleep window in progress (e.g. the scenePhase
    /// backgrounding as the user goes to bed) aims at windowEnd − lead, so iOS's discretionary
    /// grant lands on the one run that matters — the morning drain — not mid-night.
    func testRequestInsideSleepWindowAimsAtMorning() {
        let now = Date(timeIntervalSince1970: 100_000)
        let window = DateInterval(start: now.addingTimeInterval(-3_600),
                                  end: now.addingTimeInterval(7 * 3_600))
        let scheduler = BackgroundRefreshScheduler(
            scheduler: RecordingScheduler(),
            now: { now },
            window: { _ in window }
        )

        let request = scheduler.makeRequest()
        let processing = scheduler.makeProcessingRequest()

        let aimed = window.end.addingTimeInterval(-BackgroundSyncPolicy.morningLeadTime)
        XCTAssertEqual(request.earliestBeginDate?.timeIntervalSince1970, aimed.timeIntervalSince1970)
        XCTAssertEqual(processing.earliestBeginDate?.timeIntervalSince1970, aimed.timeIntervalSince1970)
    }
}

private final class RecordingScheduler: BGTaskScheduling {
    private(set) var cancelledIdentifier: String?
    private(set) var submitted: BGTaskRequest?

    func register(forTaskWithIdentifier identifier: String,
                  using queue: DispatchQueue?,
                  launchHandler: @escaping (BGTask) -> Void) -> Bool {
        true
    }

    func cancel(taskRequestWithIdentifier identifier: String) {
        cancelledIdentifier = identifier
    }

    func submit(_ taskRequest: BGTaskRequest) throws {
        submitted = taskRequest
    }
}

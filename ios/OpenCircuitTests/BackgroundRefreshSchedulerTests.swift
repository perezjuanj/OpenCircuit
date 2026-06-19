import BackgroundTasks
import XCTest
@testable import OpenCircuit

final class BackgroundRefreshSchedulerTests: XCTestCase {
    func testRequestUsesExpectedIdentifierAndFifteenMinuteEarliestBeginDate() {
        let now = Date(timeIntervalSince1970: 1_000)
        let scheduler = BackgroundRefreshScheduler(
            scheduler: RecordingScheduler(),
            now: { now }
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
            now: { now }
        )

        scheduler.schedule()

        XCTAssertEqual(recording.cancelledIdentifier, BackgroundRefreshScheduler.identifier)
        XCTAssertEqual(recording.submitted?.identifier, BackgroundRefreshScheduler.identifier)
        XCTAssertEqual(
            recording.submitted?.earliestBeginDate?.timeIntervalSince1970,
            now.addingTimeInterval(15 * 60).timeIntervalSince1970
        )
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

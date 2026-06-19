import SwiftData
import XCTest
@testable import OpenCircuit

@MainActor
final class LocalStoreLaunchTests: XCTestCase {
    func testLaunchSnapshotReadsLastKnownHeartRate() throws {
        let container = try ModelContainer(
            for: StoredSample.self, StoredCursor.self,
            StoredSleepSummary.self, StoredDaily.self, StoredNap.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        context.insert(StoredSample(
            kindRaw: "heartRate",
            start: Date(timeIntervalSince1970: 100),
            end: Date(timeIntervalSince1970: 100),
            value: 71
        ))
        context.insert(StoredSample(
            kindRaw: "heartRate",
            start: Date(timeIntervalSince1970: 200),
            end: Date(timeIntervalSince1970: 200),
            value: 74
        ))
        try context.save()

        let snapshot = try LaunchSnapshot.load(from: LocalStore(context))

        XCTAssertEqual(snapshot.lastHeartRate?.value, 74)
    }
}

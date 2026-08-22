// THE QUEUED RECONCILE FROM AN OLDER BUILD MUST NOT DECODE AS FULLY MEASURED.
//
// `PendingSleepReconcile` carries `[SleepSegment]`, and `SleepSegment.init(from:)` decodes a missing
// `provenance` key as `.measured` — deliberately, because a segment an older build STAGED really was
// measured and that decision keeps `EpochArchiveStore.loadPendingSleepSegments` working across the
// upgrade. But an older build's EDIT put invented fill in this queue with no provenance key at all.
// Read back under the coverage filter, every invented minute in it would look measured and would be
// written to Apple Health once, on the first flush after upgrade — by the very build that exists to
// stop that write.
//
// The fix is a version suffix on the storage key. These tests pin both halves of it: the old queue
// is never decoded, and it does not linger in UserDefaults.

import XCTest
import OpenCircuitKit
@testable import OpenCircuit

final class PendingSleepReconcileKeyTests: XCTestCase {

    private let v1Key = "sleep.edit.pending-reconcile.v1"
    private let v2Key = "sleep.edit.pending-reconcile.v2"
    private let night = Date(timeIntervalSince1970: 1_750_000_000)

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: v1Key)
        UserDefaults.standard.removeObject(forKey: v2Key)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: v1Key)
        UserDefaults.standard.removeObject(forKey: v2Key)
        super.tearDown()
    }

    /// Exactly what a pre-provenance build wrote: segments with no `provenance` key.
    private func writeLegacyQueue() throws {
        let legacy: [[String: Any]] = [[
            "night": night.timeIntervalSinceReferenceDate,
            "inBedStart": night.timeIntervalSinceReferenceDate,
            "sleepOnset": night.timeIntervalSinceReferenceDate,
            "sleepWake": night.addingTimeInterval(8 * 3600).timeIntervalSinceReferenceDate,
            "segments": [[
                "start": night.timeIntervalSinceReferenceDate,
                "end": night.addingTimeInterval(8 * 3600).timeIntervalSinceReferenceDate,
                "stage": "asleepCore",
            ]],
        ]]
        UserDefaults.standard.set(try JSONSerialization.data(withJSONObject: legacy), forKey: v1Key)
    }

    func testTheLegacyBlobReallyWOULDDecodeAsFullyMeasured() throws {
        // The premise, proven rather than asserted: this is why the key had to move. If Codable ever
        // stops defaulting the missing key to `.measured`, this test says so and the bump can be
        // reconsidered.
        try writeLegacyQueue()
        let data = try XCTUnwrap(UserDefaults.standard.data(forKey: v1Key))
        let decoded = try JSONDecoder().decode([PendingSleepReconcile].self, from: data)
        XCTAssertEqual(decoded.first?.segments.first?.provenance, .measured)
        XCTAssertFalse(decoded.first?.segments.containsAssertedTime ?? true,
                       "8 hours of possibly-invented sleep, indistinguishable from measured")
    }

    func testAQueueWrittenByAnOlderBuildIsNeverDrained() throws {
        try writeLegacyQueue()
        XCTAssertTrue(PendingSleepReconcileStore.all().isEmpty,
                      "the v1 queue must not be readable by this build")
    }

    func testTheAbandonedQueueIsDroppedRatherThanLeftInUserDefaults() throws {
        try writeLegacyQueue()
        _ = PendingSleepReconcileStore.all()
        XCTAssertNil(UserDefaults.standard.object(forKey: v1Key),
                     "the unreadable blob is cleared once, not kept forever")
    }

    func testThisBuildsOwnQueueStillRoundTripsUnderTheNewKey() {
        let item = PendingSleepReconcile(
            night: night, inBedStart: night, sleepOnset: night,
            sleepWake: night.addingTimeInterval(8 * 3600),
            segments: [SleepSegment(start: night, end: night.addingTimeInterval(3600),
                                    stage: .asleepCore, provenance: .asserted)])
        PendingSleepReconcileStore.upsert(item)

        XCTAssertNotNil(UserDefaults.standard.data(forKey: v2Key))
        XCTAssertEqual(PendingSleepReconcileStore.all(), [item])
        XCTAssertEqual(PendingSleepReconcileStore.all().first?.segments.first?.provenance, .asserted,
                       "a queued item now carries its provenance across the flush boundary")

        PendingSleepReconcileStore.clear(night: night)
        XCTAssertTrue(PendingSleepReconcileStore.all().isEmpty)
    }
}

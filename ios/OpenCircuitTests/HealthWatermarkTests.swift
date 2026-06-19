import SwiftData
import XCTest
import OpenCircuitKit
@testable import OpenCircuit

@MainActor
final class HealthWatermarkTests: XCTestCase {
    private func makeStore() throws -> LocalStore {
        let container = try ModelContainer(
            for: StoredSample.self, StoredCursor.self,
            StoredSleepSummary.self, StoredDaily.self, StoredNap.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return LocalStore(container.mainContext)
    }

    private func hr(_ value: Double, _ t: TimeInterval) -> QuantitySample {
        QuantitySample(kind: .heartRate, start: Date(timeIntervalSince1970: t), value: value)
    }

    /// The dashboard auto-persist (`ingest`) must NOT starve the Health write: samples
    /// persisted for the dashboard still appear in `pendingHealthSamples` until they're
    /// explicitly marked written. (Regression test for the shared-cursor bug.)
    func testAutoPersistDoesNotStarveHealthWrite() throws {
        let store = try makeStore()
        _ = try store.ingest([hr(70, 100), hr(72, 200)])   // dashboard auto-persist

        let pending = try store.pendingHealthSamples()
        XCTAssertEqual(pending.map(\.value), [70, 72])
    }

    /// After a confirmed Health write the watermark advances, so the same samples aren't
    /// offered again — but newer samples synced afterward still surface.
    func testMarkWrittenAdvancesWatermark() throws {
        let store = try makeStore()
        _ = try store.ingest([hr(70, 100), hr(72, 200)])
        let first = try store.pendingHealthSamples()
        try store.markHealthWritten(first)

        XCTAssertTrue(try store.pendingHealthSamples().isEmpty)

        _ = try store.ingest([hr(75, 300)])
        XCTAssertEqual(try store.pendingHealthSamples().map(\.value), [75])
    }

    /// An un-authorized / failed write leaves the watermark untouched, so the samples
    /// backfill on the next flush (no data lost to a one-off Health failure).
    func testUnwrittenSamplesBackfill() throws {
        let store = try makeStore()
        _ = try store.ingest([hr(70, 100)])
        _ = try store.pendingHealthSamples()   // read but DON'T mark written

        XCTAssertEqual(try store.pendingHealthSamples().map(\.value), [70])
    }

    /// Zero/placeholder values never go to Health.
    func testZeroValuesExcluded() throws {
        let store = try makeStore()
        _ = try store.ingest([hr(0, 100), hr(70, 200)])
        XCTAssertEqual(try store.pendingHealthSamples().map(\.value), [70])
    }
}

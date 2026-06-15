import Foundation
import OpenRingKit

@MainActor
struct RingBackgroundSyncService {
    private let store: LocalStore
    private let health: HealthKitWriter

    init(store: LocalStore, health: HealthKitWriter) {
        self.store = store
        self.health = health
    }

    /// One bounded background read: connect, grab a live HR sample AND the skin temperature
    /// the descriptor streams on connect, persist both, disconnect. Wiring the store into the
    /// scanner lets `RingSession` auto-persist temperature; HR is persisted here. Returns true
    /// if an HR sample was captured (the BGTask success flag).
    @discardableResult
    func syncVitals(timeout: TimeInterval = 20) async throws -> Bool {
        let scanner = RingScanner.shared
        scanner.setLocalStore(store)   // RingSession persists skin temp from the descriptor
        let hr = await scanner.readLiveHeartRate(timeout: timeout)

        guard let hr else { return false }
        let fresh = try store.ingest([QuantitySample(kind: .heartRate, start: Date(), value: Double(hr))])
        if HealthKitWriter.isAvailable, !fresh.isEmpty {
            try? await health.write(fresh)
        }
        return true
    }
}

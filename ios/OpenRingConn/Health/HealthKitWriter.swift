import Foundation
import HealthKit
import OpenRingKit

// Writes ring metrics into Apple Health. Type/unit choices follow
// docs/HEALTHKIT_MAPPING.md. Samples are saved with the device's own timestamps
// so history backfills; a stable bundle id + the SyncCursor avoid duplicates.

@MainActor
final class HealthKitWriter {
    private let store = HKHealthStore()

    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    /// HKQuantityType for a scalar metric, or nil for non-quantity kinds (sleep).
    static func quantityType(for kind: MetricKind) -> HKQuantityType? {
        let id: HKQuantityTypeIdentifier
        switch kind {
        case .heartRate: id = .heartRate
        case .restingHeartRate: id = .restingHeartRate
        case .hrvSDNN: id = .heartRateVariabilitySDNN
        case .spo2: id = .oxygenSaturation
        case .temperature: id = .bodyTemperature
        case .respiratoryRate: id = .respiratoryRate
        case .steps: id = .stepCount
        case .activeEnergy: id = .activeEnergyBurned
        case .sleep: return nil
        }
        return HKQuantityType(id)
    }

    /// HKUnit matching MetricKind.unit (the canonical units in OpenRingKit).
    static func unit(for kind: MetricKind) -> HKUnit {
        switch kind {
        case .heartRate, .restingHeartRate, .respiratoryRate:
            return HKUnit.count().unitDivided(by: .minute())
        case .hrvSDNN: return .secondUnit(with: .milli)
        case .spo2: return .percent()                 // value is a 0…1 fraction
        case .temperature: return .degreeCelsius()
        case .steps: return .count()
        case .activeEnergy: return .kilocalorie()
        case .sleep: return .count()                  // unused
        }
    }

    private var allTypes: Set<HKSampleType> {
        var set = Set<HKSampleType>()
        for k in MetricKind.allCases {
            if let t = Self.quantityType(for: k) { set.insert(t) }
        }
        set.insert(HKQuantityType(.basalEnergyBurned))
        set.insert(HKCategoryType(.sleepAnalysis))
        return set
    }

    func requestAuthorization() async throws {
        // Read sleepAnalysis so the iOS Sleep-schedule window (HealthKitSleepSchedule) works
        // the moment the HealthKit entitlement is enabled — no further auth change needed.
        // (No effect today: without the entitlement the request is a no-op, so it can't prompt.)
        try await store.requestAuthorization(toShare: allTypes, read: [HKCategoryType(.sleepAnalysis)])
    }

    /// Write scalar samples. Caller filters with SyncCursor first.
    func write(_ samples: [QuantitySample]) async throws {
        let hkSamples: [HKQuantitySample] = samples.compactMap { s in
            guard let type = Self.quantityType(for: s.kind) else { return nil }
            let q = HKQuantity(unit: Self.unit(for: s.kind), doubleValue: s.value)
            return HKQuantitySample(type: type, quantity: q, start: s.start, end: s.end)
        }
        guard !hkSamples.isEmpty else { return }
        try await store.save(hkSamples)
    }

    func writePassiveCalories(profile: UserProfile, date: Date) async throws {
        let type = HKQuantityType(.basalEnergyBurned)
        let quantity = HKQuantity(
            unit: .kilocalorie(),
            doubleValue: Calories.bmrKcalPerHour(profile: profile)
        )
        let sample = HKQuantitySample(
            type: type,
            quantity: quantity,
            start: date,
            end: date.addingTimeInterval(3600)
        )
        try await store.save(sample)
    }

    func writeActiveCalories(kcal: Double, date: Date) async throws {
        guard kcal > 0 else { return }
        let type = HKQuantityType(.activeEnergyBurned)
        let quantity = HKQuantity(unit: .kilocalorie(), doubleValue: kcal)
        let sample = HKQuantitySample(
            type: type,
            quantity: quantity,
            start: date,
            end: date.addingTimeInterval(3600)
        )
        try await store.save(sample)
    }

    func writeActiveCalories(hrSamples: [HRSample], profile: UserProfile, date: Date) async throws {
        let maxHR = max(220 - profile.age, 1)
        let kcal = Calories.activeKcal(hrSamples: hrSamples, maxHR: maxHR)
        try await writeActiveCalories(kcal: kcal, date: date)
    }

    /// Write a night as contiguous sleepAnalysis category samples (mapping notes).
    func write(sleep segments: [SleepSegment]) async throws {
        let type = HKCategoryType(.sleepAnalysis)
        let samples = segments.map { seg in
            HKCategorySample(type: type, value: Self.sleepValue(seg.stage).rawValue,
                             start: seg.start, end: seg.end)
        }
        guard !samples.isEmpty else { return }
        try await store.save(samples)
    }

    static func sleepValue(_ stage: SleepStage) -> HKCategoryValueSleepAnalysis {
        switch stage {
        case .inBed: return .inBed
        case .awake: return .awake
        case .asleepCore: return .asleepCore
        case .asleepDeep: return .asleepDeep
        case .asleepREM: return .asleepREM
        }
    }
}

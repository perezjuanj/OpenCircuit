import Foundation
import HealthKit
import OpenCircuitKit

@MainActor
struct HealthKitHistoryInspector {
    private let store = HKHealthStore()

    struct MetricCoverage: Equatable {
        let title: String
        let nightsWithData: Int
        let minimumBaselineNights: Int
        let supportsCurrentBaseline: Bool

        var baselineReady: Bool { nightsWithData >= minimumBaselineNights }
    }

    struct Report: Equatable {
        let lookbackDays: Int
        let nightsFound: Int
        let metrics: [MetricCoverage]
        let missingCapabilities: [String]
    }

    private struct NightWindow: Equatable {
        let key: Date
        let window: DateInterval
    }

    private static let minimumNightDuration: TimeInterval = 3 * 3600
    private static let minimumBaselineNights = SkinTempBaseline.minBaselineNights

    func inspectHistoricalCoverage(lookbackDays: Int = 30) async throws -> Report {
        guard HKHealthStore.isHealthDataAvailable() else {
            return Report(lookbackDays: lookbackDays, nightsFound: 0, metrics: [], missingCapabilities: [])
        }

        let end = Date()
        let start = Calendar.current.date(byAdding: .day, value: -(lookbackDays + 2), to: end) ?? end
        let nights = try await fetchNightWindows(from: start, to: end)
        guard !nights.isEmpty else {
            return Report(
                lookbackDays: lookbackDays,
                nightsFound: 0,
                metrics: [
                    MetricCoverage(title: "Skin temperature", nightsWithData: 0,
                                   minimumBaselineNights: Self.minimumBaselineNights,
                                   supportsCurrentBaseline: true),
                    MetricCoverage(title: "Sleep HR", nightsWithData: 0,
                                   minimumBaselineNights: Self.minimumBaselineNights,
                                   supportsCurrentBaseline: false),
                    MetricCoverage(title: "Sleep HRV", nightsWithData: 0,
                                   minimumBaselineNights: Self.minimumBaselineNights,
                                   supportsCurrentBaseline: true),
                    MetricCoverage(title: "Sleep SpO2", nightsWithData: 0,
                                   minimumBaselineNights: Self.minimumBaselineNights,
                                   supportsCurrentBaseline: true),
                    MetricCoverage(title: "Sleep respiratory rate", nightsWithData: 0,
                                   minimumBaselineNights: Self.minimumBaselineNights,
                                   supportsCurrentBaseline: false),
                ],
                missingCapabilities: Self.defaultMissingCapabilities
            )
        }

        let tempNights = try await countCoveredNights(
            type: HKQuantityType(.bodyTemperature),
            from: start,
            to: end,
            nights: nights,
            minimumValue: 0
        )
        let hrNights = try await countCoveredNights(
            type: HKQuantityType(.heartRate),
            from: start,
            to: end,
            nights: nights,
            minimumValue: 0
        )
        let hrvNights = try await countCoveredNights(
            type: HKQuantityType(.heartRateVariabilitySDNN),
            from: start,
            to: end,
            nights: nights,
            minimumValue: 0
        )
        let spo2Nights = try await countCoveredNights(
            type: HKQuantityType(.oxygenSaturation),
            from: start,
            to: end,
            nights: nights,
            minimumValue: 0
        )
        let rrNights = try await countCoveredNights(
            type: HKQuantityType(.respiratoryRate),
            from: start,
            to: end,
            nights: nights,
            minimumValue: 0
        )

        return Report(
            lookbackDays: lookbackDays,
            nightsFound: nights.count,
            metrics: [
                MetricCoverage(title: "Skin temperature", nightsWithData: tempNights,
                               minimumBaselineNights: Self.minimumBaselineNights,
                               supportsCurrentBaseline: true),
                MetricCoverage(title: "Sleep HR", nightsWithData: hrNights,
                               minimumBaselineNights: Self.minimumBaselineNights,
                               supportsCurrentBaseline: false),
                MetricCoverage(title: "Sleep HRV", nightsWithData: hrvNights,
                               minimumBaselineNights: Self.minimumBaselineNights,
                               supportsCurrentBaseline: true),
                MetricCoverage(title: "Sleep SpO2", nightsWithData: spo2Nights,
                               minimumBaselineNights: Self.minimumBaselineNights,
                               supportsCurrentBaseline: true),
                MetricCoverage(title: "Sleep respiratory rate", nightsWithData: rrNights,
                               minimumBaselineNights: Self.minimumBaselineNights,
                               supportsCurrentBaseline: false),
            ],
            missingCapabilities: Self.defaultMissingCapabilities
        )
    }

    private static let defaultMissingCapabilities: [String] = [
        "Apple Health history can now help Vitals Status baseline-building for skin temperature, overnight HRV and overnight SpO₂.",
        "Apple Health history still can't rebuild OpenCircuit's stage-estimated sleep architecture.",
        "Sleep Score, movement, resting-stage HR and per-stage HR still require ring-native overnight data.",
        "This check is read-only and does not import Apple Health samples into the local store."
    ]

    private func fetchNightWindows(from start: Date, to end: Date) async throws -> [NightWindow] {
        let sleepType = HKCategoryType(.sleepAnalysis)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let samples = try await categorySamples(type: sleepType, predicate: predicate)
        let inBed = HKCategoryValueSleepAnalysis.inBed.rawValue
        let asleep = Set(HKCategoryValueSleepAnalysis.allAsleepValues.map(\.rawValue))
        let relevant = samples.filter { $0.value == inBed || asleep.contains($0.value) }

        var grouped: [Date: DateInterval] = [:]
        let cal = Calendar.current
        for sample in relevant {
            guard sample.endDate > sample.startDate else { continue }
            guard sample.endDate.timeIntervalSince(sample.startDate) >= Self.minimumNightDuration else { continue }
            let key = cal.startOfDay(for: sample.endDate)
            let candidate = DateInterval(start: sample.startDate, end: sample.endDate)
            if let existing = grouped[key] {
                grouped[key] = DateInterval(start: min(existing.start, candidate.start),
                                            end: max(existing.end, candidate.end))
            } else {
                grouped[key] = candidate
            }
        }

        return grouped.keys.sorted().compactMap { key in
            guard let window = grouped[key], window.end > window.start else { return nil }
            return NightWindow(key: key, window: window)
        }
    }

    private func countCoveredNights(
        type: HKQuantityType,
        from start: Date,
        to end: Date,
        nights: [NightWindow],
        minimumValue: Double
    ) async throws -> Int {
        guard !nights.isEmpty else { return 0 }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let samples = try await quantitySamples(type: type, predicate: predicate)
        var covered = Set<Date>()
        for sample in samples where sample.quantity.doubleValue(for: canonicalUnit(for: type)) > minimumValue {
            if let night = nights.first(where: { $0.window.intersects(DateInterval(start: sample.startDate, end: sample.endDate)) }) {
                covered.insert(night.key)
            }
        }
        return covered.count
    }

    private func canonicalUnit(for type: HKQuantityType) -> HKUnit {
        switch type.identifier {
        case HKQuantityTypeIdentifier.heartRate.rawValue,
             HKQuantityTypeIdentifier.respiratoryRate.rawValue:
            return HKUnit.count().unitDivided(by: .minute())
        case HKQuantityTypeIdentifier.heartRateVariabilitySDNN.rawValue:
            return .secondUnit(with: .milli)
        case HKQuantityTypeIdentifier.oxygenSaturation.rawValue:
            return .percent()
        case HKQuantityTypeIdentifier.bodyTemperature.rawValue:
            return .degreeCelsius()
        default:
            return .count()
        }
    }

    private func categorySamples(type: HKCategoryType,
                                 predicate: NSPredicate?) async throws -> [HKCategorySample] {
        try await withCheckedThrowingContinuation { cont in
            let query = HKSampleQuery(sampleType: type, predicate: predicate,
                                      limit: HKObjectQueryNoLimit,
                                      sortDescriptors: [NSSortDescriptor(keyPath: \HKSample.startDate, ascending: true)]) { _, result, error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume(returning: (result as? [HKCategorySample]) ?? [])
                }
            }
            store.execute(query)
        }
    }

    private func quantitySamples(type: HKQuantityType,
                                 predicate: NSPredicate?) async throws -> [HKQuantitySample] {
        try await withCheckedThrowingContinuation { cont in
            let query = HKSampleQuery(sampleType: type, predicate: predicate,
                                      limit: HKObjectQueryNoLimit,
                                      sortDescriptors: [NSSortDescriptor(keyPath: \HKSample.startDate, ascending: true)]) { _, result, error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume(returning: (result as? [HKQuantitySample]) ?? [])
                }
            }
            store.execute(query)
        }
    }
}

@MainActor
struct HealthKitVitalsBaselineReader {
    private let store = HKHealthStore()

    struct DailyValue: Equatable {
        let day: Date
        let value: Double
    }

    struct Report: Equatable {
        let restingHR: [DailyValue]
        let overnightSpO2: [DailyValue]
        let overnightHRV: [DailyValue]
        let skinTempOffsetC: Double?

        var hasAnyData: Bool {
            !restingHR.isEmpty || !overnightSpO2.isEmpty || !overnightHRV.isEmpty || skinTempOffsetC != nil
        }
    }

    private struct NightWindow: Equatable {
        let key: Date
        let window: DateInterval
    }

    private static let minimumNightDuration: TimeInterval = 3 * 3600

    func loadReport(lookbackDays: Int = 32) async throws -> Report {
        guard HKHealthStore.isHealthDataAvailable() else {
            return Report(restingHR: [], overnightSpO2: [], overnightHRV: [], skinTempOffsetC: nil)
        }

        let end = Date()
        let start = Calendar.current.date(byAdding: .day, value: -(lookbackDays + 2), to: end) ?? end
        let nights = try await fetchNightWindows(from: start, to: end)

        let restingHR = try await dailyMeans(
            type: HKQuantityType(.restingHeartRate),
            from: start,
            to: end
        )
        let overnightSpO2 = try await nightlyMeans(
            type: HKQuantityType(.oxygenSaturation),
            from: start,
            to: end,
            nights: nights,
            scale: 100
        )
        let overnightHRV = try await nightlyMeans(
            type: HKQuantityType(.heartRateVariabilitySDNN),
            from: start,
            to: end,
            nights: nights,
            scale: 1
        )
        let nightlyTemp = try await nightlyMeans(
            type: HKQuantityType(.bodyTemperature),
            from: start,
            to: end,
            nights: nights,
            scale: 1
        )

        return Report(
            restingHR: restingHR,
            overnightSpO2: overnightSpO2,
            overnightHRV: overnightHRV,
            skinTempOffsetC: skinTempOffset(from: nightlyTemp)
        )
    }

    private func skinTempOffset(from nights: [DailyValue]) -> Double? {
        let sorted = nights.sorted { $0.day < $1.day }
        guard let latest = sorted.last else { return nil }
        let prior = sorted.dropLast().map { SkinTempBaseline.NightlyTemp(night: $0.day, celsius: $0.value) }
        guard let baseline = SkinTempBaseline.baseline(priorNights: prior) else { return nil }
        return latest.value - baseline
    }

    private func dailyMeans(type: HKQuantityType,
                            from start: Date,
                            to end: Date) async throws -> [DailyValue] {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let samples = try await quantitySamples(type: type, predicate: predicate)
        let unit = canonicalUnit(for: type)
        let byDay = Dictionary(grouping: samples) { Calendar.current.startOfDay(for: $0.startDate) }
        return byDay.map { day, rows in
            let mean = rows.reduce(0.0) { $0 + $1.quantity.doubleValue(for: unit) } / Double(rows.count)
            return DailyValue(day: day, value: mean)
        }
        .sorted { $0.day < $1.day }
    }

    private func nightlyMeans(type: HKQuantityType,
                              from start: Date,
                              to end: Date,
                              nights: [NightWindow],
                              scale: Double) async throws -> [DailyValue] {
        guard !nights.isEmpty else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let samples = try await quantitySamples(type: type, predicate: predicate)
        let unit = canonicalUnit(for: type)
        var grouped: [Date: [Double]] = [:]

        for sample in samples {
            let interval = sample.endDate > sample.startDate
                ? DateInterval(start: sample.startDate, end: sample.endDate)
                : DateInterval(start: sample.startDate, duration: 1)
            guard let night = nights.first(where: { $0.window.intersects(interval) }) else { continue }
            grouped[night.key, default: []].append(sample.quantity.doubleValue(for: unit) * scale)
        }

        return grouped.map { day, values in
            let mean = values.reduce(0.0, +) / Double(values.count)
            return DailyValue(day: day, value: mean)
        }
        .sorted { $0.day < $1.day }
    }

    private func fetchNightWindows(from start: Date, to end: Date) async throws -> [NightWindow] {
        let sleepType = HKCategoryType(.sleepAnalysis)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let samples = try await categorySamples(type: sleepType, predicate: predicate)
        let inBed = HKCategoryValueSleepAnalysis.inBed.rawValue
        let asleep = Set(HKCategoryValueSleepAnalysis.allAsleepValues.map(\.rawValue))
        let relevant = samples.filter { $0.value == inBed || asleep.contains($0.value) }

        var grouped: [Date: DateInterval] = [:]
        let cal = Calendar.current
        for sample in relevant {
            guard sample.endDate > sample.startDate else { continue }
            guard sample.endDate.timeIntervalSince(sample.startDate) >= Self.minimumNightDuration else { continue }
            let key = cal.startOfDay(for: sample.endDate)
            let candidate = DateInterval(start: sample.startDate, end: sample.endDate)
            if let existing = grouped[key] {
                grouped[key] = DateInterval(start: min(existing.start, candidate.start),
                                            end: max(existing.end, candidate.end))
            } else {
                grouped[key] = candidate
            }
        }

        return grouped.keys.sorted().compactMap { key in
            guard let window = grouped[key], window.end > window.start else { return nil }
            return NightWindow(key: key, window: window)
        }
    }

    private func canonicalUnit(for type: HKQuantityType) -> HKUnit {
        switch type.identifier {
        case HKQuantityTypeIdentifier.heartRate.rawValue,
             HKQuantityTypeIdentifier.restingHeartRate.rawValue,
             HKQuantityTypeIdentifier.respiratoryRate.rawValue:
            return HKUnit.count().unitDivided(by: .minute())
        case HKQuantityTypeIdentifier.heartRateVariabilitySDNN.rawValue:
            return .secondUnit(with: .milli)
        case HKQuantityTypeIdentifier.oxygenSaturation.rawValue:
            return .percent()
        case HKQuantityTypeIdentifier.bodyTemperature.rawValue:
            return .degreeCelsius()
        default:
            return .count()
        }
    }

    private func categorySamples(type: HKCategoryType,
                                 predicate: NSPredicate?) async throws -> [HKCategorySample] {
        try await withCheckedThrowingContinuation { cont in
            let query = HKSampleQuery(sampleType: type, predicate: predicate,
                                      limit: HKObjectQueryNoLimit,
                                      sortDescriptors: [NSSortDescriptor(keyPath: \HKSample.startDate, ascending: true)]) { _, result, error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume(returning: (result as? [HKCategorySample]) ?? [])
                }
            }
            store.execute(query)
        }
    }

    private func quantitySamples(type: HKQuantityType,
                                 predicate: NSPredicate?) async throws -> [HKQuantitySample] {
        try await withCheckedThrowingContinuation { cont in
            let query = HKSampleQuery(sampleType: type, predicate: predicate,
                                      limit: HKObjectQueryNoLimit,
                                      sortDescriptors: [NSSortDescriptor(keyPath: \HKSample.startDate, ascending: true)]) { _, result, error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume(returning: (result as? [HKQuantitySample]) ?? [])
                }
            }
            store.execute(query)
        }
    }
}

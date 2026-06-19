// Device-agnostic metric models — the typed values the codec produces and the
// HealthKit writer consumes. Shapes follow docs/HEALTHKIT_MAPPING.md. These are
// app-side data structures, not protocol facts; the byte-level decoders that
// populate them stay 🔴 until captures decode each metric (PROTOCOL.md §5).

import Foundation

/// One metric family. Raw values are stable string ids (persistence/cursor keys).
public enum MetricKind: String, Codable, CaseIterable, Sendable {
    case heartRate
    case restingHeartRate
    case hrvSDNN          // HealthKit stores SDNN, not RMSSD (see mapping notes)
    case spo2
    case temperature
    case respiratoryRate
    case steps
    case activeEnergy
    case sleep            // modeled as SleepSegment, not QuantitySample
    /// Estimated walking/running distance derived from steps × stride (#81).
    /// ESTIMATE only — NOT GPS distance. Written to HealthKit `.distanceWalkingRunning`.
    /// Replaced by decoded device distance once 0x4c activity-epoch [15:22] is decoded (#93).
    case distance
    /// Estimated Apple Exercise Time from elevated-HR minutes (#82).
    /// ESTIMATE only — basic threshold model. Full 4-level intensity follows #93 decode.
    /// Written to HealthKit `.appleExerciseTime`.
    case exerciseMinutes

    /// Canonical unit each `QuantitySample.value` is expressed in, matching the
    /// HealthKit type it maps to in docs/HEALTHKIT_MAPPING.md.
    public var unit: String {
        switch self {
        case .heartRate, .restingHeartRate, .respiratoryRate: return "count/min"
        case .hrvSDNN: return "ms"
        case .spo2: return "fraction"        // HealthKit oxygenSaturation wants 0…1
        case .temperature: return "degC"
        case .steps: return "count"
        case .activeEnergy: return "kcal"
        case .sleep: return "category"
        case .distance: return "m"           // meters
        case .exerciseMinutes: return "min"  // minutes
        }
    }

    /// Human-readable label for dashboards.
    public var displayName: String {
        switch self {
        case .heartRate: return "Heart Rate"
        case .restingHeartRate: return "Resting HR"
        case .hrvSDNN: return "HRV"
        case .spo2: return "SpO₂"
        case .temperature: return "Skin Temp"
        case .respiratoryRate: return "Respiratory Rate"
        case .steps: return "Steps"
        case .activeEnergy: return "Active Energy"
        case .sleep: return "Sleep"
        case .distance: return "Distance (est.)"
        case .exerciseMinutes: return "Exercise Time (est.)"
        }
    }
}

/// A scalar metric sample carrying the device's own timestamps so history
/// backfills correctly. `end == start` for instantaneous readings.
public struct QuantitySample: Equatable, Codable, Sendable {
    public let kind: MetricKind
    public let start: Date
    public let end: Date
    public let value: Double

    public init(kind: MetricKind, start: Date, end: Date? = nil, value: Double) {
        self.kind = kind
        self.start = start
        self.end = end ?? start
        self.value = value
    }
}

/// HealthKit `sleepAnalysis` category values (docs/HEALTHKIT_MAPPING.md §sleep).
public enum SleepStage: String, Codable, CaseIterable, Sendable {
    case inBed, awake, asleepCore, asleepDeep, asleepREM
}

/// One contiguous sleep-stage segment. A night = many of these, not one record.
public struct SleepSegment: Equatable, Codable, Sendable {
    public let start: Date
    public let end: Date
    public let stage: SleepStage

    public init(start: Date, end: Date, stage: SleepStage) {
        self.start = start
        self.end = end
        self.stage = stage
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }
}

// Estimate walking/running distance from decoded step count × stride length (#81).
//
// Stride length is derived from the user's height and biological sex using standard
// anthropometric ratios (ACSM reference). This is an ESTIMATE — NOT GPS distance and
// NOT decoded device distance. Labeled as such in HealthKit metadata and UI.
//
// HealthKit target: `.distanceWalkingRunning` (written by HealthKitWriter, not stored
// as a ring sample in LocalStore).
//
// Replaced by true decoded distance once the 0x4c activity-epoch [15:22] payload is
// decoded (#93) — that payload carries `HistoryActivitySyncInfo.distance`.

import Foundation

public enum DistanceEstimate {

    /// Stride length ratio (step / height) for walking, by sex.
    /// Source: ACSM walking stride-length normative data.
    /// Male:   ~0.415 × height
    /// Female: ~0.413 × height
    static let strideRatioMale   = 0.415
    static let strideRatioFemale = 0.413

    /// Estimated stride length in centimetres from height and sex.
    public static func strideCm(heightCm: Double, sex: BiologicalSex) -> Double {
        let ratio = sex == .male ? strideRatioMale : strideRatioFemale
        return max(heightCm, 0) * ratio
    }

    /// Estimated distance in metres from step count and user profile.
    /// Returns 0 for non-positive step counts.
    /// ESTIMATE — height-based stride, not GPS or decoded ring data.
    public static func meters(steps: Int, profile: UserProfile) -> Double {
        guard steps > 0 else { return 0 }
        return Double(steps) * strideCm(heightCm: profile.heightCm, sex: profile.sex) / 100.0
    }

    /// Convenience overload with explicit height and sex.
    public static func meters(steps: Int, heightCm: Double, sex: BiologicalSex) -> Double {
        guard steps > 0 else { return 0 }
        return Double(steps) * strideCm(heightCm: heightCm, sex: sex) / 100.0
    }
}

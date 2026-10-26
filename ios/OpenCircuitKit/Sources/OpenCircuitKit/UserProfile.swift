import Foundation

public enum BiologicalSex: String, Codable, CaseIterable, Sendable {
    case male
    case female
}

public struct UserProfile: Equatable, Codable, Sendable {
    public let age: Int
    public let weightKg: Double
    public let heightCm: Double
    public let sex: BiologicalSex
    /// The max heart rate the user typed (decision 83c), or nil for Automatic (`220 − age`).
    public let manualMaxHR: Int?

    public init(age: Int, weightKg: Double, heightCm: Double, sex: BiologicalSex,
                manualMaxHR: Int? = nil) {
        self.age = age
        self.weightKg = weightKg
        self.heightCm = heightCm
        self.sex = sex
        self.manualMaxHR = manualMaxHR
    }

    /// Max heart rate for the calorie, strain and exercise-minute maths: the manual value when set
    /// and valid, else `max(220 − age, 1)` exactly as before.
    public var maxHR: Int { MaxHeartRate.resolve(age: age, manual: manualMaxHR) }
}

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

    public init(age: Int, weightKg: Double, heightCm: Double, sex: BiologicalSex) {
        self.age = age
        self.weightKg = weightKg
        self.heightCm = heightCm
        self.sex = sex
    }
}

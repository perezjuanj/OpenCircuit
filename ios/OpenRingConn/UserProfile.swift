import SwiftUI
import OpenRingKit

@MainActor
struct UserProfileSettingsView: View {
    @AppStorage("userProfile.age") private var age = 35
    @AppStorage("userProfile.weightKg") private var weightKg = 70.0
    @AppStorage("userProfile.heightCm") private var heightCm = 170.0
    @AppStorage("userProfile.sex") private var sexRaw = BiologicalSex.male.rawValue

    var body: some View {
        Form {
            Section("Profile") {
                Stepper(value: $age, in: 13...120) {
                    LabeledContent("Age", value: "\(age)")
                }
                LabeledContent("Weight") {
                    TextField("kg", value: $weightKg, format: .number.precision(.fractionLength(1)))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Height") {
                    TextField("cm", value: $heightCm, format: .number.precision(.fractionLength(1)))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
                Picker("Sex", selection: $sexRaw) {
                    ForEach(BiologicalSex.allCases, id: \.rawValue) { sex in
                        Text(sex.rawValue.capitalized).tag(sex.rawValue)
                    }
                }
            }

            Section("Calories") {
                LabeledContent("BMR", value: "\(Int(Calories.bmrKcalPerDay(profile: profile).rounded())) kcal/day")
                LabeledContent("Passive", value: "\(String(format: "%.1f", Calories.bmrKcalPerHour(profile: profile))) kcal/hour")
                LabeledContent("Max HR", value: "\(maxHR) bpm")
            }
        }
        .navigationTitle("User Profile")
    }

    private var profile: UserProfile {
        UserProfile(
            age: age,
            weightKg: max(weightKg, 1.0),
            heightCm: max(heightCm, 1.0),
            sex: BiologicalSex(rawValue: sexRaw) ?? .male
        )
    }

    private var maxHR: Int {
        max(220 - age, 1)
    }
}

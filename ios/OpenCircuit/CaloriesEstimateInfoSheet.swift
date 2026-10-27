// How the Calories card's BMR and max HR are worked out, opened from the card's info button.
// Text only, in the voice of `StrapPAIInfoSheet`. Every line here is checked against
// `Calories.swift` (`bmrKcalPerDay`, `restingEnergyScale`) and the card's `maxHR`.

import SwiftUI
import OpenCircuitKit

struct CaloriesEstimateInfoSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// The explanation, one short paragraph per line.
    static let bullets = [
        "BMR is the energy your body uses at rest. It comes from the Mifflin-St Jeor formula, using your "
            + "height, age and sex from Profile, and your weight from Profile or, if newer, your latest "
            + "body mass in Apple Health.",
        "The BMR figure and the Resting number on the card are that formula alone. When Apple Health gets "
            + "resting energy from this app, it is nudged by your measured resting heart rate compared with "
            + "your own recent average: about 1% per bpm, never more than 20% either way. With fewer than "
            + "\(Calories.minRestingBaselineDays) earlier days of resting heart rate, there is no nudge.",
        "Est. max HR is 220 minus your age, unless you set your own in Heart Rate Zones. It is a rule of "
            + "thumb, not a measured peak, and it sets the heart rate intensity behind the Active estimate.",
        "These are estimates, not a medical device. If age, weight, height or sex still show as default, "
            + "set them in Profile.",
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Self.bullets, id: \.self) { Text($0).font(.subheadline) }
                }
            }
            .navigationTitle("About These Estimates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}

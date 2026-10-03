// What PAI is, opened from the strap's PAI tile (decision 49). A sheet, not a day chart: `0x0d` is about
// one record a day, so there is nothing to chart. Text only, in the voice of the strap setup screen's
// bullets: what the number is, why the app puts no usual range on it (decision 25), and why it isn't
// in Apple Health (decision 15).

import SwiftUI

struct StrapPAIInfoSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// The explanation, one short paragraph per line.
    static let bullets = [
        "PAI is Amazfit's activity score. The strap works it out on its own, from the time your heart rate "
            + "spends in its zones over a rolling week. OpenCircuit doesn't calculate it.",
        "There's no usual range or trend here. Amazfit doesn't publish the formula, so this app can't check "
            + "the number or say what's normal for you. It shows what the strap reports.",
        "The strap records it about once a day, so the time on the tile is often yesterday's.",
        "PAI stays in the app. Apple Health has no type for it.",
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Self.bullets, id: \.self) { Text($0).font(.subheadline) }
                }
            }
            .navigationTitle("About PAI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}

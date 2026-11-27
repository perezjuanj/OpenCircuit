// The Vitals Status card's report while its card is hidden in Edit Today (#394, decision 94c).
//
// The card's fever verdict is one of the Today sentence's inputs, so hiding the card must not stop
// it. While `TodayLayout.vitalsReport` says `.hiddenRunner`, this draws the card unseen (hidden, out of
// the accessibility tree, not hit-testable) so its loads and report run exactly as they do on screen.
// While the card is shown it reports itself and this draws nothing, so exactly one copy runs.

import SwiftUI

struct HiddenVitalsReport<Card: View>: View {
    let layout: TodayLayout
    @ViewBuilder let card: () -> Card

    var body: some View {
        if layout.vitalsReport == .hiddenRunner {
            card()
                .hidden()
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
    }
}

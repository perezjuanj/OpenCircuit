import SwiftUI

// The one-time explainer shown when a user first turns headache signals ON (#183).
//
// This screen exists because the feature makes an unusual bargain and the bargain is entirely
// front-loaded: the user does the work (log every headache, for months) long before there is any
// chance of getting something back, and for many people there will never be anything back at all.
// Release notes do not reach someone who enables a setting six weeks after installing, so the ask is
// stated here, in the app, at the moment they opt in.
//
// COPY DISCIPLINE — the reason each of these lines is worded the way it is:
//  - It promises NOTHING. No prediction, no forecast, no early warning, no accuracy number. The
//    published ceiling for physiology-only headache forecasting is low enough (AUC ~0.65, roughly
//    26 % precision at our operating point) that any promise would be a lie we could not retract.
//  - It says plainly that the score measures how UNUSUAL a night was in EITHER direction. A great
//    night reads "unusual" too. Users who are not told this will read every flag as a warning.
//  - It names the confounders we cannot separate — a hangover, a late night, a hard training day —
//    rather than waiting for a tester to discover them and lose trust in everything else we say.
//  - It tells people who do NOT get headaches that they still help. Otherwise they conclude they are
//    useless and switch it off, taking with them exactly the negative days the statistics need.
//
// Deliberately short. A wall of text is dismissed unread, and an unread explainer is worse than none
// because it lets us believe the user was told.
struct HeadacheOnboardingView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("This one needs your help to work at all.")
                        .font(.title3.weight(.semibold))

                    point(icon: "square.and.pencil",
                          title: "Log every headache — even mild ones",
                          body: "Your logged headaches are the only thing any of this can ever be "
                              + "checked against. One you don't log can't be filled in later, the "
                              + "way ring data can.")

                    point(icon: "bolt.fill",
                          title: "Make it quick",
                          body: "Say \"Hey Siri, log a headache in OpenCircuit\", or add the Control "
                              + "Centre button. If you only remember the next morning, the card will "
                              + "ask you — that counts just as much.")

                    point(icon: "heart.text.square",
                          title: "Already track them in Apple Health?",
                          body: "Import them from the card. Those count from day one.")

                    point(icon: "moon.stars",
                          title: "What you'll see",
                          body: "After about a week, whether last night looked unusual for you — how "
                              + "far your sleep, heart rate, HRV and skin temperature drifted from "
                              + "your own normal. After about three weeks it can also tell you, at "
                              + "most once in a morning, when a night stood out. You can switch "
                              + "those mornings off in Settings whenever you like.")

                    point(icon: "exclamationmark.triangle",
                          title: "What it won't do",
                          body: "It never tells you a headache is coming — it only ever reports what "
                              + "it measured. \"Unusual\" cuts both ways: a genuinely great night "
                              + "looks unusual too, and so does a hangover, a late night, or a hard "
                              + "workout. Whether any of it relates to your headaches is exactly "
                              + "what your logging is there to find out, and for some people the "
                              + "answer will be no.")

                    point(icon: "person.2",
                          title: "Don't get headaches? Still useful",
                          body: "The days nothing happens are exactly what tells us whether the "
                              + "signals mean anything. Leaving this on helps.")

                    Text("OpenCircuit is not a medical device. A headache log is your own record, "
                         + "not a diagnosis. If you feel unwell, consult a qualified medical "
                         + "professional.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)
                }
                .padding(20)
            }
            .navigationTitle("Headache signals")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                Button {
                    dismiss()
                } label: {
                    Text("Start logging")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
                .background(.bar)
            }
        }
    }

    private func point(icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Theme.accent)
                .frame(width: 26)
                .accessibilityHidden(true)   // the title below already carries the meaning
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(body).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

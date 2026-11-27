// The Strain detail (#391, decision 93c), opened from the Strain dial on Today's scores card. It
// absorbs the old "About Strain" sheet (its bullets, the zones it used and the default-age note move
// here verbatim) and adds the score itself, with its band and freshness, and a way to today's heart rate.
//
// It shows `TrendsData.todayStrain`, the reading the dial shows (invariant I3).

import SwiftUI
import OpenCircuitKit

/// The former sheet's name. The detail replaces it, and its existing tests (`StrainTileTests`,
/// `ProfileDefaultsTests`, `ProfileScreenHostedTests`) keep pinning the moved copy and wiring unmodified.
typealias StrainInfoSheet = StrainDetailView

struct StrainDetailView: View {
    let reading: DailyStrain.Reading?
    /// True while Profile age has never been set, so the 220 − age maximum rests on the placeholder
    /// age. Same predicate as the Profile age row (`ProfileDefaultsStatus`).
    var ageIsDefault: Bool = ProfileDefaultsStatus.current().age
    /// Opens today's heart-rate chart. No row when nil.
    var onHeartRate: (() -> Void)?

    @ScaledMetric(relativeTo: .largeTitle) private var ringSize: CGFloat = 150

    static let defaultAgeNote = "Your age isn't set in Profile, so this maximum uses a default age of 35. "
        + "Set your age in Profile for zones that fit you."

    static let bullets = [
        "Strain is how hard your heart has worked today, on a 0 to 21 scale. It adds up the time your "
            + "heart rate spends in the upper zones of your heart-rate reserve, and harder zones count more.",
        "It starts again at midnight and only goes up through the day. There's no usual range here: a "
            + "running total would always look low next to whole past days.",
        "Light is under 10, moderate 10 to 14, high 14 to 18, and all out 18 or more.",
        "Your zones come from your resting heart rate (the same one the Resting HR tile shows) and an "
            + "estimated maximum of 220 minus the age in your profile, or the maximum you set in Heart Rate Zones.",
        "It's an estimate from your wearable's heart-rate readings, which come every minute or few "
            + "minutes, not every beat. It needs at least 10 minutes of them to score.",
        "Strain stays in the app. Apple Health has no type for it.",
    ]

    private var valueText: String? { StrainTileText.value(reading) }

    var body: some View {
        List {
            Section { hero }
                .listRowBackground(Color.clear)
            zones
            Section("About strain") {
                ForEach(Self.bullets, id: \.self) { Text($0).font(.subheadline) }
            }
            Section {
                if let onHeartRate {
                    Button(action: onHeartRate) { linkRow("Today's heart rate", icon: .heart, tint: Theme.hr) }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens today's heart-rate chart")
                }
                NavigationLink {
                    HealthSourcesView(focus: .strain)
                } label: {
                    linkRow("Sources & methods", icon: .info, tint: Theme.accent, chevron: false)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Strain")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var hero: some View {
        VStack(spacing: 8) {
            ReadinessRing(progress: reading?.gaugeFraction, tint: Theme.energy, lineWidth: 15) {
                VStack(spacing: 0) {
                    Text(valueText ?? TodayScoresCopy.missing)
                        .font(.system(size: ringSize * 0.3, weight: .bold, design: .rounded))
                        .monospacedDigit().contentTransition(.numericText())
                        .foregroundStyle(valueText == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                        .minimumScaleFactor(0.5).lineLimit(1)
                    if valueText != nil {
                        Text("of 21").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: ringSize, height: ringSize)
            if valueText != nil {
                if let band = StrainTileText.bandLine(reading) {
                    Text(band).font(.title3.weight(.semibold))
                }
                if let fresh = StrainTileText.freshness(reading) {
                    Text(fresh).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(StrainTileText.status(reading))
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(StrainTileText.accessibilityLabel(reading))
    }

    /// The zones today's score was built on, and the default-age note whenever the maximum rests on it.
    @ViewBuilder
    private var zones: some View {
        let rhr = reading?.restingHR
        if rhr != nil || ageIsDefault {
            Section("Today's zones use") {
                if let reading, let rhr {
                    LabeledContent("Resting heart rate", value: "\(rhr) bpm")
                    LabeledContent("Estimated maximum",
                                   value: "\(reading.maxHR) bpm" + (ageIsDefault ? " (default age)" : ""))
                }
                if ageIsDefault { Text(Self.defaultAgeNote).font(.subheadline) }
            }
        }
    }

    /// A NavigationLink draws its own disclosure chevron; a plain button row gets a Keyline one.
    private func linkRow(_ title: String, icon: KeylineIcon, tint: Color, chevron: Bool = true) -> some View {
        HStack(spacing: 10) {
            KeylineGlyph(icon, size: 16).foregroundStyle(tint)
            Text(title).font(.body)
            Spacer()
            if chevron {
                KeylineGlyph(.chevronRight, size: 12, relativeTo: .caption).foregroundStyle(.tertiary)
            }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

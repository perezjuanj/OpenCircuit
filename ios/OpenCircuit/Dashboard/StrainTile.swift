// Today's strain on the Your Numbers grid (#216, "readiness and strain as dominant, glanceable numbers
// with a gauge"). The number is `DailyStrain` over today's heart rate from the shared trends load
// (`TrendsData.todayStrain`), on the 0…21 scale `Strain` computes; the gauge is the readiness card's
// own dial (`ReadinessRing`), filled to the score's share of 21.
//
// Laid out row for row like the other tiles — label + time, large value with a small unit, a line of
// words, the 34 pt chart slot, a bottom line — with the gauge in their sparkline's slot, so the tile is
// the same height as its neighbours. It has no usual range and no "vs usual":
// today's strain is a running total that only grows until midnight, so comparing it with whole past
// days would read every morning as "below usual". Tapping it explains strain (a sheet).
//
// Honest when it can't score: no heart rate today, under the 10 minutes `Strain` needs, or no resting
// heart rate to build zones on each say so in words, with an empty gauge, never a 0. Wording is
// device-neutral ("your wearable"): ring and Helio Strap wearers both see this tile.

import SwiftUI
import OpenCircuitKit

/// The tile's words, kept out of the view so a test can pin them.
enum StrainTileText {
    /// "8.4", or nil when there is no score.
    static func value(_ reading: DailyStrain.Reading?) -> String? {
        reading?.strain.map { String(format: "%.1f", $0) }
    }

    /// The line under the value: the band while there's a score, else nothing.
    static func bandLine(_ reading: DailyStrain.Reading?) -> String? {
        reading?.band.map { "\($0.label) · so far today" }
    }

    /// The bottom line: what the number is, or why there isn't one.
    static func status(_ reading: DailyStrain.Reading?) -> String {
        guard let reading, !reading.hasNoData else { return "No heart rate yet today" }
        if reading.strain != nil { return "Heart-rate effort · 0–21 scale" }
        if reading.coveredSeconds < DailyStrain.minCoveredSeconds {
            let need = DailyStrain.minCoveredSeconds / 60
            return "Needs \(need) min of heart rate · \(reading.coveredSeconds / 60) min so far"
        }
        return "Needs a resting heart rate first"
    }

    /// "as of 9:41 AM" from the newest reading used, or nil without one.
    static func freshness(_ reading: DailyStrain.Reading?) -> String? {
        reading?.latestSampleAt.map { "as of \($0.formatted(date: .omitted, time: .shortened))" }
    }

    static func accessibilityLabel(_ reading: DailyStrain.Reading?) -> String {
        var parts = ["Strain"]
        if let reading, let strain = reading.strain {
            parts.append("\(String(format: "%.1f", strain)) out of 21")
            if let band = reading.band { parts.append("\(band.label), so far today") }
            if let fresh = freshness(reading) { parts.append(fresh) }
            parts.append("Heart-rate effort on a 0 to 21 scale")
        } else {
            parts.append(status(reading).replacingOccurrences(of: " · ", with: ", "))
        }
        return parts.joined(separator: ". ")
    }
}

struct StrainTileView: View {
    /// nil until the first trends load lands (the grid is redacted then).
    let reading: DailyStrain.Reading?

    @ScaledMetric(relativeTo: .title) private var valueSize: CGFloat = 30

    private var valueText: String? { StrainTileText.value(reading) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                KeylineGlyph(.activity, size: 14, relativeTo: .caption).foregroundStyle(Theme.energy)
                Text("STRAIN")
                    .font(.caption2.weight(.semibold)).tracking(0.6)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 2)
                if let fresh = StrainTileText.freshness(reading), valueText != nil {
                    Text(fresh).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            // Large value, small unit (the scale's top, as the stress tile shows "/ 100").
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(valueText ?? "—")
                    .font(.system(size: valueSize, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(valueText == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                    .contentTransition(.numericText())
                    .lineLimit(1).minimumScaleFactor(0.6)
                if valueText != nil {
                    Text("/ 21").font(.footnote.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Text(StrainTileText.bandLine(reading) ?? " ")
                .font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.8)
            // The readiness card's dial, filled to the score's share of 21 (track only without one).
            // It sits in the sparkline's 34 pt slot, so the tile is the same height as its neighbours.
            ReadinessRing(progress: reading?.gaugeFraction, tint: Theme.energy, lineWidth: 5) {
                EmptyView()
            }
            .frame(width: 34, height: 34)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityHidden(true)
            Text(StrainTileText.status(reading))
                .font(.caption2).foregroundStyle(.secondary)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ocCardSurface(padding: 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(StrainTileText.accessibilityLabel(reading))
        .accessibilityHint("Explains what strain is")
        .accessibilityAddTraits(.isButton)
    }
}

/// What strain is, opened from the Strain tile. Text only, in the voice of the PAI sheet.
struct StrainInfoSheet: View {
    let reading: DailyStrain.Reading?

    @Environment(\.dismiss) private var dismiss

    static let bullets = [
        "Strain is how hard your heart has worked today, on a 0 to 21 scale. It adds up the time your "
            + "heart rate spends in the upper zones of your heart-rate reserve, and harder zones count more.",
        "It starts again at midnight and only goes up through the day. There's no usual range here: a "
            + "running total would always look low next to whole past days.",
        "Light is under 10, moderate 10 to 14, high 14 to 18, and all out 18 or more.",
        "Your zones come from your resting heart rate (the same one the Resting HR tile shows) and an "
            + "estimated maximum of 220 minus the age in your profile.",
        "It's an estimate from your wearable's heart-rate readings, which come every minute or few "
            + "minutes, not every beat. It needs at least 10 minutes of them to score.",
        "Strain stays in the app. Apple Health has no type for it.",
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Self.bullets, id: \.self) { Text($0).font(.subheadline) }
                }
                if let reading, let rhr = reading.restingHR {
                    Section("Today's zones use") {
                        LabeledContent("Resting heart rate", value: "\(rhr) bpm")
                        LabeledContent("Estimated maximum", value: "\(reading.maxHR) bpm")
                    }
                }
            }
            .navigationTitle("About Strain")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}

// "How this score is made": the factors behind the Sleep Score badge, opened from the Sleep card.
// The rows come from `SleepScoreBreakdown` (Kit): the night's factors saved when its score was written,
// or, for an edited night, a rebuild from the row. Either is shown only when it adds up to the badge,
// so a night with neither simply has no sheet.

import SwiftUI
import OpenCircuitKit

extension StoredSleepSummary {
    /// The breakdown for this row's badge, nil when it cannot be shown (see `SleepScoreBreakdown`).
    ///
    /// First the factors SAVED when the score was written (`SleepScoreFactorStore`), shown only while
    /// their score is still this row's. Without one, an EDITED night is rebuilt from its stored
    /// minutes (measured exact on every edited night), and only if the rebuild equals the badge. A
    /// ring or strap night scored before factors were saved has neither and shows the badge alone.
    var scoreBreakdown: SleepScoreBreakdown? {
        if let saved = SleepScoreBreakdown.make(saved: SleepScoreFactorStore.shared.entry(night: night),
                                                storedScore: sleepScore) {
            return saved
        }
        guard isManuallyEdited else { return nil }
        return SleepScoreBreakdown.make(.init(
            storedScore: sleepScore, producer: .edited,
            asleepMin: deepMin + lightMin + remMin, awakeMin: awakeMin,
            deepMin: deepMin, lightMin: lightMin, remMin: remMin, efficiency: efficiency))
    }
}

struct SleepScoreBreakdownView: View {
    let breakdown: SleepScoreBreakdown
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(breakdown.rows) { FactorRow(row: $0) }
                } header: {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(breakdown.score)")
                            .font(.system(.largeTitle, design: .rounded).weight(.bold)).monospacedDigit()
                        Text("sleep score").font(.subheadline).foregroundStyle(.secondary)
                    }
                    .textCase(nil).foregroundStyle(.primary)
                    .padding(.bottom, 4)
                    .accessibilityElement(children: .combine)
                } footer: {
                    Text(SleepScoreBreakdown.footnote)
                }
            }
            .navigationTitle("How this score is made")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
    }

    private struct FactorRow: View {
        let row: SleepScoreBreakdown.Row

        /// The same tier colours as the badge, applied to the 0–100 sub-score.
        private var tint: Color {
            switch SleepScore.Tier.of(row.subScore) {
            case .excellent: return .green
            case .good: return .teal
            case .needsImprovement: return .orange
            }
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(row.title).font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(row.subScore)").font(.subheadline.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(tint)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.18))
                        Capsule().fill(tint).frame(width: geo.size.width * CGFloat(row.subScore) / 100)
                    }
                }
                .frame(height: 6)
                HStack {
                    Text(row.valueText).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(row.weightText) of score").font(.caption).foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(row.title), \(row.subScore) out of 100")
            .accessibilityValue("\(row.valueText), \(row.weightText) of the score")
        }
    }
}

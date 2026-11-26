// The Recovery detail (#391, decision 93c), opened from the Recovery dial on Today's scores card. It
// absorbs the old Readiness card: the score with its tier, what went into it (sleep score and sleeping
// HRV, with the shares computed from the Kit's weights), the low-confidence note, the estimate
// disclaimer with the sources one tap away, and last night's HRV and resting heart rate from the same
// tiles Your Numbers shows.
//
// It is handed the card's `TodayScores`, so the number here is the ring's number (invariant I2).

import SwiftUI
import OpenCircuitKit

struct RecoveryDetailView: View {
    let scores: TodayScores
    /// Today's tiles, for the "Last night" rows (the grid's own values and vs-usual words).
    var tiles: [TodayTile] = []
    var onMetric: (TodayTile.Metric) -> Void = { _ in }

    @ScaledMetric(relativeTo: .largeTitle) private var ringSize: CGFloat = 150

    private var recovery: TodayScores.Recovery { scores.recovery }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                hero
                if let r = recovery.result {
                    factors(r)
                }
                method
                lastNight
            }
            .padding()
        }
        .background(Theme.pageBackground)
        .navigationTitle("Recovery")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Score

    private var hero: some View {
        VStack(spacing: 10) {
            ReadinessRing(progress: recovery.result.map { Double($0.score) / 100 },
                          tint: recovery.result?.tier.ringColor ?? Theme.readiness,
                          lowConfidence: recovery.isLowConfidence, lineWidth: 15) {
                VStack(spacing: 0) {
                    Text(TodayScoresCopy.recoveryValue(recovery))
                        .font(.system(size: ringSize * 0.3, weight: .bold, design: .rounded))
                        .monospacedDigit().contentTransition(.numericText())
                        .foregroundStyle(recovery.result == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                        .minimumScaleFactor(0.5).lineLimit(1)
                    if recovery.result != nil {
                        Text("of 100").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: ringSize, height: ringSize)
            if let r = recovery.result {
                Text(TodayScoresCopy.tier(r.tier)).font(.title3.weight(.semibold))
                Text(TodayScoresCopy.detailBasis).font(.caption).foregroundStyle(.secondary)
            } else if let gap = TodayScoresCopy.detailGap(recovery) {
                Text(gap)
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(TodayScoresCopy.recoveryAccessibility(recovery)
                            + (TodayScoresCopy.detailGap(recovery).map { ". \($0)" } ?? ""))
    }

    // MARK: What went into it

    private func factors(_ r: WellnessBalance.Result) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("WHAT WENT INTO IT")
            if let sleep = r.factors[.sleep] {
                ReadinessFactorBar(label: TodayScoresCopy.detailSleepFactor, value: sleep, tint: r.tier.ringColor)
            }
            if let hrv = r.factors[.recovery] {
                ReadinessFactorBar(label: TodayScoresCopy.detailHRVFactor, value: hrv, tint: r.tier.ringColor)
            }
            Text(recovery.isLowConfidence ? TodayScoresCopy.detailSleepAlone : TodayScoresCopy.detailShares())
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .ocCardSurface()
    }

    // MARK: How it's worked out

    private var method: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("HOW IT'S WORKED OUT")
            Text(TodayScoresCopy.detailMethod)
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            NavigationLink {
                HealthSourcesView(focus: .readiness)
            } label: {
                HStack(spacing: 4) {
                    Text("Sources & methods").font(.subheadline.weight(.medium))
                    KeylineGlyph(.chevronRight, size: 12, relativeTo: .caption)
                }
                .foregroundStyle(Theme.accent)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .ocCardSurface()
    }

    // MARK: Last night

    /// Last night's HRV and resting heart rate, as the tiles show them. A row is hidden when its tile
    /// is missing, has no value, or is stale.
    private var lastNightTiles: [TodayTile] {
        [TodayTile.Metric.hrv, .restingHR].compactMap { m in
            tiles.first { $0.metric == m && $0.valueText != nil && !$0.isStale() }
        }
    }

    @ViewBuilder
    private var lastNight: some View {
        let rows = lastNightTiles
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                sectionTitle("LAST NIGHT").padding(.bottom, 4)
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, tile in
                    if index > 0 { Divider() }
                    Button { onMetric(tile.metric) } label: { row(tile) }
                        .buttonStyle(.plain)
                }
            }
            .ocCardSurface()
        }
    }

    private func row(_ tile: TodayTile) -> some View {
        HStack(spacing: 10) {
            KeylineGlyph(tile.icon, size: 16).foregroundStyle(tile.tint)
            Text(tile.title).font(.body)
            Spacer(minLength: 8)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(tile.valueText ?? TodayScoresCopy.missing)
                    .font(.body.weight(.semibold)).monospacedDigit()
                if !tile.unit.isEmpty {
                    Text(tile.unit).font(.footnote.weight(.medium)).foregroundStyle(.secondary)
                }
                if let delta = tile.deltaText {
                    Text(delta).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            KeylineGlyph(.chevronRight, size: 12, relativeTo: .caption).foregroundStyle(.tertiary)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tile.accessibilityLabel)
        .accessibilityHint("Opens today's \(tile.title) chart and its trend")
        .accessibilityAddTraits(.isButton)
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s).font(.caption.weight(.semibold)).tracking(1.2).foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

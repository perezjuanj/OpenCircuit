// The readiness ring (#216) — a thick, glanceable dial for the Wellness Balance score, in the
// card's existing tier colours (the same green / teal / orange the score number always used).
//
// Pure drawing: it fills to exactly the fraction it's given and says nothing of its own. Today's
// scores card and the Recovery and Strain details (decision 93) decide the number, the tier and the
// empty/low-confidence states; this only renders them. A value change animates unless Reduce Motion is on; the first frame
// always shows the real value (so screenshots and VoiceOver never see a half-drawn ring).

import SwiftUI
import OpenCircuitKit

struct ReadinessRing<Center: View>: View {
    /// 0…1, or nil for the empty state (track only).
    let progress: Double?
    var tint: Color = Theme.readiness
    /// Dashed track + muted fill: the score is real but rests on fewer inputs than usual.
    var lowConfidence = false
    var lineWidth: CGFloat = 16
    @ViewBuilder var center: () -> Center

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color(uiColor: .systemFill),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round,
                                           dash: lowConfidence ? [2, lineWidth * 0.55] : []))
            if let progress, progress > 0 {
                Circle()
                    .trim(from: 0, to: min(max(progress, 0), 1))
                    .stroke(
                        AngularGradient(colors: [tint.opacity(0.75), tint, tint],
                                        center: .center,
                                        startAngle: .degrees(0),
                                        endAngle: .degrees(360 * min(max(progress, 0.01), 1))),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .opacity(lowConfidence ? 0.7 : 1)
                    .animation(reduceMotion ? nil : .spring(response: 0.8, dampingFraction: 0.85),
                               value: progress)
            }
            center()
        }
        .padding(lineWidth / 2)
    }
}

/// One Wellness Balance factor as a slim labelled bar (sleep / recovery / vitals / activity).
struct ReadinessFactorBar: View {
    let label: String
    /// 0…1 as the analytics computed it.
    let value: Double
    var tint: Color = Theme.readiness

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text("\(Int((value * 100).rounded()))")
                    .font(.caption.weight(.semibold)).monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(uiColor: .systemFill))
                    Capsule().fill(tint)
                        .frame(width: max(geo.size.width * min(max(value, 0), 1), 4))
                }
            }
            .frame(height: 5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(Int((value * 100).rounded())) out of 100")
    }
}

extension WellnessBalance.Tier {
    /// The tier colour the readiness card has always used for its score (#97). Never the only
    /// carrier of the tier: the label is always shown beside it.
    var ringColor: Color {
        switch self {
        case .excellent:        return .green
        case .good:             return .teal
        case .needsImprovement: return .orange
        }
    }
}

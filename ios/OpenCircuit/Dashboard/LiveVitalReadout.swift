// The large live readout (#216) shown above the live chart during an on-demand HR / SpO₂
// measurement: one big number with a small unit, a heart that beats at the measured rate, and the
// low / high of this measurement so far. It shows only what the ring has sent — no smoothing, no
// placeholder number while the sensor warms up.
//
// Reduce Motion: the heart holds still and the number changes without the rolling transition.

import SwiftUI

struct LiveVitalReadout: View {
    /// The latest reading, or nil while the sensor is still warming up.
    let value: Int?
    let unit: String
    let tint: Color
    /// Beat the heart glyph at `value` bpm (HR only).
    var pulses = false
    /// Low / high of every reading so far in this measurement (display units).
    var sessionRange = LiveSessionRange()
    /// The Today strip's size: a 34 pt number instead of the 72 pt hero the metric detail keeps.
    var compact = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var heroSize: CGFloat = 72
    @ScaledMetric(relativeTo: .title) private var compactSize: CGFloat = 34
    private var size: CGFloat { compact ? compactSize : heroSize }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: compact ? 6 : 10) {
            if pulses {
                BeatingHeart(bpm: value, tint: tint, still: reduceMotion, glyph: compact ? 18 : 28)
                    .frame(width: compact ? 22 : size * 0.42, height: compact ? 22 : size * 0.42)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - size * 0.06 }
            }
            Text(value.map(String.init) ?? "—")
                .font(.system(size: size, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(value == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                .contentTransition(reduceMotion ? .identity : .numericText())
                .animation(reduceMotion ? nil : .snappy, value: value)
                .lineLimit(1).minimumScaleFactor(0.6)
            VStack(alignment: .leading, spacing: 2) {
                Text(unit).font(compact ? .subheadline.weight(.medium) : .title3.weight(.medium))
                    .foregroundStyle(.secondary)
                if !compact, let r = sessionRange.range {
                    Text("\(Int(r.lowerBound.rounded()))–\(Int(r.upperBound.rounded())) so far")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var accessibilityText: String {
        guard let value else { return "Waiting for a reading" }
        var s = "\(value) \(unit == "%" ? "percent" : unit == "bpm" ? "beats per minute" : unit)"
        if let r = sessionRange.range {
            s += ", \(Int(r.lowerBound.rounded())) to \(Int(r.upperBound.rounded())) so far"
        }
        return s
    }
}

/// Today's live measurement, small: the pulsing heart and number, the low–high so far, and a short
/// sparkline, on one row. The full readout and scrolling chart live on the metric detail's Measure
/// card, which a tap here opens — Today only says "a measurement is running, and here is the number".
struct LiveMeasureStrip: View {
    let title: String
    let value: Int?
    let unit: String
    let tint: Color
    var pulses = false
    var sessionRange = LiveSessionRange()
    let buffer: LiveBuffer

    var body: some View {
        OCCard(spacing: 6, padding: 14) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    LiveVitalReadout(value: value, unit: unit, tint: tint, pulses: pulses, compact: true)
                    if let r = sessionRange.range {
                        Text("\(Int(r.lowerBound.rounded()))–\(Int(r.upperBound.rounded())) so far")
                            .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                LiveVitalsChart(buffer: buffer, color: tint, window: 90, unit: unit,
                                emptyText: "Hold still…", compact: true)
                    .frame(width: 112, height: 48)
                    .padding(.trailing, 10)   // room for the endpoint's pulse ring
                    .accessibilityHidden(true)
                KeylineGlyph(.chevronRight, size: 12, relativeTo: .caption).foregroundStyle(.tertiary)
            }
        }
    }
}

/// The low and high of EVERY reading in the current measurement. The chart's `LiveBuffer` keeps only
/// its last 120 points, so a low–high taken from it would quietly become "over the last 120
/// readings" on a long measurement. Nothing here is trimmed. Reset it wherever the buffer is reset.
struct LiveSessionRange: Equatable {
    private(set) var low: Double?
    private(set) var high: Double?
    private(set) var count = 0

    mutating func include(_ value: Double) {
        guard value.isFinite else { return }
        low = min(low ?? value, value)
        high = max(high ?? value, value)
        count += 1
    }

    mutating func reset() { self = LiveSessionRange() }

    /// low…high once there are two readings to span, nil before.
    var range: ClosedRange<Double>? {
        guard count > 1, let low, let high else { return nil }
        return low...high
    }
}

/// A Keyline heart that scales on each beat at `bpm` (clamped to a sane 30–220), or stays still.
private struct BeatingHeart: View {
    let bpm: Int?
    let tint: Color
    let still: Bool
    var glyph: CGFloat = 28

    var body: some View {
        if still || bpm == nil {
            KeylineGlyph(.heart, size: glyph, relativeTo: .largeTitle).foregroundStyle(tint)
        } else {
            TimelineView(.animation) { ctx in
                let period = 60.0 / Double(min(max(bpm ?? 60, 30), 220))
                let phase = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
                // A quick "lub" in the first fifth of the beat, then rest.
                let beat = phase < 0.2 ? sin(phase / 0.2 * .pi) : 0
                KeylineGlyph(.heart, size: glyph, relativeTo: .largeTitle)
                    .foregroundStyle(tint)
                    .scaleEffect(1 + 0.14 * beat)
            }
        }
    }
}

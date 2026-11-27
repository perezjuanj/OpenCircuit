// What the Today scores widget draws (#398), from a stored snapshot and the time it is drawn at.
//
// SHARED SOURCE (app + `ScoresWidget` extension): the extension renders these on the home and lock
// screens; the app compiles them only for its DEBUG widget preview screen. Pure drawing: the numbers
// and words come from the snapshot as the app wrote them, and the only decision made here is how old
// the snapshot is (`ScoresWidgetFreshness`).

import SwiftUI
import WidgetKit

// MARK: - Display model

struct ScoresWidgetDial: Equatable, Identifiable {
    enum Kind: String, CaseIterable { case sleep, recovery, strain }

    let kind: Kind
    let label: String
    /// The centre text: the snapshot's value, else the card's dash. Never a 0 for a missing value.
    let value: String
    let fill: Double?
    let status: String
    let tint: ScoresWidgetSnapshot.Tint
    let dashed: Bool
    let spoken: String
    /// Drawn dimmed: the value is today's but older than `ScoresWidgetFreshness.staleAfter`. Set only
    /// by `ScoresWidgetDisplay.make` from `ScoresWidgetDisplay.isDimmed`, so no view decides it.
    var isDimmed = false

    var id: Kind { kind }
    var isMissing: Bool { value == TodayScoresWords.missing }

    var route: ScoresQuickLink.Route {
        switch kind {
        case .sleep:    return .sleep
        case .recovery: return .recovery
        case .strain:   return .strain
        }
    }
}

struct ScoresWidgetDisplay: Equatable {
    let dials: [ScoresWidgetDial]
    let freshness: ScoresWidgetFreshness
    /// "As of 9:41" for a stale snapshot; nil otherwise.
    let asOf: String?

    static let notUpdatedToday = "Open to update"
    static let neverWritten = "Open the app"

    /// A stale snapshot is drawn dimmed, on every size; the home-screen footer and the rectangular
    /// lock-screen widget also show `asOf`, so stale is never marked by opacity alone there.
    var isDimmed: Bool { freshness == .stale }

    func dial(_ kind: ScoresWidgetDial.Kind) -> ScoresWidgetDial {
        dials.first { $0.kind == kind } ?? dials[0]
    }

    static func make(_ snapshot: ScoresWidgetSnapshot?, now: Date, calendar: Calendar = .current,
                     locale: Locale = .current) -> ScoresWidgetDisplay {
        let freshness = ScoresWidgetFreshness.of(writtenAt: snapshot?.writtenAt, now: now, calendar: calendar)
        guard let snapshot, freshness == .current || freshness == .stale else {
            let reason = freshness == .none ? neverWritten : notUpdatedToday
            return ScoresWidgetDisplay(dials: ScoresWidgetDial.Kind.allCases.map { empty($0, reason: reason) },
                                       freshness: freshness, asOf: nil)
        }
        var asOf: String?
        if freshness == .stale {
            var style = Date.FormatStyle(date: .omitted, time: .shortened)
            style.calendar = calendar
            style.timeZone = calendar.timeZone
            style.locale = locale
            asOf = "As of \(snapshot.writtenAt.formatted(style))"
        }
        let dials = [dial(.sleep, snapshot.sleep, asOf: asOf), dial(.recovery, snapshot.recovery, asOf: asOf),
                     dial(.strain, snapshot.strain, asOf: asOf)]
        let display = ScoresWidgetDisplay(dials: dials, freshness: freshness, asOf: asOf)
        return ScoresWidgetDisplay(dials: dials.map { var d = $0; d.isDimmed = display.isDimmed; return d },
                                   freshness: freshness, asOf: asOf)
    }

    private static func label(_ kind: ScoresWidgetDial.Kind) -> String {
        switch kind {
        case .sleep:    return TodayScoresWords.sleepLabel
        case .recovery: return TodayScoresWords.recoveryLabel
        case .strain:   return TodayScoresWords.strainLabel
        }
    }

    private static func dial(_ kind: ScoresWidgetDial.Kind, _ d: ScoresWidgetSnapshot.Dial,
                             asOf: String?) -> ScoresWidgetDial {
        ScoresWidgetDial(kind: kind, label: label(kind), value: d.value ?? TodayScoresWords.missing,
                         fill: d.value == nil ? nil : d.fill, status: d.status, tint: d.tint,
                         dashed: d.dashed, spoken: asOf.map { "\(d.spoken) \($0)." } ?? d.spoken)
    }

    private static func empty(_ kind: ScoresWidgetDial.Kind, reason: String) -> ScoresWidgetDial {
        let tint: ScoresWidgetSnapshot.Tint = kind == .sleep ? .sleep : kind == .strain ? .strain : .recoveryNone
        let name = kind == .sleep ? "Sleep score" : kind == .recovery ? "Recovery" : "Strain"
        return ScoresWidgetDial(kind: kind, label: label(kind), value: TodayScoresWords.missing, fill: nil,
                                status: reason, tint: tint, dashed: false,
                                spoken: "\(name) unavailable. \(reason == neverWritten ? "Open OpenCircuit to see today's scores." : "Not updated today. Open OpenCircuit to update.")")
    }
}

// MARK: - Colours

/// The card's colours: Sleep is `Theme.sleep`, Strain `Theme.energy`, Recovery its tier colour (or
/// `Theme.readiness` when there is none). A test resolves these against `Theme` in light and dark.
enum ScoresWidgetPalette {
    static func color(_ tint: ScoresWidgetSnapshot.Tint) -> Color {
        switch tint {
        case .sleep:                    return adaptive((0.42, 0.33, 0.85), (0.62, 0.55, 0.99))
        case .strain:                   return adaptive((0.83, 0.39, 0.08), (0.99, 0.60, 0.30))
        case .recoveryNone:             return adaptive((0.28, 0.34, 0.86), (0.48, 0.55, 1.00))
        case .recoveryExcellent:        return .green
        case .recoveryGood:             return .teal
        case .recoveryNeedsImprovement: return .orange
        }
    }

    private static func adaptive(_ light: (CGFloat, CGFloat, CGFloat), _ dark: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(uiColor: UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }
}

// MARK: - Views

/// One dial: the ring, the value inside it.
struct ScoresWidgetRing: View {
    let dial: ScoresWidgetDial
    let lineWidth: CGFloat
    var showsLabelInside = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.14),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round,
                                           dash: dial.dashed ? [2, lineWidth * 0.55] : []))
            if let fill = dial.fill, fill > 0 {
                Circle()
                    .trim(from: 0, to: min(fill, 1))
                    .stroke(ScoresWidgetPalette.color(dial.tint),
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .opacity(dial.dashed ? 0.7 : 1)
                    .widgetAccentable()
            }
            VStack(spacing: 0) {
                Text(dial.value)
                    .font(.system(size: 100, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.05)
                    .lineLimit(1)
                    .foregroundStyle(dial.isMissing ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                    // Health scores: iOS may redact them while the phone is locked.
                    .privacySensitive()
                if showsLabelInside {
                    Text(dial.label.prefix(1) + dial.label.dropFirst().lowercased())
                        .font(.system(size: 9, weight: .medium))
                        .lineLimit(1).minimumScaleFactor(0.6)
                        .foregroundStyle(.secondary)
                }
            }
            // With the label inside, keep the text within the square the circle inscribes (side
            // ≈ 0.71 × the diameter), or the label's ends run into the ring.
            .padding(showsLabelInside ? lineWidth * 2.4 : lineWidth * 1.3)
        }
        .padding(lineWidth / 2)
        .opacity(dial.isDimmed ? 0.55 : 1)
    }
}

/// A dial with its label and status underneath, as one column of the card.
private struct ScoresWidgetColumn: View {
    let dial: ScoresWidgetDial
    let ringSize: CGFloat
    let lineWidth: CGFloat

    var body: some View {
        VStack(spacing: 3) {
            ScoresWidgetRing(dial: dial, lineWidth: lineWidth)
                .frame(width: ringSize, height: ringSize)
            Text(dial.label)
                .font(.system(size: 9, weight: .semibold)).tracking(0.4)
                .foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(dial.status)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2).minimumScaleFactor(0.75)
                .fixedSize(horizontal: false, vertical: true)
                // Time asleep and the like: redactable while locked, as the value is.
                .privacySensitive()
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(dial.spoken)
    }
}

/// The disclaimer line every home-screen size carries, with the stale time in front of it.
private struct ScoresWidgetFooter: View {
    let display: ScoresWidgetDisplay

    var body: some View {
        let text = Text(TodayScoresWords.footer)
        Group {
            if let asOf = display.asOf {
                Text(asOf).fontWeight(.semibold) + Text(" · ") + text
            } else {
                text
            }
        }
        .font(.system(size: 9))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .lineLimit(2).minimumScaleFactor(0.8)
        .frame(maxWidth: .infinity)
    }
}

/// Home screen, small: three dials and the disclaimer. A small widget has one tap target (the system
/// allows no per-dial links at this size), so the whole widget opens Today.
struct ScoresWidgetSmallView: View {
    let display: ScoresWidgetDisplay

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .top, spacing: 4) {
                ForEach(display.dials) {
                    ScoresWidgetColumn(dial: $0, ringSize: 42, lineWidth: 4.5)
                }
            }
            Spacer(minLength: 0)
            ScoresWidgetFooter(display: display)
        }
        .widgetURL(ScoresQuickLink.url(.today))
    }
}

/// Home screen, medium: each dial opens its own screen, and the disclaimer opens the sources.
struct ScoresWidgetMediumView: View {
    let display: ScoresWidgetDisplay

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(display.dials) { dial in
                    Link(destination: ScoresQuickLink.url(dial.route)) {
                        ScoresWidgetColumn(dial: dial, ringSize: 64, lineWidth: 6)
                    }
                }
            }
            Spacer(minLength: 0)
            Link(destination: ScoresQuickLink.url(.sources)) {
                ScoresWidgetFooter(display: display)
            }
            .accessibilityHint("Opens how these numbers are worked out")
        }
        // A Link draws its label in the accent colour; the dials keep the card's own colours instead
        // (blue labels and dashes were hard to read on the dark widget background).
        .foregroundStyle(.primary)
        .tint(.primary)
        .widgetURL(ScoresQuickLink.url(.today))
    }
}

/// Lock screen, rectangular: the three dials in a row, labels under them, and the "As of" time when
/// the snapshot is stale (the lock screen's tinted mode may flatten the dimming). Opens Today.
struct ScoresWidgetRectangularView: View {
    let display: ScoresWidgetDisplay

    var body: some View {
        let ring: CGFloat = display.asOf == nil ? 44 : 36
        VStack(spacing: 1) {
            HStack(spacing: 6) {
                ForEach(display.dials) { dial in
                    VStack(spacing: 1) {
                        ScoresWidgetRing(dial: dial, lineWidth: 3.5)
                            .frame(width: ring, height: ring)
                        Text(dial.label)
                            .font(.system(size: 8, weight: .semibold))
                            .lineLimit(1).minimumScaleFactor(0.6)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(dial.spoken)
                }
            }
            if let asOf = display.asOf {
                Text(asOf)
                    .font(.system(size: 9, weight: .semibold))
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("On-device estimates, not medical advice. Opens Today")
        .widgetURL(ScoresQuickLink.url(.today))
    }
}

/// Lock screen, circular: one score, opening its own screen.
struct ScoresWidgetCircularView: View {
    let dial: ScoresWidgetDial

    var body: some View {
        ScoresWidgetRing(dial: dial, lineWidth: 4.5, showsLabelInside: true)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(dial.spoken)
            .accessibilityHint("On-device estimate, not medical advice")
            .widgetURL(ScoresQuickLink.url(dial.route))
    }
}

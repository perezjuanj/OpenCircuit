// Shared design system for the tabbed UI overhaul.
//
// Goal: one "adaptive & clean" visual language (iOS-Health / Oura-like) that reads well in BOTH
// light and dark mode with zero per-call-site branching. Surfaces defer to system semantic colors;
// the metric palette is per-scheme (deeper on light card surfaces, brighter on dark) so the same
// accent passes contrast whether it's a chart line, an avg pill, or a value label.
//
// Nothing here holds state or touches the ring/store — it's pure styling, safe to use anywhere.

import SwiftUI
import UIKit

enum Theme {
    /// A per-scheme color: `light` on light backgrounds, `dark` on dark. Uses a dynamic UIColor so it
    /// resolves live when the appearance changes. Values are 0…1 RGB.
    private static func adaptive(_ light: (Double, Double, Double),
                                 _ dark: (Double, Double, Double)) -> Color {
        Color(uiColor: UIColor { tc in
            let c = tc.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }

    // MARK: Brand accent (tab tint, primary buttons, focus)

    /// App accent — a calm indigo-blue that reads as "health" in both modes (deeper on light for tint
    /// legibility, brighter on dark).
    static let accent = adaptive((0.28, 0.34, 0.86), (0.48, 0.55, 1.00))

    // MARK: Metric accent palette
    //
    // Curated so charts + hero numbers across the app read as one family. Light variants are deep
    // enough to pass WCAG large-text contrast on the near-white card surface; dark variants are
    // brightened for the dark card surface.

    static let hr     = adaptive((0.84, 0.15, 0.24), (0.99, 0.38, 0.45))   // heart rate — red
    static let hrv    = adaptive((0.11, 0.56, 0.34), (0.32, 0.82, 0.56))   // HRV — green
    static let spo2   = adaptive((0.08, 0.50, 0.76), (0.36, 0.78, 0.98))   // SpO₂ — cyan/blue
    static let rr     = adaptive((0.07, 0.54, 0.51), (0.30, 0.82, 0.78))   // respiratory rate — teal
    static let temp   = adaptive((0.83, 0.41, 0.08), (0.99, 0.62, 0.32))   // skin temp — orange
    static let sleep  = adaptive((0.42, 0.33, 0.85), (0.62, 0.55, 0.99))   // sleep — indigo/violet
    static let steps  = adaptive((0.15, 0.58, 0.33), (0.38, 0.82, 0.52))   // steps — green
    static let energy = adaptive((0.83, 0.39, 0.08), (0.99, 0.60, 0.30))   // active energy — orange
    static let stress = adaptive((0.80, 0.23, 0.23), (0.97, 0.46, 0.46))   // stress — red
    static var readiness: Color { accent }                                  // readiness — brand

    // MARK: Surfaces

    /// The page background behind every tab (defers to the grouped background so it tracks light/dark).
    static let pageBackground = Color(uiColor: .systemGroupedBackground)
    /// The raised card surface.
    static let cardBackground = Color(uiColor: .secondarySystemGroupedBackground)

    // MARK: Metrics

    /// Card corner radius — a touch rounder than the old 16 for the softer, modern look.
    static let cardCornerRadius: CGFloat = 20
    static let cardPadding: CGFloat = 16
    static let sectionSpacing: CGFloat = 16
}

// MARK: - Card surface

/// The single card treatment shared by EVERY card across the app (OCCard, the restyled chart cards,
/// the recent-readings rows): full width, comfortable padding, rounded surface, and a very soft lift
/// that shows in light mode and disappears in dark (shadows read poorly on dark). Applying this one
/// modifier everywhere is what makes the "one card look" actually uniform.
struct OCCardSurface: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    var padding: CGFloat = Theme.cardPadding

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                    .fill(Theme.cardBackground)
            )
            .shadow(color: .black.opacity(scheme == .dark ? 0.0 : 0.06), radius: 10, x: 0, y: 3)
    }
}

extension View {
    /// Wrap any content in the standard OpenCircuit card surface (rounded, padded, soft light-mode lift).
    func ocCardSurface(padding: CGFloat = Theme.cardPadding) -> some View {
        modifier(OCCardSurface(padding: padding))
    }
}

/// A card with the standard vertical-stack content layout + the shared surface.
struct OCCard<Content: View>: View {
    var spacing: CGFloat = 12
    var padding: CGFloat = Theme.cardPadding
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) { content() }
            .ocCardSurface(padding: padding)
    }
}

extension View {
    /// Wrap any content in the standard OpenCircuit card surface.
    func ocCard(spacing: CGFloat = 12, padding: CGFloat = Theme.cardPadding) -> some View {
        OCCard(spacing: spacing, padding: padding) { self }
    }
}

// MARK: - Section header

/// A tab-section header: an SF Symbol chip in the section's accent color + a title, with an optional
/// trailing accessory (e.g. a "7d avg" pill). Consistent across Today/Sleep/Activity/Trends.
struct OCSectionHeader<Accessory: View>: View {
    let title: String
    var systemImage: String?
    var tint: Color = .secondary
    @ViewBuilder var accessory: () -> Accessory

    init(_ title: String, systemImage: String? = nil, tint: Color = .secondary,
         @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.accessory = accessory
    }

    var body: some View {
        HStack(spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)
            }
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            accessory()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Big hero number

/// The large rounded numeric hero used at the top of a tab (e.g. sleep hours, steps). Uses
/// `@ScaledMetric` so the headline grows with Dynamic Type / accessibility text sizes.
struct OCHeroValue: View {
    let value: String
    var unit: String? = nil
    var tint: Color = .primary

    @ScaledMetric(relativeTo: .largeTitle) private var size: CGFloat = 40

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(value)
                .font(.system(size: size, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
                .contentTransition(.numericText())
            if let unit {
                Text(unit)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

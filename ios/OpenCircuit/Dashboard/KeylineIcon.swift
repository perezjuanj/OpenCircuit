// Keyline icons (MIT, keylineicons.com — see docs/THIRD_PARTY_NOTICES.md) used by the Today
// dashboard (#216) and onboarding (#255). The 24×24 stroke SVGs live unmodified in
// Assets.xcassets/Keyline as template, vector-preserving image sets, so they tint with
// `foregroundStyle` and stay sharp at every Dynamic Type size. Existing SF Symbols elsewhere in the app are untouched.

import SwiftUI

enum KeylineIcon: String, CaseIterable {
    case heart, activity, droplet, wind, thermometer, route, sparkles
    case arrowUpRight = "arrow-up-right"
    case arrowDownRight = "arrow-down-right"
    case minus, calendar
    case chevronLeft = "chevron-left"
    case chevronRight = "chevron-right"
    case circleAlert = "circle-alert"
    case circleCheck = "circle-check"
    case circle, bluetooth, info, check

    /// The asset-catalog name (the `Keyline` folder provides a namespace).
    var assetName: String { "Keyline/\(rawValue)" }
}

extension Image {
    init(keyline icon: KeylineIcon) {
        self.init(icon.assetName)
    }
}

/// A Keyline glyph sized to a text style, so it scales with Dynamic Type like an SF Symbol would.
struct KeylineGlyph: View {
    let icon: KeylineIcon
    var size: CGFloat = 16
    var relativeTo: Font.TextStyle = .subheadline

    @ScaledMetric private var scale: CGFloat = 1

    init(_ icon: KeylineIcon, size: CGFloat = 16, relativeTo: Font.TextStyle = .subheadline) {
        self.icon = icon
        self.size = size
        self.relativeTo = relativeTo
        _scale = ScaledMetric(wrappedValue: 1, relativeTo: relativeTo)
    }

    var body: some View {
        Image(keyline: icon)
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .frame(width: size * scale, height: size * scale)
            .accessibilityHidden(true)
    }
}

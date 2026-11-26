//
//  OCBrand.swift
//  OpenCircuit — Onboarding (gradient direction)
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - App mark

/// The logo. Drop `AppLogo.png` into the asset catalogue and this picks it up;
/// until then it falls back to a drawn mark so the header never renders empty.
struct BrandMark: View {
    var size: CGFloat = 17

    var body: some View {
        Group {
            if let image = UIImage(named: "OnboardingAppLogo") {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                FallbackMark()
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Used only when `AppLogo` is missing from the bundle.
struct FallbackMark: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            ZStack {
                Circle().fill(OCColor.brandCore)
                Circle()
                    .strokeBorder(Color.white.opacity(0.85), lineWidth: s * 0.09)
                    .padding(s * 0.26)
            }
        }
    }
}

// MARK: - Background

/// Full-bleed brand gradient. `.hero` is the welcome screen's strong version;
/// `.step` is the quieter one behind content.
struct OCScreenBackground: View {
    enum Variant: String { case hero, step }

    var variant: Variant = .hero

    var body: some View {
        ZStack {
            LinearGradient(
                stops: variant == .hero ? Self.heroStops : Self.stepStops,
                startPoint: .top,
                endPoint: .bottom
            )

            RadialGradient(
                colors: [OCColor.glow.opacity(variant == .hero ? 0.85 : 0.55), OCColor.glow.opacity(0)],
                center: .top,
                startRadius: 0,
                endRadius: 460
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private static let heroStops: [Gradient.Stop] = [
        .init(color: OCColor.gradientTop, location: 0),
        .init(color: OCColor.gradientUpper, location: 0.24),
        .init(color: OCColor.gradientFade, location: 0.66),
        .init(color: .black, location: 1)
    ]

    private static let stepStops: [Gradient.Stop] = [
        .init(color: OCColor.gradientStepTop, location: 0),
        .init(color: OCColor.gradientFade, location: 0.46),
        .init(color: .black, location: 1)
    ]
}

// MARK: - Progress

/// Dash indicator: the current step is a wide white dash, the rest short grey.
struct DashProgress: View {
    let total: Int
    let current: Int   // 1-based

    var body: some View {
        HStack(spacing: 6) {
            ForEach(1...max(total, 1), id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(index <= current ? Color.white : Color.white.opacity(0.28))
                    .frame(width: index == current ? 26 : 13, height: 3)
            }
        }
        .animation(.easeOut(duration: 0.25), value: current)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Step \(current) of \(total)"))
    }
}

// MARK: - Assets

/// A bundled catalogue image, scaled to fit. The onboarding images ship in Assets.xcassets.
struct OCAssetImage: View {
    let name: String

    var body: some View {
        Image(name)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
    }
}

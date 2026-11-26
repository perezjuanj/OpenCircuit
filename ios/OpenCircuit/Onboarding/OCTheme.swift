//
//  OCTheme.swift
//  OpenCircuit — Onboarding (gradient direction)
//
//  Tokens for the full-bleed gradient flow: brand blue as atmosphere, white as
//  the only action colour, SF Pro Dynamic Type text styles for type. No app-specific code.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Colour

extension Color {
    /// `Color(hex: 0x0000FF)` — sRGB, optional alpha.
    init(hex: UInt32, alpha: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}

enum OCColor {
    // Brand, sampled from the app mark.
    static let brandCore = Color(hex: 0x0000FF)
    static let brandEdge = Color(hex: 0x3B3FFF)
    static let brandHi   = Color(hex: 0x8F91FF)
    static let glow      = Color(hex: 0x6062FF)

    // Gradient stops, top to bottom.
    static let gradientTop    = Color(hex: 0x2A17FF)
    static let gradientUpper  = Color(hex: 0x0B00C8)
    static let gradientFade   = Color(hex: 0x05030F)
    static let gradientStepTop = Color(hex: 0x0F00C4)

    // Type
    static let ink  = Color.white
    static let dim  = Color.white.opacity(0.62)
    static let dim2 = Color.white.opacity(0.45)
    static let dim3 = Color.white.opacity(0.28)

    // Surfaces — translucent, never bordered (except selection).
    static let panel     = Color.white.opacity(0.07)
    static let panelHigh = Color.white.opacity(0.14)
    static let panelSoft = Color.white.opacity(0.05)
    static let rim       = Color.white.opacity(0.24)
    /// The strap key sheet's background.
    static let sheet     = Color(hex: 0x0C0D11)

    /// Text on the white pill.
    static let actionInk = Color(hex: 0x0A0A0C)
}

// MARK: - Metrics

enum OCMetric {
    static let gutter: CGFloat = 24
    static let pillHeight: CGFloat = 54
    static let panelRadius: CGFloat = 22
    static let cardRadius: CGFloat = 20
    static let bottomInset: CGFloat = 28
}

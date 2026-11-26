//
//  OCComponents.swift
//  OpenCircuit — Onboarding (gradient direction)
//
//  Type is Dynamic Type text styles throughout, so every step scales with the user's text size;
//  glyphs are Keyline (onboarding's icon set, see KeylineIcon.swift).
//

import SwiftUI

// MARK: - Press feedback

struct OCPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

// MARK: - Pill button

struct PillButton: View {
    enum Style: String { case light, dim }

    let title: String
    var style: Style = .light
    var isEnabled: Bool = true
    let action: () -> Void

    @ScaledMetric(relativeTo: .callout) private var height: CGFloat = OCMetric.pillHeight

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(.callout, weight: .medium))
                .tracking(-0.1)
                .foregroundStyle(style == .light ? OCColor.actionInk : Color.white)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .frame(minHeight: height)
                .background(
                    style == .light ? Color.white : Color.white.opacity(0.16),
                    in: Capsule(style: .continuous)
                )
                .shadow(
                    color: style == .light ? Color.black.opacity(0.55) : Color.clear,
                    radius: 18, x: 0, y: 10
                )
        }
        .buttonStyle(OCPressStyle())
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
    }
}

// MARK: - Device panel

struct DevicePanel: View {
    let device: ActiveDeviceChoice
    let isSelected: Bool
    let isInUse: Bool
    let accessibilityText: String
    let action: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Button(action: action) {
            // Accessibility sizes: art and radio above the text, so the name gets the full width.
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                : AnyLayout(HStackLayout(spacing: 14))
            layout {
                if typeSize.isAccessibilitySize {
                    HStack { art; Spacer(minLength: 0); radio }
                } else {
                    art
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(device.displayName)
                        .font(.system(.callout, weight: .semibold))
                        .tracking(-0.2)
                        .foregroundStyle(Color.white)
                        .fixedSize(horizontal: false, vertical: true)
                    if isInUse { TagPill(text: "In use", isSolid: true) }
                    Text(device.cardDetail)
                        .font(.footnote)
                        .foregroundStyle(OCColor.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .multilineTextAlignment(.leading)

                if !typeSize.isAccessibilitySize {
                    Spacer(minLength: 0)
                    radio
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                OCColor.panel,
                in: RoundedRectangle(cornerRadius: OCMetric.panelRadius, style: .continuous)
            )
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: OCMetric.panelRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: OCMetric.panelRadius, style: .continuous))
        }
        .buttonStyle(OCPressStyle())
        .animation(.easeOut(duration: 0.22), value: isSelected)
        // One element per panel: device, detail, "In use" (OnboardingFlow.cardAccessibilityLabel).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityText))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var art: some View {
        ZStack {
            // Soft spotlight so the black strap separates from the panel.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.white.opacity(0.18), Color.white.opacity(0)],
                        center: .center,
                        startRadius: 0,
                        endRadius: 44
                    )
                )
            OCAssetImage(name: device.onboardingAssetName)
                .frame(width: 66, height: 66)
                .shadow(color: Color.black.opacity(0.45), radius: 8, x: 0, y: 6)
                .scaleEffect(isSelected ? 1.04 : 1)
                .animation(.easeOut(duration: 0.22), value: isSelected)
        }
        .frame(width: 66, height: 66)
        .accessibilityHidden(true)
    }

    private var radio: some View {
        ZStack {
            Circle()
                .fill(isSelected ? Color.white : Color.clear)
            Circle()
                .strokeBorder(isSelected ? Color.white : Color.white.opacity(0.4), lineWidth: 1.5)
            if isSelected {
                Circle()
                    .fill(OCColor.brandCore)
                    .frame(width: 8, height: 8)
            }
        }
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
    }
}

// MARK: - Step row

struct StepRow: View {
    let index: Int
    let title: String
    let detail: String
    let isLast: Bool

    @ScaledMetric(relativeTo: .caption) private var badge: CGFloat = 26

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            VStack(spacing: 0) {
                ZStack {
                    Circle().fill(Color.white.opacity(0.12))
                    Text("\(index)")
                        .font(.system(.caption, weight: .semibold))
                        .foregroundStyle(Color.white)
                }
                .frame(width: badge, height: badge)

                if !isLast {
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.32), Color.white.opacity(0.06)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                        .padding(.vertical, 5)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(.subheadline, weight: .semibold))
                    .tracking(-0.15)
                    .foregroundStyle(Color.white)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(OCColor.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 2)
            .padding(.bottom, isLast ? 0 : 15)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Permission panel

struct PermissionPanel: View {
    let assetName: String
    let title: String
    let tag: String
    var tagIsSolid: Bool = false
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            OCAssetImage(name: assetName)
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(OCColor.rim, lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.45), radius: 7, x: 0, y: 6)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        titleText
                        TagPill(text: tag, isSolid: tagIsSolid)
                        Spacer(minLength: 0)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        titleText
                        TagPill(text: tag, isSolid: tagIsSolid)
                    }
                }
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(OCColor.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(OCColor.panel, in: RoundedRectangle(cornerRadius: OCMetric.cardRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var titleText: some View {
        Text(title)
            .font(.system(.subheadline, weight: .semibold))
            .tracking(-0.15)
            .foregroundStyle(Color.white)
    }
}

struct TagPill: View {
    let text: String
    var isSolid: Bool = false

    var body: some View {
        Text(text.uppercased())
            .font(.system(.caption2, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(isSolid ? OCColor.actionInk : Color.white.opacity(0.8))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                isSolid ? Color.white : Color.white.opacity(0.14),
                in: Capsule(style: .continuous)
            )
            .fixedSize()
    }
}

// MARK: - Legal panel

struct LegalPanel: View {
    let icon: KeylineIcon
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 9) {
                KeylineGlyph(icon, size: 15, relativeTo: .subheadline)
                    .foregroundStyle(Color.white)
                Text(title)
                    .font(.system(.subheadline, weight: .semibold))
                    .tracking(-0.1)
                    .foregroundStyle(Color.white)
            }
            Text(detail)
                .font(.footnote)
                .foregroundStyle(OCColor.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .background(OCColor.panel, in: RoundedRectangle(cornerRadius: OCMetric.cardRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Note

struct NotePanel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(Color.white.opacity(0.62))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 15)
            .padding(.vertical, 13)
            .background(OCColor.panelSoft, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

// MARK: - Device pill

struct DevicePill: View {
    let device: ActiveDeviceChoice
    var onChange: (() -> Void)? = nil

    var body: some View {
        // One capsule when it fits; at large text sizes the name and Change stack in a rounded box.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                name
                if onChange != nil {
                    Rectangle()
                        .fill(Color.white.opacity(0.22))
                        .frame(width: 1, height: 12)
                        .padding(.leading, 2)
                    change
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 12)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.12), in: Capsule(style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                name
                if onChange != nil { change }
            }
            .padding(12)
            .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private var name: some View {
        HStack(spacing: 8) {
            KeylineGlyph(device.onboardingGlyph, size: 13, relativeTo: .footnote)
                .foregroundStyle(Color.white)
            Text(device.displayName)
                .font(.system(.footnote, weight: .medium))
                .foregroundStyle(Color.white)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var change: some View {
        if let onChange = onChange {
            Button(action: onChange) {
                Text("Change")
                    .font(.footnote)
                    .foregroundStyle(Color.white.opacity(0.62))
                    .padding(.vertical, 2)
            }
            .buttonStyle(OCPressStyle())
            .accessibilityLabel(Text("Change device"))
        }
    }
}

// MARK: - Alternate device row

struct AltDeviceRow: View {
    let device: ActiveDeviceChoice
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                KeylineGlyph(device.onboardingGlyph, size: 16, relativeTo: .footnote)
                    .foregroundStyle(Color.white.opacity(0.75))

                VStack(alignment: .leading, spacing: 1) {
                    Text("Using the \(device.displayName)?")
                        .font(.system(.footnote, weight: .semibold))
                        .foregroundStyle(Color.white)
                    Text(device.cardDetail)
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.55))
                }
                .multilineTextAlignment(.leading)

                Spacer(minLength: 0)

                KeylineGlyph(.chevronRight, size: 13, relativeTo: .caption)
                    .foregroundStyle(Color.white.opacity(0.45))
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 13)
            .background(
                Color.white.opacity(0.05),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(OCPressStyle())
    }
}

// MARK: - Ticks

/// One row when it fits, stacked at large text sizes.
struct TickRow: View {
    let items: [String]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                ticks
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 6) { ticks }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(items.joined(separator: ", ")))
    }

    private var ticks: some View {
        ForEach(items, id: \.self) { item in
            HStack(spacing: 6) {
                KeylineGlyph(.check, size: 11, relativeTo: .caption)
                    .foregroundStyle(Color.white)
                Text(item)
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.62))
                    .fixedSize()
            }
        }
    }
}

// MARK: - Scrolling step body

/// Every step's body: scrolls when the text outgrows the screen (the largest accessibility sizes),
/// and fills the height when it doesn't, so a step's own Spacers still place it.
struct OCStepScroll<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { proxy in
            ScrollView(.vertical) {
                content()
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .top)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.hidden)
        }
    }
}

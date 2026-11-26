//
//  OCFlowView.swift
//  OpenCircuit — Onboarding (gradient direction)
//
//  Container: gradient background, mark + skip, one step at a time,
//  dash progress and one white pill at the bottom.
//

import SwiftUI

struct OnboardingFlowView: View {

    @ObservedObject var model: OnboardingViewModel
    @State private var isRequestingPermissions = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let onFinish: () -> Void
    let onSkip: () -> Void
    var requestPermissions: () async -> Void = { await OnboardingPermissions.request() }

    private var motion: Animation? { reduceMotion ? nil : .easeOut(duration: 0.26) }

    /// `OnboardingFlow`'s page for the current step (same order).
    private var page: OnboardingFlow.Page { OnboardingFlow.Page(rawValue: model.step.rawValue) ?? .welcome }

    var body: some View {
        ZStack {
            OCScreenBackground(variant: model.step == .welcome ? .hero : .step)

            VStack(spacing: 0) {
                header
                content
                bottom
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            if model.step != .welcome {
                Button {
                    withAnimation(motion) { model.back() }
                } label: {
                    KeylineGlyph(.chevronLeft, size: 18, relativeTo: .body)
                        .foregroundStyle(Color.white.opacity(0.85))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(OCPressStyle())
                .accessibilityLabel(Text("Back"))
            }

            ZStack {
                Circle().fill(Color.white)
                BrandMark(size: 17)
            }
            .frame(width: 27, height: 27)
            .accessibilityHidden(true)

            Text("OpenCircuit")
                .font(.system(.body, weight: .medium))
                .tracking(-0.2)
                .foregroundStyle(Color.white)
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 0)

            // Skip on every step; on the last, "Set Up Later" when it ends on the strap's setup, and
            // nothing when the primary button already finishes. Both finish like Get Started.
            if let secondary = model.flow.secondary(on: page, pick: model.device) {
                Button(action: onSkip) {
                    Text(secondary.title)
                        .font(.subheadline)
                        .foregroundStyle(Color.white.opacity(0.62))
                        .padding(.vertical, 6)
                        .padding(.leading, 14)
                }
                .buttonStyle(OCPressStyle())
            }
        }
        .padding(.horizontal, OCMetric.gutter)
        .padding(.top, 22)
        // Chrome stops growing at xxxLarge so the step itself keeps the room; the step scrolls at any size.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    // MARK: Step content

    private var content: some View {
        Group {
            switch model.step {
            case .welcome: WelcomeStep()
            case .device: DeviceStep(model: model)
            case .setup: SetupStep(model: model)
            case .permissions: PermissionsStep()
            case .legal: LegalStep()
            }
        }
        .id(model.step)
        .transition(
            reduceMotion ? .opacity : .asymmetric(
                insertion: .opacity.combined(with: .offset(x: 24)),
                removal: .opacity
            )
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 24, coordinateSpace: .local)
                .onEnded { value in
                    let dx = value.translation.width
                    let dy = value.translation.height
                    if dx > 50, abs(dx) > abs(dy), model.step != .welcome {
                        withAnimation(motion) { model.back() }
                    }
                }
        )
    }

    // MARK: Bottom

    private var bottom: some View {
        VStack(spacing: 0) {
            DashProgress(total: model.totalSteps, current: model.step.position)
                .padding(.bottom, 18)

            PillButton(
                title: model.primaryCTATitle,
                isEnabled: model.canAdvance && !isRequestingPermissions,
                action: handlePrimary
            )

            if model.step == .welcome {
                PillButton(title: "Skip for now", style: .dim, action: onSkip)
                    .padding(.top, 10)
            }

            Text(model.footnote)
                .font(.footnote)
                .foregroundStyle(Color.white.opacity(0.5))
                .multilineTextAlignment(.center)
                .padding(.top, 14)
        }
        .padding(.horizontal, OCMetric.gutter)
        .padding(.bottom, OCMetric.bottomInset)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private func handlePrimary() {
        if model.isLastStep {
            onFinish()
            return
        }

        if model.step == .permissions {
            guard !isRequestingPermissions else { return }
            isRequestingPermissions = true
            Task { @MainActor in
                await requestPermissions()
                isRequestingPermissions = false
                withAnimation(motion) { model.advance() }
            }
            return
        }

        withAnimation(motion) { model.advance() }
    }
}

// MARK: - Shared step pieces

/// Headline + optional lead line, used at the top of the content screens.
struct OCStepTitle: View {
    let headline: String
    var lead: String? = nil
    var compact: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(headline)
                .font(.system(compact ? .title : .largeTitle, weight: .semibold))
                .tracking(compact ? -0.7 : -0.9)
                .foregroundStyle(Color.white)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            if let lead = lead {
                Text(lead)
                    .font(.callout)
                    .foregroundStyle(OCColor.dim)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

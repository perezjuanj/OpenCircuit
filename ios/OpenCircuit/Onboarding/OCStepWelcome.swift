//
//  OCStepWelcome.swift
//  OpenCircuit — Onboarding (gradient direction)
//

import SwiftUI

struct WelcomeStep: View {
    var body: some View {
        OCStepScroll {
            VStack(spacing: 0) {
                Spacer(minLength: 16)

                OCAssetImage(name: "OnboardingHeroWearables")
                    .frame(maxWidth: .infinity, maxHeight: 230)
                    .padding(.horizontal, OCMetric.gutter)
                    .accessibilityHidden(true)

                Spacer(minLength: 16)

                VStack(alignment: .leading, spacing: 0) {
                    Text(OnboardingCopy.welcomeHeadline)
                        .font(.system(.largeTitle, weight: .semibold))
                        .tracking(-0.9)
                        .foregroundStyle(Color.white)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)

                    Text(DeviceCopy.welcomeLead)
                        .font(.callout)
                        .foregroundStyle(OCColor.dim)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 14)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, OCMetric.gutter)
                .padding(.bottom, 24)
            }
        }
    }
}

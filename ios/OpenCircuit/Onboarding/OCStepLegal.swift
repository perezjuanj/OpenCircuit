//
//  OCStepLegal.swift
//  OpenCircuit — Onboarding (gradient direction)
//
//  The shared disclaimer (`DeviceCopy.disclaimer`, also Profile ▸ About), shown as its two halves.
//

import SwiftUI

struct LegalStep: View {
    var body: some View {
        OCStepScroll {
            VStack(alignment: .leading, spacing: 0) {
                OCStepTitle(
                    headline: "Before you\nstart",
                    lead: "Two things worth knowing. Then you're in.",
                    compact: true
                )
                .padding(.horizontal, OCMetric.gutter)
                .padding(.top, 20)

                VStack(spacing: 11) {
                    LegalPanel(icon: .info, title: "Independent app", detail: DeviceCopy.notAffiliated)
                    LegalPanel(icon: .activity, title: "Not a medical device", detail: DeviceCopy.notMedical)
                }
                .padding(.horizontal, OCMetric.gutter)
                .padding(.top, 24)

                TickRow(items: OnboardingCopy.ticks)
                    .padding(.horizontal, OCMetric.gutter)
                    .padding(.top, 16)
                    .padding(.bottom, 24)

                Spacer(minLength: 0)
            }
        }
    }
}

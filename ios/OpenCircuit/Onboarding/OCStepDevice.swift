//
//  OCStepDevice.swift
//  OpenCircuit — Onboarding (gradient direction)
//

import SwiftUI

struct DeviceStep: View {
    @ObservedObject var model: OnboardingViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        OCStepScroll {
            VStack(alignment: .leading, spacing: 0) {
                OCStepTitle(
                    headline: "Which one\ndo you wear?",
                    lead: "Pick one and we'll show only its first steps.",
                    compact: true
                )
                .padding(.horizontal, OCMetric.gutter)
                .padding(.top, 20)

                VStack(spacing: 11) {
                    ForEach(ActiveDeviceChoice.allCases, id: \.self) { choice in
                        DevicePanel(
                            device: choice,
                            isSelected: model.device == choice,
                            isInUse: model.flow.inUse == choice,
                            accessibilityText: model.flow.cardAccessibilityLabel(choice)
                        ) {
                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) {
                                model.select(choice)
                            }
                        }
                    }
                }
                .padding(.horizontal, OCMetric.gutter)
                .padding(.top, 26)

                NotePanel(text: DeviceCopy.oneAtATime)
                    .padding(.horizontal, OCMetric.gutter)
                    .padding(.top, 14)
                    .padding(.bottom, 24)

                Spacer(minLength: 0)
            }
        }
    }
}

//
//  OCStepSetup.swift
//  OpenCircuit — Onboarding (gradient direction)
//
//  Device-aware first steps. The densest screen, so it scrolls on small devices and at large
//  Dynamic Type sizes.
//

import SwiftUI

struct SetupStep: View {
    @ObservedObject var model: OnboardingViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var device: ActiveDeviceChoice { model.shownSetupDevice }
    private var motion: Animation? { reduceMotion ? nil : .easeOut(duration: 0.26) }

    var body: some View {
        OCStepScroll {
            VStack(alignment: .leading, spacing: 0) {
                OCStepTitle(headline: "Getting started", compact: true)
                    .padding(.horizontal, OCMetric.gutter)
                    .padding(.top, 20)

                DevicePill(device: device, onChange: {
                    withAnimation(motion) { model.changeDevice() }
                })
                .padding(.horizontal, OCMetric.gutter)
                .padding(.top, 18)

                // The pick isn't the device in use: say what is, and what switches (OnboardingFlow).
                if let note = model.flow.switchNote(for: model.device) {
                    NotePanel(text: note)
                        .padding(.horizontal, OCMetric.gutter)
                        .padding(.top, 14)
                }

                let steps = device.onboardingSteps
                VStack(spacing: 0) {
                    ForEach(steps.indices, id: \.self) { index in
                        StepRow(
                            index: index + 1,
                            title: steps[index].title,
                            detail: steps[index].detail,
                            isLast: index == steps.count - 1
                        )
                    }
                }
                .padding(.horizontal, OCMetric.gutter)
                .padding(.top, 20)

                if let hint = model.flow.setupHint(for: device, pick: model.device) {
                    Text(hint)
                        .font(.footnote)
                        .foregroundStyle(Color.white.opacity(0.62))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, OCMetric.gutter)
                        .padding(.top, 14)
                }

                VStack(spacing: 8) {
                    ForEach(model.otherSetupDevices, id: \.self) { other in
                        AltDeviceRow(device: other) {
                            withAnimation(motion) { model.select(other) }
                        }
                    }
                }
                .padding(.horizontal, OCMetric.gutter)
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
        }
    }
}

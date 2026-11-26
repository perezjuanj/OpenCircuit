//
//  OCStepPermissions.swift
//  OpenCircuit — Onboarding (gradient direction)
//
//  Continue on this step asks iOS for both (`OnboardingPermissions`), so the copy says so.
//

import SwiftUI

struct PermissionsStep: View {
    var body: some View {
        OCStepScroll {
            VStack(alignment: .leading, spacing: 0) {
                OCStepTitle(
                    headline: "Two things\nto allow",
                    lead: OnboardingCopy.permissionsLead,
                    compact: true
                )
                .padding(.horizontal, OCMetric.gutter)
                .padding(.top, 20)

                VStack(spacing: 11) {
                    PermissionPanel(
                        assetName: "PermissionBluetooth",
                        title: "Bluetooth",
                        tag: "Required",
                        tagIsSolid: true,
                        detail: DeviceCopy.bluetoothPurpose
                    )

                    PermissionPanel(
                        assetName: "PermissionAppleHealth",
                        title: "Apple Health",
                        tag: "You choose",
                        detail: "Saves your metrics to Apple Health. You choose exactly which types to share."
                    )
                }
                .padding(.horizontal, OCMetric.gutter)
                .padding(.top, 26)

                NotePanel(text: OnboardingCopy.permissionsNote)
                    .padding(.horizontal, OCMetric.gutter)
                    .padding(.top, 14)
                    .padding(.bottom, 24)

                Spacer(minLength: 0)
            }
        }
    }
}

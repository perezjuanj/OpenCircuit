//
//  OCPermissions.swift
//  OpenCircuit — Onboarding (gradient direction)
//

import CoreBluetooth
import Foundation

enum OnboardingPermissions {

    /// Awaited by `OnboardingFlowView` before step 4 advances, so the system
    /// sheets appear against the screen that explains them.
    @MainActor
    static func request() async {
        await requestBluetooth()
        await requestHealth()
    }

    // MARK: Bluetooth

    @MainActor
    private static func requestBluetooth() async {
        // Creating a CBCentralManager triggers the iOS Bluetooth permission prompt
        // if authorization hasn't been determined yet.
        let probe = BluetoothPermissionProbe()
        await probe.requestIfNeeded()
    }

    // MARK: Apple Health

    private static func requestHealth() async {
        try? await HealthKitWriter().requestAuthorization()
    }
}

@MainActor
private final class BluetoothPermissionProbe: NSObject, CBCentralManagerDelegate {
    private var manager: CBCentralManager?
    private var continuation: CheckedContinuation<Void, Never>?

    func requestIfNeeded() async {
        guard CBCentralManager.authorization == .notDetermined else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.continuation = cont
            self.manager = CBCentralManager(delegate: self, queue: .main)
            // Safety timeout in case CoreBluetooth doesn't fire state update promptly.
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self?.finish()
            }
        }
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor [weak self] in
            if CBCentralManager.authorization != .notDetermined || central.state != .unknown {
                self?.finish()
            }
        }
    }

    private func finish() {
        continuation?.resume()
        continuation = nil
        manager = nil
    }
}

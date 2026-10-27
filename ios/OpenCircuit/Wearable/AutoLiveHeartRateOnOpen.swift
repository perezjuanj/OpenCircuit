import Foundation
import OpenCircuitKit
import SwiftUI

// Live heart rate when the app opens (decision 81, #336). The pure decision is
// `OpenCircuitKit.AutoLiveHeartRate`; this file holds the per-device setting, the copy, the drivers
// that reach each device's EXISTING Measure, and the coordinator that remembers one activation.

// MARK: Setting and copy

extension ActiveDeviceChoice {
    /// The per-device switch (decision 81e), one key per device so each keeps its own.
    var autoLiveHeartRateOnOpenKey: String { "liveHeartRate.onOpen.v1.\(rawValue)" }

    /// Whether the person (or the device's default) has the setting on. A device that can't do it is
    /// always off, whatever an old key says.
    func autoLiveHeartRateOnOpenEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        switch autoLiveHeartRateOnOpen {
        case .unsupported: return false
        case .supported(let defaultOn): return defaults.object(forKey: autoLiveHeartRateOnOpenKey) as? Bool ?? defaultOn
        }
    }
}

enum AutoLiveHeartRateOnOpenCopy {
    static let label = "Live heart rate when the app opens"
    /// The strap's and the ring's heart-rate Measure both run for `StrapLiveHeartRate.duration`
    /// (the ring's is `RingSession`'s 90 s user measure).
    @MainActor static var footnote: String {
        "Measures for \(Int(StrapLiveHeartRate.duration)) seconds each time you open the app."
    }
}

/// The settings row, the same in each device's own settings screen.
struct AutoLiveHeartRateOnOpenRow: View {
    @AppStorage private var isOn: Bool

    init(choice: ActiveDeviceChoice) {
        var defaultOn = false
        if case .supported(let on) = choice.autoLiveHeartRateOnOpen { defaultOn = on }
        _isOn = AppStorage(wrappedValue: defaultOn, choice.autoLiveHeartRateOnOpenKey)
    }

    var body: some View {
        Section {
            Toggle(AutoLiveHeartRateOnOpenCopy.label, isOn: $isOn)
        } footer: {
            Text(AutoLiveHeartRateOnOpenCopy.footnote)
        }
    }
}

// MARK: Drivers

/// What the coordinator sees of one device. Each implementation reaches the device's existing Measure
/// (decision 81a), never a new path.
@MainActor
protocol AutoLiveHeartRateDriver {
    /// Connected and able to start a stream.
    var sessionReady: Bool { get }
    var syncing: Bool { get }
    /// The foreground sync's start isn't decided yet (81b).
    var syncStillToDecide: Bool { get }
    var owner: AutoLiveHeartRate.Owner { get }
    func startMeasure()
    /// Stops the Measure stream. Called only while a Measure (never a workout) owns it.
    func stopMeasure()
}

extension AutoLiveHeartRateDriver {
    var facts: AutoLiveHeartRateFacts {
        AutoLiveHeartRateFacts(sessionReady: sessionReady, syncing: syncing, syncStillToDecide: syncStillToDecide, owner: owner)
    }
}

/// What the view watches to re-ask the coordinator.
struct AutoLiveHeartRateFacts: Equatable {
    var sessionReady: Bool
    var syncing: Bool
    var syncStillToDecide: Bool
    var owner: AutoLiveHeartRate.Owner
}

/// Re-asks the coordinator when the driver's facts change. A modifier of its own, so the screen's
/// already long `onChange` chain doesn't grow.
struct AutoLiveHeartRateObserver: ViewModifier {
    let facts: AutoLiveHeartRateFacts?
    let reevaluate: () -> Void

    func body(content: Content) -> some View {
        content.onChange(of: facts) { _, _ in reevaluate() }
    }
}

/// The strap: `HelioSession.startLiveHeartRate(duration:)`, as `StrapLiveHeartRate.toggle()` starts it.
@MainActor
struct StrapAutoLiveDriver: AutoLiveHeartRateDriver {
    let session: HelioSession

    var sessionReady: Bool { session.ready && session.canStreamHeartRate }
    var syncing: Bool { session.syncing }
    var syncStillToDecide: Bool { !session.activationSyncSettled }
    var owner: AutoLiveHeartRate.Owner {
        if session.liveHeartRateRunning {
            return session.liveHeartRateOwner == .workout ? .workout : .measure
        }
        // A recording workout holds the strap before its stream has started.
        return StrapWorkoutRecorder.holdsStrapLink ? .workout : .none
    }

    func startMeasure() { session.startLiveHeartRate(duration: StrapLiveHeartRate.duration) }
    func stopMeasure() { session.stopLiveHeartRate() }
}

/// The ring: `RingSession.startMonitoring(mode: .hr, userInitiated: true, quickLiveRead: true)`, the
/// call the Measure button makes.
@MainActor
struct RingAutoLiveDriver: AutoLiveHeartRateDriver {
    let session: RingSession
    /// ContentView's armed foreground sync (`pendingAutoSync`): still to run or be skipped by its throttle.
    let foregroundSyncPending: Bool

    var sessionReady: Bool {
        session.ready && !session.notStreaming && !session.calibrationCapturing
            && !session.capturingHistoricPull && !session.capturingForensicSweep && !session.probing
    }
    var syncing: Bool { session.syncing }
    var syncStillToDecide: Bool { foregroundSyncPending }
    var owner: AutoLiveHeartRate.Owner {
        if session.workoutHolding { return .workout }
        return session.monitoring ? .measure : .none
    }

    func startMeasure() { session.startMonitoring(mode: .hr, userInitiated: true, quickLiveRead: true) }
    func stopMeasure() { session.stopLiveMonitoring() }
}

// MARK: Coordinator

/// One foreground activation's memory (81c): what was started, and what the person did. The view calls
/// `activate` when the scene becomes active, `evaluate` whenever the driver's facts change, and
/// `leftForeground` when the scene goes to the background.
@MainActor
final class AutoLiveHeartRateCoordinator {
    private let defaults: UserDefaults
    private let measureDuration: TimeInterval

    private var choice: ActiveDeviceChoice?
    private var activatedAt: Date?
    private var inFront = false
    private var syncRan = false
    private var autoStarted = false
    private var stoppedByPerson = false
    /// The stream running now is the one this coordinator started (81d stops only that one).
    private var autoStreamLive = false
    private var autoStartedAt: Date?

    init(defaults: UserDefaults = .standard, measureDuration: TimeInterval = StrapLiveHeartRate.duration) {
        self.defaults = defaults
        self.measureDuration = measureDuration
    }

    /// The scene became active: a fresh activation, then ask.
    func activate(choice: ActiveDeviceChoice, driver: (any AutoLiveHeartRateDriver)?, now: Date = Date()) {
        self.choice = choice
        activatedAt = now
        inFront = true
        syncRan = false
        autoStarted = false
        stoppedByPerson = false
        autoStreamLive = false
        autoStartedAt = nil
        evaluate(choice: choice, driver: driver, now: now)
    }

    /// Something changed (the link, a sync, the stream's owner): ask again.
    func evaluate(choice: ActiveDeviceChoice, driver: (any AutoLiveHeartRateDriver)?, now: Date = Date()) {
        guard let activatedAt, let driver else { return }
        if self.choice != choice {
            // The person switched devices mid-activation: this activation is spent.
            self.choice = choice
            autoStarted = true
            autoStreamLive = false
            return
        }
        if driver.syncing { syncRan = true }
        // The stream we started has ended: by its own timer, or early because the person stopped it
        // (or the link dropped). An early end is treated as the person's stop, the side where nothing
        // restarts (81c).
        if autoStreamLive, driver.owner != .measure {
            autoStreamLive = false
            if let autoStartedAt, now.timeIntervalSince(autoStartedAt) < measureDuration - 2 { stoppedByPerson = true }
        }
        let decision = AutoLiveHeartRate.decide(.init(
            supported: choice.autoLiveHeartRateOnOpen != .unsupported,
            settingOn: choice.autoLiveHeartRateOnOpenEnabled(defaults),
            inFront: inFront, activatedAt: activatedAt, now: now,
            sessionReady: driver.sessionReady, syncing: driver.syncing, syncRanSinceActivation: syncRan,
            syncStillToDecide: driver.syncStillToDecide, owner: driver.owner,
            alreadyAutoStarted: autoStarted, stoppedByPerson: stoppedByPerson))
        guard decision == .startNow else { return }
        autoStarted = true
        autoStreamLive = true
        autoStartedAt = now
        driver.startMeasure()
    }

    /// The scene left the front (81d): an automatically started stream stops at once. A Measure the
    /// person started keeps today's behaviour.
    func leftForeground(driver: (any AutoLiveHeartRateDriver)?) {
        inFront = false
        defer { autoStreamLive = false }
        guard autoStreamLive, let driver, driver.owner == .measure else { return }
        driver.stopMeasure()
    }
}

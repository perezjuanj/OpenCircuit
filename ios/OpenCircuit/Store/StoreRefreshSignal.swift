import Foundation
import Observation
import SwiftData
import SwiftUI

/// The one coalesced "the store changed" signal the dashboard's off-main reads refresh on
/// (decision 75b).
///
/// Every `ModelContext` save bumps `version`, except while a sync runs: then the bumps are throttled
/// to at most one per `interval`, trailing, so a sync's tens of saves cost a few refreshes instead of
/// one each. When the sync ends (any way it ends) `version` is bumped once, immediately, so no card
/// shows data older than the end of the sync that wrote it. Outside a sync (a workout stop, a live
/// reading, a sleep or nap edit, a delete) a save refreshes at once, as `@Query` did.
///
/// It is also where the per-sync main-thread breadcrumb comes from (decision 75d ii): while a sync
/// runs, a `MainThreadStallProbe` measures the main run loop, and its longest stall is logged when
/// the sync ends.
@Observable
@MainActor
final class StoreRefreshSignal {

    static let shared = StoreRefreshSignal()

    /// The trailing refresh interval while a sync runs. 3 s: decision 75b's figure; the benchmark in
    /// `SyncSaveMainThreadBenchmarkTests` and the report give the numbers behind it.
    nonisolated static let syncInterval: TimeInterval = 3

    /// Moves when the cards should read again. Its value means nothing; only a change does.
    private(set) var version = 0

    /// Why `version` moved.
    enum Reason: Equatable { case save, trailing, syncEnd }
    /// Told about every refresh, with its reason (tests).
    @ObservationIgnored var onRefresh: (@MainActor (Reason) -> Void)?

    @ObservationIgnored let interval: TimeInterval
    @ObservationIgnored private(set) var syncActive = false
    @ObservationIgnored private var trailing: Task<Void, Never>?
    @ObservationIgnored private var saveObserver: NSObjectProtocol?
    @ObservationIgnored private var syncMonitor: SyncActivityMonitor?
    @ObservationIgnored private let probe = MainThreadStallProbe()
    @ObservationIgnored private var savesThisSync = 0
    @ObservationIgnored private var refreshesThisSync = 0
    /// Where the per-sync breadcrumb goes. Counts and milliseconds only.
    @ObservationIgnored var breadcrumb: @MainActor (String) -> Void = {
        ObservabilityStore().recordMetricEvent(source: "sync-ui", detail: $0)
    }

    init(interval: TimeInterval = StoreRefreshSignal.syncInterval) {
        self.interval = interval
    }

    // MARK: Inputs

    /// Follows every `ModelContext` save, or only saves of contexts on `container` (tests). The
    /// dashboard's own reads never save, so they can't feed back.
    func observeSaves(of container: ModelContainer? = nil) {
        if let saveObserver { NotificationCenter.default.removeObserver(saveObserver) }
        saveObserver = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil,
                                                              queue: nil) { [weak self] note in
            if let container, (note.object as? ModelContext)?.container !== container { return }
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.storeDidSave() }
            } else {
                Task { @MainActor in self?.storeDidSave() }
            }
        }
    }

    /// Follows whether the active wearable's session is syncing, foreground or background: the ring's
    /// `RingSession.syncing`, the strap's `HelioSession.syncing`. A sync ends when that reads false,
    /// whether the session finished, failed, was cancelled, or went away with its link.
    func followSyncs(_ isSyncing: @escaping @MainActor () -> Bool = {
        ActiveWearable.activeDeviceSession()?.syncing == true
    }) {
        syncMonitor = SyncActivityMonitor(isSyncing: isSyncing) { [weak self] in self?.setSyncActive($0) }
        syncMonitor?.start()
    }

    /// A save landed.
    func storeDidSave() {
        guard syncActive else { refresh(.save); return }
        savesThisSync += 1
        guard trailing == nil else { return }
        let interval = interval
        trailing = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.trailing = nil
            self.refresh(.trailing)
        }
    }

    /// A sync started or ended. The end flushes: one refresh, now.
    func setSyncActive(_ active: Bool) {
        guard active != syncActive else { return }
        syncActive = active
        if active {
            savesThisSync = 0
            refreshesThisSync = 0
            probe.start()
            return
        }
        trailing?.cancel()
        trailing = nil
        refresh(.syncEnd)
        let stalls = probe.stop()
        breadcrumb(Self.breadcrumbDetail(stalls, saves: savesThisSync, refreshes: refreshesThisSync))
    }

    /// The breadcrumb line: `longest=<ms>ms busy=<ms>ms stretches=<n> saves=<n> refreshes=<n>`.
    nonisolated static func breadcrumbDetail(_ r: MainThreadStallProbe.Report, saves: Int, refreshes: Int) -> String {
        "longest=\(r.longestMS)ms busy=\(r.busyMS)ms stretches=\(r.stretches) saves=\(saves) refreshes=\(refreshes)"
    }

    /// Whether the per-sync main-thread probe is running (it runs only while a sync is active).
    var stallProbeRunning: Bool { probe.isRunning }

    private func refresh(_ reason: Reason) {
        version &+= 1
        if syncActive || reason == .syncEnd { refreshesThisSync += 1 }
        onRefresh?(reason)
    }
}

/// Watches a main-actor value through Observation and reports each change of it (once per change,
/// read after the mutation lands). Constructs nothing: the closure decides what it reads.
@MainActor
final class SyncActivityMonitor {
    private let isSyncing: @MainActor () -> Bool
    private let onChange: @MainActor (Bool) -> Void
    private var last = false

    init(isSyncing: @escaping @MainActor () -> Bool, onChange: @escaping @MainActor (Bool) -> Void) {
        self.isSyncing = isSyncing
        self.onChange = onChange
    }

    func start() { track() }

    private func track() {
        let now = withObservationTracking { isSyncing() } onChange: { [weak self] in
            // Fires before the mutation; read again once it has landed.
            Task { @MainActor in self?.track() }
        }
        guard now != last else { return }
        last = now
        onChange(now)
    }
}

/// The signal a view's reads key on: `StoreRefreshSignal.shared` unless a test injects its own.
private struct StoreRefreshSignalKey: EnvironmentKey {
    static let defaultValue: StoreRefreshSignal? = nil
}

extension EnvironmentValues {
    var storeRefreshSignal: StoreRefreshSignal? {
        get { self[StoreRefreshSignalKey.self] }
        set { self[StoreRefreshSignalKey.self] = newValue }
    }
}

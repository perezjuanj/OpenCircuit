import BackgroundTasks
import SwiftData
import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    private let scheduler = BackgroundRefreshScheduler()

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Show health alerts / reminders even when the app is in the FOREGROUND — which is the
        // primary moment they're evaluated (scenePhase==.active and on sync completion). Without
        // a delegate returning presentation options, iOS silently suppresses foreground-delivered
        // local notifications, so the user would see nothing and the backoff would still record a
        // fire — making them miss the alert entirely.
        UNUserNotificationCenter.current().delegate = self
        scheduler.register { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Self.handle(refreshTask, kind: .appRefresh,
                        timeout: RingBackgroundSyncService.defaultTimeout)
        }
        // BGProcessingTask: the longer-window sibling that finally gives the optical-HR poll room
        // to clear its ~60 s warm-up in the background (#45). Same sync path, larger time budget.
        scheduler.registerProcessing { task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Self.handle(processingTask, kind: .processing,
                        timeout: RingBackgroundSyncService.processingTimeout)
        }

        // Re-instantiate the CBCentralManager (with its restore identifier) during launch so
        // iOS can deliver state restoration — including when it relaunches us in the
        // background because the ring came back in range. Touching `.shared` + `ensureCentral()`
        // (inside `reconnectKnownPeripheral`) creates the central; it then arms a pending
        // connect-by-identifier to the last ring (no scan — background scans without a service
        // filter are dropped). (#7)
        //
        // GATED (#142): only for a RETURNING user (any ring ever saved). A fresh install has nothing
        // to restore, and allocating the central here would fire the Bluetooth permission prompt at
        // launch — before onboarding says the prompt comes later. `hasSavedRingToRestore` reads
        // UserDefaults WITHOUT touching `.shared`, so the check itself creates no central. A saved
        // ring implies a restorable central, so a state-restoration relaunch is covered by this gate.
        if RingScanner.hasSavedRingToRestore {
            MainActor.assumeIsolated {
                RingScanner.shared.reconnectKnownPeripheral()
            }
        }
        // Bootstrap the BGTask chain AT LAUNCH (#119). Registration alone launches nothing — a
        // request must be SUBMITTED, and until build 17 the only initial submission point was
        // `applicationDidEnterBackground` below, which iOS never delivers to a scene-based
        // SwiftUI app (backgrounding goes to `scenePhase`; see OpenCircuitApp). Device-
        // confirmed consequence: no BGTask had EVER run — `obs.bgLastScheduled` was absent
        // after weeks of use. Submitting here also re-arms the chain after a force-quit or
        // reboot, both of which cancel every pending request.
        scheduler.schedule()
        scheduler.scheduleProcessing()
        ObservabilityStore().recordScheduled()
        return true
    }

    /// NOT delivered under the SwiftUI scene lifecycle — kept only as belt-and-braces against a
    /// future lifecycle change. The live submission points are `didFinishLaunching` above and
    /// OpenCircuitApp's `scenePhase == .background` handler. (#119)
    func applicationDidEnterBackground(_ application: UIApplication) {
        scheduler.schedule()
        scheduler.scheduleProcessing()
        ObservabilityStore().recordScheduled()
    }

    /// Run one bounded background sync for either BGTask variant. `kind`/`timeout` differ (short
    /// app-refresh vs. longer processing), but the body is shared: schedule the next runs, sync,
    /// record the outcome to the observability log, and fire any debounced silent-failure alerts
    /// (#44). Always re-submits BOTH requests so a granted run keeps the chain alive.
    private static func handle(_ task: BGTask, kind: TaskRecord.Kind, timeout: TimeInterval) {
        let scheduler = BackgroundRefreshScheduler()
        let observability = ObservabilityStore()
        scheduler.schedule()
        scheduler.scheduleProcessing()
        observability.recordScheduled()

        let operation = Task { @MainActor in
            do {
                let container = OpenCircuitApp.makeContainer()
                let service = RingBackgroundSyncService(
                    store: LocalStore(container.mainContext),
                    health: HealthKitWriter()
                )
                // Pass the per-task budget. The app-refresh path keeps the ~28 s budget so the
                // live-HR poll isn't starved by the history drain (#45 A); the processing path
                // gets the longer budget so the poll can actually lock. The expirationHandler
                // below still cancels cleanly if iOS grants a shorter window.
                let synced = try await service.syncVitals(timeout: timeout)
                guard !Task.isCancelled else { return }
                observability.recordSyncOutcome(kind: kind, success: synced,
                                                detail: synced ? "captured/flushed data" : "no data this run")
                await Self.evaluateAlerts()
                // Body-vital alerts (#73/#85) from the freshly-synced store — battery/session are
                // gone in the background, so this reads persisted samples only (session: nil).
                await HealthNotificationCenter().evaluate(store: LocalStore(container.mainContext),
                                                          session: nil)
                scheduler.schedule()
                scheduler.scheduleProcessing()
                task.setTaskCompleted(success: synced)
            } catch {
                guard !Task.isCancelled else { return }
                observability.recordSyncOutcome(kind: kind, success: false,
                                                detail: "error: \(error.localizedDescription)")
                await Self.evaluateAlerts()
                scheduler.schedule()
                scheduler.scheduleProcessing()
                task.setTaskCompleted(success: false)
            }
        }

        task.expirationHandler = {
            operation.cancel()
            observability.recordSyncOutcome(kind: kind, success: false, detail: "iOS ended the task early")
            scheduler.schedule()
            scheduler.scheduleProcessing()
            task.setTaskCompleted(success: false)
        }
    }

    /// Present locally-posted notifications as a banner+sound+list entry while the app is in the
    /// foreground (default iOS behavior is to suppress them). Health alerts and reminders are
    /// evaluated mostly in the foreground, so this is what makes them actually visible.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    /// Fire debounced local notifications for silent-failure conditions after a background run.
    /// Battery is nil here (the background session is already torn down), so low-battery is
    /// evaluated only in the foreground (ContentView) where a live reading exists — the staleness
    /// and Health-auth-lost conditions are the ones that matter when iOS isn't waking us. (#44)
    private static func evaluateAlerts() async {
        let healthAuthorized = await MainActor.run { HealthKitWriter().isShareAuthorized }
        await LocalAlertCenter().evaluate(batteryPercent: nil, healthAuthorized: healthAuthorized)
    }
}

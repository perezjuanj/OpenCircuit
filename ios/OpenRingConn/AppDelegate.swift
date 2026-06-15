import BackgroundTasks
import SwiftData
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    private let scheduler = BackgroundRefreshScheduler()

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        scheduler.register { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Self.handle(refreshTask)
        }

        // Re-instantiate the CBCentralManager (with its restore identifier) during launch so
        // iOS can deliver state restoration — including when it relaunches us in the
        // background because the ring came back in range. Touching `.shared` creates the
        // central; `reconnectKnownPeripheral` then arms a pending connect-by-identifier to the
        // last ring (no scan — background scans without a service filter are dropped). (#7)
        MainActor.assumeIsolated {
            RingScanner.shared.reconnectKnownPeripheral()
        }
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        scheduler.schedule()
    }

    private static func handle(_ task: BGAppRefreshTask) {
        let scheduler = BackgroundRefreshScheduler()
        scheduler.schedule()

        let operation = Task { @MainActor in
            do {
                let container = OpenRingConnApp.makeContainer()
                let service = RingBackgroundSyncService(
                    store: LocalStore(container.mainContext),
                    health: HealthKitWriter()
                )
                let synced = try await service.syncVitals(timeout: 20)
                guard !Task.isCancelled else { return }
                scheduler.schedule()
                task.setTaskCompleted(success: synced)
            } catch {
                guard !Task.isCancelled else { return }
                scheduler.schedule()
                task.setTaskCompleted(success: false)
            }
        }

        task.expirationHandler = {
            operation.cancel()
            scheduler.schedule()
            task.setTaskCompleted(success: false)
        }
    }
}

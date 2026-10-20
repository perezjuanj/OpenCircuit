import BackgroundTasks
import OpenCircuitKit
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
        // The Shortcuts actions' first-unlock check (#260, steer 4): created on a normal launch; before
        // the first unlock the add fails harmlessly and the next launch tries again.
        FirstUnlockSentinel().ensure()
        Self.registerNotificationCategories()
        let refreshRegistered = scheduler.register { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Self.handle(refreshTask, kind: .appRefresh,
                        timeout: RingBackgroundSyncService.defaultTimeout)
        }
        // BGProcessingTask: the longer-window sibling that finally gives the optical-HR poll room
        // to clear its ~60 s warm-up in the background (#45). Same sync path, larger time budget.
        let processingRegistered = scheduler.registerProcessing { task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Self.handle(processingTask, kind: .processing,
                        timeout: RingBackgroundSyncService.processingTimeout)
        }
        // Record whether iOS ACCEPTED our task-handler registrations (#bg-observability). A `false`
        // means the identifier isn't in `BGTaskSchedulerPermittedIdentifiers` (Info.plist) or we
        // registered too late — either way no background task of that kind can EVER run, and this is
        // the line in the Diagnostics export that would say so.
        ObservabilityStore().recordMetricEvent(
            source: "bgregister", detail: "refresh=\(refreshRegistered) processing=\(processingRegistered)")

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
        // #215: only the CHOSEN device's central is re-created. With the Helio Strap active the ring's
        // scanner is never constructed (decision 1); the strap's own central is re-created instead,
        // with its own restore identifier, so iOS can hand back its state; a restored or reconnected
        // strap syncs on connect, and the BGTask / Sleep Focus wakes drive it too (#215 phase 4).
        let helioActive = ActiveDeviceChoiceStore.persisted() == .helioStrap
        // Decision 33 (#233): a strap catch-up (woke-up event, reconnect, restoration, Health delivery)
        // runs the same alert passes as the strap's BGTask run. A static hook: setting it constructs
        // nothing, so a ring user's launch is unchanged.
        MainActor.assumeIsolated {
            // Review-236 S1: a strap sync that ends in the background (it started in front) runs the
            // same body-alert pass as these runs.
            HelioConnection.bodyAlertPass = { store in await Self.evaluateBodyAlerts(store: store) }
            HelioWakeCoordinator.afterRun = { run in
                // #233 item 5, review-225e SF-3: the flush's verdict on a held night, kept.
                if run.flushMS != nil { StrapNightRefresh.record(run.refreshAt, scheduler: BackgroundRefreshScheduler()) }
                // A coalesced run's alert passes are the other run's (#233 item 3).
                guard run.ending != .expired, !run.ending.isCoalesced else { return }
                await Self.evaluateAlerts()
                if run.ending == .synced, let store = try? OpenCircuitApp.backgroundStore() {
                    await Self.evaluateBodyAlerts(store: store)
                }
            }
        }
        // Decision 33 (#233): the iPhone's step count as a second wake, strap users who turned it on
        // only. The observer query is set up during launch, as HealthKit requires for its background
        // delivery; with the ring chosen, a delivery left on is turned off. A ring-only install has
        // neither key, so nothing is constructed.
        if helioActive || HelioHealthWake.wasEverUsed() {
            MainActor.assumeIsolated { _ = HelioHealthWake.shared.configureAtLaunch() }
        }
        if helioActive, HelioConnection.hasSavedStrap {
            MainActor.assumeIsolated {
                // A fallback-built container is published as `sharedContainer`, so later sites reuse
                // it; `container:` keeps it alive as long as the strap's store.
                if let container = try? OpenCircuitApp.sharedOrFallbackContainer() {
                    HelioConnection.shared.setLocalStore(LocalStore(container: container))
                }
                HelioConnection.shared.reconnectKnown()
            }
        }
        if !helioActive, RingScanner.hasSavedRingToRestore {
            MainActor.assumeIsolated {
                // Wire the process-wide store into the shared scanner BEFORE arming reconnect, so a
                // CoreBluetooth state-restoration relaunch (iOS waking us because the ring came back
                // in range — a wake source INDEPENDENT of any BGTask grant) has a store to persist
                // into. Without this, `willRestoreState`/`didConnect` build the RingSession with a nil
                // store, and the autonomous 0x11-heartbeat drain that follows ingests nothing, writes
                // no sleep summary, and flushes nothing to Health until the next FOREGROUND launch —
                // silently defeating openless sync on the primary all-day path (G1). Non-destructive
                // builder ONLY (never `makeContainer()`), so #131's no-background-wipe invariant holds;
                // if neither container resolves (pre-first-unlock Data Protection) the store stays nil
                // and behavior is exactly as before. `setLocalStore` is a reference assign that also
                // propagates to an existing session (no second drain), so one-writer is preserved.
                // A fallback-built container is published as `sharedContainer` (#222 review Q2), so
                // the BGTask handler, the Focus filter and the intents reuse it instead of opening a
                // second container over the same file; `container:` keeps it alive as long as the
                // scanner's store.
                if let container = try? OpenCircuitApp.sharedOrFallbackContainer() {
                    RingScanner.shared.setLocalStore(LocalStore(container: container))
                }
                RingScanner.shared.reconnectKnownPeripheral()
            }
        }
        // Decision 75b: the dashboard's off-main reads refresh on one coalesced store-change signal,
        // throttled while the active wearable syncs (foreground or background) and flushed when it
        // stops. After the wiring above, so a returning user's driver already exists; reading the
        // active session never touches the other device's driver (decision 1).
        MainActor.assumeIsolated {
            StoreRefreshSignal.shared.observeSaves()
            StoreRefreshSignal.shared.followSyncs()
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
        // Snapshot what iOS actually queued right after submitting (#bg-observability): if this shows
        // zero pending, the submit is silently failing; if it shows our two ids but no handler ever
        // runs, iOS just isn't granting. Async (getPendingTaskRequests) — lands in the metric log.
        scheduler.probePendingRequests()
        return true
    }

    /// Register the app's `UNNotificationCategory` set. Currently exactly one: the #183 morning
    /// overnight-signals verdict.
    ///
    /// ══ THE CATEGORY HAS NO ACTIONS, AND THAT IS DELIBERATE. DO NOT ADD ANY. ══
    ///
    /// The obvious "improvement" here is a pair of quick-reply buttons — "I have a headache" /
    /// "No headache" — or a one-tap log action. It would be a serious, irreversible mistake.
    ///
    /// Those buttons would appear ONLY on flagged mornings, because that is the only morning this
    /// notification fires. Label capture would then be CONDITIONED ON OUR OWN PREDICTION: we would
    /// collect ground truth disproportionately from the days we flagged, and every precision,
    /// recall and AUC number computed afterwards would be inflated by construction — including the
    /// ones the auto-retire quality monitor uses to decide whether this alert is helping the user
    /// at all. The bias is invisible in the data (a flagged-day label looks exactly like any other)
    /// and it is permanent: labels collected under a biased sampling scheme cannot be repaired
    /// afterwards, and this feature has exactly one source of ground truth.
    ///
    /// Logging therefore stays ONLY on paths that are NOT conditioned on the flag, all of which
    /// already exist and are always available: the Siri/App Intents (`HeadacheLogIntent`), the
    /// Control Centre control (`HeadacheLogControl`), the card's "Log a headache" button, and the
    /// daily morning-after prompt — which deliberately ignores the score for exactly this reason.
    ///
    /// `setNotificationCategories` REPLACES the whole set, and this is the only call site in the
    /// app (verified: no other `setNotificationCategories` / `UNNotificationCategory` exists), so a
    /// future second category must be added to this array rather than registered by a second call.
    private static func registerNotificationCategories() {
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: HeadacheSignsNotifications.categoryIdentifier,
                                   actions: [],              // ← intentionally empty; see above.
                                   intentIdentifiers: [],
                                   options: []),
        ])
    }

    /// NOT delivered under the SwiftUI scene lifecycle — kept only as belt-and-braces against a
    /// future lifecycle change. The live submission points are `didFinishLaunching` above and
    /// OpenCircuitApp's `scenePhase == .background` handler. (#119)
    func applicationDidEnterBackground(_ application: UIApplication) {
        scheduler.schedule()
        scheduler.scheduleProcessing()
        // Review-225e SF-3: a strap night's margin refresh survives this `schedule()` (no-op for the ring).
        StrapNightRefresh.resubmit(scheduler, strapChosen: ActiveDeviceChoiceStore.persisted() == .helioStrap)
        ObservabilityStore().recordScheduled()
    }

    /// Run one bounded background sync for either BGTask variant. `kind`/`timeout` differ (short
    /// app-refresh vs. longer processing), but the body is shared: schedule the next runs, sync,
    /// record the outcome to the observability log, and fire any debounced silent-failure alerts
    /// (#44). Always re-submits BOTH requests so a granted run keeps the chain alive.
    private static func handle(_ task: BGTask, kind: TaskRecord.Kind, timeout: TimeInterval) {
        let scheduler = BackgroundRefreshScheduler()
        let observability = ObservabilityStore()
        let completion = BackgroundTaskCompletion(task)
        // Breadcrumb the INSTANT iOS invokes us, before any async work — so "iOS never woke us" (no
        // such line) is distinguishable from "woke us but the drain didn't finish" (this line with no
        // matching sync outcome below). This is the single record that answers "does ANY background
        // task ever actually run?" — the whole question behind "every sync has been foreground".
        // (#bg-observability)
        observability.recordMetricEvent(source: "bgtask", detail: "\(kind.rawValue): handler INVOKED by iOS")
        scheduler.schedule()
        scheduler.scheduleProcessing()
        observability.recordScheduled()

        // #215 phase 4, decision 1: the chosen device's drain only, decided from UserDefaults before
        // either driver is touched. The strap's branch never constructs the ring's scanner; the ring's
        // (the rest of this function) never touches the strap's connection.
        if BackgroundDrain(ActiveDeviceChoiceStore.persisted()) == .strap {
            handleStrap(task, kind: kind, timeout: timeout)
            return
        }

        let operation = Task { @MainActor in
            do {
                // #131: NEVER build the container via the destructive `makeContainer()` here — its
                // wipe-and-recover fallback would silently delete un-resyncable raw sample/cursor
                // history on a transient open failure during a routine background wake, with no UI
                // to surface the reset. Reuse the process-wide container the foreground `App` built
                // at launch (it is populated before iOS invokes this handler on a later run-loop
                // turn — see OpenCircuitApp.sharedContainer). In the rare case it isn't built yet,
                // fall back to the NON-destructive `makeContainerOrThrow()`, whose throw is caught
                // below → the run aborts, the scheduler chain stays armed, and the next wake retries;
                // the store is never touched. A fallback-built container is published for the next
                // site, and the stores below keep it alive (`container:`, #222 review U2).
                let container = try OpenCircuitApp.sharedOrFallbackContainer()
                // #215: the ring's background drain runs only while the ring is the chosen device; it
                // is what constructs the ring's scanner and central. The strap's wake took the branch
                // above; this catches a switch to the strap between that check and this task running.
                guard ActiveDeviceChoiceStore.persisted() == .ringConn else {
                    observability.recordSyncOutcome(kind: kind, success: false,
                                                    detail: "device switched to the Helio Strap; ring drain skipped")
                    await Self.evaluateAlerts()
                    scheduler.schedule()
                    scheduler.scheduleProcessing()
                    completion.complete(success: false)
                    return
                }
                let service = RingBackgroundSyncService(
                    store: LocalStore(container: container),
                    health: HealthKitWriter()
                )
                // Pass the per-task budget. The app-refresh path keeps the ~28 s budget so the
                // live-HR poll isn't starved by the history drain (#45 A); the processing path
                // gets the longer budget so the poll can actually lock. The expirationHandler
                // below still cancels cleanly if iOS grants a shorter window.
                // Skip the opportunistic live-HR poll on the SHORT app-refresh window so the run
                // completes and flushes to Health cleanly instead of being cut mid-poll ("iOS ended
                // the task early"); the longer processing window keeps the poll — it can lock. (#daytime-bg-drain)
                let synced = try await service.syncVitals(timeout: timeout, allowLivePoll: kind == .processing)
                guard !Task.isCancelled else { return }
                observability.recordSyncOutcome(kind: kind, success: synced,
                                                detail: synced ? "captured/flushed data" : "no data this run")
                await Self.evaluateAlerts()
                // Body-vital alerts (#73/#85) from the freshly-synced store — battery/session are
                // gone in the background, so this reads persisted samples only (session: nil).
                //
                // #183: the overnight-signals row for today is frozen IMMEDIATELY BEFORE that alert
                // pass, so a background drain alone can produce the morning verdict — no foreground
                // open required — and the alert pass reads the fresh row. The engine's expensive
                // input (the resting-HR daily series) is fetched only when the user has opted in and
                // is then shared with the fever cross-check inside `evaluate`, so a background wake
                // never pays for that scan twice; opted out, this costs one UserDefaults read and
                // the pass is exactly as it was before #183.
                let alertStore = LocalStore(container: container)
                let alerts = HealthNotificationCenter()
                let restingHRDaily = UserDefaults.standard.bool(forKey: HeadacheDefaults.enabled)
                    ? await alerts.restingHRDailySeries(store: alertStore) : nil
                if let restingHRDaily {
                    await HeadacheEngine().refreshToday(store: alertStore, restingHR: restingHRDaily)
                }
                await alerts.evaluate(store: alertStore, session: nil,
                                      restingHRDaily: restingHRDaily)
                scheduler.schedule()
                scheduler.scheduleProcessing()
                completion.complete(success: synced)
            } catch {
                guard !Task.isCancelled else { return }
                observability.recordSyncOutcome(kind: kind, success: false,
                                                detail: "error: \(error.localizedDescription)")
                await Self.evaluateAlerts()
                scheduler.schedule()
                scheduler.scheduleProcessing()
                completion.complete(success: false)
            }
        }

        task.expirationHandler = {
            // Like the strap's: the cancelled capture still needs a main-actor turn to tear its session
            // down and re-arm the standing connect (`captureForBackground`'s defer). Completing the task
            // in this handler let iOS suspend the app before that ran, stranding a half-drained link.
            operation.cancel()
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(Self.ringExpiryGrace))
                guard completion.complete(success: false) else { return }
                observability.recordSyncOutcome(kind: kind, success: false, detail: "iOS ended the task early")
                scheduler.schedule()
                scheduler.scheduleProcessing()
            }
        }
    }

    /// How long after iOS expires a ring run the task is completed anyway: room for the cancelled
    /// capture's teardown and standing-connect re-arm, which run on the next main-actor turns.
    private static let ringExpiryGrace: TimeInterval = 2

    /// How long after iOS expires a strap run the task is completed anyway, if the run hasn't done it
    /// (a Health save still in flight). The run's own teardown needs about `teardownGrace`.
    private static let strapExpiryGrace: TimeInterval = 2

    /// The Helio Strap's BGTask run (#215 phase 4): `HelioBackgroundSyncService` (connect, auth with
    /// the Keychain key, clock, fetch acked `03 09`, commit, Health flush, one "helio strap:" line in
    /// the run log), then the same alert passes as the ring's run. The task is completed only after
    /// the run has flushed, or has abandoned the sync (open round acked `03 09`, link dropped) because
    /// iOS expired it; never before.
    private static func handleStrap(_ task: BGTask, kind: TaskRecord.Kind, timeout: TimeInterval) {
        let scheduler = BackgroundRefreshScheduler()
        let observability = ObservabilityStore()
        let completion = BackgroundTaskCompletion(task)
        // Review-225e SF-3: `handle` just called `schedule()`; a pending strap margin refresh stays.
        StrapNightRefresh.resubmit(scheduler, strapChosen: true)

        let operation = Task { @MainActor in
            do {
                // #131: never the destructive `makeContainer()`; the store keeps a fallback-built
                // container alive, and the container is published for the next site.
                let store = try OpenCircuitApp.backgroundStore()
                let run = await HelioBackgroundSyncService.live(store: store).run(kind: kind, timeout: timeout)
                // A coalesced task's alert passes are the run holding the strap's (#233 item 3).
                if run.ending != .expired, !run.ending.isCoalesced {
                    await Self.evaluateAlerts()
                    if run.ending == .synced { await Self.evaluateBodyAlerts(store: store) }
                }
                scheduler.schedule()
                scheduler.scheduleProcessing()
                // #233 item 5: a night the flush held back gets its own refresh at the margin's end, and
                // review-225e SF-3: one still pending survives the `schedule()` above.
                if run.flushMS != nil { StrapNightRefresh.record(run.refreshAt, scheduler: scheduler) }
                StrapNightRefresh.resubmit(scheduler, strapChosen: true)
                completion.complete(success: run.success)
            } catch {
                observability.recordSyncOutcome(kind: kind, success: false,
                                                detail: "helio strap: error: \(error.localizedDescription)")
                await Self.evaluateAlerts()
                scheduler.schedule()
                scheduler.scheduleProcessing()
                StrapNightRefresh.resubmit(scheduler, strapChosen: true)
                completion.complete(success: false)
            }
        }

        task.expirationHandler = {
            // The cancelled run acks an open round `03 09`, drops the link, logs why, then completes the
            // task (above). Only if it hasn't within the grace is the task completed here.
            operation.cancel()
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(Self.strapExpiryGrace))
                guard completion.complete(success: false) else { return }
                observability.recordSyncOutcome(kind: kind, success: false, detail: "helio strap: iOS ended the task early")
                scheduler.schedule()
                scheduler.scheduleProcessing()
                StrapNightRefresh.resubmit(scheduler, strapChosen: true)
            }
        }
    }

    /// The ring run's post-sync alert passes (#73/#85, #183), for the strap's store: freeze today's
    /// overnight-signals row (opted-in only), then the body-vital alerts from persisted samples.
    /// Internal, not private, so `BackgroundAlertOffMainTests` can drive this exact pass (#305).
    @MainActor
    static func evaluateBodyAlerts(store: LocalStore) async {
        let alerts = HealthNotificationCenter()
        let restingHRDaily = UserDefaults.standard.bool(forKey: HeadacheDefaults.enabled)
            ? await alerts.restingHRDailySeries(store: store) : nil
        if let restingHRDaily {
            await HeadacheEngine().refreshToday(store: store, restingHR: restingHRDaily)
        }
        await alerts.evaluate(store: store, session: nil, restingHRDaily: restingHRDaily)
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

/// Completes a BGTask exactly once: whichever of the run and the expiry grace gets there first.
@MainActor
final class BackgroundTaskCompletion {
    private let task: BGTask
    private(set) var isDone = false

    init(_ task: BGTask) { self.task = task }

    /// false when the task was already completed.
    @discardableResult
    func complete(success: Bool) -> Bool {
        guard !isDone else { return false }
        isDone = true
        task.setTaskCompleted(success: success)
        return true
    }
}

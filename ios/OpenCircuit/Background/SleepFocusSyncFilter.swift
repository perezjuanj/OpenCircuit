import AppIntents
import Foundation

/// Opt-in Focus Filter shown by iOS under Settings > Focus > Sleep > Add Filter.
///
/// Focus Filters don't expose the name of the Focus that owns them, so the user attaches this
/// filter specifically to Sleep Focus. iOS delivers the suggested `true` value while that Focus is
/// active, then calls `perform()` again with the parameter's default (`false`) when the Focus ends.
/// Only that falling edge starts a sync; enabling Sleep Focus leaves every existing sync path alone.
struct SleepFocusSyncFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Sync after Sleep Focus"
    static let description = IntentDescription(
        "Sync your device when the Sleep Focus this filter belongs to turns off."
    )
    // iOS 26 replaced `openAppWhenRun` with explicit execution modes. This intent must launch the
    // containing app into a BACKGROUND process: its work depends on the app-owned CoreBluetooth
    // restoration manager, SwiftData container, and HealthKit writer. Leaving the mode implicit made
    // iOS 27 advertise the filter in Settings but never invoke `perform()` while OpenCircuit was
    // suspended (device log: neither the enabled nor disabled breadcrumb ever appeared).
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    // Compatibility for iOS 17...25. On iOS 26+ `supportedModes` above is authoritative.
    static let openAppWhenRun = false

    /// The default MUST remain false. iOS supplies parameter defaults when a Focus turns off; the
    /// suggested configured filter below supplies true while Sleep Focus is active.
    @Parameter(title: "Sync when this Focus ends", default: false)
    var focusIsActive: Bool

    init() {}

    private init(focusIsActive: Bool) {
        self.focusIsActive = focusIsActive
    }

    static func suggestedFocusFilters(for context: FocusFilterSuggestionContext) async -> [Self] {
        [Self(focusIsActive: true)]
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "Sync when Focus ends",
            subtitle: focusIsActive ? "Enabled" : "Inactive"
        )
    }

    func perform() async throws -> some IntentResult {
        guard Self.shouldSync(focusIsActive: focusIsActive) else {
            ObservabilityStore().recordMetricEvent(
                source: "focus", detail: "Sleep Focus enabled; wake sync armed")
            return .result()
        }

        await SleepFocusSyncRunner.run()
        return .result()
    }

    /// Pure seam that locks the edge semantics in a unit test: configured/active means arm only;
    /// the default/off delivery is the single state that starts a sync.
    nonisolated static func shouldSync(focusIsActive: Bool) -> Bool {
        !focusIsActive
    }
}

/// Runs the same bounded capture + HealthKit flush used by the short BGAppRefresh path, but is
/// entered by the Sleep Focus Filter instead of BGTaskScheduler. Kept in the app target so it can
/// reuse the app's process-wide SwiftData container, saved ring, and CoreBluetooth restoration
/// state without moving any existing persistence into a different container.
@MainActor
private enum SleepFocusSyncRunner {
    static func run() async {
        let observability = ObservabilityStore()
        let scheduler = BackgroundRefreshScheduler()

        observability.recordMetricEvent(
            source: "focus", detail: "Sleep Focus ended; sync INVOKED by iOS")
        // Decision 78a (#332): T, the moment Sleep Focus ended, outlives this one bounded run. Recorded
        // for both devices; only the strap's flushes read it.
        let focusEnd = Date()
        SleepFocusFinalization.persist(focusEnd)

        // The Focus-triggered run is additive. Keep both existing BGTask chains armed exactly as a
        // normal background run does; this does not cancel or replace either pending request.
        scheduler.schedule()
        scheduler.scheduleProcessing()
        observability.recordScheduled()

        do {
            // Background work must never reach makeContainer()'s destructive recovery path. This
            // mirrors AppDelegate's BGTask invariant: reuse the launch container or attempt the
            // non-destructive builder and retry on a later trigger if protected data is unavailable.
            // A fallback-built container is published for the next site, and `container:` keeps it
            // alive for as long as the store (#222 review Q2 + U2).
            let container = try OpenCircuitApp.sharedOrFallbackContainer()
            let store = LocalStore(container: container)
            // #215 phase 4, decision 1: the chosen device's drain only. With the Helio Strap chosen the
            // ring's scanner is never constructed; the strap's drain runs instead.
            if BackgroundDrain(ActiveDeviceChoiceStore.persisted()) == .strap {
                await runStrap(store: store, focusEnd: focusEnd)
                return
            }
            let service = RingBackgroundSyncService(store: store, health: HealthKitWriter())

            // Sleep Focus ending is a short system wake, so use the same bounded, no-live-poll mode
            // as BGAppRefresh. The history drain and Health flush complete without spending the
            // remaining window waiting for an optical HR lock.
            //
            // `forceHistoryDrain: true` — Focus ending is the authoritative "sleep is over" wake, the
            // exact moment the overnight-quiet policy defers the whole-night drain TO. So this drains
            // ring→app in ONE pass even when the learned sleep window still overlaps 09:00 (a non-manual
            // drain would be SKIPPED by that gate, which is why a just-ended night failed to reach Health
            // until the user opened the app). `sleepFinalized: true` then writes the drained night to
            // Apple Health immediately, bypassing the 20-min settle margin — so Focus-off delivers the
            // full ring→app→Health chain.
            let synced = try await service.syncVitals(
                timeout: RingBackgroundSyncService.defaultTimeout,
                allowLivePoll: false,
                sleepFinalized: true,
                forceHistoryDrain: true
            )
            guard !Task.isCancelled else { return }

            observability.recordSyncOutcome(
                kind: .sleepFocus,
                success: synced,
                detail: synced ? "captured/flushed data" : "no data this run"
            )
            await evaluateAlerts()
            // #183: Focus-off is the authoritative "the night is over" wake and the earliest moment
            // the night is settled, so freeze today's overnight-signals row here, immediately before
            // the alert pass reads it. Idempotent — a later BGTask or wake-drain that reaches the
            // same day is a no-op. The resting-HR daily series is fetched only for an opted-in user
            // and is then shared with the fever cross-check inside `evaluate` rather than scanned
            // twice; opted out, this short system wake costs exactly what it did before #183.
            let alerts = HealthNotificationCenter()
            let restingHRDaily = UserDefaults.standard.bool(forKey: HeadacheDefaults.enabled)
                ? await alerts.restingHRDailySeries(store: store) : nil
            if let restingHRDaily {
                await HeadacheEngine().refreshToday(store: store, restingHR: restingHRDaily)
            }
            await alerts.evaluate(store: store, session: nil, restingHRDaily: restingHRDaily)

            scheduler.schedule()
            scheduler.scheduleProcessing()
        } catch {
            guard !Task.isCancelled else { return }
            observability.recordSyncOutcome(
                kind: .sleepFocus,
                success: false,
                detail: "error: \(error.localizedDescription)"
            )
            await evaluateAlerts()
            scheduler.schedule()
            scheduler.scheduleProcessing()
        }
    }

    /// The Helio Strap's Focus-off run (#215 phase 4): the same bounded, short window as the ring's.
    /// Focus ending is the authoritative "the night is over" signal, so the strap's nights skip the
    /// 20-minute quiet margin, exactly as the ring's do on this wake (`sleepFinalized`). The run logs
    /// itself ("helio strap: …", kind `sleepFocus`); the alert passes follow a finished sync.
    private static func runStrap(store: LocalStore, focusEnd: Date) async {
        let scheduler = BackgroundRefreshScheduler()
        // T, the moment Sleep Focus ended: in memory its nights skip the margin within 30 min of it
        // (decision 31); persisted, a later flush within 6 h finalizes the nights that ended by then
        // (decision 78a).
        let run = await HelioBackgroundSyncService.live(store: store).run(
            kind: .sleepFocus, timeout: RingBackgroundSyncService.defaultTimeout, nightsFinalized: focusEnd)
        // The night as the store has it after the run's flush (or with none).
        let night = HelioConnection.savedTimeline.map { store.strapFocusNight(timeline: $0, focusEnd: focusEnd) } ?? .none
        guard !Task.isCancelled else {
            // Decision 78b/78c: an expired run still asks for its retry and leaves its line.
            SleepFocusStrapFollowUp.finish(run, focusEnd: focusEnd, night: night, expired: true,
                                           scheduler: scheduler, observability: ObservabilityStore())
            return
        }
        await evaluateAlerts()
        if run.ending == .synced {
            let alerts = HealthNotificationCenter()
            let restingHRDaily = UserDefaults.standard.bool(forKey: HeadacheDefaults.enabled)
                ? await alerts.restingHRDailySeries(store: store) : nil
            if let restingHRDaily {
                await HeadacheEngine().refreshToday(store: store, restingHR: restingHRDaily)
            }
            await alerts.evaluate(store: store, session: nil, restingHRDaily: restingHRDaily)
        }
        scheduler.schedule()
        scheduler.scheduleProcessing()
        // #233 item 5: a night this flush held back, and review-225e SF-3: one still pending survives
        // the `schedule()` above. Decision 78b: a night not in Apple Health gets a retry at T + 15 min.
        SleepFocusStrapFollowUp.finish(run, focusEnd: focusEnd, night: night, expired: false,
                                       scheduler: scheduler, observability: ObservabilityStore())
    }

    private static func evaluateAlerts() async {
        let healthAuthorized = HealthKitWriter().isShareAuthorized
        await LocalAlertCenter().evaluate(batteryPercent: nil, healthAuthorized: healthAuthorized)
    }
}

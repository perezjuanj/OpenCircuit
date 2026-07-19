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
        "Sync your ring when the Sleep Focus this filter belongs to turns off."
    )
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

        // The Focus-triggered run is additive. Keep both existing BGTask chains armed exactly as a
        // normal background run does; this does not cancel or replace either pending request.
        scheduler.schedule()
        scheduler.scheduleProcessing()
        observability.recordScheduled()

        do {
            // Background work must never reach makeContainer()'s destructive recovery path. This
            // mirrors AppDelegate's BGTask invariant: reuse the launch container or attempt the
            // non-destructive builder and retry on a later trigger if protected data is unavailable.
            let container = try OpenCircuitApp.sharedContainer ?? OpenCircuitApp.makeContainerOrThrow()
            let store = LocalStore(container.mainContext)
            let service = RingBackgroundSyncService(store: store, health: HealthKitWriter())

            // Sleep Focus ending is a short system wake, so use the same bounded, no-live-poll mode
            // as BGAppRefresh. The history drain and Health flush complete without spending the
            // remaining window waiting for an optical HR lock.
            let synced = try await service.syncVitals(
                timeout: RingBackgroundSyncService.defaultTimeout,
                allowLivePoll: false
            )
            guard !Task.isCancelled else { return }

            observability.recordSyncOutcome(
                kind: .sleepFocus,
                success: synced,
                detail: synced ? "captured/flushed data" : "no data this run"
            )
            await evaluateAlerts()
            await HealthNotificationCenter().evaluate(store: store, session: nil)

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

    private static func evaluateAlerts() async {
        let healthAuthorized = HealthKitWriter().isShareAuthorized
        await LocalAlertCenter().evaluate(batteryPercent: nil, healthAuthorized: healthAuthorized)
    }
}

import Foundation
import HealthKit
import OpenCircuitKit

// Writes ring metrics into Apple Health. Type/unit choices follow
// docs/HEALTHKIT_MAPPING.md. Samples are saved with the device's own timestamps
// so history backfills; a stable bundle id + the SyncCursor avoid duplicates.

/// Latch for the one-shot Apple Health republish of nights edited under build 47's withholding rule
/// (`HealthKitWriter.republishPreUpgradeEditedNights`). Registered rather than read bare, matching
/// `HealthAlertDefaults` / `HeadacheDefaults` / `SleepScheduleDefaults`, and registered AT THE READ
/// SITE for the same reason they are: there is no single launch path every entry point goes through
/// (a BGTask or CoreBluetooth-restoration launch never connects a scene).
///
/// ⚠️ THE VERSION SUFFIX IS THE ONLY WAY TO RUN THIS AGAIN. Bump it if — and only if — a later build
/// changes what an edited night is entitled to publish, the way build 48 changed it. Reusing `v1`
/// would leave every existing install latched and the new rule unapplied to their history.
enum SleepHealthRepublishDefaults {
    static let doneKey = "health.republishedEditedNightSleep.v1"

    static func register(_ defaults: UserDefaults = .standard) {
        defaults.register(defaults: [doneKey: false])
    }
}

@MainActor
final class HealthKitWriter {
    private let store = HKHealthStore()
    private static let systolicType = HKQuantityType(.bloodPressureSystolic)
    private static let diastolicType = HKQuantityType(.bloodPressureDiastolic)
    private static let bloodPressureType = HKCorrelationType.correlationType(forIdentifier: .bloodPressure)!
    /// Reentrancy guard for `flushToHealth`: the method suspends on each HealthKit `save`,
    /// and it's triggered from several UI/lifecycle points — without this, two overlapping
    /// flushes could both read the same pending set before either advanced its watermark and
    /// double-write to Health. STATIC so it serializes across the separate foreground and
    /// background-task `HealthKitWriter` instances too (both run on the MainActor, which reads/
    /// writes this synchronously around the awaits — they share one underlying SQLite store).
    private static var isFlushing = false

    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    /// HKQuantityType for a scalar metric, or nil for non-quantity kinds (sleep).
    static func quantityType(for kind: MetricKind) -> HKQuantityType? {
        let id: HKQuantityTypeIdentifier
        switch kind {
        case .heartRate: id = .heartRate
        case .restingHeartRate: id = .restingHeartRate
        case .hrvSDNN: id = .heartRateVariabilitySDNN
        case .spo2: id = .oxygenSaturation
        // Skin temp is captured ONLY during the nightly sleep window (RingSession). The ideal
        // sleeping-wrist type (`.appleSleepingWristTemperature`) is Apple-COMPUTED and read-only
        // for third parties: it can't be save()d, and putting it in the `toShare` set of
        // `requestAuthorization` raises NSInvalidArgumentException, which would crash auth or —
        // swallowed by the call-site `try?` — silently disable EVERY metric's writeback. We
        // previously used `.basalBodyTemperature`, but Apple Health hard-wires that type to
        // Cycle Tracking's basal body temperature (BBT) chart, which is a specific fertility
        // signal — polluting it with nightly skin readings misreports BBT. Writing to the
        // general `.bodyTemperature` keeps the data in Health without entangling it with the
        // menstrual-cycle chart. Units stay °C (see `unit(for:)`).
        case .temperature: id = .bodyTemperature
        case .respiratoryRate: id = .respiratoryRate
        case .steps: id = .stepCount
        case .activeEnergy: id = .activeEnergyBurned
        case .sleep: return nil
        // ESTIMATE — steps × RingConn's own per-step constant. See DistanceEstimate.swift (#81).
        case .distance: id = .distanceWalkingRunning
        // Apple Exercise Time is an Apple-COMPUTED Activity-ring metric — NOT third-party
        // shareable or writable. Listing it in `requestAuthorization(toShare:)` raises an Obj-C
        // NSInvalidArgumentException (-[HKHealthStore _throwIfAuthorizationDisallowedForSharing:])
        // that crashed the app on first Health auth (TestFlight #110), and `save()` of it errors.
        // Apps contribute exercise time only via HKWorkout (the #93 path), so there is no writable
        // quantity type for it — return nil so it is excluded from BOTH the auth set and writes.
        case .exerciseMinutes: return nil
        }
        return HKQuantityType(id)
    }

    /// HKUnit matching MetricKind.unit (the canonical units in OpenCircuitKit).
    static func unit(for kind: MetricKind) -> HKUnit {
        switch kind {
        case .heartRate, .restingHeartRate, .respiratoryRate:
            return HKUnit.count().unitDivided(by: .minute())
        case .hrvSDNN: return .secondUnit(with: .milli)
        case .spo2: return .percent()                 // value is a 0…1 fraction
        case .temperature: return .degreeCelsius()
        case .steps: return .count()
        case .activeEnergy: return .kilocalorie()
        case .sleep: return .count()                  // unused
        case .distance: return .meter()              // ESTIMATE — steps × RingConn's per-step constant
        case .exerciseMinutes: return .minute()      // ESTIMATE — elevated HR minutes
        }
    }

    // Internal (not private) so HealthKitShareTypesTests can guard the set's contents.
    var allTypes: Set<HKSampleType> {
        var set = Set<HKSampleType>()
        for k in MetricKind.allCases {
            if let t = Self.quantityType(for: k) { set.insert(t) }
        }
        set.insert(HKQuantityType(.basalEnergyBurned))
        set.insert(HKCategoryType(.sleepAnalysis))
        // Workout types (#75): HKWorkout + GPS route (workout sessions feature).
        set.insert(HKWorkoutType.workoutType())
        set.insert(HKSeriesType.workoutRoute())
        // Cycling distance is written for cycling workouts (foot-based sports use the
        // .distanceWalkingRunning type already covered by MetricKind.distance above).
        set.insert(HKQuantityType(.distanceCycling))
        // Women's health (#78): user-logged period flow written to Health.
        // NOTE: temperature is NOT added here — it already ships via the canonical
        // `.bodyTemperature` path (MetricKind.temperature). No triple-write.
        set.insert(HKCategoryType(.menstrualFlow))
        // Headache log (headache signals, Phase 1): the user's OWN logged headaches, mirrored as
        // `HKCategoryValueSeverity`. Safe to authorize because `.headache` is an ordinary
        // third-party-WRITABLE CATEGORY type — the same class as `.menstrualFlow` directly above —
        // and NOT the Apple-computed / HKCorrelationType class whose presence in the auth set raised
        // the uncatchable NSInvalidArgumentException of #121 (fixed in #128) and the #110 crash.
        // That type distinction, not any try/catch, is the entire reason the crash cannot recur here.
        set.insert(HKCategoryType(.headache))
        // Blood pressure (#121): authorization is granted on the two CONSTITUENT quantity
        // types only. The `bloodPressureType` HKCorrelationType must NEVER be added here:
        // correlation types are not authorizable, and their presence in the `toShare` set of
        // `requestAuthorization`/`statusForAuthorizationRequest` raises an uncatchable Obj-C
        // NSInvalidArgumentException — which crashed the app whenever the auth path ran, e.g.
        // right after the user revoked Health access in the Health app (the #119 auth-recovery
        // path re-requests). Saving the HKCorrelation itself needs no correlation-level grant;
        // it is authorized through systolic + diastolic.
        set.insert(Self.systolicType)
        set.insert(Self.diastolicType)
        return set
    }

    /// The READ half of the app's ONE HealthKit authorization request. `allTypes` is the SHARE half.
    ///
    /// ⚠️ ONE REQUEST, ALWAYS — this is a scar, not a preference. Build 50 added a SECOND request in
    /// `WorkoutHistoryReader` (`requestAuthorization(toShare: [], read: [HKObjectType.workoutType()])`)
    /// so the Activity tab could read workouts back, while THIS request kept naming the same workout
    /// type in `toShare` only. On device that produced a loop the user could never settle
    /// (maintainer, build 50): fresh launch prompts for Workouts + Workout Routes WRITE → Allow →
    /// Health ▸ Data Access shows both granted → open the Activity tab → the read prompt appears →
    /// the write grant is gone → next fresh launch prompts for write again, forever.
    ///
    /// WHAT IS ESTABLISHED, and at what confidence:
    ///   • 🟢 The loop itself — reported first-hand off a build-50 device, reproduced every launch.
    ///   • 🟢 The wiped share status is `.notDetermined`, not `.sharingDenied`. DEDUCED, not
    ///     measured: the relaunch prompt is `ContentView.reconcileNewlyAuthorizableShareTypes()`,
    ///     which fires only on `.shouldRequest`, and `.sharingDenied` is a choice the user HAS made
    ///     — Apple's header defines the status probe as "whether the user would be PROMPTED", and a
    ///     request over fully-answered types "will be called without prompting the user"
    ///     (HKHealthStore.h). A denied type would therefore have reported `.unnecessary` and no
    ///     sheet would have appeared. This is why the heal in `reconcileNewlyAuthorizableShareTypes`
    ///     can reach these users at all.
    ///   • 🟢 The wipe was SCOPED, not wholesale — on the same deduction, since that reconcile runs
    ///     only inside `if healthAuthorized` (`isShareAuthorized`, probed on HEART RATE). Heart-rate
    ///     share was therefore still granted while the workout rows were being re-asked for. (It
    ///     rests on the sheet being UNPROMPTED at launch, which is how it was reported; a sheet the
    ///     user summoned with the Connect button would not carry this.)
    ///   • 🟡 Its exact scope is NOT explained by any evidence we have. Build 50's second request
    ///     named `HKObjectType.workoutType()` and nothing else, yet Workout ROUTES — a type that
    ///     request never mentioned — lost its write grant too. So "the named type's share bit is
    ///     re-derived from the new (empty) `toShare`" is too narrow to fit, and "the app's whole
    ///     request record is replaced" is too wide to fit. Do not write either down as the cause.
    ///   • 🟡 WHY HealthKit clears it: NOT documented by Apple and NOT claimed here. The header
    ///     documents only that a repeat request over already-answered types completes silently; it
    ///     says nothing about a request RESETTING one. Two corroborating third-party reports,
    ///     neither authoritative: an unanswered 2022 Apple Developer Forums post describing this
    ///     exact operation on this exact type — "when I do a second call for the same type but with
    ///     a different permission, HealthKit is going to delete my previous permission for that
    ///     type" (forums.developer.apple.com/forums/thread/707078) — and a DTS-answered thread where
    ///     adding READ for `workoutType`/`workoutRoute` after WRITE was already granted left the
    ///     Health Data Access rows wrong, which the DTS engineer called "a HealthKit bug … I don't
    ///     see anything you can do from the app side to work around the issue" (thread/765556).
    ///     The fix does not depend on the mechanism: with one request, no type ever carries two
    ///     disagreeing `toShare` memberships in the first place.
    ///
    /// WHY WORKOUTS ARE NOT IN THIS SET, even though the Activity tab reads workouts back.
    /// Apple, on `HKHealthStore.authorizationStatus(for:)`: "If your app is given share permission
    /// but not read permission, you see only the data that your app has written to the store. Data
    /// from other sources remains hidden." `WorkoutHistoryReader.recentWorkouts` queries with
    /// `HKQuery.predicateForObjects(from: .default())` — OUR OWN source only, deliberately and
    /// permanently (see that file's header) — so the workout SHARE grant this app has held since
    /// #75 already covers it. Build 50's read request bought nothing; it only cost the write grant.
    /// Asking for workout READ is also not free: it would put a fresh HealthKit sheet in front of
    /// EVERY existing install on upgrade, and it is the exact operation of thread/765556 above.
    /// If a card ever needs OTHER apps' workouts, that is when to add the read — and it is added
    /// HERE, to this one set, never in a request of its own.
    ///
    /// `HKSeriesType` — the GPS workout route — is excluded for that reason and one more: nothing
    /// reads a route back at all. `WorkoutSessionManager` inserts routes
    /// (`HKWorkoutRouteBuilder.insertRouteData`) and no query in this app names the type.
    ///
    /// BOTH `requestAuthorization()` AND `authorizationPromptAvailable()` MUST PASS THIS SET. Apple
    /// documents `getRequestStatusForAuthorizationToShareTypes:readTypes:` as reporting whether the
    /// user would be prompted "if the same collections of types are passed to
    /// requestAuthorizationToShareTypes:readTypes:" (HKHealthStore.h). A probe over a narrower read
    /// set answers a different question than the request it guards — and the #129 upgrade re-prompt
    /// is built entirely on that probe, so a drift there is what silently strands a new type.
    ///
    /// Aligning the probe to this set prompts NOBODY new, and that follows from the derivation, not
    /// from optimism: this set is `allTypes` minus the two workout types, so it can only be stale for
    /// a user whose SHARE half is stale too — and that user's probe already reported `.shouldRequest`
    /// off the share half alone. The derivation has held since `97a7803`, and the one `allTypes`
    /// growth since (`.headache`, `7deb02f`) went out through this same single request.
    var authorizationReadTypes: Set<HKObjectType> {
        // Read sleepAnalysis so the iOS Sleep-schedule window (HealthKitSleepSchedule) works the
        // moment the HealthKit entitlement is enabled — no further auth change needed.
        var read: Set<HKObjectType> = [HKCategoryType(.sleepAnalysis)]
        for type in allTypes {
            // Workouts and the GPS route series stay WRITE-ONLY, and NOT for safety — both are plain
            // `HKSampleType`s (HealthKit/HKObjectType.h) and both are readable. They are excluded
            // because share permission already covers reading back our OWN samples, which is all
            // this app ever reads. See the note above for Apple's wording and the cost of asking.
            if type is HKWorkoutType || type is HKSeriesType { continue }
            read.insert(type)
        }
        return read
    }

    /// True once the user has granted share access (probed on heart rate as a representative
    /// type). Lets the app auto-flush to Health without a button tap, while staying silent
    /// when access was never granted. (HealthKit hides READ status for privacy, but SHARE
    /// status is reportable.)
    var isShareAuthorized: Bool {
        Self.isAvailable
            && store.authorizationStatus(for: HKQuantityType(.heartRate)) == .sharingAuthorized
    }

    /// True when SLEEP specifically is being written to Apple Health right now.
    ///
    /// Deliberately NOT `isShareAuthorized`, which probes HEART RATE as a representative type: the
    /// partial-grant case (#132) is real — heart rate on, sleep off in Settings ▸ Health ▸ Data
    /// Access — and in that state the app writes no sleep at all. The Sleep card's edited-night
    /// notice tells the wearer what Apple Health holds for that night, so it must key on the type it
    /// is talking about, not on a proxy.
    var isSleepShareAuthorized: Bool {
        Self.isAvailable
            && store.authorizationStatus(for: HKCategoryType(.sleepAnalysis)) == .sharingAuthorized
    }

    /// The shareable, AUTHORIZABLE types the user has explicitly DENIED (turned off in the iOS
    /// permission sheet or later in Settings ▸ Health ▸ Data Access). SHARE status is reportable
    /// per-type (unlike READ status), so this is a trustworthy signal. `allTypes` already excludes
    /// the non-authorizable `bloodPressureType` HKCorrelationType (querying it throws an uncatchable
    /// Obj-C exception), so this never touches it. Includes `.sleepAnalysis` and `.menstrualFlow`.
    func deniedShareTypes() -> [HKSampleType] {
        guard Self.isAvailable else { return [] }
        return allTypes.filter { store.authorizationStatus(for: $0) == .sharingDenied }
    }

    /// Tri-state Health share status so the UI can tell "never granted" from "some granted, some
    /// denied" — the partial case is the trap #132 fixes: `isShareAuthorized` (heart rate) is `true`
    /// yet other metrics silently never reach Health. `isShareAuthorized` stays as-is so the flush
    /// keeps writing the metrics that ARE granted; this only drives the honest status copy.
    enum ShareState: Equatable {
        case unauthorized
        case partial([HKSampleType])   // HR granted, but these types are denied
        case authorized
    }

    var shareState: ShareState {
        guard Self.isAvailable else { return .unauthorized }
        return Self.resolveShareState(authorizableTypes: allTypes) {
            store.authorizationStatus(for: $0)
        }
    }

    /// Pure share-state resolution over an injected authorization-status lookup — testable without a
    /// live `HKHealthStore` (the simulator reports every type `.notDetermined`). Heart rate is the
    /// representative "did the user grant anything" gate, mirroring `isShareAuthorized`.
    static func resolveShareState(authorizableTypes: Set<HKSampleType>,
                                  status: (HKSampleType) -> HKAuthorizationStatus) -> ShareState {
        guard status(HKQuantityType(.heartRate)) == .sharingAuthorized else { return .unauthorized }
        let denied = authorizableTypes.filter { status($0) == .sharingDenied }
        return denied.isEmpty ? .authorized : .partial(Array(denied))
    }

    /// User-facing name for a share type, for the partial-grant / failure warnings. Maps quantity
    /// types back through `MetricKind` where possible; a small table covers the non-`MetricKind`
    /// extras (sleep, energy, cycle tracking, blood pressure, workouts).
    static func friendlyName(for type: HKSampleType) -> String {
        for k in MetricKind.allCases {
            if let qt = quantityType(for: k), qt.isEqual(type) { return k.displayName }
        }
        if type.isEqual(HKCategoryType(.sleepAnalysis)) { return "Sleep" }
        if type.isEqual(HKQuantityType(.basalEnergyBurned)) { return "Resting Energy" }
        if type.isEqual(HKCategoryType(.menstrualFlow)) { return "Cycle Tracking" }
        if type.isEqual(systolicType) || type.isEqual(diastolicType) { return "Blood Pressure" }
        if type.isEqual(HKQuantityType(.distanceCycling)) { return "Cycling Distance" }
        if type is HKWorkoutType || type is HKSeriesType { return "Workouts" }
        // Without this the #132 partial-grant banner would show the raw
        // "HKCategoryTypeIdentifierHeadache" from the fallthrough below.
        if type.isEqual(HKCategoryType(.headache)) { return "Headache" }
        return type.identifier
    }

    /// De-duplicated, stably-sorted friendly names for a set of denied/failed types (both BP
    /// constituents collapse to one "Blood Pressure", etc.).
    static func friendlyNames(for types: [HKSampleType]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for name in types.map({ friendlyName(for: $0) }).sorted() where seen.insert(name).inserted {
            out.append(name)
        }
        return out
    }

    /// Deep link into the Health app — the recovery path once the one-time permission sheet
    /// has been used up (see `authorizationPromptAvailable`). There is no per-app deep link to
    /// Health's privacy page; the app root is as close as iOS allows.
    static let healthAppURL = URL(string: "x-apple-health://")!

    /// Whether calling `requestAuthorization()` would actually present the iOS permission
    /// sheet. iOS shows the HealthKit sheet ONCE per app for a given type set: after the user
    /// responds — even declining everything — later requests return immediately with no UI,
    /// which reads as a dead "Connect" button. `false` (while unauthorized) means the only
    /// path left is the Health app's own toggles, so the UI must route there instead. `nil` =
    /// status unknown (the entitlement-stripped sideload case) — treat as promptable so the
    /// tap path can throw and surface `healthUnavailable` as before. A new shareable type
    /// added in an update flips this back to `true` (the sheet re-appears for the new types
    /// only), so the prompt path self-heals across upgrades. That is also what heals a device left
    /// in the build-50 workout loop: its `HKWorkoutType`/`HKSeriesType` SHARE status is back to
    /// `.notDetermined`, both are in `allTypes`, so this reports `.shouldRequest` and #129 re-asks.
    ///
    /// The two sets passed here MUST stay the two sets `requestAuthorization()` passes — Apple
    /// defines this probe as "whether the user would be prompted if the SAME collections of types
    /// are passed to requestAuthorization" (HKHealthStore.h). Until this build the read half was
    /// `[sleepAnalysis]` while the request sent a much larger set, so this probe was answering for a
    /// request the app never makes, and a type added to the request's read half would have been
    /// invisible to the #129 upgrade re-prompt. Aligning them adds no prompt for anyone — see
    /// `authorizationReadTypes`.
    func authorizationPromptAvailable() async -> Bool? {
        guard Self.isAvailable else { return false }
        guard let status = try? await store.statusForAuthorizationRequest(toShare: allTypes,
                                                                          read: authorizationReadTypes)
        else { return nil }
        return status == .shouldRequest
    }

    /// What a `flushToHealth` pass actually wrote (for a status line); all-zero when there
    /// was nothing pending or share access isn't granted.
    struct FlushResult: Equatable {
        var samples = 0, sleepSegments = 0, steps = 0
        var restingDays = 0, passiveHours = 0
        var activeKcal = 0.0
        var naps = 0
        var distanceM = 0.0         // estimated distance written (#81)
        var exerciseMinutes = 0.0   // estimated exercise minutes written (#82)
        var menstrualFlowEntries = 0  // user-logged period entries written (#78)
        var headacheEntries = 0       // user-logged headache entries written (headache signals P1)
        /// Metrics whose HealthKit `save` actually THREW this pass (#135) — distinct from "nothing
        /// pending". Persisted per-metric so the UI can surface an honest "X hasn't synced" warning
        /// instead of the blanket "Auto-syncing" line. Empty on a clean/idle flush.
        var failures: Set<MetricKind> = []
        var wroteAnything: Bool {
            samples > 0 || sleepSegments > 0 || steps > 0
                || restingDays > 0 || passiveHours > 0 || activeKcal > 0 || naps > 0
                || distanceM > 0 || exerciseMinutes > 0 || menstrualFlowEntries > 0
                || headacheEntries > 0
        }
    }

    /// Metrics whose HealthKit `save` threw during the CURRENT flush pass. Reset at the top of
    /// `flushToHealth`; the inline blocks and per-helper flushes add to it on a caught save error.
    /// Rolled into `FlushResult.failures` and persisted (below) so all three flush entry points
    /// (foreground, RingSession, background task) surface a consistent failure state. (#135)
    private var pendingFlushFailures: Set<MetricKind> = []

    // MARK: Persisted per-metric write-failure map (#135)
    //
    // Flushes run from three entry points on SEPARATE `HealthKitWriter` instances, so the last
    // failure per metric lives in UserDefaults (mirroring the `hk.*` watermark pattern) where all
    // three can write it and the UI can read it. Set on a caught save error, CLEARED on the next
    // successful write of that metric — so "nothing pending" and "writes failing" stay distinct.
    private static let failureMapKey = "hk.failures.byMetric"   // [MetricKind.rawValue : since1970]

    /// Merge one flush pass into the persisted failure map: stamp `failed` metrics with `now`, and
    /// clear any `written` metric's flag (a later success wins, so a re-enabled type self-heals).
    static func recordFlushOutcome(written: Set<MetricKind>, failed: Set<MetricKind>,
                                   now: Date = Date(), _ defaults: UserDefaults = .standard) {
        var map = (defaults.dictionary(forKey: failureMapKey) as? [String: Double]) ?? [:]
        for m in failed { map[m.rawValue] = now.timeIntervalSince1970 }
        for m in written { map.removeValue(forKey: m.rawValue) }
        if map.isEmpty { defaults.removeObject(forKey: failureMapKey) }
        else { defaults.set(map, forKey: failureMapKey) }
    }

    /// The persisted per-metric write failures (metric → last failure time), for the UI warning.
    static func healthWriteFailures(_ defaults: UserDefaults = .standard) -> [MetricKind: Date] {
        guard let map = defaults.dictionary(forKey: failureMapKey) as? [String: Double] else { return [:] }
        return map.reduce(into: [:]) { acc, kv in
            if let kind = MetricKind(rawValue: kv.key) { acc[kind] = Date(timeIntervalSince1970: kv.value) }
        }
    }

    /// Mirror everything pending into Apple Health in one pass — scalar vitals, the night's
    /// sleep, and today's step delta — each gated by its own watermark so nothing double-
    /// writes. No-op (and advances no watermark) when share access isn't granted, so the
    /// data backfills on the first flush after the user authorizes. Best-effort: a failure
    /// on one metric doesn't block the others or advance its watermark.
    /// `sleepFinalized` is reserved for an authoritative wake signal (currently Sleep Focus ending):
    /// unlike an ordinary drain, that signal proves the user ended their sleep session, so the night
    /// can be written immediately instead of waiting for the conservative 20-minute quiet margin.
    @discardableResult
    func flushToHealth(store: LocalStore, sleepSegments: [SleepSegment] = [],
                       sleepFinalized: Bool = false) async -> FlushResult {
        var result = FlushResult()
        guard isShareAuthorized, !Self.isFlushing else { return result }
        Self.isFlushing = true
        defer { Self.isFlushing = false }

        pendingFlushFailures = []            // per-pass failure accumulator (#135)
        var writtenKinds: Set<MetricKind> = []  // metrics that landed at least one sample this pass

        // Scalars: write, THEN advance the watermark, so a failed save backfills next time. The
        // write is SPLIT per metric (#132): a single denied type (e.g. SpO₂) no longer sinks the
        // whole batch — the granted metrics still land and only the denied one is left pending.
        if let pending = try? store.pendingHealthSamples(), !pending.isEmpty {
            let outcome = await write(pending)
            if !outcome.written.isEmpty {
                try? store.markHealthWritten(outcome.written)   // advance ONLY for what actually saved
                result.samples = outcome.written.count
                writtenKinds.formUnion(outcome.written.map(\.kind))
            }
            pendingFlushFailures.formUnion(outcome.failed)
        }
        // Sleep: mirror the SETTLED night to Health (SleepHealthGate) — with periodic overnight
        // draining the staged night grows as epochs arrive, so an in-progress night is held back
        // behind the quiet margin. A night also routinely RE-STAGES hours after wake (denser data /
        // the once-a-morning full re-stage), and the old forward-only `.sleep` cursor made the write
        // append-only, freezing Health at the first, thinner write while the card grew to the fuller
        // staging. `mirrorSettledNight` fixes that: it delete-and-replaces the night whenever the
        // current staging differs from what was last mirrored (a no-op when nothing changed), so
        // Apple Health tracks the card up AND down.
        if SleepHealthGate.isReadyToWrite(latestSegmentEnd: sleepSegments.map(\.end).max(),
                                          now: Date(), finalized: sleepFinalized) {
            switch await mirrorSettledNight(local: store, segments: sleepSegments) {
            case .wrote(let count):
                result.sleepSegments = count
                writtenKinds.insert(.sleep)
            case .unchanged:
                break
            case .failed:
                // A denied .sleepAnalysis type (or a transient write error) — surface it (#135)
                // instead of silently retrying, so the card can say "Sleep hasn't synced".
                pendingFlushFailures.insert(.sleep)
            }
        }
        // Persisted manual extensions backfill after the ordinary night write. This is essential for
        // bedtime slices (which sit before the forward cursor) and also retries a wake extension if
        // the edit happened while Health was denied/offline. Watermarks advance only after `save`
        // succeeds; no HealthKit object is queried, replaced, or deleted.
        if let edits = try? store.pendingSleepEditHealthWrites() {
            for edit in edits {
                // Same rule as `reconcileEditedNightSleepLocked`: these segments are bounded by a
                // window the WEARER typed and saved, which cannot grow the way an in-progress
                // staged night can, so her Save is the finalization signal and the 20-minute quiet
                // margin does not apply. Leaving it here would strand the leading in-bed slice of
                // the very edit the reconcile had just written (2026-08-24 tester: saved 06:50
                // against a 06:44 wake).
                guard SleepHealthGate.isReadyToWrite(
                    latestSegmentEnd: edit.segments.map(\.end).max(), now: Date(), finalized: true
                ) else { continue }
                do {
                    // Track the backfill sample UUIDs so a later TRIM of the same night can delete
                    // them (otherwise an extension written here would survive the trim).
                    let uuids = try await writeReturningSleepUUIDs(edit.segments)
                    store.appendSleepEditHealthUUIDs(uuids, night: edit.night)
                    // Watermark from what Health actually received, never from what was proposed —
                    // see the note in `reconcileEditedNightSleepLocked` step 3. Nothing is withheld
                    // today (the two sets coincide), and the rule is kept anyway because it is the
                    // path where a future withholding would bite hardest: a leading extension left
                    // out of the write but watermarked anyway is never offered again, so the sleep
                    // could not be backfilled even once records arrived to justify it.
                    let published = edit.segments.healthPublishable
                    try store.markSleepEditHealthWritten(night: edit.night, segments: published)
                    result.sleepSegments += published.count
                    writtenKinds.insert(.sleep)
                } catch {
                    pendingFlushFailures.insert(.sleep)
                    break
                }
            }
        }
        // Drain any sleep-edit reconciles that were deferred because a flush held the gate when the
        // user saved (so a trim made mid-flush still reaches Health). We hold `isFlushing` here, so
        // run the locked core directly — it deletes the trimmed sleep the append-only paths can't.
        // Clear ONLY if the stored marker is still the one we processed, so a newer same-night edit
        // enqueued during our awaits is preserved (not lost) and drained next flush.
        var drainedNights: [Date] = []
        for pending in store.pendingSleepReconciles() {
            let times = SleepEdit.Times(inBedStart: pending.inBedStart, sleepOnset: pending.sleepOnset,
                                        sleepWake: pending.sleepWake)
            let done = await reconcileEditedNightSleepLocked(local: store, night: pending.night,
                                                             times: times,
                                                             editedSegments: pending.segments)
            if done { store.clearPendingSleepReconcileIfUnchanged(pending) }
            drainedNights.append(pending.night)
        }
        // ONE-SHOT: re-run the Health write for nights the wearer edited BEFORE this build, whose
        // asserted sleep build 47 dropped on the floor. Placed HERE, at the end of the sleep block,
        // for three reasons: `Self.isFlushing` is already held so it can call the locked reconcile
        // core directly (exactly as the drain above does); `flushToHealth` is the one Health entry
        // point that runs on a BGTask / CoreBluetooth-restoration launch as well as a foreground
        // one, so the repair does not wait for the wearer to open the app; and running AFTER the
        // drain means a night that is already queued is written once, not twice.
        await republishPreUpgradeEditedNights(local: store, alreadyDrained: drainedNights)
        // Naps (#76): each carries its own `healthWritten` flag (NOT the night's `.sleep` cursor),
        // so a daytime nap and the overnight night write independently and never collide.
        result.naps = await flushNaps(store: store)
        if result.naps > 0 { writtenKinds.insert(.sleep) }

        // Women's health (#78): write pending user-logged period flow entries to Health.
        // Gated by each entry's own `healthWritten` flag — independent of all other writes.
        result.menstrualFlowEntries = await flushMenstrualFlow(localStore: store)

        // Headache log (headache signals, Phase 1): the user's own logged headaches. Same shape as
        // the period log — gated by each entry's own `healthWritten` flag, so it neither blocks nor
        // is blocked by any other write. Nothing here is inferred; every row is user-entered.
        result.headacheEntries = await flushHeadacheLog(localStore: store)

        // Profile is used for calories + exercise-minute thresholds — resolved once here so the
        // derived writes use the same snapshot. Body inputs come from the shared profile defaults;
        // the ring transmits none of them. Distance (below) no longer needs it — PROTOCOL.md §5.3.1
        // confirms RingConn's distance derivation is a fixed per-step constant, not height/sex.
        let profile = Self.storedUserProfile()

        // Steps + distance estimate (#81, #steps-history): write each pending TIMESTAMPED step
        // snapshot as its OWN narrow-window stepCount sample (its real observed start/end), not
        // one `startOfDay→now` lump. HealthKit's stepCount type apportions a sample across every
        // hour it overlaps, so the old single-window write smeared a whole day's steps evenly
        // across every elapsed hour instead of landing them near when they actually happened —
        // per-snapshot writes fix that while HealthKit's SUM still lands the correct daily total.
        // Distance is netted/credited per CALENDAR DAY (the GPS-credit ledger in UserDefaults is
        // day-keyed), so snapshots are grouped by day rather than assuming one day's worth.
        if let pending = try? store.pendingStepSamples(), !pending.isEmpty {
            let stepSamples: [QuantitySample] = pending.map {
                QuantitySample(kind: .steps, start: $0.start, end: $0.end, value: Double($0.delta))
            }
            // Derive the per-day distance samples (and their GPS-credit reductions) up front, but do
            // NOT fold them into the step write — see the coupling note below. `netDistanceEstimate`
            // only COMPUTES the net (reading the day-keyed GPS ledger); the ledger is mutated solely
            // by `commitDistanceGPSCredit`, which we defer until distance actually writes.
            var distanceSamples: [QuantitySample] = []
            var gpsCommits: [(reduction: Double, day: Date)] = []
            let byDay = Dictionary(grouping: pending) { Calendar.current.startOfDay(for: $0.end) }
            for (day, rows) in byDay {
                let dayDelta = rows.reduce(0) { $0 + $1.delta }
                let rawDistanceM = DistanceEstimate.meters(steps: dayDelta)
                let (netDistanceM, gpsReduction) = Self.netDistanceEstimate(rawDistanceM, day: day)
                if netDistanceM > 0 {
                    let dayEnd = rows.map(\.end).max() ?? day
                    distanceSamples.append(QuantitySample(kind: .distance, start: day, end: dayEnd, value: netDistanceM))
                }
                gpsCommits.append((gpsReduction, day))
            }
            // Scalar KINDS split independently (#132), but steps and the DERIVED distance stay COUPLED:
            // distance has no watermark of its own — it's re-derived from the same `StoredStepSample`
            // rows every flush and rides their `healthWritten` flag (advanced only by
            // `markStepSamplesWritten`). So distance is written in a SEPARATE pass that runs ONLY after
            // the step rows are marked written this flush. Folding distance into the step batch would
            // let a granted-distance sample LAND even when the steps save fails (the per-kind split
            // saves each kind independently) — and, with the rows still pending, re-derive + re-write
            // every subsequent flush → HealthKit SUMS it → the day's distance inflates ~N×. Writing
            // distance only after a successful step save defers it instead of duplicating it.
            let stepsOutcome = await write(stepSamples)
            if !stepsOutcome.failed.contains(.steps) {
                try? store.markStepSamplesWritten(pending)
                result.steps = pending.reduce(0) { $0 + $1.delta }
                writtenKinds.insert(.steps)
                // Steps landed and the rows are now marked written → safe to write/commit distance.
                if !distanceSamples.isEmpty {
                    let distanceOutcome = await write(distanceSamples)
                    if Self.distanceMayWrite(stepsFailed: false,
                                             distanceFailed: distanceOutcome.failed.contains(.distance)) {
                        for commit in gpsCommits { Self.commitDistanceGPSCredit(commit.reduction, day: commit.day) }
                        let distanceWritten = distanceOutcome.written
                            .filter { $0.kind == .distance }.reduce(0) { $0 + $1.value }
                        result.distanceM = distanceWritten
                        if distanceWritten > 0 { writtenKinds.insert(.distance) }
                    } else {
                        // TRADEOFF (accepted): steps granted + distance denied → this window's distance
                        // estimate is skipped and won't backfill if the user later enables Distance,
                        // because the step rows are already marked written. Distance is a DERIVED
                        // estimate (steps × stride), not measured data; a separate `distanceWritten`
                        // flag + migration to make it independently backfillable is out of scope. The
                        // GPS credit is NOT committed here, so it isn't consumed against a write that
                        // didn't happen.
                        pendingFlushFailures.insert(.distance)
                    }
                }
            }
            // If steps FAILED, distance was never written (deferred with the rows), so no distance
            // failure is recorded here.
            pendingFlushFailures.formUnion(stepsOutcome.failed.subtracting([.distance]))
        }
        // Pre-fetch HR samples for the 32-day basal-energy lookback — the widest window needed
        // by both resting HR and passive-calorie flushes. Fetched once and shared so we don't
        // query LocalStore twice for overlapping ranges (#172 review, fix #2).
        let basalHR = Self.prefetchHRSamples(local: store, lookbackDays: Self.basalRHRLookbackDays,
                                              now: Date())

        // Derived daily resting HR — one sample per finalized day (#18, #37). Idempotency is a
        // UserDefaults day-watermark, NOT the store cursor: RHR isn't a stored sample, and the
        // `hk:` cursor rows belong to the raw-sample mirror above.
        result.restingDays = await flushRestingHR(prefetchedHR: basalHR, sleepSegments: sleepSegments)
        if result.restingDays > 0 { writtenKinds.insert(.restingHeartRate) }

        // Energy: passive (hourly BMR) + active (HR-derived or steps-derived estimate).
        // Watermark-gated (#37) and labeled as derived estimates in HealthKit metadata.
        result.passiveHours = await flushPassiveCalories(profile: profile, prefetchedHR: basalHR)
        result.activeKcal = await flushActiveCalories(local: store, profile: profile)
        if result.activeKcal > 0 { writtenKinds.insert(.activeEnergy) }

        // Exercise minutes estimate (#82): elevated-HR minutes outside the sleep window.
        // ESTIMATE — basic 50% maxHR threshold. Full 4-level intensity follows #93 decode.
        result.exerciseMinutes = await flushExerciseMinutes(local: store, profile: profile)

        // Roll the per-pass failures into the result and persist the per-metric failure map so all
        // three flush entry points surface a consistent "X hasn't synced" state; a same-pass success
        // clears a prior failure so a re-enabled type self-heals. (#135)
        result.failures = pendingFlushFailures
        Self.recordFlushOutcome(written: writtenKinds, failed: pendingFlushFailures)
        return result
    }

    /// Write each pending nap to Apple Health as sleep (a coarse inBed + asleepCore pair over the
    /// nap window) and mark it written, returning the count. Gated by each nap's own
    /// `healthWritten` flag — independent of the night's `.sleep` cursor — so naps and the night
    /// never collide. Best-effort: a failed save leaves the flag so it retries next flush.
    private func flushNaps(store: LocalStore) async -> Int {
        guard let pending = try? store.pendingNaps(), !pending.isEmpty else { return 0 }
        var written = 0
        for nap in pending {
            // Write the nap's staged hypnogram (Deep/Light/REM — RingConn sleepPhases parity) when it
            // has one, else a coarse inBed+asleepCore pair. Append-only, gated by the nap's own flag.
            let segs = nap.stagedSegments ?? [
                SleepSegment(start: nap.effectiveStart, end: nap.effectiveEnd, stage: .inBed),
                SleepSegment(start: nap.effectiveStart, end: nap.effectiveEnd, stage: .asleepCore),
            ]
            // A MANUALLY ADDED nap is sleep the ring never detected, typed in full by the wearer —
            // the same epistemic status as an `.asserted` span in an edited night, and until
            // 2026-08-24 the two paths disagreed about it: the night withheld it while the nap wrote
            // it as plain `.asleepCore` (`SleepEditedNightNotice` conceded the inconsistency in
            // writing). Now both publish and both label. An EDITED auto-nap is not tagged: the ring
            // did record there, and the edit only moved the edges — the nap-scale
            // `.assertedOverMeasured`.
            do {
                // WRITE FIRST, THEN CLEAN — the same ordering `reconcileEditedNightSleep` uses, so a
                // HealthKit failure can never leave Health emptier than before. `editNap` re-arms
                // `healthWritten` when a shrink or a move leaves a previously-mirrored span
                // uncovered; without this, that stale sleep stayed in Apple Health permanently
                // because `pendingNaps()` never offered the row again.
                let uuids = try await writeReturningSleepUUIDs(segs,
                                                               userEntered: nap.isManuallyAdded)
                if let stale = store.staleNapHealthSpan(start: nap.start) {
                    await deleteStaleNapSleep(stale, keeping: uuids,
                                              current: nap.effectiveStart ..< nap.effectiveEnd)
                }
                try store.markNapWritten(start: nap.start)
                written += 1
            } catch { pendingFlushFailures.insert(.sleep); break }   // surface + stop; naps retry next flush
        }
        return written
    }

    /// Delete this app's sleep samples across a nap's previously-mirrored span, EXCLUDING the
    /// samples just written and anything inside the nap's current window. Own-samples-only, so a
    /// night's sleep or another app's data is never touched. Best-effort: a failure leaves a
    /// transient duplicate the next edit cleans up, which is strictly better than deleting
    /// optimistically and losing the record.
    private func deleteStaleNapSleep(_ stale: DateInterval, keeping newUUIDs: [String],
                                     current: Range<Date>) async {
        // Own-samples-only comes from `deleteObjects` itself — HealthKit refuses to delete another
        // source's data — exactly as `deleteNightSleep` (:1938) relies on. Deliberately NOT adding an
        // `HKSource.default()` predicate: it is redundant there and an unproven variation here, and a
        // source predicate that matched nothing would make this delete silently do nothing.
        let type = HKCategoryType(.sleepAnalysis)
        var subs: [NSPredicate] = [
            HKQuery.predicateForSamples(withStart: stale.start, end: stale.end, options: []),
        ]
        let keep = Set(newUUIDs.compactMap { UUID(uuidString: $0) })
        if !keep.isEmpty {
            subs.append(NSCompoundPredicate(
                notPredicateWithSubpredicate: HKQuery.predicateForObjects(with: keep)))
        }
        if current.upperBound > current.lowerBound {
            subs.append(NSCompoundPredicate(notPredicateWithSubpredicate:
                HKQuery.predicateForSamples(withStart: current.lowerBound, end: current.upperBound,
                                            options: [.strictStartDate, .strictEndDate])))
        }
        _ = try? await store.deleteObjects(of: type,
                                           predicate: NSCompoundPredicate(andPredicateWithSubpredicates: subs))
    }

    /// Write pending user-logged period flow entries to Apple Health, returning the count
    /// written. Apple Health Cycle Tracking models flow as one sample PER DAY, so each logged day
    /// from start through the mirrored last day is written as its own one-day `menstrualFlow`
    /// sample. We NEVER invent a duration: a FINALIZED period mirrors exactly the days the user
    /// logged, and an OPEN one mirrors up to today bounded by `maxAutoExtendPeriodDays`. (#78)
    ///
    /// Reshaped after `flushHeadacheLog`, which already documents why this shape is the correct
    /// one. Two defects reported by a tester on 2026-08-24 ("I can see a lot of entries being
    /// added every day, not just one, but several dozen per day") are fixed here:
    ///
    /// 1. NO REWRITE UNLESS THE CONTENT CAN DIFFER. An open period was never finalized, so it was
    ///    returned by the pending query on EVERY flush — foreground activation, sync completion,
    ///    every BLE wake-drain and every BGTask — and each one deleted and rewrote the entire
    ///    span. Now every successful mirror finalizes the row, and it re-opens for exactly the two
    ///    reasons the content can actually change: a clinical edit (`savePeriodEntry` clears the
    ///    watermark) or a new DAY appearing on an open period (`periodMirrorIsUpToDate`, which
    ///    reads the covered span off the tracked sample count and so needs no new stored column).
    ///    An entry that is already correct now costs one comparison and touches neither store.
    ///
    /// 2. WRITE FIRST, DELETE AFTER. The old delete-first order left a window in which a crash
    ///    made the user's Health store EMPTIER than before the flush — data loss on a log they can
    ///    never reconstruct. Write-first's own hazard is narrower and is closed explicitly: the
    ///    new UUIDs are recorded ALONGSIDE the stale ones before anything is deleted, so a kill
    ///    mid-flush can only leave a TRACKED duplicate that the next flush removes — never a
    ///    sample this app wrote but can no longer name, which the user could then never delete
    ///    through our UI. This goes one step FURTHER than `flushHeadacheLog`, which records the
    ///    new UUIDs after its save and so still has a (small) window where a kill strands real
    ///    samples untracked; recording before the save closes it outright, and the Kit suite
    ///    steps a kill through every point to prove it. Worth porting back to the headache path.
    private func flushMenstrualFlow(localStore: LocalStore) async -> Int {
        // EXPLICIT denial is TERMINAL — the save can never succeed, so return before touching
        // either store rather than throwing on every entry on every flush (the same guard, for the
        // same reason, as `flushHeadacheLog`). `.notDetermined` deliberately falls THROUGH: the
        // save throws until the user grants, the entries stay pending, and the whole log backfills
        // on the first flush after Cycle Tracking sharing is turned on.
        if store.authorizationStatus(for: HKCategoryType(.menstrualFlow)) == .sharingDenied {
            return 0
        }
        guard let candidates = try? localStore.periodEntriesNeedingHealthMirror(),
              !candidates.isEmpty else { return 0 }
        var written = 0
        for entry in candidates {
            let now = Date()
            // An entry whose watermark is still set has had no clinical edit, so the ONLY thing
            // that can have changed is the elapsed-day span. If that matches what we already
            // wrote, this flush has nothing to say — write nothing, delete nothing, touch nothing.
            if entry.healthWritten,
               CyclePredictor.periodMirrorIsUpToDate(writtenSampleCount: entry.hkSampleUUIDs.count,
                                                     start: entry.start, end: entry.end,
                                                     today: now) {
                continue
            }
            // `alreadyCoveredDays` is the anti-retraction floor: one tracked UUID == one mirrored
            // day, so a legacy open period past the cap keeps every day it already put in Health.
            let samples = Self.menstrualFlowSamples(start: entry.start, end: entry.end,
                                                    flowLevelRaw: entry.flowLevelRaw,
                                                    alreadyCoveredDays: entry.hkSampleUUIDs.count,
                                                    today: now)
            guard !samples.isEmpty else { continue }   // nothing to assert yet (future start date)
            let stale = entry.hkSampleUUIDs   // read BEFORE `recordPeriodEntryHK` overwrites it
            let fresh = samples.map { $0.uuid.uuidString }
            do {
                // Track new AND stale together BEFORE the save, not between the save and the
                // delete. `HKObject` assigns its `uuid` at construction, so the names exist while
                // the samples are still only in memory — which lets this close the one window the
                // headache path cannot: a kill between `save` and a record-after would leave real
                // samples in Health that no row names, and the user could never delete them
                // through our UI. Recording a UUID that never reached Health is harmless in the
                // other direction: the delete predicate simply matches nothing.
                try localStore.recordPeriodEntryHK(start: entry.start,
                                                   hkSampleUUIDs: stale + fresh, finalized: false)
                try await store.save(samples)
                // Only now that the replacement is actually IN Health may the previous copy go.
                if !stale.isEmpty { await deleteMenstrualFlowSamples(uuidStrings: stale) }
                try localStore.recordPeriodEntryHK(start: entry.start,
                                                   hkSampleUUIDs: fresh, finalized: true)
                written += 1
            } catch {
                // Roll the tracking back to what it was before this attempt. Recording ahead of
                // the save is what makes every written sample nameable, but it means a FAILED save
                // would otherwise leave `fresh` — UUIDs that never reached Health — tracked
                // forever, and the next attempt would append another generation on top: the array
                // would grow by a full span on every flush for as long as the save kept failing
                // (a `.notDetermined` authorization does exactly that). Restoring `stale` bounds
                // it. If we are killed before this lands, the row simply carries one extra
                // generation of unreachable UUIDs, which the next successful flush deletes
                // harmlessly — the delete predicate matches nothing for samples that never existed.
                try? localStore.recordPeriodEntryHK(start: entry.start,
                                                    hkSampleUUIDs: stale, finalized: false)
                break   // stop on first failure; unwritten entries retry next flush
            }
        }
        return written
    }

    // (`writeMenstrualFlow` was folded into `flushMenstrualFlow` above: the write-first/
    // delete-after order needs the sample UUIDs in hand BEFORE the save is committed to the store,
    // so a helper that both built and saved them could no longer sit between those two steps.)

    /// Build one HealthKit menstrual-flow sample per logged day. HealthKit requires
    /// `HKMetadataKeyMenstrualCycleStart` on EVERY menstrual-flow sample: `true` on the first
    /// day and `false` thereafter. Omitting the key raises an uncatchable Obj-C exception while
    /// constructing the second sample, which caused the build 17–22 TestFlight launch/background
    /// crash loop for anyone with a multi-day period pending. Internal for the app-target crash
    /// regression test.
    static func menstrualFlowSamples(start: Date,
                                     end: Date?,
                                     flowLevelRaw: Int,
                                     alreadyCoveredDays: Int = 0,
                                     today now: Date = Date(),
                                     calendar cal: Calendar = .current) -> [HKCategorySample] {
        let type = HKCategoryType(.menstrualFlow)
        let flowValue: HKCategoryValueMenstrualFlow
        switch flowLevelRaw {
        case 1: flowValue = .light
        case 3: flowValue = .heavy
        default: flowValue = .medium
        }
        let firstDay = cal.startOfDay(for: start)
        // Finalized period: through the logged end day, clamped to today (unchanged — an
        // explicitly logged end is authoritative at any length). Open period: up to today OR the
        // auto-extension cap, whichever comes first, so an unended period stops inventing days
        // instead of growing by one sample per elapsed day forever. Either way, never a future
        // day. `alreadyCoveredDays` floors the open case at the span ALREADY mirrored, so the cap
        // can only ever stop the app ADDING days — it can never withdraw one already written to a
        // wearer's medical record (the upgrade path; see `openPeriodAutoExtendLastDay`).
        // The rule itself is `CyclePredictor`'s so it is covered by the Kit suite.
        let lastDay = CyclePredictor.periodMirrorLastDay(start: start, end: end, today: now,
                                                          alreadyCoveredDays: alreadyCoveredDays,
                                                          calendar: cal)
        guard lastDay >= firstDay else { return [] }

        var samples: [HKCategorySample] = []
        var day = firstDay
        var isFirstDay = true
        while day <= lastDay {
            let dayEnd = cal.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
            // The key is REQUIRED on every sample; only its Boolean value changes after day one.
            let metadata: [String: Any] = [HKMetadataKeyMenstrualCycleStart: isFirstDay]
            samples.append(HKCategorySample(type: type, value: flowValue.rawValue,
                                            start: day, end: dayEnd, metadata: metadata))
            isFirstDay = false
            day = dayEnd
        }
        return samples
    }

    /// Delete previously-written `menstrualFlow` samples by UUID (best-effort). Used when a
    /// logged period is edited (delete-then-rewrite) or deleted in-app, so Apple Health never
    /// keeps a stale or orphaned flow sample. (#78)
    func deleteMenstrualFlowSamples(uuidStrings: [String]) async {
        let uuids = Set(uuidStrings.compactMap { UUID(uuidString: $0) })
        guard !uuids.isEmpty, Self.isAvailable else { return }
        let predicate = HKQuery.predicateForObjects(with: uuids)
        _ = try? await store.deleteObjects(of: HKCategoryType(.menstrualFlow), predicate: predicate)
    }

    // MARK: Headache log (headache signals, Phase 1)
    //
    // A user-entered LABEL series, not a measurement: nothing in this app detects a headache, so
    // every sample below is `HKMetadataKeyWasUserEntered: true` and every field comes verbatim from
    // what the user typed. Shaped after the period log (#78), with one deliberate divergence noted
    // on `flushHeadacheLog`.

    /// Write pending user-logged headache entries to Apple Health, returning the count written.
    ///
    /// One sample per entry, gated by that entry's own `healthWritten` flag. Entries IMPORTED from
    /// Health are already excluded by `pendingHeadacheEntries`, so a read-back can never loop round
    /// into a write-back.
    ///
    /// An OPEN headache (`end == nil`) is FINALIZED like any other. It is tempting to leave it
    /// pending "so it extends later, like an open period" — but that analogy is false and the bug it
    /// causes is real: `menstrualFlowSamples` derives its last day from `today`, so an open period
    /// genuinely yields MORE samples as days elapse, whereas `headacheSamples` is a pure function of
    /// (onset, end, severity) — with `end == nil` it rebuilds a byte-identical zero-length sample
    /// forever. Leaving it unfinalized re-wrote that identical sample on every flush (foreground
    /// activation, sync completion, every BLE wake-drain and BGTask) for the life of the entry, and
    /// every one of those rewrites reopened the orphan window below. `saveHeadacheEntry` already
    /// resets `healthWritten` on any clinical change, so the mirror re-opens exactly when the
    /// content can actually differ — which is the only time a rewrite carries new information.
    ///
    /// Ordering DIVERGES from `flushMenstrualFlow` on purpose: this writes FIRST and deletes the
    /// prior sample(s) afterwards, the same no-data-loss order `mirrorSettledNight` uses. The period
    /// path's delete-first leaves a window in which a crash makes the user's Health store EMPTIER
    /// than it was before the flush. Write-first's own hazard is narrower but NOT self-healing, so
    /// it is closed explicitly: the new UUIDs are recorded ALONGSIDE the stale ones before anything
    /// is deleted, so a kill mid-flush can only ever leave a TRACKED duplicate the next flush
    /// removes — never a sample this app wrote that it can no longer name, which the user could
    /// then never delete through our UI.
    func flushHeadacheLog(localStore: LocalStore) async -> Int {
        // EXPLICIT denial is TERMINAL — the save can never succeed, so return before touching the
        // store instead of throwing on every entry on every flush. `.notDetermined` deliberately
        // falls THROUGH: the save throws until the user grants, the entries stay pending, and the
        // whole log backfills on the first flush after Headache sharing is turned on.
        if store.authorizationStatus(for: HKCategoryType(.headache)) == .sharingDenied { return 0 }
        guard let pending = try? localStore.pendingHeadacheEntries(), !pending.isEmpty else { return 0 }
        var written = 0
        for entry in pending {
            let now = Date()
            let samples = Self.headacheSamples(onset: entry.onset, end: entry.end,
                                               severityRaw: entry.severityRaw, now: now)
            guard !samples.isEmpty else { continue }   // unloggable row (placeholder onset)
            let stale = entry.hkSampleUUIDs   // read BEFORE `recordHeadacheEntryHK` overwrites it
            let fresh = samples.map { $0.uuid.uuidString }
            let settled = Self.headacheEntryIsSettled(end: entry.end, now: now)
            do {
                try await store.save(samples)
                // Track new AND stale together before deleting anything, so a kill between the save
                // and the delete leaves every sample we have written still nameable by this row.
                try localStore.recordHeadacheEntryHK(onset: entry.onset,
                                                     hkSampleUUIDs: stale + fresh,
                                                     finalized: false)
                // Only now that the replacement is actually IN Health may the previous copy go.
                if !stale.isEmpty { await deleteHeadacheSamples(uuidStrings: stale) }
                try localStore.recordHeadacheEntryHK(onset: entry.onset,
                                                     hkSampleUUIDs: fresh,
                                                     finalized: settled)
                written += 1
            } catch { break }   // stop; the unwritten entry stays pending and retries next flush
        }
        return written
    }

    /// Whether the sample written for this entry is SETTLED — i.e. rebuilding it later from the
    /// same entry cannot produce anything different, so the entry may be finalized and stop being
    /// re-written on every flush.
    ///
    /// Pure + static so the rule is unit-testable without a live `HKHealthStore`: it is the guard
    /// against a regression that is completely invisible at runtime (an identical sample rewritten
    /// dozens of times a day forever, each rewrite reopening the orphan window, and
    /// `FlushResult.wroteAnything` pinned true so every background wake logs a phantom Health write).
    ///
    /// `end == nil` is settled: `headacheSamples` emits a zero-length sample at `onset` that is
    /// byte-identical on every rebuild. A PAST `end` is settled for the same reason. Only a FUTURE
    /// `end` is unsettled, because `headacheSamples` clamps it to `now` — so the correct sample
    /// genuinely does change as time passes, and that is the one case worth staying pending for.
    static func headacheEntryIsSettled(end: Date?, now: Date = Date()) -> Bool {
        guard let end else { return true }
        return end <= now
    }

    /// Build the Apple Health sample(s) for one logged headache — exactly ONE, spanning
    /// `[onset, end]`. Pure + static (the same seam `menstrualFlowSamples` uses) so the clamping
    /// rules below are unit-testable without a live `HKHealthStore`.
    static func headacheSamples(onset: Date, end: Date?, severityRaw: Int,
                                now: Date = Date()) -> [HKCategorySample] {
        // `StoredHeadacheEntry.onset` defaults to `.distantPast` for SwiftData lightweight
        // migration, so a row that never received a real onset must produce NOTHING rather than a
        // sample dated in year 1. Returning [] (not trapping) keeps one bad row from sinking the flush.
        guard onset > .distantPast else { return [] }

        // A headache with no logged resolution is a ZERO-LENGTH sample — we never invent a duration
        // the user didn't state. HealthKit REJECTS `endDate < startDate`, and a rejected save would
        // strand the entry permanently pending, so a future end is clamped to `now` and that clamp
        // is itself floored at `onset` (an onset the user set in the future must still be writable).
        var sampleEnd = onset
        if let end, end > onset { sampleEnd = max(onset, min(end, now)) }

        // `severityRaw` carries `HKCategoryValueSeverity`'s raw values 1:1, so this is the identity
        // mapping — but it must be VALIDATED against the known set, not merely constructed.
        // `HKCategoryValueSeverity` imports as a NON-FROZEN Obj-C enum, so `init(rawValue:)`
        // succeeds for ANY Int (measured against the iOS 26.5 SDK: -1, 5, 99 and Int.max all
        // construct successfully). An `init?` + `??` fallback is therefore DEAD CODE that would
        // write a corrupt or future-build number into Apple Health as a severity.
        //
        // Anything outside the known set lands on `.unspecified` — NEVER on `.moderate` or any
        // other substantive level. Quietly promoting an unknown number into a clinical one would
        // assert a severity the user never stated.
        let knownSeverities: Set<Int> = [
            HKCategoryValueSeverity.unspecified.rawValue,
            HKCategoryValueSeverity.notPresent.rawValue,
            HKCategoryValueSeverity.mild.rawValue,
            HKCategoryValueSeverity.moderate.rawValue,
            HKCategoryValueSeverity.severe.rawValue,
        ]
        let value = knownSeverities.contains(severityRaw)
            ? severityRaw
            : HKCategoryValueSeverity.unspecified.rawValue

        // User-entered by definition: nothing in this app auto-detects a headache.
        return [HKCategorySample(type: HKCategoryType(.headache), value: value,
                                 start: onset, end: sampleEnd,
                                 metadata: [HKMetadataKeyWasUserEntered: true])]
    }

    /// Delete previously-written `.headache` samples by UUID (best-effort). Used by the write-then-
    /// delete replacement above and when the user deletes a logged headache in-app, so Apple Health
    /// never keeps a stale or orphaned entry. UUID- AND type-scoped, so no other data is reachable.
    func deleteHeadacheSamples(uuidStrings: [String]) async {
        let uuids = Set(uuidStrings.compactMap { UUID(uuidString: $0) })
        guard !uuids.isEmpty, Self.isAvailable else { return }
        let predicate = HKQuery.predicateForObjects(with: uuids)
        _ = try? await store.deleteObjects(of: HKCategoryType(.headache), predicate: predicate)
    }

    /// One headache read back OUT of Apple Health, for the import path. A plain value type rather
    /// than an `HKCategorySample` so the importer stays HealthKit-agnostic and testable.
    struct ImportedHeadache: Sendable {
        let uuid: String
        let onset: Date
        let end: Date?
        let severityRaw: Int
    }

    /// The outcome of an Apple Health headache read, split by SOURCE.
    ///
    /// `ownSourceCount` exists for the sake of honest copy, not for the data. A read that came back
    /// with nothing but OpenCircuit's own samples is a completely different thing to tell the user
    /// than a read that came back with nothing at all — the latter is indistinguishable from a
    /// DENIED read (HealthKit reports no error for one, only an empty result), the former proves
    /// the read worked. Collapsing the two made the app tell a user whose Health store was full of
    /// their own logged headaches that none were found, and blame permissions for it.
    struct HeadacheReadResult: Sendable {
        let external: [ImportedHeadache]
        let ownSourceCount: Int

        /// True only when the query returned NO samples whatsoever — the single case where "nothing
        /// found" is accurate and where Health permissions are a plausible explanation.
        var returnedNothingAtAll: Bool { external.isEmpty && ownSourceCount == 0 }
    }

    /// Headaches logged in Apple Health at or after `since`, EXCLUDING this app's own writes.
    ///
    /// HONEST EMPTY — read this before writing any UI copy against the result: HealthKit does not
    /// report READ authorization (by design, so an app can't learn what a user declined to share).
    /// A denied read simply returns no samples, INDISTINGUISHABLE from "the user has none logged".
    /// `[]` here therefore means "nothing readable", and the caller must say "found none to import",
    /// never anything about whether the user gets headaches.
    ///
    /// Read authorization needs no separate change: `requestAuthorization()` already builds its
    /// `read` set from `allTypes` (minus the write-only workout + route types), so `.headache`
    /// joining `allTypes` puts it in BOTH halves of the request, and Info.plist already carries
    /// NSHealthShareUsageDescription for the existing reads. Users who already authorized are
    /// re-prompted because a newly-added shareable type flips `authorizationPromptAvailable()` back
    /// to `true` (see its note).
    func readHeadacheSamples(since: Date) async -> HeadacheReadResult {
        guard Self.isAvailable else { return HeadacheReadResult(external: [], ownSourceCount: 0) }
        // Our own samples must never be re-imported: each would return as a second, "healthImport"
        // copy of an entry the user already logged, and every later import round would breed
        // another. There is no existing own-source helper in this codebase, so identity is
        // `Bundle.main.bundleIdentifier` matched against each sample's source. A nil bundle id
        // (never true for a real app bundle) means we can't tell ours apart — refuse, don't loop.
        guard let ownBundleID = Bundle.main.bundleIdentifier else {
            return HeadacheReadResult(external: [], ownSourceCount: 0)
        }
        let predicate = HKQuery.predicateForSamples(withStart: since, end: nil, options: [])
        let samples: [HKCategorySample] = await withCheckedContinuation { cont in
            let query = HKSampleQuery(
                sampleType: HKCategoryType(.headache), predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(keyPath: \HKSample.startDate, ascending: true)]
            ) { _, result, _ in
                // The error is dropped deliberately: a denied read reports no error, only an empty
                // result, so an error branch could not tell the two apart anyway (see above).
                cont.resume(returning: (result as? [HKCategorySample]) ?? [])
            }
            store.execute(query)
        }
        let ownSource = samples.filter { $0.sourceRevision.source.bundleIdentifier == ownBundleID }
        let external = samples.compactMap { sample -> ImportedHeadache? in
            guard sample.sourceRevision.source.bundleIdentifier != ownBundleID else { return nil }
            return ImportedHeadache(
                uuid: sample.uuid.uuidString,
                onset: sample.startDate,
                // Zero-length = an onset with no logged resolution. Report nil, not an end equal to
                // the start, which downstream would read as a real 0-minute headache.
                end: sample.endDate > sample.startDate ? sample.endDate : nil,
                severityRaw: sample.value
            )
        }
        return HeadacheReadResult(external: external, ownSourceCount: ownSource.count)
    }

    /// THE app's only HealthKit authorization request. Adding a second one is the defect fixed on
    /// this branch — see `authorizationReadTypes`. A new type belongs in `allTypes` (to write) or in
    /// `authorizationReadTypes` (to read), never in a request of its own.
    func requestAuthorization() async throws {
        // `authorizationReadTypes` is passed BY NAME at every call site here and in
        // `authorizationPromptAvailable()` — never bound to a local first. A local is how the probe
        // and the request drifted apart before this build, and `HealthKitAuthorizationSurfaceTests`
        // pins the by-name form precisely because a local named `read` walks past a text audit.
        //
        // Every type in `allTypes` is deliberately third-party-WRITABLE (that's why `.temperature`
        // maps to `.bodyTemperature`, not the read-only `.appleSleepingWristTemperature`) —
        // an unshareable type here would poison the whole request. Defensive isolation: if the
        // request still throws (a future/edge type the OS refuses to share), retry WITHOUT
        // temperature so one bad type degrades to "temp not shared" instead of disabling share
        // access for every metric. (A genuinely non-shareable Apple-computed type raises an Obj-C
        // NSInvalidArgumentException this can't catch — which is exactly why we never list one.)
        do {
            try await store.requestAuthorization(toShare: allTypes, read: authorizationReadTypes)
        } catch {
            var writable = allTypes
            if let temp = Self.quantityType(for: .temperature) { writable.remove(temp) }
            try await store.requestAuthorization(toShare: writable, read: authorizationReadTypes)
        }
    }

    /// Outcome of a split scalar write (#132): which input samples actually LANDED (so the caller
    /// advances only their watermark) and which metric KINDS threw (so they're surfaced + retried).
    struct ScalarWriteOutcome {
        var written: [QuantitySample] = []
        var failed: Set<MetricKind> = []
    }

    /// Whether the derived distance estimate may be WRITTEN + GPS-credited this pass. Distance rides
    /// the step rows' single `healthWritten` flag, so it may only land when steps saved (rows marked
    /// written, so nothing re-derives) AND distance itself wasn't denied — else a granted distance
    /// re-writes every flush while steps stay pending and HealthKit sums the duplicate (#132 fix).
    static func distanceMayWrite(stepsFailed: Bool, distanceFailed: Bool) -> Bool {
        !stepsFailed && !distanceFailed
    }

    /// Write scalar samples, SPLIT per metric kind. Caller filters with SyncCursor first.
    ///
    /// The batch is grouped by `MetricKind` and each group saved on its own, so a single DENIED
    /// type (which makes `store.save` throw `errorAuthorizationDenied` for everything in one call)
    /// no longer sinks the whole batch — the granted metrics still reach Health and only the denied
    /// kind is reported as failed and left pending (#132). Non-throwing: failures are returned, not
    /// raised, so the caller can advance watermarks per surviving kind.
    func write(_ samples: [QuantitySample]) async -> ScalarWriteOutcome {
        var outcome = ScalarWriteOutcome()
        let byKind = Dictionary(grouping: samples, by: \.kind)
        for (kind, group) in byKind {
            let hk: [HKQuantitySample] = group.compactMap { s in
                guard let type = Self.quantityType(for: s.kind) else { return nil }
                let q = HKQuantity(unit: Self.unit(for: s.kind), doubleValue: s.value)
                return HKQuantitySample(type: type, quantity: q, start: s.start, end: s.end,
                                        metadata: Self.metadata(for: s.kind))
            }
            guard !hk.isEmpty else { continue }   // no writable HK type for this kind — nothing to save
            do {
                try await store.save(hk)
                outcome.written.append(contentsOf: group)
            } catch {
                outcome.failed.insert(kind)   // this metric is denied/failing; others still land
            }
        }
        return outcome
    }

    /// Metadata key on HRV samples flagging which statistic the value actually is.
    static let hrvStatisticMetadataKey = "OpenCircuitHRVStatistic"

    /// Per-kind sample metadata. The ring reports HRV as **RMSSD**, but HealthKit only offers
    /// an **SDNN** field — so we store the RMSSD value in `.heartRateVariabilitySDNN` and tag it
    /// honestly here rather than invent an RMSSD→SDNN conversion constant (the two are not a
    /// fixed ratio; see docs/HEALTHKIT_MAPPING.md). Readers can distinguish via this key.
    static func metadata(for kind: MetricKind) -> [String: Any]? {
        switch kind {
        case .hrvSDNN: return [hrvStatisticMetadataKey: "RMSSD"]
        // Distance is an ESTIMATE (steps × height-based stride, not GPS). Tag it so Health
        // readers can filter or label it appropriately (#81). Replaced by decoded device
        // distance once the activity-epoch [15:22] payload is decoded (#93).
        case .distance: return [HKMetadataKeyWasUserEntered: false,
                                "OpenCircuitDistanceSource": "steps×stride-estimate"]
        default: return nil
        }
    }

    /// Metadata flag marking basal (passive) energy samples as a derived ESTIMATE — a BMR formula
    /// prorated per hour, NOT a value the ring measured — so Health readers can label or filter it.
    static let basalEnergyEstimateMetadataKey = "OpenCircuitBasalEnergyEstimated"

    /// Metadata flag on a basal-energy sample recording whether the day's MEASURED resting HR
    /// actually modulated the formula BMR this hour (true), or it fell back to the static value
    /// (false — new user / no baseline yet). Lets Health readers and QA see which path ran.
    static let basalEnergyRHRAdjustedMetadataKey = "OpenCircuitBasalEnergyRHRAdjusted"

    /// Write one hour of basal (passive) energy. Previously this was a STATIC per-profile constant
    /// (Mifflin-St Jeor ÷ 24) — identical every hour of every day. It's now nudged by how far the
    /// day's MEASURED resting HR (`restingHR`) sits from the person's own recent baseline
    /// (`baselineRestingHR`); pass either as nil to fall back to the static BMR (never zero). Still
    /// an ESTIMATE, labeled as such in metadata.
    func writePassiveCalories(profile: UserProfile, date: Date,
                              restingHR: Double? = nil, baselineRestingHR: Double? = nil) async throws {
        let type = HKQuantityType(.basalEnergyBurned)
        let quantity = HKQuantity(
            unit: .kilocalorie(),
            doubleValue: Calories.basalKcalPerHour(profile: profile,
                                                   restingHR: restingHR,
                                                   baselineRestingHR: baselineRestingHR)
        )
        let adjusted = restingHR != nil && baselineRestingHR != nil
        let sample = HKQuantitySample(
            type: type,
            quantity: quantity,
            start: date,
            end: date.addingTimeInterval(3600),
            metadata: [Self.basalEnergyEstimateMetadataKey: true,
                       Self.basalEnergyRHRAdjustedMetadataKey: adjusted,
                       HKMetadataKeyWasUserEntered: false]
        )
        try await store.save(sample)
    }

    /// Metadata flag marking active-energy samples as a derived ESTIMATE (HR-TRIMP / steps×distance),
    /// NOT a value the ring measured — so Health readers can label or filter it (#82-style).
    static let activeEnergyEstimateMetadataKey = "OpenCircuitActiveEnergyEstimated"

    /// Build one active-energy sample over an EXPLICIT window. Extracted as a pure static (the same
    /// seam `menstrualFlowSamples` uses) so the timestamps can be asserted in the app test target —
    /// `HealthKitWriter` builds a live `HKHealthStore`, so anything that saves cannot be tested.
    /// Returns nil for non-positive kcal or an inverted/empty window; HealthKit REJECTS `end < start`
    /// and a throw there would strand the flush watermarks (see `ActiveEnergyWindow`).
    static func activeEnergySample(kcal: Double, start: Date, end: Date) -> HKQuantitySample? {
        guard kcal > 0, end > start else { return nil }
        return HKQuantitySample(
            type: HKQuantityType(.activeEnergyBurned),
            quantity: HKQuantity(unit: .kilocalorie(), doubleValue: kcal),
            start: start,
            end: end,
            metadata: [Self.activeEnergyEstimateMetadataKey: true,
                       HKMetadataKeyWasUserEntered: false]
        )
    }

    /// Write one active-energy delta over the window it accrued in.
    ///
    /// WAS `writeActiveCalories(kcal:date:)`, which hardcoded `start: date, end: date + 3600` and was
    /// only ever called with `date = startOfDay` — so the WHOLE day's active energy piled into Apple
    /// Health's 00:00–01:00 bar ("it says I burned 300 calories at 12am, while I was laying in bed").
    /// The daily total was always correct (HealthKit SUMs this type); only the placement was wrong.
    /// The window now comes from `ActiveEnergyWindow.resolve`. Returns whether a sample was written.
    @discardableResult
    func writeActiveCalories(kcal: Double, window: DateInterval) async throws -> Bool {
        guard let sample = Self.activeEnergySample(kcal: kcal,
                                                   start: window.start,
                                                   end: window.end) else { return false }
        try await store.save(sample)
        return true
    }

    /// Save a whole flush's worth of per-bucket increments in ONE call.
    ///
    /// Batched on purpose: the ledger's watermarks advance as a unit, so a partial save would let
    /// the marks outrun what Health actually accepted — and since `activeEnergyBurned` SUMS, the
    /// kcal Health did accept could never be reconciled away. `HKHealthStore.save([HKSample])` is
    /// atomic, so the marks are only ever committed against a save that fully succeeded.
    @discardableResult
    func writeActiveCalories(_ writes: [ActiveEnergyLedger.Write]) async throws -> Bool {
        let samples = writes.compactMap {
            Self.activeEnergySample(kcal: $0.kcal, start: $0.start, end: $0.end)
        }
        guard !samples.isEmpty else { return false }
        try await store.save(samples)
        return true
    }

    /// One derived resting-HR sample for a day (anchored at start-of-day; HealthKit buckets it
    /// onto that calendar day). Value comes from `RestingHR` (sleep mean → low-activity floor).
    func writeRestingHR(bpm: Double, day: Date) async throws {
        let q = HKQuantity(unit: Self.unit(for: .restingHeartRate), doubleValue: bpm)
        let sample = HKQuantitySample(type: HKQuantityType(.restingHeartRate),
                                      quantity: q, start: day, end: day)
        try await store.save(sample)
    }

    // MARK: Derived-write watermarks (UserDefaults — see flushToHealth)
    //
    // Resting HR and energy are DERIVED, not stored samples, so they can't ride the LocalStore
    // `hk:` cursor (which gates the raw-sample mirror). Each keeps its own idempotency mark in
    // UserDefaults — shared across the foreground + background `HealthKitWriter` instances, and
    // only advanced after a confirmed write, so a failed/unauthorized flush backfills next time.
    private static let rhrWatermarkKey = "hk.restingHR.lastDay"      // start-of-day last written
    private static let basalWatermarkKey = "hk.basalEnergy.nextHour" // first hour not yet written
    static let activeDayKey = "hk.activeEnergy.day"          // start-of-day of the accumulator
    static let activeWrittenKey = "hk.activeEnergy.writtenKcal"
    /// End of the last active-energy window SUCCESSFULLY written — the start of the next one, so
    /// consecutive deltas tile the day without overlapping (HealthKit SUMs them). Advanced only
    /// alongside `activeWrittenKey` on a confirmed save; see `ActiveEnergyWindow.resolve` for why
    /// every read of it is clamped to start-of-day.
    private static let activeAnchorKey = "hk.activeEnergy.anchorEnd"
    // Per-bucket accounting (see `ActiveEnergyLedger`). Indexed by ordinal from local midnight, so
    // a late drain that inserts an EARLIER bucket pays only its own increment. All four are
    // day-scoped and cleared together on rollover.
    static let activeBucketKcalKey = "hk.activeEnergy.bucketKcal"
    static let activeCarryKey = "hk.activeEnergy.carryKcal"
    static let activeBucketSeedDayKey = "hk.activeEnergy.bucketSeedDay"
    private static let activeWorkoutCreditedKey = "hk.activeEnergy.workoutCreditedKcal"
    private static let activeWorkoutCreditedDayKey = "hk.activeEnergy.workoutCreditedDay"
    /// Total active kcal this app has actually SAVED to HealthKit today. Distinct from the bucket
    /// marks, which say only where energy sits: this is the day-total backstop that makes any
    /// bucket relocation incapable of re-paying kcal Health already holds.
    static let activeSavedKey = "hk.activeEnergy.savedKcal"
    /// Time zone the stored day marker was computed in. `startOfDay` evaluates BOTH sides in the
    /// CURRENT zone, so flying west turns mid-day into "a new day", which would reset every mark
    /// and re-pay the morning. Travel must re-seed against the new grid, never reset.
    static let activeDayTZKey = "hk.activeEnergy.dayTZ"
    // Exercise minutes (#82) watermark — like active energy, delta-based per day.
    private static let exerciseDayKey     = "hk.exerciseTime.day"         // start-of-day
    private static let exerciseWrittenKey = "hk.exerciseTime.writtenMin"  // total minutes already counted

    // Distance double-count avoidance (steps×stride estimate vs workout GPS).
    // WorkoutSessionManager records foot-based (walk/run/hike) GPS distance written to
    // .distanceWalkingRunning today via `recordWorkoutWalkRunDistance`; the daily steps×stride
    // estimate nets out this GPS distance so the same foot-distance isn't summed twice in
    // Health's "Walking + Running Distance" total. Cycling GPS goes to .distanceCycling, which
    // doesn't overlap the walk/run estimate, so it's never netted. GPS is preferred (the
    // accurate measurement is kept; only the estimate is reduced for the overlapping window).
    static let workoutWalkRunDistanceDayKey    = "hk.workoutWalkRunDistance.day"
    static let workoutWalkRunDistanceMetersKey = "hk.workoutWalkRunDistance.meters"
    static let workoutActiveKcalDayKey         = "hk.workoutActiveKcal.day"
    static let workoutActiveKcalKey            = "hk.workoutActiveKcal.kcal"
    private static let estimateGPSCreditedDayKey    = "hk.distanceEstimate.gpsCreditedDay"
    private static let estimateGPSCreditedMetersKey = "hk.distanceEstimate.gpsCreditedMeters"

    /// Record foot-based workout GPS distance (meters) written to .distanceWalkingRunning today,
    /// so the daily steps×stride estimate can net it out and avoid double counting. Day-keyed.
    static func recordWorkoutWalkRunDistance(_ meters: Double, now: Date = Date(),
                                             _ defaults: UserDefaults = .standard) {
        guard meters > 0 else { return }
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let storedDay = Date(timeIntervalSince1970: defaults.double(forKey: workoutWalkRunDistanceDayKey))
        var total = cal.startOfDay(for: storedDay) == today
            ? defaults.double(forKey: workoutWalkRunDistanceMetersKey) : 0
        total += meters
        defaults.set(today.timeIntervalSince1970, forKey: workoutWalkRunDistanceDayKey)
        defaults.set(total, forKey: workoutWalkRunDistanceMetersKey)
    }

    /// Record workout active energy that was successfully committed to HealthKit. The daily
    /// active-energy estimate uses this to avoid double-counting workout HR that #121 now also
    /// persists into LocalStore for Goals/Trends.
    static func recordWorkoutActiveKcal(_ kcal: Double, day: Date = Date(),
                                        _ defaults: UserDefaults = .standard) {
        guard kcal > 0 else { return }
        let cal = Calendar.current
        let today = cal.startOfDay(for: day)
        let storedDay = Date(timeIntervalSince1970: defaults.double(forKey: workoutActiveKcalDayKey))
        let prior = cal.startOfDay(for: storedDay) == today
            ? defaults.double(forKey: workoutActiveKcalKey) : 0
        defaults.set(today.timeIntervalSince1970, forKey: workoutActiveKcalDayKey)
        defaults.set(prior + kcal, forKey: workoutActiveKcalKey)
    }

    private static func workoutActiveKcalCredited(day today: Date,
                                                  _ defaults: UserDefaults = .standard) -> Double {
        let cal = Calendar.current
        let storedDay = Date(timeIntervalSince1970: defaults.double(forKey: workoutActiveKcalDayKey))
        return cal.startOfDay(for: storedDay) == today
            ? defaults.double(forKey: workoutActiveKcalKey) : 0
    }

    /// Net a completed workout's committed active energy out of today's daily active-energy
    /// estimate. The daily estimate is `max(hrKcal, stepKcal)` — whichever channel is larger for
    /// the day — and the workout ALREADY wrote its own `activeEnergyBurned` sample to Health. So we
    /// subtract the committed workout kcal from the CHOSEN daily estimate, not from one channel:
    ///   • HR-locked outdoor run → HR channel dominates → credit nets the HR side,
    ///   • indoor/treadmill (steps counted, HR sparse) → step channel dominates → credit STILL nets
    ///     (the old "HR side only" netting left indoor sessions double-counted — reviewer #1),
    ///   • distance-derived workout (HR never locked) → credit nets whichever channel is chosen,
    ///     never over-subtracting a channel that never held the workout (reviewer #2).
    /// Clamped at 0 so a workout larger than the whole-day estimate can't push it negative.
    static func netDailyActiveKcalEstimate(hrKcal: Double, stepKcal: Double,
                                           workoutActiveKcal: Double) -> Double {
        let dailyEstimate = max(max(hrKcal, 0), max(stepKcal, 0))
        return max(0, dailyEstimate - max(workoutActiveKcal, 0))
    }

    /// Reduce a raw steps×stride distance estimate by however much workout GPS walk/run distance
    /// hasn't yet been netted out today, preferring the accurate GPS measurement. Returns the
    /// net meters to write (≥ 0) and the reduction applied (to commit after a successful write).
    private static func netDistanceEstimate(_ raw: Double, day today: Date,
                                            _ defaults: UserDefaults = .standard) -> (net: Double, reduction: Double) {
        let cal = Calendar.current
        let gpsDay = Date(timeIntervalSince1970: defaults.double(forKey: workoutWalkRunDistanceDayKey))
        let gpsTotal = cal.startOfDay(for: gpsDay) == today
            ? defaults.double(forKey: workoutWalkRunDistanceMetersKey) : 0
        let creditedDay = Date(timeIntervalSince1970: defaults.double(forKey: estimateGPSCreditedDayKey))
        let credited = cal.startOfDay(for: creditedDay) == today
            ? defaults.double(forKey: estimateGPSCreditedMetersKey) : 0
        let uncredited = max(0, gpsTotal - credited)
        let reduction = min(max(raw, 0), uncredited)
        return (raw - reduction, reduction)
    }

    /// Commit a distance-estimate GPS netting after a successful write (advances the credited
    /// accumulator so the same GPS meters aren't subtracted again on a later flush).
    private static func commitDistanceGPSCredit(_ reduction: Double, day today: Date,
                                                _ defaults: UserDefaults = .standard) {
        guard reduction > 0 else { return }
        let cal = Calendar.current
        let creditedDay = Date(timeIntervalSince1970: defaults.double(forKey: estimateGPSCreditedDayKey))
        let credited = cal.startOfDay(for: creditedDay) == today
            ? defaults.double(forKey: estimateGPSCreditedMetersKey) : 0
        defaults.set(today.timeIntervalSince1970, forKey: estimateGPSCreditedDayKey)
        defaults.set(credited + reduction, forKey: estimateGPSCreditedMetersKey)
    }

    /// A day's resting HR is finalized once the day is ~half over, so a pre-dawn flush can't
    /// freeze a partial-night value, yet last night's RHR still lands the same day (by midday).
    private static let restingFinalizationDelay: TimeInterval = 12 * 3600

    /// Pre-fetch HR samples from LocalStore for a given lookback, returning mapped HRSamples.
    /// Called once per flush cycle; the result is shared across `flushRestingHR` and
    /// `flushPassiveCalories` to avoid redundant LocalStore queries (#172 review, fix #2).
    private static func prefetchHRSamples(local: LocalStore, lookbackDays: Int,
                                           now: Date) -> [HRSample] {
        let cal = Calendar.current
        let from = cal.date(byAdding: .day, value: -lookbackDays, to: cal.startOfDay(for: now))
            ?? now.addingTimeInterval(-Double(lookbackDays) * 86_400)
        guard let stored = try? local.samples(kind: .heartRate, from: from, to: now),
              !stored.isEmpty else { return [] }
        return stored.map { HRSample(bpm: Int($0.value), start: $0.start, end: $0.end) }
    }

    /// Write one resting-HR sample per finalized day not yet covered by the day-watermark.
    /// Uses pre-fetched HR samples (shared with `flushPassiveCalories`) to avoid a redundant
    /// LocalStore query.
    private func flushRestingHR(prefetchedHR: [HRSample], sleepSegments: [SleepSegment]) async -> Int {
        let cal = Calendar.current
        let now = Date()
        let defaults = UserDefaults.standard
        let lastWritten = Date(timeIntervalSince1970: defaults.double(forKey: Self.rhrWatermarkKey))
        let cutoff = now.addingTimeInterval(-Self.restingFinalizationDelay)
        // Bound the scan: never re-read already-written days, and look back at most a week so a
        // first run backfills recent history without an unbounded query.
        let lookback = cal.date(byAdding: .day, value: -7, to: cal.startOfDay(for: now))
            ?? now.addingTimeInterval(-7 * 86_400)
        let scanStart = max(lookback, lastWritten)
        let hr = prefetchedHR.filter { $0.start >= scanStart }
        guard !hr.isEmpty else { return 0 }
        let days = RestingHR.dailyValues(hr: hr, sleep: sleepSegments, calendar: cal)

        var written = 0
        var newWatermark = lastWritten
        for d in days where d.day > lastWritten && d.day <= cutoff {  // days ascend
            do {
                try await writeRestingHR(bpm: d.bpm, day: d.day)
                written += 1
                newWatermark = d.day
            } catch { pendingFlushFailures.insert(.restingHeartRate); break }  // surface; stop, already-written days stay covered
        }
        if newWatermark > lastWritten {
            defaults.set(newWatermark.timeIntervalSince1970, forKey: Self.rhrWatermarkKey)
        }
        return written
    }

    /// How far back the basal-energy path reads daily resting HR: enough to hold the personal
    /// baseline window plus the couple of days an hourly backfill can touch. Bounds the query.
    private static let basalRHRLookbackDays = 32

    /// Write basal (passive) energy for each completed hour since the watermark, returning the
    /// count. First run starts the meter at the current hour (no historical flood); a long gap
    /// is clamped to the last ~24 hours.
    ///
    /// Basal energy is no longer a static per-profile constant: each hour is nudged by the MEASURED
    /// resting HR for the calendar day it belongs to, judged against the person's own prior-day
    /// baseline. Uses pre-fetched HR samples (shared with `flushRestingHR`) and derives daily RHR
    /// WITHOUT sleep segments so all days in the window use the same `lowestSustained` method —
    /// ensuring derivation parity between today and the baseline (#172 review, fix #1).
    /// Days with no RHR or too little baseline history fall back to the static per-hour BMR.
    private func flushPassiveCalories(profile: UserProfile,
                                      prefetchedHR: [HRSample]) async -> Int {
        let cal = Calendar.current
        let defaults = UserDefaults.standard
        let now = Date()
        let currentHour = Self.startOfHour(now)
        let stored = defaults.double(forKey: Self.basalWatermarkKey)
        var hour = stored == 0 ? currentHour : Date(timeIntervalSince1970: stored)
        hour = max(hour, currentHour.addingTimeInterval(-24 * 3600))  // clamp a long gap

        // Per-calendar-day resting HR over the baseline window (empty on missing/thin data → the
        // loop below simply degrades to static BMR for those hours).
        let dailyRHR = Self.dailyRestingHR(prefetchedHR: prefetchedHR, now: now, calendar: cal)

        var written = 0
        while hour < currentHour {
            let (rhr, baseline) = Self.restingEnergyInputs(forDay: cal.startOfDay(for: hour),
                                                           from: dailyRHR)
            do {
                try await writePassiveCalories(profile: profile, date: hour,
                                               restingHR: rhr, baselineRestingHR: baseline)
                written += 1
                hour = hour.addingTimeInterval(3600)
            } catch { break }  // leave the watermark at the failed hour; retry next flush
        }
        // `hour` now points at the first hour still unwritten (currentHour when all succeeded).
        if hour.timeIntervalSince1970 > stored {
            defaults.set(hour.timeIntervalSince1970, forKey: Self.basalWatermarkKey)
        }
        return written
    }

    /// Per-calendar-day resting HR (bpm), oldest day first. Derives daily RHR from pre-fetched
    /// HR samples using the `lowestSustained` path for ALL days (sleep segments intentionally
    /// omitted). This ensures derivation parity between today's RHR and the baseline: the flush
    /// receives `sleepSegments` covering only the most recent night, so passing them would make
    /// today use `sleepMean` while baseline days fall to `lowestSustained` — a systematic offset
    /// in the (today − baseline) delta that the ±20% clamp bounds but doesn't eliminate.
    /// By using `lowestSustained` uniformly, both sides of the comparison are on the same basis.
    ///
    /// NOTE (expected, not a bug): the RHR this produces to SCALE basal energy (`lowestSustained`,
    /// sleep omitted) intentionally will NOT match the daily resting-HR SAMPLE written to Health by
    /// `flushRestingHR`, which passes `sleepSegments` and so uses the sleep-mean for the most recent
    /// night. Basal-energy scaling wants a uniform, sleep-independent signal across the whole
    /// baseline window (derivation parity, above); the displayed daily RHR wants the clinically
    /// familiar sleeping resting-HR. So the internal driver and the shown metric are two different
    /// derivations by design — the divergence is expected, not a discrepancy to reconcile.
    static func dailyRestingHR(prefetchedHR: [HRSample],
                                       now: Date, calendar cal: Calendar) -> [RestingHR.DailyValue] {
        guard !prefetchedHR.isEmpty else { return [] }
        return RestingHR.dailyValues(hr: prefetchedHR, sleep: [], calendar: cal)
    }

    /// Resolve `(day's measured RHR, personal baseline)` for one calendar `day` from ascending
    /// daily values. RHR is that day's value (nil when the day has none); baseline is the trimmed
    /// mean of PRIOR days' values, or nil below the trusted minimum. Either nil ⇒ caller uses
    /// static BMR.
    static func restingEnergyInputs(forDay day: Date,
                                            from daily: [RestingHR.DailyValue])
        -> (restingHR: Double?, baseline: Double?) {
        guard let today = daily.first(where: { $0.day == day })?.bpm else { return (nil, nil) }
        let prior = daily.filter { $0.day < day }.map(\.bpm)
        return (today, Calories.restingBaselineBpm(prior: prior))
    }

    /// Earliest moment today's active-energy estimate could have started accruing: the first sample
    /// that actually fed it. `Calories.dailyEstimate` derives active kcal from qualifying HR samples
    /// (outside the sleep window) and, when the step channel wins, from the day's step total — so
    /// nothing it produces can predate the earliest of those observations.
    ///
    /// Returns nil when there is no data at all, in which case the caller falls back to start-of-day.
    /// Pure and static so it is unit-testable without HealthKit.
    static func earliestActiveEnergyContribution(hrSamples: [HRSample],
                                                 stepSamples: [StoredStepSample],
                                                 sleepWindow: DateInterval?) -> Date? {
        // HR inside the sleep window is excluded from the estimate, so it must not lower the floor.
        let hrStarts = hrSamples
            .filter { sample in sleepWindow.map { !$0.contains(sample.start) } ?? true }
            .map(\.start)
        // A step snapshot's `start` is its observation window's start (see `StoredStepSample`).
        let stepStarts = stepSamples.map(\.start)
        return (hrStarts + stepStarts).min()
    }

    /// Write today's active-energy DELTA (today's HR-derived TRIMP kcal minus what's already
    /// been written today), returning the kcal written. HealthKit SUMS activeEnergyBurned, so
    /// writing the delta lands the running daily total without re-adding it each flush.
    private func flushActiveCalories(local: LocalStore, profile: UserProfile) async -> Double {
        let cal = Calendar.current
        let now = Date()
        let today = cal.startOfDay(for: now)
        let defaults = UserDefaults.standard
        let day = Self.beginActiveEnergyDay(defaults, today: today, calendar: cal)
        let isNewDay = day.isNewDay
        var written = day.written

        // Use the same elevated-HR duration + Keytel energy estimate as the dashboard rings. This
        // keeps Health mirroring from reviving the old contradiction where moderate HR earned
        // exercise minutes but zero HR calories. Sleep is excluded before either value is derived.
        let hr = (try? local.samples(kind: .heartRate, from: today, to: now)) ?? []
        let hrSamples = hr.map { HRSample(bpm: Int($0.value), start: $0.start, end: $0.end) }
        let steps = (try? local.todaySteps(day: today)) ?? 0
        let sleepWindow: DateInterval? = (try? local.latestSleepSummary()).flatMap { s in
            guard s.inBedStart > Date.distantPast, s.inBedEnd > s.inBedStart else { return nil }
            return DateInterval(start: s.inBedStart, end: s.inBedEnd)
        }
        // Fetched from YESTERDAY so a step snapshot whose observation window opened before midnight
        // still contributes its in-day share; `Calories` clips it and prorates on metres.
        let stepSamples = (try? local.stepSamples(from: today.addingTimeInterval(-86_400),
                                                  to: now)) ?? []
        let estimate = Calories.dailyEstimate(
            hrSamples: hrSamples,
            steps: steps,
            profile: profile,
            sleepWindow: sleepWindow,
            stepWindows: stepSamples.map {
                StepWindow(start: $0.start, end: $0.end, delta: $0.delta)
            },
            dayStart: today
        )

        // Time-attributed path. Falls through to the single-delta path below when attribution
        // could not run (no step history for the day) — see `Calories.dailyEstimate`.
        if !estimate.buckets.isEmpty {
            return await flushAttributedActiveCalories(buckets: estimate.buckets,
                                                       today: today,
                                                       now: now,
                                                       legacyWritten: written,
                                                       isNewDay: isNewDay,
                                                       defaults: defaults)
        }

        // #121 started persisting workout HR into LocalStore for Goals/Trends, and workouts also
        // write their own activeEnergyBurned sample. Subtract the committed workout active kcal from
        // whichever daily channel (HR or step) is chosen, so both HR-locked and indoor/step-only
        // workouts are netted exactly once (see `netDailyActiveKcalEstimate`).
        let total = Self.netDailyActiveKcalEstimate(
            hrKcal: estimate.activeKcal,
            stepKcal: 0,
            workoutActiveKcal: Self.workoutActiveKcalCredited(day: today)
        )
        let delta = total - written
        guard delta >= 1.0 else {  // ignore sub-kcal churn; still persist the (reset) day marker
            defaults.set(today.timeIntervalSince1970, forKey: Self.activeDayKey)
            defaults.set(written, forKey: Self.activeWrittenKey)
            // Deliberately does NOT advance the anchor: this window's energy is still owed, so it
            // must roll into the next delta's window rather than being silently skipped over.
            return 0
        }

        // WHEN this delta accrued, not just how much. Previously every delta was stamped
        // [startOfDay, +1h] and Health showed the day's whole active burn at midnight (#tester
        // 2026-07-27).
        //
        // The first-flush floor is the earliest moment this energy could possibly have accrued. It
        // is deliberately NOT just the sleep window's end: `latestSleepSummary` returns the newest
        // night by date REGARDLESS OF AGE, so on any day whose night never staged — fresh install,
        // ring on the charger overnight, or a sleep drain that starved, which is precisely the
        // tester population that reports this — that value predates today, gets clamped away, and
        // the window collapses back to [00:00, now]. The reported bug would have survived the fix
        // for exactly the users who hit it. So the floor also takes the earliest sample that
        // actually FED the estimate: no active energy can predate the first data point it was
        // derived from, and that bound needs no staged night to exist.
        let earliestContribution = Self.earliestActiveEnergyContribution(
            hrSamples: hrSamples,
            stepSamples: (try? local.stepSamples(from: today, to: now)) ?? [],
            sleepWindow: sleepWindow
        )
        let notBefore = [sleepWindow?.end, earliestContribution].compactMap { $0 }.max()

        // A stored anchor can never legitimately exceed `now`; a clock step-forward (bad RTC before
        // NTP, restored backup, manual date change) would otherwise wedge active energy off until
        // wall-clock caught up — a skipped write never advances the anchor, so there is no self-heal
        // path. Clamp on read; `beginActiveEnergyDay` already cleared it on a rollover, and the
        // `isNewDay` guard keeps that intent explicit rather than relying on that side effect.
        let storedAnchor = defaults.double(forKey: Self.activeAnchorKey)
        var anchor: Date? = storedAnchor > 0 ? Date(timeIntervalSince1970: storedAnchor) : nil
        if isNewDay { anchor = nil }
        if let a = anchor, a > now { anchor = nil }

        guard let window = ActiveEnergyWindow.resolve(anchor: anchor,
                                                      notBefore: notBefore,
                                                      now: now,
                                                      dayStart: today,
                                                      kcal: delta) else {
            // No legal window (clock step-back, or two flushes inside the same second). Skip the
            // write and leave BOTH marks untouched so the kcal is still owed and rides the next
            // delta — advancing them here would silently drop it.
            return 0
        }
        do {
            let wrote = try await writeActiveCalories(kcal: delta, window: window)
            guard wrote else { return 0 }
            defaults.set(today.timeIntervalSince1970, forKey: Self.activeDayKey)
            defaults.set(total, forKey: Self.activeWrittenKey)
            defaults.set(window.end.timeIntervalSince1970, forKey: Self.activeAnchorKey)
            // Count it toward the day-total backstop too: a day can start here (no step history
            // yet) and switch to the bucket path later, whose marks know nothing about this write.
            defaults.set(defaults.double(forKey: Self.activeSavedKey) + delta,
                         forKey: Self.activeSavedKey)
            return delta
        } catch { pendingFlushFailures.insert(.activeEnergy); return 0 }
    }

    struct ActiveEnergyDayState: Equatable {
        let isNewDay: Bool
        /// Active kcal already accounted for today (0 immediately after a rollover).
        let written: Double
    }

    /// Open today's active-energy accounting, persisting a rollover reset IMMEDIATELY.
    ///
    /// This exists as its own step because the reset must survive a flush that decides to write
    /// nothing. Stamping only the day marker on such a flush leaves YESTERDAY's `writtenKcal` in
    /// place; the next flush then reads `isNewDay == false`, seeds every one of today's buckets as
    /// already paid, and writes nothing for the rest of the day — the exact "active energy stops
    /// and never resumes" symptom this change exists to fix, reintroduced through the rollover
    /// path. It is armed by any first flush of a day worth under the 1 kcal aggregate gate, which
    /// is most mornings.
    ///
    /// Travel is deliberately NOT a rollover. `startOfDay` evaluates both sides in the CURRENT zone,
    /// so flying west maps the stored marker onto the previous calendar day and the test fires
    /// mid-day, over a day Health already holds writes for. Keep the marks and force a re-seed onto
    /// the new day grid instead, so the written energy is absorbed rather than paid twice.
    static func beginActiveEnergyDay(_ defaults: UserDefaults,
                                     today: Date,
                                     calendar cal: Calendar = .current,
                                     timeZoneID: String = TimeZone.current.identifier)
        -> ActiveEnergyDayState {
        let storedDay = Date(timeIntervalSince1970: defaults.double(forKey: activeDayKey))
        let storedTZ = defaults.string(forKey: activeDayTZKey)
        let travelled = storedTZ != nil && storedTZ != timeZoneID
        let isNewDay = cal.startOfDay(for: storedDay) != today && !travelled
        defaults.set(timeZoneID, forKey: activeDayTZKey)

        if isNewDay {
            defaults.set(today.timeIntervalSince1970, forKey: activeDayKey)
            defaults.set(0.0, forKey: activeWrittenKey)
            defaults.set(0.0, forKey: activeCarryKey)
            defaults.set(0.0, forKey: activeSavedKey)
            defaults.removeObject(forKey: activeBucketKcalKey)
            defaults.removeObject(forKey: activeBucketSeedDayKey)
            defaults.removeObject(forKey: activeAnchorKey)
            return ActiveEnergyDayState(isNewDay: true, written: 0)
        }
        if travelled { defaults.removeObject(forKey: activeBucketSeedDayKey) }
        return ActiveEnergyDayState(isNewDay: false,
                                    written: defaults.double(forKey: activeWrittenKey))
    }

    /// Write the per-bucket active-energy increments this flush owes (see `ActiveEnergyLedger`).
    ///
    /// Replaces the single whole-day delta for any day that has step history. The old scalar
    /// froze the instant the last elevated-HR bout ended — `max(hrKcal, stepKcal)` stopped
    /// growing, `delta` was exactly 0, and Apple Health went silent for the rest of the day
    /// (tester, 2026-07-28). Per-bucket marks cannot do that: an afternoon bucket owes whatever it
    /// earned, whatever the morning did.
    private func flushAttributedActiveCalories(buckets: [Calories.EnergyBucket],
                                               today: Date,
                                               now: Date,
                                               legacyWritten: Double,
                                               isNewDay: Bool,
                                               defaults: UserDefaults) async -> Double {
        let cal = Calendar.current
        var marks = isNewDay
            ? []
            : (defaults.array(forKey: Self.activeBucketKcalKey) as? [Double] ?? [])
        var carry = isNewDay ? 0 : defaults.double(forKey: Self.activeCarryKey)

        // Upgrade day (or any day whose marks predate attribution): convert the legacy scalar into
        // chronological per-bucket marks, so the user writes only what the old code never got to —
        // in the buckets where they earned it — instead of re-paying the morning. Seeding is a pure
        // function of (buckets, legacyWritten), so re-running it after a no-write flush is a no-op.
        let seedDay = Date(timeIntervalSince1970: defaults.double(forKey: Self.activeBucketSeedDayKey))
        if isNewDay || cal.startOfDay(for: seedDay) != today {
            let seeded = ActiveEnergyLedger.seed(buckets: buckets,
                                                 legacyWrittenKcal: legacyWritten,
                                                 dayStart: today)
            marks = seeded.watermarks
            carry = seeded.carry
        }

        // A completed workout already wrote its own activeEnergyBurned sample. Net it out once,
        // tracked by its own credited mark exactly like `netDistanceEstimate` does for GPS.
        let creditedDay = Date(timeIntervalSince1970:
                                defaults.double(forKey: Self.activeWorkoutCreditedDayKey))
        let alreadyCredited = cal.startOfDay(for: creditedDay) == today
            ? defaults.double(forKey: Self.activeWorkoutCreditedKey) : 0
        let uncreditedWorkout = max(0, Self.workoutActiveKcalCredited(day: today) - alreadyCredited)

        let savedToday = defaults.double(forKey: Self.activeSavedKey)
        let plan = ActiveEnergyLedger.plan(buckets: buckets,
                                           watermarks: marks,
                                           dayStart: today,
                                           now: now,
                                           carry: carry,
                                           uncreditedWorkoutKcal: uncreditedWorkout,
                                           savedKcal: savedToday)
        guard !plan.writes.isEmpty else {
            // Nothing owed (or below the aggregate gate). The day marker and the rollover reset are
            // already persisted by the caller, so there is nothing to stamp here — but a fall in an
            // already-paid bucket may have been netted into carry, and that debt MUST be persisted
            // or the overpayment is forgotten and paid again on the next rise.
            if plan.carryRemaining != carry || plan.watermarks != marks {
                defaults.set(plan.watermarks, forKey: Self.activeBucketKcalKey)
                defaults.set(plan.carryRemaining, forKey: Self.activeCarryKey)
                defaults.set(today.timeIntervalSince1970, forKey: Self.activeBucketSeedDayKey)
            }
            return 0
        }
        do {
            let wrote = try await writeActiveCalories(plan.writes)
            guard wrote else { return 0 }
            defaults.set(today.timeIntervalSince1970, forKey: Self.activeDayKey)
            defaults.set(plan.watermarks, forKey: Self.activeBucketKcalKey)
            defaults.set(plan.carryRemaining, forKey: Self.activeCarryKey)
            defaults.set(today.timeIntervalSince1970, forKey: Self.activeBucketSeedDayKey)
            defaults.set(alreadyCredited + plan.workoutConsumed,
                         forKey: Self.activeWorkoutCreditedKey)
            defaults.set(today.timeIntervalSince1970, forKey: Self.activeWorkoutCreditedDayKey)
            defaults.set(savedToday + plan.totalKcal, forKey: Self.activeSavedKey)
            // Keep the legacy scalar + anchor coherent, so a day that later loses its step history
            // (or a rollback to a build without attribution) resumes from sane state. Σ marks
            // includes increments netted against debt rather than written, so it can exceed what
            // Health holds — that direction only SUPPRESSES a legacy write, never double-writes.
            defaults.set(plan.watermarks.reduce(0, +), forKey: Self.activeWrittenKey)
            if let lastEnd = plan.writes.map(\.end).max() {
                defaults.set(lastEnd.timeIntervalSince1970, forKey: Self.activeAnchorKey)
            }
            return plan.totalKcal
        } catch { pendingFlushFailures.insert(.activeEnergy); return 0 }
    }

    /// The user's body profile, read from the shared `@AppStorage` keys (the same keys
    /// `UserProfileSettingsView`/`CaloriesCardView` use — keep these defaults in sync). Feeds the
    /// BMR/TRIMP energy estimates; the ring transmits none of these inputs.
    static func storedUserProfile(_ defaults: UserDefaults = .standard) -> UserProfile {
        let age = defaults.object(forKey: "userProfile.age") as? Int ?? 35
        let weightKg = defaults.object(forKey: "userProfile.weightKg") as? Double ?? 70
        let heightCm = defaults.object(forKey: "userProfile.heightCm") as? Double ?? 170
        let sexRaw = defaults.string(forKey: "userProfile.sex") ?? BiologicalSex.male.rawValue
        return UserProfile(age: age, weightKg: max(weightKg, 1), heightCm: max(heightCm, 1),
                           sex: BiologicalSex(rawValue: sexRaw) ?? .male)
    }

    private static func startOfHour(_ date: Date, _ cal: Calendar = .current) -> Date {
        cal.date(from: cal.dateComponents([.year, .month, .day, .hour], from: date)) ?? date
    }

    /// Write today's exercise-minute DELTA (elevated-HR minutes not yet pushed to Health),
    /// returning minutes written. ESTIMATE — basic 50% maxHR threshold (#82).
    /// Full 4-level intensity (Vigorous/Moderate/Low/Inactive) follows the activity-epoch
    /// decode (#93). Uses a per-day UserDefaults accumulator identical to active energy.
    private func flushExerciseMinutes(local: LocalStore, profile: UserProfile) async -> Double {
        let cal = Calendar.current
        let now = Date()
        let today = cal.startOfDay(for: now)
        let defaults = UserDefaults.standard
        let storedDay = Date(timeIntervalSince1970: defaults.double(forKey: Self.exerciseDayKey))
        var writtenMin = defaults.double(forKey: Self.exerciseWrittenKey)
        if cal.startOfDay(for: storedDay) != today { writtenMin = 0 }

        guard let rawSamples = try? local.samples(kind: .heartRate, from: today, to: now),
              !rawSamples.isEmpty else {
            defaults.set(today.timeIntervalSince1970, forKey: Self.exerciseDayKey)
            defaults.set(writtenMin, forKey: Self.exerciseWrittenKey)
            return 0
        }
        // Exclude the latest detected sleep window so sleeping elevated HR doesn't count.
        let sleepWindow: DateInterval? = (try? local.latestSleepSummary()).flatMap { s in
            guard s.inBedStart > Date.distantPast else { return nil }
            return DateInterval(start: s.inBedStart, end: s.inBedEnd)
        }
        let hrSamples = rawSamples.map { HRSample(bpm: Int($0.value), start: $0.start, end: $0.end) }
        let maxHR = max(220 - profile.age, 1)
        let totalMin = ExerciseMinutes.estimate(hrSamples: hrSamples, maxHR: maxHR,
                                                sleepWindow: sleepWindow)
        let pendingMin = totalMin - writtenMin
        guard pendingMin >= 1.0 else {
            defaults.set(today.timeIntervalSince1970, forKey: Self.exerciseDayKey)
            defaults.set(writtenMin, forKey: Self.exerciseWrittenKey)
            return 0
        }
        // Apple Exercise Time is Apple-computed and not third-party writable (saving it errors,
        // and requesting share auth for it crashes — see `quantityType(for:)`). So the estimate
        // is surfaced in-app only and is NOT mirrored to Apple Health; advance the day watermark
        // so the running total stays correct. Contributing to the Exercise ring needs HKWorkout (#93).
        defaults.set(today.timeIntervalSince1970, forKey: Self.exerciseDayKey)
        defaults.set(totalMin, forKey: Self.exerciseWrittenKey)
        return pendingMin
    }

    // ⚠️ THE ONLY TWO FUNCTIONS IN THIS APP THAT CREATE A SLEEP `HKCategorySample`.
    //
    // Verified by grep 2026-08-20: every other `HKCategoryType(.sleepAnalysis)` in the app is a
    // READ, a DELETE predicate, or the authorization set. Five call sites reach Health with sleep —
    // `flushToHealth`'s edit backfill, `flushNaps`, `reconcileEditedNightSleepLocked`,
    // `mirrorSettledNight`, and the deferred-reconcile drain — and every one of them funnels through
    // one of these two. So the provenance split belongs HERE and nowhere else: a rule applied at
    // four of five call sites is a false sense of safety, and the audit found exactly that shape of
    // bug elsewhere in this feature.
    //
    // `segments.healthPublication` is the single split: the `.inBed` layer and everything the ring
    // measured go in as ordinary samples, and the wearer's claims over PROVEN-empty ground go in
    // carrying `HKMetadataKeyWasUserEntered: true`. Segments with no provenance information — which
    // is everything the staging path emits — are `.measured`, so an unedited night's Health write is
    // byte-for-byte what it always was, metadata included (there is none).
    //
    // ⚠️ 2026-08-24 — THIS PATH USED TO DROP THE WEARER'S ASSERTED SLEEP, AND THE MAINTAINER
    // REVERSED THAT. The report: "I corrected the night in your app, but the data in Apple Health
    // wasn't updated… I compared it with the RingConn app, and this time the entire night was
    // correctly imported into Apple Health." Silently subtracting her own correction from the one
    // surface she checks it against cost more truth than it bought. The tag is how the sample now
    // carries its own provenance instead.

    /// Write a night as contiguous sleepAnalysis category samples (mapping notes).
    func write(sleep segments: [SleepSegment]) async throws {
        let samples = Self.sleepSamples(segments, site: "write(sleep:)")
        guard !samples.isEmpty else { return }
        try await store.save(samples)
    }

    /// Write a night's sleepAnalysis samples and RETURN their UUID strings, so a later edit can delete
    /// exactly these (menstrual-flow-style tracked delete/replace).
    ///
    /// - Parameter userEntered: force the whole block to carry `HKMetadataKeyWasUserEntered`. Used
    ///   for a MANUALLY ADDED nap, whose segments the wearer typed in full — see `flushNaps`. It is
    ///   a separate argument rather than an `.asserted` provenance on those segments because
    ///   `.asserted` means "we PROVED the ring recorded nothing here", and no coverage test was run
    ///   for a typed nap; `isManuallyAdded` is the fact we actually hold.
    @discardableResult
    func writeReturningSleepUUIDs(_ segments: [SleepSegment],
                                  userEntered: Bool = false) async throws -> [String] {
        let samples = Self.sleepSamples(segments, allUserEntered: userEntered,
                                        site: "writeReturningSleepUUIDs")
        guard !samples.isEmpty else { return [] }
        try await store.save(samples)
        return samples.map { $0.uuid.uuidString }
    }

    /// Build the category samples for one night from the publication split — the ONE place the
    /// user-entered tag is applied, for the same reason the coverage filter lived in one place: a
    /// rule applied at some of the write sites is a false sense of safety.
    private static func sleepSamples(_ segments: [SleepSegment], allUserEntered: Bool = false,
                                     site: String) -> [HKCategorySample] {
        let type = HKCategoryType(.sleepAnalysis)
        let split = segments.healthPublication
        let publication = allUserEntered
            ? SleepHealthPublication(measured: [], userEntered: split.published,
                                     withheld: split.withheld, published: split.published)
            : split
        logUserEnteredSleep(segments, publication, site: site)
        func sample(_ seg: SleepSegment, metadata: [String: Any]?) -> HKCategorySample {
            HKCategorySample(type: type, value: Self.sleepValue(seg.stage).rawValue,
                             start: seg.start, end: seg.end, metadata: metadata)
        }
        return publication.measured.map { sample($0, metadata: nil) }
            // `HKMetadataKeyWasUserEntered` is Apple's own flag for "a person typed this", which is
            // exactly what an asserted span is. It does NOT exclude the sample from any total — see
            // `SleepHealthPublication` — it only lets a reader (and us, later) tell the two apart.
            + publication.userEntered.map { sample($0, metadata: [HKMetadataKeyWasUserEntered: true]) }
    }

    /// Breadcrumb how much of a night reached Health as the wearer's own entry, so the effect is
    /// auditable on a real phone instead of inferred. Silent when there is none — every unedited
    /// night. (Until 2026-08-24 this logged the same quantity as a WITHHELD one; the minutes are the
    /// same, their destination is not.)
    private static func logUserEnteredSleep(_ all: [SleepSegment],
                                            _ publication: SleepHealthPublication,
                                            site: String) {
        // Measured from what is ACTUALLY being tagged, not from the segments' provenance: the
        // manual-nap path tags a block whose segments carry no provenance at all, and reading
        // `unmeasuredAsleepSeconds` there would print a silent 0 for a real user-entered write.
        let userEnteredAsleepMin = SleepStaging.totalAsleep(publication.userEntered) / 60
        guard userEnteredAsleepMin > 0 else { return }
        let mins = String(format: "%.1f", userEnteredAsleepMin)
        ringLog.info("""
            [OC] sleep-health: \(mins, privacy: .public) asserted asleep-min written as USER-ENTERED \
            from \(site, privacy: .public) \
            (\(publication.userEntered.count, privacy: .public) of \(all.count, privacy: .public) segments \
            tagged; \(publication.withheld.count, privacy: .public) withheld)
            """)
    }

    /// Reconcile Apple Health so a manually-edited night matches the EDITED window. This is the piece
    /// that makes a **trim** REMOVE sleep from Health — the ordinary flush is append-only, so shrinking
    /// a night otherwise left the old, wider sleep in Health.
    ///
    /// WRITE-FIRST, then delete the PRIOR samples, so a HealthKit failure can never leave Health
    /// emptier than before (worst case is a transient duplicate the next edit cleans up). Deletion is
    /// UUID-scoped to the exact samples this app wrote for THIS night last time, plus a one-time
    /// cleanup of app-authored sleep still in the RECORDED in-bed span (the night the ordinary flush
    /// wrote before this feature) — never the extension region, where a daytime nap can live. So naps,
    /// other nights, and other apps' data are never deleted.
    func reconcileEditedNightSleep(local: LocalStore, night: Date,
                                   times: SleepEdit.Times, editedSegments: [SleepSegment]) async {
        // NOTE: don't gate here on `isShareAuthorized` (that probes heart-rate) — an edit made while
        // Sleep sharing is merely not-yet-granted should DEFER and retry on grant, not be dropped. The
        // locked core drops the marker only when Sleep sharing is explicitly denied.
        guard !editedSegments.isEmpty else { return }

        // Serialize with the periodic flush, which also mutates HealthKit sleep — wait briefly for an
        // in-flight flush, then take the same gate so our write+delete can't interleave with it. If a
        // flush is STILL holding the gate after the wait, DEFER (persist) the reconcile so the next
        // flush applies it — never silently drop the trim (the flush's own sleep path can't trim).
        var waited = 0
        while Self.isFlushing, waited < 40 {
            try? await Task.sleep(nanoseconds: 50_000_000); waited += 1
        }
        if Self.isFlushing {
            local.setPendingSleepReconcile(night: night, times: times, segments: editedSegments)
            return
        }
        Self.isFlushing = true
        defer { Self.isFlushing = false }
        let done = await reconcileEditedNightSleepLocked(local: local, night: night, times: times,
                                                         editedSegments: editedSegments)
        // A fresh user edit supersedes any stale pending marker on success; if it couldn't apply
        // (e.g. a transient write failure), defer it so the next flush retries.
        if done { local.clearPendingSleepReconcile(night: night) }
        else { local.setPendingSleepReconcile(night: night, times: times, segments: editedSegments) }
    }

    /// The reconcile body, assuming the Health-write gate is ALREADY held (the public wrapper takes it;
    /// the flush calls this directly while draining a deferred reconcile). Returns `true` when the
    /// reconcile is DONE or moot (the pending marker should be cleared) and `false` when it should be
    /// RETRIED later (kept/queued).
    @discardableResult
    private func reconcileEditedNightSleepLocked(local: LocalStore, night: Date,
                                                 times: SleepEdit.Times,
                                                 editedSegments: [SleepSegment]) async -> Bool {
        guard !editedSegments.isEmpty else { return true }   // nothing to write → clear the marker
        // Sleep sharing EXPLICITLY denied → we can never write this, so drop the marker (no forever
        // churn). `.notDetermined` falls through and retries — the write throws until Sleep is granted.
        if store.authorizationStatus(for: HKCategoryType(.sleepAnalysis)) == .sharingDenied { return true }
        guard let row = try? local.sleepSummary(night: night) else { return true }  // night gone → clear
        // A USER'S SAVE **IS** THE FINALIZATION SIGNAL, so the 20-minute quiet margin does not apply
        // here.
        //
        // 🟢 THE DEFECT (2026-08-24, Gen 2 Air FR04.009). She woke, saw the app had ended her night
        // at the bathroom trip, and corrected her wake to 06:44. She saved at 06:50–06:53 — SIX
        // MINUTES later, inside `SleepHealthGate.settleMargin` (20 min) — so this returned `false`,
        // wrote nothing, and merely queued the reconcile. Editing your wake time right after waking
        // is the NORMAL case, not an edge case, and "nothing happened when I saved" is exactly what
        // she reported.
        //
        // The margin exists to stop an IN-PROGRESS night being mirrored while it is still GROWING
        // (`SleepHealthGate`'s own doc). An edited night cannot grow: every edge here is one the
        // wearer typed, and the whole point of `isReadyToWrite(finalized:)` is that an authoritative
        // signal may write immediately. It still requires real segments — the empty guard above and
        // the `nil` check inside — so nothing is fabricated by writing early.
        guard SleepHealthGate.isReadyToWrite(latestSegmentEnd: editedSegments.map(\.end).max(),
                                             now: Date(), finalized: true) else { return false }

        let recordedStart = row.sleepEditRecordedInBedStart > .distantPast
            ? row.sleepEditRecordedInBedStart : times.inBedStart
        let recordedEnd = row.sleepEditRecordedInBedEnd > recordedStart
            ? row.sleepEditRecordedInBedEnd : times.sleepWake

        // 1. WRITE the edited picture FIRST. If this throws, nothing was deleted → no data loss;
        //    return false so the edit is retried on the next flush.
        let newUUIDs: [String]
        do { newUUIDs = try await writeReturningSleepUUIDs(editedSegments) }
        catch { return false }

        // 2. DELETE the prior night's samples — exact tracked UUIDs + a recorded-span transition
        //    cleanup — always EXCLUDING the fresh write AND every Health-written nap window (so a nap
        //    the night later grew over is never deleted). Returns prior UUIDs we could NOT confirm
        //    deleted, so we keep tracking them for a retry instead of forgetting them.
        //
        //    ⚠️ AND EXCLUDING EVERY SPAN WE DECLINED TO PUBLISH. A coverage-driven shrink must never
        //    drive a Health DELETE. Withholding a span from our own write is reversible — the next
        //    sync can add it back. Deleting across that span is not, and what it removes is whatever
        //    an earlier, better-informed run wrote there, when the epoch archive still held the
        //    records this run no longer does. Retention already fooled this code once (measured:
        //    403.0 asleep-min in Apple Health replaced by 0.0 on a fully-recorded night edited two
        //    days late); `MeasuredCoverage.trusted(for:)` is the primary guard and this is the
        //    backstop that keeps the failure non-destructive even if that guard is ever wrong.
        //
        //    ⚠️ 2026-08-24: `withheldSpans` IS EMPTY NOW, AND IT MUST BE. Asserted sleep is published
        //    (tagged user-entered) rather than withheld, so nothing is declined — and a stale
        //    "asserted spans" reading here would have protected the ground we DO write, sparing the
        //    PREVIOUS write over the same span from this cleanup and duplicating the night on every
        //    re-edit. It is derived from `healthPublication.withheld` so the two answers cannot
        //    drift apart again.
        let napWindows = local.healthWrittenNapWindows(overlapping: recordedStart, to: recordedEnd)
        let survivingPrior = await deletePriorEditedNightSleep(
            priorUUIDs: local.sleepEditHealthUUIDs(night: night),
            recordedStart: recordedStart, recordedEnd: recordedEnd,
            napWindows: napWindows, keeping: newUUIDs,
            withheld: editedSegments.withheldSpans)

        // 2b. Sweep auto-naps the EDITED window absorbed. Nothing else can: `mirrorSettledNight`
        //     leaves edited nights entirely alone, and the transition cleanup above deletes only
        //     inside the FROZEN recorded span while excluding nap windows — so a nap the user's
        //     corrective edit turned into night sleep would stay double-counted in totals and in
        //     Health forever (🟢 2026-08-16 tester: an 86-min 09:04–10:30 auto-nap inside her
        //     corrected wake; review find). HEALTH FIRST, row second: the row is the only record
        //     those samples exist, so it is deleted only once its samples are gone (`healthWritten`
        //     false ⇒ nothing in Health, delete directly). A Health-delete failure keeps the row —
        //     the next edit of this night retries the sweep.
        //     A nap only PARTLY inside the edited window is swept WHOLE (same semantics as the
        //     unedited path's prune): the user's asserted window wins over the detector's tail.
        let absorbed = local.autoNaps(overlapping: times.inBedStart, to: times.sleepWake)
        var sweptNaps: [StoredNap] = []
        for nap in absorbed {
            let lo = min(nap.start, nap.effectiveStart)
            let hi = max(nap.end, nap.effectiveEnd)
            if nap.healthWritten, hi > lo {
                // Exclude MANUAL naps' windows: a user-asserted nap inside the swept span must keep
                // its samples (its row survives, so orphaning would be silent double-bookkeeping).
                let manualWindows = local.healthWrittenNapWindows(overlapping: lo, to: hi,
                                                                  manualOnly: true)
                do { try await deleteNightSleep(from: lo, to: hi, napWindows: manualWindows,
                                                keeping: newUUIDs) }
                catch { continue }
            }
            sweptNaps.append(nap)
        }
        local.deleteNaps(sweptNaps, reason: "absorbed-by-edit", night: night)

        // 3. Track (fresh write + any prior we couldn't delete), and pin the watermarks so the periodic
        //    flush neither re-adds the trimmed recorded tail nor re-appends the leading extension.
        //
        //    ⚠️ THE WATERMARKS COME FROM WHAT WAS ACTUALLY WRITTEN, NOT FROM WHAT WAS PROPOSED. The
        //    write above is `editedSegments.healthPublishable`; pinning the edges from the unfiltered
        //    set would declare a leading extension "already in Health" that the coverage filter had
        //    just withheld, and `pendingSleepEditHealthWrites` would then never offer it again — so
        //    the sleep could not be added later even once the records arrived to justify it. A
        //    watermark is a claim about Apple Health, and it must only ever be made about samples
        //    Apple Health received.
        local.setSleepEditHealthUUIDs(newUUIDs + survivingPrior, night: night)
        let published = editedSegments.healthPublishable
        let editedEnd = published.map(\.end).max() ?? recordedEnd
        try? local.forceSleepCursorAtLeast(max(recordedEnd, editedEnd))
        try? local.markSleepEditHealthWritten(night: night, segments: published)
        try? local.markSleepEditHealthCovered(by: published)
        return true   // applied to Health; caller clears the pending marker (conditionally, on drain)
    }

    /// ONE-SHOT, IDEMPOTENT REPUBLISH of every night the wearer edited BEFORE this build.
    ///
    /// THE DEFECT. Reported 2026-08-25 (Gen 2 Air FR04.009 on build 47) and reproduced from the
    /// tester's own bytes by the reporter — the figures below are quoted from that report, not
    /// re-derived here. Build 47 wrote her edited night to Apple Health but silently dropped every
    /// asleep segment sitting over ground it had proved holds no records — 2 h 53 m of that night, so
    /// Health received 340 asleep minutes against the card's 513. What IS verified in this lane is
    /// the mechanism: the four exits below were each re-read at the file:line given.
    ///
    /// Build 48 reversed the policy: `healthPublication` now PUBLISHES those
    /// segments carrying `HKMetadataKeyWasUserEntered` (see `SleepProvenanceBreakdown`). But nothing
    /// re-triggers the write for a night edited BEFORE the upgrade, and all four exits are shut:
    ///   - `mirrorSettledNight` bails on `isManuallyEdited` (`:2181`) — correctly; that guard is what
    ///     stops a re-drain overwriting her edit;
    ///   - the `pendingSleepEditHealthWrites` watermarks already sit on the edited edges, so it
    ///     offers nothing;
    ///   - the pending-reconcile marker was cleared when build 47's write SUCCEEDED (`:1872`);
    ///   - `SleepProvenanceRederivation` (`:75-79`) upgrades a label only where NEW records have
    ///     appeared under the asserted span, and the 30 h archive holds none for an older night.
    /// So the only way her correction reaches Health is for this build to go back and write it once.
    ///
    /// 🚨 IT REBUILDS FROM THE STORED HYPNOGRAM, NEVER BY RE-STAGING. `LocalStore.editedNightRepublishItems`
    /// is the structural guard and carries the full argument: re-staging a night older than
    /// `EpochArchive.retention` (30 h) collapses it into ONE flat block falsely marked `.measured`,
    /// which would write invented, untagged sleep to Apple Health — a data-destroying regression
    /// dressed as a fix.
    ///
    /// INTERRUPTION IS HARMLESS because the work is idempotent and the latch is set only at the end:
    /// a kill mid-loop leaves the flag unset and the whole set re-runs on the next flush, and a night
    /// written twice is replaced rather than duplicated (`reconcileEditedNightSleepLocked` writes
    /// first, then deletes the exact tracked UUIDs of its own previous write).
    ///
    /// A PHONE WITH NO EDITED NIGHTS IS A NO-OP: one SwiftData fetch, no HealthKit call, latched for
    /// the life of the install.
    private func republishPreUpgradeEditedNights(local: LocalStore, alreadyDrained: [Date]) async {
        SleepHealthRepublishDefaults.register()
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: SleepHealthRepublishDefaults.doneKey) else { return }

        // Sleep sharing EXPLICITLY denied → we can never write these, and latching now would strand
        // the repair permanently if the wearer later switches Sleep back on in Settings ▸ Health.
        // Not latching costs one `authorizationStatus` call per flush. `.notDetermined` deliberately
        // falls THROUGH: the write throws, the night lands in the pending queue below, and the
        // ordinary drain retries it the moment access is granted — the same route a fresh edit takes
        // (see the note on `reconcileEditedNightSleep`).
        guard store.authorizationStatus(for: HKCategoryType(.sleepAnalysis)) != .sharingDenied
        else { return }

        let items = local.editedNightRepublishItems()
        guard !items.isEmpty else {
            defaults.set(true, forKey: SleepHealthRepublishDefaults.doneKey)
            return
        }

        var rewritten = 0
        var queued = 0
        var skipped = 0
        for item in items {
            // Already written this pass by the deferred-reconcile drain, from the same stored labels.
            // Same-day comparison because that is how `PendingSleepReconcileStore` keys its items.
            if alreadyDrained.contains(where: { Calendar.current.isDate($0, inSameDayAs: item.night) }) {
                skipped += 1
                continue
            }
            let times = SleepEdit.Times(inBedStart: item.inBedStart, sleepOnset: item.sleepOnset,
                                        sleepWake: item.sleepWake)
            if await reconcileEditedNightSleepLocked(local: local, night: item.night, times: times,
                                                     editedSegments: item.segments) {
                rewritten += 1
            } else {
                // A transient HealthKit write failure (or Sleep still `.notDetermined`). Hand it to
                // the app's own durable retry path instead of re-running the whole set forever.
                local.setPendingSleepReconcile(night: item.night, times: times, segments: item.segments)
                queued += 1
            }
        }
        defaults.set(true, forKey: SleepHealthRepublishDefaults.doneKey)
        // Counts only — never a clock time — so this is safe in the system log, like the sleep
        // breadcrumbs above it.
        ringLog.notice("""
            [OC] sleep-health: one-shot republish of pre-upgrade edited nights — \
            \(rewritten, privacy: .public) rewritten, \(queued, privacy: .public) queued for retry, \
            \(skipped, privacy: .public) already drained this pass, of \
            \(items.count, privacy: .public) eligible
            """)
    }

    /// Delete the app's own prior sleep for an edited night: the exact tracked UUIDs from the last
    /// write (a), plus a transition cleanup of app-authored sleep still in the RECORDED in-bed span
    /// (b, for the untracked ordinary-flush night). Both EXCLUDE the freshly-written samples, and (b)
    /// additionally excludes every Health-written NAP window — the recorded span can contain a nap the
    /// night later widened over, which must never be deleted. Returns the (a) UUIDs that could not be
    /// confirmed deleted, so the caller keeps tracking them.
    private func deletePriorEditedNightSleep(priorUUIDs: [String], recordedStart: Date,
                                             recordedEnd: Date, napWindows: [DateInterval],
                                             keeping newUUIDs: [String],
                                             withheld: [DateInterval] = []) async -> [String] {
        let type = HKCategoryType(.sleepAnalysis)
        let keep = Set(newUUIDs.compactMap { UUID(uuidString: $0) })

        // (a) Precise: the exact samples we wrote last time (never a nap or another night). Retain any
        //     we couldn't confirm deleted so they aren't forgotten (would otherwise become a permanent
        //     duplicate once the overlay is overwritten).
        var surviving: [String] = []
        let prior = Set(priorUUIDs.compactMap { UUID(uuidString: $0) }).subtracting(keep)
        if !prior.isEmpty {
            do {
                _ = try await store.deleteObjects(of: type,
                                                  predicate: HKQuery.predicateForObjects(with: prior))
            } catch {
                surviving = prior.map { $0.uuidString }
            }
        }

        // (b) Transition cleanup: app sleep still in the RECORDED in-bed span, EXCLUDING the fresh
        //     write and every Health-written nap window. Idempotent — a failure just retries next time.
        guard recordedEnd > recordedStart else { return surviving }
        var subs: [NSPredicate] = [
            HKQuery.predicateForSamples(withStart: recordedStart, end: recordedEnd, options: []),
        ]
        if !keep.isEmpty {
            subs.append(NSCompoundPredicate(
                notPredicateWithSubpredicate: HKQuery.predicateForObjects(with: keep)))
        }
        for window in napWindows {
            subs.append(NSCompoundPredicate(notPredicateWithSubpredicate:
                HKQuery.predicateForSamples(withStart: window.start, end: window.end, options: [])))
        }
        // The coverage filter's withheld ground, protected in the same way a nap window is. This is
        // the one clause that makes "we decline to publish X" incapable of ALSO meaning "and delete
        // whatever is already there across X" — see the call site.
        for span in withheld where span.duration > 0 {
            subs.append(NSCompoundPredicate(notPredicateWithSubpredicate:
                HKQuery.predicateForSamples(withStart: span.start, end: span.end, options: [])))
        }
        let pred = subs.count == 1 ? subs[0] : NSCompoundPredicate(andPredicateWithSubpredicates: subs)
        _ = try? await store.deleteObjects(of: type, predicate: pred)
        return surviving
    }

    enum MirrorOutcome { case wrote(Int); case unchanged; case failed }

    /// Mirror a SETTLED, non-edited night into Apple Health so it tracks the CARD — the merge-protected
    /// `StoredSleepSummary`, not the raw drain. The ordinary flush used to append behind the forward
    /// `.sleep` cursor, so once a night's end was under the cursor a later, fuller re-stage could never
    /// reach Health (the card grew; Health stayed frozen at the first write). This compares a content
    /// signature of the staged segments to what was last mirrored and, when it changed, delete-and-
    /// replaces the night.
    ///
    /// The night is resolved by IN-BED OVERLAP against the stored summary (`sleepSummaryOverlapping`),
    /// not `startOfDay(firstSegment)`, so a bedtime that straddles midnight can't key the mirror to a
    /// different day than the card — which would else miss an edited row (invariant 5) or under-scope
    /// the cleanup. Two guards keep Health from ever going THINNER than the card: an edited night is
    /// left to the edit reconcile, and a drain fragment whose asleep total is below the summary's
    /// (the card stayed fuller via `SleepSummaryMerge`) is NOT written — otherwise a later re-drain of
    /// a partial night would shrink Health below the protected card.
    ///
    /// Data-safety mirrors the edit reconcile: WRITE-FIRST (a throw can't empty the night — the prior
    /// samples remain), then re-check the edited flag (an edit racing our write must win), then delete
    /// the prior copy over the UNION of the last-mirrored, current, and the summary's RECORDED in-bed
    /// spans — EXCLUDING the fresh write and every Health-written nap window (so naps, other nights, and
    /// other apps are never touched). Anchoring to the durable summary span (not just this drain's
    /// segments) means a wider prior write, or one made before this overlay existed, is still cleaned.
    /// The signature is recorded even if the delete throws (write-first already put the correct night in
    /// Health) to avoid per-flush rewrite churn; the leftover duplicate — de-overlapped by Health in the
    /// "time asleep" total — is cleared by the next re-stage's union delete. Assumes the Health-write
    /// gate (`Self.isFlushing`) is HELD by the caller.
    func mirrorSettledNight(local: LocalStore, segments: [SleepSegment]) async -> MirrorOutcome {
        guard let start = segments.map(\.start).min(),
              let end = segments.map(\.end).max(), end > start else { return .unchanged }
        // Resolve the night by in-bed overlap so the key matches the card's summary across midnight;
        // fall back to start-of-day when no summary row exists yet (first-ever mirror of a new night).
        let row = try? local.sleepSummaryOverlapping(start: start, end: end)
        // The fallback MUST use the same rule the writer will file the row under (`SleepNightKey` —
        // the day the block ends on). Start-of-day of the block's start resolves to the PREVIOUS
        // night's key for any pre-midnight bedtime: `mirroredNight(night:)` would then return the
        // previous night's record, whose spanStart/spanEnd widen this night's delete window over it
        // — deleting last night's app-written sleep from Apple Health — and `setMirroredNight` would
        // overwrite its signature so the loss went undetected on the next flush too.
        let night = row?.night ?? SleepNightKey.night(inBedStart: start, inBedEnd: end)
        // A manually-edited night is OWNED by the edit reconcile, which writes the EDITED picture.
        // The raw staging here must never overwrite it, so leave edited nights entirely alone.
        //
        // ⚠️ THIS BAIL ALSO FREEZES THE NIGHT'S PROVENANCE, WHICH IS WHY THE RE-DERIVATION DOES NOT
        // GO THROUGH HERE. A night scored `.asserted` against a shorter archive would otherwise keep
        // that verdict forever (🟢 2026-08-24: 1350 s of a "proven hole" had records under it within
        // the hour). `LocalStore.rederiveEditedNightProvenance` upgrades the stored LABELS and
        // queues a reconcile, so the edit stays authoritative here and the correction still lands.
        if row?.isManuallyEdited == true { return .unchanged }
        // Don't let a thinner drain fragment shrink Health below the merge-protected card: if the card
        // (summary) is fuller than this staging, `SleepSummaryMerge` kept the older, fuller night — so
        // this staging is a partial re-drain, not a correction. Skip it (a hair of epoch tolerance
        // keeps a benign reclassification from tripping the guard).
        if let row {
            let currentAsleep = SleepStaging.totalAsleep(segments)
            let cardAsleep = TimeInterval(row.asleepMin) * 60
            if currentAsleep + TimeInterval(BulkRecord.epochSeconds) < cardAsleep { return .unchanged }
        }
        // Sleep sharing EXPLICITLY denied → we can never write; surface as a failure (the card's
        // "hasn't synced" note). `.notDetermined` falls through and the write throws until granted.
        if store.authorizationStatus(for: HKCategoryType(.sleepAnalysis)) == .sharingDenied {
            return .failed
        }

        // A COVERAGE-DRIVEN SHRINK MUST NEVER DRIVE THIS PATH'S DELETE. Step 2 below deletes across a
        // SPAN, with no withheld-ground protection, because nothing that reaches here should ever
        // carry withheld ground: `SleepStaging.classify` emits only `.measured`, and an edited night
        // returned at the guard above. If that ever stops being true, this path would write a filtered
        // night and then delete the span it declined to fill — the exact irreversible shape of M2. Bail
        // instead; the edit reconcile, which IS protected, owns any night with asserted time.
        // (Nothing is withheld as of 2026-08-24, so the shrink is currently unreachable from either
        // path — this stays because the bail is ALSO the ownership rule, and the ownership rule is
        // what keeps asserted nights on the one path that tags them and tracks their sample UUIDs.)
        if segments.containsAssertedTime { return .unchanged }

        let signature = Self.sleepSignature(segments)
        let last = local.mirroredNight(night: night)
        // Health already reflects this exact staging — nothing to do (the common steady-state).
        if last?.signature == signature { return .unchanged }

        // 1. WRITE the current staging FIRST. A throw here leaves the prior night intact → no loss.
        let fresh: [String]
        do { fresh = try await writeReturningSleepUUIDs(segments) }
        catch { return .failed }

        // 1b. An edit could have landed DURING the write's await (both run on the main actor). If the
        //     night is now edited, don't delete or record — leave the raw samples we just wrote for the
        //     edit reconcile's recorded-span cleanup to replace, so the user's edit wins.
        if (try? local.sleepSummary(night: night))?.isManuallyEdited == true { return .unchanged }

        // 2. DELETE the prior copy across the UNION of the last-mirrored, current, and RECORDED in-bed
        //    spans (so a re-stage that SHRANK the night, or a wider pre-overlay write, is still
        //    cleared), nap-safe and excluding the fresh write.
        let cleanStart = min(start, last?.spanStart ?? start, row?.inBedStart ?? start)
        let cleanEnd = max(end, last?.spanEnd ?? end, row?.inBedEnd ?? end)
        let napWindows = local.healthWrittenNapWindows(overlapping: cleanStart, to: cleanEnd)
        // Record the signature regardless of the delete's outcome: the correct night is already in
        // Health (write-first), so recording avoids re-writing it every flush. A delete failure leaves
        // a duplicate that Health de-overlaps in the asleep total and that the next re-stage's union
        // delete removes; retrying the whole write would only pile up more duplicates.
        do {
            try await deleteNightSleep(from: cleanStart, to: cleanEnd,
                                       napWindows: napWindows, keeping: fresh)
        } catch {
            // best-effort; see note above
        }
        local.setMirroredNight(night: night, signature: signature, spanStart: cleanStart, spanEnd: cleanEnd)
        try? local.forceSleepCursorAtLeast(end)
        try? local.markSleepEditHealthCovered(by: segments)
        return .wrote(segments.count)
    }

    /// Delete this app's sleep samples in `[start, end]`, EXCLUDING the freshly-written samples and
    /// every Health-written nap window. Same nap-safe, own-samples-only predicate as the edit path's
    /// transition cleanup, but it THROWS so the caller can tell whether the prior copy was removed.
    private func deleteNightSleep(from start: Date, to end: Date,
                                  napWindows: [DateInterval], keeping newUUIDs: [String]) async throws {
        guard end > start else { return }
        let type = HKCategoryType(.sleepAnalysis)
        var subs: [NSPredicate] = [
            HKQuery.predicateForSamples(withStart: start, end: end, options: []),
        ]
        let keep = Set(newUUIDs.compactMap { UUID(uuidString: $0) })
        if !keep.isEmpty {
            subs.append(NSCompoundPredicate(
                notPredicateWithSubpredicate: HKQuery.predicateForObjects(with: keep)))
        }
        for window in napWindows {
            subs.append(NSCompoundPredicate(notPredicateWithSubpredicate:
                HKQuery.predicateForSamples(withStart: window.start, end: window.end, options: [])))
        }
        let pred = subs.count == 1 ? subs[0] : NSCompoundPredicate(andPredicateWithSubpredicates: subs)
        _ = try await store.deleteObjects(of: type, predicate: pred)
    }

    /// A stable (launch-invariant) content signature of a night's staged segments: the sorted set of
    /// (start, end, HealthKit stage value). Changes whenever the staging changes in any Health-visible
    /// way — including an interior reclassification that keeps the asleep TOTAL constant — so the
    /// mirror re-writes exactly when it must and no-ops otherwise. FNV-1a (not Swift's per-launch
    /// `Hasher`, which is seeded and would force a needless rewrite every launch).
    static func sleepSignature(_ segments: [SleepSegment]) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        func mix(_ value: Int) {
            var bits = UInt64(bitPattern: Int64(value))
            for _ in 0..<8 {
                hash = (hash ^ (bits & 0xff)) &* 0x100000001b3
                bits >>= 8
            }
        }
        // TOTAL order (start, then end, then stage): segments routinely share a start — the in-bed
        // span and the leading latency-awake both begin at bedtime — so sorting by start alone is
        // ambiguous and would make the signature depend on input order (spurious rewrites). Ordering
        // by all three fields makes it a pure function of the segment SET.
        let ordered = segments.sorted { a, b in
            if a.start != b.start { return a.start < b.start }
            if a.end != b.end { return a.end < b.end }
            return sleepValue(a.stage).rawValue < sleepValue(b.stage).rawValue
        }
        for seg in ordered {
            mix(Int(seg.start.timeIntervalSince1970.rounded()))
            mix(Int(seg.end.timeIntervalSince1970.rounded()))
            mix(sleepValue(seg.stage).rawValue)
        }
        return String(hash, radix: 16)
    }

    static func sleepValue(_ stage: SleepStage) -> HKCategoryValueSleepAnalysis {
        switch stage {
        case .inBed: return .inBed
        case .awake: return .awake
        case .asleepCore: return .asleepCore
        case .asleepDeep: return .asleepDeep
        case .asleepREM: return .asleepREM
        }
    }

    /// Write one correlated blood-pressure estimate to Apple Health.
    @discardableResult
    func writeBPEstimate(sbp: Double, dbp: Double, at date: Date) async -> Bool {
        let metadata: [String: Any] = ["OpenCircuitBPSource": "RingPPGCalibration"]
        let mmHg = HKUnit.millimeterOfMercury()
        let systolic = HKQuantitySample(
            type: Self.systolicType,
            quantity: HKQuantity(unit: mmHg, doubleValue: sbp),
            start: date,
            end: date,
            metadata: metadata
        )
        let diastolic = HKQuantitySample(
            type: Self.diastolicType,
            quantity: HKQuantity(unit: mmHg, doubleValue: dbp),
            start: date,
            end: date,
            metadata: metadata
        )
        let correlation = HKCorrelation(
            type: Self.bloodPressureType,
            start: date,
            end: date,
            objects: [systolic, diastolic],
            metadata: metadata
        )
        do {
            try await store.save(correlation)
            return true
        } catch {
            return false
        }
    }
}

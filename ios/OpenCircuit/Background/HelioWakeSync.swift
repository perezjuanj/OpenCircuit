import Foundation
import OpenCircuitKit
import UIKit

// Decision 33 (#233): the strap wakes the app; BGTasks are the backstop. Build 59's first night showed
// why: iOS granted the BGTasks only when it predicted the app would be opened, which is when they stop
// mattering. With the authenticated link kept up in the background (B.5) and a standing connect armed
// whenever it drops, these can wake a suspended app, and each runs at most one bounded catch-up sync:
//   • the link coming back (a pending connect completing, or a state-restoration relaunch), after
//     `reconnectCatchUpAfter` without a completed sync (ZEPP_PROTOCOL.md §16.3–§16.4: no strap message
//     is a dependable wake source). B.5 holds the link up, so a strap worn in range all night never
//     reconnects (decision 35);
//   • for that held link, anything the strap sends on its own over it (decision 35, `idleTraffic`),
//     gated exactly like a reconnect. Not dependable either: an idle authenticated link carries no
//     heart-rate stream (that needs `04 01` plus a `04 02` from the phone every second, §7.1, which
//     would be manufactured traffic), so this fires only if the strap pings or sends a §16.2 message;
//   • HealthKit delivering new iPhone steps (`HelioHealthWake`), for strap users who turned it on: the
//     only wake that doesn't depend on the strap;
//   • the strap's woke-up event (`06 00` on `0x001D`), an opportunistic hint only (§16.4: 🔴 whether
//     the Helio sends it). Nothing depends on it, and it carries no time: the catch-up fetches history
//     and only the night selection writes sleep.
// A catch-up is a `HelioBackgroundSyncService` run (the BGTask's budget, `03 09` acks and teardown, and
// the Health flush) under a `beginBackgroundTask` assertion. Every reconnect re-runs auth and setup
// with a fresh session (§4–§5, §9). Nothing here makes the strap talk: no realtime stream, no strap
// setting, no keep-alive traffic.

/// Decision 33's rules for when a wake syncs, pure so they test without CoreBluetooth or UIKit.
enum HelioWakePolicy {
    /// A catch-up's run budget from what is left of its assertion: the full `defaultTimeout` at most,
    /// less a margin for the alert passes that follow the run. A fixed 28 s inside a ~30 s assertion
    /// left the alerts no time, so iOS expired the assertion and the round was acked `03 09` unsaved.
    static let afterRunReserve: TimeInterval = 4
    static let minimumCatchUp: TimeInterval = 10
    @MainActor static func catchUpTimeout(backgroundTimeRemaining: TimeInterval) -> TimeInterval {
        min(RingBackgroundSyncService.defaultTimeout,
            max(minimumCatchUp, backgroundTimeRemaining - afterRunReserve))
    }

    /// N: a background reconnect (or restoration relaunch) catches up only when the last completed strap
    /// sync is at least this old. A strap that briefly leaves range (a shower, another room) reconnects
    /// many times a day, and syncing on each would cost the strap's battery and the app's background
    /// time for a few minutes of data; four hours is longer than those absences and shorter than any
    /// night, so a drop overnight and a reconnect in the morning always catch up. Daytime freshness
    /// comes from the BGTasks, the Health delivery wake and opening the app.
    static let reconnectCatchUpAfter: TimeInterval = 4 * 3600
    /// No reconnect catch-up within this long of the last background strap run's start: the reconnect
    /// that follows a run's own teardown, or a flapping link, must not chain run after run.
    static let reconnectCooldown: TimeInterval = 30 * 60
    /// A Health delivery wake skips the sync when one completed this recently: there is nothing to
    /// catch up, and iOS delivers steps right after the app's own activity too.
    static let healthDeliveryFreshness: TimeInterval = 10 * 60

    enum Action: Equatable {
        /// Nothing to do; `reason` is for the breadcrumb.
        case skip(String)
        /// The app is in front: the session syncs the ordinary way and its own hook flushes.
        case syncInForeground
        /// One bounded background catch-up.
        case catchUp
    }

    /// The skip reason while the app records a strap workout (#227, review-238 B1).
    static let workoutHoldsStrapReason = "a strap workout holds the strap"
    /// The skip reason inside `reconnectCooldown` of the last background run's start.
    static let cooldownReason = "a background run started under \(Int(reconnectCooldown / 60)) min ago"

    /// Decision 87d: when a woke-up event skipped for the cooldown asks for its app refresh: the later of
    /// the cooldown's end and a minute from now. nil for every other wake and every other action: the
    /// event is a hint to look again, never a finalization (decision 33: it carries no time).
    static func refreshAfterSkip(for wake: HelioWake, action: Action, lastBackgroundRunStart: Date?, now: Date) -> Date? {
        guard wake == .strapEvent, action == .skip(cooldownReason), let start = lastBackgroundRunStart else { return nil }
        return max(start.addingTimeInterval(reconnectCooldown), now.addingTimeInterval(60))
    }

    static func action(for wake: HelioWake, strapChosen: Bool, appIsActive: Bool, runActive: Bool,
                       lastCompletedSync: Date?, lastBackgroundRunStart: Date?, now: Date,
                       workoutHoldsStrap: Bool = false) -> Action {
        guard strapChosen else { return .skip("the strap isn't the chosen device") }
        // Review-238 B1: a strap workout's link carries its heart-rate stream until End. No wake (a
        // reconnect, a restoration, the woke-up hint, the Health step delivery, the stream's own traffic
        // on the held link) may sync, tear down or disconnect it; the sync the workout held back runs
        // when it ends (`StrapWorkoutRecorder.end`).
        if workoutHoldsStrap { return .skip(workoutHoldsStrapReason) }
        if appIsActive {
            // In front, a connect made there syncs on connect, and a session that came up in the
            // background syncs when the app comes to the front (`HelioActivationSync`, review-225e
            // SF-1); only the woke-up event asks for a sync here.
            return wake == .strapEvent ? .syncInForeground : .skip("the app is in front")
        }
        if runActive { return .skip("a background run already holds the strap") }
        switch wake {
        case .strapEvent:
            // Review-235 S3: a woke-up event can repeat at every night-time awakening; at most one
            // event-triggered catch-up per cooldown.
            if let start = lastBackgroundRunStart, now >= start, now.timeIntervalSince(start) < reconnectCooldown {
                return .skip(cooldownReason)
            }
            return .catchUp
        case .reconnect, .restoration, .idleTraffic:
            if let last = lastCompletedSync, now.timeIntervalSince(last) < reconnectCatchUpAfter, now >= last {
                return .skip("last completed sync under \(Int(reconnectCatchUpAfter / 3600)) h ago")
            }
            if let start = lastBackgroundRunStart, now >= start, now.timeIntervalSince(start) < reconnectCooldown {
                return .skip(cooldownReason)
            }
            return .catchUp
        case .healthDelivery:
            if let last = lastCompletedSync, now >= last, now.timeIntervalSince(last) < healthDeliveryFreshness {
                return .skip("synced under \(Int(healthDeliveryFreshness / 60)) min ago")
            }
            return .catchUp
        case .appRefresh, .processing, .sleepFocus, .foreground:
            return .skip("not a wake source")
        }
    }

    /// The run-log kind of a catch-up: CoreBluetooth wakes are `.cbWake`; the Health delivery wake is
    /// logged as a background sync.
    static func kind(for wake: HelioWake) -> TaskRecord.Kind {
        wake == .healthDelivery ? .backgroundSync : .cbWake
    }
}

/// Decision 35: the strap's own traffic over the held, idle link is a wake, gated like a reconnect by
/// `HelioWakePolicy`. This only keeps it from being evaluated on every packet: at most once per
/// `checkInterval`, never with the app in front, never during a sync's own traffic or while a
/// background run holds the strap. Nothing here makes the strap send anything.
struct HelioIdleTrafficGate {
    static let checkInterval: TimeInterval = 5 * 60
    private(set) var lastCheck: Date?

    /// `workoutHoldsStrap`: during a strap workout the link carries the heart-rate stream, which is the
    /// app's own traffic, never a wake (#227, review-238 B1).
    mutating func shouldCheck(now: Date, appIsActive: Bool, syncing: Bool, runActive: Bool,
                              workoutHoldsStrap: Bool = false) -> Bool {
        guard !appIsActive, !syncing, !runActive, !workoutHoldsStrap else { return false }
        if let last = lastCheck, now >= last, now.timeIntervalSince(last) < Self.checkInterval { return false }
        lastCheck = now
        return true
    }
}

/// The two moments the wake rules read, persisted: a catch-up decision is often made in a fresh process
/// (a restoration relaunch).
struct HelioWakeState {
    nonisolated static let lastCompletedSyncKey = "helio.lastCompletedSync.v1"
    nonisolated static let lastBackgroundRunStartKey = "helio.lastBackgroundRunStart.v1"

    let defaults: UserDefaults
    init(_ defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// The last strap sync that ran to its end (not interrupted), foreground or background.
    var lastCompletedSync: Date? {
        get { date(Self.lastCompletedSyncKey) }
        nonmutating set { set(newValue, Self.lastCompletedSyncKey) }
    }

    /// The last background strap run's start (a BGTask, Sleep Focus or catch-up run).
    var lastBackgroundRunStart: Date? {
        get { date(Self.lastBackgroundRunStartKey) }
        nonmutating set { set(newValue, Self.lastBackgroundRunStartKey) }
    }

    private func date(_ key: String) -> Date? {
        let t = defaults.double(forKey: key)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    private func set(_ date: Date?, _ key: String) {
        if let date { defaults.set(date.timeIntervalSince1970, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}

/// Runs decision 33's catch-ups. One at a time; every path calls `done` exactly once (the Health
/// delivery wake's completion handler rides on it).
@MainActor
final class HelioWakeCoordinator {
    struct Environment {
        var strapChosen: @MainActor () -> Bool
        var appIsActive: @MainActor () -> Bool
        /// A background run (BGTask, Sleep Focus or catch-up) holds the strap.
        var runActive: @MainActor () -> Bool
        var state: HelioWakeState
        var now: @MainActor () -> Date
        /// The app is in front and the strap woke up: an ordinary sync on the live session.
        var syncInForeground: @MainActor () -> Void
        /// `UIApplication.beginBackgroundTask`: the token, and the expiry handler iOS calls first.
        var beginAssertion: @MainActor (_ expired: @escaping @MainActor () -> Void) -> Int
        var endAssertion: @MainActor (Int) -> Void
        /// One bounded background run for `wake`; nil when it couldn't start (no store yet).
        var run: @MainActor (_ wake: HelioWake) async -> HelioBackgroundRun?
        /// iOS is ending the assertion: in this call, before the app is suspended, queue the open
        /// round's `03 09`, end the fetch, issue the link cancel and arm the standing connect (its
        /// `connect` goes out when the cancel lands; `HelioBackgroundLink.tearDownForExpiry`).
        var expire: @MainActor () -> Void
        /// After a run: the alert passes, and the margin re-aim.
        var afterRun: @MainActor (HelioBackgroundRun) async -> Void
        /// A breadcrumb line.
        var note: @MainActor (HelioWake, String) -> Void
        /// The app records a strap workout (#227): every wake skips (review-238 B1).
        var workoutHoldsStrap: @MainActor () -> Bool = { StrapWorkoutRecorder.holdsStrapLink }
        /// Decision 87d: a woke-up event skipped for the cooldown asks for an app refresh at this date
        /// (`StrapNightRefresh.recordAfterSkippedWokeUp` in the app); false when an earlier pending one
        /// was kept. A no-op in tests that don't drive it.
        var requestRefresh: @MainActor (_ notBefore: Date, _ now: Date) -> Bool = { _, _ in false }
        /// Decision 87d: the woke-up event's skip line, outside the breadcrumb budget
        /// (`HelioBreadcrumbs.wokeUpSkipped` in the app); nil: through `note`, like every other line.
        var noteWokeUpSkip: (@MainActor (String) -> Void)? = nil
    }

    static let shared = HelioWakeCoordinator(.live)

    private let env: Environment
    private(set) var isRunning = false

    init(_ env: Environment) { self.env = env }

    /// A wake arrived. `done` is called exactly once, on every path: at once when nothing runs, after the
    /// catch-up otherwise, and from the expiry handler when iOS ends the background time first.
    func wake(_ wake: HelioWake, done: (@MainActor () -> Void)? = nil) {
        let once = Once(done)
        let action = HelioWakePolicy.action(
            for: wake, strapChosen: env.strapChosen(), appIsActive: env.appIsActive(),
            runActive: env.runActive() || isRunning, lastCompletedSync: env.state.lastCompletedSync,
            lastBackgroundRunStart: env.state.lastBackgroundRunStart, now: env.now(),
            workoutHoldsStrap: env.workoutHoldsStrap())
        switch action {
        case .skip(let reason):
            // Decision 87d: a woke-up event inside the cooldown isn't lost: it asks for an app refresh
            // at the cooldown's end (an earlier pending one is kept), so the morning's night is looked
            // at again even when no other wake comes.
            var text = "no catch-up: \(reason)"
            let now = env.now()
            if let at = HelioWakePolicy.refreshAfterSkip(for: wake, action: action,
                                                         lastBackgroundRunStart: env.state.lastBackgroundRunStart, now: now) {
                text += env.requestRefresh(at, now)
                    ? "; refresh requested in \(Int((at.timeIntervalSince(now) / 60).rounded(.up))) min"
                    : "; an earlier refresh is pending"
            }
            // A reconnect or Health delivery that has nothing to do is the common case: noted only
            // for the woke-up event, which should always lead somewhere, and for a workout's hold.
            if wake == .strapEvent, let noteWokeUpSkip = env.noteWokeUpSkip {
                noteWokeUpSkip(text)
            } else if wake == .strapEvent || reason == HelioWakePolicy.workoutHoldsStrapReason {
                env.note(wake, text)
            }
            once.call()
        case .syncInForeground:
            env.note(wake, "app in front; syncing the ordinary way")
            env.syncInForeground()
            once.call()
        case .catchUp:
            catchUp(wake, once)
        }
    }

    private func catchUp(_ wake: HelioWake, _ once: Once) {
        isRunning = true
        let box = TaskBox()
        let token = env.beginAssertion { [env, weak self] in
            // iOS is about to suspend the app: the teardown can't wait for the run's next turn.
            box.task?.cancel()
            env.expire()
            env.note(wake, "iOS ended the background time; open round acked 03 09 (queued), link cancel issued, standing connect armed")
            self?.finish(box, once)
        }
        box.token = token
        box.task = Task { @MainActor [env, weak self] in
            if let run = await env.run(wake), !Task.isCancelled {
                await env.afterRun(run)
            }
            self?.finish(box, once)
        }
    }

    private func finish(_ box: TaskBox, _ once: Once) {
        guard !box.finished else { return }
        box.finished = true
        isRunning = false
        if let token = box.token { env.endAssertion(token) }
        once.call()
    }

    @MainActor
    private final class TaskBox {
        var task: Task<Void, Never>?
        var token: Int?
        var finished = false
    }

    @MainActor
    private final class Once {
        private var body: (@MainActor () -> Void)?
        init(_ body: (@MainActor () -> Void)?) { self.body = body }
        func call() {
            let body = self.body
            self.body = nil
            body?()
        }
    }
}

extension HelioWakeCoordinator.Environment {
    /// The app's: the shared connection, `UIApplication`'s background-task assertion, the BGTask run.
    @MainActor static var live: Self {
        let connection = HelioConnection.shared
        return Self(
            strapChosen: { ActiveDeviceChoiceStore.persisted() == .helioStrap },
            appIsActive: { UIApplication.shared.applicationState == .active },
            runActive: { connection.activeBackgroundRuns > 0 },
            state: HelioWakeState(),
            now: { Date() },
            syncInForeground: { connection.session?.syncHistory(manual: false) },
            beginAssertion: { expired in
                UIApplication.shared.beginBackgroundTask(withName: "helio catch-up") {
                    MainActor.assumeIsolated { expired() }
                }.rawValue
            },
            endAssertion: { UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: $0)) },
            run: { wake in
                // #131: never the destructive `makeContainer()`.
                guard let store = try? OpenCircuitApp.backgroundStore() else {
                    connection.breadcrumbs.wakeNote(wake, "no store yet (before the first unlock?); not syncing")
                    return nil
                }
                let timeout = HelioWakePolicy.catchUpTimeout(
                    backgroundTimeRemaining: UIApplication.shared.backgroundTimeRemaining)
                return await HelioBackgroundSyncService.live(store: store).run(
                    kind: HelioWakePolicy.kind(for: wake), timeout: timeout, wake: wake)
            },
            expire: { connection.tearDownForExpiry() },
            afterRun: { run in await HelioWakeCoordinator.afterRun?(run) },
            note: { wake, text in connection.breadcrumbs.wakeNote(wake, text) },
            requestRefresh: { at, now in
                StrapNightRefresh.recordAfterSkippedWokeUp(at, now: now, scheduler: BackgroundRefreshScheduler())
            },
            noteWokeUpSkip: { text in connection.breadcrumbs.wokeUpSkipped(text) })
    }
}

extension HelioWakeCoordinator {
    /// The alert passes and re-aim after a catch-up, set at launch (`AppDelegate`).
    static var afterRun: (@MainActor (HelioBackgroundRun) async -> Void)?
}

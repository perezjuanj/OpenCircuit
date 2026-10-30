import BackgroundTasks
import OpenCircuitKit
import XCTest
import ZeppKit
@testable import OpenCircuit

// Decision 33 (#233): when a wake syncs, and the catch-up coordinator's guarantees (one at a time,
// `done` exactly once on every path, the background assertion always ended). The end-to-end woke-up
// test against the simulated strap is in `HelioBackgroundSyncTests`. Every time is synthetic.

@MainActor
final class HelioWakeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_789_862_400 + 7 * 3600)

    private func action(_ wake: HelioWake, strapChosen: Bool = true, appIsActive: Bool = false, runActive: Bool = false,
                        lastSync: TimeInterval? = nil, lastRun: TimeInterval? = nil) -> HelioWakePolicy.Action {
        HelioWakePolicy.action(for: wake, strapChosen: strapChosen, appIsActive: appIsActive, runActive: runActive,
                               lastCompletedSync: lastSync.map { now.addingTimeInterval(-$0) },
                               lastBackgroundRunStart: lastRun.map { now.addingTimeInterval(-$0) }, now: now)
    }

    // MARK: Policy

    func testTheWokeUpEventAlwaysCatchesUpInTheBackground() {
        XCTAssertEqual(action(.strapEvent), .catchUp)
        XCTAssertEqual(action(.strapEvent, lastSync: 60), .catchUp, "the night just ended: no freshness gate")
        XCTAssertEqual(action(.strapEvent, lastRun: 29 * 60), .skip("a background run started under 30 min ago"),
                       "review-235 S3: at most one event-triggered catch-up per cooldown")
        XCTAssertEqual(action(.strapEvent, lastRun: 30 * 60), .catchUp)
        XCTAssertEqual(action(.strapEvent, appIsActive: true), .syncInForeground)
        XCTAssertEqual(action(.strapEvent, runActive: true), .skip("a background run already holds the strap"))
        XCTAssertEqual(action(.strapEvent, strapChosen: false), .skip("the strap isn't the chosen device"))
    }

    /// N = 4 h, and a 30-minute cooldown after a background run's start (the reconnect after its own
    /// teardown, or a flapping link).
    func testAReconnectCatchesUpOnlyAfterFourHoursWithoutASync() {
        for wake in [HelioWake.reconnect, .restoration, .idleTraffic] {
            XCTAssertEqual(action(wake), .catchUp, "never synced")
            XCTAssertEqual(action(wake, lastSync: 3 * 3600 + 59 * 60), .skip("last completed sync under 4 h ago"))
            XCTAssertEqual(action(wake, lastSync: 4 * 3600), .catchUp)
            XCTAssertEqual(action(wake, lastSync: 9 * 3600, lastRun: 29 * 60), .skip("a background run started under 30 min ago"))
            XCTAssertEqual(action(wake, lastSync: 9 * 3600, lastRun: 30 * 60), .catchUp)
            XCTAssertEqual(action(wake, appIsActive: true), .skip("the app is in front"),
                           "in front: a connect made there syncs on connect; one made in the background syncs on activation (SF-1)")
        }
        XCTAssertEqual(HelioWakePolicy.reconnectCatchUpAfter, 4 * 3600)
    }

    func testAHealthDeliveryCatchesUpUnlessASyncJustCompleted() {
        XCTAssertEqual(action(.healthDelivery), .catchUp)
        XCTAssertEqual(action(.healthDelivery, lastSync: 9 * 60), .skip("synced under 10 min ago"))
        XCTAssertEqual(action(.healthDelivery, lastSync: 10 * 60), .catchUp)
        XCTAssertEqual(action(.healthDelivery, appIsActive: true), .skip("the app is in front"))
        XCTAssertEqual(action(.healthDelivery, strapChosen: false), .skip("the strap isn't the chosen device"), "ring users")
        XCTAssertEqual(HelioWakePolicy.kind(for: .healthDelivery), .backgroundSync)
        XCTAssertEqual(HelioWakePolicy.kind(for: .strapEvent), .cbWake)
        XCTAssertEqual(HelioWakePolicy.kind(for: .reconnect), .cbWake)
    }

    /// Decision 35's debounce: the idle link's traffic is looked at no more than every 5 minutes, and
    /// never in front, during a sync, or while a run holds the strap.
    func testIdleLinkTrafficIsCheckedAtMostEveryFiveMinutes() {
        var gate = HelioIdleTrafficGate()
        XCTAssertFalse(gate.shouldCheck(now: now, appIsActive: true, syncing: false, runActive: false))
        XCTAssertFalse(gate.shouldCheck(now: now, appIsActive: false, syncing: true, runActive: false))
        XCTAssertFalse(gate.shouldCheck(now: now, appIsActive: false, syncing: false, runActive: true))
        XCTAssertTrue(gate.shouldCheck(now: now, appIsActive: false, syncing: false, runActive: false))
        XCTAssertFalse(gate.shouldCheck(now: now.addingTimeInterval(1), appIsActive: false, syncing: false, runActive: false))
        XCTAssertFalse(gate.shouldCheck(now: now.addingTimeInterval(299), appIsActive: false, syncing: false, runActive: false))
        XCTAssertTrue(gate.shouldCheck(now: now.addingTimeInterval(300), appIsActive: false, syncing: false, runActive: false))
        XCTAssertEqual(HelioWakePolicy.kind(for: .idleTraffic), .cbWake)
    }

    // MARK: #233 item 5: the refresh after a held night

    private func night(endingAt end: Date) -> HelioSleepSelection.Night {
        let start = end.addingTimeInterval(-7 * 3600)
        return HelioSleepSelection.Night(segments: [SleepSegment(start: start, end: end, stage: .asleepCore)],
                                         window: DateInterval(start: start, end: end), strapScore: 80)
    }

    func testAHeldNightAimsTheNextRefreshAtItsMarginsEnd() {
        let held = night(endingAt: now.addingTimeInterval(-5 * 60))
        let settled = night(endingAt: now.addingTimeInterval(-3 * 3600))
        XCTAssertEqual(StrapNightRefresh.aim(nights: [settled, held], focusEndedAt: nil, flushStartedAt: now, afterWokeUp: false),
                       now.addingTimeInterval(15 * 60), "the held night's end + 20 min")
        XCTAssertNil(StrapNightRefresh.aim(nights: [settled], focusEndedAt: nil, flushStartedAt: now, afterWokeUp: false))
        XCTAssertNil(StrapNightRefresh.aim(nights: [], focusEndedAt: nil, flushStartedAt: now, afterWokeUp: false))
        XCTAssertNil(StrapNightRefresh.aim(nights: [held], focusEndedAt: now.addingTimeInterval(-60), flushStartedAt: now,
                                           afterWokeUp: false), "finalized by Sleep Focus (decision 31): written already")
        XCTAssertEqual(StrapNightRefresh.aim(nights: [held], focusEndedAt: now.addingTimeInterval(-31 * 60), flushStartedAt: now,
                                             afterWokeUp: false), now.addingTimeInterval(15 * 60), "a stale Focus end doesn't count")
        // After a woke-up catch-up the record may be late (§21.4): at least 30 min, one request for both.
        XCTAssertEqual(StrapNightRefresh.aim(nights: [], focusEndedAt: nil, flushStartedAt: now, afterWokeUp: true),
                       now.addingTimeInterval(30 * 60))
        XCTAssertEqual(StrapNightRefresh.aim(nights: [held], focusEndedAt: nil, flushStartedAt: now, afterWokeUp: true),
                       now.addingTimeInterval(30 * 60))
    }

    // MARK: Coordinator

    private final class Harness {
        var appIsActive = false
        var strapChosen = true
        var runActive = false
        var begun = 0
        var ended: [Int] = []
        var expiry: (@MainActor () -> Void)?
        var runs: [HelioWake] = []
        var expired = 0
        var afterRuns = 0
        var foregroundSyncs = 0
        var notes: [String] = []
        /// The run waits for this (or for cancellation) before it returns.
        var release = false
        var ending: HelioBackgroundRun.Ending = .synced
    }

    private func coordinator(_ h: Harness, defaults: UserDefaults) -> HelioWakeCoordinator {
        HelioWakeCoordinator(.init(
            strapChosen: { h.strapChosen }, appIsActive: { h.appIsActive }, runActive: { h.runActive },
            state: HelioWakeState(defaults), now: { [now] in now },
            syncInForeground: { h.foregroundSyncs += 1 },
            beginAssertion: { expired in
                h.begun += 1
                h.expiry = expired
                return h.begun
            },
            endAssertion: { h.ended.append($0) },
            run: { wake in
                h.runs.append(wake)
                for _ in 0..<10_000 where !h.release && !Task.isCancelled { await Task.yield() }
                return HelioBackgroundRun(ending: Task.isCancelled ? .expired : h.ending)
            },
            expire: { h.expired += 1 },
            afterRun: { _ in h.afterRuns += 1 },
            note: { wake, text in h.notes.append("\(wake.rawValue): \(text)") }))
    }

    private func settle(_ until: () -> Bool) async {
        for _ in 0..<20_000 where !until() { await Task.yield() }
    }

    func testACatchUpRunsUnderOneAssertionAndCallsDoneOnce() async {
        let defaults = UserDefaults(suiteName: "HelioWakeTests.\(UUID().uuidString)")!
        let h = Harness()
        h.release = true
        var done = 0
        let wake = coordinator(h, defaults: defaults)
        wake.wake(.strapEvent) { done += 1 }
        XCTAssertTrue(wake.isRunning)
        await settle { done > 0 }
        XCTAssertEqual(h.runs, [.strapEvent])
        XCTAssertEqual(h.begun, 1)
        XCTAssertEqual(h.ended, [1])
        XCTAssertEqual(h.afterRuns, 1)
        XCTAssertEqual(done, 1)
        XCTAssertFalse(wake.isRunning)
    }

    /// Every path that doesn't run calls `done` at once, with no assertion (the Health delivery
    /// completion handler rides on it).
    func testEveryPathThatDoesntRunCallsDoneAtOnce() {
        let defaults = UserDefaults(suiteName: "HelioWakeTests.\(UUID().uuidString)")!
        HelioWakeState(defaults).lastCompletedSync = now.addingTimeInterval(-60)
        let h = Harness()
        let wake = coordinator(h, defaults: defaults)
        var done = 0
        wake.wake(.healthDelivery) { done += 1 }               // synced a minute ago
        h.strapChosen = false
        wake.wake(.healthDelivery) { done += 1 }               // ring chosen
        h.strapChosen = true
        h.runActive = true
        wake.wake(.strapEvent) { done += 1 }                   // a BGTask run holds the strap
        h.runActive = false
        h.appIsActive = true
        wake.wake(.strapEvent) { done += 1 }                   // in front: an ordinary sync
        wake.wake(.reconnect) { done += 1 }
        XCTAssertEqual(done, 5)
        XCTAssertEqual(h.begun, 0)
        XCTAssertEqual(h.runs, [])
        XCTAssertEqual(h.foregroundSyncs, 1)
        XCTAssertEqual(h.notes, ["strapEvent: no catch-up: a background run already holds the strap",
                                 "strapEvent: app in front; syncing the ordinary way"])
    }

    /// One catch-up at a time: a second wake while one runs is done at once.
    func testASecondWakeWhileACatchUpRunsIsDoneAtOnce() async {
        let defaults = UserDefaults(suiteName: "HelioWakeTests.\(UUID().uuidString)")!
        let h = Harness()
        let wake = coordinator(h, defaults: defaults)
        var first = 0, second = 0
        wake.wake(.strapEvent) { first += 1 }
        await settle { !h.runs.isEmpty }
        wake.wake(.healthDelivery) { second += 1 }
        XCTAssertEqual(second, 1)
        XCTAssertEqual(h.begun, 1)
        h.release = true
        await settle { first > 0 }
        XCTAssertEqual(first, 1)
        XCTAssertEqual(h.runs, [.strapEvent])
    }

    /// iOS ends the background time first: the teardown runs synchronously, the assertion is ended and
    /// `done` called from the expiry handler, and the cancelled run's return calls neither again.
    func testAnExpiryTearsDownEndsTheAssertionAndCallsDoneOnce() async {
        let defaults = UserDefaults(suiteName: "HelioWakeTests.\(UUID().uuidString)")!
        let h = Harness()
        let wake = coordinator(h, defaults: defaults)
        var done = 0
        wake.wake(.healthDelivery) { done += 1 }
        await settle { !h.runs.isEmpty }
        h.expiry?()
        XCTAssertEqual(h.expired, 1)
        XCTAssertEqual(h.ended, [1])
        XCTAssertEqual(done, 1, "the completion handler is called before the app is suspended")
        XCTAssertFalse(wake.isRunning)
        await Task.yield()
        for _ in 0..<200 { await Task.yield() }
        XCTAssertEqual(h.ended, [1], "ended once")
        XCTAssertEqual(done, 1, "called once")
        XCTAssertEqual(h.afterRuns, 0, "no alert pass after an expiry")
        XCTAssertTrue(h.notes.contains { $0.contains("iOS ended the background time") })
    }

    /// The wake state persists, so a restoration relaunch (a new process) sees the last sync.
    func testTheWakeStatePersists() {
        let defaults = UserDefaults(suiteName: "HelioWakeTests.\(UUID().uuidString)")!
        HelioWakeState(defaults).lastCompletedSync = now
        HelioWakeState(defaults).lastBackgroundRunStart = now.addingTimeInterval(-60)
        XCTAssertEqual(HelioWakeState(defaults).lastCompletedSync, now)
        XCTAssertEqual(HelioWakeState(defaults).lastBackgroundRunStart, now.addingTimeInterval(-60))
    }
}

// MARK: - Decision 87d (#352): a woke-up event skipped for the cooldown asks for a refresh

/// What the app asked iOS for (the refresh a skipped woke-up event records).
private final class WokeUpRefreshRecorder: BGTaskScheduling {
    private(set) var submitted: BGTaskRequest?
    func register(forTaskWithIdentifier identifier: String, using queue: DispatchQueue?,
                  launchHandler: @escaping (BGTask) -> Void) -> Bool { true }
    func cancel(taskRequestWithIdentifier identifier: String) {}
    func submit(_ taskRequest: BGTaskRequest) throws { submitted = taskRequest }
}

extension HelioWakeTests {
    /// The refresh comes at the later of the cooldown's end and a minute from now; only for the woke-up
    /// event and only for the cooldown's skip.
    func testTheSkippedWokeUpEventAimsItsRefreshAtTheCooldownsEnd() {
        let start = now.addingTimeInterval(-10 * 60)
        let skip = HelioWakePolicy.Action.skip(HelioWakePolicy.cooldownReason)
        XCTAssertEqual(HelioWakePolicy.cooldownReason, "a background run started under 30 min ago")
        XCTAssertEqual(HelioWakePolicy.refreshAfterSkip(for: .strapEvent, action: skip, lastBackgroundRunStart: start, now: now),
                       start.addingTimeInterval(30 * 60))
        let nearEnd = now.addingTimeInterval(-(30 * 60 - 20))
        XCTAssertEqual(HelioWakePolicy.refreshAfterSkip(for: .strapEvent, action: skip, lastBackgroundRunStart: nearEnd, now: now),
                       now.addingTimeInterval(60), "at least a minute away")
        for wake in [HelioWake.reconnect, .restoration, .idleTraffic, .healthDelivery] {
            XCTAssertNil(HelioWakePolicy.refreshAfterSkip(for: wake, action: skip, lastBackgroundRunStart: start, now: now), wake.rawValue)
        }
        XCTAssertNil(HelioWakePolicy.refreshAfterSkip(for: .strapEvent, action: .skip("a background run already holds the strap"),
                                                      lastBackgroundRunStart: start, now: now))
        XCTAssertNil(HelioWakePolicy.refreshAfterSkip(for: .strapEvent, action: .catchUp, lastBackgroundRunStart: start, now: now))
    }

    private func wokeUpCoordinator(_ h: Harness, defaults: UserDefaults, scheduler: BackgroundRefreshScheduler,
                                   skipLines: @escaping (String) -> Void) -> HelioWakeCoordinator {
        HelioWakeCoordinator(.init(
            strapChosen: { h.strapChosen }, appIsActive: { h.appIsActive }, runActive: { h.runActive },
            state: HelioWakeState(defaults), now: { [now] in now },
            syncInForeground: { h.foregroundSyncs += 1 },
            beginAssertion: { _ in h.begun += 1; return h.begun },
            endAssertion: { h.ended.append($0) },
            run: { wake in
                h.runs.append(wake)
                return HelioBackgroundRun(ending: .synced)
            },
            expire: { h.expired += 1 },
            afterRun: { _ in h.afterRuns += 1 },
            note: { wake, text in h.notes.append("\(wake.rawValue): \(text)") },
            requestRefresh: { at, now in
                StrapNightRefresh.recordAfterSkippedWokeUp(at, now: now, scheduler: scheduler, defaults: defaults)
            },
            noteWokeUpSkip: skipLines))
    }

    /// A woke-up event 10 minutes after a background run started: skipped, and a refresh is recorded at
    /// the cooldown's end (so `schedule()` keeps it). The skip line says so, outside the budget.
    func testAWokeUpEventInsideTheCooldownRecordsARefreshAtItsEnd() {
        let defaults = UserDefaults(suiteName: "HelioWakeTests.\(UUID().uuidString)")!
        HelioWakeState(defaults).lastBackgroundRunStart = now.addingTimeInterval(-10 * 60)
        let recorder = WokeUpRefreshRecorder()
        let scheduler = BackgroundRefreshScheduler(scheduler: recorder, now: { [now] in now }, window: { _ in nil })
        let h = Harness()
        var lines: [String] = []
        var done = 0
        wokeUpCoordinator(h, defaults: defaults, scheduler: scheduler, skipLines: { lines.append($0) }).wake(.strapEvent) { done += 1 }
        XCTAssertEqual(done, 1)
        XCTAssertEqual(h.runs, [], "skipped")
        let at = now.addingTimeInterval(20 * 60)
        XCTAssertEqual(StrapNightRefresh.pending(now: now, defaults: defaults), at)
        XCTAssertEqual(recorder.submitted?.earliestBeginDate, at)
        XCTAssertEqual(lines, ["no catch-up: a background run started under 30 min ago; refresh requested in 20 min"])
        XCTAssertEqual(h.notes, [], "not through the budgeted note")
    }

    /// An earlier pending refresh is kept (it looks again sooner); a later one gives way.
    func testAWokeUpSkipKeepsAnEarlierPendingRefresh() {
        for (pendingIn, kept) in [(5.0, true), (50.0, false)] {
            let defaults = UserDefaults(suiteName: "HelioWakeTests.\(UUID().uuidString)")!
            HelioWakeState(defaults).lastBackgroundRunStart = now.addingTimeInterval(-10 * 60)
            let recorder = WokeUpRefreshRecorder()
            let scheduler = BackgroundRefreshScheduler(scheduler: recorder, now: { [now] in now }, window: { _ in nil })
            let pending = now.addingTimeInterval(pendingIn * 60)
            StrapNightRefresh.record(pending, scheduler: scheduler, defaults: defaults)
            var lines: [String] = []
            wokeUpCoordinator(Harness(), defaults: defaults, scheduler: scheduler, skipLines: { lines.append($0) }).wake(.strapEvent)
            XCTAssertEqual(StrapNightRefresh.pending(now: now, defaults: defaults), kept ? pending : now.addingTimeInterval(20 * 60), "\(pendingIn)")
            XCTAssertEqual(lines, [kept ? "no catch-up: a background run started under 30 min ago; an earlier refresh is pending"
                                        : "no catch-up: a background run started under 30 min ago; refresh requested in 20 min"])
        }
    }

    /// 40 minutes after the run started: a catch-up, as before; nothing recorded. A reconnect inside the
    /// cooldown records nothing either.
    func testAWokeUpEventPastTheCooldownCatchesUpAndRecordsNothing() async {
        let defaults = UserDefaults(suiteName: "HelioWakeTests.\(UUID().uuidString)")!
        HelioWakeState(defaults).lastBackgroundRunStart = now.addingTimeInterval(-40 * 60)
        let recorder = WokeUpRefreshRecorder()
        let scheduler = BackgroundRefreshScheduler(scheduler: recorder, now: { [now] in now }, window: { _ in nil })
        let h = Harness()
        var lines: [String] = []
        var done = 0
        let coordinator = wokeUpCoordinator(h, defaults: defaults, scheduler: scheduler, skipLines: { lines.append($0) })
        coordinator.wake(.strapEvent) { done += 1 }
        for _ in 0..<20_000 where done == 0 { await Task.yield() }
        XCTAssertEqual(h.runs, [.strapEvent])
        XCTAssertNil(StrapNightRefresh.pending(now: now, defaults: defaults))
        XCTAssertNil(recorder.submitted)

        HelioWakeState(defaults).lastBackgroundRunStart = now.addingTimeInterval(-10 * 60)
        HelioWakeState(defaults).lastCompletedSync = now.addingTimeInterval(-5 * 3600)
        coordinator.wake(.reconnect)
        XCTAssertNil(StrapNightRefresh.pending(now: now, defaults: defaults), "only the woke-up event")
        XCTAssertEqual(lines, [])
    }
}


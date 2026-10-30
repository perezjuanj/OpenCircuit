import Foundation
import OpenCircuitKit
import UIKit
import ZeppKit

// The Amazfit Helio Strap's background sync (#215 phase 4, decision 26). The strap's counterpart of
// `RingBackgroundSyncService`, entered by the same wakes: the two existing BGTask identifiers and the
// Sleep Focus filter (AppDelegate, SleepFocusSyncFilter). CoreBluetooth state restoration is the
// third leg and needs no code here: `HelioConnection`'s own central relaunches the app, and a
// session that connects then syncs on its own (docs/BACKGROUND_SYNC.md Part B).
//
// One bounded run: connect if needed (by identifier, never a scan) → the session authenticates with
// the Keychain key, sets the clock and fetches (every round acked `03 09`, decision 8, and committed
// to `LocalStore` as it arrives) → flush to Apple Health → one line in the background-run log with a
// "helio strap:" label, plus a `bgphase` breadcrumb (B.4).
//
// Budget (B.3): the fetch gets the task's window minus `flushReserve`. When that runs out, or iOS
// expires the task, the open round is acked `03 09`, what was committed stays committed, the link is
// dropped cleanly (a running find gets its `06` first) and the rest stays on the strap for next time.
// Only an uninterrupted sync is followed by the Health flush inside the window; an abandoned one
// flushes only when the budget (not iOS) ended it. If the app is in front when the budget runs out,
// nothing is torn down: the sync is handed to the app, whose post-sync hook flushes it (review-225 S1).
//
// Key states (decision 7): no key, a rejected key (persisted), or a strap that ended busy in the last
// 20 minutes end the run before any radio work; a session that turns out keyless, rejected, busy or
// unsupported ends it quietly. No retry, no Health write, and the log says why. "Busy" lasts 20
// minutes (decision 78d, #316; it lasted the whole launch before): the next background run after that
// tries once more, and a Sleep Focus run always does. A strap still held latches again (review-225 F1).

/// Decision 31: Sleep Focus turning off at time T ("the night is over") lets the strap's nights skip
/// the 20-minute settle margin only in a Health flush that STARTS within `window` of T. Every path that
/// carries it (the Focus run itself, a waiting run's request on the link, a hand-off to a session, a
/// sync result an adopting run reads) carries T, and the decision is made in one place, where the
/// flush starts (`HelioConnection.healthFlush`). So a path that carries a stale T can only delay a
/// night (the margin applies), never write one early.
enum SleepFocusFinalization {
    /// Decision 31's window. It covers every legitimate use: the Focus run's own budget, a sync handed
    /// to the app (at most a 90 s stall), and a waiting run's request used by the active run.
    static let window: TimeInterval = 30 * 60

    /// Whether a flush starting at `flushStart` may skip the margin for a Focus that ended at `focusEnd`.
    static func applies(focusEndedAt focusEnd: Date?, flushStartsAt flushStart: Date) -> Bool {
        guard let focusEnd else { return false }
        return flushStart.timeIntervalSince(focusEnd) <= window
    }

    /// One T when two meet (a run's own and a waiting run's request, or a hand-off onto a session that
    /// already carries one): the latest. It is the most recent "the night is over", the one the flush
    /// answers; an earlier T only expires sooner, so keeping it would only delay a night that a real,
    /// later Focus end already allows.
    static func latest(_ a: Date?, _ b: Date?) -> Date? {
        [a, b].compactMap { $0 }.max()
    }

    // MARK: Decision 78a (#332): the persisted Focus end, judged per night

    /// Where the Sleep Focus wake persists T, for both devices (only the strap reads it).
    nonisolated static let persistedKey = "helio.sleepFocusEndedAt.v1"
    /// How long after T a flush may still use the persisted T: past the morning's last plausible
    /// wake, well short of the next night's end.
    static let persistedValidity: TimeInterval = 6 * 3600
    /// The slack after T (decision 78a, kept for both sources by decision 87a): a night that ends up to
    /// this long AFTER T is finalized. A strap record is read about 3 minutes behind its end (decision
    /// 58), so the record a sync reads at the Focus end, or at the wake that detects it, is covered.
    static let nightEndSlack: TimeInterval = 10 * 60

    /// Where a persisted T came from. Since decision 87a both finalize alike; the source is kept for
    /// the bundle's `Sleep Focus` line (78h S-1).
    enum Source: String, Equatable {
        /// `perform()` ran with the Focus off (or decision 31's in-memory T).
        case perform
        /// A wake read the filter not active after seeing it active (78f).
        case detected
    }

    /// The persisted T's source, beside `persistedKey`.
    nonisolated static let persistedSourceKey = "helio.sleepFocusEndedAt.source.v1"

    /// The Sleep Focus wake (ring and strap), or a wake that detected the end (decision 78f): Focus
    /// ended at `focusEnd`. One store for both paths, with its source: the latest wins, and it never
    /// moves backwards.
    static func persist(_ focusEnd: Date, source: Source = .perform, defaults: UserDefaults = .standard) {
        guard focusEnd > (persisted(defaults: defaults) ?? .distantPast) else { return }
        defaults.set(focusEnd.timeIntervalSince1970, forKey: persistedKey)
        defaults.set(source.rawValue, forKey: persistedSourceKey)
    }

    /// The persisted T's source; a T with none recorded is a `perform()` one.
    static func persistedSource(defaults: UserDefaults = .standard) -> Source {
        defaults.string(forKey: persistedSourceKey).flatMap(Source.init(rawValue:)) ?? .perform
    }

    /// The last persisted Focus end, or nil when none was ever recorded.
    static func persisted(defaults: UserDefaults = .standard) -> Date? {
        let t = defaults.double(forKey: persistedKey)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    /// Decision 87b: when a night's SLEEP began: its first asleep segment (core, deep or REM). The
    /// decision 77 lead-in is an `.inBed` and an `.awake` segment over one span, and an in-bed span
    /// with no sleep in it is `.inBed`/`.awake` only, so neither can ever be the sleep start, whether
    /// or not the lead-in is recognised as one. nil for a night with no asleep segment.
    static func sleepStart(of night: [SleepSegment]) -> Date? {
        night.filter { $0.stage == .asleepCore || $0.stage == .asleepDeep || $0.stage == .asleepREM }.map(\.start).min()
    }

    /// What one strap Health flush finalizes, per night, from the Focus ends that apply to it (each
    /// T: decision 31's in-memory one, the persisted one of either source). A night is over when, for
    /// some T, it ends by T plus `nightEndSlack` (decision 87a, both sources) or its sleep began before
    /// T (decision 87b: the night in progress when the Focus went off is over, whatever its end). A
    /// night finalized here skips the settle margin (`SleepHealthGate`) and the newest-night hold
    /// (decision 58a); every other night is judged by the normal rules. Every reader (the writer's gate
    /// and its 78c count, the 58a backstop, the refresh aim, 78b's Focus night) asks `finalizes`, so
    /// they can't disagree.
    struct Nights: Equatable {
        /// The `perform()` Focus end this flush answers (in memory or persisted), nil when none applies.
        let focusEnd: Date?
        /// A persisted T, not decision 31's in-memory one, applies (decision 78c's breadcrumb).
        let fromPersisted: Bool
        /// The detected Focus end this flush answers (78f), nil when none applies.
        var detectedEnd: Date? = nil

        static let none = Nights(focusEnd: nil, fromPersisted: false)

        /// Whether `night` (its segments, lead-in included or not) is over.
        func finalizes(_ night: [SleepSegment]) -> Bool {
            finalizes(sleepStart: SleepFocusFinalization.sleepStart(of: night), nightEndingAt: night.map(\.end).max())
        }

        /// The one rule: the night whose sleep began at `sleepStart` (nil: unknown) and whose last
        /// segment ends at `end` is over.
        func finalizes(sleepStart: Date?, nightEndingAt end: Date?) -> Bool {
            guard let end else { return false }
            return [focusEnd, detectedEnd].compactMap { $0 }.contains { t in
                end <= t.addingTimeInterval(SleepFocusFinalization.nightEndSlack)
                    || sleepStart.map { $0 < t } == true
            }
        }

        /// By the end alone (decision 87a): for a caller that knows no sleep start.
        func finalizes(nightEndingAt end: Date?) -> Bool {
            finalizes(sleepStart: nil, nightEndingAt: end)
        }
    }

    /// Decision 78a: the one place a strap flush's finalization is decided. `inMemory` is decision
    /// 31's T (the run's own, a waiter's or a hand-off's; always a `perform()` T), used while the flush
    /// starts within `window` of it; `persisted` is the stored T with its `source`, used by a flush
    /// that starts at or after it and within `persistedValidity`. Decision 87c: a Focus seen on after
    /// the persisted T (`seenActive`, 78f-1; a `perform()` Focus-on sets it too, 78f-4) voids it, for
    /// either source, until a new T is persisted: a misread "off" in the night stops finalizing at the
    /// next wake that reads the Focus on. Decision 31's in-memory T comes only from a `perform()` that
    /// just ran, and keeps working as before. Per night: `Nights.finalizes`.
    static func nights(inMemory: Date?, persisted: Date?, source: Source = .perform, seenActive: Date? = nil,
                       flushStartsAt flushStart: Date) -> Nights {
        let memory = applies(focusEndedAt: inMemory, flushStartsAt: flushStart) ? inMemory : nil
        let stored = persisted.flatMap { t in
            flushStart >= t && flushStart.timeIntervalSince(t) <= persistedValidity
                && !(seenActive.map { $0 > t } ?? false) ? t : nil
        }
        switch source {
        case .perform:
            guard let focusEnd = latest(memory, stored) else { return .none }
            return Nights(focusEnd: focusEnd, fromPersisted: memory == nil || focusEnd != memory)
        case .detected:
            guard memory != nil || stored != nil else { return .none }
            return Nights(focusEnd: memory, fromPersisted: memory == nil, detectedEnd: stored)
        }
    }

    /// `nights` from what `defaults` holds: the persisted T, its source and the seen-active time.
    /// What every strap flush site and the refresh verdict after it read, so they read alike.
    static func nights(inMemory: Date?, flushStartsAt flushStart: Date, defaults: UserDefaults) -> Nights {
        nights(inMemory: inMemory, persisted: persisted(defaults: defaults), source: persistedSource(defaults: defaults),
               seenActive: SleepFocusDetection.seenActive(defaults: defaults), flushStartsAt: flushStart)
    }

    /// The persisted T the 78c breadcrumb was last recorded for.
    nonisolated static let persistedWriteLoggedKey = "helio.sleepFocusEndedAt.logged.v1"

    /// Decision 78c: a flush wrote a night that only the persisted T finalized. One `focus` line per
    /// T, from the first such flush: how many minutes after Focus ended. Counts only.
    static func notePersistedWrite(focusEnd: Date, flushStart: Date, defaults: UserDefaults = .standard) {
        guard defaults.double(forKey: persistedWriteLoggedKey) != focusEnd.timeIntervalSince1970 else { return }
        defaults.set(focusEnd.timeIntervalSince1970, forKey: persistedWriteLoggedKey)
        let minutes = max(0, Int(flushStart.timeIntervalSince(focusEnd) / 60))
        ObservabilityStore(defaults).recordMetricEvent(
            source: "focus", detail: "night written from the Sleep Focus end, \(minutes) min after it")
    }
}

/// Decision 78d (#316): how long "the strap ended busy" holds. Decision 7 stands for a strap another
/// central really holds (the next try latches again), but one failed auth no longer stops every
/// background sync for the rest of the launch.
enum HelioBusyLatch {
    static let expiry: TimeInterval = 20 * 60

    /// A latch set at `since` still holds at `now`: set, and no older than `expiry`.
    static func holds(since: Date?, now: Date) -> Bool {
        guard let since else { return false }
        let age = now.timeIntervalSince(since)
        return age >= 0 && age <= expiry
    }
}

/// #233 item 5: when the next app-refresh should come after a strap flush, so a night the flush held
/// back doesn't wait for the next generic grant. nil when nothing is waiting.
enum StrapNightRefresh {
    /// After the strap's woke-up event the night's record may be late or partial (ZEPP_PROTOCOL.md
    /// §21.4): look again this much later.
    static let afterWokeUp: TimeInterval = 30 * 60

    /// The latest of: the end of the earliest held night's settle margin (a night the flush didn't
    /// write because its last segment ended under 20 minutes before the flush started, and no Sleep
    /// Focus finalization applied, decision 31), and, after a woke-up catch-up, `afterWokeUp`. One
    /// request covers both. The scheduler keeps it at least a minute away.
    ///
    /// `storedNightSettles` (decision 57b, #262): the margin end of the newest stored strap night not
    /// yet in Apple Health, read after the flush (`LocalStore.newestStrapNightSettles`). It counts as a
    /// held night even when this sync didn't carry it, so a sync whose strap had stopped re-delivering
    /// the night (an app opened right after a background wake stored it) asks for the same refresh
    /// instead of clearing it. Read after the flush, a night it wrote has its mirror record and is nil.
    ///
    /// Decision 78a: a night counts as held unless the flush's finalization (`SleepFocusFinalization.
    /// nights`, from `focusEndedAt`, `persistedFocusEnd` and the seen-active time, decision 87c) covers
    /// that night (`Nights.finalizes`: by its end, or by its sleep start, decision 87).
    static func aim(nights: [HelioSleepSelection.Night], storedNightSettles: Date? = nil, focusEndedAt: Date?,
                    persistedFocusEnd: Date? = nil, persistedSource: SleepFocusFinalization.Source = .perform,
                    focusSeenActive: Date? = nil, flushStartedAt: Date, afterWokeUp wokeUp: Bool) -> Date? {
        var candidates: [Date] = []
        let finalization = SleepFocusFinalization.nights(inMemory: focusEndedAt, persisted: persistedFocusEnd,
                                                         source: persistedSource, seenActive: focusSeenActive,
                                                         flushStartsAt: flushStartedAt)
        var held = nights.filter { !finalization.finalizes($0.segments) }
            .compactMap { $0.segments.map(\.end).max() }
            .filter { !SleepHealthGate.isSettled(latestSegmentEnd: $0, now: flushStartedAt) }
            .map { $0.addingTimeInterval(SleepHealthGate.settleMargin) }
        if let storedNightSettles { held.append(storedNightSettles) }
        if let earliest = held.min() { candidates.append(earliest) }
        if wokeUp { candidates.append(flushStartedAt.addingTimeInterval(afterWokeUp)) }
        return candidates.max()
    }

    // Review-225e SF-3: the app's own `schedule()` (scene → background, `applicationDidEnterBackground`,
    // the start of every BGTask) cancels and resubmits `bgrefresh` at the aimed date, which replaced a
    // margin request within seconds of a foreground sync. So the pending date is persisted (strap only)
    // and re-submitted after those calls.

    /// The pending margin refresh (strap only).
    nonisolated static let pendingKey = "helio.nightRefreshAt.v1"

    /// A strap flush's verdict: the refresh it wants, submitted and kept; or nil (no night is waiting:
    /// it was written, or none was held), which clears the pending one.
    static func record(_ aim: Date?, scheduler: BackgroundRefreshScheduler, defaults: UserDefaults = .standard) {
        if let aim {
            defaults.set(aim.timeIntervalSince1970, forKey: pendingKey)
            scheduler.scheduleRefresh(notBefore: aim)
        } else {
            defaults.removeObject(forKey: pendingKey)
        }
    }

    /// Decision 87d: a woke-up event skipped for the cooldown asks for a refresh at `at`. A pending
    /// refresh at or before `at` is kept (it looks again sooner); otherwise `at` is recorded, so the
    /// app's own `schedule()` doesn't replace it. Returns whether `at` was recorded.
    @discardableResult
    static func recordAfterSkippedWokeUp(_ at: Date, now: Date, scheduler: BackgroundRefreshScheduler,
                                         defaults: UserDefaults = .standard) -> Bool {
        if let pending = pending(now: now, defaults: defaults), pending <= at { return false }
        record(at, scheduler: scheduler, defaults: defaults)
        return true
    }

    /// The pending refresh while it is still ahead of `now`; one that has passed is cleared.
    static func pending(now: Date, defaults: UserDefaults = .standard) -> Date? {
        let t = defaults.double(forKey: pendingKey)
        guard t > 0 else { return nil }
        let date = Date(timeIntervalSince1970: t)
        guard date > now else {
            defaults.removeObject(forKey: pendingKey)
            return nil
        }
        return date
    }

    /// After `schedule()`: submit the pending margin refresh again, with the strap chosen and the date
    /// still ahead. With the ring chosen nothing happens, so the request stays exactly `schedule()`'s.
    @discardableResult
    static func resubmit(_ scheduler: BackgroundRefreshScheduler, strapChosen: Bool, now: Date = Date(),
                         defaults: UserDefaults = .standard) -> Bool {
        guard strapChosen, let at = pending(now: now, defaults: defaults) else { return false }
        return scheduler.scheduleRefresh(notBefore: at)
    }
}

/// Decision 78b/78c (#332): what a strap Sleep Focus run leaves behind, whatever its ending. The run
/// is one bounded wake; when it didn't get the night into Apple Health (the link was down, it
/// coalesced into a run that ran out of time, the strap was busy, the record was still in progress),
/// a refresh soon after Focus ended asks again, and the persisted T (78a) finalizes the night there.
enum SleepFocusStrapFollowUp {
    /// The night a Focus run was for, as the store has it after the run.
    enum Night: String {
        /// The newest stored strap night that T finalizes (it ended by T plus the slack, or its sleep
        /// began before T, decision 87b), and that ended within `nightLookback` before T, has a Health
        /// mirror record.
        case written
        /// It has none.
        case storedNotWritten = "stored-not-written"
        /// No such night is stored.
        case none
    }

    /// The retry refresh comes this long after Focus ended.
    static let retryAfter: TimeInterval = 15 * 60
    /// How long before T the night a Focus run was for may have ended.
    static let nightLookback: TimeInterval = 18 * 3600

    /// After the run. `expired`: iOS ended the task, so `schedule()` didn't run and nothing after it
    /// does: only the retry and the breadcrumb, which are synchronous. Otherwise this comes after
    /// `schedule()`: the run's own margin verdict (as before), then the retry, then the pending
    /// refresh is submitted again. The retry is recorded (so `schedule()` doesn't replace it, review-
    /// 225e SF-3) unless a refresh at or after it is already pending. Returns whether a retry is pending.
    @discardableResult
    static func finish(_ run: HelioBackgroundRun, focusEnd: Date, night: Night, expired: Bool,
                       scheduler: BackgroundRefreshScheduler, observability: ObservabilityStore,
                       defaults: UserDefaults = .standard, now: Date = Date()) -> Bool {
        if !expired, run.flushMS != nil { StrapNightRefresh.record(run.refreshAt, scheduler: scheduler, defaults: defaults) }
        var retry = false
        if night != .written {
            let at = focusEnd.addingTimeInterval(retryAfter)
            if let pending = StrapNightRefresh.pending(now: now, defaults: defaults), pending >= at {
                retry = true   // a later refresh is already pending: kept
            } else if at > now {
                StrapNightRefresh.record(at, scheduler: scheduler, defaults: defaults)
                retry = true
            }
        }
        observability.recordMetricEvent(source: "focus", detail: breadcrumb(ending: run.ending, night: night, retry: retry))
        if !expired { StrapNightRefresh.resubmit(scheduler, strapChosen: true, now: now, defaults: defaults) }
        return retry
    }

    /// Decision 78c: one line per strap Focus run. Counts only: no clock time of sleep, no value.
    static func breadcrumb(ending: HelioBackgroundRun.Ending, night: Night, retry: Bool) -> String {
        "ending=\(ending.label) night=\(night.rawValue) retry=\(retry ? "yes" : "no")"
    }
}

/// The run holding the link, as a later run sees it (#233 item 3: coalescing).
struct HelioActiveRun: Equatable {
    enum Stage: Equatable {
        /// In its watch loop: its sync can still be handed over.
        case watching
        /// Past it: tearing down or flushing. `synced`: its sync ran to its end.
        case finishing(synced: Bool)
    }

    let wake: HelioWake
    /// When its sync work must stop (its budget minus the flush reserve).
    let deadline: Date
    var stage: Stage = .watching
    /// A later run with a larger budget asked for the sync; the run hands it over at its next turn.
    var handOverTo: HelioWake?
}

/// A sync handed from one run to a later one (#233 item 3): the session it runs on and the count of
/// syncs that session had finished before it, so the run taking over flushes exactly that sync.
struct HelioHandOver {
    weak var session: HelioSession?
    let baseline: Int
}

/// What the background run needs from the strap's connection: `HelioConnection` in the app, a
/// simulated strap in the tests.
@MainActor
protocol HelioBackgroundLink: AnyObject {
    /// The strap's session on the current link, if any.
    var session: HelioSession? { get }
    /// When the last connection ended with the strap busy (decision 7), nil when it didn't. Decision
    /// 78d (#316): it holds for `HelioBusyLatch.expiry`; after that a background run tries once again.
    var endedBusyAt: Date? { get }
    /// Decision 78d: a Sleep Focus run clears the busy latch and tries once.
    func clearBusyLatch()
    /// Where the strap's rows live (`zeppos:<id>`): the connected strap's, else the saved one's; nil
    /// when no strap was ever connected.
    var strapTimeline: SyncDeviceID? { get }
    /// Background runs in progress on this link (0 or 1: runs take turns, review-225 S2). A run is
    /// counted from the start of its sync work (after its turn-wait and its no-radio quiet checks, so
    /// a run that ends quietly there is never counted) until it returns. It only serialises runs;
    /// which sessions belong to a run is `backgroundRunAdoptsNewSessions` plus the loop's adoption. A
    /// count, not a flag, so one run's exit can never clear another's.
    var activeBackgroundRuns: Int { get set }
    /// True only while a run's watch loop runs (review-225b S-A). A session the link creates then
    /// belongs to the run (`HelioSession.backgroundRunOwnsSyncs`), and so does a session already up
    /// when the loop starts (the loop adopts it): the run flushes and logs their syncs, and releases
    /// a live one when it hands off or ends synced. A session created after the loop (during the run's
    /// teardown or Health flush, or once the run is over) is never the run's: it flushes and logs its
    /// own syncs through the connection's post-sync hook.
    var backgroundRunAdoptsNewSessions: Bool { get set }
    /// A Sleep Focus run that gives up waiting for its turn leaves its "the night is over" (its Focus
    /// end time T) here for the run holding the link (review-225b N-a). That run takes it into its
    /// flush or its hand-off, and it is cleared when that run returns, used or not (review-225c SF-1),
    /// so it never reaches a later run's flush through the link. A hand-off moves it onto the
    /// handed-over sync (`HelioSession.finalizeNightsOnHandOff`), which ends whenever that sync does.
    /// Decision 31 bounds both: whichever flush receives T finalizes only if it starts within 30
    /// minutes of it (`SleepFocusFinalization`). A waiter that iOS expires leaves nothing.
    var pendingNightsFinalization: Date? { get set }
    /// The run holding the link, while `activeBackgroundRuns` is 1 (#233 item 3).
    var activeRun: HelioActiveRun? { get set }
    /// A sync a run handed to a later one, until that run adopts it (#233 item 3).
    var handOver: HelioHandOver? { get set }
    /// Arm a connect to the saved strap by identifier (no scan). false when there is none.
    func connectForBackground() -> Bool
    /// End the link cleanly and don't reconnect by itself: stop a running find, ack an open round
    /// `03 09`, then drop the link. `cancelNow`: in this call, never deferred (an expiry's teardown).
    func disconnectForBackground(cancelNow: Bool)
    /// After a run's own teardown (out of time, or expired): arm a standing connect again, so the strap
    /// can wake the app later (decision 33). Never after a quiet ending (decision 7).
    func rearmAfterTeardown()
    /// A run started its sync work (`HelioWakeState.lastBackgroundRunStart`: the reconnect cooldown).
    func noteBackgroundRunStarted(at date: Date)
}

extension HelioBackgroundLink {
    func disconnectForBackground() { disconnectForBackground(cancelNow: false) }

    /// iOS is ending a catch-up's background time (`HelioWakeCoordinator`), and suspends the app when
    /// this returns. Review-225e SF-2: everything has to happen in this call.
    /// - The open round's `03 09` is queued first, then the fetch ends (`stopSyncForTeardown`), so the
    ///   session no longer reads "syncing" and nothing defers the cancel.
    /// - The link cancel is issued in this call (`cancelNow`), never 500 ms later in a task the
    ///   suspended app wouldn't run. A `03 09` still waiting in the write queue can be lost with it, which
    ///   is safe: an unacked round stays on the strap (keep-on-device, decision 8).
    /// - The standing connect is armed in this call (`rearmAfterTeardown`). Its `connect` is issued when
    ///   the cancel lands (`didDisconnectPeripheral`, an event iOS wakes the app for), not before: one
    ///   issued while the cancel is in flight could keep the session-less link up, the state this fixes.
    ///
    /// While the app records a strap workout (#227, review-238 B1) nothing is torn down: the workout's
    /// location session keeps the app alive, its link carries the heart-rate stream, and no sync runs on it.
    func tearDownForExpiry() {
        guard !StrapWorkoutRecorder.holdsStrapLink else {
            helioLog.notice("helio: expiry teardown skipped: a strap workout holds the strap")
            return
        }
        session?.stopSyncForTeardown()
        disconnectForBackground(cancelNow: true)
        rearmAfterTeardown()
    }
}

/// How one background run ended, for the run log and the task's success flag.
struct HelioBackgroundRun: Equatable {
    enum Ending: Equatable {
        /// A sync ran to its end (`result`; it may have had nothing new).
        case synced
        /// Quiet endings, before or right after auth. No retry, no writes.
        case noSavedStrap
        case keyNeeded
        case keyRejected
        case strapBusy
        /// The strap lacks what the app needs to fetch history.
        case unsupported
        /// The strap didn't connect, or the sync didn't finish, inside the budget: abandoned with
        /// `03 09` and a clean disconnect.
        case outOfTime
        /// iOS expired the task: abandoned the same way, without the Health flush.
        case expired
        /// Out of budget (or expired) while the app was in front: the sync was left running for the
        /// app, whose own post-sync hook flushes and logs it (review-225 S1). Nothing torn down.
        case handedToApp
        /// Another background run held the strap for this run's whole window (review-225 S2). This
        /// run touched nothing; the other one syncs and flushes. Since coalescing (#233) only a run
        /// waiting behind another one's teardown can end this way.
        case anotherRunActive
        /// Coalesced (#233 item 3): another run already holds the strap with at least this run's
        /// budget, so this one's task completed at once and the other syncs and flushes.
        case coalesced(into: HelioWake)
        /// Coalesced the other way: a later run with a larger budget took this run's sync over.
        case handedOver(to: HelioWake)
        /// The app records a strap workout (#227, review-238 B1): the run touched nothing (no sync, no
        /// teardown, no disconnect); the workout's End runs the sync it held back.
        case workoutHoldsStrap

        /// For the breadcrumb: the case name, with the other run's wake when there is one.
        var label: String {
            switch self {
            case .coalesced(let into): return "coalesced(\(into.rawValue))"
            case .handedOver(let to): return "handedOver(\(to.rawValue))"
            default: return "\(self)"
            }
        }

        /// One sync for two tasks: the other run does the work, alert passes included.
        var isCoalesced: Bool {
            switch self {
            case .coalesced, .handedOver: return true
            default: return false
            }
        }
    }

    var ending: Ending
    /// The last sync that ended during the run (finished or interrupted).
    var result: HelioSyncResult?
    var connectMS: Int?
    var syncMS: Int?
    var flushMS: Int?
    /// Nil when no flush ran (a quiet ending, an expiry, or Health unavailable).
    var flush: HealthKitWriter.FlushResult?
    /// This run acked an open round `03 09` and dropped the link (out of time, or expired).
    var disconnected = false
    /// When the next app-refresh should come for a night this run's flush held back (#233 item 5).
    var refreshAt: Date?

    /// A quiet ending: nothing was fetched and nothing may be written (decision 7).
    var endedQuietly: Bool {
        switch ending {
        case .noSavedStrap, .keyNeeded, .keyRejected, .strapBusy, .unsupported, .anotherRunActive,
             .coalesced, .handedOver, .workoutHoldsStrap: return true
        case .synced, .outOfTime, .expired, .handedToApp: return false
        }
    }

    /// The BGTask success flag: an uninterrupted sync, anything written to Apple Health, or one sync
    /// done for two tasks (#233: a coalesced task is not a failure).
    var success: Bool {
        (ending == .synced && result?.interrupted == false) || flush?.wroteAnything == true || ending.isCoalesced
            || ending == .workoutHoldsStrap   // the app was busy recording, not failing
    }

    /// What an out-of-time or expired run did to the link, for its log line.
    private var teardown: String { disconnected ? "; open round kept on the strap (03 09), disconnected" : "" }

    /// The run-log line. Counts only: never a key, a serial number or a health value.
    var detail: String {
        let head: String
        switch ending {
        case .synced: head = result?.interrupted == true ? "sync interrupted" : "synced"
        case .noSavedStrap: head = "no strap saved; nothing to sync"
        case .keyNeeded: head = "key needed; not connecting"
        case .keyRejected: head = "key rejected; not retrying"
        case .strapBusy: head = "strap busy (another phone or app holds it); not retrying"
        case .unsupported: head = "strap doesn't offer history over Bluetooth"
        case .outOfTime: head = "out of time" + teardown
        case .expired: head = "iOS ended the task" + teardown
        case .handedToApp: head = "handed to the app"
        case .anotherRunActive: head = "another background run held the strap for this run's whole window; nothing done"
        case .coalesced(let into): head = "coalesced into the \(into.runName) run"
        case .handedOver(let to): head = "handed its sync to the \(to.runName) run (larger budget)"
        case .workoutHoldsStrap: head = "a strap workout holds the strap; nothing synced or torn down (the sync runs when it ends)"
        }
        var parts = ["helio strap: \(head)"]
        if let result {
            parts.append("\(result.roundsStored) round(s) stored, \(result.roundsFailed) failed, \(result.nights.count) night(s)")
        }
        if let flush { parts.append("Health samples=\(flush.samples) sleep=\(flush.sleepSegments) steps=\(flush.steps)"
            + flush.recoveryHRVLogSuffix) }
        return parts.joined(separator: "; ")
    }

    /// The `bgphase` breadcrumb (B.4), in the ring's shape plus `device=helio`.
    func breadcrumb(kind: TaskRecord.Kind) -> String {
        func ms(_ value: Int?) -> String { value.map { "\($0)ms" } ?? "n/a" }
        return "device=helio kind=\(kind.rawValue) ending=\(ending.label) connect=\(ms(connectMS)) sync=\(ms(syncMS))"
            + " flush=\(ms(flushMS)) rounds=\(result?.roundsStored ?? 0) failed=\(result?.roundsFailed ?? 0)"
            + " mirrored=\(flush?.wroteAnything ?? false)"
    }
}

@MainActor
struct HelioBackgroundSyncService {
    /// Kept back from the task's window for the Apple Health flush and the teardown, so the flush
    /// doesn't start when iOS is about to expire the task (the ring's app-refresh runs were cut
    /// mid-flush 11 times in 15 before its flush-first fix, #119).
    static let flushReserve: TimeInterval = 8
    /// How long the teardown waits for the `03 09` and a find `06` to leave the radio before the
    /// flush (`HelioConnection.disconnect` cancels the link after 0.5 s).
    static let teardownGrace: TimeInterval = 0.6
    /// A later run takes the active run's sync over only when its deadline is this much later (#233):
    /// a few seconds aren't worth a hand-over.
    static let handOverMargin: TimeInterval = 5

    let link: any HelioBackgroundLink
    let keyStore: any HelioKeyStoring
    let observability: ObservabilityStore
    /// The strap's Apple Health pass (`HelioConnection.healthFlush` in the app, the post-sync hook's
    /// own): the rows of `timeline`, attributed from the row and the strap's `identity`, never from
    /// the current device choice (decision 28).
    let flush: @MainActor (_ timeline: SyncDeviceID, _ nights: [HelioSleepSelection.Night],
                           _ identity: WearableIdentity?, _ focusEndedAt: Date?) async -> HealthKitWriter.FlushResult?
    let now: @MainActor () -> Date
    /// One wait between checks (250 ms in the app; the tests move the simulated strap along instead).
    let pause: @MainActor () async -> Void
    /// After an abandoned sync: time for the `03 09` (and a find `06`) to leave the radio before the
    /// link goes. It must also run in a task iOS just expired, so the app's version can't be cancelled.
    let grace: @MainActor () async -> Void
    /// The app is in front (`applicationState == .active`). Then a run that runs out of time hands
    /// its sync to the app instead of tearing down the link the person is now using (review-225 S1).
    let appIsActive: @MainActor () -> Bool
    /// The link and wake breadcrumbs (#233); nil in tests that don't look at them.
    var breadcrumbs: HelioBreadcrumbs? = nil
    /// The app records a strap workout (#227): the run ends at once, touching nothing (review-238 B1).
    var workoutHoldsStrap: @MainActor () -> Bool = { StrapWorkoutRecorder.holdsStrapLink }
    /// Decision 57b (#262): the margin end of the newest stored strap night not yet in Apple Health,
    /// read after the flush (`LocalStore.newestStrapNightSettles` in the app, as `HelioConnection.
    /// nightRefreshAim` reads it for the post-sync hook). A run whose strap no longer re-delivers that
    /// night still asks for its margin refresh, instead of clearing the one an earlier sync asked for.
    /// nil in tests that don't store nights.
    var storedNightSettles: @MainActor (_ timeline: SyncDeviceID, _ now: Date) -> Date? = { _, _ in nil }
    /// Decision 78a (#332): the persisted Sleep Focus end (`SleepFocusFinalization.persisted` in the
    /// app), for the refresh verdict after the flush; the flush reads it itself. nil in tests that
    /// don't set one.
    var persistedFocusEnd: @MainActor () -> Date? = { nil }
    /// Its source (`SleepFocusFinalization.persistedSource` in the app).
    var persistedFocusSource: @MainActor () -> SleepFocusFinalization.Source = { .perform }
    /// Decision 87c: the time a read (or `perform()`) last saw the Focus on (`SleepFocusDetection.
    /// seenActive` in the app); one later than the persisted T voids it. nil in tests that don't set one.
    var focusSeenActive: @MainActor () -> Date? = { nil }
    /// Decision 78f (#332): the run's read of the Sleep Focus filter, at its start, before anything
    /// else and so before its flush decides finalization (`SleepFocusDetection.check` in the app). It
    /// never connects, syncs or schedules. A no-op in tests that don't drive it.
    var detectFocusEnd: @MainActor (_ kind: TaskRecord.Kind, _ now: Date) async -> Void = { _, _ in }

    /// One bounded run. `nightsFinalized` is the Sleep Focus wake's "the night is over": the time T
    /// Sleep Focus ended. The strap's nights then skip the 20-minute quiet margin, as the ring's do on
    /// that wake, but only in a flush that starts within 30 minutes of T (decision 31). `wake` is why
    /// the run is happening, for the breadcrumbs (#233); a BGTask kind's own by default.
    func run(kind: TaskRecord.Kind, timeout: TimeInterval, nightsFinalized: Date? = nil,
             wake: HelioWake? = nil) async -> HelioBackgroundRun {
        let wake = wake ?? HelioWake(task: kind) ?? .foreground
        let start = now()
        // Decision 78f: iOS may not have run the Focus filter; a Focus end seen here persists T, which
        // this run's own flush then uses (78a, 87). The read is bounded (2 s, 78h S-2), and the run's
        // budget counts from `start`, taken before it.
        await detectFocusEnd(kind, start)
        var run = HelioBackgroundRun(ending: .outOfTime)
        let syncDeadline = start.addingTimeInterval(max(0, timeout - Self.flushReserve))

        // Review-238 B1: a strap workout holds the link. A sync would be deferred (and read as
        // "unsupported", which disconnects), and a teardown would end the workout's heart rate. So the
        // run touches nothing: no connect, no sync, no teardown.
        if workoutHoldsStrap() {
            run.ending = .workoutHoldsStrap
            return record(run, kind: kind)
        }

        // Review-225 S2: one run at a time on a link. The Sleep Focus wake and the scheduler's morning
        // refresh can overlap; two runs would adopt the same sync and both flush it (and a
        // non-finalized flush could win over the Focus run's finalized one).
        //
        // #233 item 3, decision 33: and no run sits out its window waiting. iOS tends to grant the
        // refresh and processing tasks together; build 59's refresh run waited out its whole window
        // while the processing run fought for the strap. A later run decides at once:
        //   • the active run's deadline is at least as late (within `handOverMargin`): COALESCE. This
        //     run's task completes now, successfully ("coalesced into the processing run"); the active
        //     run's sync is the one sync, and a Sleep Focus run leaves its finalization for it (N-a,
        //     decision 31 bounds it).
        //   • this run's deadline is later: TAKE IT OVER. The active run hands its sync to this one at
        //     its next turn (no teardown, nothing sent to the strap) and its task completes; this run
        //     adopts the session and the sync in progress, with its larger budget.
        //   • the active run is past its watch loop: if its sync finished, its flush is the one flush,
        //     so coalesce; if it is tearing down an unfinished sync, wait for it (seconds) and run.
        // Coalescing rather than waiting is the choice for the smaller budget because nothing is lost:
        // the strap's data stays on it (acks `03 09`) for the run that holds the link.
        while link.activeBackgroundRuns > 0 {
            if Task.isCancelled {
                // Review-225b N-c: an expiry while waiting is an expiry (no alert pass follows), and
                // review-225c SF-1: a waiter that iOS expired leaves nothing. A take-over it asked for
                // is withdrawn; one already made goes back to the session, whose own hook flushes it.
                if link.activeRun?.handOverTo == wake { link.activeRun?.handOverTo = nil }
                if let handOver = link.handOver {
                    handOver.session?.backgroundRunOwnsSyncs = false
                    link.handOver = nil
                }
                run.ending = .expired
                return record(run, kind: kind)
            }
            if let active = link.activeRun {
                switch active.stage {
                case .watching where syncDeadline > active.deadline.addingTimeInterval(Self.handOverMargin):
                    if link.activeRun?.handOverTo == nil { link.activeRun?.handOverTo = wake }
                case .watching, .finishing(synced: true):
                    if let focusEnd = nightsFinalized {
                        link.pendingNightsFinalization = SleepFocusFinalization.latest(link.pendingNightsFinalization, focusEnd)
                    }
                    run.ending = .coalesced(into: active.wake)
                    return record(run, kind: kind)
                case .finishing(synced: false):
                    break
                }
            }
            if now() >= syncDeadline {
                // Review-225c SF-1: only a waiter that gave up (not one iOS expired) leaves its request.
                if let focusEnd = nightsFinalized {
                    link.pendingNightsFinalization = SleepFocusFinalization.latest(link.pendingNightsFinalization, focusEnd)
                }
                run.ending = .anotherRunActive
                return record(run, kind: kind)
            }
            await pause()
        }

        // Decision 78d (#316): a Sleep Focus run clears the busy latch and tries once; a strap that is
        // busy again on that try latches again (decision 7).
        if kind == .sleepFocus { link.clearBusyLatch() }
        // Quiet endings before any radio work: nothing is connected and no central is created.
        if link.strapTimeline == nil {
            run.ending = .noSavedStrap
        } else if keyStore.load() == nil {
            run.ending = .keyNeeded
        } else if keyStore.isRejected {
            run.ending = .keyRejected
        } else if HelioBusyLatch.holds(since: link.endedBusyAt, now: now()) {
            // Decision 78d: only for `HelioBusyLatch.expiry`; an older latch is cleared and tried once.
            run.ending = .strapBusy
        }
        if run.endedQuietly { return record(run, kind: kind) }

        link.activeBackgroundRuns += 1
        link.activeRun = HelioActiveRun(wake: wake, deadline: syncDeadline)
        link.noteBackgroundRunStarted(at: start)
        var handedOver = false
        defer {
            link.activeBackgroundRuns -= 1
            link.activeRun = nil
            if !handedOver { link.handOver = nil }
            // Review-225c SF-1: a waiter's request lives only as long as this run. Unused (this run
            // expired, ended quietly, or was already in its flush), it goes with it, so it can never
            // finalize an unrelated flush hours later. A run that hands its sync over leaves it (and
            // its own) for the run taking it over, whose return clears it in turn.
            if !handedOver { link.pendingNightsFinalization = nil }
        }
        // Review-225b S-A: sessions made from here to the end of the watch loop are this run's. The
        // mark is dropped before anything after the loop awaits (teardown grace, Health flush), so a
        // session made then (the app opened during an abandoned run's teardown) owns its own syncs.
        link.backgroundRunAdoptsNewSessions = true
        defer { link.backgroundRunAdoptsNewSessions = false }

        var watched: HelioSession?
        var baseline = 0
        var requested = false
        var syncStartedAt: Date?
        var loggedSyncStart = false
        if link.session?.isLinkConnected != true { _ = link.connectForBackground() }

        loop: while true {
            // Checked first, before an expiry and before `syncHistory` (which a workout defers): a
            // workout started while this run waited for the session ends the run without a teardown.
            if workoutHoldsStrap() { run.ending = .workoutHoldsStrap; break }
            if Task.isCancelled { run.ending = .expired; break }
            if let to = link.activeRun?.handOverTo { run.ending = .handedOver(to: to); break }
            if let session = link.session, session.isLinkConnected {
                if session !== watched {
                    // A connection made during this run (its link marked it) counts every sync it
                    // ran; one that was already up counts only syncs from now on; one handed over by
                    // an earlier run (#233) counts from where that run counted.
                    watched = session
                    if let handOver = link.handOver, handOver.session === session {
                        baseline = handOver.baseline
                    } else {
                        baseline = session.backgroundRunOwnsSyncs ? 0 : session.syncsFinished
                    }
                    link.handOver = nil
                    session.backgroundRunOwnsSyncs = true
                    requested = session.syncing || baseline < session.syncsFinished
                    if session.syncing, syncStartedAt == nil { syncStartedAt = now() }
                }
                if session.syncsFinished > baseline, let result = session.lastSyncResult {
                    run.result = result
                    if !session.syncing {
                        run.ending = .synced
                        break loop
                    }
                }
                switch session.phase {
                case .keyless: run.ending = .keyNeeded; break loop
                case .keyRejected: run.ending = .keyRejected; break loop
                case .strapBusy: run.ending = .strapBusy; break loop
                case .unsupported: run.ending = .unsupported; break loop
                case .ready:
                    if run.connectMS == nil { run.connectMS = Self.ms(from: start, to: now()) }
                    if !requested {
                        requested = true
                        session.syncHistory(manual: false)
                        guard session.phase == .syncing else { run.ending = .unsupported; break loop }
                        syncStartedAt = now()
                    }
                case .syncing:
                    if run.connectMS == nil { run.connectMS = Self.ms(from: start, to: now()) }
                    if syncStartedAt == nil { syncStartedAt = now() }
                case .starting, .authenticating, .settingUp:
                    break
                }
            }
            if syncStartedAt != nil, !loggedSyncStart {
                loggedSyncStart = true
                breadcrumbs?.syncStarted(wake: wake, detail: "kind=\(kind.rawValue)")
            }
            if now() >= syncDeadline { run.ending = .outOfTime; break }
            await pause()
        }
        link.backgroundRunAdoptsNewSessions = false
        link.activeRun?.stage = .finishing(synced: run.ending == .synced)
        if let syncStartedAt, run.ending == .synced { run.syncMS = Self.ms(from: syncStartedAt, to: now()) }

        switch run.ending {
        case .outOfTime where appIsActive(), .expired where appIsActive():
            // Review-225 S1: the person opened the app while this run was syncing (the Sleep Focus
            // wake, then a look at last night). Abandoning would disconnect the strap under the open
            // app, and nothing reconnects it. Hand the sync over instead: the session's own post-sync
            // hook flushes and logs it once it ends (its result is no longer the run's), so there is
            // still exactly one flush, and nothing is sent to the strap here.
            watched?.backgroundRunOwnsSyncs = false
            link.session?.backgroundRunOwnsSyncs = false   // one made during the loop's last turn, not yet watched
            // Review-225b S-B: the Sleep Focus run's "the night is over" goes with the sync, so the
            // hook's flush writes the night without the 20-minute margin, as this run would have.
            // Review-225d SF-A: only a session whose next sync end IS the handed-over sync gets it: one
            // that is syncing, or still connecting (it syncs on connect). An idle session (its sync
            // already ended, say in the loop's last pause before iOS expired the task) gets nothing,
            // so the next, unrelated sync on it is not finalized. Decision 31 bounds it anyway.
            if let focusEnd = takeNightsFinalized(nightsFinalized) {
                // `watched` and `link.session` are usually the same session; `latest` makes that harmless.
                for session in [watched, link.session].compactMap({ $0 }) where Self.handOffEndsWithItsNextSync(session) {
                    session.finalizeNightsOnHandOff = SleepFocusFinalization.latest(session.finalizeNightsOnHandOff, focusEnd)
                }
            }
            run.ending = .handedToApp
            return record(run, kind: kind)
        case .synced:
            // Leave the link as it is: an idle, authenticated link costs nothing, the next wake skips
            // connect + auth, and the standing reconnect stays armed for the restoration leg. (The
            // ring re-arms a fresh connect instead; for the strap that reconnects at once and the
            // sync-on-connect would fetch everything a second time.)
            watched?.backgroundRunOwnsSyncs = false
        case .outOfTime, .expired:
            // The teardown's writes get their moment on the radio before anything else runs.
            if abandon() {
                run.disconnected = true
                await grace()
            }
            // Review-225 N4: iOS may expire the task during that grace; then no flush follows.
            if Task.isCancelled { run.ending = .expired }
            if let watched, watched.syncsFinished > baseline, let result = watched.lastSyncResult { run.result = result }
        case .handedOver:
            // #233: the later run adopts the session and the sync in flight, which stays a run's
            // (no hook flush): `handOver` tells it where this run counted from. Nothing is sent to
            // the strap here.
            if let watched {
                link.handOver = HelioHandOver(session: watched, baseline: baseline)
            } else if let made = link.session {
                link.handOver = HelioHandOver(session: made, baseline: 0)   // made during this run's loop
            }
            if let focusEnd = nightsFinalized {
                link.pendingNightsFinalization = SleepFocusFinalization.latest(link.pendingNightsFinalization, focusEnd)
            }
            handedOver = true
            return record(run, kind: kind)
        case .handedToApp, .anotherRunActive, .coalesced:
            // These return above; none may touch a link another party is using.
            return record(run, kind: kind)
        case .workoutHoldsStrap:
            // Review-238 B1: the link is the workout's. Nothing sent, nothing torn down; a session this
            // run adopted goes back to its own hooks.
            watched?.backgroundRunOwnsSyncs = false
            link.session?.backgroundRunOwnsSyncs = false
            breadcrumbs?.wakeNote(wake, "background run ended: a strap workout holds the strap")
            return record(run, kind: kind)
        case .keyNeeded, .keyRejected, .strapBusy, .unsupported, .noSavedStrap:
            // Decision 7: end here, drop the link and leave it down; the next explicit connect retries.
            link.disconnectForBackground()
            // Decision 78b (#332): a Sleep Focus run leaves the standing connect armed on every ending
            // but key needed, key rejected, no saved strap and a workout holding the strap.
            // DECISION-GAP: after `.strapBusy` the re-arm meets the latch just set (78d: a strap busy
            // again latches again), so `rearmAfterTeardown` declines it until the latch expires.
            if kind == .sleepFocus, run.ending == .strapBusy || run.ending == .unsupported { link.rearmAfterTeardown() }
            return record(run, kind: kind)
        }

        // The Health flush: never after an expiry (the task is over), never for a quiet ending.
        if run.ending != .expired, let timeline = link.strapTimeline {
            let flushStart = now()
            // Review-225c SF-2: a sync a Focus run handed over, then adopted here, keeps that run's
            // finalization (it rides on the result).
            // Decision 31: whichever Focus end reaches this flush, `healthFlush` decides at its start.
            let focusEnd = SleepFocusFinalization.latest(takeNightsFinalized(nightsFinalized), run.result?.nightsFinalized)
            run.flush = await flush(timeline, run.result?.nights ?? [], run.result?.identity ?? watched?.identity,
                                    focusEnd)
            run.flushMS = Self.ms(from: flushStart, to: now())
            run.refreshAt = StrapNightRefresh.aim(nights: run.result?.nights ?? [],
                                                  storedNightSettles: storedNightSettles(timeline, now()),
                                                  focusEndedAt: focusEnd, persistedFocusEnd: persistedFocusEnd(),
                                                  persistedSource: persistedFocusSource(), focusSeenActive: focusSeenActive(),
                                                  flushStartedAt: flushStart, afterWokeUp: wake == .strapEvent)
            if run.flush?.wroteAnything == true { observability.recordHealthWrite() }
        }
        return record(run, kind: kind)
    }

    /// The session's next sync end is the sync being handed over: it is syncing, or still connecting
    /// (it syncs on connect). An idle, connected session is not (review-225d SF-A).
    private static func handOffEndsWithItsNextSync(_ session: HelioSession) -> Bool {
        switch session.phase {
        case .syncing, .starting, .authenticating, .settingUp: return true
        case .ready, .keyless, .keyRejected, .strapBusy, .unsupported: return false
        }
    }

    /// This run's Focus end, or the one a waiting Sleep Focus run left on the link, whichever is later
    /// (the link's is consumed).
    private func takeNightsFinalized(_ own: Date?) -> Date? {
        defer { link.pendingNightsFinalization = nil }
        return SleepFocusFinalization.latest(own, link.pendingNightsFinalization)
    }

    /// Ack an open round `03 09` and drop the link (the find stop goes out first), then arm a standing
    /// connect again (decision 33). false when no session is up: a connect still pending stays armed,
    /// so the strap coming into range can wake the app through state restoration later.
    private func abandon() -> Bool {
        guard let session = link.session, !workoutHoldsStrap() else { return false }
        session.abortSync()
        link.disconnectForBackground()
        link.rearmAfterTeardown()
        return true
    }

    @discardableResult
    private func record(_ run: HelioBackgroundRun, kind: TaskRecord.Kind) -> HelioBackgroundRun {
        observability.recordSyncOutcome(kind: kind, success: run.success, detail: run.detail)
        observability.recordMetricEvent(source: "bgphase", detail: run.breadcrumb(kind: kind))
        helioLog.notice("\(run.detail, privacy: .public)")
        return run
    }

    private static func ms(from start: Date, to end: Date) -> Int {
        Int((end.timeIntervalSince(start) * 1000).rounded())
    }
}

extension HelioBackgroundSyncService {
    /// The app's run: the shared connection, the Keychain key, the real Health writer and clock.
    static func live(store: LocalStore) -> HelioBackgroundSyncService {
        let connection = HelioConnection.shared
        connection.setLocalStore(store)
        return HelioBackgroundSyncService(
            link: connection, keyStore: connection.keyStore, observability: ObservabilityStore(),
            flush: { timeline, nights, identity, focusEndedAt in
                await HelioConnection.healthFlush(timeline: timeline, store: store, nights: nights,
                                                  identity: identity, nightsFinalized: focusEndedAt)
            },
            now: { Date() },
            pause: { try? await Task.sleep(for: .milliseconds(250)) },
            grace: {
                // Not `Task.sleep`: that returns at once in a cancelled (expired) task.
                await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                    DispatchQueue.main.asyncAfter(deadline: .now() + teardownGrace) { done.resume() }
                }
            },
            appIsActive: { UIApplication.shared.applicationState == .active },
            breadcrumbs: connection.breadcrumbs,
            storedNightSettles: { timeline, now in store.newestStrapNightSettles(timeline: timeline, now: now) },
            persistedFocusEnd: { SleepFocusFinalization.persisted() },
            persistedFocusSource: { SleepFocusFinalization.persistedSource() },
            focusSeenActive: { SleepFocusDetection.seenActive() },
            detectFocusEnd: { kind, _ in await SleepFocusDetection.check(kind: kind.rawValue) })
    }
}

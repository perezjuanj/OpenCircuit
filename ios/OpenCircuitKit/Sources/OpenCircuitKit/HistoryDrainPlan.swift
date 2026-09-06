// Which history channels one drain pass opens, and in what order.
//
// Extracted from three inline booleans in `RingSession.performHistoryDrain` so the order — and in
// particular the #119 invariant that the workout prime never touches the sleep channel — is locked
// by tests instead of by prose. Behaviour is unchanged from the inline version.
//
// THE INVESTIGATION THAT LED HERE (tester Diagnostics export, 2026-07-27). Over ~9 h the all-day
// channel (`0x03`) reported `noAck` on 27 of 32 attempts, and every one of the five successes came
// from a BACKGROUND pass — where all-day already goes first. In the foreground, where sleep goes
// first unconditionally, all-day never once completed. The user's daytime HR / SpO₂ / RR therefore
// never landed, and their active-energy estimate fell back to the steps-only floor.
//
// WHAT IS ACTUALLY ESTABLISHED, AND WHAT IS NOT. Two candidate mechanisms exist and this file
// takes NO position between them — an earlier draft of this comment claimed the first was refuted,
// which was an overstatement corrected in review:
//
//   (a) 🟡 A ring-side limit — "the ring services one DATA-RETURNING `0x02` sync-open per
//       authenticated connection". Derived from official-app btsnoop captures showing the app makes
//       TWO SEPARATE connections, each with a full re-auth, to drain both channels. The captures
//       live in `desktop/captures/` which is GITIGNORED (health data — see CLAUDE.md), so this is
//       NOT auditable from the repo alone and is recorded here as probable, not confirmed.
//       ⚠️ Do not cite `desktop/captures/probe_*.log` as refuting it, as an earlier draft did: in
//       `probe_1783286341.log` all 32 swept channels report `-> empty`, so its 32 `82 00 00 82`
//       ACKs only show the ring ACKs an open on an ALREADY-DRAINED backlog. An ACK is not evidence
//       a channel was serviced, and those logs say nothing about a second DATA-returning open.
//
//   (b) 🟢 Link flakiness — independently evidenced, and the only one this file acts on. A tester's
//       Diagnostics export (2026-07-27, not in the repo: it contains personal health data, so these
//       figures are unauditable here by design) shows `ble-write: skipped state=disconnected` /
//       `state=connecting` recurring all day, interleaved with the failing drains, and all-day
//       reporting `noAck` on 27 of 32 attempts. `RingSession.write` silently returned when the link
//       was unusable; `drainChannel` ignored that and sat in its tick loop waiting for frames that
//       could never arrive, then classified the channel `noAck` — a label meaning "no `0x82` seen",
//       which cannot distinguish "the ring refused" from "we never transmitted the open at all".
//
// Both can be true at once, and (a) vs (b) is not resolvable from the data in hand. That is exactly
// why the fix is to make the app HONEST rather than clever: `write` now reports delivery,
// `drainChannel` abandons a channel it could not open instead of burning 12–45 s, and the new
// `HistoryChannelOutcome.linkDown` splits "we never asked" out of `.noAck`. The next export will
// then say plainly which mechanism is in play — under (a) the second channel gets a real `.noAck`
// with the open confirmed sent; under (b) it gets `.linkDown`. Measure before reordering anything.
//
// Pure (no Apple frameworks beyond Foundation) so it unit-tests on the CLI, matching
// LiveMeasureOwnership / HistoryDrainCadence / ReconnectBackoff.

import Foundation

public enum HistoryDrainPlan {

    /// One channel to open in this pass, in order.
    public struct Step: Equatable, Sendable {
        public let channel: UInt8
        public let label: String

        public init(channel: UInt8, label: String) {
            self.channel = channel
            self.label = label
        }
    }

    public static let sleepStep = Step(channel: Command.syncChannelSleep, label: "sleep")
    public static let allDayStep = Step(channel: Command.syncChannelAllDay, label: "all-day")
    public static let sportStep = Step(channel: Command.syncChannelSport, label: "sport")

    /// Default width of the post-wake window in which the overnight sleep backlog outranks
    /// everything else. Mirrors `RingSession.morningCatchUpWindow`.
    public static let defaultMorningCatchUpWindow: TimeInterval = 3 * 3600

    /// The ordered channel opens for one drain pass. BEHAVIOURALLY IDENTICAL to the inline booleans
    /// this replaced — this is an extraction for testability, not a behaviour change.
    ///
    /// - `inBackground`: a BGTask / CoreBluetooth-wake drain. The window is ~30 s and iOS often cuts
    ///   it, so all-day goes first to guarantee today's vitals land — the device-observed behaviour
    ///   commit `39f3e43` shipped.
    /// - `allDayOnly`: the workout prime. Touches ONLY `0x03` — never the sleep channel, so the
    ///   overnight sleep resume pointer is never walked (#119). Sport is excluded too.
    /// - `nightWindowEnd` / `now`: in the BACKGROUND, inside `morningCatchUpWindow` after wake, the
    ///   night's backlog is the whole point of the pass, so sleep goes first.
    /// - `sportEnabled`: automatic workout detection is on. Sport (`0x02`) is foreground-only and
    ///   always last — it is workout REVIEW data and not worth a bounded background wake.
    ///
    /// ⚠️ A REORDER HEURISTIC WAS PROTOTYPED HERE AND DELIBERATELY NOT SHIPPED (2026-07-27). The
    /// idea was to promote all-day ahead of sleep after a pass where all-day never reached the wire,
    /// since a tester's export showed all-day starved on 27 of 32 attempts with every success coming
    /// from a background (all-day-first) pass. Adversarial review killed it on four counts, all
    /// verified in the code: the signal would also be written by CANCELLED drains (a user tapping
    /// Measure cancels `syncTask`, and a cancelled channel classifies `.noAck`) and by the
    /// `allDayOnly` workout prime (which runs while the ring is deliberately busy, so a silent
    /// channel there is expected); the morning-catch-up exemption does NOT fire when it matters,
    /// because for a LEARNED sleep window the morning drain runs from `nightWindow.end - 5400 s`
    /// while `nearWake` requires `now >= nightWindow.end`; and because the signal is recomputed
    /// every pass, it would in practice ALTERNATE the order — trading an all-day starvation for a
    /// sleep one, the exact outcome it was written to avoid. Ship the link-awareness fix and the
    /// `.linkDown` diagnostic first; they make the next export say plainly whether ordering is even
    /// the lever. Do not reintroduce ordering logic without that measurement.
    ///
    /// ONE reorder input HAS since been admitted, and it is deliberately confined here rather than
    /// applied by the caller: `resumeHint` (2026-09-04). It is a single first-hand fact — the channel
    /// THIS app's own session teardown cut off mid-wait — and it may reorder ONLY the plain foreground
    /// plan. The two deliberate, device-observed orderings are unreachable from it by construction:
    ///
    ///   • `allDayOnly` returns before the hint is ever consulted, so the workout prime still touches
    ///     `0x03` and nothing else (#119).
    ///   • the hint is gated on `!inBackground`, which covers BOTH background orderings in one test:
    ///     the ordinary all-day-first background plan (`39f3e43`, device-observed "sleep no-ack
    ///     added=0, then all-day added=173") and the morning catch-up, which by construction only
    ///     exists when `inBackground` is true. Inverting either inside a ~30 s BGTask window is
    ///     exactly the measurement-free reorder the paragraph above forbids — and since `sleep` goes
    ///     first in the FOREGROUND plan, `sleep` is the channel most often in flight at teardown, so
    ///     an ungated hint would have inverted `39f3e43` on nearly every background pass.
    ///
    /// The gate lives in this pure function, not at the call site, so the invariant is locked by
    /// `HistoryDrainPlanTests` instead of by prose in an untestable CoreBluetooth class.
    public static func steps(inBackground: Bool,
                             allDayOnly: Bool,
                             sportEnabled: Bool,
                             now: Date,
                             nightWindowEnd: Date?,
                             morningCatchUpWindow: TimeInterval = defaultMorningCatchUpWindow,
                             resumeHint: Step? = nil)
        -> [Step] {

        // The workout prime is all-day and nothing else — no sleep pointer, no sport.
        if allDayOnly { return [allDayStep] }

        // Mirrors the replaced inline `morningCatchUp`, INCLUDING its `inBackground` requirement:
        // the foreground path was unconditionally sleep-first and must stay that way.
        let morningCatchUp: Bool = {
            guard inBackground, let end = nightWindowEnd else { return false }
            let sinceWake = now.timeIntervalSince(end)
            return sinceWake >= 0 && sinceWake <= morningCatchUpWindow
        }()
        let sleepFirst = !inBackground || morningCatchUp

        var steps = sleepFirst ? [sleepStep, allDayStep] : [allDayStep, sleepStep]
        if !inBackground, sportEnabled { steps.append(sportStep) }
        // FOREGROUND ONLY (see the header above): the background plan's all-day-first order and the
        // morning catch-up's sleep-first order are both device-observed decisions, and a hint that
        // reordered them would be a measurement-free reorder.
        if let resumeHint, !inBackground { steps = resuming(resumeHint, in: steps) }
        return steps
    }

    /// Move `step` to the front of `plan` when present, so a channel that was still waiting on the
    /// ring when a BLE reconnect tore down the session gets first crack on the very next attempt
    /// instead of being re-queued behind whatever already won that race (2026-09-04: a session-churn
    /// investigation found `all-day`/`sport` starved almost every cycle, behind `sleep`, which always
    /// goes first in the foreground plan and so had first claim on each connection window before the
    /// next churn cut in).
    ///
    /// ⚠️ THIS IS NOT THE REORDER HEURISTIC REJECTED ABOVE — but "it is a first-hand fact" is not on
    /// its own what keeps it clean. An earlier draft of this comment asserted the hint "cannot be
    /// polluted the way the rejected heuristic could"; adversarial review measured that claim and it
    /// was FALSE as written, because `RingScanner.teardownSession()` has six callers and three of them
    /// are not session churn at all. The property is now held by four explicit guards, each with its
    /// own test — describe these, do not re-assert the property:
    ///
    ///   1. ORDERING. `steps(…)` applies the hint only to the plain FOREGROUND plan (see its doc);
    ///      the `allDayOnly` prime and both background orderings are unreachable from it.
    ///   2. CAPTURE SITE. `RingScanner` captures the hint only on the genuine reconnect paths
    ///      (`didDisconnectPeripheral`, and a session replaced under `didConnect`/`willRestoreState`).
    ///      A user `disconnect()`/`forgetActiveRing()`, an in-app switch to a DIFFERENT ring, and the
    ///      normal end of a bounded background read all tear the session down WITHOUT capturing, and
    ///      clear any hint already standing.
    ///   3. IDENTITY + TTL. The hint carries the peripheral it was captured from and the instant of
    ///      capture; `ResumeHint.step(forPeripheral:at:)` refuses it on any other ring or after
    ///      `ResumeHint.timeToLive`.
    ///   4. ONE-SHOT. It is consumed once per replacement session and discarded win or lose, so it is
    ///      never accumulated or recomputed the way the rejected heuristic was.
    ///
    /// It also cannot fire for a user Measure-cancel: that cancels `syncTask` in place, without going
    /// through `teardownSession()` at all.
    public static func resuming(_ step: Step, in plan: [Step]) -> [Step] {
        guard let index = plan.firstIndex(of: step), index != 0 else { return plan }
        var reordered = plan
        reordered.remove(at: index)
        reordered.insert(step, at: 0)
        return reordered
    }

    /// Why a `RingSession` is being torn down — and therefore whether the channel it had in flight is
    /// worth resuming on whatever session replaces it. Guard 2 of the four listed on
    /// `resuming(_:in:)`, lifted out of `RingScanner` so the policy is a tested table rather than a
    /// boolean literal repeated at six call sites.
    ///
    /// THE DEFECT THIS FIXES (review, 2026-09-05). The hint was captured unconditionally inside
    /// `RingScanner.teardownSession()`, which has six callers — and three of them are not session
    /// churn at all. `.switchingRing` handed ring A's in-flight channel to ring B's fresh session;
    /// `.userDisconnected` let a deliberate "stop using this ring" leave a reorder queued for some
    /// future connect; `.backgroundReadEnded` fires at the orderly end of EVERY bounded background
    /// read, where nothing was cut off. Only a link that actually dropped, or a session actually
    /// being replaced on the same ring, is evidence that a channel lost its turn.
    public enum TeardownReason: String, Equatable, Sendable, CaseIterable {
        /// `centralManager(_:didDisconnectPeripheral:error:)` — the link dropped, possibly under a
        /// mid-flight drain, and auto-reconnect will bring up a replacement session on the same ring.
        case linkDropped
        /// A session is being replaced on the SAME ring under `didConnect` / `willRestoreState`
        /// (normally there is none left to replace; this covers a restore racing a connect).
        case sessionReplaced
        /// The in-app picker switched to a DIFFERENT ring. The old ring's interrupted channel says
        /// nothing about the new one.
        case switchingRing
        /// `disconnect()` / `forgetActiveRing()` — a deliberate user stop, not an interruption.
        case userDisconnected
        /// `endBackgroundReadRearming()` — the bounded background read reached its own end. The drain
        /// was not cut off; the read finished.
        case backgroundReadEnded

        /// Whether a teardown for this reason should record the in-flight channel as a resume hint.
        public var capturesResumeHint: Bool {
            switch self {
            case .linkDropped, .sessionReplaced: return true
            case .switchingRing, .userDisconnected, .backgroundReadEnded: return false
            }
        }
    }

    /// A captured resume hint plus the two facts that make it refusable: WHICH ring it came from and
    /// WHEN it was taken. Extracted into the Kit (rather than living as three stored properties on
    /// `RingScanner`) for the usual reason — `RingScanner` is a `CBCentralManagerDelegate` and cannot
    /// be unit-tested, so the decision it makes is lifted into a pure value that can be.
    ///
    /// Guard 3 of the four listed on `resuming(_:in:)`. Before it existed the stored hint had neither
    /// identity nor an expiry: it was cleared only when a new session was created, so it could sit for
    /// days and then be applied to whatever ring happened to connect next.
    public struct ResumeHint: Equatable, Sendable {
        public let step: Step
        /// `CBPeripheral.identifier` of the ring whose drain was interrupted.
        public let peripheralID: UUID
        public let capturedAt: Date

        public init(step: Step, peripheralID: UUID, capturedAt: Date) {
            self.step = step
            self.peripheralID = peripheralID
            self.capturedAt = capturedAt
        }

        /// How long a hint stays applicable. 120 s.
        ///
        /// BASIS: the hint describes the channel that was in flight when the link dropped, and it is
        /// only meaningful to the session that IMMEDIATELY replaces the one that was cut off. The
        /// longest single reconnect backoff step is 30 s (`ReconnectBackoff.delays == [1, 5, 30]`,
        /// capped to 8 s while backgrounded); 120 s covers that worst-case delay plus connect, service
        /// discovery and the SM3 auth handshake with roughly 3× margin, while expiring long before the
        /// next drain cadence. Past that the "interrupted" channel is no longer a fact about the
        /// current connection, and the plan's own ordering is at least as good a guess — so the hint
        /// is dropped rather than guessed with.
        public static let timeToLive: TimeInterval = 120

        /// The hinted step if this hint still applies to `peripheralID` at `now`, else `nil`.
        /// A hint from a different ring, or one older than `timeToLive`, is refused.
        public func step(forPeripheral peripheralID: UUID, at now: Date) -> Step? {
            guard peripheralID == self.peripheralID else { return nil }
            let age = now.timeIntervalSince(capturedAt)
            // A negative age means the clock moved backwards between capture and consumption
            // (NTP correction / manual set). Refuse rather than trust an un-ageable hint.
            guard age >= 0, age <= Self.timeToLive else { return nil }
            return step
        }

        /// The hint that should be standing after a session teardown — the whole capture-site policy
        /// as one pure function, so `RingScanner` stores the answer rather than deciding it.
        ///
        /// - `reason`: why the session is going away.
        /// - `inFlight`: the channel that session had mid-wait, if any
        ///   (`RingSession.interruptedDrainChannel`, read BEFORE its `syncTask` is cancelled).
        /// - `peripheralID`: the ring being torn down from, if one is targeted.
        /// - `standing`: the hint already held, if any.
        ///
        /// ⚠️ THE CASE THAT IS EASY TO GET WRONG, and the reason this is a tested function rather
        /// than an `if` at the call site: a capturing teardown with NOTHING in flight must LEAVE the
        /// standing hint alone, not clear it. The ordinary reconnect runs `didDisconnectPeripheral`
        /// (`.linkDropped`, captures from the live session) and then, one connect later, `didConnect`
        /// (`.sessionReplaced`, by which point `session` is already nil so there is nothing to
        /// capture). Clearing on that second teardown would erase the hint the first one just took
        /// and make the entire resume path dead — silently, since the fallback is simply the normal
        /// plan order. Only a NON-capturing reason clears.
        public static func afterTeardown(_ reason: TeardownReason,
                                         inFlight: Step?,
                                         peripheralID: UUID?,
                                         at now: Date,
                                         standing: ResumeHint?) -> ResumeHint? {
            guard reason.capturesResumeHint else { return nil }
            guard let inFlight, let peripheralID else { return standing }
            return ResumeHint(step: inFlight, peripheralID: peripheralID, capturedAt: now)
        }
    }
}

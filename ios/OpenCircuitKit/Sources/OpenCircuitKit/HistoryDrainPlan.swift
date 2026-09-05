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
    public static func steps(inBackground: Bool,
                             allDayOnly: Bool,
                             sportEnabled: Bool,
                             now: Date,
                             nightWindowEnd: Date?,
                             morningCatchUpWindow: TimeInterval = defaultMorningCatchUpWindow)
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
        return steps
    }

    /// Move `step` to the front of `plan` when present, so a channel that was still waiting on the
    /// ring when a BLE reconnect tore down the session gets first crack on the very next attempt
    /// instead of being re-queued behind whatever already won that race (2026-09-04: a session-churn
    /// investigation found `all-day`/`sport` starved almost every cycle, behind `sleep`, which always
    /// goes first in the foreground plan and so had first claim on each connection window before the
    /// next churn cut in).
    ///
    /// ⚠️ THIS IS NOT THE REORDER HEURISTIC REJECTED ABOVE. That one inferred "starvation" from
    /// aggregate outcome history recomputed every pass, and was killed because the signal was
    /// polluted by a user-cancelled `syncTask` and by the `allDayOnly` prime, and because it thrashed.
    /// This is a single, first-hand fact — `RingSession.interruptedDrainChannel` reads which channel
    /// THIS session's OWN teardown cut off, synchronously, before anything is cancelled — applied
    /// ONCE per replacement session and then discarded regardless of outcome, not accumulated or
    /// recomputed. It cannot fire for a user Measure-cancel (that cancels `syncTask` in place, without
    /// going through `RingScanner.teardownSession()`), and a stale hint against a plan that excludes
    /// it (e.g. the `allDayOnly` prime's `[allDayStep]`) is simply a no-op — `#119` is untouched.
    public static func resuming(_ step: Step, in plan: [Step]) -> [Step] {
        guard let index = plan.firstIndex(of: step), index != 0 else { return plan }
        var reordered = plan
        reordered.remove(at: index)
        reordered.insert(step, at: 0)
        return reordered
    }
}

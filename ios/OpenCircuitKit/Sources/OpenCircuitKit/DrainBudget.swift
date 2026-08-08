// Whether a per-channel history drain that has run out of budget should EXTEND rather than cut.
//
// WHY THIS IS A PURE TYPE. `drainChannel`'s budget used to be a fixed `for tick in 0 ..< 45` — an
// absolute wall that expired even while the ring was mid-handoff. Falling through it yields
// `.hardTimeout` → `HistoryChannelOutcome.partial` → `allowsSleepCommit == false` → `HistoryCommitGate`
// denies `.stage`, so the night is banked but never staged and the user sees no sleep summary.
//
// 🟢 MEASURED 2026-08-07 (Gen 2 Air / FR04.009): the whole-night catch-up streamed 20 pages / 119
// records over 43 s and its `0x50` end-of-history landed ~55 s after the open — clearing the 45-tick
// wall only because the `@MainActor` loop runs 1.2–1.9× nominal. A 10 h night (~240 records ≈ 88 s of
// handoff) would not have cleared it.
//
// ⚠️ THE OFF-BY-ONE THIS EXISTS TO PIN. The first attempt at the extend rule tested
// `quietTicks <= 1`, reasoning that it means "a page landed on this very tick". It does — but that is
// the WRONG test. A channel only reaches the budget check if it did NOT take the 3-quiet-tick exit,
// so `quietTicks ∈ {1, 2}`, and with a measured 2.26 s mean inter-page gap against 1 s ticks the
// value is 2 about half the time. `<= 1` therefore refused to extend a still-live stream on roughly
// half of all bursts, purely on tick phase — reintroducing the exact coin-flip it was meant to remove.
// The correct definition of "still streaming" is "pages arrived AND the quiet exit has not fired".
//
// Pure and Apple-framework-free so that reasoning is asserted by tests rather than re-derived by hand,
// matching `UnattributedPageBuffer` / `DrainBankCadence`.

import Foundation

public enum DrainBudget {

    /// Should an exhausted budget be extended?
    ///
    /// - Parameters:
    ///   - tick: iterations completed so far.
    ///   - cap: the current budget, in ticks.
    ///   - ceiling: absolute bound; never extend past it.
    ///   - sawPages: this channel has received at least one page.
    ///   - quietTicks: ticks since the last page (the frame handler zeroes it on every page).
    ///   - quietExitThreshold: the loop's own quiet-exit threshold, so the two can never drift apart.
    public static func shouldExtend(tick: Int,
                                    cap: Int,
                                    ceiling: Int,
                                    sawPages: Bool,
                                    quietTicks: Int,
                                    quietExitThreshold: Int = 3) -> Bool {
        guard tick >= cap else { return false }          // budget not spent yet
        guard sawPages else { return false }             // an idle channel is not "streaming"
        guard quietTicks < quietExitThreshold else { return false }   // the quiet exit owns this case
        return cap < ceiling
    }

    /// The extended budget: one more `step`, clamped to `ceiling`.
    public static func extendedCap(cap: Int, step: Int, ceiling: Int) -> Int {
        min(cap + step, ceiling)
    }
}

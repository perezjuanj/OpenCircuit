// When acked-but-uncommitted history pages must be banked to the EpochArchive (#188 follow-up).
//
// WHY THIS EXISTS. `RingSession` acks every `0x4c` page unconditionally, and that ack advances the
// ring's single resume pointer — so an acked page is gone from the ring whether or not we kept it.
// `UnattributedPageBuffer` already encodes that contract for pages arriving with NO drain open. The
// pages arriving WITH a drain open had no equivalent: they accumulate in a volatile `bulkRecords`
// array from the first page until `commitDrainedRecords`, which for a whole-night handoff is the
// better part of a minute.
//
// 🟢 MEASURED 2026-08-07 (Gen 2 Air / FR04.009, app build 38). The wake catch-up drain opened at
// 06:30:12 local, took 20 `0x4c` pages off the wire in one 43 s burst — 119 contiguous records,
// 01:31:47 → 06:26:46 local at the ring's exact 150 s epoch cadence, terminated by a clean `0x50`
// end-of-history — and NONE of them reached the EpochArchive or LocalStore. The archive holds the
// epoch immediately before (01:29:17) and the one immediately after (06:29:16, delivered 53 s later
// outside the burst), so the loss boundary is exactly the drain window. Every graceful teardown path
// banks correctly, which leaves "acked but not yet committed" as the only window that can lose them.
//
// THE RULE THIS TYPE ENCODES. Bank on a short quiet debounce so one burst costs a couple of archive
// writes — but ALSO bound the total hold, because the debounce re-arms on every page and a
// CONTINUOUS handoff (precisely the whole-night shape above) would otherwise defer the bank until
// the burst ends, which is the exact window being closed. That second half is not hypothetical: the
// unattributed path shipped without it and had to have `unattributedMaxHold` added in review.
//
// Pure and Apple-framework-free so the invariant is unit-testable, matching `UnattributedPageBuffer`.

import Foundation

public enum DrainBankCadence {

    /// Quiet window after the last page before banking.
    ///
    /// 🟢 Sized off the measured burst: inter-page gaps on the 2026-08-07 handoff ran 1–3 s (20 pages
    /// across 43 s ⇒ a 2.26 s mean). This sits ABOVE that 3 s ceiling on purpose, so a healthy stream
    /// is not chopped into one archive write per page — mid-burst durability is `maxHold`'s job, not
    /// the debounce's. (A value inside the gap range would still be CORRECT, just wasteful: banking
    /// is idempotent. It would, however, leave `maxHold` dead, which is the half that carries the
    /// guarantee.)
    public static let quiet: TimeInterval = 4

    /// Hard bound on how long acked-but-unbanked pages may sit in volatile memory. This is the load-
    /// bearing half: the debounce re-arms on every page, so during a CONTINUOUS handoff — the exact
    /// shape of the whole-night catch-up — only this bound ever fires. At 8 s the measured 43 s burst
    /// banks ~5 times on the way through instead of once at the end. Banking is idempotent
    /// (`EpochArchive.merge` dedups by counter), so splitting one burst across several banks costs
    /// nothing but the writes.
    public static let maxHold: TimeInterval = 8

    public enum Action: Equatable, Sendable {
        /// Bank immediately — the hold bound is reached; do not wait out the debounce.
        case bankNow
        /// Arm (or re-arm) the quiet debounce.
        case debounce
    }

    /// - Parameters:
    ///   - firstUnbankedAt: when the oldest not-yet-banked page arrived, or nil when nothing is held.
    ///   - now: current time (injected so this stays pure).
    public static func decide(firstUnbankedAt: Date?,
                              now: Date,
                              maxHold: TimeInterval = maxHold) -> Action {
        guard let first = firstUnbankedAt else { return .debounce }
        return now.timeIntervalSince(first) >= maxHold ? .bankNow : .debounce
    }
}

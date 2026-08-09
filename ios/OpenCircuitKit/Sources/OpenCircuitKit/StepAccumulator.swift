// Step accumulation (#34, premise re-derived in #192).
//
// WHAT THE RING ACTUALLY SENDS 🟢 — the `0x10`/`0x87` descriptor's step field (`[4:6]`, 16-bit
// big-endian, `DeviceStatus.steps`) is **NOT a running daily total**. It is a **quarter-hour
// bucket**: steps counted since the last wall-clock `:00` / `:15` / `:30` / `:45`, cleared back to
// 0 at each boundary. Re-derived 2026-08-09 over the whole local diagnostics corpus — 10,327
// descriptor frames, **two different rings** (`RingConn Gen2-03AD` FR02.018 America/New_York and
// `RingConn Gen2 Air-2F9F` FR04.009 Europe/Paris), 11 bundles spanning 06-26…08-09:
//   * **268 drops**, and every single one brackets a wall-clock quarter boundary. Not one is
//     explained by anything else; only 5 sit anywhere near local midnight, and those are just the
//     `00:00`/`00:15` boundaries doing what every other boundary does.
//   * The value never exceeds **746** in any capture, while the app's own folded day totals for
//     the same days are 2,611–4,566. A day counter cannot be 4–6× smaller than the day.
//   * The clear is **quarter-aligned with a ring-side settling lag** — a descriptor that arrives
//     within ~2 min after a boundary can still be carrying the previous bucket (measured max
//     **108 s**, `2026-06-27` bundle: the `13:15` bucket cleared at `13:16:49`).
// The old header claimed a CURRENT-DAY count on the strength of one 2026-06-14 ground truth (the
// app read 81 and `[4:6]` read 81). That single reading is still true — it was simply a partial
// bucket, and reading a day count into it was over-reach.
//
// WHY THE ARITHMETIC BELOW IS UNCHANGED ANYWAY — and why you must not "fix" it. Crediting the
// increment while the value climbs and crediting `newRaw` in full when it drops is *exactly*
// "sum the observed buckets": each drop closes a bucket at its last seen value and opens the next
// one at its first. The premise was wrong; the fold was already right. Measured on the same
// corpus (`desktop`-side replay of every descriptor frame, #192):
//   * current fold ...................... 31,638 steps
//   * "credit in full on any wall-clock bucket change" ... 33,183 (**+4.9 % — an OVER-count**)
//   * the same rule with a 120 s lag margin ............... 34,232 (**+8.2 %**)
// Both "fixes" double-count the settling lag: a frame at `14:30:00` still carrying the `14:15`
// bucket's 162 gets credited 162 a second time. The true residual error of the fold below is the
// opposite sign and far smaller: **27 boundary crossings, 423 steps, 1.3 % UNDER** across the
// whole corpus — the crossings where the new bucket had already climbed past the old bucket's
// last seen value, so no drop was visible. Online that case is **indistinguishable** from the
// settling lag (only the *next* frame's drop tells them apart), and the strictest safe rule that
// can tell them apart recovers just **+70 steps (+0.22 %)** corpus-wide. Steps have no ring-side
// backlog to heal them, so an over-count is as permanent as an under-count: 1.3 % low beats
// 4.9 % high. **Do not re-derive a wall-clock bucket-boundary credit here.**
//
// WHAT THE PREMISE DID CHANGE — `windowStart(sampleDate:previousSampleAt:dayStart:)`. A delta
// derived from a bucket can only represent steps taken *inside that bucket*, so the timestamped
// `StoredStepSample` window that carries it to HealthKit must not start earlier. It used to start
// at the previous reading (hours ago after a reconnect) or at local midnight (on the day's first
// reading) — measured on the corpus, **22 of 989 credits (5.3 % of all step mass)** carried a
// window that predated their own bucket, six of them spanning 11–22 hours for a few dozen steps.
// That is a HealthKit time-attribution defect, and it is the one thing here that was genuinely
// computing the wrong answer.
//
// This type is the pure, unit-tested core of the fold. `RingSession` persists the last raw counter
// + its day + its timestamp across sessions (UserDefaults) and `LocalStore` upserts the resulting
// delta into the per-day rollup; both stay thin callers so the tricky cases live here where they
// can be tested without CoreBluetooth or SwiftData.
//
// Pure (no Apple frameworks beyond Foundation) so it runs on the SwiftPM CLI.

import Foundation

/// Outcome of folding one raw counter observation into the running daily total.
public struct StepUpdate: Equatable, Sendable {
    /// Steps to add to the SAMPLE day's running total. Always `>= 0` — never negative, so a
    /// caller can add it blindly without re-checking for a drop.
    public let deltaToAdd: Int
    /// The ring's quarter-hour bucket rolled: the raw counter dropped below the last reading, so
    /// `newRaw` is the *new* bucket's count and is credited in full (`deltaToAdd == newRaw`),
    /// not `newRaw - previousRaw`.
    ///
    /// 🟢 This is the ORDINARY case, not an alarm: measured **268 rolls across 11 capture
    /// bundles ≈ 24 per device-day**. It used to be reported as a "mid-day reset (handoff /
    /// reboot / wrap)" anomaly; that flag encoded the refuted day-count premise and is gone (#192).
    /// A reboot or a 16-bit wrap presents identically and is not separable from a bucket roll
    /// without timestamps the ring does not give us.
    public let isReset: Bool

    public init(deltaToAdd: Int, isReset: Bool) {
        self.deltaToAdd = deltaToAdd
        self.isReset = isReset
    }
}

public enum StepAccumulator {
    /// Length of the ring's step bucket 🟢 — steps in `[4:6]` are cleared every 15 wall-clock
    /// minutes (`:00`/`:15`/`:30`/`:45`). See the header for the 268-roll derivation.
    public static let bucketSeconds: TimeInterval = 15 * 60

    /// How long after a boundary the ring may still report the PREVIOUS bucket 🟢 — measured max
    /// **108 s** across the corpus (`2026-06-27` bundle, the `13:15` bucket cleared at `13:16:49`;
    /// the `2026-08-05` bundle's `09:00` bucket cleared at `09:01:05`). Rounded up to 120 s and
    /// used only to widen `windowStart` backwards, never to credit steps.
    public static let clearLagAllowance: TimeInterval = 120

    /// Fold a freshly observed raw counter against the last one we recorded.
    ///
    /// - Parameters:
    ///   - previousRaw: the last raw counter we persisted, or `nil` when there is no prior
    ///     reading (first run ever / fresh pairing / app reinstall wiped both the day-totals
    ///     and this baseline together). With no baseline the honest reading of `newRaw` is
    ///     "this bucket so far", which is credited in full — crediting 0 instead would drop the
    ///     steps already counted in the quarter we happened to connect in.
    ///   - newRaw: the counter just observed (`DeviceStatus.steps`, 0…65535 — steps so far in the
    ///     ring's current quarter-hour, NOT a day total).
    ///   - dayChanged: the sample's calendar day differs from the day `previousRaw` was observed.
    ///     Across a day boundary the two readings are certainly in different buckets, so `newRaw`
    ///     is credited in full — the same thing a visible drop would do. **It does not recover the
    ///     morning:** the ring keeps no cumulative counter, so steps taken in quarters we never
    ///     observed are gone. The old comment here claimed otherwise; it was wrong (#192).
    public static func update(previousRaw: Int?, newRaw: Int, dayChanged: Bool) -> StepUpdate {
        guard let previous = previousRaw else {
            // No baseline — credit the current bucket so far rather than dropping it.
            return StepUpdate(deltaToAdd: newRaw, isReset: false)
        }
        if dayChanged {
            // New calendar day ⇒ certainly a new bucket: credit it whole, never subtract
            // yesterday's baseline even if today's raw has already climbed past it.
            return StepUpdate(deltaToAdd: newRaw, isReset: newRaw < previous)
        }
        if newRaw >= previous {
            // The bucket is still climbing (or a boundary passed without a visible drop, which is
            // indistinguishable from the ring's settling lag — see the header). Credit only the
            // increment: the conservative choice, and the measured-cheaper error.
            return StepUpdate(deltaToAdd: newRaw - previous, isReset: false)
        }
        // Drop ⇒ the bucket rolled (or, indistinguishably, a reboot/16-bit wrap). `newRaw` is the
        // new bucket's count so far and is credited whole.
        return StepUpdate(deltaToAdd: newRaw, isReset: true)
    }

    /// Start of the wall-clock quarter-hour containing `date`, in `calendar`'s time zone.
    ///
    /// Computed from the local minute-of-hour rather than by flooring the UNIX epoch, so it stays
    /// correct in the `:30` and `:45` UTC offsets (India, Nepal, Chatham) where an epoch floor
    /// would land 30/45 min off.
    public static func bucketStart(for date: Date, calendar: Calendar = .current) -> Date {
        let parts = calendar.dateComponents([.minute, .second, .nanosecond], from: date)
        let intoBucket = TimeInterval((parts.minute ?? 0) % 15) * 60
            + TimeInterval(parts.second ?? 0)
            + TimeInterval(parts.nanosecond ?? 0) / 1_000_000_000
        return date.addingTimeInterval(-intoBucket)
    }

    /// Window START to stamp on the `StoredStepSample` carrying `update(…).deltaToAdd`, i.e. the
    /// earliest instant those steps could have been taken.
    ///
    /// A descriptor delta is bounded by the ring's bucket: it can never represent a step taken
    /// before the current quarter-hour began (minus `clearLagAllowance`, because a frame arriving
    /// just after a boundary may still be reporting the previous bucket). So the window is the
    /// previous reading's timestamp — the narrow, accurate case for a steady stream — **floored**
    /// to that bucket start, which is what a reconnect after a gap, and the day's first reading,
    /// actually deserve.
    ///
    /// Before #192 those two cases stamped `previousSampleAt` from hours earlier, or local
    /// midnight; measured on the corpus, 22 of 989 credits (5.3 % of all step mass) were smeared
    /// that way, six of them across 11–22 hours.
    ///
    /// - Parameters:
    ///   - sampleDate: when the descriptor arrived (the window END).
    ///   - previousSampleAt: when the reading `deltaToAdd` was folded against arrived; pass `nil`
    ///     on a day rollover or a fresh baseline, where there is no prior same-day reading.
    ///   - dayStart: start of `sampleDate`'s calendar day. The window never crosses it, so a
    ///     sample always stays on its own day's row.
    /// - Returns: a date in `[dayStart, sampleDate]`.
    public static func windowStart(sampleDate: Date,
                                   previousSampleAt: Date?,
                                   dayStart: Date,
                                   calendar: Calendar = .current) -> Date {
        let lagged = sampleDate.addingTimeInterval(-clearLagAllowance)
        let floor = max(dayStart, min(bucketStart(for: lagged, calendar: calendar), sampleDate))
        guard let previous = previousSampleAt, previous >= floor, previous <= sampleDate else {
            return floor
        }
        return previous
    }
}

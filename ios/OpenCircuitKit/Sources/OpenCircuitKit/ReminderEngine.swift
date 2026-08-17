// Pure reminder-firing predicates (#84). Three kinds: sedentary/move, ring-not-worn,
// and bedtime wind-down. All logic is side-effect-free — callers route survivors through
// the shared `NotificationGate` (DND + backoff) in `HealthNotificationCenter`.
//
// "Activity" for the sedentary rule is a nonzero step delta from the ring. The caller
// supplies `lastActivityAt` (from UserDefaults). nil → false (never a cold-launch nag).

import Foundation

// MARK: - Reminder kinds

/// Stable identifiers for each reminder type. The raw value is used as the
/// `UNUserNotificationRequest` identifier AND as the de-dupe key in the shared
/// `HealthNotificationStore` — must stay stable across launches.
public enum ReminderKind: String, CaseIterable, Sendable {
    case sedentary = "reminder.sedentary"
    case wear      = "reminder.wear"
    case bedtime   = "reminder.bedtime"
}

// MARK: - Sedentary / move reminder

/// Fire if the user has been physically inactive for longer than `interval` and we're
/// inside the daily active window. "Activity" = a nonzero step delta from the ring;
/// `lastActivityAt` is nil until the first step arrives so the rule stays silent on a
/// fresh session / day the ring isn't worn (never a false positive).
///
/// ══ A RING ON THE CHARGER CANNOT COUNT STEPS ══
///
/// 🟢 Reported false positive: "Move reminder — you've been inactive for a while" arriving while the
/// ring sat on the charger. The mechanism is the same fallacy `WearReminder` below was rewritten to
/// avoid, one layer over: `lastActivityAt` only advances when a nonzero step delta arrives from the
/// ring, so ANY stretch the ring is off the finger — charging, in the case, on a desk — reads as a
/// stretch of zero steps. A ~50-minute charge is therefore indistinguishable from 50 minutes of
/// sitting still, and the nag lands on a user who may have been walking the whole time. Absence of
/// measurement is not evidence of inactivity.
///
/// So the rule now needs the ring to have been ON THE FINGER for the whole window it is about to
/// complain about. Three suppressions carry that:
///
///  1. `isOnCharger` — the live 🟢 `[2] == 0x04` descriptor byte (`DeviceStatus.isOnCharger`). Instant
///     and definitive: whatever the step field says, the ring is docked and measuring nothing.
///  2. `lastOffFingerAt` — the newest moment we OBSERVED the ring off the finger (docked, or a cold
///     skin temperature under `ActivityPeriod.wornMinTemperatureC` — `DeviceStatus.isWorn`). Only
///     silence entirely NEWER than that observation is measured inactivity, so the clock effectively
///     restarts when the ring goes back on: after a charge the user gets a full `interval` of real,
///     measured stillness before the first nudge, instead of inheriting the charge as "inactivity".
///  3. `lastRingDataAt` — the charge that happens while the LINK IS DOWN leaves no descriptor to
///     stamp (1) or (2) with, and the ring's step field carries no history to recover it from: the
///     first frame after the reconnect is warm and current, while `lastActivityAt` still dates from
///     before the charge. A window we heard nothing at all across is unobserved for the same reason
///     a charge is, so a ring that has been silent for the whole `interval` earns no nudge either.
///     Note this is NOT the wear rule's discredited "silence ⇒ not worn" inference: silence here
///     only ever WITHHOLDS a claim, never makes one.
///
/// All three are suppressions — they never CAUSE a fire, so a ring that reports none of them (an old
/// build's persisted state, a session that has seen no descriptor yet) behaves exactly as before.
public struct SedentaryReminder: Equatable, Sendable {
    /// Inactivity threshold before firing.
    public var interval: TimeInterval
    /// Minutes-since-midnight window within which the reminder may fire. Default 08:00–21:00.
    public var activeStartMinutes: Int
    public var activeEndMinutes: Int

    public init(interval: TimeInterval = 50 * 60,
                activeStartMinutes: Int = 8 * 60,
                activeEndMinutes: Int = 21 * 60) {
        self.interval = interval
        self.activeStartMinutes = activeStartMinutes
        self.activeEndMinutes = activeEndMinutes
    }

    /// True when inactive for ≥ `interval`, inside the active window, and the ring was on the
    /// finger for that whole stretch (so the stillness was actually MEASURED).
    ///
    /// - Parameters:
    ///   - lastActivityAt: newest moment a nonzero step delta arrived, or nil before the first one.
    ///   - isOnCharger: the ring reports itself docked right now (🟢 descriptor `[2] == 0x04`).
    ///   - lastOffFingerAt: newest moment we observed the ring off the finger — docked, or reading
    ///     colder than `ActivityPeriod.wornMinTemperatureC`. Aged against `now`, like the wear rule's
    ///     worn-evidence stamp, with the same `max(0, …)` clamp so a stamp dated ahead of `now` (ring
    ///     clock drift, a timezone change between the frame and this pass) reads as "just now"
    ///     deliberately rather than sliding through on a negative interval.
    ///   - lastRingDataAt: newest moment any frame arrived. `nil` means "no information" and does NOT
    ///     suppress — every path that writes `lastActivityAt` writes this one too, so in practice a
    ///     nil here alongside a non-nil activity stamp only occurs on legacy persisted state, where
    ///     the pre-existing behaviour is the safer answer.
    public func shouldFire(lastActivityAt: Date?, now: Date,
                           isOnCharger: Bool = false,
                           lastOffFingerAt: Date? = nil,
                           lastRingDataAt: Date? = nil,
                           calendar: Calendar = .current) -> Bool {
        guard !isOnCharger else { return false }
        guard let last = lastActivityAt else { return false }
        guard now.timeIntervalSince(last) >= interval else { return false }
        if let off = lastOffFingerAt,
           max(0, now.timeIntervalSince(off)) < interval {
            return false
        }
        if let heard = lastRingDataAt,
           max(0, now.timeIntervalSince(heard)) >= interval {
            return false
        }
        let c = calendar.dateComponents([.hour, .minute], from: now)
        let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return m >= activeStartMinutes && m < activeEndMinutes
    }
}

// MARK: - Wear reminder

/// Fire when the ring appears to be OFF THE FINGER. Opt-in (default off) — never fires before the
/// first connection (`everConnected = false`).
///
/// ══ SILENCE IS NOT EVIDENCE OF NOT-WEARING ══
///
/// 🟢 A tester reported "alerts that the ring is not detected even though I am wearing it… once or
/// twice a day, and overnight" (2026-08-12). Their diagnostics bundle shows why: the sync activity
/// log is dominated by `session replaced — no drain ran` and the epoch archive carries multi-hour
/// holes — the BLE LINK drops routinely while the ring keeps recording perfectly well on the
/// finger, and the backlog lands on the next successful drain. The old predicate ("no frame in
/// 20 min") measured the health of OUR CONNECTION and reported it to the user as a fact about
/// their ring. It is wrong for exactly the population it fires on hardest — the users whose link is
/// flakiest — and the user can do nothing about it, which is the definition of a bad alert.
///
/// So silence is now only ONE necessary condition. Three suppressions carry the actual evidence:
///
///  1. `isConnected` — a live link with a quiet notify pipe means the ring is right there. Whatever
///     is wrong, "put your ring back on" is the wrong instruction.
///  2. `lastWornEvidenceAt` — the newest DEVICE timestamp we hold for an epoch the ring recorded
///     while WORN (an epoch carrying a heart rate; the unworn template decodes no HR at all — see
///     `BulkRecord.Layout.idle`). This arrives late by design, on the drain that heals the gap, and
///     it is retro-active proof that the silent window was worn. Only silence NEWER than that proof
///     can still be a genuine take-off.
///  3. `inSleepWindow` — the tester got this at night. Nobody acts on a wear nag while asleep, and
///     the overnight link is the least reliable of all; a nag here is pure cost.
///
/// The default interval is also an hour rather than 20 minutes: a background drain cadence measured
/// in tens of minutes made 20 min indistinguishable from a normal quiet stretch.
///
/// A fourth suppression covers the charger (same report as `SedentaryReminder` above): if the newest
/// descriptor we hold said 🟢 ON THE CHARGER, we did not fail to detect the ring — we detected it,
/// and it is docked. "Ring not detected · Put your ring back on" is then simply a false statement,
/// aimed at a user who is deliberately charging and would have to interrupt the charge to comply.
/// It is bounded by `chargerGrace` rather than absolute, so a ring that is dropped in a drawer
/// straight off the charger still earns the nag once the charge could plausibly have finished.
public struct WearReminder: Equatable, Sendable {
    /// Gap without ring data that triggers the reminder.
    public var noDataInterval: TimeInterval

    /// How long a last-seen-on-charger reading keeps suppressing the reminder. 4 h is deliberately
    /// well past a full RingConn Gen-2 charge (~1.5 h from empty) so an ordinary top-up is covered
    /// end to end, while a ring parked off the finger all afternoon still gets nagged about.
    public var chargerGrace: TimeInterval

    public init(noDataInterval: TimeInterval = 60 * 60,
                chargerGrace: TimeInterval = 4 * 3600) {
        self.noDataInterval = noDataInterval
        self.chargerGrace = chargerGrace
    }

    /// True when the ring looks genuinely un-worn: nothing has arrived for ≥ `noDataInterval`, we
    /// are not currently connected, we are not inside the user's sleep window, and no drained epoch
    /// proves the ring was on the finger during the silence.
    ///
    /// - Parameters:
    ///   - lastRingDataAt: newest moment ANY frame arrived (wall-clock), or nil.
    ///   - everConnected: a ring has been paired at least once. nil-safe gate, unchanged.
    ///   - lastWornEvidenceAt: newest DEVICE timestamp of an epoch recorded while worn, or nil when
    ///     we hold none. Deliberately compared against `now`, not against `lastRingDataAt`: it is
    ///     proof about the RING'S OWN timeline, so it must age out on the same clock the silence does.
    ///   - isConnected: a ring is connected right now.
    ///   - inSleepWindow: `now` falls inside the user's configured sleep schedule.
    ///   - lastKnownOnCharger: the NEWEST descriptor we hold reported the ring docked (🟢
    ///     `[2] == 0x04`). It describes the ring as of `lastRingDataAt` — that pairing is what makes
    ///     it ageable — so pass the state carried by the last frame, not "was ever on the charger".
    public func shouldFire(lastRingDataAt: Date?, now: Date, everConnected: Bool,
                           lastWornEvidenceAt: Date? = nil,
                           isConnected: Bool = false,
                           inSleepWindow: Bool = false,
                           lastKnownOnCharger: Bool = false) -> Bool {
        guard everConnected, !isConnected, !inSleepWindow else { return false }
        // We know where the ring is: on the charger, as of the last frame. Not "not detected".
        // Aged on the same clock as the silence (and clamped for the same drift reason), so the
        // suppression expires with `chargerGrace` instead of persisting for a ring that left the
        // charger during a link outage and never came back.
        if lastKnownOnCharger, let last = lastRingDataAt,
           max(0, now.timeIntervalSince(last)) < chargerGrace {
            return false
        }
        // Positive proof the ring was worn recently outranks the absence of frames. A worn epoch
        // dated within `noDataInterval` of now means the ring was on the finger for the very
        // stretch the silence rule is about to complain about.
        // `max(0, …)` because a worn timestamp NEWER than `now` (a ring whose clock has drifted
        // ahead, or a device timezone change between the drain and this pass) yields a NEGATIVE
        // age. Negative is trivially < the interval, so the untreated comparison happened to
        // suppress — but only by accident, and a future-dated evidence stamp is no evidence at all.
        // Clamping makes "newer than now" mean "as fresh as possible", which is the same verdict
        // reached deliberately rather than by sign.
        if let worn = lastWornEvidenceAt,
           max(0, now.timeIntervalSince(worn)) < noDataInterval {
            return false
        }
        guard let last = lastRingDataAt else { return true }   // ever connected but no data
        return now.timeIntervalSince(last) >= noDataInterval
    }
}

// MARK: - Bedtime reminder

/// Fire once inside the window [bedMinutes − minutesBefore, bedMinutes) to give the
/// user a heads-up before their configured bedtime. The window is in minutes-since-
/// midnight and wraps past midnight correctly. Returns false when bed == wake (schedule
/// not configured), matching `SleepWindow`'s convention.
public struct BedtimeReminder: Equatable, Sendable {
    /// How many minutes before the bedtime the window opens.
    public var minutesBefore: Int

    public init(minutesBefore: Int = 30) {
        self.minutesBefore = minutesBefore
    }

    /// True when the current time-of-day falls inside [bed − minutesBefore, bed).
    public func shouldFire(now: Date, bedMinutes: Int, wakeMinutes: Int,
                           calendar: Calendar = .current) -> Bool {
        guard bedMinutes != wakeMinutes else { return false }   // not configured
        let windowStart = (bedMinutes - minutesBefore + 1440) % 1440
        let windowEnd   = bedMinutes
        let c = calendar.dateComponents([.hour, .minute], from: now)
        let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return minuteInWindow(m, start: windowStart, end: windowEnd)
    }

    private func minuteInWindow(_ m: Int, start: Int, end: Int) -> Bool {
        if start == end { return false }
        if start < end  { return m >= start && m < end }
        return m >= start || m < end   // wraps past midnight
    }
}

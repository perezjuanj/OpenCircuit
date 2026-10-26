import Foundation
import OpenCircuitKit
import SwiftData
import ZeppKit

// Decision 50b (#253): the backstop that offers a stored strap night to Apple Health when no sync's
// flush carried it. A sync hands a night to its flush only through `HelioSyncResult.nights`, which
// covers that one sync (and is gone after a relaunch), so a night whose every re-delivery after its
// first store was kept as thinner, or that any other path left behind, was never offered again.
// Decision 57 (#262): the newest stored night too, 3 hours after its end. Decision 58a (#274) withdrew
// 57's faster path for a night ending near the scheduled wake: the strap lets the phone read a sleep
// record while the sleep is still going on, so a stored end near the wake time can be minutes before
// the sync that read it, hours before the real wake.

extension LocalStore {

    /// How far back the backstop looks: a stranded night older than a week stays in the app.
    static let strapNightHealthLookback: TimeInterval = 7 * 86_400

    /// Decision 57a (#262): how long after its end the NEWEST stored night must have stayed the newest
    /// before the backstop may claim it, whatever clock time it ended at (decision 58a, #274). Juan's
    /// choice (1 h / 3 h / 6 h). A night written too early is replaced only by a copy that extends it
    /// (decision 58b), so don't shorten it without asking Juan.
    static let strapNewestNightHealthBuffer: TimeInterval = 3 * 3600

    /// Decision 58b (#274): how much later than the night already in Apple Health a re-delivered night
    /// must end to replace it. The strap re-stages a night's start (and its end by a few minutes)
    /// between deliveries; that is jitter, not growth. A night still in progress grows by far more
    /// than this between the sync that read it early and the final record.
    nonisolated static let strapNightExtensionMinimum: TimeInterval = 10 * 60

    /// Decision 58b (#274): whether `incoming` extends the night already written to Apple Health
    /// (`written`, its mirror record's span), so that it may replace it: the two overlap (touching
    /// edges don't) and `incoming` ends at least `strapNightExtensionMinimum` after `written` does.
    /// A night that ends earlier, at the same time or less than 10 minutes later, or that only starts
    /// differently, doesn't.
    nonisolated static func strapNightExtends(_ incoming: DateInterval, written: DateInterval) -> Bool {
        incoming.start < written.end && written.start < incoming.end
            && incoming.end >= written.end.addingTimeInterval(strapNightExtensionMinimum)
    }

    /// The stored hypnograms of the strap's nights that never reached Apple Health, for
    /// `HelioConnection.flushStrap` to offer next to its sync's own nights (decision 50b). A night
    /// qualifies when all of these hold:
    /// - the strap owns it (decision 28a, the rule it was stored under);
    /// - it isn't manually edited (the edit reconcile owns those);
    /// - it has a stored hypnogram;
    /// - it has no Health mirror record for its key, in the zone it was stored in or the current one,
    ///   or its stored segments extend the record's span (decision 58e, `storedNightAwaitsHealth`);
    /// - the writer hasn't declined this exact stored hypnogram (#259);
    /// The segments offered carry the awake fill from `timeline`'s stored heart rate (decision 74,
    /// `helioAwakeFilled`), so they are the segments the sync's own store path gives the night.
    /// - it began within `strapNightHealthLookback` of `now`;
    /// - a LATER stored night (any device, keyed no later than `now`, #259) exists, or, for the
    ///   newest night itself (decision 57), more than `strapNewestNightHealthBuffer` (3 h) has passed
    ///   since its end. Its end is the later of the row's `inBedEnd` and its hypnogram's last segment.
    ///
    /// Why the newest night waits 3 hours, whatever clock time it ended at (decision 58a, #274): a
    /// stored newest night can be a night still in progress. The strap lets the phone read its sleep
    /// record while the sleep goes on, so a sync can store an end minutes before the sync itself and
    /// hours before the real wake; and after a mid-night awakening (stored 23:00–02:00, back to bed at
    /// 02:30), 28f stitches the later sleep into the night. Decision 57d's faster path (once settled,
    /// for an end near the sleep schedule's wake time) wrote such a partial night on a later short
    /// sync. The sync that carries the final night still offers it through its own nights, behind the
    /// settle margin, and that copy replaces a shorter written one (decision 58b).
    ///
    /// `now` must be the real wall clock at the check (`flushStrap`'s default), never a sync's start.
    ///
    /// Decision 78a (#332): a night `finalization` covers (it ended by the Sleep Focus end plus its
    /// slack, in a flush that may use that end) skips the 3 h hold: Focus ending says it is over.
    /// Every other night waits exactly as above.
    ///
    /// Empty with an empty ownership log (a ring-only install): no query runs.
    func strapNightsAwaitingHealth(timeline: SyncDeviceID, now: Date,
                                   finalization: SleepFocusFinalization.Nights = .none) -> [[SleepSegment]] {
        let log = Self.ownershipLog()
        guard !log.isEmpty, let newest = newestSleepNightKey(notAfter: now) else { return [] }
        let family = DeviceOwnershipLog.Family(timeline: timeline)
        let since = now.addingTimeInterval(-Self.strapNightHealthLookback)
        let descriptor = FetchDescriptor<StoredSleepSummary>(
            predicate: #Predicate { $0.inBedStart >= since },
            sortBy: [SortDescriptor(\.night, order: .forward)])
        return ((try? context.fetch(descriptor)) ?? []).compactMap { row in
            guard let segments = strapSegmentsAwaitingHealth(row, log: log, family: family) else { return nil }
            let end = max(row.inBedEnd, segments.map(\.end).max() ?? row.inBedEnd)
            guard row.night < newest || now.timeIntervalSince(end) > Self.strapNewestNightHealthBuffer
                    || finalization.finalizes(nightEndingAt: end) else { return nil }
            // Decision 74 (#278): the night as the store path gives it, with its awake fill from the
            // stored heart rate (a row a build before 74 stored has none). Inside the segments' span.
            guard let start = segments.map(\.start).min() else { return segments }
            return helioAwakeFilled(segments, window: DateInterval(start: start, end: segments.map(\.end).max() ?? start),
                                    device: timeline)
        }
    }

    /// Decision 57b (#262): when the newest stored strap night that hasn't reached Apple Health leaves
    /// its 20-minute settle margin (`SleepHealthGate`), while it is still inside it; nil otherwise. A
    /// strap flush whose own sync no longer carries that night (the strap stopped re-delivering it)
    /// still asks for the margin refresh with this (`StrapNightRefresh.aim`), so opening the app
    /// doesn't drop a refresh a background wake had asked for. Same qualifying rules as
    /// `strapNightsAwaitingHealth`, on the newest row only. nil with an empty ownership log.
    func newestStrapNightSettles(timeline: SyncDeviceID, now: Date) -> Date? {
        let log = Self.ownershipLog()
        guard !log.isEmpty, let row = try? latestSleepSummary(),
              row.inBedStart >= now.addingTimeInterval(-Self.strapNightHealthLookback),
              let segments = strapSegmentsAwaitingHealth(row, log: log, family: DeviceOwnershipLog.Family(timeline: timeline))
        else { return nil }
        let end = max(row.inBedEnd, segments.map(\.end).max() ?? row.inBedEnd)
        return SleepHealthGate.isSettled(latestSegmentEnd: end, now: now) ? nil : end.addingTimeInterval(SleepHealthGate.settleMargin)
    }

    /// Decision 78b (#332): the night a strap Sleep Focus run that ended Focus at `focusEnd` was for:
    /// the newest stored night the strap owns (decision 28a) that ended at or before `focusEnd` plus
    /// `SleepFocusFinalization.nightEndSlack` and no earlier than `SleepFocusStrapFollowUp.nightLookback`
    /// before it, and whether it has a Health mirror record. Its end is the later of `inBedEnd` and the
    /// hypnogram's last segment, as the backstop reads it. `.none` with an empty ownership log.
    func strapFocusNight(timeline: SyncDeviceID, focusEnd: Date) -> SleepFocusStrapFollowUp.Night {
        let log = Self.ownershipLog()
        guard !log.isEmpty else { return .none }
        let family = DeviceOwnershipLog.Family(timeline: timeline)
        let latest = focusEnd.addingTimeInterval(SleepFocusFinalization.nightEndSlack)
        let earliest = focusEnd.addingTimeInterval(-SleepFocusStrapFollowUp.nightLookback)
        // A night is never longer than a day, so one that ends after `earliest` began after this.
        let since = earliest.addingTimeInterval(-86_400)
        let descriptor = FetchDescriptor<StoredSleepSummary>(predicate: #Predicate { $0.inBedStart >= since })
        let night = ((try? context.fetch(descriptor)) ?? [])
            .compactMap { row -> (row: StoredSleepSummary, end: Date)? in
                guard row.inBedEnd > row.inBedStart,
                      log.owner(ofNightFrom: row.inBedStart, to: row.inBedEnd) == family else { return nil }
                let end = max(row.inBedEnd, SleepHypnogramCodec.decode(row.hypnogramData).map(\.end).max() ?? row.inBedEnd)
                return end >= earliest && end <= latest ? (row, end) : nil
            }
            .max { $0.end < $1.end }
        guard let night else { return .none }
        return MirroredNightOverlay.hasRecord(storedNight: night.row.night) ? .written : .storedNotWritten
    }

    /// `row`'s stored hypnogram when the row is a strap night that may still go to Apple Health: the
    /// strap owns it, it isn't manually edited, its hypnogram isn't empty, the writer hasn't declined
    /// this exact hypnogram, and its mirror record allows it (`storedNightAwaitsHealth`: none, or the
    /// stored night extends the written span, decision 58e).
    private func strapSegmentsAwaitingHealth(_ row: StoredSleepSummary, log: DeviceOwnershipLog,
                                             family: DeviceOwnershipLog.Family) -> [SleepSegment]? {
        guard row.inBedEnd > row.inBedStart, !row.isManuallyEdited,
              log.owner(ofNightFrom: row.inBedStart, to: row.inBedEnd) == family,
              // The writer declined this exact stored night before (#259): it would again.
              StrapNightDeclinedOverlay.load(storedNight: row.night) != row.hypnogramData else { return nil }
        let segments = SleepHypnogramCodec.decode(row.hypnogramData)
        guard let start = segments.map(\.start).min(), let end = segments.map(\.end).max(), end > start,
              storedNightAwaitsHealth(storedNight: row.night, window: DateInterval(start: start, end: end)) else { return nil }
        return segments
    }

    /// Whether the stored night keyed `night`, offered as `window` (its stored segments' span), may go
    /// to Apple Health as far as its mirror record goes: it has none, in the zone it was stored in or the
    /// current one (#259: a time-zone change must not re-offer a week of nights Health already holds),
    /// or `window` extends the written span (decision 58e, 58b's `strapNightExtends` applied to the
    /// stored night). The exception exists for a night stored over a shorter written one inside its
    /// settle margin and then re-delivered a little thinner: the merge keeps it, so no sync hands it to
    /// the flush again. After the writer's rewrite the record's span is the union, which covers the
    /// stored night, so this is false again and nothing is offered twice. A record that can't be read,
    /// or has no span, counts as written.
    func storedNightAwaitsHealth(storedNight night: Date, window: DateInterval) -> Bool {
        guard MirroredNightOverlay.hasRecord(storedNight: night) else { return true }
        guard let record = MirroredNightOverlay.record(storedNight: night), record.spanEnd > record.spanStart else { return false }
        return Self.strapNightExtends(window, written: DateInterval(start: record.spanStart, end: record.spanEnd))
    }

    /// The newest stored night key that is not after `now`, from any device: the backstop's guard.
    ///
    /// #259: it was `latestSleepSummary()`, the newest key of all. A key is the start of the day the
    /// night ended on, so a real night's key is never after the moment it is read: its wake has
    /// passed. A key after `now` can only come from a future-dated night (a device clock set ahead),
    /// and as the newest key it would hold back every night before it until real time caught up.
    /// Such a row is not judged here; it is just not allowed to be the guard.
    private func newestSleepNightKey(notAfter now: Date) -> Date? {
        var descriptor = FetchDescriptor<StoredSleepSummary>(
            predicate: #Predicate { $0.night <= now },
            sortBy: [SortDescriptor(\.night, order: .reverse)])
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first?.night
    }

    /// Note that the writer declined `segments` (`HealthKitWriter.MirrorOutcome.declined`) when they
    /// are a stored night's hypnogram exactly, so the backstop stops offering that night (#259).
    ///
    /// Without this, a night the writer refuses without leaving a mirror record — another device
    /// keeps it, or it is thinner than its card — was offered on every strap flush for 7 days, each
    /// offer costing a full-table overlap query on the main actor, to the same refusal each time.
    ///
    /// What is noted is the stored HYPNOGRAM, not just the night: a night whose stored hypnogram
    /// changes is a different offer, and is offered again. A `failed` write is never noted (it may
    /// pass next time), and nor is a night whose mirror record keeps it out anyway. A night that
    /// extends its mirror record IS noted (decision 58e): the backstop offers it despite the record,
    /// so without the note a writer that keeps declining it (the other device keeps it, or it is
    /// thinner than its card) would meet it on every strap flush for the whole lookback. Nothing with
    /// an empty ownership log.
    func noteStrapNightDeclined(_ segments: [SleepSegment]) {
        guard !Self.ownershipLog().isEmpty,
              let start = segments.map(\.start).min(), let end = segments.map(\.end).max(), end > start,
              let row = try? sleepSummaryOverlapping(start: start, end: end),
              !row.hypnogramData.isEmpty,
              storedNightAwaitsHealth(storedNight: row.night, window: DateInterval(start: start, end: end)),
              // Decision 74: the backstop offers the stored hypnogram with its awake fill, so the two
              // are compared without it (a night with no fill: exactly as before).
              HelioSleepSelection.withoutAwakeFill(SleepHypnogramCodec.decode(row.hypnogramData))
                == HelioSleepSelection.withoutAwakeFill(segments) else { return }
        StrapNightDeclinedOverlay.save(row.hypnogramData, storedNight: row.night)
    }
}

/// The stored hypnogram of a strap night the writer declined, by its stored night key (#259).
/// Keyed by the key's exact instant rather than the current zone's start of day, so a time-zone
/// change can't lose it. A night re-keyed by a migration loses its note and is offered once more,
/// which is the behaviour before this existed.
enum StrapNightDeclinedOverlay {
    private static func key(_ night: Date) -> String {
        "sleep.strap.declined.night.\(night.timeIntervalSince1970)"
    }

    static func load(storedNight night: Date) -> Data? {
        UserDefaults.standard.data(forKey: key(night))
    }

    static func save(_ hypnogram: Data, storedNight night: Date) {
        UserDefaults.standard.set(hypnogram, forKey: key(night))
    }

    static func clear(storedNight night: Date) {
        UserDefaults.standard.removeObject(forKey: key(night))
    }
}

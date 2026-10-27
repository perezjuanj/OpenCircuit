import Foundation
import OpenCircuitKit
import SwiftData
import ZeppKit

// Decision 77 (#328): a strap night's in-bed lead-in, from the strap's own STORED rows.
//
// The arithmetic is `HelioInBedLeadIn` in ZeppKit; this file only gathers its inputs, the same way
// `helioAwakeFilled` gathers decision 74's (77b: never a sync's fetched minutes, so every re-delivery
// of a night derives the same lead-in, whatever that sync fetched).
//
// WHOSE ROWS. Heart rate: `.heartRate` samples carrying the strap's own device id. Steps: the strap
// writes its per-minute steps as `StoredStepSample` rows (`ingestHelioStepMinutes`), which carry NO
// device column. They are attributed by ownership, the store's rule for every untagged row (decision
// 28): both step writers keep a row wholly inside time its device owns (the strap's `ingestHelioStepMinutes`
// and the ring's `addDailySteps`, decision 28b), so a step row in time the strap owns is the strap's.
// That is why the walk never reaches before the strap's ownership start: the floor below is the one
// thing that makes every row it reads the strap's.

extension LocalStore {

    /// Decision 77a: `night` with its lead-in from the stored rows (`helioLeadInStart`), or `night`
    /// unchanged when it has none (or already carries one).
    ///
    /// `sleeps` are the windows of the sync's own strap sleeps (`ownedNights`): a sleep the same sync
    /// will store as a nap AFTER the nights (`storeNaps`) is a sleep too, and the lead-in never covers
    /// one (77c), so it doesn't wait for the nap's row to exist.
    func helioWithLeadIn(_ night: HelioSleepSelection.Night, sleeps: [DateInterval] = [],
                         device: SyncDeviceID) -> HelioSleepSelection.Night {
        guard night.leadIn == nil, let start = helioLeadInStart(night, sleeps: sleeps, device: device) else { return night }
        return night.withLeadIn(from: start)
    }

    /// Decision 77a: where `night`'s lead-in starts, from the strap's stored heart rate and steps, or nil.
    ///
    /// It never starts before (77c): the end of the latest sleep that ended at or before the night's
    /// first in-bed start (a stored night or nap of either device, recorded or edited window, or one of
    /// `sleeps`), nor the start of the strap's ownership stretch containing that in-bed start (28).
    func helioLeadInStart(_ night: HelioSleepSelection.Night, sleeps: [DateInterval] = [],
                          device: SyncDeviceID) -> Date? {
        let window = night.windowWithoutLeadIn
        let inBedStart = window.start
        guard let firstSleep = night.segments
            .filter({ $0.stage == .asleepCore || $0.stage == .asleepDeep || $0.stage == .asleepREM })
            .map(\.start).min() else { return nil }
        let log = Self.ownershipLog()
        guard log.owns(device, at: inBedStart) else { return nil }
        let earliest = max(log.ownershipStart(at: inBedStart), helioLatestSleepEnd(atOrBefore: inBedStart, sleeps: sleeps))
        let from = max(earliest, inBedStart.addingTimeInterval(-HelioInBedLeadIn.maxLength))
        guard from < inBedStart else { return nil }
        let to = firstSleep.addingTimeInterval(HelioInBedLeadIn.sleepingLevelSpan)

        let kindRaw = MetricKind.heartRate.rawValue
        let deviceID = device.rawValue
        let heartRate = FetchDescriptor<StoredSample>(
            predicate: #Predicate { $0.kindRaw == kindRaw && $0.deviceID == deviceID && $0.start >= from && $0.start < to && $0.value > 0 },
            sortBy: [SortDescriptor(\.start)])
        let beats = ((try? context.fetch(heartRate)) ?? []).map { HelioInBedLeadIn.HeartRateMinute(time: $0.start, bpm: $0.value) }
        let steps = FetchDescriptor<StoredStepSample>(
            predicate: #Predicate { $0.start < inBedStart && $0.end > from && $0.delta > 0 })
        let walked = ((try? context.fetch(steps)) ?? []).map { HelioInBedLeadIn.StepMinute(start: $0.start, end: $0.end, steps: $0.delta) }
        return HelioInBedLeadIn.start(inBedStart: inBedStart, firstSleep: firstSleep, heartRate: beats,
                                      steps: walked, earliest: earliest)
    }

    /// Decision 77c: where the lead-in before `instant` (a night's first in-bed start) must stop: the
    /// latest end, at or before `instant`, of any stored night (either device, its recorded or edited
    /// window), and, for a stored nap (either device) or one of `sleeps` that starts before `instant`,
    /// its end or `instant`, whichever is earlier. A nap that runs into the in-bed start (one the night
    /// is about to absorb and prune) leaves no room for a lead-in over it (77j: a lead-in never lies
    /// over a nap). A stored night that runs into `instant` is this night's own earlier copy and is
    /// not a sleep before it. `.distantPast` when none.
    ///
    /// The clamp applies when the night is derived. A night stored BEFORE the sync that first sees a nap
    /// more than 60 min before its sleep onset was stored with a lead-in over that nap; the next
    /// re-delivery replaces it while the night is not in Apple Health (decision 79e,
    /// `helioStoredLeadInIsStale`). Known limit, documented and not fixed (ZEPP_PROTOCOL.md §21.6): a
    /// night already WRITTEN keeps that lead-in (77f, forward-only), so it can lie over the nap by up to
    /// the clamp difference (at most the 120 min cap): in Health an `inBed` overlap and an `awake` sample
    /// over the nap's asleep one, asleep time not counted twice. It converges only when the night comes
    /// back extended (58b). Rare on the production fetch: a session nap comes with any later sync of the
    /// night, and a block nap with the night's own activity round.
    func helioLatestSleepEnd(atOrBefore instant: Date, sleeps: [DateInterval] = []) -> Date {
        // Rows are keyed by the day they end on, naps by their start: two days back reaches every
        // sleep that can end within `maxLength` of `instant`.
        let lo = instant.addingTimeInterval(-2 * 86_400)
        var ends: [Date] = []
        for row in (try? sleepSummaries(from: lo, to: instant.addingTimeInterval(86_400))) ?? [] {
            if row.inBedEnd > row.inBedStart { ends.append(row.inBedEnd) }
            if row.isManuallyEdited, row.editedInBedEnd > row.editedInBedStart { ends.append(row.editedInBedEnd) }
        }
        ends = ends.filter { $0 <= instant }
        var napSpans = sleeps
        for nap in (try? naps(from: lo, to: instant)) ?? [] {
            let start = min(nap.start, nap.effectiveStart), end = max(nap.end, nap.effectiveEnd)
            if end > start { napSpans.append(DateInterval(start: start, end: end)) }
        }
        ends += napSpans.filter { $0.start < instant }.map { min($0.end, instant) }
        return ends.max() ?? .distantPast
    }
}

extension LocalStore {
    /// Decision 79e (#331 item 1): whether `night` (`sleep` with its lead-in) replaces the stored copy of
    /// its night instead of going to the merge: only while the night is NOT written to Apple Health
    /// (`writtenNightSpan(for: sleep)`; a written night is left as 77f leaves it) and only a stored copy
    /// with a stale lead-in (`helioStoredLeadInIsStale`).
    func helioReplacesStoredCopy(with night: HelioSleepSelection.Night, sleep: HelioSleepSelection.Night) -> Bool {
        writtenNightSpan(for: sleep) == nil && helioStoredLeadInIsStale(for: night)
    }

    /// Decision 79e: whether the stored copy of `night` (the row its window overlaps) is the
    /// same night with a lead-in that starts EARLIER than `night`'s: an unedited strap night whose sleep
    /// window (its window without its lead-in) is `night`'s, within a second, stored with a lead-in from
    /// before `night`'s start. That copy was stored before a nap that now clamps the lead-in (77c), and
    /// the merge would keep it (the same sleep, more time in bed). False for every other stored row: a
    /// different sleep window goes to the merge as before.
    func helioStoredLeadInIsStale(for night: HelioSleepSelection.Night) -> Bool {
        guard let row = try? sleepSummaryOverlapping(start: night.window.start, end: night.window.end),
              !row.isManuallyEdited, row.isStrapNight(log: Self.ownershipLog()), row.inBedStart < night.window.start
        else { return false }
        let sleep = HelioSleepSelection.windowWithoutLeadIn(SleepHypnogramCodec.decode(row.hypnogramData),
                                                            window: DateInterval(start: row.inBedStart, end: row.inBedEnd))
        let incoming = night.windowWithoutLeadIn
        return sleep.start > row.inBedStart
            && abs(sleep.start.timeIntervalSince(incoming.start)) <= 1 && abs(sleep.end.timeIntervalSince(incoming.end)) <= 1
    }
}

// MARK: - 77h: the night's sleep window for every reader that averages its vitals

extension StoredSleepSummary {
    /// Decision 79b (#331 item 3): whether this row is a strap night, so it may carry a lead-in. The
    /// lead-in is recognised by its shape (`HelioSleepSelection.leadIn(in:)`), and only the strap's store
    /// path adds one, so a row is read as having one only when the strap owns its night: the device you
    /// went to bed with (decision 28a, `owner(ofNightFrom:to:)`, the owner at the in-bed start). A strap
    /// night's lead-in never starts before the strap's ownership start (77c), so every strap row passes;
    /// a ring row of the same shape doesn't, and with an empty log (a ring-only install) no row does.
    /// No schema change: the ownership log is the store's rule for a row's device (decision 28).
    func isStrapNight(log: DeviceOwnershipLog) -> Bool {
        inBedEnd > inBedStart && log.owner(ofNightFrom: inBedStart, to: inBedEnd) == .zeppOS
    }

    /// Decision 77h (#328): where the night's SLEEP window starts when a reader's window starts at
    /// `start`: the end of a strap night's in-bed lead-in when `start` is that lead-in's start, else
    /// `start` itself. The lead-in is no sleep, so a reader that averages a night's vitals (the illness
    /// alert, Vitals Status, the Sleep card's overnight averages, Trends, the headache HRV and bedtime
    /// regularity) reads the night as build 88 stored it. A ring night (79b), a night without a lead-in
    /// and a manually edited night return `start` unchanged: this reads the window a reader of the
    /// CURRENT window sees, and an edited window is the person's own (79a). A reader of the RECORDED
    /// columns uses `recordedSleepWindowStart(log:)`.
    func sleepWindowStart(from start: Date, log: DeviceOwnershipLog) -> Date {
        guard !isManuallyEdited, start == inBedStart else { return start }
        return Self.leadInEnd(recordedColumns: hypnogramData, from: inBedStart, to: inBedEnd,
                              isStrap: isStrapNight(log: log)) ?? start
    }

    /// `sleepWindowStart(from:log:)` with the store's ownership log.
    @MainActor
    func sleepWindowStart(from start: Date) -> Date { sleepWindowStart(from: start, log: LocalStore.ownershipLog()) }

    /// `sleepWindowStart(from: inBedStart)`: the in-bed start without a strap night's lead-in, as a reader
    /// of the current window sees it (an edited night: the recorded start, untouched).
    @MainActor
    var sleepWindowInBedStart: Date { sleepWindowStart(from: inBedStart) }

    /// Decision 79a (#331 item 2): the RECORDED in-bed start (`inBedStart`) without the recorded night's
    /// lead-in, for every reader of the recorded columns (the illness alert, Vitals Status, Trends' vitals
    /// averages, the strap's nap backstop). A manual edit rewrites `hypnogramData` but leaves the recorded
    /// columns frozen, lead-in included, so on an edited row the recorded night's lead-in is read from
    /// `recordedHypnogramData`, the recording the edit never touches. An unedited row reads exactly what
    /// `sleepWindowStart(from: inBedStart, log:)` reads; a ring row (79b), a night without a lead-in and
    /// an edited row with no recording kept return `inBedStart`.
    func recordedSleepWindowStart(log: DeviceOwnershipLog) -> Date {
        Self.leadInEnd(recordedColumns: isManuallyEdited ? recordedHypnogramData : hypnogramData,
                       from: inBedStart, to: inBedEnd, isStrap: isStrapNight(log: log)) ?? inBedStart
    }

    /// `recordedSleepWindowStart(log:)` with the store's ownership log.
    @MainActor
    var recordedSleepWindowInBedStart: Date { recordedSleepWindowStart(log: LocalStore.ownershipLog()) }

    /// The end of the lead-in a strap night recorded over `start…end` with `hypnogram` starts with, or nil.
    /// The hypnogram is stored to the whole second (`SleepHypnogramCodec`), the in-bed columns are not: a
    /// lead-in that starts at the strap's ownership start (a switch recorded at `now`, 77c) starts at a
    /// fraction of a second, so the lead-in's start is matched to `start` within a second.
    private static func leadInEnd(recordedColumns hypnogram: Data, from start: Date, to end: Date, isStrap: Bool) -> Date? {
        guard isStrap, end > start, !hypnogram.isEmpty,
              let lead = HelioSleepSelection.leadIn(in: SleepHypnogramCodec.decode(hypnogram)),
              abs(lead.start.timeIntervalSince(start)) <= 1, lead.end < end else { return nil }
        return lead.end
    }
}

extension LocalStore {
    /// Decision 77j: where a night saved with `hypnogram` over `inBedStart…inBedEnd` starts for NEARNESS
    /// (76l's prune): the in-bed start without a strap night's lead-in, else `inBedStart`. A night with
    /// no lead-in (the ring's, any night before decision 77) gives `inBedStart`.
    nonisolated static func sleepStartForNearness(hypnogram: [SleepSegment], inBedStart: Date, inBedEnd: Date) -> Date {
        guard inBedEnd > inBedStart else { return inBedStart }
        return HelioSleepSelection.windowWithoutLeadIn(hypnogram, window: DateInterval(start: inBedStart, end: inBedEnd)).start
    }
}

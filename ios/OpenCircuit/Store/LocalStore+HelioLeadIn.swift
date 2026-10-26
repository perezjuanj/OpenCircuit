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

    /// Decision 77c: the latest end, at or before `instant`, of any sleep the store keeps (a night or
    /// nap of either device, its recorded or edited window) or of `sleeps`; `.distantPast` when none.
    func helioLatestSleepEnd(atOrBefore instant: Date, sleeps: [DateInterval] = []) -> Date {
        // Rows are keyed by the day they end on, naps by their start: two days back reaches every
        // sleep that can end within `maxLength` of `instant`.
        let lo = instant.addingTimeInterval(-2 * 86_400)
        var ends = sleeps.map(\.end)
        for row in (try? sleepSummaries(from: lo, to: instant.addingTimeInterval(86_400))) ?? [] {
            if row.inBedEnd > row.inBedStart { ends.append(row.inBedEnd) }
            if row.isManuallyEdited, row.editedInBedEnd > row.editedInBedStart { ends.append(row.editedInBedEnd) }
        }
        for nap in (try? naps(from: lo, to: instant)) ?? [] {
            ends.append(max(nap.end, nap.effectiveEnd))
        }
        return ends.filter { $0 <= instant }.max() ?? .distantPast
    }
}

// MARK: - 77h: the night's sleep window for every reader that averages its vitals

extension StoredSleepSummary {
    /// Decision 77h (#328): where the night's SLEEP window starts when a reader's window starts at
    /// `start`: the end of a strap night's in-bed lead-in when `start` is that lead-in's start, else
    /// `start` itself. The lead-in is no sleep, so a reader that averages a night's vitals (the illness
    /// alert, Vitals Status, the Sleep card's overnight averages, Trends, the headache HRV and bedtime
    /// regularity) reads the night as build 88 stored it. A ring night, a night without a lead-in and a
    /// manually edited night (the person's own window) return `start` unchanged.
    func sleepWindowStart(from start: Date) -> Date {
        guard !isManuallyEdited, start == inBedStart, inBedEnd > inBedStart, !hypnogramData.isEmpty,
              let lead = HelioSleepSelection.leadIn(in: SleepHypnogramCodec.decode(hypnogramData)),
              lead.start == start, lead.end < inBedEnd else { return start }
        return lead.end
    }

    /// `sleepWindowStart(from: inBedStart)`: the recorded in-bed start without a strap night's lead-in.
    var sleepWindowInBedStart: Date { sleepWindowStart(from: inBedStart) }
}

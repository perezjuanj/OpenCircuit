import Foundation
import OpenCircuitKit
import SwiftData
import ZeppKit

// Scoring the Helio Strap's nights on the phone — #246, decision 48.
//
// THE DEFECT. `WellnessBalance.anchoredScore` returns nil without last night's Sleep Score, so
// Readiness on Today is anchored on it. The ring's nights are scored as they are stored
// (`RingSession.computeSleepExtras`), but `saveHelioNight` stored only the hypnogram and the nightly
// skin temperature, so a strap night kept `sleepScore == 0` — this column's app-wide "never
// computed" sentinel — and the Readiness card was permanently empty for a strap wearer while every
// input for the score sat in the store. Measured on the owner's phone, build 62: the strap's night
// had neither score, every earlier (ring) night had both, and the strap's heart rate, HRV and skin
// temperature for that night were all stored.
//
// WHAT IS HERE. Two call sites' worth of input-gathering, plus the repair pass:
//   • `applyHelioNightScores` fills a night's `extras` as it is saved;
//   • `scoreUnscoredHelioNights` scores strap nights already stored with no score.
// The arithmetic is `StoredNightScore` in the Kit, so the two cannot disagree about the number.
//
// ⚠️ DECISIONS 28 AND 29 ARE THE WHOLE REASON THIS IS NOT THREE LINES IN `LocalStore+Helio.swift`.
// A night is only scored when the STRAP owns it, every input row must be the strap's own, and the
// temperature baseline is the strap's own prior nights. A finger temperature and an arm temperature
// are not one baseline (decision 29), so letting a ring night into the baseline would turn every
// device switch into a fever signal. With an EMPTY ownership log (a ring-only install) nothing here
// does anything at all: `owner(ofNightFrom:to:)` is `.ringConn` for every night.
//
// ⚠️ OVERNIGHT RECOVERY RESTS ON A 🟡 STATISTIC. The strap's HRV is taken as RMSSD on Amazfit's
// product-line documentation (decision 44); no capture has compared the `0x49` byte with the vendor
// app's number. `SleepStress.overnightScore` wants RMSSD, and the strap's HRV is stored as
// `.hrvSDNN` (the only HRV column there is). If the statistic turns out to be SDNN, the stress
// number is wrong and this is one of the two places to fix.
//
// NOT A HEALTHKIT PATH, and no schema change. `sleepScore` and `stressScore` are ours alone — Sleep
// Score has no HealthKit type — so nothing here needs authorization or queues a reconcile.

extension LocalStore {

    /// Trailing nights the temperature baseline may look back over. The ring's own number
    /// (`RingSession.computeSleepExtras`), so the two devices weigh "your usual" over the same span.
    static let helioScoreBaselineNights = 40

    // MARK: Scoring a night as it is stored

    /// Fill `extras.sleepScore` / `extras.stressScore` for a strap night about to be stored, from
    /// the strap's own stored rows inside the night's window.
    ///
    /// Called from `saveHelioNight`, which runs TWICE per night per sync: once when the sleep round
    /// lands, and again from `finishSync` after the later rounds. `HelioFetchPlan.types` fetches
    /// sleep sessions before temperature and HRV, so the first save has neither — it stores the
    /// score it can compute, and the re-save rescores the night with the sync's HRV and
    /// temperatures. `applyExtras` keeps a stored value when the new one is 0, so a round that adds
    /// nothing can never wipe a score that is already there.
    ///
    /// A night the strap does not own is left alone (decision 28). Nothing is written as 0: a
    /// `nil` from `StoredNightScore` stays 0 in `extras`, which `applyExtras` reads as "not computed
    /// this pass".
    func applyHelioNightScores(to extras: inout SleepNightExtras,
                               window: DateInterval, segments: [SleepSegment],
                               device: SyncDeviceID) {
        let log = Self.ownershipLog()
        let family = DeviceOwnershipLog.Family(timeline: device)
        // Decision 77d: the in-bed lead-in is no sleep. Every input below that is read over the night's
        // time (heart rate, HRV, the night's key) takes the window without it, so they are the night's
        // as before; only the segments carry it (time in bed and awake grow, efficiency drops).
        let window = HelioSleepSelection.windowWithoutLeadIn(segments, window: window)
        guard family == .zeppOS,
              log.owner(ofNightFrom: window.start, to: window.end) == family else { return }
        let scores = StoredNightScore.scores(.init(
            segments: segments,
            heartRate: helioHeartRate(in: window, device: device),
            // Decision 71i: the HRV of the night's in-bed spans, never of a joined night's awake gap.
            // Decision 74c: its sleep fragments' spans, never an awake run of the fill.
            rmssd: helioRMSSD(in: window, sleepSpans: HelioSleepSelection.sleepSpans(of: segments, window: window),
                              device: device),
            // The verdict the caller just reached for THIS night (0 = none or withheld), so the
            // score and the stored temperature always describe the same judgement.
            skinTempC: extras.skinTempC > 0 ? extras.skinTempC : nil,
            priorNights: strapPriorNightTemperatures(excluding: SleepNightKey.night(inBedStart: window.start,
                                                                                    inBedEnd: window.end),
                                                     log: log)))
        if let score = scores.sleepScore { extras.sleepScore = score }
        if let stress = scores.stressScore { extras.stressScore = stress }
    }

    // MARK: The repair pass

    /// Fill the missing scores of every strap night stored with no Sleep Score or no overnight
    /// stress score. Returns the nights it changed, newest first, or `[]`.
    ///
    /// WHY A PASS IS NEEDED AT ALL, when `saveHelioNight` now scores on the way in:
    ///   • a re-sync that keeps the stored night returns `.keptFullerStoredNight` (or
    ///     `.keptManualEdit`) BEFORE `applyExtras` runs — its own comment says so — so a night first
    ///     stored by a build without this fix could never pick up a score from a later sync;
    ///   • builds 59–62 stored strap nights with no score at all, and the wearer's Readiness for
    ///     today is exactly the night those builds stored.
    ///
    /// ⚠️ WHAT IT WILL NOT TOUCH, and each clause is load-bearing:
    ///   • a night the strap doesn't own — a ring night is the ring's to score (decision 28), and
    ///     with an empty ownership log EVERY night is the ring's, so a ring-only install is
    ///     byte-identical;
    ///   • a manually edited night — the wearer's word stands, and `applySleepEdit` writes its own
    ///     score (decision 13);
    ///   • a night with an empty stored hypnogram — there is nothing to score at second precision,
    ///     and the rounded minutes are not an acceptable substitute (`SleepScoreHeal`'s argument);
    ///   • a score that is already there — the predicate is `sleepScore == 0 || stressScore == 0`
    ///     and each write fills only a column that is still 0 (#259), so a stored number is never
    ///     replaced by one recomputed from thinner rows, and a night with both is skipped for ever
    ///     after, which is also what makes a second run a no-op.
    /// And it never writes a computed 0: `StoredNightScore` reports that as "no score", because
    /// writing the sentinel back would claim a repair that changed nothing.
    ///
    /// ⚠️ `row.updatedAt` IS BUMPED on a row it changes, and only then (#259): a candidate whose
    /// missing score still can't be computed, such as a night with no HRV, is left byte-identical.
    /// The bump is for the reason `healWithheldSleepScores` records: the Sleep card and Readiness
    /// are `@Query`-backed and would otherwise keep showing the empty badge until something else
    /// touched the row. Only the two score columns and
    /// `updatedAt` change — the minutes, the window, the hypnogram and every provenance column are
    /// left exactly as stored, so this turns a missing number into the number the night would have
    /// been stored with and restates nothing about the night.
    ///
    /// IDEMPOTENT AND DELIBERATELY NOT LATCHED, like `healWithheldSleepScores` and for the same
    /// reasons: it is cheap (one fetch over a table with one row per night, plus ONE HRV fetch shared
    /// by every night missing only its recovery number), a scored row is skipped by the predicate,
    /// and un-latched means a row that arrives LATER — from a restore, from a
    /// night re-keyed after the first run, or from a sync that fills in the HRV — is still picked up.
    @discardableResult
    func scoreUnscoredHelioNights() throws -> [Date] {
        let log = Self.ownershipLog()
        // A ring-only install: every night is the ring's, so there is nothing this pass may touch.
        guard !log.isEmpty else { return [] }
        let rows = try context.fetch(FetchDescriptor<StoredSleepSummary>())
        let strapNights = rows.filter {
            $0.inBedEnd > $0.inBedStart
                && log.owner(ofNightFrom: $0.inBedStart, to: $0.inBedEnd) == .zeppOS
        }
        guard !strapNights.isEmpty else { return [] }
        // The baseline candidates, newest first, from the strap's own nights. Each night below takes
        // only the ones STRICTLY OLDER than itself (#259): the save path scores a night when it is
        // the newest one stored, so a later night in its pool would give a number the save path
        // never could have.
        let candidates = strapNights.filter { $0.skinTempC > 0 }
            .sorted { $0.night > $1.night }
            .map { (night: $0.night, celsius: $0.skinTempC) }

        // #259: a night missing EITHER score is a candidate. A sync that dies between the sleep
        // round and the HRV round stores a Sleep Score and no stress score, and the `.sleepSession`
        // watermark has already moved on, so this pass is the only thing that can ever fill it.
        let targets = strapNights.filter {
            ($0.sleepScore == 0 || $0.stressScore == 0) && !$0.isManuallyEdited && !$0.hypnogramData.isEmpty
        }
        // A night with a Sleep Score but no HRV stays a candidate on every launch, so the nights
        // missing only their recovery number share ONE HRV fetch over their whole span instead of
        // one fetch each. Each night then takes the readings `helioRMSSD` would have returned.
        let stressOnly = targets.filter { $0.sleepScore != 0 }
        let sharedHRV: [QuantitySample] = {
            guard let lo = stressOnly.map(\.inBedStart).min(),
                  let hi = stressOnly.map(\.inBedEnd).max() else { return [] }
            return helioRows(kind: .hrvSDNN, in: DateInterval(start: lo, end: hi), device: nil)
        }()

        var scored: [Date] = []
        for row in targets {
            let segments = SleepHypnogramCodec.decode(row.hypnogramData)
            // Decision 77d: the save path's window, without the in-bed lead-in.
            let window = HelioSleepSelection.windowWithoutLeadIn(segments, window: DateInterval(start: row.inBedStart, end: row.inBedEnd))
            // Decision 71i: the same in-bed spans the save path judges (one, the window, for a night
            // that wasn't joined or was stored before decision 70). Decision 74c: the sleep fragments'
            // spans, never an awake run of the fill.
            let sleepSpans = HelioSleepSelection.sleepSpans(of: segments, window: window)
            let needsSleep = row.sleepScore == 0
            let scores: StoredNightScore.Scores
            if needsSleep {
                let tonight = Calendar.current.startOfDay(for: row.night)
                let priorNights = candidates
                    .filter { Calendar.current.startOfDay(for: $0.night) < tonight }
                    .prefix(Self.helioScoreBaselineNights)
                    .map { SkinTempBaseline.NightlyTemp(night: $0.night, celsius: $0.celsius) }
                scores = StoredNightScore.scores(.init(
                    segments: segments,
                    heartRate: helioHeartRate(in: window, device: nil),
                    rmssd: helioRMSSD(in: window, sleepSpans: sleepSpans, device: nil),
                    skinTempC: row.skinTempC > 0 ? row.skinTempC : nil,
                    priorNights: priorNights))
            } else {
                // Only the recovery number is missing, and it depends on the HRV alone
                // (`StoredNightScore` computes it independently of the composite), so the heart-rate
                // fetch and the baseline are skipped.
                let rmssd = sharedHRV
                    .filter { $0.start >= window.start && $0.start < window.end }
                    .filter { sample in sleepSpans.contains { $0.start <= sample.start && sample.start < $0.end } }
                    .map { Int($0.value.rounded()) }
                    .filter { $0 > 0 }
                scores = StoredNightScore.scores(.init(segments: [], rmssd: rmssd))
            }
            // ⚠️ BOTH WRITES ARE CONDITIONAL: only a score that is still 0 is filled. Recomputing
            // from thinner rows must never replace a number already stored, and a computed 0 is
            // `nil` here, so the sentinel is never written back either.
            var changed = false
            if needsSleep, let score = scores.sleepScore {
                row.sleepScore = score
                changed = true
            }
            if row.stressScore == 0, let stress = scores.stressScore {
                row.stressScore = stress
                changed = true
            }
            guard changed else { continue }
            row.updatedAt = Date()
            scored.append(row.night)
        }

        guard !scored.isEmpty else { return [] }
        try context.save()

        let newestFirst = scored.sorted(by: >)
        // ONE summary breadcrumb per pass (#259) — a breadcrumb per night cost ~135 ms on the main
        // actor at launch on a 120-night store. The night KEYS and the count only — no clock time,
        // no score, no temperature, no HRV.
        ObservabilityStore().recordMetricEvent(
            source: "sleep-score-strap",
            detail: "SCORED \(newestFirst.count) strap night(s), "
                + "oldest=\(Self.helioNightStamp(newestFirst[newestFirst.count - 1])) "
                + "newest=\(Self.helioNightStamp(newestFirst[0])) "
                + "(rebuilt from the stored hypnogram and the strap's own rows)")
        return newestFirst
    }

    /// Compact local night stamp for the breadcrumb — never user-facing and never a health value,
    /// just enough to identify a night in a diagnostics bundle. Its own formatter because
    /// `LocalStore`'s is `private` and therefore file-scoped; the format matches it exactly so the
    /// sleep breadcrumbs all read the same way.
    private static let helioNightStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    private static func helioNightStamp(_ date: Date) -> String { helioNightStampFormatter.string(from: date) }

    // MARK: The strap's own rows

    /// The strap's heart-rate readings inside `window`. `device` nil means any Zepp OS timeline,
    /// which is what the repair pass has: `StoredSleepSummary` carries no device column, so a stored
    /// night can only be attributed to a FAMILY (decision 28), and its baseline is family-wide too.
    private func helioHeartRate(in window: DateInterval, device: SyncDeviceID?) -> [HRSample] {
        helioRows(kind: .heartRate, in: window, device: device)
            .map { HRSample(bpm: Int($0.value.rounded()), start: $0.start, end: $0.end) }
    }

    /// The strap's HRV readings inside `window`, in ms, taken as RMSSD (decision 44, 🟡 — see the
    /// file header). Stored as `.hrvSDNN` because that is the app's only HRV kind. Only readings in
    /// `sleepSpans` (the night's in-bed spans, half-open like the window) count: a joined night's
    /// awake gap is no sleep (decision 71i). A night that wasn't joined has one span, its window.
    private func helioRMSSD(in window: DateInterval, sleepSpans: [DateInterval], device: SyncDeviceID?) -> [Int] {
        helioRows(kind: .hrvSDNN, in: window, device: device)
            .filter { sample in sleepSpans.contains { $0.start <= sample.start && sample.start < $0.end } }
            .map { Int($0.value.rounded()) }
            .filter { $0 > 0 }
    }

    /// Rows of one kind inside `window` that a Zepp OS device recorded for time it owned
    /// (decision 28: a device's catch-up of the other's time feeds nothing derived). `device` pins
    /// it to one strap's timeline; nil accepts any.
    ///
    /// The ownership filter is a backstop — `HelioStoreSink.owned` already drops un-owned rows at
    /// ingest — but it is the rule this value depends on, so it is stated rather than assumed.
    private func helioRows(kind: MetricKind, in window: DateInterval,
                           device: SyncDeviceID?) -> [QuantitySample] {
        guard window.end > window.start else { return [] }
        let kindRaw = kind.rawValue
        let start = window.start
        let end = window.end
        var predicate = #Predicate<StoredSample> {
            $0.kindRaw == kindRaw && $0.start >= start && $0.start < end && $0.value > 0
        }
        if let device {
            let deviceID = device.rawValue
            predicate = #Predicate<StoredSample> {
                $0.kindRaw == kindRaw && $0.deviceID == deviceID
                    && $0.start >= start && $0.start < end && $0.value > 0
            }
        }
        let descriptor = FetchDescriptor<StoredSample>(predicate: predicate,
                                                       sortBy: [SortDescriptor(\.start)])
        let log = Self.ownershipLog()
        return ((try? context.fetch(descriptor)) ?? [])
            .filter { log.isOwn(recordedBy: SyncDeviceID(rawValue: $0.deviceID), at: $0.start, by: .zeppOS) }
            .compactMap(\.sample)
    }

    /// PRIOR nights' mean skin temperatures from the STRAP's own nights (decision 29), newest first,
    /// excluding `tonight`'s key. The ring's own shape (`RingSession.computeSleepExtras`), with the
    /// family swapped: `only(.zeppOS, …, time: \.inBedStart)` is `owner(ofNightFrom:to:)` per row.
    private func strapPriorNightTemperatures(excluding tonight: Date,
                                             log: DeviceOwnershipLog) -> [SkinTempBaseline.NightlyTemp] {
        let rows = (try? recentSleepSummaries(limit: Self.helioScoreBaselineNights)) ?? []
        let tonightDay = Calendar.current.startOfDay(for: tonight)
        return log.only(.zeppOS, rows, time: \.inBedStart)
            .filter { $0.skinTempC > 0 && Calendar.current.startOfDay(for: $0.night) != tonightDay }
            .map { SkinTempBaseline.NightlyTemp(night: $0.night, celsius: $0.skinTempC) }
    }
}

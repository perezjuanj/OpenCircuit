import Foundation
import SwiftData
import OpenCircuitKit

// The app-side half of the overnight-signals index (#183, Phase 2): fetch → snapshot → assess
// off the main actor → FREEZE one row per day.
//
// The Kit (`OpenCircuitKit.HeadacheSignals`) owns every constant, threshold and arithmetic decision
// and knows nothing about SwiftData, HealthKit or CoreBluetooth. This file owns exactly three jobs:
//
//   1. Read the app's CANONICAL sources — `RestingHR` for resting HR, `SkinTempBaseline` for the
//      skin-temp offset, `VitalsBaseline.suspectedFever` for the fever flag,
//      `SleepCaptureCoverage.classify` for the truncation multiplier, `CyclePredictor` +
//      the logged period log for cycle phase. Nothing here re-derives a metric that already has an
//      owner, so the index can never tell a different story than the card the user is looking at.
//   2. Flatten those `@Model` rows to Sendable values ON THE MAIN ACTOR, then run the assessment
//      inside `Task.detached`. Running analytics inline on the main actor has ALREADY caused a
//      shipped 0x8BADF00D scene-update watchdog crash in this app — see the post-mortem at
//      `VitalsStatusCardView.swift:101-122`, whose snapshot-then-detach shape this copies.
//   3. FREEZE the result: `insertRiskDayIfAbsent` writes a day exactly once and there is no update
//      path. This is the load-bearing invariant of the whole feature. Without it every later
//      precision/AUC number is retro-fitted against a baseline that has since seen the label, and
//      the Phase-3 unlock gate is theatre.
//
// A missing input is ABSENT with a reason, never a substituted zero — the Kit's `AbsentReason` is
// carried all the way into the frozen row's `absentJSON` so a thin day stays debuggable remotely.
//
// NOTE ON PHASING: this file computes and stores. It does not notify, unlock, or say the word
// "headache" anywhere a user can see it — that is Phase 3.

// MARK: - Sendable snapshot (main actor → detached task)

/// One stored night, flattened to a value type so it can cross into the detached assessment.
///
/// Deliberately carries the EFFECTIVE window (`sleepEditCurrent*`): a night the user manually
/// re-timed (#176) is authoritative for everything else in the app, and a score built on the
/// recorded window would contradict the night the user is actually shown.
struct HeadacheNightRow: Sendable, Equatable {
    /// The row's `night` key (start-of-day of the sleep window's start) — the stable identity.
    let night: Date
    let inBedStart: Date
    let inBedEnd: Date
    /// SUMMED in-bed seconds (`asSummary.inBed`), not the wall-clock span — the same quantity the
    /// sleep card feeds `SleepCaptureCoverage` (`SleepCardView.swift:400`).
    let inBedSeconds: TimeInterval
    let asleepMin: Int
    let awakeMin: Int
    /// FRACTION (0…1), as `SleepStaging.Summary.efficiency` stores it. The feature's noise floor is
    /// in percentage POINTS, so the builder scales it — see `dayInput`.
    let efficiency: Double
    /// Nightly mean sleeping skin temperature in °C. 0 = not measured this night.
    let skinTempC: Double
    /// The summary's `updatedAt` — the re-stage detector compares this against the frozen row's.
    let updatedAt: Date
}

/// Everything one assessment needs, already off SwiftData. Built on the main actor, consumed on a
/// detached task; no `@Model` reference may ever appear in here.
struct HeadacheSnapshot: Sendable {
    /// Local start-of-day for the night that ended this morning — the frozen row's key.
    let day: Date
    /// The instant the assessment is taken AS OF. Normally "now"; for a day that is already frozen
    /// the card replays it as of `computedAt` (see `HeadacheEngine.todaysVerdict`).
    let now: Date
    let lastRingDataAt: Date?
    /// Recent nights, OLDEST → NEWEST.
    let nights: [HeadacheNightRow]
    /// The night that ended on `day`, or nil when nothing was captured.
    let tonight: HeadacheNightRow?
    let hr: [HRSample]
    let hrv: [QuantitySample]
    /// The caller's already-derived resting-HR series, when it has one. Empty ⇒ derive it here.
    let providedRestingHR: [RestingHR.DailyValue]
    let periods: [CyclePredictor.PeriodEntry]
    let womensHealthEnabled: Bool
    let scheduledBedtime: Date?
    let headacheAlreadyLoggedToday: Bool
    /// Trailing FROZEN indices, oldest → newest, excluding today.
    let priorIndices: [Int]
}

// MARK: - Pure input assembly (runs OFF the main actor)

/// Turns a `HeadacheSnapshot` into the Kit's `DayInput` and asks the Kit for a verdict.
///
/// File-scope (not nested in the `@MainActor` engine) on purpose: nested types inherit the
/// enclosing global actor, and this whole namespace exists precisely to run off it.
enum HeadacheAssessmentBuilder {

    /// Minimum HRV readings inside a night's in-bed window before that night contributes a mean.
    /// 🟡 Mirrors `RestingHR.minSleepSamples` (3) for the same reason: one or two readings is a spot
    /// check, not a night, and averaging them into a baseline invents a "usual" that never happened.
    static let minNightHRVSamples = 3

    /// Minimum waking readings before a calendar day contributes a daytime mean HR. 🔴 PROVISIONAL —
    /// ~12 epochs ≈ 1 h of coverage. Without a floor, a day whose only readings were taken during a
    /// workout becomes a "daytime mean HR" of 150 and drives the let-down term on its own.
    /// Calibration plan: docs/HEADACHE_SIGNALS.md §12, against real per-day coverage histograms.
    static let minDaytimeHRSamples = 12

    /// Perimenstrual window, in whole days either side of the first bleeding day. 🟢 MacGregor's
    /// menstrual-migraine window is "day 1 ± 2 days", where day 1 is the first day of bleeding and
    /// there is no day 0 — i.e. days −2, −1, +1, +2, +3. Re-indexed onto CALENDAR offsets from the
    /// first bleeding day (offset 0 == MacGregor's day +1), that is exactly [−2, +2].
    static let perimenstrualDaysEitherSide = 2

    static func verdict(_ snapshot: HeadacheSnapshot,
                        tuning: HeadacheSignals.Tuning = HeadacheSignals.Tuning())
        -> HeadacheSignals.Verdict {
        HeadacheSignals.assess(dayInput(snapshot), tuning: tuning)
    }

    static func dayInput(_ s: HeadacheSnapshot) -> HeadacheSignals.DayInput {
        let cal = Calendar.current

        // Only nights with real staged data may enter a baseline. A row with no asleep minutes is a
        // placeholder for a night we failed to capture; feeding its zeros to a median/MAD estimate
        // would manufacture a "usual" the person never lived.
        let usable = s.nights.filter { $0.asleepMin > 0 && $0.inBedEnd > $0.inBedStart }
        let tonight = s.tonight.flatMap { t in usable.first { $0.night == t.night } }
        // Priors are the usable nights strictly BEFORE last night's row key. When there is no row for
        // last night at all, every stored night is "prior" — which produces no today-value, hence an
        // ABSENT sleep feature rather than a fabricated one.
        let cutoff = s.tonight?.night ?? .distantFuture
        let prior = Array(usable.filter { $0.night < cutoff }.suffix(RobustBaseline.maxBaselineDays))

        func series(_ today: Double?, _ priorValues: [Double]) -> HeadacheSignals.Series? {
            guard let today else { return nil }
            return HeadacheSignals.Series(today: today, prior: priorValues)
        }

        // Sleep efficiency is stored as a FRACTION (`StoredSleepSummary.asSummary` recovers in-bed as
        // `asleep / efficiency`), but `Feature.sleepEfficiencyDrop`'s 5-unit noise floor is in
        // PERCENTAGE POINTS (§3.2). Scale here, once, rather than in the Kit.
        let efficiency = series(tonight.flatMap { $0.efficiency > 0 ? $0.efficiency * 100 : nil },
                                prior.filter { $0.efficiency > 0 }.map { $0.efficiency * 100 })
        let fragmentation = series(tonight.map { Double($0.awakeMin) },
                                   prior.map { Double($0.awakeMin) })
        let duration = series(tonight.map { Double($0.asleepMin) },
                              prior.map { Double($0.asleepMin) })

        let hrvByNight = nightlyMeans(samples: s.hrv, nights: usable)
        let hrv = series(tonight.flatMap { hrvByNight[$0.night] },
                         prior.compactMap { hrvByNight[$0.night] })

        // Resting HR: the caller's already-derived series when it has one, else the SAME canonical
        // derivation the vitals card and the fever alert make off the same readings
        // (`VitalsStatusCardView.swift:189`, `HealthNotificationCenter.swift:318`), so the three can
        // never disagree about a day's resting HR.
        let restingDaily = (s.providedRestingHR.isEmpty ? RestingHR.dailyValues(hr: s.hr)
                                                        : s.providedRestingHR)
            .sorted { $0.day < $1.day }
        let restingToday = restingDaily.last { cal.isDate($0.day, inSameDayAs: s.day) }?.bpm
        let restingPrior = Array(restingDaily.filter { $0.day < s.day }.map(\.bpm)
            .suffix(RobustBaseline.maxBaselineDays))
        let restingHR = series(restingToday, restingPrior)

        // Skin temp: the CANONICAL `SkinTempBaseline` offset, never re-derived — assembled exactly as
        // the fever alert assembles it (`HealthNotificationCenter.swift:292-303`). `previousNight` is
        // omitted because it only feeds the night-over-night FLUCTUATION flags, which this index does
        // not use; the baseline offset it does use is unaffected.
        let skinTempOffsetC: Double? = {
            guard let tonight, tonight.skinTempC > 0 else { return nil }
            let priorTemps = prior.filter { $0.skinTempC > 0 }
                .map { SkinTempBaseline.NightlyTemp(night: $0.night, celsius: $0.skinTempC) }
            return SkinTempBaseline.report(tonight: tonight.skinTempC, priorNights: priorTemps).offsetC
        }()

        // Let-down: the term is z(D−2) − z(D−1) of WAKING arousal, so the baseline must not contain
        // either of the two days being scored. Excluding both is the same "prior must not include
        // today" rule the rest of this file follows, applied to a two-day comparison.
        let dayHR = daytimeHRByDay(hr: s.hr, nights: usable)
        let dayMinus1 = cal.date(byAdding: .day, value: -1, to: s.day)
        let dayMinus2 = cal.date(byAdding: .day, value: -2, to: s.day)
        let dayHRPrior: [Double] = dayMinus2.map { edge in
            dayHR.filter { $0.key < edge }.sorted { $0.key < $1.key }.map(\.value)
        } ?? []

        // A night the ring's buffer cut short looks exactly like a genuinely short, broken one, so
        // the Kit halves the two features most prone to that false positive. Positive evidence only
        // — without a bedtime reference `classify` correctly declines to guess.
        let truncated = tonight.map {
            SleepCaptureCoverage.classify(capturedOnset: $0.inBedStart,
                                          capturedInBed: $0.inBedSeconds,
                                          scheduledBedtime: s.scheduledBedtime) == .likelyTruncated
        } ?? false

        return HeadacheSignals.DayInput(
            day: s.day,
            now: s.now,
            lastRingDataAt: s.lastRingDataAt,
            restingHR: restingHR,
            hrvSDNN: hrv,
            sleepEfficiencyPct: efficiency,
            sleepFragmentationMin: fragmentation,
            sleepDurationMin: duration,
            skinTempOffsetC: skinTempOffsetC,
            inBedStartMinutes: tonight.map { minutesSinceMidnight($0.inBedStart, cal) },
            priorInBedStartMinutes: prior.map { minutesSinceMidnight($0.inBedStart, cal) },
            dayHRPrevious: dayMinus1.flatMap { dayHR[$0] },
            dayHRTwoDaysAgo: dayMinus2.flatMap { dayHR[$0] },
            dayHRPrior: dayHRPrior,
            isPerimenstrual: perimenstrual(s),
            sleepLikelyTruncated: truncated,
            // Fever wins over this index: HRV↓ + RHR↑ + temp↑ IS the fever signature, and the
            // existing fever alert is the more actionable one (§3.9 gate 5).
            feverSuspected: VitalsBaseline.suspectedFever(restingHRToday: restingToday,
                                                          restingHRPrior: restingPrior,
                                                          skinTempOffsetC: skinTempOffsetC),
            headacheAlreadyLoggedToday: s.headacheAlreadyLoggedToday,
            priorIndices: s.priorIndices)
    }

    // MARK: Feature helpers

    /// Mean of `samples` inside each night's in-bed window, keyed by the night's `night` day.
    ///
    /// Both inputs are sorted ascending and stored nights never overlap (one uniquely-keyed row per
    /// night), so one linear pass with a forward-only window pointer suffices — no per-night rescan
    /// of the whole sample array, which on a heavy archive is the shape that blows a watchdog.
    static func nightlyMeans(samples: [QuantitySample],
                             nights: [HeadacheNightRow]) -> [Date: Double] {
        let windows = nights.sorted { $0.inBedStart < $1.inBedStart }
        let sorted = samples.sorted { $0.start < $1.start }
        var totals: [Date: (sum: Double, count: Int)] = [:]
        var idx = 0
        for sample in sorted {
            while idx < windows.count, windows[idx].inBedEnd <= sample.start { idx += 1 }
            guard idx < windows.count, sample.start >= windows[idx].inBedStart else { continue }
            let running = totals[windows[idx].night] ?? (sum: 0, count: 0)
            totals[windows[idx].night] = (running.sum + sample.value, running.count + 1)
        }
        return totals.compactMapValues {
            $0.count >= minNightHRVSamples ? $0.sum / Double($0.count) : nil
        }
    }

    /// Per-calendar-day MEAN heart rate over readings taken OUTSIDE every recorded in-bed window.
    ///
    /// Sleep readings are excluded on purpose: including them would make this series track the night,
    /// which `restingHRDeviation` already covers, and would blur the daytime D−2 → D−1 FALL that the
    /// let-down effect is about (Lipton 2014). Naps are not excluded — they are short and few, and
    /// the per-day sample floor keeps a nap from becoming a day's whole sample.
    static func daytimeHRByDay(hr: [HRSample], nights: [HeadacheNightRow]) -> [Date: Double] {
        let cal = Calendar.current
        let windows = nights.sorted { $0.inBedStart < $1.inBedStart }
        let sorted = hr.sorted { $0.start < $1.start }
        var totals: [Date: (sum: Double, count: Int)] = [:]
        var idx = 0
        for sample in sorted {
            while idx < windows.count, windows[idx].inBedEnd <= sample.start { idx += 1 }
            if idx < windows.count, sample.start >= windows[idx].inBedStart { continue }   // in bed
            let day = cal.startOfDay(for: sample.start)
            let running = totals[day] ?? (sum: 0, count: 0)
            totals[day] = (running.sum + Double(sample.bpm), running.count + 1)
        }
        return totals.compactMapValues {
            $0.count >= minDaytimeHRSamples ? $0.sum / Double($0.count) : nil
        }
    }

    /// Whether `day` sits in the perimenstrual window — `nil` when we genuinely do not know.
    ///
    /// `nil` (ABSENT, `.notApplicable`) rather than `false` in two cases, because a confident "not
    /// perimenstrual" is itself a claim: cycle tracking is off, or too little is logged for a
    /// prediction to exist. The Kit ring-fences this feature anyway (it never counts toward the
    /// ring-feature minimum, and the 35 % cap stops a calendar lookup from carrying a band).
    static func perimenstrual(_ s: HeadacheSnapshot) -> Bool? {
        guard s.womensHealthEnabled, !s.periods.isEmpty else { return nil }
        let cal = Calendar.current
        let day = cal.startOfDay(for: s.day)

        func inWindow(_ periodStart: Date) -> Bool {
            let first = cal.startOfDay(for: periodStart)
            guard let lo = cal.date(byAdding: .day, value: -perimenstrualDaysEitherSide, to: first),
                  let hi = cal.date(byAdding: .day, value: perimenstrualDaysEitherSide, to: first)
            else { return false }
            return day >= lo && day <= hi
        }

        if s.periods.contains(where: { inWindow($0.start) }) { return true }
        // Nothing LOGGED near this day. Only a prediction can say "not perimenstrual" with any
        // standing, and `CyclePredictor` needs two logged cycles before it will make one. Below that
        // we do not know, and saying `false` would be a fabricated negative.
        guard let prediction = CyclePredictor.predict(from: s.periods, now: s.now) else { return nil }
        return inWindow(prediction.nextPeriodStart)
    }

    /// Minutes since local midnight — the same time-of-day convention `SleepWindow` uses.
    static func minutesSinceMidnight(_ date: Date, _ calendar: Calendar) -> Int {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }
}

// MARK: - Engine

/// Computes today's overnight-signals verdict and freezes it exactly once.
///
/// Safe to call from every wake path, several times an hour: with the feature off it returns before
/// touching the store at all, and once a day is frozen the only work left is a two-fetch re-stage
/// check.
@MainActor
struct HeadacheEngine {

    /// How long after the night's in-bed end a score may be taken. 🔴 PROVISIONAL.
    ///
    /// Nights in this app re-stage 1–22 h after wake (project memory: *sleep-health-mirror-restage*)
    /// and the daytime drain cadence is ~1 h, so 3 h makes a complete-data verdict likely without
    /// making the user wait until evening. It deliberately does NOT cover the 22 h tail: that case is
    /// answered by `markRiskRestaged` below, never by recomputing a frozen row. Calibration plan:
    /// docs/HEADACHE_SIGNALS.md §3.8.
    static let settleMarginMinutes = 180

    /// Nights pulled for the sleep baselines: the 60-night baseline window plus last night plus a
    /// little slack for rows with no usable staging.
    static let nightsFetchLimit = RobustBaseline.maxBaselineDays + 10

    /// Raw-sample lookback for the HRV / HR series. Sized to the baseline window, but `StoredSample`
    /// prunes at 30 days (`LocalStore.sampleRetentionDays`), so in practice these two features carry a
    /// SHORTER effective baseline than the sleep-summary ones. That is a real, honest asymmetry: a
    /// pruned sample is gone, and the alternative is inventing one.
    static let sampleLookbackDays = RobustBaseline.maxBaselineDays + 2

    /// `userProfile.womensHealthEnabled`, the settings toggle that gates the cycle feature.
    ///
    /// A THIRD copy of a literal that `HeadacheDefaults` explicitly calls out as a drift hazard —
    /// unavoidable here, because the two existing copies (`UserProfile.swift:89`,
    /// `ContentView.swift:41`) are `@AppStorage` literals in files this change does not own. Hoisting
    /// all three into one constant is a follow-up; naming it once here at least means this file has a
    /// single place to fix.
    static let womensHealthEnabledKey = "userProfile.womensHealthEnabled"

    init() {}

    // MARK: Write path

    /// Freeze today's score if — and only if — last night has settled and today is not already
    /// frozen. Idempotent; a no-op when the feature is off.
    ///
    /// `restingHR` lets a caller that already derived the daily resting-HR series hand it over rather
    /// than pay for it twice; pass `[]` and it is derived from the same stored readings.
    func refreshToday(store: LocalStore, restingHR: [RestingHR.DailyValue], now: Date = Date()) async {
        // A background launch never renders ContentView, so it cannot rely on the UI having
        // registered defaults — an unregistered read would return a spurious `false` that happens to
        // match the documented default today, and would silently stop matching if it ever changed.
        HeadacheDefaults.register()
        guard UserDefaults.standard.bool(forKey: HeadacheDefaults.enabled) else { return }

        let cal = Calendar.current
        let day = cal.startOfDay(for: now)

        // Already frozen: the ONLY thing this pass may do is record that the night re-staged
        // underneath the score. The score itself is never touched — a re-staged day is EXCLUDED from
        // the Phase-3 evaluation instead, because rescoring it would break the freeze (§3.8).
        // Look the frozen row up by the night's TIMEZONE-STABLE key first, falling back to `day`.
        // A device that has changed timezone recomputes `day` differently, and a `day`-only lookup
        // would miss the row it already wrote — silently dropping this night's re-stage flag, which
        // is what keeps a stale score out of the Phase-3 denominator.
        let tonight = Self.nightEnding(on: day, store: store, calendar: cal)
        let frozenByNight = tonight.flatMap { try? store.riskRow(nightKey: $0.night) }
        if let frozen = frozenByNight ?? Self.frozenRow(store: store, day: day, calendar: cal) {
            guard !frozen.sleepRestaged, let recordedAt = frozen.sleepUpdatedAt else { return }
            if let night = tonight, night.updatedAt != recordedAt {
                // Mark against the ROW's own day, not the recomputed one, for the same reason.
                try? store.markRiskRestaged(day: frozen.day, sleepUpdatedAt: night.updatedAt)
            }
            return
        }

        // Not frozen yet: there must be a night, and it must have settled.
        guard let night = Self.nightEnding(on: day, store: store, calendar: cal) else { return }
        let inBedEnd = night.sleepEditCurrentInBedEnd
        guard inBedEnd > .distantPast,
              now >= inBedEnd.addingTimeInterval(TimeInterval(Self.settleMarginMinutes) * 60)
        else { return }
        // Read the watermark BEFORE suspending: `night` is a live `@Model` reference and must not be
        // touched again after the `await` (the row can be re-staged, or deleted, under us).
        let sleepUpdatedAt = night.updatedAt

        let snapshot = Self.snapshot(store: store, day: day, asOf: now,
                                     restingHR: restingHR, calendar: cal)
        let verdict = await Task.detached { HeadacheAssessmentBuilder.verdict(snapshot) }.value
        // Only a SCORED day gets a row. `.buildingBaseline` / `.interrupted` / `.insufficientData`
        // have no index, and writing a 0 for them would put a fabricated value into the very series
        // the percentile budget and the Phase-3 evaluation are computed over.
        guard case .scored(let assessment) = verdict else { return }

        let row = StoredHeadacheRisk(
            day: day,
            // The timezone-stable identity of the night being scored, so this row can still be
            // found after the device changes timezone and `day` is recomputed differently.
            nightKey: night.night,
            index: Double(assessment.index),
            bandRaw: assessment.band.rawValue,
            ringFeatureCount: assessment.ringFeatureCount,
            coverageFraction: assessment.coverageFraction,
            contributionsJSON: HeadacheRiskCoding.encodeContributions(assessment.contributions),
            absentJSON: HeadacheRiskCoding.encodeAbsent(assessment.contributions),
            // The freeze instant, and therefore the start of the 24 h outcome window a Phase-3
            // prediction is credited against (§5.1). Deliberately the snapshot's `now`, so the
            // recorded instant is the one the score's inputs were cut at.
            computedAt: now,
            sleepUpdatedAt: sleepUpdatedAt,
            sleepRestaged: false,
            alerted: false,
            // Promotion statistics are computed on PRE-unlock days only, so a day scored after
            // alerts unlocked can never be used to validate the gate that unlocked them.
            postUnlock: UserDefaults.standard.bool(forKey: HeadacheDefaults.unlocked),
            updatedAt: now)

        // Two overlapping wake paths can both have passed the "not frozen" check above and then
        // suspended. `insertRiskDayIfAbsent` re-checks synchronously on the main actor, so the second
        // one is a no-op rather than a duplicate.
        if (try? store.insertRiskDayIfAbsent(row)) == true {
            ringLog.notice("headache signals: froze day (ring features \(assessment.ringFeatureCount, privacy: .public), coverage \(String(format: "%.2f", assessment.coverageFraction), privacy: .public))")
        }
    }

    // MARK: Read path

    /// Today's verdict for the card. Cheap, WRITES NOTHING, `nil` when the feature is off.
    ///
    /// When the day is already frozen this re-runs the assessment AS OF the freeze instant — the same
    /// inputs, cut at the same moment — so the card reproduces the number that was recorded instead of
    /// one that has since drifted (today's resting HR keeps falling as more readings arrive). It is a
    /// reproduction, not a replay: the Kit's `Assessment`/`Contribution` have no public memberwise
    /// initialiser, so the frozen row cannot be turned back into a `Verdict` from outside the Kit. If
    /// the night has re-staged since the freeze the two WILL differ — read `frozenToday` for the
    /// number of record.
    func todaysVerdict(store: LocalStore, now: Date = Date()) async -> HeadacheSignals.Verdict? {
        HeadacheDefaults.register()
        guard UserDefaults.standard.bool(forKey: HeadacheDefaults.enabled) else { return nil }

        let cal = Calendar.current
        let day = cal.startOfDay(for: now)
        let asOf = Self.frozenRow(store: store, day: day, calendar: cal)?.computedAt ?? now
        let snapshot = Self.snapshot(store: store, day: day, asOf: asOf,
                                     restingHR: [], calendar: cal)
        return await Task.detached { HeadacheAssessmentBuilder.verdict(snapshot) }.value
    }

    /// The frozen row for `now`'s day, or nil. The number OF RECORD — prefer it over a live
    /// recompute wherever a stored index or band is being shown.
    func frozenToday(store: LocalStore, now: Date = Date()) -> StoredHeadacheRisk? {
        Self.frozenRow(store: store, day: Calendar.current.startOfDay(for: now),
                       calendar: Calendar.current)
    }

    // MARK: Fetching

    /// The frozen row for `day`, if there is one. Single-day bounded fetch.
    static func frozenRow(store: LocalStore, day: Date, calendar: Calendar) -> StoredHeadacheRisk? {
        (try? store.riskDays(from: day, to: nextDay(after: day, calendar)))?.first
    }

    /// The stored night that ENDED on `day` — the one this morning's score is about.
    ///
    /// Keyed on the in-bed END rather than the row's `night` key (start-of-day of the sleep window's
    /// START), because a bedtime that straddles midnight files the night under the previous calendar
    /// day.
    ///
    /// Bounded at local NOON, not at end-of-day. Taking the latest-ending row anywhere in the
    /// calendar day sounds safer but is backwards: tonight's bedtime is inside the same calendar
    /// day, so an evening block — a nap, or the first minutes of tonight's sleep already drained by
    /// the ring — ends LATER than this morning's night and wins the `max`. This morning's score
    /// would then be computed from tonight's opening minutes. A night that this morning's score is
    /// about always ends before noon.
    static func nightEnding(on day: Date, store: LocalStore,
                            calendar: Calendar) -> StoredSleepSummary? {
        let end = nextDay(after: day, calendar)
        let cutoff = min(calendar.date(byAdding: .hour, value: 12, to: day) ?? end, end)
        return ((try? store.recentSleepSummaries(limit: nightsFetchLimit)) ?? [])
            .filter { $0.sleepEditCurrentInBedEnd >= day && $0.sleepEditCurrentInBedEnd < cutoff }
            .max { $0.sleepEditCurrentInBedEnd < $1.sleepEditCurrentInBedEnd }
    }

    /// Fetch every row the assessment needs and flatten it to Sendable values, ON THE MAIN ACTOR.
    /// Nothing below this line may be touched from the detached task (`@Model` objects are not
    /// Sendable, and reading one off-actor is the crash this shape exists to prevent).
    static func snapshot(store: LocalStore, day: Date, asOf: Date,
                         restingHR: [RestingHR.DailyValue],
                         calendar: Calendar) -> HeadacheSnapshot {
        let defaults = UserDefaults.standard
        let end = nextDay(after: day, calendar)

        let nights = ((try? store.recentSleepSummaries(limit: nightsFetchLimit)) ?? [])
            .map(HeadacheNightRow.init)
            .sorted { $0.night < $1.night }
        let tonight = nights.filter { $0.inBedEnd >= day && $0.inBedEnd < end }
            .max { $0.inBedEnd < $1.inBedEnd }

        // Bounded by the predicate, and additionally by the 30-day sample retention.
        let sampleStart = calendar.date(byAdding: .day, value: -sampleLookbackDays, to: day) ?? day
        let hr = ((try? store.samples(kind: .heartRate, from: sampleStart, to: asOf)) ?? [])
            .map { HRSample(bpm: Int($0.value), start: $0.start, end: $0.end) }
        // 0 is a placeholder, not a measured HRV — dropping it here keeps a zero out of a baseline.
        let hrv = ((try? store.samples(kind: .hrvSDNN, from: sampleStart, to: asOf)) ?? [])
            .filter { $0.value > 0 }

        // The banding budget is a TRAILING-60-DAY window, not the last 60 rows: it exists to
        // re-calibrate within 60 days of a life change, and a user with gaps should not be judged
        // against months-old days (§3.7). `riskDays` is `[from, to)`, so today is excluded.
        let bandStart = calendar.date(byAdding: .day,
                                      value: -HeadacheSignals.Tuning().bandWindowDays,
                                      to: day) ?? day
        let priorIndices = ((try? store.riskDays(from: bandStart, to: day)) ?? [])
            .map { Int($0.index.rounded()) }

        // "Already having one" suppression. A severity-1 (`notPresent`) entry records the ABSENCE of
        // a headache — the same distinction the Apple Health import refuses to blur
        // (`HeadacheCardView.swift:235`) — so it must not suppress anything.
        let loggedToday = ((try? store.headacheEntries(from: day, to: end)) ?? [])
            .contains { $0.onset <= asOf && $0.severityRaw != 1 }

        let periods = ((try? store.allPeriodEntries()) ?? [])
            .map { CyclePredictor.PeriodEntry(start: $0.start, end: $0.end) }

        // Durable "the ring last delivered something" watermark, written by RingSession on every data
        // frame (`RingSession.swift:3423`). Stored as epoch seconds; 0 = never.
        let ringEpoch = defaults.double(forKey: ReminderDefaults.lastRingDataAt)

        // Scheduled bedtime for the truncation test — MANUAL schedule only, exactly as the sleep
        // card's truncation hint does it (`SleepCardView.swift:386-402`). No HealthKit query: this
        // runs on wake paths that must not block, and with no schedule `SleepCaptureCoverage`
        // correctly declines to guess rather than mistaking a short night for a truncated one.
        SleepScheduleDefaults.register(defaults)
        let scheduledBedtime: Date? = {
            guard defaults.bool(forKey: SleepScheduleDefaults.enabled),
                  let wake = tonight?.inBedEnd else { return nil }
            return SleepWindow.interval(
                bedMinutes: defaults.integer(forKey: SleepScheduleDefaults.bedMinutes),
                wakeMinutes: defaults.integer(forKey: SleepScheduleDefaults.wakeMinutes),
                nightEndingNear: wake, calendar: calendar)?.start
        }()

        return HeadacheSnapshot(
            day: day,
            now: asOf,
            lastRingDataAt: ringEpoch > 0 ? Date(timeIntervalSince1970: ringEpoch) : nil,
            nights: nights,
            tonight: tonight,
            hr: hr,
            hrv: hrv,
            providedRestingHR: restingHR,
            periods: periods,
            womensHealthEnabled: defaults.bool(forKey: womensHealthEnabledKey),
            scheduledBedtime: scheduledBedtime,
            headacheAlreadyLoggedToday: loggedToday,
            priorIndices: priorIndices)
    }

    private static func nextDay(after day: Date, _ calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
    }
}

extension HeadacheNightRow {
    /// Flatten a SwiftData night to a Sendable value. MAIN-ACTOR ONLY — the resulting value is what
    /// crosses into the detached task; the `@Model` row itself never does.
    @MainActor
    init(_ row: StoredSleepSummary) {
        self.init(night: row.night,
                  inBedStart: row.sleepEditCurrentInBedStart,
                  inBedEnd: row.sleepEditCurrentInBedEnd,
                  inBedSeconds: row.asSummary.inBed,
                  asleepMin: row.asleepMin,
                  awakeMin: row.awakeMin,
                  efficiency: row.efficiency,
                  skinTempC: row.skinTempC,
                  updatedAt: row.updatedAt)
    }
}

// MARK: - Frozen-row JSON

/// One feature's frozen numbers, as persisted inside `StoredHeadacheRisk.contributionsJSON`.
///
/// The keys are SHORT AND STABLE on purpose: the Diagnostics export and the Phase-3 evaluation read
/// these rows back, and the raw inputs behind them are gone — `StoredSample` prunes at 30 days, so a
/// score frozen today can never be recomputed in 60. A renamed key silently loses history the store
/// cannot re-derive.
struct HeadacheContributionRecord: Codable, Equatable, Sendable {
    /// The robust z for the series features; the raw signed °C offset for `skinTempDeviation`; 1 or 0
    /// for the binary `perimenstrual`. `nil` when the feature was ABSENT.
    var z: Double?
    /// The 0…1 ramp position. `nil` when ABSENT — never 0, which means "measured, and ordinary".
    var c: Double?
    /// The weight actually used, after the truncation quality multiplier and the 35 % single-feature
    /// cap. Recorded because renormalisation is over PRESENT features only, so a stored contribution
    /// cannot be re-weighted after the fact without it.
    var w: Double
}

/// Encode/decode the two JSON columns on `StoredHeadacheRisk`. One owner for the on-disk shape, so
/// the writer here and every later reader cannot drift apart.
enum HeadacheRiskCoding {

    /// `contributionsJSON`: an object keyed by `HeadacheSignals.Feature.rawValue`, holding every
    /// feature — present AND absent — so a thin day is legible from the row alone.
    static func encodeContributions(_ contributions: [HeadacheSignals.Contribution]) -> String {
        let pairs = contributions.map {
            ($0.feature.rawValue,
             HeadacheContributionRecord(z: $0.z, c: $0.contribution, w: $0.effectiveWeight))
        }
        return encode(Dictionary(pairs, uniquingKeysWith: { _, last in last }))
    }

    static func decodeContributions(_ raw: String) -> [HeadacheSignals.Feature: HeadacheContributionRecord] {
        let decoded: [String: HeadacheContributionRecord] = decode(raw) ?? [:]
        // Unknown keys decode AWAY rather than trapping: the feature set is expected to evolve, and a
        // row written by a newer build must stay readable by an older one (§4.2).
        return decoded.reduce(into: [:]) { out, entry in
            if let feature = HeadacheSignals.Feature(rawValue: entry.key) { out[feature] = entry.value }
        }
    }

    /// `absentJSON`: feature raw value → `AbsentReason` raw value, for the features that had no
    /// input. Absent features also appear in `contributionsJSON` with null `z`/`c`; this column is
    /// the direct answer to "WHY was it missing", which is what makes a thin day debuggable remotely.
    static func encodeAbsent(_ contributions: [HeadacheSignals.Contribution]) -> String {
        let pairs = contributions.compactMap { c -> (String, String)? in
            guard let reason = c.absentReason else { return nil }
            return (c.feature.rawValue, reason.rawValue)
        }
        return encode(Dictionary(pairs, uniquingKeysWith: { _, last in last }))
    }

    static func decodeAbsent(_ raw: String) -> [HeadacheSignals.Feature: HeadacheSignals.AbsentReason] {
        let decoded: [String: String] = decode(raw) ?? [:]
        return decoded.reduce(into: [:]) { out, entry in
            guard let feature = HeadacheSignals.Feature(rawValue: entry.key),
                  let reason = HeadacheSignals.AbsentReason(rawValue: entry.value) else { return }
            out[feature] = reason
        }
    }

    /// Sorted keys so two identical assessments produce byte-identical JSON — a diagnostics bundle
    /// stays diffable, and a row can be compared without parsing it.
    private static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    private static func decode<T: Decodable>(_ raw: String) -> T? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

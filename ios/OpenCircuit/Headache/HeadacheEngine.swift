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
// PHASE 3 adds a SECOND job to this file, at the bottom: the quality monitor. It does not change
// anything above — the freeze path is untouched — and it never writes to a frozen row. See the
// "Quality monitor" section header for what it decides and why the polarity is the way it is.

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
    /// Share of the in-bed window the ring recorded across, 0…1. **`-1` = NOT COMPUTED** — a row
    /// written before SchemaV7 — and must never be read as poor coverage.
    var coverageFraction: Double = -1
    /// Which basis this row's minutes were computed on (`SleepBasis`). Empty = unknown.
    ///
    /// The builder must not mix bases in one baseline: `HeadacheEngine` never recomputes a frozen
    /// day, so priors already on testers' phones hold asserted-INCLUSIVE `asleepMin` and
    /// `efficiency`. Comparing a measured-only today against those produces a spurious z for one
    /// whole baseline window — a wave of false flags at exactly the moment an honesty fix ships.
    var sleepBasis: String = ""
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

    /// Coverage at or above which a night's sleep features carry full weight. Below it they are
    /// halved by `HeadacheSignals.Tuning.truncatedSleepQuality` — down-weighted, not dropped,
    /// because dropping all three would leave GATE 4's anchor set (`HeadacheSignals.swift:445`)
    /// resting on HRV and resting HR, and HRV is computed from the very epochs that are missing, so
    /// those absences are CORRELATED and thin nights would flip `.scored` → `.insufficientData`
    /// wholesale. 🔴 PROVISIONAL — set from device coverage data before this is quoted as a rate.
    static let wellCoveredNightFraction = 0.90

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
        // the Kit halves the three sleep features most prone to that false positive.
        //
        // TWO INDEPENDENT WITNESSES, OR'd:
        //
        // 1. `SleepCaptureCoverage` — the shipped front-edge test. Positive evidence only: without a
        //    bedtime reference `classify` correctly declines to guess. That is also its limitation —
        //    it needs a MANUAL bedtime schedule, and it therefore fires on 0 of 21 corpus nights, so
        //    `truncatedSleepQuality` has been a dead knob since it shipped.
        //
        // 2. MEASURED COVERAGE — new, and the reason the knob comes alive. `coverageFraction` is
        //    written by the same code that tags segment provenance, needs no schedule, and catches
        //    the case the front-edge test structurally cannot: an INTERIOR hole. `R2_2026-08-18`
        //    (0.377 covered, a 4 h hole in the middle of the night) is invisible to (1) and obvious
        //    to (2).
        //
        // `-1` means "not computed" — a legacy row, or one written before SchemaV7 — and must NOT be
        // read as poor coverage; those rows fall back to witness (1) alone, exactly as today.
        let truncatedByFrontEdge = tonight.map {
            SleepCaptureCoverage.classify(capturedOnset: $0.inBedStart,
                                          capturedInBed: $0.inBedSeconds,
                                          scheduledBedtime: s.scheduledBedtime) == .likelyTruncated
        } ?? false
        let truncatedByCoverage = tonight.map {
            $0.coverageFraction >= 0 && $0.coverageFraction < Self.wellCoveredNightFraction
        } ?? false
        let truncated = truncatedByFrontEdge || truncatedByCoverage

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
    ///
    /// Two passes, in order: freeze last night, then let the quality monitor take its (rare) look.
    /// The monitor rides this call rather than being wired into the five evaluate sites separately —
    /// it needs exactly the same wake paths, and adding a sixth call to five files it does not own
    /// would be five more places to forget. It is cadence-gated to two `UserDefaults` reads on
    /// almost every pass (`refreshMonitor`).
    func refreshToday(store: LocalStore, restingHR: [RestingHR.DailyValue], now: Date = Date()) async {
        await freezeToday(store: store, restingHR: restingHR, now: now)
        await refreshMonitor(store: store, now: now)
    }

    /// The freeze pass — behaviour unchanged from Phase 2, split out only so `refreshToday` can run
    /// the monitor after it regardless of which of the freeze path's early returns was taken.
    private func freezeToday(store: LocalStore, restingHR: [RestingHR.DailyValue],
                             now: Date = Date()) async {
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
                  coverageFraction: row.coverageFraction,
                  sleepBasis: row.sleepBasis,
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

// MARK: - Quality monitor (#183, Phase 3)
//
// WHAT CHANGED FROM THE PLAN, AND WHY. docs/HEADACHE_SIGNALS.md §5.3 gated the notification behind
// PROOF: no alert until this user's own logged headaches showed the detector beating chance, which
// §1.1 computes as roughly a YEAR of complete logging for a typical episodic sufferer. That gate is
// gone. Two things replaced it:
//
//  1. The bar it was measured against. RingConn's own shipped "Headache Signs Alert" asks for a
//     5-day continuous-wear baseline plus a 7-day average and publishes NO accuracy number at all;
//     their copy hedges throughout ("SIGNS", "identify early SIGNALS", "POTENTIAL headache
//     symptoms"). A year-long proof gate is not the industry bar, it is an order of magnitude past
//     it.
//  2. What the ~26 % precision ceiling (§1) is actually an argument against. It is an argument
//     against CLAIMING TO PREDICT. It is not an argument against notifying, because a notification
//     that says "last night was unusual for you, and here is what drifted" is a MEASUREMENT — true
//     100 % of the time. Precision only starts to matter the moment we assert a headache is coming,
//     which the copy never does (`HeadacheSignalCopy`, and the notification body itself).
//
// So the notification goes live at `HeadacheSignals.Tuning.minDaysForBanding` frozen days. That is
// not a new threshold: it is the point at which `HeadacheSignals.band(index:priorIndices:...)` will
// return anything other than `.typical` at all. Below it there is no band, so there is nothing to
// notify about; at it, there is. Nothing was invented to pick that number.
//
// The statistics from §5.2 are still computed, on the same frozen rows, with the same exclusions.
// Their POLARITY is inverted: they no longer grant permission to fire, they withdraw it. Fire,
// measure, and switch the notification off for the users it demonstrably does not help. A detector
// that silently degrades is worse than one that never fired (§5.5), and that argument does not
// depend on which direction the gate points.
//
// THE FREEZE IS UNTOUCHED. Everything below READS `StoredHeadacheRisk` and writes nothing to it.
// The moment a monitor pass can rewrite a score, every number it produces is a retro-fit against a
// baseline that has already seen the label.

// MARK: Sendable snapshot (main actor → detached task)

/// One frozen row, flattened off SwiftData. Carries only what the evaluation reads — deliberately
/// NOT the contributions JSON, which is large, per-day, and irrelevant to a hit/miss count.
struct HeadacheFrozenRow: Sendable, Equatable {
    let day: Date
    let index: Double
    let bandRaw: Int
    let computedAt: Date
    let sleepRestaged: Bool
    let postUnlock: Bool
    let alerted: Bool
}

/// Everything the monitor needs, already off SwiftData.
struct HeadacheMonitorSnapshot: Sendable {
    let now: Date
    /// Frozen rows inside the evaluation window, oldest → newest.
    let rows: [HeadacheFrozenRow]
    /// ONSETS of real logged headaches (severity 1 `notPresent` already dropped), oldest → newest.
    ///
    /// Onsets only. The stored `end` is deliberately not carried, because the Kit's rule is
    /// onset-based on both sides — a hit is an onset in `(computedAt, +24 h]`, an exclusion is an
    /// onset in `[computedAt − 24 h, computedAt]` — and it owns that policy for a stated reason
    /// (HeadacheEvaluation.swift:197-202). Consulting `end` here would be the app layer quietly
    /// running a different definition than the Kit it reports through. See `scoredDays` for the one
    /// case that choice leaves behind.
    let onsets: [Date]
    /// How many of `onsets` fall inside the evaluation window — the "you logged N" figure the panel
    /// shows before any exclusion. `onsets` itself reaches slightly further back so a headache that
    /// was already running at the window's first score is still visible to the in-progress test.
    let onsetsInWindow: Int
    let lookCount: Int
    let lastDecisionAt: Date?
    let windowDays: Int
}

/// What the detail screen renders. A value type, built off the main actor, holding no `@Model`.
struct HeadacheMonitorReport: Sendable {
    let status: HeadacheEvaluation.Status
    /// `nil` only in `.building`, where nothing has been measured yet. Never a zeroed placeholder:
    /// "measured nothing" and "measured zero" are different findings.
    let metrics: HeadacheEvaluation.Metrics?
    /// Frozen days at which the notification exists at all, for the `.building` line. The count SO
    /// FAR comes from `Status.building(daysRemaining:)`, so the two can never disagree.
    let daysNeeded: Int
    /// Headaches logged in the window, BEFORE exclusions. Shown next to the usable count, because a
    /// user who logged 20 and is told 12 are usable is owed the difference.
    let loggedHeadaches: Int
    /// Logged headaches that no frozen row could be paired with at all — the ring wasn't worn that
    /// night, or nothing synced. The Kit cannot count these: a day with no row never reaches it.
    let labelsWithNoScore: Int
    /// Frozen rows dropped because their stored band isn't one this build knows. Normally 0; only a
    /// downgrade produces one. Surfaced rather than swallowed so a denominator can always be
    /// reconciled.
    let rowsWithUnknownBand: Int
    let lookCount: Int
    let lastDecisionAt: Date?
    let windowDays: Int
}

// MARK: Pure join (runs OFF the main actor)

/// Joins frozen scores to logged headaches and asks the Kit what the pairing is worth.
///
/// File-scope for the same reason `HeadacheAssessmentBuilder` is: a type nested in the `@MainActor`
/// engine inherits that actor, and this exists precisely to run off it.
enum HeadacheMonitorBuilder {

    /// Turn frozen rows + logged onsets into the Kit's scored days.
    ///
    /// THE JOIN IS ONE DECISION PER ROW: which single onset, if any, is the one relevant to this
    /// score. `ScoredDay` carries one `headacheOnset`, and the Kit reads its POSITION relative to
    /// `computedAt` to decide what the row is worth (HeadacheEvaluation.swift:304-335):
    ///   · in `(computedAt, computedAt + outcomeWindowHours]` → the row PREDICTED it;
    ///   · in `[computedAt − inProgressLookbackHours, computedAt]` → the headache was ALREADY UNDER
    ///     WAY when we scored, so the row is unclassifiable and is dropped from BOTH terms.
    /// So the in-progress side is chosen FIRST when both exist. That ordering is the whole point of
    /// the exclusion: a morning that began mid-attack must not be able to score itself a hit off the
    /// second headache of the same day. Feeding the later onset instead would inflate precision by
    /// exactly the days most likely to look impressive.
    ///
    /// LABEL BIAS — READ BEFORE ADDING A SHORTCUT. Everything here is only as good as the label
    /// series, and that series must be collected INDEPENDENTLY of what we scored. The logging paths
    /// are deliberately the ones that are not conditioned on our own output: the Siri intents, the
    /// Control Centre control, and the card's morning-after prompt, which triggers on an EMPTY day
    /// and explicitly ignores the score (`HeadacheCardView.showsYesterdayPrompt`). Do not add a
    /// "did you have a headache?" action to the notification, and do not gate a prompt on the band.
    /// Either one would collect labels disproportionately from days we flagged, and every precision
    /// number below would then be inflated by construction — invisibly, permanently, and with no way
    /// to repair the record afterwards.
    ///
    /// KNOWN RESIDUAL, and it belongs to the Kit rather than here: a long attack the user logged with
    /// an explicit end — onset more than `inProgressLookbackHours` before the score, end after it —
    /// was genuinely under way and is nonetheless counted as an ordinary negative day, because the
    /// Kit's rule is onset-based on purpose (one mis-typed date must not be able to delete a month of
    /// evidence). Reading `end` here to override that would put a second, divergent definition of
    /// "in progress" in the app layer. It biases the base rate very slightly DOWNWARD, which is the
    /// safe direction for a retirement test.
    static func scoredDays(_ s: HeadacheMonitorSnapshot,
                           tuning: HeadacheEvaluation.Tuning = .init())
        -> (days: [HeadacheEvaluation.ScoredDay], unknownBand: Int, labelsWithNoScore: Int) {
        let outcome = tuning.outcomeWindowHours * 3600
        let lookback = tuning.inProgressLookbackHours * 3600
        var unknownBand = 0
        var paired: Set<Date> = []

        let days = s.rows.compactMap { row -> HeadacheEvaluation.ScoredDay? in
            // A band raw value this build doesn't know can only come from a newer build's row after
            // a downgrade. We cannot say whether it was flagged, so it is dropped rather than read
            // as `.typical` — which would quietly deflate the flagged count and inflate precision.
            guard let band = HeadacheSignals.Band(rawValue: row.bandRaw) else {
                unknownBand += 1
                return nil
            }

            // Latest qualifying onset on the in-progress side (the attack we were inside), earliest
            // on the outcome side (the first thing that followed).
            let onset = s.onsets.last {
                $0 <= row.computedAt && $0 >= row.computedAt.addingTimeInterval(-lookback)
            } ?? s.onsets.first {
                $0 > row.computedAt && $0 <= row.computedAt.addingTimeInterval(outcome)
            }
            if let onset { paired.insert(onset) }

            return HeadacheEvaluation.ScoredDay(
                day: row.day,
                computedAt: row.computedAt,
                // Rounded to Int exactly as `HeadacheEngine.snapshot` rounds it for `priorIndices`,
                // so the series the monitor ranks is the series the banding budget was drawn from.
                // Two different roundings of one column would let the flagged days and the ranked
                // days disagree at the margin.
                index: Int(row.index.rounded()),
                band: band,
                headacheOnset: onset,
                // Handed over as facts; the Kit decides what they cost. Nothing is filtered here, so
                // `Metrics` can report how many days each exclusion removed instead of the panel
                // showing a denominator it cannot explain.
                sleepRestaged: row.sleepRestaged,
                postUnlock: row.postUnlock,
                alerted: row.alerted)
        }

        // Logged headaches no row could be paired with at all. The Kit cannot see these — a day with
        // no frozen row never becomes a `ScoredDay` — yet they are the largest single reason a user
        // who logged 20 headaches is told 12 were usable, and the one with an obvious cause (the
        // ring was off that night).
        let unpaired = s.onsets.suffix(s.onsetsInWindow).filter { !paired.contains($0) }.count
        return (days, unknownBand, unpaired)
    }

    static func report(_ s: HeadacheMonitorSnapshot) -> HeadacheMonitorReport {
        let joined = scoredDays(s)
        let status = HeadacheEvaluation.status(joined.days, now: s.now)
        // Taken from the status rather than by calling `metrics` a second time: `status` already
        // computed it over the same rows, and a second independent call is a second chance for the
        // two to disagree about what the panel is describing.
        let metrics: HeadacheEvaluation.Metrics? = {
            switch status {
            case .building:                       return nil
            case .monitoring(let m), .working(let m): return m
            case .retired(let m, _):              return m
            }
        }()
        return HeadacheMonitorReport(
            status: status,
            metrics: metrics,
            daysNeeded: HeadacheEvaluation.Tuning().minFrozenDaysForNotification,
            loggedHeadaches: s.onsetsInWindow,
            labelsWithNoScore: joined.labelsWithNoScore,
            rowsWithUnknownBand: joined.unknownBand,
            lookCount: s.lookCount,
            lastDecisionAt: s.lastDecisionAt,
            windowDays: s.windowDays)
    }
}

// MARK: Engine

@MainActor
extension HeadacheEngine {

    /// How far back the fetch reaches. Read LIVE from the Kit rather than copied: it is the same
    /// window the Kit then filters on (`HeadacheEvaluation.metrics` re-applies its own cutoff), so a
    /// local copy could only ever make the app fetch too little and silently shorten the evidence.
    static var monitorWindowDays: Int { HeadacheEvaluation.Tuning().evaluationWindowDays }

    /// Slack on the ONSET fetch only, so a headache that began just before the window and was still
    /// under way at its first score is visible to the Kit's in-progress test (whose lookback is 24 h).
    /// Never widens the denominator — `onsetsInWindow` counts onsets inside the window itself.
    static let monitorOnsetSlackDays = 2

    /// The key the NOTIFICATION gate reads to know it has been withdrawn.
    ///
    /// Referenced, never re-typed: `HealthNotificationCenter` declares it as READ-ONLY there and
    /// names this monitor as the owner of every write (HealthNotificationCenter.swift:415-428). Two
    /// spellings of one flag is exactly the drift hazard `HeadacheDefaults` exists to prevent, and
    /// here it would fail SILENTLY — the panel would say alerts were off while they kept arriving.
    /// It lives in that file rather than `HeadacheDefaults` only because neither change owns that
    /// file; hoisting it there later must keep the string value, or every retired user is un-retired.
    static var retiredKey: String { HealthNotificationCenter.headacheRetiredKey }

    /// Minimum gap between monitor DECISIONS. 🔴 PROVISIONAL — §5.4's `decisionIntervalDays`.
    ///
    /// The reason survives the polarity flip intact. Re-testing an accumulating window on every wake
    /// is a multiple-comparisons machine: run it several times an hour for a year and the extreme
    /// tail is certain to be visited. Under the old design that produced false UNLOCKS; under this
    /// one it produces false RETIREMENTS, which is a feature silently disappearing on a user whose
    /// detector was fine. `lookCount` is persisted and shown for the same reason it always was.
    static let monitorDecisionIntervalDays = 28

    /// Consecutive decisions that must ALL recommend retirement before the notification is actually
    /// withdrawn. 🔴 PROVISIONAL — §5.4's `requiredConsecutivePasses`, inverted with the polarity.
    ///
    /// This is not defensiveness, it is the Kit's explicit caller contract
    /// (`HeadacheEvaluation.shouldRetire`): that function is stateless, so asking it more often
    /// finds more bad-luck runs, and its own measured synthetic-year number is that a chance-level
    /// detector retires for 15 % of users at a single look but 24 % when the same year is
    /// re-examined every 28 days. Acting on one look would have imported that 24 % wholesale.
    ///
    /// The cost is stated plainly: a detector that genuinely does not help takes ~56 days rather
    /// than ~28 to go quiet. That is the right direction to be slow in. The user is not being harmed
    /// while we wait — they are receiving a notification that only ever reports a MEASUREMENT — and
    /// the alternative error, silently deleting a working feature from someone's phone, is the one
    /// they cannot diagnose or appeal.
    static let requiredRetirementDecisions = 2

    // MARK: Write path

    /// Take the monitor's rare look. Safe to call from every wake path: once the notification has
    /// gone live, almost every pass is two `UserDefaults` reads and a return.
    ///
    /// Two decisions live here and they are deliberately asymmetric.
    ///
    /// ON is granted ONCE, the first time a band exists, and never again. `promotedOnDayKey` is the
    /// latch. Without it, this pass would re-grant the notification every wake and quietly overrule
    /// a user who had just switched it off in Settings — an automatic decision must never be able to
    /// undo an explicit one.
    ///
    /// OFF is the only thing a later decision can do, and it takes `requiredRetirementDecisions`
    /// consecutive decisions that all agree. The monitor can withdraw the notification; it can never
    /// restore it. Restoring is the user's, through the detail screen (`resumeAlerts(now:)`),
    /// because a detector that we measured as not tracking anything and then turned back on by
    /// ourselves would be a loop with no one in it.
    ///
    /// `HeadacheDefaults.consecutivePasses` is reused for that run. Its comment in that file still
    /// describes the pre-inversion design ("the unlock requires more than one, so a single lucky
    /// window can't promote"); the STORED MEANING is unchanged — a run of agreeing decisions — only
    /// the direction the run points has flipped, so the key keeps its value and no user's state is
    /// re-interpreted. That comment belongs to a file this change does not own; it should be
    /// re-worded there, not the key renamed here.
    func refreshMonitor(store: LocalStore, now: Date = Date()) async {
        HeadacheDefaults.register()
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: HeadacheDefaults.enabled) else { return }

        let cal = Calendar.current
        if defaults.integer(forKey: HeadacheDefaults.promotedOnDayKey) == 0 {
            // The one pass that costs a fetch on every wake, and only ever before the notification
            // has gone live once. It is a bounded predicate fetch of at most `bandWindowDays` small
            // rows — smaller than the `recentSleepSummaries(limit:)` the freeze path above already
            // pays on the same wake — and it stops for good the day it succeeds.
            Self.unlockIfBandExists(store: store, now: now, calendar: cal, defaults: defaults)
            return
        }

        // Cadence. A missing/zero `lastDecisionAt` after promotion means an interrupted upgrade;
        // start the clock rather than deciding immediately on data we have never looked at.
        let stamp = defaults.double(forKey: HeadacheDefaults.lastDecisionAt)
        guard stamp > 0 else {
            defaults.set(now.timeIntervalSince1970, forKey: HeadacheDefaults.lastDecisionAt)
            return
        }
        let last = Date(timeIntervalSince1970: stamp)
        let interval = TimeInterval(Self.monitorDecisionIntervalDays) * 86_400
        // `>=` on the elapsed gap, and a FUTURE stamp (clock moved back, restore from backup) also
        // waits: taking a decision early is exactly the extra look the interval exists to prevent.
        guard now >= last.addingTimeInterval(interval) else { return }

        // CLAIM the look before suspending, and record it whatever it goes on to conclude.
        //
        // Two overlapping wake paths can both clear the cadence guard above and then suspend on the
        // await below. Claiming first means the second one finds the interval unexpired and leaves,
        // instead of both peeking at the same window and both acting on it. An unrecorded look is a
        // free extra test, which is exactly what the interval exists to ration.
        //
        // The cost of claiming early is that a pass killed mid-evaluation spends a look without
        // concluding. That can only ever DELAY a retirement by one interval — the conservative
        // direction, because the irreversible-feeling action here is switching a feature off.
        defaults.set(now.timeIntervalSince1970, forKey: HeadacheDefaults.lastDecisionAt)
        let looks = defaults.integer(forKey: HeadacheDefaults.lookCount) + 1
        defaults.set(looks, forKey: HeadacheDefaults.lookCount)

        let snapshot = Self.monitorSnapshot(store: store, now: now, calendar: cal)
        let report = await Task.detached { HeadacheMonitorBuilder.report(snapshot) }.value

        // A run of AGREEING decisions, not one look. The counter resets the moment a decision
        // declines to retire, so only a CONSECUTIVE run counts — a single unlucky window cannot
        // accumulate toward a withdrawal months later.
        guard case .retired = report.status else {
            defaults.set(0, forKey: HeadacheDefaults.consecutivePasses)
            return
        }
        let agreeing = defaults.integer(forKey: HeadacheDefaults.consecutivePasses) + 1
        defaults.set(agreeing, forKey: HeadacheDefaults.consecutivePasses)
        guard agreeing >= Self.requiredRetirementDecisions else {
            ringLog.notice("headache signals: monitor recommends retiring (\(agreeing, privacy: .public) of \(Self.requiredRetirementDecisions, privacy: .public) agreeing decisions)")
            return
        }

        // Already withdrawn: nothing to do, and re-logging it every interval would bury the one
        // breadcrumb that says when it happened. This guard is also what lets a RESUMED user be
        // withdrawn a second time — `resumeAlerts` clears the flag and the counter, so a fresh run
        // of agreeing decisions can set it again, which is exactly what the detail screen promises
        // in words.
        guard !defaults.bool(forKey: Self.retiredKey) else { return }

        // BOTH KEYS, ALWAYS, TOGETHER. The fire path gates on `retiredKey` and does not read
        // `unlocked` at all (HealthNotificationCenter.headacheCandidate, and the Kit's
        // `HeadacheSignsNotifications.candidates(retired:)` behind it). Writing only `unlocked`
        // would leave the notification firing while every screen in the app said it had been
        // switched off — a failure whose only symptom is the alert the user was told had stopped.
        // `unlocked` stays as the mirror the detail screen (`alertsLive`), the Diagnostics export
        // and the freeze path's `postUnlock` column read, so the two are complements and are never
        // written apart.
        defaults.set(true, forKey: Self.retiredKey)
        defaults.set(false, forKey: HeadacheDefaults.unlocked)
        ringLog.notice("headache signals: monitor withdrew the morning notification at look \(looks, privacy: .public)")
    }

    /// Grant the notification the first time this user HAS a band.
    ///
    /// The test is not a new threshold. `HeadacheSignals.band` returns `.typical` unconditionally
    /// until it holds `minDaysForBanding` prior frozen indices (HeadacheSignals.swift:482-484), so
    /// below that line no day can ever be `.flagged` and there is literally nothing to notify about.
    ///
    /// Asked over the TRAILING BANDING WINDOW, excluding today, because that is what this app
    /// actually feeds `band`: `snapshot` builds `priorIndices` from `riskDays(from: bandStart, to:
    /// day)` — the trailing `bandWindowDays` CALENDAR days, not the last 60 rows. So this is the
    /// exact condition under which a `.flagged` day becomes possible, which is the only honest
    /// moment to tell a user their alerts are on. `HeadacheEvaluation.status` measures `.building`
    /// over its own 365-day window instead, which is looser; the two agree for anyone wearing the
    /// ring most nights, and where they don't, the detail screen says which one is speaking
    /// (`HeadacheSignalsView.alertStateLine`) rather than papering over it.
    ///
    /// Nothing re-locks when the count later falls back under the line (a month off the ring). It
    /// does not need to: `band` stops returning `.flagged` on its own, so the notification goes
    /// quiet structurally rather than by a flag we would have to keep in step.
    private static func unlockIfBandExists(store: LocalStore, now: Date, calendar: Calendar,
                                           defaults: UserDefaults) {
        let day = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -HeadacheSignals.Tuning().bandWindowDays,
                                  to: day) ?? day
        let priorDays = ((try? store.riskDays(from: start, to: day)) ?? []).count
        // Read through the Kit's own knob, which reads `minDaysForBanding` live, so the number that
        // switches the notification on and the number the panel counts toward cannot drift apart.
        guard priorDays >= HeadacheEvaluation.Tuning().minFrozenDaysForNotification else { return }

        // Both keys, together, per the rule stated in `refreshMonitor`. Retirement cannot have
        // happened yet on this path (it runs only while `promotedOnDayKey == 0`, and only a
        // post-promotion decision can retire), so the `false` is a no-op today. It is written
        // anyway because "these two are never written apart" is only a real invariant if it has no
        // exceptions to remember.
        defaults.set(false, forKey: retiredKey)
        defaults.set(true, forKey: HeadacheDefaults.unlocked)
        defaults.set(TempFeverNotifications.dayKey(for: day, calendar: calendar),
                     forKey: HeadacheDefaults.promotedOnDayKey)
        // Start the decision clock here, so the first retirement decision is taken a full interval
        // after the notification went live rather than on the next wake with almost no fired days
        // behind it.
        defaults.set(now.timeIntervalSince1970, forKey: HeadacheDefaults.lastDecisionAt)
        ringLog.notice("headache signals: morning notification live (\(priorDays, privacy: .public) scored days in the banding window)")
    }

    /// Put the notification back on at the user's request, after the monitor withdrew it.
    ///
    /// Resets the decision clock deliberately. Otherwise the very next wake would land on an overdue
    /// decision, re-run the same window that has barely changed, and switch it straight back off —
    /// the user would tap a button that visibly does nothing. A month is also long enough for the
    /// window to actually contain new evidence, which is what the detail screen promises in words.
    func resumeAlerts(now: Date = Date()) {
        HeadacheDefaults.register()
        let defaults = UserDefaults.standard
        // RESUME only — never a first grant. The 21-night floor is the one thing that cannot be
        // waived by a tap: below it `HeadacheSignals.band` has no percentile window, so an alert
        // switched on here could not fire and the button would be a promise the app cannot keep.
        // The detail screen only offers it once `promotedOnDayKey` is set; this re-checks rather
        // than trusting a caller, because it is the policy that matters, not the button.
        guard defaults.bool(forKey: HeadacheDefaults.enabled),
              defaults.integer(forKey: HeadacheDefaults.promotedOnDayKey) != 0 else { return }
        // `retiredKey` FIRST and always: it is the flag the fire path actually reads, so clearing
        // only `unlocked` would leave the button visibly doing nothing while the panel claimed the
        // alerts were back on. `unlocked` follows as its mirror.
        defaults.set(false, forKey: Self.retiredKey)
        defaults.set(true, forKey: HeadacheDefaults.unlocked)
        // Clear the run of agreeing decisions too, for the same reason the clock is reset: leaving
        // it at the count that just triggered a withdrawal would let the very next decision meet
        // `requiredRetirementDecisions` on its own, and the button would visibly undo itself.
        defaults.set(0, forKey: HeadacheDefaults.consecutivePasses)
        defaults.set(now.timeIntervalSince1970, forKey: HeadacheDefaults.lastDecisionAt)
    }

    // MARK: Read path

    /// The monitor's current reading, for the detail screen. WRITES NOTHING — opening a screen must
    /// not be able to spend a decision, or the cadence above is decoration.
    func monitorReport(store: LocalStore, now: Date = Date()) async -> HeadacheMonitorReport? {
        HeadacheDefaults.register()
        guard UserDefaults.standard.bool(forKey: HeadacheDefaults.enabled) else { return nil }
        let snapshot = Self.monitorSnapshot(store: store, now: now, calendar: Calendar.current)
        return await Task.detached { HeadacheMonitorBuilder.report(snapshot) }.value
    }

    // MARK: Fetching

    /// Fetch the frozen rows and the labels and flatten both, ON THE MAIN ACTOR. Nothing below the
    /// return may be touched off it.
    static func monitorSnapshot(store: LocalStore, now: Date,
                                calendar: Calendar) -> HeadacheMonitorSnapshot {
        let defaults = UserDefaults.standard
        let windowDays = monitorWindowDays
        let day = calendar.startOfDay(for: now)
        let end = nextDay(after: day, calendar)
        let windowStart = calendar.date(byAdding: .day, value: -windowDays, to: day) ?? day
        let onsetStart = calendar.date(byAdding: .day, value: -monitorOnsetSlackDays,
                                       to: windowStart) ?? windowStart

        let rows = ((try? store.riskDays(from: windowStart, to: end)) ?? [])
            .map(HeadacheFrozenRow.init)

        // Severity 1 is `notPresent` — a record that there was NO headache. It is a label the user
        // gave us and it is not a headache; counting it as one would fabricate an event and inflate
        // every number on the panel. Same rule the freeze path applies to the suppression check.
        let onsets = ((try? store.headacheEntries(from: onsetStart, to: end)) ?? [])
            .filter { $0.severityRaw != 1 }
            .map(\.onset)

        let stamp = defaults.double(forKey: HeadacheDefaults.lastDecisionAt)
        return HeadacheMonitorSnapshot(
            now: now,
            rows: rows,
            onsets: onsets,
            onsetsInWindow: onsets.filter { $0 >= windowStart }.count,
            lookCount: defaults.integer(forKey: HeadacheDefaults.lookCount),
            lastDecisionAt: stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil,
            windowDays: windowDays)
    }
}

extension HeadacheFrozenRow {
    /// Flatten a frozen SwiftData row. MAIN-ACTOR ONLY — the value crosses into the detached task,
    /// the `@Model` never does.
    @MainActor
    init(_ row: StoredHeadacheRisk) {
        self.init(day: row.day,
                  index: row.index,
                  bandRaw: row.bandRaw,
                  computedAt: row.computedAt,
                  sleepRestaged: row.sleepRestaged,
                  postUnlock: row.postUnlock,
                  alerted: row.alerted)
    }
}

import XCTest
@testable import OpenCircuitKit

/// SYNTHETIC-ONLY tests for the overnight-signals index (#183, Phase 2). Every series is a flat
/// hand-built vector with a known median and MAD — never a real health value, never a value taken
/// from a capture or a device pull.
///
/// These prove CORRECTNESS, NOT SKILL. They show the machine computes what
/// `HeadacheSignals.swift` says it computes, that a missing input is ABSENT rather than a
/// substituted zero, and that the structural guards (ring-feature minimum, anchor, 35 % cap,
/// multi-feature top band, alert budget) actually hold. Nothing here — and nothing that can be
/// written here — says the index predicts anything. That is §5's job and it needs a year of real
/// labels.
final class HeadacheSignalsTests: XCTestCase {

    private typealias Feature = HeadacheSignals.Feature
    private typealias Series = HeadacheSignals.Series
    private typealias Contribution = HeadacheSignals.Contribution
    private typealias Assessment = HeadacheSignals.Assessment
    private typealias Verdict = HeadacheSignals.Verdict

    // MARK: Fixture

    // A fixed synthetic instant. Nothing about it is a real night.
    private let day = Date(timeIntervalSince1970: 1_753_660_800)
    private var now: Date { day.addingTimeInterval(8 * 3600) }

    // Flat baselines, so 1.4826 · MAD == 0 and the z-scale is exactly the feature's noise floor.
    // Every expected value below is therefore hand-computable as `delta / noiseFloor`.
    // The bases are chosen so a ±2 z probe stays physically plausible in both directions
    // (e.g. efficiency 90 ± 10 %-pt, fragmentation 40 ± 30 min) — a test must not need an
    // impossible reading to exercise the symmetry.
    private let rhrBase = 60.0          // floor 5 bpm
    private let hrvBase = 50.0          // floor 8 ms
    private let effBase = 90.0          // floor 5 %-pt
    private let fragBase = 40.0         // floor 15 min
    private let durBase = 420.0         // floor 30 min
    private let bedBase = 23 * 60       // 23:00, floor 30 min
    private let dayHRBase = 70.0        // let-down uses the restingHR floor, 5 bpm

    private func flat(_ value: Double, _ count: Int = 14) -> [Double] {
        Array(repeating: value, count: count)
    }

    /// One day's input. Passing `nil` for a today-value makes that feature ABSENT, which is the
    /// distinction most of this file exists to police.
    private func input(rhrToday: Double? = 60,
                       hrvToday: Double? = 50,
                       effToday: Double? = 90,
                       fragToday: Double? = 40,
                       durToday: Double? = 420,
                       tempOffsetC: Double? = 0,
                       bedToday: Int? = 23 * 60,
                       bedPriorNights: Int = 14,
                       dayHRPrevious: Double? = 70,
                       dayHRTwoDaysAgo: Double? = 70,
                       dayHRPriorNights: Int = 14,
                       peri: Bool? = false,
                       truncated: Bool = false,
                       fever: Bool = false,
                       alreadyLogged: Bool = false,
                       priorIndices: [Int] = [],
                       lastRingDataAt: Date? = nil) -> HeadacheSignals.DayInput {
        func series(_ today: Double?, _ base: Double) -> Series? {
            today.map { Series(today: $0, prior: flat(base)) }
        }
        return HeadacheSignals.DayInput(
            day: day,
            now: now,
            lastRingDataAt: lastRingDataAt ?? now.addingTimeInterval(-3600),
            restingHR: series(rhrToday, rhrBase),
            hrvSDNN: series(hrvToday, hrvBase),
            sleepEfficiencyPct: series(effToday, effBase),
            sleepFragmentationMin: series(fragToday, fragBase),
            sleepDurationMin: series(durToday, durBase),
            skinTempOffsetC: tempOffsetC,
            inBedStartMinutes: bedToday,
            priorInBedStartMinutes: Array(repeating: bedBase, count: bedPriorNights),
            dayHRPrevious: dayHRPrevious,
            dayHRTwoDaysAgo: dayHRTwoDaysAgo,
            dayHRPrior: flat(dayHRBase, dayHRPriorNights),
            isPerimenstrual: peri,
            sleepLikelyTruncated: truncated,
            feverSuspected: fever,
            headacheAlreadyLoggedToday: alreadyLogged,
            priorIndices: priorIndices)
    }

    private func assessment(_ verdict: Verdict) -> Assessment? {
        if case .scored(let a) = verdict { return a }
        return nil
    }

    private func contribution(_ a: Assessment, _ feature: Feature) -> Contribution? {
        a.contributions.first { $0.feature == feature }
    }

    // MARK: An ordinary day

    /// Every feature sitting on its own baseline scores exactly 0 — not a fabricated "low risk"
    /// number. The ramp's `onsetZ` exists precisely so an ordinary day has nothing to say.
    func testOrdinaryDayScoresZero() throws {
        let a = try XCTUnwrap(assessment(HeadacheSignals.assess(input())))

        XCTAssertEqual(a.index, 0)
        XCTAssertEqual(a.band, .typical)
        XCTAssertNil(a.suppressedBy)
        XCTAssertEqual(a.ringFeatureCount, 8, "all eight ring features measured")
        XCTAssertEqual(a.coverageFraction, 1.0, accuracy: 1e-9)
        for c in a.contributions where c.isPresent {
            XCTAssertEqual(c.contribution!, 0, accuracy: 1e-9, "\(c.feature.rawValue) must contribute 0")
        }
    }

    // MARK: Absent ≠ zero

    /// The single easiest way to fabricate a health value is to treat a missing input as a normal
    /// one. An absent feature must leave the DENOMINATOR, not enter the numerator as a 0.
    func testMissingInputsAreAbsentNotZero() throws {
        // Sleep efficiency 70 % against a flat 90 % baseline → (70-90)/5 = -4 z, clamped at the
        // ±4 zClamp, |z| ≥ saturationZ → contribution exactly 1.0. Everything else sits at 0.
        // `peri: nil` keeps the pool to ring features only.
        let a = try XCTUnwrap(assessment(HeadacheSignals.assess(
            input(hrvToday: nil, effToday: 70, peri: nil))))

        let hrv = try XCTUnwrap(contribution(a, .hrvDeviation))
        XCTAssertNil(hrv.contribution, "absent, NEVER 0")
        XCTAssertNil(hrv.z)
        XCTAssertEqual(hrv.absentReason, .noDataThisDay)
        XCTAssertEqual(hrv.effectiveWeight, 0, accuracy: 1e-9)
        XCTAssertFalse(hrv.isPresent)

        XCTAssertEqual(try XCTUnwrap(contribution(a, .sleepEfficiencyDrop).flatMap(\.contribution)),
                       1.0, accuracy: 1e-9)

        // Present weight = 1.00 − 0.14 (HRV) = 0.86, so index = round(100 · 0.18 / 0.86) = 21.
        XCTAssertEqual(a.index, 21)
        // The diluted answer — as if HRV had been measured and read exactly normal — is 18.
        XCTAssertNotEqual(a.index, 18, "an absent feature must not dilute the score")
        XCTAssertEqual(a.ringFeatureCount, 7)
        XCTAssertEqual(a.coverageFraction, 0.86, accuracy: 1e-9)
    }

    /// The reason must be specific: "we have never had enough of your history" is a different
    /// message to the user than "the ring gave us nothing last night".
    func testShortHistoryIsNoBaselineNotNoData() throws {
        var i = input()
        i.hrvSDNN = Series(today: 50, prior: flat(hrvBase, RobustBaseline.minBaselineDays - 1))
        let a = try XCTUnwrap(assessment(HeadacheSignals.assess(i)))
        XCTAssertEqual(try XCTUnwrap(contribution(a, .hrvDeviation)).absentReason, .noBaseline)
    }

    // MARK: Coverage and anchor gates

    func testBelowMinRingFeaturesReturnsNil() {
        // Three ring features measured (RHR, HRV, efficiency); everything else absent.
        let v = HeadacheSignals.assess(input(fragToday: nil, durToday: nil, tempOffsetC: nil,
                                             bedToday: nil, dayHRPrevious: nil,
                                             dayHRTwoDaysAgo: nil, peri: nil))
        guard case .insufficientData(let missing) = v else {
            return XCTFail("3 ring features must never produce a score, got \(v)")
        }
        XCTAssertNil(assessment(v), "no index, not even 0")
        XCTAssertEqual(missing[.skinTempDeviation], .noDataThisDay)
        XCTAssertEqual(missing[.sleepFragmentation], .noDataThisDay)
        XCTAssertEqual(missing[.sleepDurationDeviation], .noDataThisDay)
    }

    /// Guard 1 of the two that ring-fence cycle phase: a calendar lookup is not a measurement, so
    /// it can never make up the ring-feature shortfall.
    func testPerimenstrualDoesNotCountTowardRingMinimum() {
        let without = HeadacheSignals.assess(input(fragToday: nil, durToday: nil, tempOffsetC: nil,
                                                   bedToday: nil, dayHRPrevious: nil,
                                                   dayHRTwoDaysAgo: nil, peri: nil))
        let with = HeadacheSignals.assess(input(fragToday: nil, durToday: nil, tempOffsetC: nil,
                                                bedToday: nil, dayHRPrevious: nil,
                                                dayHRTwoDaysAgo: nil, peri: true))
        guard case .insufficientData = with else {
            return XCTFail("3 ring features + cycle phase is still 3 ring features, got \(with)")
        }
        XCTAssertEqual(with, without, "adding the calendar term changes nothing about the verdict")
    }

    /// A day built only from context — cycle phase, bedtime shift, skin temperature — has measured
    /// nothing about how the person actually slept or how their autonomic state moved.
    func testAnchorRuleRejectsContextOnlyDay() throws {
        let contextOnly = input(rhrToday: nil, hrvToday: nil, effToday: nil,
                                fragToday: nil, durToday: nil, tempOffsetC: 0.6, peri: true)

        // Under the shipped tuning the coverage gate (4 ring features) catches this first: there
        // are only three non-anchor ring features in existence, so the anchor gate is defence in
        // depth rather than the operative rule. Both must reject.
        guard case .insufficientData = HeadacheSignals.assess(contextOnly) else {
            return XCTFail("context-only day must never score")
        }

        // Isolate the anchor gate by lowering the coverage minimum to the three features present.
        var loose = HeadacheSignals.Tuning()
        loose.minRingFeaturesForScore = 3
        guard case .insufficientData = HeadacheSignals.assess(contextOnly, tuning: loose) else {
            return XCTFail("skin temp + schedule + let-down are all non-anchors — no verdict")
        }

        // Positive control: ADD one anchor and change nothing else — the same day now scores, so
        // the rejection above was the ANCHOR rule and not simply thin data.
        let anchored = input(hrvToday: nil, effToday: nil, fragToday: nil, durToday: nil,
                             tempOffsetC: 0.6, peri: true)
        XCTAssertNotNil(assessment(HeadacheSignals.assess(anchored, tuning: loose)),
                        "one anchor (resting HR) is enough")
    }

    /// A genuine first-week install must be told we are LEARNING, not that its ring gave us
    /// nothing. Those are different sentences and only one of them is true.
    ///
    /// REGRESSION LOCK. Gate 2 originally required BOTH no present ring feature AND every absent
    /// reason to be `.noBaseline` — which was unreachable by construction, because skin temperature
    /// has no baseline of its own: a nil offset records `.noDataThisDay` and a non-nil one makes the
    /// feature PRESENT, so the two conditions are mutually exclusive. `.buildingBaseline` could
    /// never be returned at all, and a 6-day-old install reported `.insufficientData`, which the
    /// card renders as "no sleep data for last night".
    ///
    /// The gate now asks whether the MISSING BASELINES alone would have carried us to the minimum.
    func testColdStartReportsBuildingBaselineNotMissingData() {
        var coldStart = input(tempOffsetC: nil, bedPriorNights: 6, dayHRPriorNights: 0, peri: nil)
        // Six nights of history everywhere: real values, no baseline yet anywhere.
        coldStart.restingHR = Series(today: rhrBase, prior: flat(rhrBase, 6))
        coldStart.hrvSDNN = Series(today: hrvBase, prior: flat(hrvBase, 6))
        coldStart.sleepEfficiencyPct = Series(today: effBase, prior: flat(effBase, 6))
        coldStart.sleepFragmentationMin = Series(today: fragBase, prior: flat(fragBase, 6))
        coldStart.sleepDurationMin = Series(today: durBase, prior: flat(durBase, 6))

        let verdict = HeadacheSignals.assess(coldStart)
        guard case .buildingBaseline(let daysRemaining) = verdict else {
            return XCTFail("a 6-day-old install is still learning, not missing data: got \(verdict)")
        }
        XCTAssertEqual(daysRemaining, 1, "6 nights held, 7 needed — one more night")

        // The count must come from the SERIES, not from `priorIndices`: those only accumulate once
        // a day actually scores, which is the very thing this gate is blocking. Reading them would
        // pin the message at "7 more nights" forever.
        XCTAssertTrue(coldStart.priorIndices.isEmpty, "fixture holds no frozen rows, by construction")
    }

    /// The other half of the same rule: an ESTABLISHED user whose ring simply did not report must
    /// NOT be told we are still learning about them. Missing baselines and missing data are
    /// different failures with different fixes (wait vs. check your ring).
    func testEstablishedUserWithNoDataIsInsufficientNotBuildingBaseline() {
        // 60 nights of history on every series, but nothing measured last night.
        var gap = input(tempOffsetC: nil, bedPriorNights: 60, dayHRPriorNights: 0, peri: nil)
        gap.restingHR = nil
        gap.hrvSDNN = nil
        gap.sleepEfficiencyPct = nil
        gap.sleepFragmentationMin = nil
        gap.sleepDurationMin = nil

        let verdict = HeadacheSignals.assess(gap)
        guard case .insufficientData(let missing) = verdict else {
            return XCTFail("no readings last night is a DATA gap, not a baseline gap: got \(verdict)")
        }
        XCTAssertEqual(missing[.restingHRDeviation], .noDataThisDay)
        XCTAssertEqual(missing[.hrvDeviation], .noDataThisDay)
    }

    // MARK: The 35 % cap

    /// The guard against a top-band day produced by a CALENDAR LOOKUP with no ring measurement
    /// contributing. Exhaustive over every 4-subset of the nine features INCLUDING
    /// `perimenstrual` — a sampled or cycle-excluding version of this test is written around the
    /// defect it is supposed to catch (docs/HEADACHE_SIGNALS.md §3.5).
    func testNoSingleFeatureExceedsCapAtMinimumFeatureCount() {
        let all = Feature.allCases
        let tuning = HeadacheSignals.Tuning()
        var subsets: [[Feature]] = []
        for a in 0..<all.count {
            for b in (a + 1)..<all.count {
                for c in (b + 1)..<all.count {
                    for d in (c + 1)..<all.count { subsets.append([all[a], all[b], all[c], all[d]]) }
                }
            }
        }
        XCTAssertEqual(subsets.count, 126, "C(9,4) — every 4-subset, not a sample")

        var subsetsThatNeededCapping = 0
        for subset in subsets {
            let contributions = all.map { f -> Contribution in
                subset.contains(f)
                    ? Contribution(feature: f, z: 4, contribution: 1,
                                   effectiveWeight: f.weight, absentReason: nil)
                    : Contribution(feature: f, z: nil, contribution: nil,
                                   effectiveWeight: 0, absentReason: .noDataThisDay)
            }
            let label = subset.map(\.rawValue).joined(separator: "+")

            let preTotal = contributions.reduce(0.0) { $0 + $1.effectiveWeight }
            if contributions.map(\.effectiveWeight).max()! / preTotal > tuning.maxSingleFeatureShare {
                subsetsThatNeededCapping += 1
            }

            let capped = HeadacheSignals.applySingleFeatureCap(contributions, tuning: tuning)
            let total = capped.reduce(0.0) { $0 + $1.effectiveWeight }
            let share = capped.map(\.effectiveWeight).max()! / total
            XCTAssertLessThanOrEqual(share, tuning.maxSingleFeatureShare + 1e-9,
                                     "\(label) leaves one feature at \(share) of the pool")
            // The cap redistributes; it must never zero a measured feature out of the pool.
            for c in capped where subset.contains(c.feature) {
                XCTAssertGreaterThan(c.effectiveWeight, 0, "\(label) dropped \(c.feature.rawValue)")
            }
        }
        XCTAssertGreaterThan(subsetsThatNeededCapping, 0, "if nothing needed capping the test is vacuous")
    }

    // MARK: Unsigned by design

    /// Pinned deliberately, not incidentally: pre-attack signal directions invert between people,
    /// so every feature except the let-down term scores departure in EITHER direction. The cost —
    /// an unusually restorative night scoring like a bad one — is the design, and this test is
    /// what stops someone "fixing" it without reading the header.
    func testUnsignedDeviationIsSymmetric() throws {
        // (feature, base, noise floor) — a ±2 z probe is base ± 2 · floor.
        let probes: [(Feature, Double, (Double) -> HeadacheSignals.DayInput)] = [
            (.restingHRDeviation, rhrBase, { self.input(rhrToday: $0) }),
            (.hrvDeviation, hrvBase, { self.input(hrvToday: $0) }),
            (.sleepEfficiencyDrop, effBase, { self.input(effToday: $0) }),
            (.sleepFragmentation, fragBase, { self.input(fragToday: $0) }),
            (.sleepDurationDeviation, durBase, { self.input(durToday: $0) }),
        ]
        // (|z| 2 − onsetZ 1) / (saturationZ 2.5 − onsetZ 1) = 2/3.
        let expected = 2.0 / 3.0

        for (feature, base, make) in probes {
            let delta = 2 * feature.noiseFloor
            let up = try XCTUnwrap(assessment(HeadacheSignals.assess(make(base + delta))))
            let down = try XCTUnwrap(assessment(HeadacheSignals.assess(make(base - delta))))
            let cUp = try XCTUnwrap(contribution(up, feature))
            let cDown = try XCTUnwrap(contribution(down, feature))

            XCTAssertEqual(cUp.contribution!, expected, accuracy: 1e-9, feature.rawValue)
            XCTAssertEqual(cDown.contribution!, cUp.contribution!, accuracy: 1e-9,
                           "\(feature.rawValue) must score the same in both directions")
            XCTAssertEqual(cDown.z!, cUp.z!, accuracy: 1e-9, "|z| is stored, so the sign is gone")
            XCTAssertEqual(up.index, down.index, "\(feature.rawValue): the whole index is symmetric")
        }

        // Skin temperature ramps in °C rather than z, so check it separately. Here the raw signed
        // offset IS kept on the contribution (the UI needs it) — only the contribution is unsigned.
        let warm = try XCTUnwrap(assessment(HeadacheSignals.assess(input(tempOffsetC: 0.75))))
        let cool = try XCTUnwrap(assessment(HeadacheSignals.assess(input(tempOffsetC: -0.75))))
        XCTAssertEqual(try XCTUnwrap(contribution(warm, .skinTempDeviation)).contribution!,
                       0.5, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(contribution(cool, .skinTempDeviation)).contribution!,
                       0.5, accuracy: 1e-9)
        XCTAssertEqual(warm.index, cool.index)
    }

    // MARK: The one signed term

    /// `arousalLetdown` is the exception: a FALL in daytime arousal from D−2 to D−1 is the risk
    /// direction (Lipton 2014), so a RISE must contribute nothing rather than being folded back in
    /// by `abs()`.
    func testLetdownIsSignedAndOnlyCountsAFall() throws {
        // Baseline day HR is flat at 70 with the 5 bpm resting-HR floor, so 80 → z = +2.
        let falling = try XCTUnwrap(assessment(HeadacheSignals.assess(
            input(dayHRPrevious: 70, dayHRTwoDaysAgo: 80))))     // z2 − z1 = 2 − 0 = +2
        let rising = try XCTUnwrap(assessment(HeadacheSignals.assess(
            input(dayHRPrevious: 80, dayHRTwoDaysAgo: 70))))     // z2 − z1 = −2 → clipped to 0

        let fell = try XCTUnwrap(contribution(falling, .arousalLetdown))
        let rose = try XCTUnwrap(contribution(rising, .arousalLetdown))
        // ⚠️ SPEC-vs-CODE: docs/HEADACHE_SIGNALS.md §3.2 lists a 0.5 z noise floor for this
        // feature, but `HeadacheSignals.swift:387-389` scores both days against
        // `Feature.restingHRDeviation.noiseFloor` (5 bpm) and never consumes
        // `Feature.arousalLetdown.noiseFloor`. Pinned to the CODE: with the 0.5 floor this z would
        // be 20 (clamped to 4), not 2. Reported with the Phase-2 hand-off — do not "fix" the test.
        XCTAssertEqual(fell.z!, 2, accuracy: 1e-9)
        XCTAssertEqual(fell.contribution!, 2.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(rose.z!, 0, accuracy: 1e-9)
        XCTAssertEqual(rose.contribution!, 0, accuracy: 1e-9, "a RISE in arousal is not the signal")
        XCTAssertGreaterThan(falling.index, rising.index)

        // Only D−1 and D−2 feed it: there is no today term, and no other field may leak in.
        // Same let-down inputs, everything else about the day pushed to an extreme.
        let noisyDay = try XCTUnwrap(assessment(HeadacheSignals.assess(
            input(rhrToday: 100, effToday: 60, tempOffsetC: 2.0,
                  dayHRPrevious: 70, dayHRTwoDaysAgo: 80, truncated: true))))
        XCTAssertEqual(try XCTUnwrap(contribution(noisyDay, .arousalLetdown)), fell,
                       "the let-down term saw only D−1 and D−2")

        // Absent when either day is missing — not silently treated as "no fall".
        let missing = try XCTUnwrap(assessment(HeadacheSignals.assess(input(dayHRTwoDaysAgo: nil))))
        XCTAssertEqual(try XCTUnwrap(contribution(missing, .arousalLetdown)).absentReason,
                       .noDataThisDay)
    }

    // MARK: Saturation and degenerate baselines

    func testSaturationClamps() throws {
        // 100 bpm against a flat 60 baseline is z = 8 raw, clamped to the ±4 zClamp; the ramp then
        // clamps at 1.0. Neither may overshoot.
        let a = try XCTUnwrap(assessment(HeadacheSignals.assess(input(rhrToday: 100))))
        let rhr = try XCTUnwrap(contribution(a, .restingHRDeviation))
        XCTAssertEqual(rhr.z!, RobustBaseline.zClamp, accuracy: 1e-9)
        XCTAssertEqual(rhr.contribution!, 1.0, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(rhr.contribution!, 1.0)

        // Skin temp saturates on its own °C ramp.
        let hot = try XCTUnwrap(assessment(HeadacheSignals.assess(input(tempOffsetC: 25))))
        XCTAssertEqual(try XCTUnwrap(contribution(hot, .skinTempDeviation)).contribution!,
                       1.0, accuracy: 1e-9)

        // Everything saturated at once is still an index of 100, never more.
        let everything = try XCTUnwrap(assessment(HeadacheSignals.assess(
            input(rhrToday: 100, hrvToday: 0, effToday: 40, fragToday: 200, durToday: 0,
                  tempOffsetC: 3, bedToday: 12 * 60, dayHRPrevious: 60, dayHRTwoDaysAgo: 100,
                  peri: true))))
        XCTAssertEqual(everything.index, 100)
    }

    /// A perfectly regular person has MAD == 0. The noise floor takes over as the scale, so a
    /// sub-floor wobble is treated as ABSENT DEVIATION — contribution exactly 0 — rather than the
    /// infinite z a raw divide would produce.
    func testZeroMADIsAbsentNotInfinite() throws {
        // 64 bpm against a flat 60 baseline: 4 bpm is below the 5 bpm floor → z 0.8 → below
        // onsetZ 1.0 → contributes 0. The feature is PRESENT with a real z; only the deviation is
        // absent.
        let a = try XCTUnwrap(assessment(HeadacheSignals.assess(input(rhrToday: 64))))
        let rhr = try XCTUnwrap(contribution(a, .restingHRDeviation))
        XCTAssertTrue(rhr.isPresent, "a flat baseline is a baseline, not a missing one")
        XCTAssertNil(rhr.absentReason)
        XCTAssertTrue(rhr.z!.isFinite)
        XCTAssertEqual(rhr.z!, 0.8, accuracy: 1e-9)
        XCTAssertEqual(rhr.contribution!, 0, accuracy: 1e-9)

        for c in a.contributions {
            XCTAssertTrue(c.z.map(\.isFinite) ?? true, "\(c.feature.rawValue) z is not finite")
            XCTAssertTrue(c.contribution.map(\.isFinite) ?? true,
                          "\(c.feature.rawValue) contribution is not finite")
            XCTAssertTrue(c.effectiveWeight.isFinite)
        }
        XCTAssertEqual(a.index, 0)
    }

    // MARK: Quality multipliers

    /// A ring-buffer-truncated night looks exactly like a genuinely short, broken one, so the two
    /// features most prone to that false positive are halved — and NOTHING else moves.
    func testTruncatedNightHalvesSleepWeight() throws {
        let normal = try XCTUnwrap(assessment(HeadacheSignals.assess(input())))
        let cut = try XCTUnwrap(assessment(HeadacheSignals.assess(input(truncated: true))))
        let halved: Set<Feature> = [.sleepDurationDeviation, .sleepFragmentation]

        for feature in Feature.allCases {
            let before = try XCTUnwrap(contribution(normal, feature))
            let after = try XCTUnwrap(contribution(cut, feature))
            if halved.contains(feature) {
                XCTAssertEqual(after.effectiveWeight,
                               feature.weight * HeadacheSignals.Tuning().truncatedSleepQuality,
                               accuracy: 1e-9, feature.rawValue)
                XCTAssertEqual(after.effectiveWeight, before.effectiveWeight / 2, accuracy: 1e-9)
            } else {
                XCTAssertEqual(after.effectiveWeight, before.effectiveWeight, accuracy: 1e-9,
                               "\(feature.rawValue) must be untouched by the truncation flag")
            }
            // Truncation changes the WEIGHT of the evidence, never the measurement itself.
            XCTAssertEqual(after.contribution, before.contribution, feature.rawValue)
            XCTAssertEqual(after.z, before.z, feature.rawValue)
        }
    }

    // MARK: Banding — the alert budget

    func testBandingRequiresMinDays() {
        let tuning = HeadacheSignals.Tuning()
        let thin = Array(repeating: 0, count: tuning.minDaysForBanding - 1)
        XCTAssertEqual(HeadacheSignals.band(index: 100, priorIndices: thin), .typical,
                       "below minDaysForBanding there is no band, ever")
        XCTAssertEqual(HeadacheSignals.band(index: 100, priorIndices: thin + [0]), .flagged,
                       "…and exactly at the minimum there is one")

        // End to end: a maximal day with too little history is still `.typical`.
        let a = assessment(HeadacheSignals.assess(
            input(rhrToday: 100, hrvToday: 0, effToday: 40, priorIndices: thin)))
        XCTAssertEqual(a?.band, .typical)
        XCTAssertGreaterThan(a?.index ?? 0, 0, "the index is real; only the band is withheld")
    }

    /// The false-alarm BUDGET, which is the only promise this feature actually makes: flagging the
    /// top decile of a person's own scale must cost roughly 0.8 interrupts a week (§1).
    ///
    /// Pooled over 50 independent synthetic years rather than asserted on one: a single year's
    /// realised rate is a binomial draw with sd ≈ 1.6 pp, so a one-year assertion at 11 % would be
    /// a coin flip and inviting a seed to be chosen until it passes. `contributions: []` isolates
    /// the percentile rule from the multi-feature rule tested below.
    func testHighBandRateIsBoundedByPercentile() {
        let years = 50
        let daysPerYear = 365
        var flagged = 0
        var elevatedOrWorse = 0

        for seed in 1...UInt64(years) {
            var rng = SeededUniform(seed: seed)
            var priorIndices: [Int] = []
            for _ in 0..<daysPerYear {
                let index = Int((rng.next01() * 100).rounded())
                let band = HeadacheSignals.band(index: index, priorIndices: priorIndices)
                if band == .flagged { flagged += 1 }
                if band > .typical { elevatedOrWorse += 1 }
                priorIndices.append(index)
            }
        }

        let total = Double(years * daysPerYear)
        let flaggedRate = Double(flagged) / total
        XCTAssertLessThanOrEqual(flaggedRate, 0.11,
                                 "flagged on \(flaggedRate) of days — over the ~0.8 alerts/week budget")
        // Positive control: the rule must not be vacuously safe by never firing.
        XCTAssertGreaterThan(flaggedRate, 0.08)
        XCTAssertGreaterThan(Double(elevatedOrWorse) / total, flaggedRate,
                             "the p75 band must be wider than the p90 band")
    }

    /// The thesis as an enforceable invariant: the top band can NEVER be reached by thresholding
    /// one input, however high that day ranks on the user's own scale.
    func testFlaggedRequiresThreeContributingFeatures() {
        let tuning = HeadacheSignals.Tuning()
        let priors = Array(repeating: 0, count: tuning.minDaysForBanding)

        func contributions(saturated: Int) -> [Contribution] {
            Feature.allCases.enumerated().map { i, f in
                Contribution(feature: f, z: 4, contribution: i < saturated ? 1.0 : 0.0,
                             effectiveWeight: f.weight, absentReason: nil)
            }
        }

        // Index 100 clears the p90 of every prior, so only the multi-feature rule can hold it back.
        XCTAssertEqual(HeadacheSignals.band(index: 100, priorIndices: priors,
                                            contributions: contributions(saturated: 1)),
                       .elevated, "one feature at 1.0 can never flag")
        XCTAssertEqual(HeadacheSignals.band(index: 100, priorIndices: priors,
                                            contributions: contributions(saturated: 2)),
                       .elevated, "two is still not enough")
        XCTAssertEqual(HeadacheSignals.band(index: 100, priorIndices: priors,
                                            contributions: contributions(saturated: 3)),
                       .flagged)
    }

    // MARK: Interruption

    func test24HourGapYieldsInterrupted() {
        let tuning = HeadacheSignals.Tuning()
        let gap = now.addingTimeInterval(-tuning.dataGapHours * 3600)
        XCTAssertEqual(HeadacheSignals.assess(input(lastRingDataAt: gap)), .interrupted(since: gap),
                       "exactly 24 h of silence already counts")

        let longer = now.addingTimeInterval(-30 * 3600)
        XCTAssertEqual(HeadacheSignals.assess(input(lastRingDataAt: longer)),
                       .interrupted(since: longer))

        // Never worn at all: still interrupted, and honest about having no `since`.
        var never = input()
        never.lastRingDataAt = nil
        XCTAssertEqual(HeadacheSignals.assess(never), .interrupted(since: nil))

        // Just inside the window a normal day is still assessed — the gate must not swallow it.
        let fresh = now.addingTimeInterval(-23 * 3600)
        XCTAssertNotNil(assessment(HeadacheSignals.assess(input(lastRingDataAt: fresh))))
    }

    // MARK: Suppression

    /// Suppression withholds the (Phase 3) notification candidate, not the score. The card still
    /// shows what was measured — hiding it would be a different kind of dishonesty.
    func testFeverSuppressesCandidateNotScore() throws {
        let plain = try XCTUnwrap(assessment(HeadacheSignals.assess(input(effToday: 70))))
        let fevered = try XCTUnwrap(assessment(HeadacheSignals.assess(input(effToday: 70, fever: true))))

        XCTAssertNil(plain.suppressedBy)
        XCTAssertEqual(plain.index, 15, "round(100 · 0.18 / 1.20) with every feature present")
        XCTAssertEqual(fevered.suppressedBy, .fever)
        XCTAssertEqual(fevered.index, plain.index)
        XCTAssertEqual(fevered.band, plain.band)
        XCTAssertEqual(fevered.contributions, plain.contributions)
        XCTAssertEqual(fevered.coverageFraction, plain.coverageFraction, accuracy: 1e-9)

        let logged = try XCTUnwrap(assessment(HeadacheSignals.assess(
            input(effToday: 70, alreadyLogged: true))))
        XCTAssertEqual(logged.suppressedBy, .headacheAlreadyLogged)
        XCTAssertEqual(logged.index, plain.index)

        // Fever wins: two interrupts for one physiological event devalues both.
        let both = try XCTUnwrap(assessment(HeadacheSignals.assess(
            input(effToday: 70, fever: true, alreadyLogged: true))))
        XCTAssertEqual(both.suppressedBy, .fever)
    }

    // MARK: Determinism

    /// A frozen row is written once and never recomputed, so two evaluations of the same day must
    /// not disagree — otherwise which one got frozen would be a race.
    func testIdempotent() {
        let sparse = input(hrvToday: nil, effToday: 70, truncated: true,
                           priorIndices: Array(0..<30))
        for day in [input(), sparse, input(rhrToday: 100, peri: true, fever: true)] {
            XCTAssertEqual(HeadacheSignals.assess(day), HeadacheSignals.assess(day))
            XCTAssertEqual(HeadacheSignals.assess(day, tuning: HeadacheSignals.Tuning()),
                           HeadacheSignals.assess(day))
        }
    }
}

// MARK: - Synthetic index generator

/// A tiny deterministic LCG, so `testHighBandRateIsBoundedByPercentile` is reproducible on every
/// machine and every run. SYNTHETIC — these are not anyone's indices.
private struct SeededUniform {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next01() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(state >> 11) * (1.0 / 9_007_199_254_740_992.0)   // 2⁻⁵³
    }
}

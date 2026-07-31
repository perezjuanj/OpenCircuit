import XCTest
@testable import OpenCircuitKit

/// SYNTHETIC-ONLY tests for the headache-signals QUALITY MONITOR (#183, Phase 3). Every index,
/// every label and every date below is generated from a seeded PRNG. Nothing here came from a
/// capture, a device pull, or a person.
///
/// These prove the MONITOR is honest, not that the detector has skill. The distinction matters more
/// in this file than anywhere else in the feature: this is the machinery that decides whether we
/// tell a user "this works for you", and a monitor that mistakes noise for skill is worse than no
/// monitor at all — it would launder the random walk of one person's year into an accuracy claim.
/// So the load-bearing test here is the NEGATIVE control (`testNoSkillIsNeverJudgedWorking`), and
/// the positive controls exist only to show the bar is not merely impossible.
final class HeadacheEvaluationTests: XCTestCase {

    private typealias Eval = HeadacheEvaluation
    private typealias ScoredDay = HeadacheEvaluation.ScoredDay
    private typealias Tuning = HeadacheEvaluation.Tuning

    // MARK: - Synthetic world

    /// Deterministic PRNG so every trial below is reproducible from its seed alone.
    private struct SplitMix64: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// A fixed synthetic instant. Not a real date for anybody.
    private let anchor = Date(timeIntervalSince1970: 1_600_000_000)

    /// Rows are frozen at ~10:00 — after the 3 h settle margin on a normal wake, matching §3.8.
    private let freezeOffset: TimeInterval = 10 * 3600

    private func day(_ i: Int) -> Date { anchor.addingTimeInterval(Double(i) * 86_400) }
    private func computedAt(_ i: Int) -> Date { day(i).addingTimeInterval(freezeOffset) }
    /// An evaluation instant late enough that day `count-1`'s 24 h outcome window has closed.
    private func now(after count: Int) -> Date {
        computedAt(count - 1).addingTimeInterval(28 * 3600)
    }

    private func gaussian(_ rng: inout SplitMix64) -> Double {
        let u1 = Double.random(in: 1e-12..<1, using: &rng)
        let u2 = Double.random(in: 0..<1, using: &rng)
        return (-2 * Foundation.log(u1)).squareRoot() * Foundation.cos(2 * .pi * u2)
    }

    /// A synthetic year for one user.
    ///
    /// The latent-plus-shift ("binormal") construction is the standard way to synthesise a detector
    /// of KNOWN skill: negatives draw a latent N(0,1), positives draw N(d', 1), and the resulting
    /// AUC is `Φ(d'/√2)`. The values used below are
    ///
    ///   d' = 0.00 → AUC 0.500 (no skill at all — index and label are independent)
    ///   d' = 0.55 → AUC 0.651 (the realistic centre of §1's table)
    ///   d' = 1.40 → AUC 0.839 (a strong personal detector)
    ///   d' = −0.75 → AUC 0.298 (actively anti-predictive)
    ///
    /// The latent is mapped to the 0…100 index by `max(0, round(20·latent + 5))`, which reproduces
    /// the structure that actually matters here: a large TIE MASS AT ZERO, because a day inside
    /// 1 MAD-unit on every feature scores a true 0 by design (`HeadacheSignals.Tuning.onsetZ`).
    /// Roughly 40 % of ordinary days land on exactly 0, so the tie rule is exercised on every trial
    /// rather than in a special case.
    ///
    /// Flagging takes the top `flaggedFraction` of the series by index, so `.flagged` lands on
    /// ~10 % of days — the false-alarm BUDGET the banding percentiles are chosen to hit (§3.7).
    private func makeYear(count: Int = 360,
                          positives: Int = 48,
                          dPrime: Double,
                          flaggedFraction: Double = 0.10,
                          alertFlaggedDays: Bool = true,
                          restagedEvery: Int? = nil,
                          rng: inout SplitMix64) -> [ScoredDay] {
        var isPositive = [Bool](repeating: false, count: count)
        for i in 0..<min(positives, count) { isPositive[i] = true }
        isPositive.shuffle(using: &rng)

        var indices = [Int](repeating: 0, count: count)
        for i in 0..<count {
            let latent = gaussian(&rng) + (isPositive[i] ? dPrime : 0)
            indices[i] = max(0, Int((20 * latent + 5).rounded()))
        }

        // Top-N by index; ties broken by position so the flag set is deterministic.
        let flagCount = Int((Double(count) * flaggedFraction).rounded())
        let flaggedSet = Set(indices.indices
            .sorted { indices[$0] == indices[$1] ? $0 < $1 : indices[$0] > indices[$1] }
            .prefix(flagCount))

        return (0..<count).map { i in
            let flagged = flaggedSet.contains(i)
            return ScoredDay(
                day: day(i),
                computedAt: computedAt(i),
                index: indices[i],
                band: flagged ? .flagged : (indices[i] > 0 ? .elevated : .typical),
                // A headache 6 h after the freeze — inside the outcome window, so it is a genuine
                // look-ahead rather than something already under way.
                headacheOnset: isPositive[i] ? computedAt(i).addingTimeInterval(6 * 3600) : nil,
                sleepRestaged: restagedEvery.map { i % $0 == 0 } ?? false,
                postUnlock: true,
                alerted: flagged && alertFlaggedDays)
        }
    }

    // MARK: - AUC

    func testAUCKnownAnswers() {
        // Perfect separation.
        XCTAssertEqual(Eval.auc(positiveScores: [10, 9, 8], negativeScores: [1, 2, 3])!,
                       1.0, accuracy: 1e-12)
        // Perfectly inverted.
        XCTAssertEqual(Eval.auc(positiveScores: [1, 2, 3], negativeScores: [10, 9, 8])!,
                       0.0, accuracy: 1e-12)
        // ALL TIES — the case that dominates real data, because an ordinary day scores exactly 0.
        // Splitting ties is the only convention under which a detector that emits the same number
        // every day reads as chance instead of as perfect.
        XCTAssertEqual(Eval.auc(positiveScores: [0, 0, 0, 0], negativeScores: [0, 0, 0])!,
                       0.5, accuracy: 1e-12)
        // Hand-computed 5×5 with a tie. positives {5,4,3,2,1} vs negatives {4,3,3,0,0}:
        //   5 beats all 5                              → 5.0
        //   4 beats {3,3,0,0} and ties {4}             → 4.5
        //   3 beats {0,0}, ties {3,3}, loses {4}       → 3.0
        //   2 beats {0,0}                              → 2.0
        //   1 beats {0,0}                              → 2.0
        //   U = 16.5, AUC = 16.5 / 25 = 0.66
        XCTAssertEqual(Eval.auc(positiveScores: [5, 4, 3, 2, 1], negativeScores: [4, 3, 3, 0, 0])!,
                       0.66, accuracy: 1e-12)
        // Undefined, not 0.5: one side empty means there is nothing to rank against.
        XCTAssertNil(Eval.auc(positiveScores: [], negativeScores: [1, 2]))
        XCTAssertNil(Eval.auc(positiveScores: [1, 2], negativeScores: []))
    }

    /// The shipped AUC uses the midrank identity for speed. This pins it to the definition it claims
    /// to implement — an explicit pairwise count with ties credited 0.5 — on tie-heavy random data.
    func testAUCMidrankIdentityMatchesPairwiseCount() {
        var rng = SplitMix64(seed: 0xC0FF_EE01)
        for _ in 0..<200 {
            // Deliberately coarse, so ties are common rather than incidental.
            let pos = (0..<Int.random(in: 1...12, using: &rng)).map { _ in
                Double(Int.random(in: 0...4, using: &rng))
            }
            let neg = (0..<Int.random(in: 1...12, using: &rng)).map { _ in
                Double(Int.random(in: 0...4, using: &rng))
            }
            var u = 0.0
            for p in pos {
                for n in neg { u += p > n ? 1 : (p == n ? 0.5 : 0) }
            }
            XCTAssertEqual(Eval.auc(positiveScores: pos, negativeScores: neg)!,
                           u / Double(pos.count * neg.count), accuracy: 1e-12)
        }
    }

    func testHanleyMcNeilCINarrowsAsNGrows() {
        // Same AUC, more data: the interval must shrink and must stay inside [0, 1].
        var previousWidth = Double.infinity
        for scale in [1, 2, 4, 8, 16] {
            let pos = Array(repeating: 60.0, count: 5 * scale) + Array(repeating: 10.0, count: 5 * scale)
            let neg = Array(repeating: 40.0, count: 10 * scale)
            let a = Eval.auc(positiveScores: pos, negativeScores: neg)!
            let se = Eval.hanleyMcNeilSE(auc: a, nPos: pos.count, nNeg: neg.count)!
            let low = max(0, a - 1.96 * se), high = min(1, a + 1.96 * se)
            XCTAssertGreaterThanOrEqual(low, 0)
            XCTAssertLessThanOrEqual(high, 1)
            XCTAssertLessThan(high - low, previousWidth)
            previousWidth = high - low
        }
    }

    // MARK: - The exact p-value

    func testHypergeometricTailMatchesHandComputedValue() {
        // N = 10 days, K = 4 headache days, n = 5 flagged, 3 of the flags landed on headaches.
        //   P(X ≥ 3) = [C(4,3)·C(6,2) + C(4,4)·C(6,1)] / C(10,5)
        //            = [4·15 + 1·6] / 252 = 66 / 252 = 0.2619047619047619
        XCTAssertEqual(Eval.hypergeometricUpperTail(observed: 3, flagged: 5, positives: 4, total: 10)!,
                       66.0 / 252.0, accuracy: 1e-12)
        // The whole distribution.
        XCTAssertEqual(Eval.hypergeometricUpperTail(observed: 0, flagged: 5, positives: 4, total: 10)!,
                       1.0, accuracy: 1e-12)
        // More hits than there are headaches is impossible, not merely unlikely.
        XCTAssertEqual(Eval.hypergeometricUpperTail(observed: 5, flagged: 5, positives: 4, total: 10)!,
                       0.0, accuracy: 1e-12)
        // Forced-hit floor: flagging 8 of 10 days when 4 are headaches guarantees ≥ 2 hits, so
        // P(X ≥ 2) is exactly 1 and no amount of "significance" can be squeezed out of it.
        XCTAssertEqual(Eval.hypergeometricUpperTail(observed: 2, flagged: 8, positives: 4, total: 10)!,
                       1.0, accuracy: 1e-12)
    }

    /// The p-value must be the EXACT tail, not a normal approximation. At the counts this feature
    /// actually sees — tens of positives — the normal approximation is anti-conservative in the
    /// upper tail: it reports a smaller p than the truth, on the one number that decides whether we
    /// tell a user the feature works for them.
    func testPValueIsExactNotNormalApproximated() {
        let total = 180, positives = 24, flagged = 18, observed = 6

        // Independent exact computation, written the naive way on purpose: a direct multiplicative
        // binomial coefficient, no log-gamma, no shared code with the implementation.
        func choose(_ n: Int, _ k: Int) -> Double {
            guard k >= 0, k <= n else { return 0 }
            var r = 1.0
            for i in 0..<min(k, n - k) { r = r * Double(n - i) / Double(i + 1) }
            return r
        }
        var exact = 0.0
        for k in observed...min(flagged, positives) {
            exact += choose(positives, k) * choose(total - positives, flagged - k)
        }
        exact /= choose(total, flagged)

        let measured = Eval.hypergeometricUpperTail(observed: observed, flagged: flagged,
                                                    positives: positives, total: total)!
        XCTAssertEqual(measured, exact, accuracy: 1e-9)

        // The normal approximation with a continuity correction, for contrast.
        let p = Double(positives) / Double(total)
        let mean = Double(flagged) * p
        let variance = Double(flagged) * p * (1 - p)
            * Double(total - flagged) / Double(total - 1)
        let z = (Double(observed) - 0.5 - mean) / variance.squareRoot()
        let normal = 0.5 * erfc(z / 2.0.squareRoot())

        XCTAssertLessThan(normal, measured,
                          "the normal approximation should be anti-conservative here")
        XCTAssertGreaterThan(measured - normal, 1e-3,
                             "the gap must be large enough to matter at α = 0.01")
    }

    // MARK: - Exclusions

    /// Restaged rows and already-in-progress rows must leave BOTH terms — numerator and denominator
    /// — and the counts must be visible, because an exclusion nobody can see is indistinguishable
    /// from data we quietly threw away.
    func testRestagedAndInProgressExcludedFromBothTermsAndCounted() {
        var rows: [ScoredDay] = []
        // 10 clean flagged-and-positive days.
        for i in 0..<10 {
            rows.append(ScoredDay(day: day(i), computedAt: computedAt(i), index: 90, band: .flagged,
                                  headacheOnset: computedAt(i).addingTimeInterval(3600)))
        }
        // 5 restaged days that also happen to be flagged hits — if they leaked in they would
        // flatter every number here.
        for i in 10..<15 {
            rows.append(ScoredDay(day: day(i), computedAt: computedAt(i), index: 95, band: .flagged,
                                  headacheOnset: computedAt(i).addingTimeInterval(3600),
                                  sleepRestaged: true))
        }
        // 4 days whose headache was already under way at freeze time.
        for i in 15..<19 {
            rows.append(ScoredDay(day: day(i), computedAt: computedAt(i), index: 95, band: .flagged,
                                  headacheOnset: computedAt(i).addingTimeInterval(-2 * 3600)))
        }
        // 6 clean non-flagged days with no headache.
        for i in 19..<25 {
            rows.append(ScoredDay(day: day(i), computedAt: computedAt(i), index: 0, band: .typical))
        }

        let m = Eval.metrics(rows, now: now(after: 25))
        XCTAssertEqual(m.scoredDays, 16)            // 10 + 6, nothing else
        XCTAssertEqual(m.labelledDays, 10)
        XCTAssertEqual(m.flaggedDays, 10)
        XCTAssertEqual(m.truePositives, 10)
        XCTAssertEqual(m.excludedRestaged, 5)
        XCTAssertEqual(m.excludedInProgress, 4)
        XCTAssertEqual(m.excludedUnresolved, 0)
        XCTAssertEqual(m.baseRate!, 10.0 / 16.0, accuracy: 1e-12)
        XCTAssertEqual(m.precision!, 1.0, accuracy: 1e-12)
        XCTAssertEqual(m.recall!, 1.0, accuracy: 1e-12)
    }

    /// A row is excluded ONCE. Restaged outranks in-progress: the score describes staging the app no
    /// longer believes, so nothing downstream of it is interpretable in the first place.
    func testExclusionPrecedenceCountsEachRowOnce() {
        let rows = [
            ScoredDay(day: day(0), computedAt: computedAt(0), index: 50, band: .flagged,
                      headacheOnset: computedAt(0).addingTimeInterval(-3600), sleepRestaged: true),
        ]
        let m = Eval.metrics(rows, now: now(after: 1))
        XCTAssertEqual(m.excludedRestaged, 1)
        XCTAssertEqual(m.excludedInProgress, 0)
        XCTAssertEqual(m.scoredDays, 0)
    }

    /// A headache that started BEFORE the freeze is never a hit. This is the difference between a
    /// prediction and a retrodiction, and it is exactly the number that would be quoted as evidence.
    func testOnsetBeforeComputedAtIsNeverCredited() {
        let atFreeze = ScoredDay(day: day(0), computedAt: computedAt(0), index: 99, band: .flagged,
                                 headacheOnset: computedAt(0))
        XCTAssertEqual(Eval.metrics([atFreeze], now: now(after: 1)).excludedInProgress, 1)

        // One second after the freeze IS inside the window — the boundary is half-open on purpose.
        let justAfter = ScoredDay(day: day(0), computedAt: computedAt(0), index: 99, band: .flagged,
                                  headacheOnset: computedAt(0).addingTimeInterval(1))
        let m = Eval.metrics([justAfter], now: now(after: 1))
        XCTAssertEqual(m.excludedInProgress, 0)
        XCTAssertEqual(m.labelledDays, 1)
        XCTAssertEqual(m.truePositives, 1)
    }

    /// A headache older than the in-progress lookback belongs to a different episode and must not
    /// silently disqualify the row. Without the bound, one mis-entered date could delete a month of
    /// evidence and nothing in the UI would explain the gap.
    func testStaleOnsetIsNotTreatedAsInProgress() {
        let stale = ScoredDay(day: day(3), computedAt: computedAt(3), index: 10, band: .typical,
                              headacheOnset: computedAt(3).addingTimeInterval(-72 * 3600))
        let m = Eval.metrics([stale], now: now(after: 4))
        XCTAssertEqual(m.excludedInProgress, 0)
        XCTAssertEqual(m.scoredDays, 1)
        XCTAssertEqual(m.labelledDays, 0)       // outside the outcome window ⇒ a negative day
    }

    /// A row whose 24 h outcome window is still open cannot be labelled yet — including one whose
    /// headache has ALREADY been logged. Keeping the known-positives while dropping the
    /// not-yet-known would bias the base rate and the precision upward by construction.
    func testUnresolvedOutcomeWindowExcludedIncludingKnownPositives() {
        let justFrozen = computedAt(1)
        let evaluatedAt = justFrozen.addingTimeInterval(2 * 3600)   // 22 h of window still open
        let rows = [
            ScoredDay(day: day(1), computedAt: justFrozen, index: 80, band: .flagged,
                      headacheOnset: justFrozen.addingTimeInterval(3600)),   // already positive
            ScoredDay(day: day(1), computedAt: justFrozen, index: 5, band: .typical),
        ]
        let m = Eval.metrics(rows, now: evaluatedAt)
        XCTAssertEqual(m.excludedUnresolved, 2)
        XCTAssertEqual(m.scoredDays, 0)
        XCTAssertNil(m.auc)
        XCTAssertNil(m.baseRate)
    }

    // MARK: - Absent, not zero

    func testUndefinedQuantitiesAreNilNeverZero() {
        // Never flagged: "you have never been flagged" and "40 flags, none became a headache" are
        // opposite findings, so precision must not collapse them to 0.
        let neverFlagged = (0..<30).map {
            ScoredDay(day: day($0), computedAt: computedAt($0), index: 0, band: .typical,
                      headacheOnset: $0 < 5 ? computedAt($0).addingTimeInterval(3600) : nil)
        }
        let m1 = Eval.metrics(neverFlagged, now: now(after: 30))
        XCTAssertNil(m1.precision)
        XCTAssertNil(m1.lift)
        XCTAssertNil(m1.pValue)
        XCTAssertEqual(m1.recall!, 0, accuracy: 1e-12)   // measured: 0 of 5 caught

        // No headaches at all: AUC has nothing to rank, so it is absent — not 0.5.
        let noLabels = (0..<30).map {
            ScoredDay(day: day($0), computedAt: computedAt($0), index: $0,
                      band: $0 > 25 ? .flagged : .typical)
        }
        let m2 = Eval.metrics(noLabels, now: now(after: 30))
        XCTAssertNil(m2.auc)
        XCTAssertNil(m2.aucCILow)
        XCTAssertNil(m2.aucCIHigh)
        XCTAssertNil(m2.recall)
        XCTAssertNil(m2.pValue)
        XCTAssertEqual(m2.baseRate!, 0, accuracy: 1e-12)
        XCTAssertNil(m2.lift)                             // a base rate of 0 has no lift
        XCTAssertEqual(m2.precision!, 0, accuracy: 1e-12)
    }

    func testAlertsPerWeekCountsDeliveredAlertsNotBandedDays() {
        // 28 days, 8 banded `.flagged`, but only 4 alerts actually reached the user (the rest were
        // suppressed by fever / already-logged / the never-fire window).
        let rows = (0..<28).map { i in
            ScoredDay(day: day(i), computedAt: computedAt(i), index: 50,
                      band: i < 8 ? .flagged : .typical,
                      alerted: i < 4)
        }
        let m = Eval.metrics(rows, now: now(after: 28))
        XCTAssertEqual(m.flaggedDays, 8)
        XCTAssertEqual(m.alertsPerWeek!, 1.0, accuracy: 1e-12)   // 4 alerts over 28 days
    }

    /// An alert that fired on a night which later re-staged still woke the user up. The statistics
    /// drop that row; the INTERRUPTION RATE must not, because it is the one number a user can check
    /// against their own memory and an under-count would read as us hiding alerts.
    func testAlertsPerWeekCountsAlertsOnRowsExcludedFromTheStatistics() {
        let rows = (0..<28).map { i in
            ScoredDay(day: day(i), computedAt: computedAt(i), index: 50,
                      band: i < 4 ? .flagged : .typical,
                      sleepRestaged: i < 2,     // two of the four alerted days later re-staged
                      alerted: i < 4)
        }
        let m = Eval.metrics(rows, now: now(after: 28))
        XCTAssertEqual(m.excludedRestaged, 2)
        XCTAssertEqual(m.scoredDays, 26)
        XCTAssertEqual(m.flaggedDays, 2)                          // statistics see only the survivors
        XCTAssertEqual(m.alertsPerWeek!, 1.0, accuracy: 1e-12)    // but all 4 interruptions count
    }

    func testScopeSplitsPreAndPostUnlockRows() {
        let rows = (0..<40).map { i in
            ScoredDay(day: day(i), computedAt: computedAt(i), index: 50, band: .flagged,
                      headacheOnset: i >= 20 ? computedAt(i).addingTimeInterval(3600) : nil,
                      postUnlock: i >= 20)
        }
        let n = now(after: 40)
        XCTAssertEqual(Eval.metrics(rows, now: n, scope: .all).scoredDays, 40)
        XCTAssertEqual(Eval.metrics(rows, now: n, scope: .preUnlock).scoredDays, 20)
        XCTAssertEqual(Eval.metrics(rows, now: n, scope: .preUnlock).labelledDays, 0)
        XCTAssertEqual(Eval.metrics(rows, now: n, scope: .postUnlock).scoredDays, 20)
        XCTAssertEqual(Eval.metrics(rows, now: n, scope: .postUnlock).labelledDays, 20)
    }

    // MARK: - Building

    /// Below `minDaysForBanding` there is no percentile window, so no band, so nothing to notify
    /// about — WHATEVER the labels say. A perfect detector on 20 days is still `.building`.
    func testBuildingBelowMinDaysWhateverTheLabelsSay() {
        let tuning = Tuning()
        let n = tuning.minFrozenDaysForNotification - 1
        let perfect = (0..<n).map { i in
            ScoredDay(day: day(i), computedAt: computedAt(i), index: i < 5 ? 100 : 0,
                      band: i < 5 ? .flagged : .typical,
                      headacheOnset: i < 5 ? computedAt(i).addingTimeInterval(3600) : nil)
        }
        guard case let .building(remaining) = Eval.status(perfect, now: now(after: n)) else {
            return XCTFail("expected .building below the banding floor")
        }
        XCTAssertEqual(remaining, 1)

        // Restaged rows still COUNT toward the floor: they are excluded from the statistics but they
        // are real frozen indices sitting in the percentile window that makes a band exist.
        let withRestaged = perfect + [ScoredDay(day: day(n), computedAt: computedAt(n), index: 0,
                                                band: .typical, sleepRestaged: true)]
        if case .building = Eval.status(withRestaged, now: now(after: n + 1)) {
            XCTFail("a restaged row is still a frozen row for banding purposes")
        }
    }

    // MARK: - The negative control (the reason this file exists)

    /// A detector with NO SKILL — labels shuffled independently of the index — must not be judged
    /// `.working`, and must not be judged working across REPEATED looks either, since the UI may
    /// call `status(_:now:)` on every refresh.
    ///
    /// MEASURED, not asserted from theory: over 400 seeded trials of a synthetic year, each looked
    /// at every 28 days from day 120 (the `.working` floor) onward, the realised false-`working`
    /// rate is reported below and the bound is set with headroom above it. If a change to the bar
    /// pushes this over the bound, the monitor has started mistaking noise for skill and must not
    /// ship in that state.
    func testNoSkillIsNeverJudgedWorking() {
        var falseWorking = 0
        let trials = 400
        for seed in 0..<UInt64(trials) {
            var rng = SplitMix64(seed: 0xA11C_E000 &+ seed)
            let year = makeYear(dPrime: 0, rng: &rng)
            var everWorking = false
            for look in stride(from: 120, through: year.count, by: 28) {
                if case .working = Eval.status(Array(year.prefix(look)), now: now(after: look)) {
                    everWorking = true
                    break
                }
            }
            if everWorking { falseWorking += 1 }
        }
        let rate = Double(falseWorking) / Double(trials)
        // MEASURED 2026-07-31 on this generator: 0 of 400 trials, across all 9 looks each. The
        // bound below carries deliberate headroom over that; it is a regression fence, not a target.
        XCTAssertLessThanOrEqual(rate, 0.02,
                                 "noise is being read as skill (\(falseWorking)/\(trials))")
    }

    /// The error that actually costs a user something: retiring a detector that DOES work for them.
    ///
    /// MEASURED 2026-07-31, re-examining each simulated year every 28 days from day 180 onward:
    ///   AUC ≈ 0.59 (a weak but real detector) → retired in 4.0 % of simulated years (8/200)
    ///   AUC ≈ 0.65 (§1's realistic centre)    → retired in 0.5 % (1/200)
    /// So the retirement rule essentially never fires on a detector with real skill, and the weak
    /// case — where it could plausibly do harm — is the one asserted here.
    func testARealDetectorIsAlmostNeverRetired() {
        for (dPrime, bound) in [(0.35, 0.06), (0.55, 0.03)] {
            var retired = 0
            let trials = 200
            for seed in 0..<UInt64(trials) {
                var rng = SplitMix64(seed: 0xBEEF_0000 &+ seed &+ UInt64(dPrime * 100) &* 104_729)
                let year = makeYear(dPrime: dPrime, rng: &rng)
                var everRetired = false
                for look in stride(from: 180, through: year.count, by: 28) {
                    if case .retired = Eval.status(Array(year.prefix(look)), now: now(after: look)) {
                        everRetired = true
                        break
                    }
                }
                if everRetired { retired += 1 }
            }
            XCTAssertLessThanOrEqual(Double(retired) / Double(trials), bound,
                                     "d'=\(dPrime): a real detector is being retired "
                                     + "(\(retired)/\(trials))")
        }
    }

    /// Characterisation, not a bound: a detector sitting exactly at chance IS eventually switched
    /// off for some users, and that is the rule doing its job — those users have an alert that tells
    /// them nothing. But `.monitoring` must remain the MAJORITY outcome, because the copy written
    /// for it is what most users will read for most of the feature's life.
    ///
    /// MEASURED 2026-07-31 at d' = 0 over one simulated year: retired for 15.5 % of users (31/200)
    /// at a single terminal look, 25 % (50/200) across the every-28-day look schedule,
    /// `.monitoring` for the rest.
    ///
    /// The gap between 15.5 % and 25 % is MULTIPLICITY and it is a real residual: `status(_:now:)`
    /// is stateless, so looking more often finds more bad-luck runs. Bounded, not solved. THE APP
    /// MUST NOT ACT ON A SINGLE RETIREMENT RECOMMENDATION — see `shouldRetire`'s caller contract on
    /// requiring it to persist across consecutive decision points.
    func testChanceLevelDetectorIsEventuallyRetiredButMonitoringDominates() {
        var retired = 0, monitoring = 0
        let trials = 200
        for seed in 0..<UInt64(trials) {
            var rng = SplitMix64(seed: 0xC0DE_0000 &+ seed)
            let year = makeYear(dPrime: 0, rng: &rng)
            switch Eval.status(year, now: now(after: year.count)) {
            case .retired: retired += 1
            case .monitoring: monitoring += 1
            case .working: XCTFail("chance read as working")
            case .building: XCTFail("a full year should be past the banding floor")
            }
        }
        XCTAssertGreaterThan(retired, 0, "a useless alert is never switched off")
        XCTAssertGreaterThan(monitoring, trials / 2, ".monitoring must stay the majority outcome")
    }

    /// `.monitoring` is the DEFAULT and is not a failure state. Most users live here.
    func testMonitoringIsTheDefaultForAChanceDetector() {
        var rng = SplitMix64(seed: 0x5EED_1234)
        let year = makeYear(dPrime: 0, rng: &rng)
        guard case let .monitoring(m) = Eval.status(year, now: now(after: year.count)) else {
            return XCTFail("a chance-level year should read as .monitoring, not a verdict")
        }
        XCTAssertEqual(m.scoredDays, 360)
        XCTAssertEqual(m.labelledDays, 48)
        XCTAssertEqual(m.flaggedDays, 36)
        XCTAssertNotNil(m.auc)
    }

    // MARK: - The positive controls (the bar must not be merely impossible)

    func testRealSkillReachesWorking() {
        var working = 0
        let trials = 100
        for seed in 0..<UInt64(trials) {
            var rng = SplitMix64(seed: 0x600D_0000 &+ seed)
            // d' = 1.40 ⇒ AUC ≈ 0.84, a strong personal detector. Deliberately well above §1's
            // realistic 0.65 centre: a bar that only a strong detector clears is the point.
            let year = makeYear(dPrime: 1.40, rng: &rng)
            if case .working = Eval.status(year, now: now(after: year.count)) { working += 1 }
        }
        // MEASURED 2026-07-31: 100 of 100.
        XCTAssertGreaterThanOrEqual(Double(working) / Double(trials), 0.90,
                                    "a genuinely strong detector cannot reach .working (\(working)/\(trials))")
    }

    func testAntiPredictiveDetectorIsRetired() {
        var retired = 0, viaAUC = 0
        let trials = 100
        for seed in 0..<UInt64(trials) {
            var rng = SplitMix64(seed: 0xDEAD_0000 &+ seed)
            // d' = −0.75 ⇒ AUC ≈ 0.30: the index ranks this user's headache days BELOW their
            // ordinary ones. Being flagged is actively misleading for them.
            let year = makeYear(dPrime: -0.75, rng: &rng)
            if case let .retired(_, reason) = Eval.status(year, now: now(after: year.count)) {
                retired += 1
                if reason == .noBetterThanChance { viaAUC += 1 }
            }
        }
        // MEASURED 2026-07-31: retired in 98 of 100, and the AUC test is what catches 95 of those
        // 98. The handful attributed to `.noUsefulPrecisionGain` are tail draws whose realised AUC
        // interval crept above chance while their flagged days still caught nothing — a legitimate
        // retirement by the other route, so the reason is asserted as a MAJORITY rather than an
        // invariant.
        XCTAssertGreaterThanOrEqual(Double(retired) / Double(trials), 0.90,
                                    "an anti-predictive detector keeps notifying (\(retired)/\(trials))")
        XCTAssertGreaterThan(viaAUC, retired * 3 / 4,
                             "the AUC test should be what catches an inverted detector")
    }

    // MARK: - The minimum evidence bar

    /// The bar is the whole reason retirement is safe. Hanley-McNeil's standard error COLLAPSES TO
    /// ZERO at AUC 0 or 1, so a handful of positives that all happen to score low produce the
    /// interval [0, 0] and would "prove" the detector is worse than chance on a fortnight of data.
    func testRetirementRequiresTheMinimumEvidenceBar() {
        // 30 days, 3 positives, 5 flagged. Every positive scores below every negative, so AUC is
        // exactly 0 and Hanley-McNeil hands back the degenerate zero-width interval [0, 0].
        let rows = (0..<30).map { i -> ScoredDay in
            let positive = i < 3
            let flagged = (3..<8).contains(i)
            return ScoredDay(day: day(i), computedAt: computedAt(i),
                             index: positive ? 0 : 50,
                             band: flagged ? .flagged : .typical,
                             headacheOnset: positive ? computedAt(i).addingTimeInterval(3600) : nil)
        }
        let m = Eval.metrics(rows, now: now(after: 30))
        XCTAssertEqual(m.auc!, 0, accuracy: 1e-12)
        XCTAssertEqual(m.aucCIHigh!, 0, accuracy: 1e-12)   // the degenerate interval, unguarded
        XCTAssertEqual(m.flaggedDays, 5)
        XCTAssertNil(Eval.shouldRetire(m), "retired on 30 days and 3 headaches")

        // Each leg of the bar vetoes on its own — a bar is only a bar if every term can block.
        var tuning = Tuning()
        tuning.minScoredDaysForRetirement = 30
        XCTAssertNil(Eval.shouldRetire(m, tuning: tuning), "positives floor should still block")
        tuning.minPositivesForRetirement = 3
        XCTAssertNil(Eval.shouldRetire(m, tuning: tuning), "flagged floor should still block")
        tuning.minFlaggedForRetirement = 5
        XCTAssertEqual(Eval.shouldRetire(m, tuning: tuning), .noBetterThanChance,
                       "with every floor lowered the same data does retire — so the bar, not the "
                       + "statistic, is what protects the user here")
    }

    /// A detector sitting exactly at chance is retired only once enough flagged days accumulate to
    /// BOUND the benefit below `minUsefulPrecisionGain`. This is an equivalence test, and it is
    /// deliberately NOT "the interval overlaps the base rate" — overlapping is the definition of
    /// `.monitoring`, so that rule would retire almost every user by construction.
    func testChanceDetectorRetiresOnlyOnceTheBenefitIsBounded() {
        /// A detector sitting on chance in BOTH senses, constructed exactly rather than sampled:
        /// every index is identical (so AUC is exactly 0.5 by the tie rule), 10 % of days are
        /// flagged, and the headaches are placed so that `truePositives / flagged` equals
        /// `positives / total` to the day. There is nothing to find in this data and the monitor
        /// must not pretend otherwise in either direction.
        func chanceSeries(days count: Int) -> [ScoredDay] {
            let flaggedIdx = (0..<count).filter { $0 % 10 == 0 }
            let unflaggedIdx = (0..<count).filter { $0 % 10 != 0 }
            let positives = count / 15
            let truePositives = (flaggedIdx.count * positives) / count
            var positiveSet = Set(flaggedIdx.prefix(truePositives))
            positiveSet.formUnion(unflaggedIdx.prefix(positives - truePositives))
            return (0..<count).map { i in
                ScoredDay(day: day(i), computedAt: computedAt(i),
                          index: 40,
                          band: i % 10 == 0 ? .flagged : .typical,
                          headacheOnset: positiveSet.contains(i)
                            ? computedAt(i).addingTimeInterval(3600) : nil)
            }
        }
        var tuning = Tuning()
        tuning.evaluationWindowDays = 4000

        // One year. Precision and base rate agree, but 36 flagged days cannot BOUND the benefit —
        // the interval still admits a gain worth interrupting for, so the honest answer is "we
        // cannot tell yet", not "it failed".
        let oneYear = Eval.metrics(chanceSeries(days: 360), now: now(after: 360), tuning: tuning)
        XCTAssertEqual(oneYear.auc!, 0.5, accuracy: 1e-12)
        XCTAssertNil(Eval.shouldRetire(oneYear, tuning: tuning))

        // Several years. The AUC interval still straddles chance — an equivalence question is not
        // answerable by a two-sided interval around 0.5 — but the precision bound has tightened
        // under the margin, so the alert retires itself for the right reason.
        let long = Eval.metrics(chanceSeries(days: 1800), now: now(after: 1800), tuning: tuning)
        XCTAssertGreaterThan(long.aucCIHigh!, 0.5)
        XCTAssertEqual(Eval.shouldRetire(long, tuning: tuning), .noUsefulPrecisionGain)
    }

    /// Every leg of the `.working` conjunction blocks on its own — a bar is only a bar if each term
    /// can veto.
    func testEachWorkingCriterionAloneBlocks() {
        var rng = SplitMix64(seed: 0x1234_5678)
        let year = makeYear(dPrime: 1.40, rng: &rng)
        let n = now(after: year.count)
        let m = Eval.metrics(year, now: n)
        XCTAssertTrue(Eval.meetsWorkingBar(m))

        var scoredDaysBar = Tuning(); scoredDaysBar.minScoredDaysForWorking = 100_000
        XCTAssertFalse(Eval.meetsWorkingBar(m, tuning: scoredDaysBar))

        var positivesBar = Tuning(); positivesBar.minPositivesForWorking = 10_000
        XCTAssertFalse(Eval.meetsWorkingBar(m, tuning: positivesBar))

        var alphaBar = Tuning(); alphaBar.workingAlpha = 0
        XCTAssertFalse(Eval.meetsWorkingBar(m, tuning: alphaBar))

        var ciBar = Tuning(); ciBar.chanceAUC = 0.999
        XCTAssertFalse(Eval.meetsWorkingBar(m, tuning: ciBar))
    }

    /// The gate reads the CI LOWER BOUND, not the point estimate. The plan's worked counter-example:
    /// an AUC of 0.62 whose interval still contains chance must not be called working.
    func testWorkingUsesTheCILowerBoundNotThePointEstimate() {
        // The plan's worked counter-example (§5.3): an AUC point estimate ABOVE chance whose
        // interval still contains chance must not be called working. Gating on the point estimate
        // would let roughly one user in eight with a worthless detector be told it works.
        //
        // d' = 0.55 ⇒ AUC ≈ 0.65, §1's realistic centre. Over one year the interval still straddles
        // chance for many users — which is exactly why §1.1 concludes a typical user needs about a
        // year to reach α = 0.01, and why `.monitoring` has to be a comfortable place to live.
        var straddled = 0
        for seed in 0..<UInt64(50) {
            var r = SplitMix64(seed: 0x7777_0000 &+ seed)
            let m = Eval.metrics(makeYear(dPrime: 0.55, rng: &r), now: now(after: 360))
            guard let a = m.auc, let low = m.aucCILow, a > 0.5, low <= 0.5 else { continue }
            straddled += 1
            XCTAssertFalse(Eval.meetsWorkingBar(m),
                           "AUC \(a) with a lower bound of \(low) was called working")
        }
        XCTAssertGreaterThan(straddled, 0,
                             "no trial produced an above-chance point estimate with a straddling "
                             + "interval, so this test proves nothing")
    }

    // MARK: - Determinism

    func testMetricsAreDeterministic() {
        var rng = SplitMix64(seed: 0xFACE_0001)
        let year = makeYear(dPrime: 0.55, restagedEvery: 17, rng: &rng)
        let n = now(after: year.count)
        let first = Eval.metrics(year, now: n)
        for _ in 0..<5 { XCTAssertEqual(Eval.metrics(year, now: n), first) }
        // Row order must not move a single number: the statistics are a property of the SET.
        var shuffled = year
        var shuffleRNG = SplitMix64(seed: 0xFACE_0002)
        shuffled.shuffle(using: &shuffleRNG)
        XCTAssertEqual(Eval.metrics(shuffled, now: n), first)
    }
}

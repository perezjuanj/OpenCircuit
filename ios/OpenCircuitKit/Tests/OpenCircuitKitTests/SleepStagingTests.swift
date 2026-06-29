import XCTest
@testable import OpenCircuitKit

// SYNTHETIC-ONLY tests for the sleep-stage classifier. We have no per-epoch ground
// truth (the ring sends no hypnogram, §5.3), so these build controlled epoch
// sequences with a known intended stage and assert the classifier recovers it, plus
// one "constructed night" that checks the stage totals partition the night the way
// the RingConn app's night totals do (light ≫ rem > deep, modest awake).
final class SleepStagingTests: XCTestCase {

    // MARK: - Record builders

    /// A sleep-vitals epoch (sub 0x62) with explicit HR/HRV and a uniform motion byte.
    private func vrec(_ counter: UInt32, hr: UInt8, hrv: UInt8 = 0, motion: UInt8 = 1) -> BulkRecord {
        var b = [UInt8](repeating: 0, count: 23)
        b[0] = UInt8(counter >> 24); b[1] = UInt8((counter >> 16) & 0xFF)
        b[2] = UInt8((counter >> 8) & 0xFF); b[3] = UInt8(counter & 0xFF)
        b[4] = hr; b[5] = hrv; b[8] = 0x62
        for k in 0..<5 { b[10 + k] = motion }
        return BulkRecord(b)!
    }

    /// A sleep-vitals epoch that ALSO sets the respiratory-rate byte `[7] = rr*8`, so
    /// `BulkRecord.respiratoryRate` (raw[7]/8) decodes. The plain `vrec` leaves `[7] = 0`
    /// (RR = nil); this variant is for the RR-fusion tests. `rr` must be ≤ 31 (rr*8 ≤ 248).
    private func vrecRR(_ counter: UInt32, hr: UInt8, hrv: UInt8 = 0, motion: UInt8 = 1,
                        rr: Double) -> BulkRecord {
        var b = [UInt8](repeating: 0, count: 23)
        b[0] = UInt8(counter >> 24); b[1] = UInt8((counter >> 16) & 0xFF)
        b[2] = UInt8((counter >> 8) & 0xFF); b[3] = UInt8(counter & 0xFF)
        b[4] = hr; b[5] = hrv; b[7] = UInt8((rr * 8).rounded()); b[8] = 0x62
        for k in 0..<5 { b[10 + k] = motion }
        return BulkRecord(b)!
    }

    /// An active/awake epoch (sub 0x12, high motion, no vitals).
    private func arec(_ counter: UInt32, motion: UInt8 = 0x14) -> BulkRecord {
        var b = [UInt8](repeating: 0, count: 23)
        b[0] = UInt8(counter >> 24); b[1] = UInt8((counter >> 16) & 0xFF)
        b[2] = UInt8((counter >> 8) & 0xFF); b[3] = UInt8(counter & 0xFF)
        b[8] = 0x12
        for k in 0..<5 { b[10 + k] = motion }
        return BulkRecord(b)!
    }

    private let step: UInt32 = 150

    /// Fraction of asleep (non-inBed, non-awake) time spent in `stage`.
    private func fraction(_ segs: [SleepSegment], _ stage: SleepStage) -> Double {
        let totals = SleepStaging.stageTotals(segs)
        let asleep = (totals[.asleepCore] ?? 0) + (totals[.asleepDeep] ?? 0) + (totals[.asleepREM] ?? 0)
        guard asleep > 0 else { return 0 }
        return (totals[stage] ?? 0) / asleep
    }

    // MARK: - Single-stage recovery

    func testStillFlatLowHRIsMostlyDeep() {
        // A calm night: flat low HR, no motion -> should read as predominantly Deep.
        var recs: [BulkRecord] = []
        var c: UInt32 = 0x0c220000
        for _ in 0..<12 { recs.append(arec(c)); c += step }
        for _ in 0..<120 { recs.append(vrec(c, hr: 50)); c += step }   // flat, still, low
        for _ in 0..<12 { recs.append(arec(c)); c += step }

        let segs = SleepStaging.classify(from: recs)
        XCTAssertFalse(segs.isEmpty)
        XCTAssertGreaterThan(fraction(segs, .asleepDeep), 0.8, "calm flat low HR -> mostly Deep")
        XCTAssertEqual(fraction(segs, .asleepREM), 0.0, "no variability/elevation -> no REM")
    }

    func testElevatedFlatHRLowMotionIsREM() {
        // Deep baseline + a clearly elevated, still block -> elevated block is REM.
        var recs: [BulkRecord] = []
        var c: UInt32 = 0x0c220000
        for _ in 0..<12 { recs.append(arec(c)); c += step }
        for _ in 0..<100 { recs.append(vrec(c, hr: 50)); c += step }          // Deep baseline
        let remStart = c
        for _ in 0..<40 { recs.append(vrec(c, hr: 66)); c += step }           // elevated, still
        let remEnd = c
        for _ in 0..<12 { recs.append(arec(c)); c += step }

        let segs = SleepStaging.classify(from: recs)
        XCTAssertGreaterThan(fraction(segs, .asleepREM), 0.2, "elevated still block -> REM present")
        // The bulk of REM should sit in the elevated window (a couple boundary epochs
        // may bleed in due to transition variability — tolerate ±2 epochs).
        let lo = Date(timeIntervalSince1970: Double(Int(remStart) + Command.syncEpoch))
            .addingTimeInterval(-2 * Double(step))
        let hi = Date(timeIntervalSince1970: Double(Int(remEnd) + Command.syncEpoch))
            .addingTimeInterval(2 * Double(step))
        let remSegs = segs.filter { $0.stage == .asleepREM }
        let remTotal = remSegs.reduce(0.0) { $0 + $1.duration }
        let remInWindow = remSegs.filter { $0.start >= lo && $0.end <= hi }.reduce(0.0) { $0 + $1.duration }
        XCTAssertGreaterThan(remTotal, 0)
        XCTAssertGreaterThanOrEqual(remInWindow / remTotal, 0.8, "REM concentrates in the elevated window")
    }

    func testVariabilitySeparatesREMFromLightAtSameMeanHR() {
        // Two still blocks with the SAME mean HR (58): one flat, one oscillating.
        // Variability — not absolute HR — must put the oscillating one in REM.
        var recs: [BulkRecord] = []
        var c: UInt32 = 0x0c220000
        for _ in 0..<12 { recs.append(arec(c)); c += step }
        let flatStart = c
        for _ in 0..<100 { recs.append(vrec(c, hr: 55)); c += step }          // flat
        let varStart = c
        // 2-epoch steps so runs survive smoothing; mean 55, swings ±10.
        for k in 0..<40 { recs.append(vrec(c, hr: (k / 2) % 2 == 0 ? 45 : 65)); c += step }
        for _ in 0..<12 { recs.append(arec(c)); c += step }

        let segs = SleepStaging.classify(from: recs)
        let varLo = Date(timeIntervalSince1970: Double(Int(varStart) + Command.syncEpoch))
        let flatLo = Date(timeIntervalSince1970: Double(Int(flatStart) + Command.syncEpoch))
        let remInVar = segs.filter { $0.stage == .asleepREM && $0.start >= varLo }
            .reduce(0.0) { $0 + $1.duration }
        let remInFlat = segs.filter { $0.stage == .asleepREM && $0.start >= flatLo && $0.start < varLo }
            .reduce(0.0) { $0 + $1.duration }
        XCTAssertGreaterThan(remInVar, 0, "variable block reads as REM")
        XCTAssertGreaterThan(remInVar, remInFlat, "REM concentrates in the variable block, not the flat one")
    }

    func testHighMotionMidSleepIsAwake() {
        // A burst of motion inside the night must surface as an Awake segment.
        var recs: [BulkRecord] = []
        var c: UInt32 = 0x0c220000
        for _ in 0..<12 { recs.append(arec(c)); c += step }
        for _ in 0..<60 { recs.append(vrec(c, hr: 52)); c += step }
        let wakeStart = c
        for _ in 0..<3 { recs.append(arec(c, motion: 0x16)); c += step }     // mid-sleep movement
        for _ in 0..<60 { recs.append(vrec(c, hr: 52)); c += step }
        for _ in 0..<12 { recs.append(arec(c)); c += step }

        let segs = SleepStaging.classify(from: recs)
        let awake = segs.filter { $0.stage == .awake }
        XCTAssertFalse(awake.isEmpty, "mid-sleep motion -> Awake segment")
        let wt = Date(timeIntervalSince1970: Double(Int(wakeStart) + Command.syncEpoch))
        XCTAssertTrue(awake.contains { abs($0.start.timeIntervalSince(wt)) < Double(step) * 4 },
                      "awake segment aligns with the motion burst")
        // Awake stays inside the inBed window.
        let inBed = segs.first { $0.stage == .inBed }!
        for a in awake {
            XCTAssertGreaterThanOrEqual(a.start, inBed.start)
            XCTAssertLessThanOrEqual(a.end, inBed.end)
        }
    }

    // MARK: - SpO2 + respiratory-rate fusion (additive; default-inert)

    /// The new `rrVarWeight` knob defaults to 0, so the classifier output for ANY night —
    /// even one carrying respiratory-rate readings — must be byte-identical with the default
    /// tuning vs. an explicit `Tuning(rrVarWeight: 0)`. This is the safety property that
    /// guarantees the RR feature regresses nothing until it is deliberately fit.
    func testRrVarWeightZeroIsNoOp() {
        // Build a night WITHOUT RR (vrec, raw[7]=0) and the IDENTICAL night WITH RR injected
        // (vrecRR) — same HR/HRV/motion/SpO2. At the default tuning (rrVarWeight 0) RR carriage
        // must not change a SINGLE segment. This proves the feature is genuinely inert (the RR
        // values flow through the rows but never reach a decision), not merely that 0 == 0.
        func night(rr: Bool) -> [BulkRecord] {
            var recs: [BulkRecord] = []
            var c: UInt32 = 0x0c220000
            for _ in 0..<12 { recs.append(arec(c)); c += step }
            for k in 0..<140 {
                let hr: UInt8 = k % 3 == 0 ? 52 : 58
                recs.append(rr ? vrecRR(c, hr: hr, hrv: 55, rr: k % 2 == 0 ? 13 : 18)
                               : vrec(c, hr: hr, hrv: 55))
                c += step
            }
            for _ in 0..<12 { recs.append(arec(c)); c += step }
            return recs
        }
        let withoutRR = SleepStaging.classify(from: night(rr: false))
        let withRR = SleepStaging.classify(from: night(rr: true))
        XCTAssertFalse(withRR.isEmpty)
        XCTAssertEqual(withoutRR, withRR,
                       "RR carriage is inert at the default rrVarWeight (0): output is byte-identical with vs without RR")
        // And an explicit Tuning(rrVarWeight: 0) matches the default.
        XCTAssertEqual(withRR, SleepStaging.classify(from: night(rr: true),
                                                     tuning: SleepStaging.Tuning(rrVarWeight: 0)))
    }

    /// Respiratory-rate variability is a REM cue, mirroring the HRV term. A flat-HR /
    /// flat-HRV block whose ONLY variable signal is respiratory rate must NOT read as REM
    /// at the default (rrVarWeight = 0), but SHOULD gain REM once rrVarWeight is raised.
    /// This proves RR is genuinely fused into the variability score (not merely carried).
    func testRrVariabilityAddsREMCue() {
        // deepHR (p42) < target HR (54) < remHR (p86), so the target is neither Deep- nor
        // REM-by-HR; the only thing that can push it to REM is its RR variability.
        var recs: [BulkRecord] = []
        var c: UInt32 = 0x0c220000
        for _ in 0..<12 { recs.append(arec(c)); c += step }                              // onset (awake)
        for _ in 0..<120 { recs.append(vrecRR(c, hr: 50, hrv: 50, rr: 15)); c += step }  // low, flat (Deep)
        let tStart = c
        for k in 0..<16 {                                                                // FLAT HR/HRV, OSC RR
            recs.append(vrecRR(c, hr: 54, hrv: 50, rr: k % 2 == 0 ? 10 : 22)); c += step
        }
        let tEnd = c
        for _ in 0..<80 { recs.append(vrecRR(c, hr: 58, hrv: 50, rr: 15)); c += step }   // high, flat (light/REM-by-HR)
        for _ in 0..<12 { recs.append(arec(c)); c += step }                              // offset (awake)

        let lo = Date(timeIntervalSince1970: Double(Int(tStart) + Command.syncEpoch))
        let hi = Date(timeIntervalSince1970: Double(Int(tEnd) + Command.syncEpoch))
        func remInTarget(_ w: Double) -> Double {
            let segs = SleepStaging.classify(from: recs,
                                             tuning: SleepStaging.Tuning(rrVarWeight: w))
            return segs.filter { $0.stage == .asleepREM }.reduce(0.0) { acc, s in
                acc + max(0, min(s.end, hi).timeIntervalSince(max(s.start, lo)))
            }
        }

        let remOff = remInTarget(0)
        let remOn = remInTarget(1.0)
        XCTAssertEqual(remOff, 0, accuracy: 0.001,
                       "with rrVarWeight:0 the flat-HR/flat-HRV block carries no REM")
        XCTAssertGreaterThan(remOn, 0,
                             "raising rrVarWeight turns the RR-variable block into REM")
        XCTAssertGreaterThan(remOn, remOff, "RR variability adds a REM cue the HR-only model misses")
    }

    // MARK: - HR-aware onset/offset ("still but awake") — the screenshot fix

    /// A long, STILL block of elevated HR before real sleep (e.g. lying in bed awake)
    /// must NOT be counted as ASLEEP — but it IS time in bed, so under RingConn's
    /// two-window model it is kept as AWAKE-IN-BED, not trimmed out of the in-bed window.
    /// inBed spans the full bedtime window (pre-sleep included), the core stays the only
    /// asleep time, and efficiency = asleep / time-in-bed drops below 1.0. This is the
    /// case motion alone misses (no movement → "still" → falsely asleep).
    func testStillButElevatedHRPreSleepCountedAsAwakeInBedNotTrimmed() {
        var recs: [BulkRecord] = []
        var c: UInt32 = 0x0c220000
        let preStart = c
        let preEpochs = 40
        for _ in 0..<preEpochs { recs.append(vrec(c, hr: 78)); c += step }   // still but AWAKE (high HR)
        let onset = c
        for _ in 0..<120 { recs.append(vrec(c, hr: 54)); c += step }          // real sleep core
        for _ in 0..<8 { recs.append(arec(c)); c += step }                    // morning (motion-active)

        let segs = SleepStaging.classify(from: recs)
        XCTAssertFalse(segs.isEmpty)
        let inBed = segs.first { $0.stage == .inBed }!
        let preStartDate = Date(timeIntervalSince1970: Double(Int(preStart) + Command.syncEpoch))
        let onsetDate = Date(timeIntervalSince1970: Double(Int(onset) + Command.syncEpoch))
        // (a) in-bed spans the FULL bedtime window: it starts at the FIRST epoch (pre-sleep
        // included), NOT the trimmed onset.
        XCTAssertEqual(inBed.start.timeIntervalSince(preStartDate), 0, accuracy: Double(step) * 2,
                       "in-bed spans the full bedtime window, pre-sleep included")
        // (b) the key invariant: the pre-sleep block is STILL not asleep — asleep ≈ the core.
        let s = SleepStaging.summary(segs)
        let coreMin = Double(120 * Int(step)) / 60
        XCTAssertEqual(Double(s.minutes.asleep), coreMin, accuracy: 30,
                       "asleep reflects the real core, not the pre-sleep wake")
        // (c) the pre-sleep span surfaces as AWAKE-IN-BED (not dropped): an awake segment
        // starts at the first epoch and runs up to onset.
        let awakeSegs = segs.filter { $0.stage == .awake }
        XCTAssertTrue(awakeSegs.contains {
            abs($0.start.timeIntervalSince(preStartDate)) < Double(step) * 2 &&
            $0.end <= onsetDate.addingTimeInterval(Double(step) * 2)
        }, "pre-sleep wake-in-bed is an awake segment, not trimmed away")
        // (d) efficiency is now < 1 (it was 1.0 when pre-sleep was trimmed out of in-bed).
        XCTAssertLessThan(s.efficiency, 1.0, "in-bed wake pulls efficiency below 100%")
        // Partition holds: in-bed == asleep + awake.
        XCTAssertEqual(s.inBed, s.totalAsleep + s.awake, accuracy: Double(step))
    }

    /// Two-window model end to end: still-but-awake time in bed BEFORE onset and AFTER
    /// final wake, bracketing a sleep core. All three are time-IN-BED; only the core is
    /// asleep, so efficiency = asleep / time-in-bed lands in a plausible 0.6–0.8 band and
    /// in-bed partitions exactly into asleep + awake (pre + post wake both counted).
    func testStillAwakePrePostSleepGivesPlausibleEfficiency() {
        var recs: [BulkRecord] = []
        var c: UInt32 = 0x0c220000
        for _ in 0..<8 { recs.append(arec(c)); c += step }                    // up, before bed (outside block)
        let bedStart = c
        for _ in 0..<30 { recs.append(vrec(c, hr: 78)); c += step }           // in bed, awake, still
        for _ in 0..<120 { recs.append(vrec(c, hr: 54)); c += step }          // asleep core
        for _ in 0..<30 { recs.append(vrec(c, hr: 78)); c += step }           // awake in bed, still
        let bedEnd = c
        for _ in 0..<8 { recs.append(arec(c)); c += step }                    // got up (outside block)

        let segs = SleepStaging.classify(from: recs)
        XCTAssertFalse(segs.isEmpty)
        let s = SleepStaging.summary(segs)

        // Only the 120-epoch core counts as asleep; the 60 still-but-awake epochs do not.
        let coreMin = Double(120 * Int(step)) / 60
        XCTAssertEqual(Double(s.minutes.asleep), coreMin, accuracy: 30,
                       "only the core counts as asleep, not the still-but-awake tails")
        // efficiency = asleep / time-in-bed ≈ 120 / 180 = 0.67.
        XCTAssertGreaterThan(s.efficiency, 0.6, "efficiency includes in-bed wake → < 1")
        XCTAssertLessThan(s.efficiency, 0.8, "two awake tails pull efficiency down to ~0.67")
        // In-bed partitions exactly into asleep + awake.
        XCTAssertEqual(s.inBed, s.totalAsleep + s.awake, accuracy: Double(step))
        // In-bed spans the full bedtime window (both still-awake tails).
        let inBed = segs.first { $0.stage == .inBed }!
        let bedStartDate = Date(timeIntervalSince1970: Double(Int(bedStart) + Command.syncEpoch))
        let bedEndDate = Date(timeIntervalSince1970: Double(Int(bedEnd) + Command.syncEpoch))
        XCTAssertEqual(inBed.start.timeIntervalSince(bedStartDate), 0, accuracy: Double(step) * 2,
                       "in-bed starts at bedtime, not onset")
        XCTAssertEqual(inBed.end.timeIntervalSince(bedEndDate), 0, accuracy: Double(step) * 2,
                       "in-bed ends at final get-up, not last-asleep")
        // Both a pre-sleep and a post-wake awake-in-bed segment exist.
        XCTAssertGreaterThanOrEqual(segs.filter { $0.stage == .awake }.count, 2,
                                    "pre- and post-sleep wake-in-bed both present")
    }

    /// A sustained HR elevation in the MIDDLE of sleep with NO motion (lying still, eyes
    /// open) must surface as Awake. Pure-motion staging misses this — it's why a real
    /// ~1-hour morning wake was reported as ~10 min.
    func testInteriorSustainedHRWakeWithoutMotionIsAwake() {
        var recs: [BulkRecord] = []
        var c: UInt32 = 0x0c220000
        for _ in 0..<12 { recs.append(arec(c)); c += step }
        for _ in 0..<60 { recs.append(vrec(c, hr: 54)); c += step }
        let wakeStart = c
        for _ in 0..<10 { recs.append(vrec(c, hr: 80)); c += step }           // still but AWAKE, 25 min
        for _ in 0..<60 { recs.append(vrec(c, hr: 54)); c += step }
        for _ in 0..<12 { recs.append(arec(c)); c += step }

        let segs = SleepStaging.classify(from: recs)
        let awake = segs.filter { $0.stage == .awake }
        XCTAssertFalse(awake.isEmpty, "sustained mid-sleep HR elevation -> Awake, even with no motion")
        let wt = Date(timeIntervalSince1970: Double(Int(wakeStart) + Command.syncEpoch))
        XCTAssertTrue(awake.contains { abs($0.start.timeIntervalSince(wt)) < Double(step) * 4 },
                      "awake segment aligns with the HR elevation")
        // It stays interior (sleep resumes after), so onset is before and offset after it.
        let inBed = segs.first { $0.stage == .inBed }!
        for a in awake { XCTAssertLessThan(a.end, inBed.end) }
    }

    // MARK: - Descent-relative onset trim (the "mild wind-down" fix)

    /// The case the FIXED `wakeHRMarginBPM` gate misses: HR drifting DOWN through a calm,
    /// still wind-down that never rises a full 18 bpm above the floor (e.g. 62 → 56 → 50).
    /// The old gate counted that whole stretch as asleep (efficiency pinned at ~100%); the
    /// descent-relative onset must mark it AWAKE-IN-BED instead, so asleep ≈ the real core
    /// and efficiency drops below 1. A control run with the trim disabled (huge
    /// `onsetMinDescentBPM`) shows the wind-down WOULD otherwise read as asleep.
    func testMildWindDownBelowFixedMarginIsTrimmedAsAwakeInBed() {
        var recs: [BulkRecord] = []
        var c: UInt32 = 0x0c220000
        for _ in 0..<8 { recs.append(arec(c)); c += step }                   // before bed (outside block)
        let onset = { () -> UInt32 in
            for _ in 0..<12 { recs.append(vrec(c, hr: 62)); c += step }       // wind-down, still, < floor+18
            for _ in 0..<4  { recs.append(vrec(c, hr: 56)); c += step }       // settling
            let o = c
            for _ in 0..<120 { recs.append(vrec(c, hr: 50)); c += step }      // asleep core
            return o
        }()
        for _ in 0..<8 { recs.append(arec(c)); c += step }                   // morning (outside block)

        let segs = SleepStaging.classify(from: recs)
        let s = SleepStaging.summary(segs)
        // (a) asleep reflects the 120-epoch core, NOT the 16-epoch wind-down too.
        let coreMin = Double(120 * Int(step)) / 60
        XCTAssertEqual(Double(s.minutes.asleep), coreMin, accuracy: 30,
                       "mild wind-down is not counted as asleep")
        // (b) efficiency is now < 1 (the wind-down is awake-in-bed, not asleep).
        XCTAssertLessThan(s.efficiency, 0.95, "wind-down pulls efficiency below 100%")
        // (c) an awake-in-bed segment covers the pre-onset wind-down.
        let onsetDate = Date(timeIntervalSince1970: Double(Int(onset) + Command.syncEpoch))
        XCTAssertTrue(segs.contains { $0.stage == .awake && $0.end <= onsetDate.addingTimeInterval(Double(step) * 2) },
                      "the wind-down surfaces as awake-in-bed, ending at onset")
        // Control: with the descent gate disabled, the SAME wind-down reads as asleep (eff ~1).
        let disabled = SleepStaging.classify(from: recs, tuning: SleepStaging.Tuning(onsetMinDescentBPM: 999))
        let sd = SleepStaging.summary(disabled)
        XCTAssertGreaterThan(sd.minutes.asleep, s.minutes.asleep,
                             "disabling the trim counts the wind-down as asleep (the old behavior)")
        XCTAssertGreaterThan(sd.efficiency, s.efficiency)
    }

    /// SAFETY 1 — descent gate. A night with NO real wind-down (flat HR from lights-out) must be
    /// BYTE-IDENTICAL with the trim on vs off: there is nothing to trim, so the calibrated split
    /// is untouched. This is what keeps the change inert on the nights it shouldn't touch.
    func testFlatNightIsByteIdenticalWithTrimOnVsOff() {
        var recs: [BulkRecord] = []
        var c: UInt32 = 0x0c220000
        for _ in 0..<8 { recs.append(arec(c)); c += step }
        for k in 0..<140 { recs.append(vrec(c, hr: k % 3 == 0 ? 52 : 50, hrv: 55)); c += step }  // flat, calm
        for _ in 0..<8 { recs.append(arec(c)); c += step }
        let on = SleepStaging.classify(from: recs)                                       // default (trim on)
        let off = SleepStaging.classify(from: recs, tuning: SleepStaging.Tuning(onsetMinDescentBPM: 999))
        XCTAssertEqual(on, off, "no wind-down (descent < gate) → trim is inert, output identical")
    }

    /// SAFETY 2 — bounded search. A night that stays elevated for HOURS and only settles past the
    /// onset search horizon must NOT be trimmed (we don't guess "awake until 2 a.m." from HR alone).
    /// The leading elevated stretch is left as-is rather than declared a multi-hour wake.
    func testLateSettleBeyondSearchWindowIsNotTrimmed() {
        var recs: [BulkRecord] = []
        var c: UInt32 = 0x0c220000
        for _ in 0..<8 { recs.append(arec(c)); c += step }
        for _ in 0..<60 { recs.append(vrec(c, hr: 60)); c += step }    // 2.5 h elevated — beyond the 48-epoch search
        for _ in 0..<80 { recs.append(vrec(c, hr: 50)); c += step }    // settles only here
        for _ in 0..<8 { recs.append(arec(c)); c += step }
        let on = SleepStaging.classify(from: recs)
        let off = SleepStaging.classify(from: recs, tuning: SleepStaging.Tuning(onsetMinDescentBPM: 999))
        // No onset found within the search window → identical to trim-off (no runaway leading wake).
        XCTAssertEqual(SleepStaging.summary(on).minutes.awake,
                       SleepStaging.summary(off).minutes.awake,
                       "a late settle past the search window is not trimmed (bounded, no runaway)")
    }

    // MARK: - Lead-in wake onset (the "lay still but awake for hours" fix)

    /// The 2026-06-26 screenshot night: the user lay still but AWAKE for hours before sleep, HR
    /// FLUCTUATING with a clearly-elevated (~90 bpm) block, then settled into sleep at a level the
    /// descent band never reaches within the search window. The fixed gate flags the 90-bpm block but
    /// leaves the short still dips before it reading as "asleep", so onset wrongly anchored to the
    /// FIRST dip (hours early, the "asleep 10:37 PM" bug). Onset must instead land AFTER the last
    /// pre-sleep wake block — the dips before it are awake-in-bed, not sleep.
    func testFragmentedPreSleepAnchorsOnsetAfterLastWakeBlock() {
        var recs: [BulkRecord] = []
        var c: UInt32 = 0x0c220000
        for _ in 0..<8 { recs.append(arec(c)); c += step }                    // before bed (outside block)
        let firstDip = c
        for _ in 0..<10 { recs.append(vrec(c, hr: 64)); c += step }            // brief still dip (pre-sleep, NOT real sleep)
        for _ in 0..<16 { recs.append(vrec(c, hr: 90)); c += step }            // clearly AWAKE (~90 bpm), still
        let afterWake = c
        for _ in 0..<40 { recs.append(vrec(c, hr: 60)); c += step }            // early light sleep, above the descent band
        for _ in 0..<100 { recs.append(vrec(c, hr: 52)); c += step }           // deep consolidated sleep (settles past the search window)
        for _ in 0..<8 { recs.append(arec(c)); c += step }                     // morning

        let segs = SleepStaging.classify(from: recs)
        XCTAssertFalse(segs.isEmpty)
        guard let win = SleepStaging.sleepWindow(segs) else { return XCTFail("no sleep window") }
        let firstDipDate = Date(timeIntervalSince1970: Double(Int(firstDip) + Command.syncEpoch))
        let afterWakeDate = Date(timeIntervalSince1970: Double(Int(afterWake) + Command.syncEpoch))
        // (a) onset is at/after the end of the wake block — NOT the first 64-bpm dip ~1 h earlier.
        XCTAssertGreaterThanOrEqual(win.onset, afterWakeDate.addingTimeInterval(-Double(step) * 2),
                                    "onset anchors after the last pre-sleep wake block, not the first still dip")
        XCTAssertGreaterThan(win.onset.timeIntervalSince(firstDipDate), Double(step) * 20,
                             "the fragmented pre-sleep (dip + wake block) is well before onset")
        // (b) control: with the lead-in rule off (consolidation guard 0 ⇒ never fires), onset
        // regresses to the early dip — proving the rule is what fixes it.
        let off = SleepStaging.classify(from: recs,
                                        tuning: SleepStaging.Tuning(minConsolidatedSleepEpochs: 0))
        guard let winOff = SleepStaging.sleepWindow(off) else { return XCTFail("no window (off)") }
        XCTAssertLessThan(winOff.onset, win.onset,
                          "without the lead-in rule, onset anchors earlier (the bug)")
    }

    /// GUARD: a night with REAL consolidated sleep before an early awakening must NOT have its onset
    /// pushed past that awakening — the lead-in rule only fires on a pre-sleep struggle (no sleep yet),
    /// never on a normal mid-night stir after the user is already asleep.
    func testConsolidatedSleepBeforeEarlyWakeKeepsOnsetEarly() {
        var recs: [BulkRecord] = []
        var c: UInt32 = 0x0c220000
        for _ in 0..<8 { recs.append(arec(c)); c += step }                     // before bed (outside block)
        let onset = c
        for _ in 0..<30 { recs.append(vrec(c, hr: 52)); c += step }            // real sleep (75 min) BEFORE the stir
        for _ in 0..<8 { recs.append(vrec(c, hr: 90)); c += step }             // early awakening (still asleep night)
        for _ in 0..<100 { recs.append(vrec(c, hr: 52)); c += step }           // back to sleep
        for _ in 0..<8 { recs.append(arec(c)); c += step }

        let segs = SleepStaging.classify(from: recs)
        guard let win = SleepStaging.sleepWindow(segs) else { return XCTFail("no sleep window") }
        let onsetDate = Date(timeIntervalSince1970: Double(Int(onset) + Command.syncEpoch))
        // Onset stays at the FIRST sleep block (the 90-bpm stir is an interior awakening, not pre-sleep).
        XCTAssertEqual(win.onset.timeIntervalSince(onsetDate), 0, accuracy: Double(step) * 3,
                       "consolidated sleep before the stir keeps onset early — the stir is interior wake")
        let awake = segs.filter { $0.stage == .awake }
        XCTAssertFalse(awake.isEmpty, "the early awakening still surfaces as an interior awake segment")
    }

    // MARK: - Constructed-night partition (sanity vs. RingConn night totals)

    func testConstructedNightPartitionsLikeATracker() {
        // ~5 sleep cycles: Light-heavy with periodic Deep troughs and elevated REM,
        // plus brief awakenings. We assert the SHAPE (light ≫ rem > deep, modest awake,
        // inBed ≈ asleep + awake) the way the app's night totals do — NOT exact minutes.
        // Light/REM carry HR JITTER and Deep is FLAT — that's how the model separates them
        // (Deep = the flat low-HR troughs; real light sleep is never perfectly flat). A
        // flat-HR "Light" block would correctly read as Deep, which is why this models the
        // real variability structure (confirmed against the Helio hypnogram, 2026-06-20).
        var recs: [BulkRecord] = []
        var c: UInt32 = 0x0c220000
        for _ in 0..<8 { recs.append(arec(c)); c += step }                   // sleep onset (awake)
        for cycle in 0..<5 {
            for k in 0..<10 { recs.append(vrec(c, hr: k % 2 == 0 ? 54 : 62, hrv: 60)); c += step }   // Light (jittery mid)
            for _ in 0..<8  { recs.append(vrec(c, hr: 50, hrv: 70)); c += step }                      // Deep (flat low)
            for k in 0..<8  { recs.append(vrec(c, hr: k % 2 == 0 ? 54 : 62, hrv: 60)); c += step }   // Light (jittery mid)
            for k in 0..<10 { recs.append(vrec(c, hr: k % 2 == 0 ? 64 : 78, hrv: 45)); c += step }   // REM (elevated, jittery)
            if cycle < 4 { for _ in 0..<2 { recs.append(arec(c, motion: 0x15)); c += step } } // brief wake
        }
        for _ in 0..<8 { recs.append(arec(c)); c += step }                   // morning (awake)

        let segs = SleepStaging.classify(from: recs)
        XCTAssertFalse(segs.isEmpty)
        let s = SleepStaging.summary(segs)

        // All four stages present.
        XCTAssertGreaterThan(s.deep, 0); XCTAssertGreaterThan(s.rem, 0)
        XCTAssertGreaterThan(s.light, 0); XCTAssertGreaterThan(s.awake, 0)

        // Architecture sanity: Light dominates, REM exceeds Deep (as in the GT night:
        // light 285m > rem 102m > deep 70m). Not exact-minute matching.
        XCTAssertGreaterThan(s.light, s.rem, "Light is the largest asleep stage")
        XCTAssertGreaterThan(s.rem, s.deep, "REM exceeds Deep")

        // Totals partition the night: inBed ≈ asleep + awake (within one epoch of rounding).
        XCTAssertEqual(s.inBed, s.totalAsleep + s.awake, accuracy: Double(step))
        // Efficiency in a plausible nightly range.
        XCTAssertGreaterThan(s.efficiency, 0.6)
        XCTAssertLessThanOrEqual(s.efficiency, 1.0)

        // stageTotals agrees with the summary.
        let totals = SleepStaging.stageTotals(segs)
        XCTAssertEqual(totals[.asleepDeep], s.deep)
        XCTAssertEqual(SleepStaging.totalAsleep(segs), s.totalAsleep, accuracy: 0.001)
    }

    // MARK: - Stitching a night handed off in MULTIPLE fragments (the shrink fix)

    /// A night split by a data gap (ring buffer dropped epochs / a missed overnight drain) must be
    /// STITCHED: both fragments staged and summed, not just the latest one kept. This is the core of
    /// the "sleep shrinks on every sync" fix — previously a single gap discarded everything but one
    /// block.
    func testFragmentedNightIsStitchedAcrossGap() {
        var recs: [BulkRecord] = []
        var c: UInt32 = 0x0c220000
        // Fragment 1: a ~5 h sleep core, bracketed by onset/EOF motion.
        for _ in 0..<8   { recs.append(arec(c)); c += step }
        for _ in 0..<120 { recs.append(vrec(c, hr: 52)); c += step }
        for _ in 0..<8   { recs.append(arec(c)); c += step }
        // Data gap well past the detector's break threshold (no records for 2 h).
        c += UInt32(2 * 3600)
        // Fragment 2: a second ~4 h sleep core.
        for _ in 0..<8   { recs.append(arec(c)); c += step }
        for _ in 0..<100 { recs.append(vrec(c, hr: 52)); c += step }
        for _ in 0..<8   { recs.append(arec(c)); c += step }

        XCTAssertEqual(BulkSleep.contiguousFragments(recs).count, 2, "gap splits into two fragments")

        let segs = SleepStaging.classify(from: recs)
        XCTAssertFalse(segs.isEmpty)
        let s = SleepStaging.summary(segs)

        // Asleep spans BOTH cores (120 + 100 epochs), not just one fragment.
        let bothCoresMin = Double((120 + 100) * Int(step)) / 60
        XCTAssertEqual(Double(s.minutes.asleep), bothCoresMin, accuracy: 40,
                       "stitched asleep covers both fragments, not just the latest")
        // One in-bed span per fragment; the 2 h gap is NOT counted as in-bed.
        let inBeds = segs.filter { $0.stage == .inBed }
        XCTAssertEqual(inBeds.count, 2, "one in-bed segment per fragment")
        let wallSpan = (segs.map(\.end).max()!).timeIntervalSince(segs.map(\.start).min()!)
        XCTAssertGreaterThan(wallSpan - s.inBed, 1.5 * 3600,
                             "the inter-fragment gap is excluded from in-bed")
        // Partition still holds across the stitch: in-bed ≈ asleep + awake.
        XCTAssertEqual(s.inBed, s.totalAsleep + s.awake, accuracy: Double(step) * 2)
    }

    /// A single contiguous night must be unchanged by the stitching path (one fragment ⇒ one in-bed
    /// segment, identical to the pre-stitch classifier).
    func testSingleFragmentNightUnchangedByStitch() {
        var recs: [BulkRecord] = []
        var c: UInt32 = 0x0c220000
        for _ in 0..<8   { recs.append(arec(c)); c += step }
        for _ in 0..<120 { recs.append(vrec(c, hr: 52)); c += step }
        for _ in 0..<8   { recs.append(arec(c)); c += step }
        XCTAssertEqual(BulkSleep.contiguousFragments(recs).count, 1)
        let segs = SleepStaging.classify(from: recs)
        XCTAssertEqual(segs.filter { $0.stage == .inBed }.count, 1)
    }

    func testNoSleepBlockYieldsNoSegments() {
        var recs: [BulkRecord] = []
        var c: UInt32 = 0x0c220000
        for _ in 0..<80 { recs.append(arec(c, motion: 0x18)); c += step }
        XCTAssertTrue(SleepStaging.classify(from: recs).isEmpty, "all-active -> no staging")
        XCTAssertTrue(SleepStaging.stageTotals([]).isEmpty)
        XCTAssertEqual(SleepStaging.totalAsleep([]), 0)
    }

    func testBulkSleepStagedSegmentsDelegatesToClassifier() {
        var recs: [BulkRecord] = []
        var c: UInt32 = 0x0c220000
        for _ in 0..<12 { recs.append(arec(c)); c += step }
        for _ in 0..<120 { recs.append(vrec(c, hr: 50)); c += step }
        for _ in 0..<12 { recs.append(arec(c)); c += step }
        XCTAssertEqual(BulkSleep.stagedSegments(from: recs), SleepStaging.classify(from: recs),
                       "BulkSleep.stagedSegments is a thin wrapper over SleepStaging.classify")
    }

    // MARK: - Issue #15 — all HealthKit sleep-analysis stage values (#15)

    /// `stagedSegments` must produce every stage value required by issue #15:
    /// `inBed`, `asleepCore` (light), `asleepDeep`, `asleepREM`, `awake`.
    /// HEALTHKIT_MAPPING.md: `HKCategoryType(.sleepAnalysis)` with these values.
    /// Uses a 5-cycle night (Deep troughs, REM peaks, brief awakenings) that exercises
    /// all four asleep stages plus the enclosing inBed span.
    func testStagedSegmentsProduceAllFiveHealthKitStages() {
        var recs: [BulkRecord] = []
        var c: UInt32 = 0x0c220000
        for _ in 0..<8  { recs.append(arec(c)); c += step }               // sleep onset (awake)
        for _ in 0..<5 {
            for _ in 0..<10 { recs.append(vrec(c, hr: 57, hrv: 55)); c += step }   // Light/core
            for _ in 0..<8  { recs.append(vrec(c, hr: 50, hrv: 65)); c += step }   // Deep
            for _ in 0..<8  { recs.append(vrec(c, hr: 57, hrv: 55)); c += step }   // Light/core
            for _ in 0..<10 { recs.append(vrec(c, hr: 65, hrv: 40)); c += step }   // REM (elevated)
            for _ in 0..<2  { recs.append(arec(c, motion: 0x15)); c += step }      // brief Awake
        }
        for _ in 0..<8  { recs.append(arec(c)); c += step }               // wake-up (awake)

        let segs = BulkSleep.stagedSegments(from: recs)
        XCTAssertFalse(segs.isEmpty, "staged segments must be produced")

        let present = Set(segs.map(\.stage))
        XCTAssertTrue(present.contains(.inBed),      "#15: inBed span required")
        XCTAssertTrue(present.contains(.asleepCore),  "#15: asleepCore (light) required")
        XCTAssertTrue(present.contains(.asleepDeep),  "#15: asleepDeep required")
        XCTAssertTrue(present.contains(.asleepREM),   "#15: asleepREM required")
        XCTAssertTrue(present.contains(.awake),       "#15: awake required")
    }

    /// `SleepStage.allCases` must cover all five values expected by HEALTHKIT_MAPPING.md.
    /// This is a compile-time-checkable structural guard: if a new case is added (or one
    /// renamed), the test breaks, forcing the HealthKitWriter mapping to be updated too.
    func testSleepStageEnumCoversAllHealthKitValues() {
        let required: Set<SleepStage> = [.inBed, .asleepCore, .asleepDeep, .asleepREM, .awake]
        XCTAssertEqual(Set(SleepStage.allCases), required,
                       "SleepStage must cover exactly the 5 HKCategoryValueSleepAnalysis cases")
    }

    // MARK: - Dedup: SyncCursor gates re-writing the same night (#15)

    /// The `.sleep` SyncCursor must gate re-presenting the same night's staged segments.
    /// `pendingHealthSleep` in LocalStore uses `cursor.isNew(.sleep, segments.max(\.end))`
    /// — advance → not-new — so a second sync with the same night never double-writes.
    func testSleepCursorDedupsByMaxEndDate() {
        // Build a synthetic night and extract its max end date.
        var recs: [BulkRecord] = []
        var c: UInt32 = 0x0c220000
        for _ in 0..<12 { recs.append(arec(c)); c += step }
        for _ in 0..<120 { recs.append(vrec(c, hr: 55)); c += step }
        for _ in 0..<12 { recs.append(arec(c)); c += step }

        let segs = BulkSleep.stagedSegments(from: recs)
        XCTAssertFalse(segs.isEmpty, "need staged segments for this test")
        guard let maxEnd = segs.map(\.end).max() else { return XCTFail("no end dates") }

        var cursor = SyncCursor()
        // Before any write: the night is "new".
        XCTAssertTrue(cursor.isNew(.sleep, maxEnd),
                      "fresh cursor: staged night is new (must be written)")

        // Simulate marking it written: advance the cursor past maxEnd.
        cursor.advance(.sleep, to: maxEnd)

        // Same or earlier end date: not new — dedup gate blocks a re-write.
        XCTAssertFalse(cursor.isNew(.sleep, maxEnd),
                       "after write: same night must not be written again (dedup)")

        // A genuinely new future night (maxEnd + 1 s) must still pass through.
        let nextNight = maxEnd.addingTimeInterval(1)
        XCTAssertTrue(cursor.isNew(.sleep, nextNight),
                      "next night is newer than cursor: must be written")
    }

    // MARK: - Personal (multi-night) baseline — Deep band anchoring (RingConn-aligned)

    /// The factory uses the MEDIAN of recent nights' deep-sleep HR, ignores non-positive entries
    /// (nights with no detected Deep), and needs ≥ `minNights` valid nights or it returns nil.
    func testPersonalBaselineFactory() {
        XCTAssertNil(SleepStaging.PersonalBaseline.fromRecentDeepHR([51, 52], minNights: 3),
                     "too few nights → no baseline (stay single-night)")
        XCTAssertNil(SleepStaging.PersonalBaseline.fromRecentDeepHR([0, 0, 51], minNights: 3),
                     "zeros (no-Deep nights) are filtered → too few valid → nil")
        // Odd count: sorted valid [51,51,52,75,102] → median 52, robust to the 75/102 outlier nights.
        XCTAssertEqual(SleepStaging.PersonalBaseline.fromRecentDeepHR([51, 75, 52, 51, 102])?.deepSleepHR,
                       52)
        // Even count → TRUE median (mean of the two central values), NOT an upper-median:
        // sorted [48,49,70,72] → (49+70)/2 = 59.5 (an upper-median would wrongly bias up to 70).
        XCTAssertEqual(SleepStaging.PersonalBaseline.fromRecentDeepHR([72, 48, 70, 49])?.deepSleepHR,
                       59.5)
    }

    /// The core win: a GLOBALLY-ELEVATED night (flat HR well above the person's norm) is read as mostly
    /// Deep by the single-night classifier (its own lowest epochs look "deep"), but a personal baseline
    /// anchored to the true deep HR (~50) recognises that 70 bpm is not deep for this person → not Deep.
    func testBaselineSuppressesDeepOnGloballyElevatedNight() {
        var recs: [BulkRecord] = []
        var c: UInt32 = 0x0c220000
        for _ in 0..<12 { recs.append(arec(c)); c += step }
        for _ in 0..<120 { recs.append(vrec(c, hr: 70, hrv: 55)); c += step }   // flat, still, ELEVATED
        for _ in 0..<12 { recs.append(arec(c)); c += step }

        let noBaseline = SleepStaging.classify(from: recs)
        let withBaseline = SleepStaging.classify(from: recs,
            baseline: SleepStaging.PersonalBaseline(deepSleepHR: 50))   // ceiling 50+10 = 60 < 70
        XCTAssertGreaterThan(fraction(noBaseline, .asleepDeep), 0.5,
            "single-night: the flat block reads as Deep relative to its own distribution")
        XCTAssertLessThan(fraction(withBaseline, .asleepDeep), 0.05,
            "with a personal baseline, a 70-bpm night is not deep for a person whose deep HR is ~50")
        // The suppressed Deep must become LIGHT, not REM: a flat elevated night has remHR ≈ the flat HR,
        // so letting suppressed epochs fall through to the REM test would absurdly read the whole night
        // as REM. A calm, flat epoch is Light (REM needs elevation OR variability).
        XCTAssertGreaterThan(fraction(withBaseline, .asleepCore), 0.8,
            "baseline-suppressed Deep relabels to Light")
        XCTAssertLessThan(fraction(withBaseline, .asleepREM), 0.2,
            "a flat elevated night does not spuriously read as all-REM")
    }

    /// SAFETY: the baseline must be INERT on a normal night — when the night's Deep HR sits within the
    /// margin of the baseline (or below it), the ceiling never binds and the staging is byte-identical
    /// to the single-night classifier. Two cases: a matching baseline, and a clearly non-binding one.
    func testBaselineIsInertWhenItDoesNotBind() {
        var recs: [BulkRecord] = []
        var c: UInt32 = 0x0c220000
        for _ in 0..<12 { recs.append(arec(c)); c += step }
        for _ in 0..<120 { recs.append(vrec(c, hr: 50, hrv: 55)); c += step }   // normal calm low-HR night
        for _ in 0..<12 { recs.append(arec(c)); c += step }

        let single = SleepStaging.classify(from: recs)
        // Matching baseline (deep HR 50, ceiling 60 ≥ the night's 50 epochs) → no Deep removed.
        XCTAssertEqual(single, SleepStaging.classify(from: recs,
            baseline: SleepStaging.PersonalBaseline(deepSleepHR: 50)),
            "a baseline matching the night's deep HR changes nothing")
        // A higher baseline (ceiling well above all HR) is likewise inert.
        XCTAssertEqual(single, SleepStaging.classify(from: recs,
            baseline: SleepStaging.PersonalBaseline(deepSleepHR: 80)),
            "a non-binding baseline is byte-identical to the single-night classifier")
    }
}

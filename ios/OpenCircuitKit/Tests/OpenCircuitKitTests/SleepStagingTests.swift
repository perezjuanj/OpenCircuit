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

    // MARK: - HR-aware onset/offset ("still but awake") — the screenshot fix

    /// A long, STILL block of elevated HR before real sleep (e.g. lying in bed / on the
    /// couch awake) must be TRIMMED out of the in-bed window, not counted as sleep. This
    /// is the case motion alone misses (no movement → "still" → falsely asleep) and the
    /// root of the 3-hour over-count: in-bed onset 23:01 vs a real ~02:00.
    func testStillButElevatedHRPreSleepIsTrimmed() {
        var recs: [BulkRecord] = []
        var c: UInt32 = 0x0c220000
        let preEpochs = 40
        for _ in 0..<preEpochs { recs.append(vrec(c, hr: 78)); c += step }   // still but AWAKE (high HR)
        let onset = c
        for _ in 0..<120 { recs.append(vrec(c, hr: 54)); c += step }          // real sleep core
        for _ in 0..<8 { recs.append(arec(c)); c += step }                    // morning (motion-active)

        let segs = SleepStaging.classify(from: recs)
        XCTAssertFalse(segs.isEmpty)
        let inBed = segs.first { $0.stage == .inBed }!
        let onsetDate = Date(timeIntervalSince1970: Double(Int(onset) + Command.syncEpoch))
        // In-bed window starts at real onset (the low-HR block), NOT the elevated pre-sleep.
        XCTAssertEqual(inBed.start.timeIntervalSince(onsetDate), 0, accuracy: Double(step) * 2,
                       "pre-sleep elevated-HR block is trimmed from in-bed")
        // The pre-sleep block is not counted as asleep: asleep ≈ the 120-epoch core.
        let s = SleepStaging.summary(segs)
        let coreMin = Double(120 * Int(step)) / 60
        XCTAssertEqual(Double(s.minutes.asleep), coreMin, accuracy: 30,
                       "asleep reflects the real core, not the pre-sleep wake")
        // None of the trimmed pre-sleep time leaks back as an Awake segment.
        for seg in segs where seg.stage != .inBed {
            XCTAssertGreaterThanOrEqual(seg.start, inBed.start)
        }
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
}

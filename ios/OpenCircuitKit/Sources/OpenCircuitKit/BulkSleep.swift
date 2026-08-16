// Bulk activity/sleep decode — the `0x4c` history stream (docs/PROTOCOL.md §5.3).
//
// Confirmed on FW FR02.018 by aligning captures/sleep_sync_btsnoop.log
// (2026-06-13 overnight sync) to the RingConn app's own readout for that night
// (avg HR 68 / HRV 65 ms / SpO2 98 %, low 93 % ~02:30–03:00). The decisive anchor:
// the decoded SpO2 low-cluster lands at 02:32–03:07, matching the app exactly.
//
// A 0x4c page is `[0x4c][0x00][countdown][N × 23-byte record][xor]`. The counter
// is seconds since `Command.syncEpoch`; records step +0x96 = 150 s, so each record
// is one 2.5-min epoch. Records align to page boundaries (each page body is a whole
// number of records — they do not span pages).
//
// Two record layouts, keyed on byte [8]:
//   • Sleep-vitals epoch ([8] in 0x57…0x63): [4]=HR bpm 🟢, [5]=HRV/RMSSD ms 🟢,
//     [6]=confidence 🟢, [7]=RR×8 🟢 (respiratoryRate below), [8]=SpO2 % 🟢, [10:20]=acti_counts.
//   • Activity/awake epoch ([8]=0x12/0x13): [4]=HR bpm 🟢 (ALL-DAY HR — same head as sleep;
//     confirmed 2026-06-17 by sleep↔activity continuity across all captures, ±4.6 bpm / corr +0.76),
//     [10:20]=acti_counts (motion/intensity blob; [15:20] is just its tail, NOT a separate
//     steps/distance payload — that claim was retracted, PROTOCOL.md §5.3 #93).
//     byte[5] HRV and byte[7] RR ARE present and valid on these epochs (🟢 #185, 6 independent
//     archives): byte[5] is only artifact-inflated while the [15:20] intensity tail is NON-ZERO.
//     SpO2 genuinely is absent — [8] IS the activity tag. The recovered values reach the HealthKit
//     sample path ONLY (measuredHRVRMSSD / measuredRespiratoryRate); the strict sleep-vitals
//     accessors below remain the "ring is measuring sleep" MODE signal that staging consumes.
//     The real steps/distance/activeSeconds record (历史活动响应) is a SEPARATE,
//     still-uncaptured stream — §5.3.1, `RingSession.probeActivityChannels`.
// Respiratory rate IS per-epoch ([7]÷8, ground-truthed). Skin temp is NOT per-epoch here (it's
// read live off the 0x10/0x87 descriptor, §5.4). Sleep stages are not on the wire — compute them
// in Swift (Analytics/SleepDetection), per Phase 5.
//
// Do not add behavior that isn't in PROTOCOL.md. New facts go into the spec (and
// desktop/decode_bulk.py) first, then get ported here.

import Foundation

/// One 23-byte record from a `0x4c` bulk activity/sleep page (PROTOCOL.md §5.3).
public struct BulkRecord: Equatable {
    /// Bytes per record (🟢).
    public static let length = 23
    /// Counter step between consecutive records: 0x96 = 150 s (🟢).
    public static let epochSeconds = 150

    /// The raw 23 bytes.
    public let raw: [UInt8]

    public init?(_ bytes: [UInt8]) {
        guard bytes.count == Self.length else { return nil }
        self.raw = bytes
    }

    /// `[0:4]` big-endian counter — seconds since `Command.syncEpoch`.
    public var counter: UInt32 {
        (UInt32(raw[0]) << 24) | (UInt32(raw[1]) << 16) | (UInt32(raw[2]) << 8) | UInt32(raw[3])
    }

    /// Wall-clock time of this epoch (counter + epoch offset).
    public func date(epoch: Int = Command.syncEpoch) -> Date {
        Date(timeIntervalSince1970: TimeInterval(Int(counter) + epoch))
    }

    public enum Layout: Equatable {
        case idle          // unworn / no measurement: motion 01×5 and zero payload
        case sleepVitals   // [8] is an SpO2 %; HR/HRV/SpO2 live in [4:9]
        // No SpO2 read in this epoch: [8] is a sentinel (0x12/0x13 awake-active, 0x11 the
        // ring's "nothing measured" block terminator), NOT a percentage. The old comment here
        // claimed a separate "[15:22] payload" — that is the #93 claim PROTOCOL.md §5.3
        // RETRACTED on 2026-06-17; [15:22] is just the tail of `acti_counts`.
        case activity
    }

    public var layout: Layout {
        // Decide layout from STRUCTURE, not the SpO2 *value* (#39). The old code returned
        // .sleepVitals only when [8] ∈ 0x57…0x63 (87–99 %), so a genuine desaturation
        // (< 87 %, the clinically interesting apnea case) failed that gate, fell through to
        // .activity, and the WHOLE epoch's HR/HRV/SpO2 was discarded. Decide instead by the
        // two STRUCTURAL signatures and treat anything else as sleep-vitals:
        //   • idle/unworn template (🟢 §5.3): [4:8]=05 00 0c 00, [9]=0a, motion 01×5,
        //     [15:22]=00×7. The FULL template matters: a deep-sleep epoch is also still with
        //     a zero [15:22] payload, but carries real HR/HRV in [4:8] — so matching only
        //     "still + zero payload" would mistake deep sleep for idle and drop its vitals.
        //   • activity/awake epoch (🟢 §5.3): [8] subtype tag 0x12 / 0x13 / 0x11.
        // A low-SpO2 sleep epoch matches neither → .sleepVitals, so its vitals survive. The
        // emitted SpO2 is range-guarded in `spo2Percent`, but the band no longer gates layout.
        //
        // 0x11 IS A THIRD "no SpO2 here" SENTINEL 🟢 (#195, §5.3). It is not a 17 % saturation
        // and not a desaturation #39 must protect — measured over the 5648 unique non-idle
        // records of the 5-ring local corpus:
        //   • ALL 13 of them carry [4] == 0x04, the ring's <30 "PR unmeasured" sentinel, and
        //     12 of 13 carry the whole dead head `04 00 00 00` (HR/HRV/conf/RR all unmeasured).
        //     NO record with a real SpO2 byte ever carries [4] == 0x04 (0 of 1750); among the
        //     0x12 activity epochs 14 of 3869 do. So there are no vitals here to preserve.
        //   • ALL 13 sit at the tail of a contiguous run — 11 are the last record before a
        //     multi-epoch hole and the other 2 are immediately followed by another 0x11 that
        //     is. Every one is preceded by an ACTIVITY epoch, never by a sleep-vitals one, so
        //     none of them sits in an SpO2 slot of the §5.3 duty cycle.
        // ⚠️ The other impossible-SpO2 bytes in the corpus — 0x00 / 0x0a / 0x0e, 16 records —
        // are DELIBERATELY LEFT ALONE. They are the opposite shape: 12 of the 16 sit in an
        // SpO2 slot with an activity epoch on BOTH sides, and 14 of 16 carry a plausible
        // `[4:8]` head. They are sleep-vitals epochs whose SpO2 byte failed, which is exactly
        // the case #39's fall-through exists for; `spo2Percent`'s 70…100 guard already stops
        // the impossible value reaching a sample.
        if raw[4] == 0x05 && raw[5] == 0x00 && raw[6] == 0x0c && raw[7] == 0x00
            && raw[9] == 0x0a
            && raw[10..<15] == [1, 1, 1, 1, 1]
            && raw[15..<22] == [0, 0, 0, 0, 0, 0, 0] {
            return .idle
        }
        if raw[8] == 0x12 || raw[8] == 0x13 || raw[8] == 0x11 { return .activity }
        return .sleepVitals
    }

    /// Heart rate in bpm — `[4]` on ANY worn epoch (🟢). This is the ALL-DAY HR: byte[4] carries
    /// HR on BOTH sleep-vitals AND activity/awake epochs (the same head layout `[4]=HR, [5]=HRV`;
    /// only `[8]` differs — SpO2 vs the `0x12/0x13` activity tag). Confirmed 2026-06-17 by aligning
    /// every capture's worn 0x4c epochs: across 204 sleep↔activity transitions, activity `[4]`
    /// tracks the neighbouring sleep HR to within 4.6 bpm (corr +0.76) and forms ONE continuous
    /// series across layout boundaries (e.g. the 08:41–11:56 worn run). We previously gated this to
    /// sleep-vitals only, discarding all daytime/active HR — the root of "no daytime/workout HR",
    /// sparse-HR active calories, and thin resting-HR coverage (#45/#38).
    /// nil for the idle (unworn) template — its `[4]==0x05` is rejected by the band below anyway —
    /// and for any byte outside the physiological band (`LiveHR.validBPM`, 30…220), which also stops
    /// a garbage epoch (the impossible "Resting HR 4 bpm") from becoming a sample.
    public var heartRate: Int? {
        guard layout != .idle else { return nil }
        let hr = Int(raw[4])
        return LiveHR.validBPM.contains(hr) ? hr : nil
    }

    /// HRV in ms — `[5]` on a sleep-vitals epoch (🟢). The ring reports RMSSD; HealthKit
    /// only has SDNN (different statistic, same unit) — see HEALTHKIT_MAPPING.md.
    ///
    /// ⚠️ THIS IS A MODE SIGNAL AS WELL AS A VALUE, and the mode signal is the load-bearing half.
    /// `!= nil` means "the ring emitted a sleep-vitals template here". Sleep DETECTION
    /// (`sleepVitalTimeline` → `ActivityPeriod.sleepVitalsRescue`), STAGING (`SleepStaging`
    /// forward-fill + the raw `vitals` flag), NAPS (`NapDetection.sleepVitalsShare`) and
    /// `SleepStress` all read it that way — widening its layout scope MOVES THE DETECTED NIGHT.
    /// It therefore deliberately does NOT recover the HRV that 0x12/0x13 activity epochs also
    /// carry: that is `measuredHRVRMSSD`, which only `BulkSleep.samples` may use (#185).
    public var hrvRMSSD: Int? {
        guard layout == .sleepVitals, raw[5] > 0 else { return nil }
        return Int(raw[5])
    }

    /// SpO2 percent — `[8]` on a sleep-vitals epoch (🟢). nil otherwise. Guarded to a
    /// clinically plausible band (70…100): unlike the old layout gate this admits genuine
    /// desaturations below the healthy 87…99 range (#39) while rejecting noise. The HR/HRV
    /// of a sub-70 epoch still decode — only the implausible SpO2 reading is dropped.
    public var spo2Percent: Int? {
        guard layout == .sleepVitals else { return nil }
        let v = Int(raw[8])
        return (70...100).contains(v) ? v : nil
    }

    /// Respiratory rate in breaths/min — `[7]` on a sleep-vitals epoch, scaled ÷8 (🟢,
    /// ground-truthed 2026-06-15): per-epoch `[7]/8` matches the RingConn app's nightly
    /// average 15.1 and its low/high 14.5–16.1 at the p5–p95 of the asleep epochs. (The
    /// raw field is RR×8; exact divisor ≈8.07, but 8 is the natural 1/8-brpm fixed point.)
    ///
    /// ⚠️ Sleep-vitals-scoped like `hrvRMSSD`, and `SleepStaging` forward-fills it (:530).
    /// The activity-epoch RR is `measuredRespiratoryRate` — sample path only (#185).
    public var respiratoryRate: Double? {
        guard layout == .sleepVitals, raw[7] > 0 else { return nil }
        return Double(raw[7]) / 8.0
    }

    // MARK: - Measured vitals (#185) — HealthKit sample emission ONLY
    //
    // `hrvRMSSD` / `respiratoryRate` above are SLEEP-VITALS-SCOPED, and detection/staging/naps/
    // stress consume that scope as the ring's "I am measuring sleep" MODE flag. But the ring also
    // puts a real RMSSD in [5] and a real RR in [7] on 0x12/0x13 ACTIVITY epochs, so those two
    // accessors discard roughly half of both metrics before they can reach Apple Health.
    //
    // The two accessors below answer a DIFFERENT question — "did the ring MEASURE this value on
    // this epoch, whichever record template carried it?" — and are consumed by `BulkSleep.samples`
    // and NOTHING else. They are deliberately INTERNAL, not public: the app target physically
    // cannot reference them, so every sleep-pipeline consumer stays byte-identical by construction.
    //
    // 🟢 MEASURED over 6 INDEPENDENT real archives (5 Gen-2/Gen-3 + 1 Gen-2-Air FR04; 3679 distinct
    // 0x4c records after de-duplicating four contained captures). Matching each activity epoch's [5]
    // to its nearest sleep-vitals neighbour within 300 s gives a median delta of −1.5…+2.5 ms on
    // every Gen-2/Gen-3 archive — ordinary epoch-to-epoch RMSSD variation, i.e. the values are REAL.
    // 🟡 OPEN PROTOCOL QUESTION: the FR04 Gen-2-Air alone runs ≈ −11…−15 ms (the exact median moves
    // with the neighbour tie-break, the sign and scale do not). Recorded and deliberately NOT
    // "corrected". A run whose two populations disagree by more than `hrvPoolingNoiseFloorMs`
    // simply stops pooling — see `BulkSleep.hrvPooling`. The offset itself is still an OPEN protocol
    // question; the gate makes such a run no worse than pre-#185, it does not explain the Air.

    /// Physiological RMSSD ceiling (ms) for an EMITTED HRV sample. 🟢 MEASURED: the max byte[5] over
    /// every worn epoch of every archive is exactly 200 (2671 non-zero HRV bytes), so this rejects
    /// only the never-observed 201…255 byte space and drops 0 of the 1109 samples we ship today.
    /// A byte-garbage backstop, NOT the motion discriminator — that is the quiet gate below.
    /// (Bands with teeth were measured: 5...200 would drop 1 shipped sample, 5...150 four,
    /// 15...200 twenty-eight. 1...200 is the only one that drops nothing.)
    static let maxPlausibleHRVMs = 200

    /// HRV in ms the ring MEASURED on this epoch, on EITHER record template (#185). Sleep-vitals
    /// epochs pass through as `hrvRMSSD` does; activity epochs must ADDITIONALLY be QUIET
    /// (`motionIntensityTailIsZero` — the ring's own "nothing moved" verdict, #184).
    ///
    /// WHY the quiet gate, and why ONLY on activity epochs. 🟢 MEASURED, pooled over the deduped
    /// union: QUIET activity epochs run p50 58 / p90 86 / p99 111 / max 142 — statistically the same
    /// population as sleep-vitals (p50 60 / p90 88 / p99 119) — while MOVING activity epochs run
    /// p90 98 / p99 196 / max 200. A 200 ms RMSSD on a moving awake wrist is PPG artifact. Applying
    /// the SAME gate to sleep-vitals epochs would DROP 382 of the 1109 HRV samples we ship today
    /// (34.4 %), so the asymmetry is deliberate.
    ///
    /// ⚠️ FOR `BulkSleep.samples` ONLY. Detection, staging, naps and `SleepStress` keep using
    /// `hrvRMSSD`, whose sleep-vitals scope is the signal they actually consume.
    var measuredHRVRMSSD: Int? {
        guard layout != .idle, raw[5] > 0, Int(raw[5]) <= Self.maxPlausibleHRVMs else { return nil }
        guard layout == .sleepVitals || motionIntensityTailIsZero else { return nil }
        return Int(raw[5])
    }

    /// Plausible adult respiratory-rate band (brpm) for an EMITTED sample. 🟢 MEASURED: every
    /// byte[7] > 0 epoch in the corpus (2511, all layouts, all generations) has a raw value in
    /// 101…141 → 12.625…17.625 brpm, so this drops 0 of the 1084 samples we ship today and rejects
    /// only raw 1…31 and 241…255 — sentinel / stuck-byte space. The ceiling is REACHABLE inside a
    /// UInt8 (255/8 = 31.875), so unlike a 40 brpm ceiling it is a real, testable clamp.
    static let plausibleRespiratoryRate: ClosedRange<Double> = 4.0 ... 30.0

    /// RR in brpm the ring MEASURED on this epoch, on EITHER record template (#185): [7]/8 on ANY
    /// worn epoch, band-guarded. 🟢 MEASURED: motion does NOT corrupt this field — sleep-vitals
    /// epochs run p50 15.125 / p99 16.875 / max 17.625 and activity epochs p50 15.25 / p99 17.0 /
    /// max 17.625 — so unlike HRV there is NO quiet gate. The idle template carries [7] == 0 by
    /// construction (0 exceptions in the corpus), so `layout != .idle` is belt-and-braces.
    ///
    /// ⚠️ FOR `BulkSleep.samples` ONLY — `SleepStaging` keeps using `respiratoryRate` (#185).
    var measuredRespiratoryRate: Double? {
        guard layout != .idle, raw[7] > 0 else { return nil }
        let rr = Double(raw[7]) / 8.0
        return Self.plausibleRespiratoryRate.contains(rr) ? rr : nil
    }

    /// `[10:15]` — 5 per-30 s motion/activity counts (🟢 role). `01` baseline = still.
    public var motion: [UInt8] { Array(raw[10..<15]) }

    /// True when `[10:15]` is a CONSTANT run (all five 30-s sub-samples equal) on a worn epoch —
    /// the ring's "no fine-motion recorded" placeholder. 🟢 verified on the 2026-07-12 capture: a
    /// byte-identical `0f 0f 0f 0f 0f` (=15) filled 185 epochs across the whole core-sleep window
    /// while HR/HRV/SpO2 varied normally — a constant field is a FILLER, not a measurement, and its
    /// `[15:20]` tail was zero 71 % of the time with no correlation to sleep depth. The placeholder
    /// level is device- and posture-dependent (Gen-2 idles at `01`, Gen-3 at `0f` and DRIFTS), so
    /// this keys on the STRUCTURE (zero intra-epoch variation), never a specific value — real motion,
    /// whose counts always vary sample-to-sample, is never a constant run. Layout-agnostic on purpose:
    /// the same placeholder rides BOTH sleep-vitals AND `0x12`-activity epochs (92 + 93 of the 185),
    /// so gating on layout would miss half of them and leave the movement bar half-wrong. The idle /
    /// unworn template is excluded — it has its own `.idle` layout and dedicated handling.
    public var motionIsPlaceholder: Bool {
        guard layout != .idle else { return false }
        let m = raw[10..<15]
        return m.allSatisfy { $0 == m.first }
    }

    /// True when the five 30-s sub-samples all sit within `motionStillThreshold` of one another —
    /// the epoch on its OWN cannot express movement. This is precisely the component of the motion
    /// channel that `ActivityPeriod.motionAboveLocalFloor` CANNOT remove: the rolling floor subtracts
    /// a per-window LEVEL, so a flat plateau at any level cancels (Gen-2 `01`, Gen-3 `0f`, and the
    /// drifting `16→24→39` plateaus alike), but a step INSIDE one epoch survives de-flooring intact.
    /// `motionIsPlaceholder` (all five EQUAL) is the zero-spread special case of this.
    var motionResolvesStillness: Bool {
        guard layout != .idle else { return false }
        let m = raw[10..<15]
        guard let lo = m.min(), let hi = m.max() else { return false }
        return Float(hi - lo) <= ActivityPeriod.motionStillThreshold
    }

    /// True when `[15:20]` is all zero — the ring's OWN "nothing moved in this epoch" verdict.
    ///
    /// ⚠️ THIS PREDICATE IS BYTE-ALIGNED AND THE FIELD IS NOT (#195). `[15:23)` is really five
    /// 12-bit magnitudes (`activityMagnitudes`), so a byte window of `[15:20]` covers magnitudes
    /// 0–2 in full and only the top nibble of magnitude 3 — it cannot see magnitudes 3 and 4 at
    /// all. 🟢 MEASURED on the 5648-record local corpus: of the 1950 epochs this calls quiet,
    /// **253 (13.0 %) carry a non-zero magnitude**, and every one of those 253 is a magnitude 3
    /// (97) or 4 (194), i.e. exactly the two the window cannot reach.
    /// It is kept EXACTLY as it is on purpose. Three shipped calibrations are fitted to this
    /// predicate's population, not to the correct one: `primaryMotionIsDegenerate`'s
    /// `degenerateMaxQuietStillFraction` (0.50) and `degenerateMinSlotOrderFraction` (0.75),
    /// `measuredHRVRMSSD`'s quiet gate, and `hrvPoolingNoiseFloorMs` (9.0). Redefining it moves
    /// all three off their measured separations at once. Use `activityMagnitudesAreZero` for new
    /// work; retiring this one is a separate, measured migration.
    var motionIntensityTailIsZero: Bool { raw[15..<20].allSatisfy { $0 == 0 } }

    /// `[15:23)` decoded correctly: **five 12-bit big-endian magnitudes, nibble-packed** — the
    /// `acti_counts` V2 sub-layout PROTOCOL.md §5.3 had open as "length 7.5, `info` = 0.5 B"
    /// (60 bits + a 4-bit flag = the 8 bytes `[15]…[22]`). Magnitude *k* is nibbles 3k, 3k+1,
    /// 3k+2 counting from the high nibble of `[15]`; the leftover LOW nibble of `[22]` is
    /// `activityInfoNibble`.
    ///
    /// 🟢 THE BIT LAYOUT IS MEASURED, over the 5648 unique non-idle records of the 5-ring local
    /// corpus (#195). CARRY TEST — for a genuine 12-bit integer whose low byte is ~uniform,
    /// `P(value ≡ 0 mod 256 | value > 0)` is 1/256 = 0.0039; a window straddling a field boundary
    /// has a "low byte" made of one field's LAST nibble and the next field's FIRST, both of which
    /// are 0 about half the time, so it must be orders of magnitude larger. Measured:
    ///   • this nibble phase — 0.0017…0.0030 per field, and 0.0000…0.0029 per ring (5 rings);
    ///   • phase +1 nibble — 0.0172…0.0317; phase +2 nibbles — 0.1491…0.1627.
    /// Two model-free corroborations of the same 1.5-byte period: the mean nibble value over the
    /// 16 nibble positions repeats 1.21 / 3.37 / 3.97 five times (the most-significant nibble
    /// lands on 0, 3, 6, 9, 12 — nowhere else), and the mean BYTE value repeats 22.5 / 65 / 57
    /// with a 3-byte period. The trailing nibble is categorical, not a digit: `0` (66.3 %) and
    /// `4` (31.6 %) cover 97.9 % of records with 9 distinct values, against 15–16 for every
    /// magnitude nibble — and a LEADING flag would put the magnitudes at phase +1, which the
    /// carry test rejects by 6–10×.
    ///
    /// 🔴 WHAT THE FIVE NUMBERS PHYSICALLY ARE is NOT established. They are NOT a higher-precision
    /// copy of `[10:15]`'s five 30-s slots: over the 3021 records whose primary channel is not a
    /// placeholder, magnitude *k* vs motion byte *j* is +0.13…+0.19 for EVERY pair with no
    /// diagonal, and Σmagnitudes vs Σmotion is only +0.20. Observed range 0…4095 (the full 12-bit
    /// span), p50 10, p90 1302, 46.9 % exactly zero. Treat as `confidence`/`activityCounts` are
    /// treated: decoded and exposed for the supervised sleep-stage fitter to test, NOT a licence
    /// to hand-tune `SleepStaging`.
    public var activityMagnitudes: [Int] {
        func nibble(_ i: Int) -> Int {
            let b = Int(raw[15 + i / 2])
            return i.isMultiple(of: 2) ? (b >> 4) : (b & 0x0f)
        }
        return (0 ..< 5).map { (nibble($0 * 3) << 8) | (nibble($0 * 3 + 1) << 4) | nibble($0 * 3 + 2) }
    }

    /// The 4-bit `info` flag that closes the `[15:23)` block — the LOW nibble of `[22]`
    /// (🟢 boundary, 🟡 meaning: 97.9 % of records read `0` or `4`).
    public var activityInfoNibble: UInt8 { raw[22] & 0x0f }

    /// The layout-correct counterpart of `motionIntensityTailIsZero`: every one of the five 12-bit
    /// magnitudes is zero. 🟢 MEASURED: 1697 of 5648 corpus records (30.0 %), against the byte-
    /// aligned predicate's 1950 (34.5 %) — the 253-record difference is the 13.0 % the old window
    /// cannot see. Deliberately NOT wired into any existing analytic (see `motionIntensityTailIsZero`).
    var activityMagnitudesAreZero: Bool { activityMagnitudes.allSatisfy { $0 == 0 } }

    /// Confidence / signal quality, `[6]` (🟢 named, PROTOCOL.md §5.3 — range ~0...12,
    /// not yet bounded precisely). Decoded but NOT currently consumed by any analytic —
    /// available for the supervised sleep-stage fitter (`desktop/ringconn_sleep_fit.py`)
    /// to test as a confidence-weighting cue once real ground truth is captured
    /// (`docs/RUNBOOK_SLEEP_GROUNDTRUTH.md`); do not bake an untested weighting into
    /// `SleepStaging` ahead of that.
    public var confidence: Int? {
        guard layout != .idle else { return nil }
        return Int(raw[6])
    }

    /// `[10:20]` — the FULL 10-byte `acti_counts` blob (🟢 role, PROTOCOL.md §5.3): `motion`
    /// above only exposes its first 5 bytes (`[10:15]`); bytes `[15:20]` are its "intensity
    /// tail" (PROTOCOL.md's #93 reconciliation — non-zero iff moving, NOT a separate
    /// steps/distance payload). Exposed here because it's already decoded and currently fed
    /// to nothing — like `confidence`, it's a candidate cue for the supervised sleep-stage
    /// fitter to test empirically, not a license to hand-tune `SleepStaging` with it.
    public var activityCounts: [UInt8] { Array(raw[10..<20]) }

    /// `[15:20]` — the intensity half of `activityCounts`. This is NOT a second step counter or a
    /// separately timed five-sample motion channel, but it remains zero while still and carries
    /// measured activity when some firmware sessions replace `[10:15]` with a constant filler.
    /// Consumers may use it only through `BulkSleep.motionSource`, which requires the primary channel
    /// to be structurally ABSENT (a constant filler) or structurally UNABLE TO RESOLVE STILLNESS
    /// (#184) across a run; normal primary-motion nights never mix the two signals.
    public var motionIntensityTail: [UInt8] { Array(raw[15..<20]) }
}

/// Reassembles `0x4c` pages into records and maps sleep-vitals epochs to samples.
public enum BulkSleep {

    /// Records carried by ONE 0x4c page frame (full notification incl. opcode + XOR).
    /// Returns [] if the XOR trailer is invalid or the opcode isn't 0x4c.
    public static func records(fromPage frame: [UInt8]) -> [BulkRecord] {
        guard let p = Frame.parse(frame), p.opcode == Frame.responseID(Opcode.page4C) else { return [] }
        // body = [00][countdown][records…]; records begin at body index 2.
        return records(fromStream: Array(p.body.dropFirst(2)))
    }

    /// Split a raw record stream (no page header/trailer) into whole 23-byte records.
    /// A trailing partial chunk is dropped.
    public static func records(fromStream bytes: [UInt8]) -> [BulkRecord] {
        guard bytes.count >= BulkRecord.length else { return [] }
        return stride(from: 0, through: bytes.count - BulkRecord.length, by: BulkRecord.length)
            .compactMap { BulkRecord(Array(bytes[$0 ..< $0 + BulkRecord.length])) }
    }

    /// Reassemble a multi-page bulk transfer into one ordered record list.
    public static func records(fromPages frames: [[UInt8]]) -> [BulkRecord] {
        frames.flatMap { records(fromPage: $0) }
    }

    /// Split records into CONTIGUOUS runs, breaking wherever the gap between consecutive epoch
    /// counters exceeds `maxGap`. A "night" arrives in MORE THAN ONE drain (the ring buffers only
    /// ~4.75 h and drops the oldest; each manual sync drains a partial slice), so the union holds the
    /// real night as several fragments separated by data gaps. Staging each fragment independently and
    /// summing — instead of keeping only one block — is what stitches the night back together. The
    /// threshold matches `SleepDetection`'s gap-break (`gravityMaxGap`) so a fragment never contains a
    /// gap the detector would itself split on (which would re-introduce the single-block discard).
    public static func contiguousFragments(_ records: [BulkRecord],
                                           maxGap: TimeInterval = ActivityPeriod.gravityMaxGap) -> [[BulkRecord]] {
        let sorted = records.sorted { $0.counter < $1.counter }
        guard !sorted.isEmpty else { return [] }
        var frags: [[BulkRecord]] = []
        var cur: [BulkRecord] = [sorted[0]]
        for i in 1 ..< sorted.count {
            let gap = TimeInterval(Int(sorted[i].counter) - Int(sorted[i - 1].counter))
            if gap > maxGap { frags.append(cur); cur = [sorted[i]] }
            else { cur.append(sorted[i]) }
        }
        frags.append(cur)
        return frags
    }

    /// Expand 0x4c records into a per-30 s motion timeline (5 sub-samples per
    /// 150 s epoch from the [10:15] channel) for `SleepDetection.detectFromMotion`.
    /// Motion counts are passed through directly (baseline `01` = still) unless `motionSource`
    /// rejects the primary channel for this run; callers should scope `records` to a worn period
    /// (charging data reads as still too).
    public static func motionTimeline(from records: [BulkRecord],
                                      epoch: Int = Command.syncEpoch) -> [MotionSample] {
        let source = motionSource(records)
        let fallbackMagnitudes: [Float]
        let useIntensityFallback: Bool
        if case .intensityTail(let degenerate) = source {
            useIntensityFallback = true
            fallbackMagnitudes = motionIntensityFallbackMagnitudes(records, degenerate: degenerate)
        } else {
            useIntensityFallback = false
            fallbackMagnitudes = []
        }
        var out: [MotionSample] = []
        out.reserveCapacity(records.count * 5)
        for (recordIndex, r) in records.enumerated() {
            let base = r.date(epoch: epoch)
            // The intensity tail is an epoch-level fallback, not five independently-timed samples.
            // Repeat its derived light/active magnitude over the epoch's five 30-second slots so the
            // detector retains its canonical cadence without inventing sub-epoch timing.
            for k in 0 ..< 5 {
                out.append(MotionSample(time: base.addingTimeInterval(Double(k) * 30),
                                        movement: useIntensityFallback
                                            ? fallbackMagnitudes[recordIndex]
                                            : Float(r.raw[10 + k])))
            }
        }
        return out
    }

    /// Which channel a run's motion is read from. `.intensityTail` carries WHY the primary was
    /// rejected, because the two reasons need different tail→magnitude mappings (see
    /// `motionIntensityFallbackMagnitudes`).
    enum MotionSource: Equatable {
        /// `[10:15]`, the normal path. Every input that reaches it is byte-identical to pre-#184.
        case primary
        /// `[15:20]`. `degenerate == false` is the original 2026-07-12 constant-filler shape;
        /// `degenerate == true` is the FR04.009 non-expressive-primary shape (#184).
        case intensityTail(degenerate: Bool)
    }

    /// Pick the motion channel for a run. The primary `[10:15]` channel is unusable in TWO
    /// structurally distinct ways, and either one falls through to the `[15:20]` intensity tail:
    ///   • CONSTANT FILLER — every worn epoch is a constant run (`motionIsPlaceholder`); the channel
    ///     carries no measurement at all. 🟢 the 2026-07-12 Gen-3 capture.
    ///   • NON-EXPRESSIVE — the channel varies, but never in a way that can read still, and its
    ///     variation is a fixed intra-epoch template rather than movement (`primaryMotionIsDegenerate`).
    ///     🟢 FR04.009 (#184): a fixed two-level step (slots 0–1 ≈ 27.6, slots 2–4 ≈ 34.9 on EVERY
    ///     epoch) plus ±2 noise, which no cross-sample rolling floor can cancel.
    /// The two are mutually exclusive by construction: a constant run has zero intra-epoch spread, so
    /// it always `motionResolvesStillness` and can never be degenerate. Either way the run must ALSO
    /// show at least two non-zero tail epochs, exactly as before, so a genuinely motionless archive
    /// keeps the primary path.
    ///
    /// ⚠️ `constantFiller` IS DEAD CODE, AND WIDENING IT IS A MEASURED TRAP (#195 / #190). The
    /// all-or-nothing quantifier fires on **0 of the 18 sources** in the local corpus while the
    /// flat-placeholder failure it was written for is everywhere: worn-epoch placeholder share is
    /// 82–99.6 % on the Gen-2 nights and never 100 %, so a handful of getting-up epochs disqualify
    /// the whole run. It is left alone anyway, because the obvious repair is unsafe and that is
    /// MEASURED, not assumed — the `degenerate: false` branch maps the tail through a fixed p80
    /// QUANTILE (`motionIntensityFallbackMagnitudes`), a rank with no absolute floor, so widening
    /// the gate moves nights onto a mapping whose "movement" threshold is a function of the record
    /// set. Replacing the quantifier with a placeholder-SHARE threshold and re-running the corpus:
    ///   • ≥ 0.90 — 8 of 18 sources flip, staged sleep −5…−85 min. Both ground-truthed WAKE times
    ///     are unchanged, so the only labels this project has cannot adjudicate any of it.
    ///   • ≥ 0.50 — 15 of 18 move, −100…+45 min, and the SAME night (2026-08-04 22:26 → 08-05)
    ///     goes −12 min in one bundle and +45 min in another. Scope-dependent, i.e. exactly the
    ///     "the answer depends on when you synced" class #190/#191 exist to remove.
    /// This corroborates the earlier REFUTED branch `fix/motion-source-dead-primary-run`
    /// (rank-based `magnitude >= positive[p80] ? 16 : 1`, end-to-end −158/−212/−265 min and one
    /// night reduced to zero). Fixing this needs an ABSOLUTE-floor tail→magnitude mapping fitted
    /// against real labels first; the gate is the second half of that job, not the first.
    static func motionSource(_ records: [BulkRecord]) -> MotionSource {
        let worn = records.filter { $0.layout != .idle }
        guard worn.count >= 4 else { return .primary }
        let constantFiller = !worn.contains(where: { !$0.motionIsPlaceholder })
        let degenerate = constantFiller ? false : primaryMotionIsDegenerate(worn)
        guard constantFiller || degenerate else { return .primary }
        guard worn.lazy.filter({ $0.motionIntensityTail.contains(where: { $0 > 0 }) }).prefix(2).count == 2
        else { return .primary }
        return .intensityTail(degenerate: degenerate)
    }

    /// True when this run reads motion off the `[15:20]` intensity tail instead of `[10:15]`.
    static func usesMotionIntensityFallback(_ records: [BulkRecord]) -> Bool {
        if case .intensityTail = motionSource(records) { return true }
        return false
    }

    /// Minimum all-zero-tail ("the ring itself says nothing moved") epochs before the
    /// non-expressive-primary test will judge a run. 24 × `BulkRecord.epochSeconds` (150 s) = 1 h =
    /// `ActivityPeriod.minSleepDuration`: below that there is no stageable night to rescue and the
    /// statistic is too thin to trust.
    static let degenerateMinQuietEpochs = 24

    /// At most this share of those epochs may resolve stillness on the primary channel. 🟢 MEASURED
    /// EXHAUSTIVELY over every contiguous window of 9 real captures (270 029 evaluable windows):
    /// FR04.009 0.000–0.269, real Gen-2/Gen-3 0.792–1.000. 0.50 sits between, ≥0.23 clear of both.
    static let degenerateMaxQuietStillFraction = 0.50

    /// A sub-sample slot pair must keep the SAME ordering on at least this share of those epochs.
    /// Real wrist motion has no reason to prefer the 3rd–5th 30-s slot of every 2.5-min epoch, so a
    /// persistent ordering is instrumentation, not movement. 🟢 MEASURED over the same windows:
    /// FR04.009 0.833–1.000; real Gen-2/Gen-3 never exceeds 0.167.
    static let degenerateMinSlotOrderFraction = 0.75

    /// Strength of a fixed intra-epoch template: the largest share of `epochs` on which one ordered
    /// slot pair keeps the same ordering. ≈0.5 for independent noise, 0 for constant runs (every
    /// comparison ties), ≈1 for a fixed step. O(10 × n), no allocation.
    static func slotOrderConsistency(_ epochs: [BulkRecord]) -> Double {
        guard !epochs.isEmpty else { return 0 }
        var best = 0
        for j in 0 ..< 4 {
            for k in (j + 1) ..< 5 {
                var less = 0, greater = 0
                for r in epochs {
                    let a = r.raw[10 + j], b = r.raw[10 + k]
                    if a < b { less += 1 } else if b < a { greater += 1 }
                }
                best = max(best, max(less, greater))
            }
        }
        return Double(best) / Double(epochs.count)
    }

    /// True when the primary `[10:15]` channel is structurally unable to express stillness on this
    /// run, so `motionAboveLocalFloor` can never de-floor it to still and `detect()` can never reach
    /// `gravityStillFraction` — the #184 blank-card shape. Decided entirely from the run's OWN
    /// distribution, never a device label or firmware string (the Kit is generation-agnostic by
    /// design, FirmwareInfo.swift:12), by the same logic that let the Gen-3 rolling floor cancel a
    /// plateau at any level.
    ///
    /// The test CONDITIONS on the ring's own verdict: look only at epochs whose `[15:20]` intensity
    /// tail is all zero — i.e. epochs the ring itself says had no movement — and ask whether the
    /// primary channel agrees. On a healthy channel it always does (a zero-tail epoch IS a flat
    /// epoch). Two gates must both hold:
    ///   (a) fewer than `degenerateMaxQuietStillFraction` of those epochs resolve stillness — the
    ///       primary refuses to read still even where the ring says nothing moved; and
    ///   (b) the residual is a FIXED template: some slot pair keeps the same ordering on at least
    ///       `degenerateMinSlotOrderFraction` of them.
    /// Each gate separates the measured populations on its own; together they are defence in depth.
    static func primaryMotionIsDegenerate(_ worn: [BulkRecord]) -> Bool {
        let quiet = worn.filter(\.motionIntensityTailIsZero)
        guard quiet.count >= degenerateMinQuietEpochs else { return false }
        let stillCount = quiet.filter(\.motionResolvesStillness).count
        guard Double(stillCount) < Double(quiet.count) * degenerateMaxQuietStillFraction else { return false }
        return slotOrderConsistency(quiet) >= degenerateMinSlotOrderFraction
    }

    // MARK: - HRV pooling gate (#185 regression)
    //
    // #185 pools the HRV that 0x12/0x13 activity epochs carry into `samples`. On every Gen-2 and
    // Gen-3 archive that is correct — the two record templates measure the same thing. On one
    // device family they do NOT: the activity template runs ~13–20 ms LOW, 43 % of that archive's
    // HRV samples are recovered ones, and the depressed mean propagates into Apple Health, into
    // `VitalsBaseline.overnightHRV` and into the headache HRV z-score, where a new user has no
    // history to contradict it.
    //
    // Decide from the RUN'S OWN DATA whether the two populations agree, exactly as `motionSource`
    // decides which motion channel a run can use. NO ring generation, NO firmware string
    // (FirmwareInfo.swift:12). NO per-device correction: a disagreeing run simply stops pooling and
    // falls back to sleep-vitals HRV alone.

    /// Widest |HRV shift| (ms) between the two record templates that still reads as AGREEMENT.
    /// 🟢 MEASURED over 10 real archives / 3092 30-h union windows (N ≥ 20 per pool): every window
    /// on a device whose templates agree lands at |shift| ≤ 5.0; every window on the one archive
    /// whose templates disagree lands at ≥ 13.0 (p50 14.8, max 20.0). ANY threshold in [5.0, 13.0)
    /// splits the corpus perfectly; 9.0 is the midpoint, 4.0 ms clear of both classes.
    /// Independently corroborated by a matched-count permutation null (relabel the two pools inside
    /// each agreeing window, group sizes fixed, 8748 relabelings): p50 2.0 / p90 5.0 / p95 6.0 /
    /// p99 8.0 — so 9.0 sits above the null's p99 and sampling noise alone false-suppresses < 1 %
    /// of agreeing runs. ABSOLUTE, not relative: the agreeing archives stay ≤ 5.0 at sleep-HRV
    /// medians spanning 22…73 ms, while the disagreeing one is ≈ 15 ms at a 45 ms mean, so a
    /// percentage floor would have to be ~33 % and would then swallow the 22 ms-median archive.
    /// 🟡 The METHOD is measured over 10 archives; the class boundary rests on ONE archive of the
    /// disagreeing class. Re-run the union sweep against any new capture of that family before
    /// trusting this number.
    static let hrvPoolingNoiseFloorMs = 9.0

    /// Minimum epochs in EACH population before the comparison is judged at all. 🟢 MEASURED: the
    /// separation gap at the union basis is 3.0 ms at N=8, 5.0 at 12, 7.0 at 16, and **8.0 at 20**,
    /// where it saturates (unchanged at 24/30/40 while decidability falls 57 %→47 %). Below 20 the
    /// statistic is noise AND the chosen 9.0 threshold stops being safe — at N=12 an agreeing
    /// archive already reaches 8.0. The two constants are jointly, not independently, calibrated.
    /// GEN2_osa3 is the cautionary case: 8 records, 1 activity vs 2 sleep-vitals HRV values, and an
    /// unguarded shift of −18.0 ms that is pure sampling artifact. It is correctly refused.
    static let hrvPoolingMinEpochs = 20

    /// Deterministic per-side cap on the pairwise difference set — an uncapped Hodges–Lehmann is
    /// O(|a|·|b|). Stride-subsampling the SORTED pool preserves its shape and uses no RNG, so it is
    /// unit-testable. 🟢 MEASURED: caps of 32/64/128/256/512 change 0 of 3092 union-window verdicts
    /// versus uncapped, and the largest pool the 30-h union can hold on the corpus is 149, so this
    /// never binds in practice — it exists only to bound a caller that passes an unpruned set.
    static let hrvPoolingSampleCap = 512

    /// Hodges–Lehmann two-sample shift: the median of all pairwise `a - b` differences. Robust
    /// (50 % breakdown) and, unlike a difference of medians, it uses the whole distribution —
    /// 🟢 MEASURED, the difference of medians separates this corpus by 7.0 ms (2.00×) against
    /// HL's 8.0 ms (2.60×).
    static func hrvShift(_ a: [Int], _ b: [Int]) -> Double {
        func thinned(_ v: [Int]) -> [Int] {
            let s = v.sorted()
            guard s.count > hrvPoolingSampleCap else { return s }
            let step = Double(s.count) / Double(hrvPoolingSampleCap)
            return (0 ..< hrvPoolingSampleCap).map { s[Int(Double($0) * step)] }
        }
        let x = thinned(a), y = thinned(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        var diffs: [Int] = []
        diffs.reserveCapacity(x.count * y.count)
        for i in x { for j in y { diffs.append(i - j) } }
        diffs.sort()
        let n = diffs.count
        return n % 2 == 1 ? Double(diffs[n / 2])
                          : Double(diffs[n / 2 - 1] + diffs[n / 2]) / 2.0
    }

    /// Verdict of the run-level HRV pooling gate. `public` only so the drain path can log it —
    /// a silent verdict flip must be visible in a Diagnostics export, not only in a wrong number.
    public enum HRVPooling: Equatable { case agree, disagree, noEvidence }

    /// Do the two record templates' HRV populations agree on THIS run?
    ///
    /// BOTH sides are conditioned on the ring's own `[15:20]` "nothing moved" verdict. The activity
    /// side already is — that is `measuredHRVRMSSD`'s quiet gate (#184/#185) — and quieting the
    /// sleep-vitals side too is what removes the awake-vs-asleep physiology confound. 🟢 MEASURED:
    /// it lifts corpus separation from 6.5 ms (1.76×, worst agreeing archive 8.5 = flush against
    /// the noise null's p99) to 8.0 ms (2.60×, worst agreeing 5.0 = the null's p90). Do NOT
    /// "simplify" this back to comparing against all sleep-vitals epochs.
    /// Conditioning on the PRIMARY `[10:15]` channel instead was tested and rejected — it makes the
    /// FR04.009 shape undecidable, because its primary channel is the #184 degenerate template.
    /// Key on the tail, never on `[10:15]`.
    ///
    /// A calibration set with NO usable sleep-vitals pool — a ring worn only in the daytime, or a
    /// firmware that stops zeroing sleep-vitals tails — returns `.noEvidence` and therefore emits no
    /// recovered HRV at all. That floor is exactly the population the project shipped for its whole
    /// life before #185 (`hrvRMSSD` is sleep-vitals-scoped, so a daytime-only archive never had any
    /// HRV), so it is a lost improvement, never a new error. `RingSession` logs the verdict so the
    /// firmware case shows up in a Diagnostics export instead of only in a thinner Health chart.
    public static func hrvPooling(_ calibration: [BulkRecord]) -> HRVPooling {
        var act: [Int] = [], sv: [Int] = []
        for r in calibration where r.motionIntensityTailIsZero {
            if r.layout == .activity {
                if let v = r.measuredHRVRMSSD { act.append(v) }
            } else if let v = r.hrvRMSSD, v <= BulkRecord.maxPlausibleHRVMs {
                // Band-guard the REFERENCE side too. `measuredHRVRMSSD` already rejects > 200 ms, but
                // `hrvRMSSD` does not, so without this a 201…255 garbage byte could enter the
                // reference pool while being structurally unable to enter the activity pool. Garbage
                // biases the shift NEGATIVE → spurious `.disagree` → silent suppression, i.e. the
                // gate's own reference would be the thing that breaks it. Does not bind on the
                // corpus (max byte[5] is exactly 200); this guards firmware drift. (Review.)
                sv.append(v)
            }
        }
        guard act.count >= hrvPoolingMinEpochs, sv.count >= hrvPoolingMinEpochs else { return .noEvidence }
        return abs(hrvShift(act, sv)) <= hrvPoolingNoiseFloorMs ? .agree : .disagree
    }

    /// One magnitude per epoch using the same run-level signal selection as `motionTimeline`.
    /// The staging model subtracts its rolling local floor afterward, exactly as on primary motion.
    static func motionMagnitudes(from records: [BulkRecord],
                                 absoluteActiveCut: Int = motionIntensityActiveCut) -> [Float] {
        if case .intensityTail(let degenerate) = motionSource(records) {
            return motionIntensityFallbackMagnitudes(records, degenerate: degenerate,
                                                     absoluteActiveCut: absoluteActiveCut)
        }
        return records.map { record in
            Float(record.motion.reduce(0) { $0 + Int($1) })
        }
    }

    /// Convert the secondary intensity distribution into the scale shared by coarse detection and
    /// staging. Any non-zero tail remains visible as LIGHT movement in `SleepDetailMetrics`, but only
    /// a tail above `motionIntensityActiveCut` becomes motion-awake here. This keeps ordinary sleeping
    /// position shifts from becoming wake while retaining substantial, sustained movement as an
    /// awakening cue. Values deliberately straddle the existing thresholds: `1` is still/light for
    /// detection and staging, `16` is active (`motionStillThreshold == 2`, `awakeMotion == 15`).
    ///
    /// ⚠️ SINCE #197 the seam is the ABSOLUTE `motionIntensityActiveCut`, and `degenerate:` only
    /// selects between the two LEGACY per-set ranks, which are reachable solely by passing
    /// `absoluteActiveCut: 0`. Both descriptions below are therefore history — kept because they
    /// record WHY the two branches once differed, and because `0` still reproduces them exactly:
    ///   • `false` — the constant-filler branch keeps the fixed 0.80 quantile, byte for byte.
    ///   • `true` — the non-expressive-primary branch (#184) uses an Otsu two-class seam over the
    ///     same positive pool. WHY: the quantile presumes the run is ~80 % sleep. On the FR04.009
    ///     archive the tail is the ONLY movement measurement, so the run contains its awake evening
    ///     too; p80 then lands INSIDE the awake mass (🟢 measured cut 549 vs Otsu 370) and moderate
    ///     evening movement maps to `1`, which is BELOW `motionStillThreshold` — the tail's real
    ///     discriminator (0 vs > 0) becomes invisible and detection calls the evening sleep. 🟢
    ///     measured on the tester's archive: p80 detects 02:30→15:21 (12.86 h), Otsu 05:55→15:21
    ///     (9.44 h), against the ring's own onset evidence — the `[15:20]` tail-zero rate and the
    ///     sleep-vitals cadence both step at 06:00 — of ~06:00.
    /// `positive` must be sorted ascending and non-empty (the caller guarantees both).
    static func otsuIntensityCut(_ positive: [Int]) -> Int {
        let n = positive.count
        guard let last = positive.last else { return 0 }
        guard n >= 2 else { return last }
        let total = positive.reduce(0, +)
        var lowSum = 0
        var best = last
        var bestVariance = -1.0
        for i in 1 ..< n {
            lowSum += positive[i - 1]
            guard positive[i] != positive[i - 1] else { continue }   // never split a tie
            let w0 = Double(i) / Double(n), w1 = 1 - Double(i) / Double(n)
            let m0 = Double(lowSum) / Double(i)
            let m1 = Double(total - lowSum) / Double(n - i)
            let v = w0 * w1 * (m0 - m1) * (m0 - m1)
            if v > bestVariance { bestVariance = v; best = positive[i] }
        }
        return best
    }

    /// The ABSOLUTE light/active seam for the intensity tail, in raw `[15:20]` byte-sum units.
    /// **`0` restores the legacy per-set rank** (p80 / Otsu) byte-for-byte — the one-line revert.
    ///
    /// WHY AN ABSOLUTE NUMBER AT ALL (#197). Both legacy seams — the 0.80 quantile and the Otsu
    /// two-class split — are computed over `positive`, i.e. over **whatever has drained so far**. The
    /// threshold was therefore a function of sync timing, not of the wearer, and 🟢 MEASURED on
    /// 2026-08-05 (AD/Gen2) it moved 249 → 247 → 247 → 249 across consecutive 5-minute truncation
    /// cuts while two interior epochs sat exactly on it, flipping them between magnitude 1 (still)
    /// and 16 (awake) and swinging the reported night 478 · 473 · 473 · 478. A rank also FORCES a
    /// fixed share of positive epochs to be "movement" on every night — a night barely stirred and a
    /// night of thrashing both got their top 20 % called awake, which is a rank artefact, not a
    /// measurement.
    ///
    /// WHY 345, AND WHAT IT IS NOT. It is **the fixed value the per-night rank was already choosing,
    /// on average** — the median per-night legacy cut over the 16 corpus sources that stage a night
    /// is 344.5, and the primary user's own ring (AD/Gen2, n = 11) has median 343, so the number is
    /// not driven by one ring. Choosing it this way deliberately PRESERVES the operating point, which
    /// is what keeps the three calibrations fitted to this population valid
    /// (`degenerateMaxQuietStillFraction` 0.50, `degenerateMinSlotOrderFraction` 0.75,
    /// `hrvPoolingNoiseFloorMs` 9.0) and what keeps the #184 Otsu case byte-identical.
    ///
    /// 🔴 IT IS **NOT** A FITTED PHYSIOLOGICAL THRESHOLD, and must not be described as one. Fitting
    /// one was attempted and ABANDONED on the evidence: taking the primary channel's own still/active
    /// verdict as the label — the very verdict this fallback exists to substitute for — the best
    /// achievable Youden J is only **0.414** (byte-sum) / 0.441 (decoded magnitudes), the optimum is
    /// flat from 150 to 300, and the two rings with a usable label disagree (280 vs 390). That is
    /// 471 labelled epochs from 2 rings, NEITHER of them the primary user's, because a night whose
    /// primary channel is expressive enough to label is by definition not a night that needs this
    /// fallback. A real threshold needs `[15:23)`'s decoded `activityMagnitudes` and supervised
    /// labels; see #197.
    static let motionIntensityActiveCut = 345

    static func motionIntensityFallbackMagnitudes(_ records: [BulkRecord],
                                                  degenerate: Bool,
                                                  absoluteActiveCut: Int = motionIntensityActiveCut) -> [Float] {
        let sums = records.map { $0.motionIntensityTail.reduce(0) { $0 + Int($1) } }
        let positive = sums.filter { $0 > 0 }.sorted()
        guard !positive.isEmpty else { return [Float](repeating: 0, count: records.count) }
        // A fixed seam does not care how much history has drained; the legacy ranks did.
        let activeCut = absoluteActiveCut > 0 ? absoluteActiveCut : (degenerate
            ? otsuIntensityCut(positive)
            : positive[Int((Double(positive.count - 1) * 0.80).rounded())])
        return sums.map { magnitude in
            guard magnitude > 0 else { return 0 }
            return magnitude >= activeCut ? 16 : 1
        }
    }

    /// Per-epoch heart-rate timeline (the 0x4c head, byte[4] 🟢) for `detectFromMotion`'s HR gate,
    /// which rejects an awake-but-still period (a sedentary evening, sitting out late) from sleep.
    /// Built from the SAME records as `motionTimeline`, so no extra channel is threaded; idle/unworn
    /// epochs (no `heartRate`) are skipped.
    public static func heartRateTimeline(from records: [BulkRecord],
                                         epoch: Int = Command.syncEpoch) -> [HeartRateSample] {
        records.compactMap { r in
            r.heartRate.map { HeartRateSample(time: r.date(epoch: epoch), bpm: $0) }
        }
    }

    /// Timestamps of epochs on which the ring emitted SLEEP VITALS (HRV present, byte[5] 🟢) — the
    /// signal `detectFromMotion`'s sleep-vitals rescue uses to tell a moving-but-ASLEEP morning (ring
    /// still measuring sleep vitals at cadence) from true wake (the sleep-vitals stream stops). Built
    /// from the SAME records as the motion/HR timelines, so no extra channel is threaded.
    ///
    /// ⚠️ MUST keep using the strict `hrvRMSSD`, never `measuredHRVRMSSD`: this timeline IS the
    /// "ring is measuring sleep" evidence `sleepVitalsRescue` extends the night on. Quiet activity
    /// epochs carry HRV on 745 of 3679 corpus records, so feeding them here would extend nights
    /// through the awake evening/morning (#185 constraint 1).
    public static func sleepVitalTimeline(from records: [BulkRecord],
                                          epoch: Int = Command.syncEpoch) -> [Date] {
        records.compactMap { $0.hrvRMSSD != nil ? $0.date(epoch: epoch) : nil }
    }

    /// Restrict `records` to those whose epoch falls within `hint`, or return them
    /// unchanged when no hint is given. Extension point for the sleep-schedule abstraction:
    /// the app can pass the user's bedtime→wake window (see ios/OpenCircuit/SleepSchedule)
    /// so detection ignores stray daytime/charging motion outside the expected night.
    public static func records(_ records: [BulkRecord],
                               within hint: DateInterval?,
                               epoch: Int = Command.syncEpoch) -> [BulkRecord] {
        guard let hint else { return records }
        return records.filter { hint.contains($0.date(epoch: epoch)) }
    }

    /// The main sleep block (in-bed window) detected from the motion channel, or nil.
    /// Pass `within:` to bound detection to the user's scheduled sleep window (optional).
    /// Pass `temperatures:` (the night's persisted skin-temp samples) to exclude
    /// off-wrist / charging blocks from sleep (#41); empty = motion-only (unchanged).
    public static func mainSleep(from records: [BulkRecord],
                                 within hint: DateInterval? = nil,
                                 temperatures: [TemperatureSample] = [],
                                 epoch: Int = Command.syncEpoch) -> ActivityPeriod? {
        let scoped = Self.records(records, within: hint, epoch: epoch)
        let periods = ActivityPeriod.detectFromMotion(motionTimeline(from: scoped, epoch: epoch),
                                                      temperatureSamples: temperatures,
                                                      heartRateSamples: heartRateTimeline(from: scoped, epoch: epoch),
                                                      sleepVitalTimes: sleepVitalTimeline(from: scoped, epoch: epoch))
        // Clustered span (brief awakenings bridged), not just the first/longest fragment — see
        // mainSleepBlock. A drifting Gen-3 floor or a real mid-sleep stir otherwise splits the night.
        return ActivityPeriod.mainSleepBlock(periods)
    }

    /// HealthKit sleep segments for the detected night: an `inBed` span plus
    /// `asleepCore`/`awake` sub-segments from the stillness detection. Finer
    /// Light/Deep/REM staging needs an HR-based model (TODO) — the ring doesn't
    /// send a hypnogram (PROTOCOL.md §5.3), so all "asleep" is reported as core.
    /// Pass `temperatures:` to drop off-wrist / charging blocks from the night (#41).
    public static func sleepSegments(from records: [BulkRecord],
                                     within hint: DateInterval? = nil,
                                     temperatures: [TemperatureSample] = [],
                                     epoch: Int = Command.syncEpoch) -> [SleepSegment] {
        let scoped = Self.records(records, within: hint, epoch: epoch)
        // Stitch a multi-fragment night: a night handed off across several drains arrives as
        // contiguous runs separated by data gaps. Segmenting each run on its own and summing — rather
        // than taking the single longest block — keeps the whole captured night (mirrors the staged
        // path in SleepStaging.classify). A single-fragment input takes the original path verbatim.
        let frags = contiguousFragments(scoped)
        guard frags.count > 1 else {
            return sleepSegmentsContiguous(from: scoped, temperatures: temperatures, epoch: epoch)
        }
        return frags
            .flatMap { sleepSegmentsContiguous(from: $0, temperatures: temperatures, epoch: epoch) }
            .sorted { $0.start < $1.start }
    }

    /// Coarse asleep/awake segmentation of ONE contiguous record run (no internal data gaps).
    private static func sleepSegmentsContiguous(from scoped: [BulkRecord],
                                                temperatures: [TemperatureSample],
                                                epoch: Int) -> [SleepSegment] {
        let periods = ActivityPeriod.detectFromMotion(motionTimeline(from: scoped, epoch: epoch),
                                                      temperatureSamples: temperatures,
                                                      heartRateSamples: heartRateTimeline(from: scoped, epoch: epoch),
                                                      sleepVitalTimes: sleepVitalTimeline(from: scoped, epoch: epoch))
        // Main in-bed block = the clustered sleep span (brief awakenings bridged via maxSleepPause),
        // not just the longest single fragment — so a drift-fragmented Gen-3 night isn't truncated.
        guard let block = ActivityPeriod.mainSleepBlock(periods) else { return [] }

        var segs = [SleepSegment(start: block.start, end: block.end, stage: .inBed)]
        for p in periods where p.start < block.end && p.end > block.start {
            let s = max(p.start, block.start), e = min(p.end, block.end)
            if e <= s { continue }
            segs.append(SleepSegment(start: s, end: e,
                                     stage: p.activity == .sleep ? .asleepCore : .awake))
        }
        return segs
    }

    // MARK: - Light/Deep/REM staging
    //
    // ⚠️ APPROXIMATION, NOT VALIDATED PER-EPOCH. The ring sends no hypnogram (§5.3), so
    // stages are estimated from the per-epoch HR/HRV/motion signals. The model now lives
    // in `SleepStaging` (Analytics/SleepStaging.swift): HR bands are drawn from the
    // night's OWN asleep HR distribution, and REM is separated from Light by HR/HRV
    // variability (not just absolute HR). Validated only against the app's night TOTALS,
    // never per-segment timing — treat output as approximate stage proportions.
    // `sleepSegments` (coarse asleep/awake) remains the non-experimental default.

    /// Scope `records` to the most recent OVERNIGHT sleep block (± a margin) so that staging a
    /// multi-night archive UNION always describes LAST NIGHT. Without this, `SleepStaging.classify`
    /// → `mainSleep` → `findSleep` returns the EARLIEST sleep block > 1 h, so a union that still
    /// holds the prior night (retention spans > 24 h) would stage the wrong night every morning.
    /// Picks the latest-ending block that is both long enough (`minSleepDuration`) AND overnight
    /// (`SleepWindow.isOvernightBlock`), so a daytime nap never wins. Detection honours the wear
    /// gate (`temperatures`) so an off-wrist/charging block can't masquerade as the night. Returns
    /// `records` unchanged when no overnight block is found (caller stages exactly as before).
    /// Maximum gap between two sleep blocks for them to count as the SAME night. The ring buffers
    /// only ~4.75 h and drops the oldest, and a missed overnight drain leaves a hole, so one night's
    /// fragments can sit several hours apart; the PRIOR night is ~(24 h − sleep) ≈ 14 h+ away. 6 h
    /// cleanly absorbs intra-night buffer-loss gaps while never merging two different nights.
    public static let maxIntraNightGap: TimeInterval = 6 * 3600

    /// Maximum plausible span of a SINGLE night (in-bed), used to cap the night-scoping window. Even a
    /// long lie-in fits well under this. WHY: the all-day `0x03` channel fills the DAYTIME, and detection
    /// reads a sedentary worn day as "still" = sleep, so it can emit a giant block bridging daytime into
    /// the night (🟢 reproduced 2026-06-30: a 20.5 h "block" 12:33→09:07). That block's midpoint reads
    /// "overnight", so `latestNightRecords` anchored on it and chained back to the PRIOR night's tail,
    /// returning ~two nights; `classify` then stitched both into a >24 h window whose midpoint is daytime,
    /// which the overnight gate (`RingSession.overnightStagedSegments`) discards → NO sleep summary
    /// persisted. Capping the window to the latest `maxNightSpan` before the wake keeps it to one night.
    public static let maxNightSpan: TimeInterval = 14 * 3600

    /// Floor on the hole that `onsetIsUnobserved` demands: below this a gap is ordinary recording
    /// jitter, not missing data. Epoch cadence is 150 s (`BulkRecord.epochSeconds`), so contiguous
    /// recording puts the predecessor one epoch back; 450 s is three epochs.
    ///
    /// ⚠️ This is NO LONGER the load-bearing test, and the "empty band" an earlier revision claimed for
    /// it does not exist. 🟢 RE-MEASURED over the two Gen 2 Air exports of 2026-08-02 (AA55: 360 unique
    /// records; 2F9F: 533): AA55's largest interior gap all day is 2532 s, and 2F9F has real gaps at
    /// 190 / 300 / **450 / 450** / 600 / 600 / 900 / 1500 / 1800 s (the two exact-450 s ones are
    /// 08-01 18:26:33 -> 18:34:03 and 08-02 06:31:48 -> 06:39:18). So the margin on the low side is
    /// ZERO, not 23x, and gaps of 5–30 min are routine while the ring is worn. What actually keeps a
    /// morning doze out is the SIZE requirement in `onsetIsUnobserved`, which scales with how much
    /// data the presumption claims is missing and is measured in HOURS; this constant survives only as
    /// a floor for the degenerate case where a block is already nearly as long as the presumed span
    /// (there the size requirement falls to ~0 while the correction is all but inert anyway).
    public static let onsetContiguityGap: TimeInterval = 3 * TimeInterval(BulkRecord.epochSeconds)

    /// Whether `block`'s ONSET is genuinely absent from `records` — the first of the two gates on
    /// presuming a 7 h night in `SleepWindow.isOvernightBlock(start:end:onsetIsUnobserved:)`. (The
    /// second is the two-pass filter in `latestNightRecords`: the correction runs only when the plain
    /// rule accepted nothing.)
    ///
    /// THE RULE: **you may only presume data that is actually missing.** Calling a `d`-long block the
    /// tail of a `presumedTruncatedNightSpan` night asserts that `presumedTruncatedNightSpan - d` of
    /// recording was lost, so require a hole back to the previous record at least that big. A 1.5 h
    /// tail must clear 5.5 h of absence; a 4 h tail, 3 h. No record at all before the block (first-ever
    /// sync, a wiped archive) is an unbounded hole and passes.
    ///
    /// This is deliberately self-scaling: the shorter the tail, the more the presumption claims, and
    /// the more absence it must show for it. It is also what kills the reported false-positive class —
    /// a late-morning doze sitting behind a 600 s gap presumes ~6 h that plainly IS in the archive.
    ///
    /// ⚠️ Judge this against the FULL archive union, never a night-scoped slice: a slice's leading edge
    /// is an artefact of the scoping, not evidence of a hole. ⚠️ Also note the union-relative form
    /// ("start == min(all records)") is WRONG and was measured to no-op on real devices — the 30 h
    /// `EpochArchive` prunes relative to the NEWEST record, so yesterday's epochs survive and the
    /// archive minimum is a full day before the night. A truncation is a HOLE; a hole is what this
    /// looks for.
    ///
    /// ⚠️ KNOWN LIMITATION, stated rather than hidden: if the ring was ON the finger but not detecting
    /// sleep for the first half of the night it still emits epochs, so there is no hole and no
    /// correction. This gate only recovers nights whose first half was never RECORDED (missed drain,
    /// re-pair, ring off the finger with the buffer since overwritten).
    public static func onsetIsUnobserved(_ block: DateInterval,
                                         in records: [BulkRecord],
                                         epoch: Int = Command.syncEpoch) -> Bool {
        // How much absence the presumption claims. Never below the jitter floor; zero (or negative)
        // for a block already at/over the presumed span, where the `min` in `isOvernightBlock` makes
        // the correction inert anyway.
        let requiredHole = max(onsetContiguityGap,
                               SleepWindow.presumedTruncatedNightSpan - block.duration)
        guard let previous = records.map({ $0.date(epoch: epoch) })
            .filter({ $0 < block.start }).max() else {
            return true   // nothing before the block at all: an unbounded hole
        }
        return block.start.timeIntervalSince(previous) > requiredHole
    }

    public static func latestNightRecords(from records: [BulkRecord],
                                          temperatures: [TemperatureSample] = [],
                                          epoch: Int = Command.syncEpoch,
                                          morningContinuationGap: TimeInterval = morningContinuationMaxGap) -> [BulkRecord] {
        // Motion detection needs a time-ordered timeline; sort defensively so the helper is correct
        // for any caller, not only the pre-sorted EpochArchive union.
        let records = records.sorted { $0.counter < $1.counter }
        let periods = ActivityPeriod.detectFromMotion(motionTimeline(from: records, epoch: epoch),
                                                      temperatureSamples: temperatures,
                                                      heartRateSamples: heartRateTimeline(from: records, epoch: epoch),
                                                      sleepVitalTimes: sleepVitalTimeline(from: records, epoch: epoch))
        let sleepBlocks = periods.filter {
            $0.activity == .sleep && $0.duration > ActivityPeriod.minSleepDuration
        }
        // TWO-PASS. Pass 1 is HEAD's rule, unchanged. Pass 2 — the TRUNCATED-NIGHT CORRECTION — runs
        // ONLY when pass 1 accepted nothing, which is exactly the reported bug (blank Sleep card,
        // nothing in Apple Health) and nothing else.
        //
        // ⚠️ THE "ONLY WHEN EMPTY" IS LOAD-BEARING, not tidiness. `SleepWindow.isOvernightBlock`'s
        // corrected form is never LESS accepting, but this function is not monotone in it, because a
        // newly-accepted block can only push `anchor.end` LATER and everything downstream keys off
        // `anchor`:
        //   * ANCHOR EVICTION — `anchor` is the latest-ENDING night. A qualifying 11:25 -> 12:29 doze
        //     outranks a real night ending 05:00, and 6 h 25 m > `maxIntraNightGap`, so the real night
        //     is not even absorbed into the cluster: it is dropped outright.
        //   * HEAD CLIPPING — `clusterStart` is floored at `anchor.end - maxNightSpan`, so moving the
        //     anchor later moves the floor later by the same delta. A real 21:00 -> 05:00 night plus a
        //     qualifying 10:20 -> 12:20 block moves the floor to 22:20 and silently drops 21:00–21:50.
        //   * INFLATION — if the block IS within `maxIntraNightGap` it gets clustered INTO the night,
        //     staging inflates, and `SleepSummaryMerge.shouldReplace` prefers the larger asleep total,
        //     so the inflated night replaces the correct one permanently.
        // Gating on "pass 1 found nothing" makes all three impossible BY CONSTRUCTION rather than by
        // argument: whenever any real night exists, this function returns records byte-identical to
        // HEAD's. Do not hoist the correction into a single filter.
        var nights = sleepBlocks.filter { SleepWindow.isOvernightBlock(start: $0.start, end: $0.end) }
        if nights.isEmpty {
            nights = sleepBlocks.filter {
                SleepWindow.isOvernightBlock(
                    start: $0.start, end: $0.end,
                    onsetIsUnobserved: onsetIsUnobserved(DateInterval(start: $0.start,
                                                                      end: max($0.end, $0.start)),
                                                         in: records, epoch: epoch))
            }
        }
        guard let anchor = nights.max(by: { $0.end < $1.end }) else { return records }
        // Cluster the night: starting from the latest-ending overnight block, absorb EARLIER overnight
        // blocks that sit within `maxIntraNightGap` of the running cluster start, chaining backward.
        // This is what lets a night fragmented across several drains be staged as ONE night — the old
        // code kept only `anchor`, discarding every earlier fragment (a single 35-min data gap already
        // threw away ~5 h of a real 10 h night). The whole clustered span (gaps included) is returned;
        // `SleepStaging`/`sleepSegments` then stitch the fragments inside it.
        var clusterStart = anchor.start
        for p in nights.sorted(by: { $0.start > $1.start }) where p.end <= anchor.end {
            if clusterStart.timeIntervalSince(p.end) <= maxIntraNightGap {
                clusterStart = min(clusterStart, p.start)
            }
        }
        // Cap the window to ONE night: never reach back more than `maxNightSpan` before the wake. Without
        // this, an all-day-data-bridged "overnight" block (or a prior night's tail chained within
        // maxIntraNightGap) widens the window past 24 h, its midpoint lands in daytime, and the overnight
        // gate discards the whole night → no summary persisted (🟢 reproduced 2026-06-30). A real night —
        // even a long lie-in — fits inside maxNightSpan, so legitimate multi-drain stitching is untouched.
        clusterStart = max(clusterStart, anchor.end.addingTimeInterval(-maxNightSpan))
        // MORNING-CONTINUATION ABSORB. A brief arousal near the natural end of the wake window can
        // split one night into "the night" + a separate later sleep block: the later block's midpoint
        // falls past 09:00, `isOvernightBlock` rejects it as a night, and it drains away as a "nap" —
        // the user's real wake time with it. 🟢 Device case 2026-08-16 (Gen 2 Air): asleep
        // 03:44→10:30 with a ~1-min detector split at 09:04 became a 03:44→09:03 night plus an
        // 86-min 09:04→10:30 "nap"; the sleep card (which excludes naps) reported 4 h for a 6¾ h
        // night. Chain FORWARD over later sleep blocks the same way the backward pass chains earlier
        // ones, but under much stricter rules — each one keeps a real failure out:
        //   * the gap must be ≤ `morningContinuationMaxGap` (30 min — the same slop this function
        //     already grants as `margin`; the device split was ~1 min). Deliberately a small fraction
        //     of `maxIntraNightGap` (6 h): a genuine late-morning or afternoon nap keeps its hours-
        //     wide gap and stays a nap.
        //   * the extended envelope must still satisfy `isOvernightBlock`, or absorbing the tail
        //     would get the WHOLE night rejected by the downstream overnight gate — losing a real
        //     night to recover its tail is the anchor-eviction failure shape all over again.
        //   * the extension never exceeds `maxNightSpan` from the cluster start, and never moves
        //     `anchor` or the head-clip floor above — both stay keyed to the pass-1/2 anchor, so
        //     every guarantee argued for them is untouched.
        // Candidates are sleep periods ≥ `NapDetection.minNapDuration` (15 min — the APK's own
        // auto-nap floor: "naps … longer than 15 minutes", pp.txt:47434), NOT `minSleepDuration`: a bout can be
        // too short to START a night yet a perfectly real continuation of one (🟢 the device case
        // had a 32-min 08:40–09:13 bout after the arousal). Anything under the nap floor is noise.
        // Blocks are DISJOINT in time (detector output), so a plain forward scan terminates; the
        // first block that fails a rule ends the chain (any later block starts even further from
        // `clusterEnd`).
        let continuations = periods.filter {
            $0.activity == .sleep && $0.duration >= NapDetection.minNapDuration
        }
        var clusterEnd = anchor.end
        if morningContinuationGap > 0 {
            for p in continuations.sorted(by: { $0.start < $1.start }) where p.start >= anchor.end {
                guard p.start.timeIntervalSince(clusterEnd) <= morningContinuationGap,
                      p.end.timeIntervalSince(clusterStart) <= maxNightSpan,
                      SleepWindow.isOvernightBlock(start: clusterStart, end: p.end) else { break }
                clusterEnd = max(clusterEnd, p.end)
            }
        }
        let margin: TimeInterval = 30 * 60   // don't clip onset/wake at detection granularity
        let lo = clusterStart.addingTimeInterval(-margin)
        let hi = clusterEnd.addingTimeInterval(margin)
        return records.filter { let t = $0.date(epoch: epoch); return t >= lo && t <= hi }
    }

    /// Longest arousal the morning-continuation absorb in `latestNightRecords` bridges between the
    /// anchor night's end and a later same-morning sleep block. Small ON PURPOSE — the backward
    /// pass's `maxIntraNightGap` (6 h) would swallow genuine daytime naps if applied forward.
    /// Passing `morningContinuationGap: 0` (or any non-positive value) disables the absorb and is
    /// byte-identical to the pre-fix scoping (kill switch, pinned by test).
    public static let morningContinuationMaxGap: TimeInterval = 30 * 60

    /// Light/Deep/REM/Awake staging of the detected sleep block. Thin wrapper over
    /// `SleepStaging.classify` (kept for source compatibility with existing callers).
    public static func stagedSegments(from records: [BulkRecord],
                                      within hint: DateInterval? = nil,
                                      epoch: Int = Command.syncEpoch,
                                      baseline: SleepStaging.PersonalBaseline? = nil) -> [SleepSegment] {
        SleepStaging.classify(from: Self.records(records, within: hint, epoch: epoch),
                              epoch: epoch, baseline: baseline)
    }

    /// HR / HRV / SpO2 / RR samples from worn epochs, with device timestamps. Iterates ALL records
    /// (not just sleep-vitals): ALL-DAY HR rides byte[4] on activity epochs (🟢), and since #185 so
    /// do HRV (byte[5], QUIET epochs only) and RR (byte[7]) — via `measuredHRVRMSSD` /
    /// `measuredRespiratoryRate`, which exist so the recovery reaches HealthKit WITHOUT reaching
    /// sleep detection/staging/naps/stress. SpO2 stays sleep-vitals-only and always will: byte[8] IS
    /// the 0x12/0x13 activity tag, so there is no SpO2 there to recover. The idle template still
    /// yields nothing. SpO2 is a 0…1 fraction (HealthKit oxygenSaturation); HRV is the ring's RMSSD
    /// written to the SDNN type (unit-compatible; see HEALTHKIT_MAPPING.md).
    ///
    /// `calibratedBy:` is the record set the HRV POOLING GATE is judged on (`hrvPooling`) — pass the
    /// rolling `EpochArchive` union, NOT this slice. Omitting it leaves the gate inert; see the
    /// warning in the body. It gates ONLY the recovered activity-epoch HRV: HR, SpO2 and RR are
    /// emitted identically either way (RR shifts ≤ 0.06 brpm between the templates on every archive,
    /// so gating it would cost recovery for no measurable benefit).
    public static func samples(from records: [BulkRecord],
                               calibratedBy calibration: [BulkRecord]? = nil,
                               epoch: Int = Command.syncEpoch) -> [QuantitySample] {
        // #185 regression fix. `records` is ONE DRAIN'S SLICE (`RingSession.commitDrainedRecords`)
        // and is far
        // too short to judge: 🟢 MEASURED, a 1-h slice is UNDECIDABLE on 100 % of windows of all 10
        // archives, and no slice under 3 h ever decides the disagreeing one. Gating on the slice
        // alone therefore either pools the disagreeing device on essentially every short drain, or
        // suppresses 45–69 % of the agreeing devices' recovery at 4 h. So the DRAIN PATH passes the
        // 30-h `EpochArchive` union as `calibration` and this emits from the slice — 🟢 MEASURED on
        // that basis: 0.0 % wrong POOL on the disagreeing archive and 0.0 % wrong SUPPRESS on all
        // eight agreeing ones, over every look-back window. Undecided ⇒ SUPPRESS: measured on a
        // cold start, default-open still leaks −2.77 ms into the disagreeing device's first day —
        // the exact day that becomes its `VitalsBaseline.overnightHRV` — while default-closed costs
        // the agreeing devices only a one-time 4.7–27.1 % of their RECOVERED half during warm-up
        // (0.0 % after the first decision, 0.0 % at a 24 h cadence).
        //
        // ⚠️ `calibration == nil` leaves the gate INERT (pre-gate behaviour). It exists only so the
        // fixture/RE callers that pass a SINGLE record — `RingKitVerify`'s #185 block,
        // `BulkSleepTests.testQuietActivityEpochRecoversHRVAndRR` — keep asserting the #185 recovery
        // itself, which no calibration set of one record could ever decide. EVERY PATH THAT REACHES
        // APPLE HEALTH MUST PASS A CALIBRATION SET. There is exactly one such path today and it does
        // (`RingSession.commitDrainedRecords`); `HRVPoolingGateTests.testNilCalibrationLeavesGateInert`
        // pins this default so it stays a documented contract rather than an accident.
        return samples(from: records,
                       verdict: calibration.map { hrvPooling($0) } ?? .agree,
                       epoch: epoch)
    }

    /// `samples` with an ALREADY-RESOLVED pooling verdict.
    ///
    /// Exists because the verdict must be able to carry MEMORY, which a pure function over one
    /// calibration set cannot: `hrvPooling` is recomputed from a 30-h rolling union on every commit,
    /// and `commitDrainedRecords` has three call sites, so without memory one night's epochs can be
    /// committed under two different verdicts — a nightly HRV mean that is an artifact of BGTask
    /// scheduling rather than of the night. Worse, both pools are conditioned on the ring's quiet
    /// tail, so `.noEvidence` correlates with restlessness — the very physiology being measured —
    /// and the SyncCursor is a forward high-water mark, so a suppressed slice is never re-offered.
    /// `RingSession` therefore persists the last DECIDED verdict per ring and treats `.noEvidence`
    /// as "keep the previous decision" rather than "suppress". (Adversarial review.)
    public static func samples(from records: [BulkRecord],
                               verdict: HRVPooling,
                               epoch: Int = Command.syncEpoch) -> [QuantitySample] {
        let poolActivityHRV = verdict == .agree
        var out: [QuantitySample] = []
        for r in records {
            let t = r.date(epoch: epoch)
            if let hr = r.heartRate {
                out.append(QuantitySample(kind: .heartRate, start: t, value: Double(hr)))
            }
            // Sleep-vitals HRV is NEVER gated: that is the pre-#185 population (modulo the ≤200 ms
            // band guard, which 🟢 MEASURED drops 0 of the corpus's 1541 sleep-vitals HRV bytes),
            // and it is pinned by StrictVitalsPinningTests. Only the RECOVERED activity-epoch half
            // waits on the run's verdict.
            if let hrv = r.measuredHRVRMSSD, r.layout == .sleepVitals || poolActivityHRV {
                out.append(QuantitySample(kind: .hrvSDNN, start: t, value: Double(hrv)))
            }
            if let spo2 = r.spo2Percent {                    // UNCHANGED (#185 constraint 2)
                out.append(QuantitySample(kind: .spo2, start: t, value: Double(spo2) / 100.0))
            }
            if let rr = r.measuredRespiratoryRate {
                out.append(QuantitySample(kind: .respiratoryRate, start: t, value: rr))
            }
        }
        return out
    }
}

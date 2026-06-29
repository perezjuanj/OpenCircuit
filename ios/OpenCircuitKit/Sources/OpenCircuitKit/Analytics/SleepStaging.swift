// Sleep-stage classifier — Awake / Light / Deep / REM from the 0x4c per-epoch
// signals (PROTOCOL.md §5.3). The ring does NOT transmit a hypnogram; the RingConn
// app computes stages on-device from the same vitals we decode, so we approximate
// that proprietary algorithm here with standard consumer-wearable heuristics.
//
// ⚠️ APPROXIMATION, NOT GROUND TRUTH. We have no PSG (or even per-epoch app) labels —
// only the app's NIGHT TOTALS to sanity-check against (see the night of 2026-06-14:
// asleep 7:37, awake 43m, REM 1:42, light 4:45, deep 1:10). So this is tuned to be
// physiologically principled and to roughly partition a night the way a wrist/ring
// tracker would; it is NOT validated to reproduce per-epoch stage timing, and the
// exact Deep/REM split should be read as approximate proportions, not a clinical
// hypnogram.
//
// Signals per 150 s epoch (forward-filled across epochs that drop a reading):
//   • HR  [4]  — the spine of the model. Stage bands are set from the NIGHT'S OWN HR
//                distribution (percentiles of the asleep HR), never absolute bpm, so
//                it generalises across people and nights.
//   • HRV [5]  — RMSSD; fused in as a secondary REM cue via its short-term variability.
//   • motion [10:15] — the awake signal (a moving sleeper is awake).
//
// Awake is decided FIRST, and from HR as well as motion: an epoch is awake when its
// motion exceeds the threshold OR its smoothed HR sits a margin above the night's
// sleeping floor. That HR gate is the fix for "lying still but awake" — the motion
// still-block alone counts pre-sleep / quiet-morning wakefulness as sleep, so the
// in-bed window starts hours early and a low-movement morning wake is missed. Sleep
// ONSET/OFFSET are then the start of the first, and end of the last, SUSTAINED asleep
// run; leading/trailing in-bed time outside that span is kept as AWAKE-IN-BED (it is
// time in bed, just not asleep — RingConn's two-window model, efficiency = asleep /
// time-in-bed), never counted as sleep. (REM and quiet wake
// overlap in HR, so the wake margin is set deliberately wide — above REM elevation —
// and short HR-only awake runs erode back to asleep so a REM bump can't punch a hole.)
//
// Stage logic, per asleep epoch:
//   • Deep  — HR near the night's minimum (low percentile) AND low HR variability AND
//             no motion: the calm, consolidated low-HR troughs.
//   • REM   — HR elevated toward waking OR HR/HRV notably variable, but motion ~0
//             (muscle atonia). Variability — not absolute HR — is what separates REM
//             from Light, matching the physiology.
//   • Light — everything else asleep (the remainder).
// Bands are percentiles of the TRIMMED (in-window) asleep distribution, so pre-sleep
// wakefulness no longer pollutes them. Stages persist in real sleep, so short Deep/REM
// runs are smoothed back to Light to avoid single-epoch flapping.

import Foundation

/// Stage-by-stage classifier over a night's `0x4c` `BulkRecord`s. Pure/testable:
/// it takes records, returns `[SleepSegment]`, and touches no I/O.
public enum SleepStaging {

    /// Tunable thresholds. All HR/variability cut-offs are PERCENTILES of the night's
    /// own asleep distribution (plus small absolute floors), so they adapt per night
    /// rather than baking in fixed bpm. The Deep/REM percentile defaults were CALIBRATED
    /// (2026-06-20) against a Helio strap hypnogram (06-20: Deep 19% / Light 55% / REM 26%)
    /// and the RingConn app's 06-14 totals (Deep 15% / Light 62% / REM 22%), validated to
    /// give physiological proportions across four decoded nights. Deep is keyed off HR
    /// FLATNESS (low variability) as much as low HR — real light sleep carries HR jitter,
    /// which is what keeps it out of Deep; a too-strict deepHRPercentile collapsed Deep to
    /// a few minutes on real (flat-HR) nights.
    public struct Tuning: Sendable, Equatable {
        /// Motion magnitude (sum of non-baseline `[10:15]` counts over the epoch) above
        /// which the epoch is Awake. Baseline `01` contributes 0.
        public var awakeMotion: Int
        /// Lower HR percentile (of asleep epochs) bounding Deep — near the night's floor.
        public var deepHRPercentile: Double
        /// Upper HR percentile bounding "HR elevated toward waking" → a REM cue.
        public var remHRPercentile: Double
        /// HR-variability percentile below which an epoch is "calm enough" for Deep.
        public var deepVarPercentile: Double
        /// HR-variability percentile above which an epoch is "variable" → a REM cue.
        public var remVarPercentile: Double
        /// Half-window (epochs each side) for the rolling HR/HRV variability estimate.
        public var variabilityHalfWindow: Int
        /// Non-degeneracy floor for the Deep variability gate, so a flat night still admits
        /// Deep. NOTE: this is on the *blended* variability scale (HR rolling-SD plus
        /// `hrvVarWeight`×HRV rolling-SD), not raw bpm — the threshold is `max(percentile, floor)`
        /// over that same blended pool, so the floor only binds on near-zero-variance nights.
        public var deepVarFloor: Double
        /// Non-degeneracy floor for the REM variability gate (blended scale; see deepVarFloor).
        public var remVarFloor: Double
        /// Minimum consolidated run length (epochs) for Deep; shorter → relabelled Light.
        public var minDeepRunEpochs: Int
        /// Minimum consolidated run length (epochs) for REM; shorter → relabelled Light.
        public var minREMRunEpochs: Int
        /// Minimum Awake run; shorter motion blips inside sleep → relabelled Light.
        public var minAwakeRunEpochs: Int
        /// Weight of HRV short-term variability fused into the variability score (0 = HR
        /// only). Only contributes on epochs where HRV is present.
        public var hrvVarWeight: Double
        /// Weight of respiratory-rate short-term variability fused into the variability
        /// score (0 = no RR contribution). Mirrors `hrvVarWeight` exactly: it adds
        /// `rrVarWeight × rollingSD(RR)` to the blended variability scale, and only on
        /// epochs where RR is present. RingConn's on-device staging fuses RR (APK RE), but
        /// the exact weight is not recoverable from their binary, so this defaults to 0 —
        /// byte-identical output to the pre-RR model — and is meant to be SUPERVISED-FIT
        /// against captured RingConn labels before being raised.
        public var rrVarWeight: Double

        // --- HR-aware wake / onset-offset (the "still but awake" fix) --------------
        // The motion still-block alone counts lying-still-but-awake as sleep, so the
        // in-bed window can start hours before real sleep onset and a quiet morning
        // wake (little movement) is missed. These gate sleep on HR: a sleeper's HR sits
        // near the night's floor; awake/active HR rides well above it.

        /// Low percentile of the block's HR taken as the night's SLEEPING FLOOR. Robust:
        /// even a window polluted by pre-sleep wake has a real sleep core at the bottom,
        /// so the floor is stable where a high percentile (the thing we're detecting)
        /// would not be.
        public var sleepFloorPercentile: Double
        /// bpm above the sleeping floor at which a (smoothed) epoch counts as awake.
        /// Deliberately set ABOVE typical REM elevation — REM and quiet wake overlap in
        /// HR, so the seam is wide; sustained wake (pre-sleep activity, the morning rise)
        /// clears it while a REM bump does not. The single most validation-sensitive knob;
        /// retune against a captured night with known bed/wake times.
        public var wakeHRMarginBPM: Double
        /// Half-window (epochs each side) for the rolling-MEDIAN HR used by the wake gate,
        /// so a one-epoch HR spike doesn't read as an awakening.
        public var hrWakeHalfWindow: Int
        /// A sustained asleep run of at least this many epochs anchors sleep ONSET (its
        /// start) and OFFSET (the end of the last such run). Leading/trailing awake outside
        /// that span is trimmed from the in-bed window — this is what shrinks an over-wide
        /// motion window back to the real night.
        public var onsetSustainEpochs: Int
        /// Minimum length of an HR-ONLY-driven interior awake run; shorter ones erode back
        /// to asleep so a transient REM-ish HR bump can't punch a hole in sleep. Motion-
        /// driven awake epochs are exempt (a real movement is awake however brief).
        public var minHRWakeRunEpochs: Int

        // --- Descent-relative ONSET trim (the "mild wind-down" fix) -----------------
        // The fixed `wakeHRMarginBPM` gate (floor + 18) catches a CLEARLY elevated pre-sleep
        // block (lying in bed at 78 bpm) but MISSES the common case: HR drifting down from a
        // calm-evening level (~65) through the quiet wind-down (~55–60) into sleep (~50) — all
        // of it BELOW floor+18, so the whole pre-sleep stretch reads as asleep and efficiency
        // pins at an impossible ~100%. These knobs add a SECOND, leading-edge-only onset rule
        // keyed to the night's OWN HR descent: onset is where smoothed HR first SETTLES near the
        // floor (a fraction of the way down from the evening level) and stays there. It scales
        // per person/night (a fast sleeper with no descent is untouched) and is bounded on both
        // ends — gated on a real descent, searched only within the first window — so it can never
        // run away and trim genuine sleep as wake. Validated 2026-06-26 against a Helio strap
        // (onset matched within ~20 min) plus the night's stored summaries; SUPERVISED-FIT
        // territory, so every knob is exposed.

        /// Fraction of the evening→floor HR descent at which (smoothed) HR is taken to have
        /// "settled" into sleep. Onset band = floor + fraction × (eveningLevel − floor). Lower =
        /// stricter (band nearer the floor) → onset later / trims more. 0 disables the band move
        /// (band == floor); raise toward 1 to trim only the most elevated wind-down.
        public var onsetSettleFraction: Double
        /// Minimum evening→floor descent (bpm) for the onset trim to fire at all. Below this there
        /// is no real wind-down to trim (the sleeper was already calm at lights-out), so the night
        /// is left byte-identical to the pre-onset-trim model. The single safety gate that keeps a
        /// flat night — where the band would otherwise cut through ordinary sleep — untouched.
        public var onsetMinDescentBPM: Double
        /// Epochs at the window head used to estimate the pre-sleep "evening level" (their median,
        /// robust to a one-epoch spike). ~12 ≈ the first 30 min in bed.
        public var onsetScanEpochs: Int
        /// The onset settle is sought ONLY within the first this-many epochs of the window; if HR
        /// never sustains below the band that early, the night is NOT trimmed (no onset guessed).
        /// Bounds the trim so a restless night that only quiets hours in can't be declared
        /// "awake until 2 a.m." ~48 ≈ 2 h.
        public var onsetSearchEpochs: Int

        // --- Lead-in wake ONSET (the "lay awake still for hours" fix) ----------------
        // The descent trim above keys off a clean HR DESCENT into the floor. But the hardest night
        // is lying still and AWAKE for hours with FLUCTUATING HR (the 2026-06-26 capture: HR bouncing
        // 58–99 with a clear ~90-bpm block near midnight, then sleep ~01:30). The fixed/descent gates
        // mark the clearly-elevated epochs awake, but the SHORT still dips between them read as
        // "asleep", so onset anchors to the FIRST such dip — hours before real sleep. This rule says:
        // if a SUSTAINED awake block still lies ahead within the onset search window, sleep hasn't
        // begun — push onset past the END of the LAST such block. It reuses the already-validated
        // awake detection (motion + HR gate), so it only ever moves onset past epochs ALREADY judged
        // awake, never invents wake from a quiet signal.

        /// A consolidated asleep run of at least this many epochs BEFORE a lead-in wake block means the
        /// block is a normal mid-night awakening (real sleep already happened) — so onset is NOT pushed
        /// past it. Only when no real sleep preceded the block (longest prior asleep run < this) is the
        /// block treated as part of a pre-sleep struggle. The single guard that keeps a normal night —
        /// asleep early, one brief stir — untouched. ~16 ≈ a 40-min first cycle.
        public var minConsolidatedSleepEpochs: Int

        /// When a `PersonalBaseline` is supplied to `classify`, an epoch may be DEEP only if its HR
        /// is within this many bpm of the person's TYPICAL deep-sleep HR. This caps Deep on a
        /// STRONGLY-ELEVATED night (fever, illness), whose OWN low percentile would otherwise admit
        /// "Deep" at an HR that is not deep for this person. Set DELIBERATELY WIDE so it never strips
        /// genuine Deep on a merely MILDLY-elevated night that still had real deep sleep (a hard
        /// training day, a warm room, a glass of wine run ~10–15 bpm high but still reach deep) — only
        /// a clearly anomalous night (≳ this margin above the personal floor) is suppressed. It only
        /// ever REMOVES Deep, never adds it, and is ignored entirely when no baseline is supplied, so
        /// the single-night classifier is byte-identical (the property is inert without a baseline).
        public var deepBaselineMarginBPM: Double

        public init(awakeMotion: Int = 15,
                    deepHRPercentile: Double = 0.42,
                    remHRPercentile: Double = 0.86,
                    deepVarPercentile: Double = 0.50,
                    remVarPercentile: Double = 0.84,
                    variabilityHalfWindow: Int = 2,
                    deepVarFloor: Double = 2.5,
                    remVarFloor: Double = 3.0,
                    minDeepRunEpochs: Int = 3,
                    minREMRunEpochs: Int = 2,
                    minAwakeRunEpochs: Int = 1,
                    hrvVarWeight: Double = 0.5,
                    rrVarWeight: Double = 0,
                    sleepFloorPercentile: Double = 0.12,
                    wakeHRMarginBPM: Double = 18,
                    hrWakeHalfWindow: Int = 2,
                    onsetSustainEpochs: Int = 6,
                    minHRWakeRunEpochs: Int = 5,
                    onsetSettleFraction: Double = 0.35,
                    onsetMinDescentBPM: Double = 10,
                    onsetScanEpochs: Int = 12,
                    onsetSearchEpochs: Int = 48,
                    minConsolidatedSleepEpochs: Int = 16,
                    deepBaselineMarginBPM: Double = 18) {
            self.awakeMotion = awakeMotion
            self.deepHRPercentile = deepHRPercentile
            self.remHRPercentile = remHRPercentile
            self.deepVarPercentile = deepVarPercentile
            self.remVarPercentile = remVarPercentile
            self.variabilityHalfWindow = variabilityHalfWindow
            self.deepVarFloor = deepVarFloor
            self.remVarFloor = remVarFloor
            self.minDeepRunEpochs = minDeepRunEpochs
            self.minREMRunEpochs = minREMRunEpochs
            self.minAwakeRunEpochs = minAwakeRunEpochs
            self.hrvVarWeight = hrvVarWeight
            self.rrVarWeight = rrVarWeight
            self.sleepFloorPercentile = sleepFloorPercentile
            self.wakeHRMarginBPM = wakeHRMarginBPM
            self.hrWakeHalfWindow = hrWakeHalfWindow
            self.onsetSustainEpochs = onsetSustainEpochs
            self.minHRWakeRunEpochs = minHRWakeRunEpochs
            self.onsetSettleFraction = onsetSettleFraction
            self.onsetMinDescentBPM = onsetMinDescentBPM
            self.onsetScanEpochs = onsetScanEpochs
            self.onsetSearchEpochs = onsetSearchEpochs
            self.minConsolidatedSleepEpochs = minConsolidatedSleepEpochs
            self.deepBaselineMarginBPM = deepBaselineMarginBPM
        }

        public static let `default` = Tuning()
    }

    /// A person's rolling, multi-night HR baseline. RingConn's on-device staging is believed to key its
    /// stages off multi-day personalized baselines (🟡 probable — `hrAvg7Days`/`hrvAvg7Days` fields read
    /// from the v3.2.1 APK data model; exact use + thresholds NOT recoverable, see memory
    /// `ringconn-sleep-is-on-device`), where ours historically used single-night percentiles only. A
    /// single-night percentile is fragile on an
    /// ATYPICAL night: when the WHOLE night runs elevated (fever, alcohol, illness), the night's own
    /// lowest epochs still look "deep" relative to that night, so Deep is assigned at an HR that is not
    /// deep for the person. Anchoring the Deep band to the person's typical deep-sleep HR fixes that.
    /// Optional everywhere — absent it, staging is exactly the single-night classifier as before.
    public struct PersonalBaseline: Sendable, Equatable {
        /// The person's TYPICAL deep-sleep heart rate (bpm), across recent nights — the personal
        /// "sleeping floor" the Deep band anchors to (see `Tuning.deepBaselineMarginBPM`).
        public let deepSleepHR: Double

        public init(deepSleepHR: Double) { self.deepSleepHR = deepSleepHR }

        /// Build from recent nights' per-night deep-sleep HR means (e.g. `StoredSleepSummary.hrDeep`).
        /// Uses the MEDIAN — robust to a single outlier night (a fever night, or a night with no real
        /// Deep) — and ignores non-positive entries (a night with no detected Deep contributes nothing).
        /// Returns `nil` when fewer than `minNights` valid nights exist: too little history to
        /// personalize, so the caller stays on single-night staging until the baseline is trustworthy.
        public static func fromRecentDeepHR(_ deepHRs: [Int], minNights: Int = 3) -> PersonalBaseline? {
            let valid = deepHRs.filter { $0 > 0 }.map(Double.init).sorted()
            guard valid.count >= minNights else { return nil }
            // True median (average the two central values for an even count) — an upper-median would
            // bias the ceiling upward (weaker suppression) on the common even-count windows.
            let mid = valid.count / 2
            let median = valid.count.isMultiple(of: 2) ? (valid[mid - 1] + valid[mid]) / 2 : valid[mid]
            return PersonalBaseline(deepSleepHR: median)
        }
    }

    /// Per-stage durations for a night, plus convenience totals. `inBed` is the whole
    /// detected window; `totalAsleep` excludes Awake (and the overlapping inBed span).
    public struct Summary: Equatable, Sendable {
        public let inBed: TimeInterval
        public let awake: TimeInterval
        public let light: TimeInterval
        public let deep: TimeInterval
        public let rem: TimeInterval

        public init(inBed: TimeInterval, awake: TimeInterval,
                    light: TimeInterval, deep: TimeInterval, rem: TimeInterval) {
            self.inBed = inBed; self.awake = awake
            self.light = light; self.deep = deep; self.rem = rem
        }

        /// Time actually asleep = Light + Deep + REM.
        public var totalAsleep: TimeInterval { light + deep + rem }
        /// Sleep efficiency = asleep / in-bed, 0…1 (0 if no in-bed window).
        public var efficiency: Double { inBed > 0 ? totalAsleep / inBed : 0 }

        /// The same numbers in whole minutes, handy for dashboards/sanity checks.
        public var minutes: (inBed: Int, awake: Int, light: Int, deep: Int, rem: Int, asleep: Int) {
            func m(_ t: TimeInterval) -> Int { Int((t / 60).rounded()) }
            return (m(inBed), m(awake), m(light), m(deep), m(rem), m(totalAsleep))
        }
    }

    /// Classify a night's records into `inBed` + Awake/Light(core)/Deep/REM segments.
    /// Returns `[]` when no sleep block (≥1 h still) is detected.
    ///
    /// STITCHING: a night handed off across several drains (the ring buffers only ~4.75 h and drops
    /// the oldest; each sync drains a partial slice) arrives as CONTIGUOUS runs separated by data gaps.
    /// Each run is staged independently and the segments concatenated, so the whole captured night is
    /// kept — not just one block. Without this, a single gap split the night and only the latest
    /// fragment survived (the "sleep shrinks on every sync" bug). Each fragment carries its own `inBed`
    /// segment (gaps are NOT counted as in-bed); `summary` sums them. A single-fragment input (every
    /// existing caller of a contiguous night, and every unit test) is staged exactly as before.
    public static func classify(from records: [BulkRecord],
                                epoch: Int = Command.syncEpoch,
                                tuning: Tuning = .default,
                                baseline: PersonalBaseline? = nil) -> [SleepSegment] {
        let frags = BulkSleep.contiguousFragments(records)
        guard frags.count > 1 else {
            return classifyContiguous(from: records, epoch: epoch, tuning: tuning, baseline: baseline)
        }
        return frags
            .flatMap { classifyContiguous(from: $0, epoch: epoch, tuning: tuning, baseline: baseline) }
            .sorted { $0.start < $1.start }
    }

    /// Stage ONE contiguous record run (no internal data gaps) into `inBed` + stage segments.
    private static func classifyContiguous(from records: [BulkRecord],
                                           epoch: Int = Command.syncEpoch,
                                           tuning: Tuning = .default,
                                           baseline: PersonalBaseline? = nil) -> [SleepSegment] {
        guard let block = BulkSleep.mainSleep(from: records, epoch: epoch) else { return [] }

        // Epochs inside the in-bed window, forward-filling HR/HRV across dropped reads.
        let inBlock = records
            .filter { $0.date(epoch: epoch) >= block.start && $0.date(epoch: epoch) <= block.end }
            .sorted { $0.counter < $1.counter }
        var lastHR: Int?, lastHRV: Int?, lastSpo2: Int?, lastRR: Double?
        var rows: [(time: Date, hr: Int, hrv: Int?, motion: Int, spo2: Int?, rr: Double?)] = []
        // Per-epoch motion energy is measured ABOVE a LOCAL idle floor (same rolling estimate as
        // detection). Gen 2 idles at ~1, Gen 3 at ~15–16 and DRIFTS across the night with posture
        // (16→24→39, 🟢 FR05.008 capture 2026-06-23). The old `$1 == 1 ? 0 : …` hard-coded Gen 2's
        // flat `1`, so every still Gen-3 epoch summed to ~75 and the `awakeMotion` gate marked the
        // WHOLE night awake → `sleepSpan` found nothing → no staged segments. De-flooring against the
        // local rolling floor stays a no-op for Gen 2 (flat `1` → 0) while tracking Gen-3 drift.
        let times = inBlock.map { $0.date(epoch: epoch) }
        let rawMotion = inBlock.map { Float($0.motion.reduce(0) { $0 + Int($1) }) }
        let floor = ActivityPeriod.rollingLowPercentile(rawMotion, times: times,
                        windowSeconds: ActivityPeriod.motionFloorWindowSecondsStaging,
                        percentile: ActivityPeriod.motionFloorPercentile)
        for (idx, r) in inBlock.enumerated() {
            if let hr = r.heartRate { lastHR = hr }
            if let v = r.hrvRMSSD { lastHRV = v }
            if let s = r.spo2Percent { lastSpo2 = s }       // forward-filled like HRV
            if let rr = r.respiratoryRate { lastRR = rr }   // forward-filled like HRV
            guard let hr = lastHR else { continue }   // skip until the first HR reading
            let motion = max(0, Int(rawMotion[idx] - floor[idx]))
            rows.append((r.date(epoch: epoch), hr, lastHRV, motion, lastSpo2, lastRR))
        }
        guard rows.count >= 2 else { return [] }

        // --- Variability (rolling SD of HR, optionally fused with HRV) -------------
        let hr = rows.map { Double($0.hr) }
        var variability = rollingSD(hr, half: tuning.variabilityHalfWindow)
        if tuning.hrvVarWeight > 0, rows.contains(where: { $0.hrv != nil }) {
            let hrv = filledForward(rows.map { $0.hrv }).map { Double($0 ?? 0) }
            let hrvVar = rollingSD(hrv, half: tuning.variabilityHalfWindow)
            for i in variability.indices { variability[i] += tuning.hrvVarWeight * hrvVar[i] }
        }
        // Respiratory-rate variability, fused identically to the HRV term above. Defaults
        // off (rrVarWeight == 0) so the blended variability — and every stage decision —
        // is byte-identical to the pre-RR model until the weight is fit.
        if tuning.rrVarWeight > 0, rows.contains(where: { $0.rr != nil }) {
            let rr = filledForward(rows.map { $0.rr }).map { $0 ?? 0 }
            let rrVar = rollingSD(rr, half: tuning.variabilityHalfWindow)
            for i in variability.indices { variability[i] += tuning.rrVarWeight * rrVar[i] }
        }

        // --- HR-aware AWAKE: motion OR sustained HR elevation ----------------------
        // The motion still-block treats "lying still but awake" as sleep, so on its own
        // the in-bed window starts before real onset and a quiet morning wake is missed.
        // Gate on HR: awake/active HR rides well above the night's sleeping floor.
        let sleepFloor = percentile(hr.sorted(), tuning.sleepFloorPercentile)
        let wakeThreshold = sleepFloor + tuning.wakeHRMarginBPM
        let smHR = rollingMedian(hr, half: tuning.hrWakeHalfWindow)
        let motionAwake = rows.map { $0.motion > tuning.awakeMotion }
        var awake = rows.indices.map { smHR[$0] >= wakeThreshold || motionAwake[$0] }
        // Erode HR-only awake runs shorter than the floor so a transient REM-ish HR bump
        // doesn't read as an awakening (motion-driven awakes are kept, however brief).
        erodeShortHRWake(&awake, motionAwake: motionAwake, minRun: tuning.minHRWakeRunEpochs)

        // --- Descent-relative onset: trim the quiet pre-sleep wind-down -------------
        // Mark the LEADING in-bed stretch as awake while HR is still settling DOWN toward the
        // night's floor — the calm-but-awake wind-down that sits below floor+18 and so slips
        // past the gate above (pinning efficiency at ~100%). Leading-edge only and bounded; a
        // night with no real descent is left untouched. Runs AFTER erosion so it isn't undone.
        markDescentOnsetAwake(&awake, smHR: smHR, motionAwake: motionAwake,
                              floor: sleepFloor, tuning: tuning)

        // --- Lead-in wake onset: push past a clear pre-sleep wake block -------------
        // Handles the "lay still but awake for hours, fluctuating HR" night the descent trim misses:
        // if a sustained awake block still lies ahead in the search window (and no real sleep preceded
        // it), onset hasn't happened yet — mark everything up to that block's end as awake-in-bed.
        markLeadInWakeOnset(&awake, tuning: tuning)

        // --- ONSET / OFFSET: trim leading & trailing awake -------------------------
        // The kept window runs from the start of the first SUSTAINED asleep run to the
        // end of the last one; everything outside is pre-sleep / post-wake awake-in-bed
        // and is dropped. This is what shrinks an over-wide motion window (e.g.
        // 23:01→09:34 with hours of quiet wakefulness) back to the real night.
        guard let (lo, hi) = sleepSpan(awake, sustain: tuning.onsetSustainEpochs) else { return [] }
        let windowStart = rows[lo].time
        let windowEnd = (hi + 1 < rows.count) ? rows[hi + 1].time : block.end

        // --- Night-relative bands from the IN-WINDOW asleep distribution -----------
        // Computed over [lo, hi] asleep epochs only, so trimmed pre-sleep wakefulness no
        // longer pollutes the percentiles (which previously dragged the bands up and
        // collapsed Deep to a few minutes).
        let windowIdx = Array(lo...hi)
        let asleepIdx = windowIdx.filter { !awake[$0] }
        let pool = asleepIdx.count >= 4 ? asleepIdx : windowIdx
        let hrPool = pool.map { hr[$0] }.sorted()
        let varPool = pool.map { variability[$0] }.sorted()

        let deepHR = percentile(hrPool, tuning.deepHRPercentile)
        let remHR = percentile(hrPool, tuning.remHRPercentile)
        let deepVar = max(percentile(varPool, tuning.deepVarPercentile), tuning.deepVarFloor)
        let remVar = max(percentile(varPool, tuning.remVarPercentile), tuning.remVarFloor)

        // --- Per-epoch decision (over the kept window) -----------------------------
        // Personal-baseline DEEP ceiling: with a multi-night baseline, an epoch may be Deep only if its
        // HR is within `deepBaselineMarginBPM` of the person's typical deep-sleep HR. nil baseline ⇒ no
        // ceiling ⇒ byte-identical to the single-night classifier. Only ever REMOVES Deep (relabels to
        // REM/Light by the same rules below), so a globally-elevated night can't read its non-deep
        // troughs as Deep just because they're the lowest THAT night.
        let deepCeiling = baseline.map { $0.deepSleepHR + tuning.deepBaselineMarginBPM }
        var stages: [SleepStage] = windowIdx.map { i in
            if awake[i] { return .awake }
            // A calm, low-variability trough is deep-LIKE by the night's own bands.
            if hr[i] <= deepHR && variability[i] <= deepVar {
                // It's real Deep only if also near the PERSON's deep HR (when a baseline exists). A calm
                // trough too elevated for this person is NOT Deep — but it is Light, NOT REM: REM needs
                // HR elevation OR variability, and this epoch is flat. Returning Light here (rather than
                // letting it fall through to the REM test, where a flat elevated night has remHR ≈ the
                // flat HR and the whole night would absurdly read as REM) keeps the relabel physiological.
                let nearPersonalDeep = deepCeiling.map { hr[i] <= $0 } ?? true
                return nearPersonalDeep ? .asleepDeep : .asleepCore
            }
            if hr[i] >= remHR || variability[i] > remVar { return .asleepREM }
            return .asleepCore
        }
        smooth(&stages, tuning)

        // --- Emit segments tiling the FULL motion (time-in-bed) window -------------
        // RingConn's two-window model: the BEDTIME window [block.start, block.end] is the
        // full time in bed; the HR-trimmed SLEEP window [windowStart, windowEnd] is
        // onset→final-wake. Efficiency = time-asleep / time-in-bed, so inBed MUST be the
        // full bedtime window — the pre-onset and post-offset spans are awake-IN-BED, not
        // dropped (dropping them inflated efficiency to ~100%). The returned segments tile
        // [block.start, block.end] with no gaps/overlaps:
        //   [inBed(full)] + [pre-awake?] + [onset→offset staged] + [post-awake?].
        var segs = [SleepSegment(start: block.start, end: block.end, stage: .inBed)]
        // Pre-sleep awake-in-bed: lying in bed before real onset.
        if windowStart > block.start {
            segs.append(SleepSegment(start: block.start, end: windowStart, stage: .awake))
        }
        var k = 0
        while k < windowIdx.count {
            var j = k
            while j + 1 < windowIdx.count && stages[j + 1] == stages[k] { j += 1 }
            // Fully tile [windowStart, windowEnd] so staged segments partition the sleep
            // window (else efficiency is mis-stated): clamp the first segment's start to
            // windowStart and the last segment's end to windowEnd.
            let segStart = (k == 0) ? windowStart : rows[windowIdx[k]].time
            let segEnd = (j + 1 < windowIdx.count) ? rows[windowIdx[j + 1]].time : windowEnd
            segs.append(SleepSegment(start: segStart, end: min(segEnd, windowEnd), stage: stages[k]))
            k = j + 1
        }
        // Post-wake awake-in-bed: lingering in bed after the final wake.
        if block.end > windowEnd {
            segs.append(SleepSegment(start: windowEnd, end: block.end, stage: .awake))
        }
        return segs
    }

    /// Total time spent in each stage across the night. The overlapping `inBed` span is
    /// excluded so the asleep stages sum to time-asleep.
    public static func stageTotals(_ segments: [SleepSegment]) -> [SleepStage: TimeInterval] {
        var out: [SleepStage: TimeInterval] = [:]
        for s in segments where s.stage != .inBed { out[s.stage, default: 0] += s.duration }
        return out
    }

    /// Roll the segments up into a `Summary` (per-stage durations + total asleep).
    public static func summary(_ segments: [SleepSegment]) -> Summary {
        let t = stageTotals(segments)
        let awake: TimeInterval = t[.awake] ?? 0
        let light: TimeInterval = t[.asleepCore] ?? 0
        let deep: TimeInterval = t[.asleepDeep] ?? 0
        let rem: TimeInterval = t[.asleepREM] ?? 0
        let staged = awake + light + deep + rem
        // Sum ALL in-bed segments: a stitched multi-fragment night carries one per fragment, and the
        // inter-fragment data gaps must NOT count as in-bed (they'd understate efficiency as phantom
        // wake). A single-fragment night has exactly one, so this is unchanged for it.
        let inBedSum = segments.filter { $0.stage == .inBed }.reduce(0) { $0 + $1.duration }
        let inBed = inBedSum > 0 ? inBedSum : staged
        return Summary(inBed: inBed, awake: awake, light: light, deep: deep, rem: rem)
    }

    /// Convenience: total time asleep (Light + Deep + REM) for a set of segments.
    public static func totalAsleep(_ segments: [SleepSegment]) -> TimeInterval {
        let t = stageTotals(segments)
        return (t[.asleepCore] ?? 0) + (t[.asleepDeep] ?? 0) + (t[.asleepREM] ?? 0)
    }

    /// The actual SLEEP window: from the first asleep epoch (real onset) to the end of the last
    /// asleep epoch (final wake). Distinct from the IN-BED window (segment min…max), which also
    /// spans the pre-sleep and post-wake awake-in-bed time. `nil` when nothing is asleep. The gap
    /// between in-bed start and `onset` is the sleep latency; this is what lets the card say "fell
    /// asleep at X / woke at Y" rather than implying the whole bedtime was sleep.
    public static func sleepWindow(_ segments: [SleepSegment]) -> (onset: Date, wake: Date)? {
        let asleep = segments.filter {
            $0.stage == .asleepCore || $0.stage == .asleepDeep || $0.stage == .asleepREM
        }
        guard let onset = asleep.map(\.start).min(), let wake = asleep.map(\.end).max() else { return nil }
        return (onset, wake)
    }

    // MARK: - Helpers

    /// Relabel sub-minimum Deep/REM/Awake runs to Light, so stages don't flap epoch to
    /// epoch (real stages persist for minutes).
    private static func smooth(_ stages: inout [SleepStage], _ t: Tuning) {
        let n = stages.count
        var i = 0
        while i < n {
            var j = i
            while j + 1 < n && stages[j + 1] == stages[i] { j += 1 }
            let run = j - i + 1
            let minRun: Int?
            switch stages[i] {
            case .asleepDeep: minRun = t.minDeepRunEpochs
            case .asleepREM:  minRun = t.minREMRunEpochs
            case .awake:      minRun = t.minAwakeRunEpochs
            default:          minRun = nil
            }
            if let m = minRun, run < m {
                for k in i ... j { stages[k] = .asleepCore }
            }
            i = j + 1
        }
    }

    /// Centered rolling MEDIAN over a ±`half`-epoch window. Robust to single-epoch HR
    /// spikes, so the wake gate keys off a sustained level rather than a transient.
    private static func rollingMedian(_ xs: [Double], half: Int) -> [Double] {
        let n = xs.count
        guard n > 0 else { return [] }
        var out = [Double](repeating: 0, count: n)
        for i in 0 ..< n {
            let s = max(0, i - half), e = min(n - 1, i + half)
            var w = Array(xs[s ... e]); w.sort()
            out[i] = w[w.count / 2]
        }
        return out
    }

    /// Relabel awake runs that are driven ONLY by HR elevation (no motion epoch inside)
    /// and shorter than `minRun` back to asleep, so a transient REM-ish HR bump doesn't
    /// read as an awakening. A run containing any motion-awake epoch is left untouched.
    private static func erodeShortHRWake(_ awake: inout [Bool], motionAwake: [Bool], minRun: Int) {
        let n = awake.count
        var i = 0
        while i < n {
            guard awake[i] else { i += 1; continue }
            var j = i
            while j + 1 < n && awake[j + 1] { j += 1 }
            let run = j - i + 1
            let hasMotion = (i ... j).contains { motionAwake[$0] }
            if run < minRun && !hasMotion { for k in i ... j { awake[k] = false } }
            i = j + 1
        }
    }

    /// Indices spanning real sleep: from the start of the FIRST asleep run of length
    /// ≥ `sustain` to the end of the LAST such run. Short asleep flickers before the
    /// first / after the last sustained run are treated as pre-sleep / post-wake and fall
    /// outside the span. nil when no run is long enough (no real sleep block).
    private static func sleepSpan(_ awake: [Bool], sustain: Int) -> (Int, Int)? {
        let n = awake.count
        var first: Int?, last: Int?
        var i = 0
        while i < n {
            guard !awake[i] else { i += 1; continue }
            var j = i
            while j + 1 < n && !awake[j + 1] { j += 1 }
            if j - i + 1 >= sustain {
                if first == nil { first = i }
                last = j
            }
            i = j + 1
        }
        if let f = first, let l = last { return (f, l) }
        return nil
    }

    /// Mark the leading pre-sleep WIND-DOWN as awake: the stretch before HR first settles near the
    /// night's floor. Fills `awake[0..<onset] = true`, where `onset` is the start of the first
    /// sustained run of smoothed HR at/below a descent-relative band, sought only within the first
    /// `onsetSearchEpochs`. A no-op (leaves `awake` untouched) when there is no real evening→floor
    /// descent, or when HR never sustains below the band early — so it can only ever ADD leading
    /// awake on a genuine wind-down, never trim real sleep on a flat or restless night.
    private static func markDescentOnsetAwake(_ awake: inout [Bool], smHR: [Double],
                                              motionAwake: [Bool], floor: Double, tuning: Tuning) {
        let n = smHR.count
        guard tuning.onsetScanEpochs >= 1, n > tuning.onsetScanEpochs else { return }
        // Evening level = median of the first few in-bed epochs (robust to a single spike).
        let evening = percentile(Array(smHR[0 ..< tuning.onsetScanEpochs]).sorted(), 0.5)
        let descent = evening - floor
        guard descent >= tuning.onsetMinDescentBPM else { return }   // already calm → nothing to trim
        let band = floor + tuning.onsetSettleFraction * descent
        // First index BEGINNING a sustained (≥ onsetSustainEpochs) at/below-band run — i.e. the
        // settle into sleep. The run may extend past the search horizon; only its START must fall
        // within `onsetSearchEpochs`. Motion epochs break a settle run (a moving sleeper is awake).
        let limit = min(tuning.onsetSearchEpochs, n)
        var i = 0
        var onset: Int?
        while i < limit {
            guard smHR[i] <= band && !motionAwake[i] else { i += 1; continue }
            var j = i
            while j + 1 < n && smHR[j + 1] <= band && !motionAwake[j + 1] { j += 1 }
            if j - i + 1 >= tuning.onsetSustainEpochs { onset = i; break }
            i = j + 1
        }
        if let o = onset, o > 0 { for k in 0 ..< o { awake[k] = true } }
    }

    /// Push sleep ONSET past a clear pre-sleep wake episode. On a night spent lying still and AWAKE
    /// for hours — HR fluctuating, with a clearly-elevated block — the fixed/descent gates flag the
    /// obviously-awake epochs but leave the SHORT still dips between them reading as "asleep", so the
    /// onset anchors to the first dip, hours early. If a SUSTAINED awake run (≥ `onsetSustainEpochs`)
    /// still BEGINS within the onset search window, real sleep hasn't started: mark everything up to
    /// the END of the LAST such run as awake-in-bed. Operates ONLY on epochs already judged awake by
    /// the motion/HR gates (it never converts a quiet epoch to wake), and is GUARDED — it does nothing
    /// when a consolidated asleep run (≥ `minConsolidatedSleepEpochs`) preceded the block, so a normal
    /// night (asleep early, one brief stir) is untouched and only a genuine pre-sleep struggle is
    /// trimmed. Leading-edge + bounded by the search window, so it can never run away.
    private static func markLeadInWakeOnset(_ awake: inout [Bool], tuning: Tuning) {
        let n = awake.count
        let limit = min(tuning.onsetSearchEpochs, n)
        guard limit > 0 else { return }
        // Last sustained awake run that BEGINS within the search window (it may extend past it).
        var blockStart: Int?, blockEnd: Int?
        var i = 0
        while i < limit {
            guard awake[i] else { i += 1; continue }
            var j = i
            while j + 1 < n && awake[j + 1] { j += 1 }
            if j - i + 1 >= tuning.onsetSustainEpochs { blockStart = i; blockEnd = j }
            i = j + 1
        }
        guard let bs = blockStart, let be = blockEnd else { return }
        // Guard: if a real consolidated sleep run preceded the block, it's a mid-night awakening, not
        // a pre-sleep struggle — leave onset where it is.
        var longest = 0, run = 0
        for k in 0 ..< bs {
            if awake[k] { run = 0 } else { run += 1; longest = max(longest, run) }
        }
        guard longest < tuning.minConsolidatedSleepEpochs else { return }
        for k in 0 ... be { awake[k] = true }
    }

    /// Centered rolling standard deviation over a ±`half`-epoch window.
    private static func rollingSD(_ xs: [Double], half: Int) -> [Double] {
        let n = xs.count
        guard n > 0 else { return [] }
        var out = [Double](repeating: 0, count: n)
        for i in 0 ..< n {
            let s = max(0, i - half), e = min(n - 1, i + half)
            let w = xs[s ... e]
            let mean = w.reduce(0, +) / Double(w.count)
            let varr = w.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(w.count)
            out[i] = varr.squareRoot()
        }
        return out
    }

    /// Forward-then-backward fill of nil gaps, so a sparse channel (HRV, RR) has no
    /// artificial jumps where readings drop out.
    private static func filledForward<T>(_ xs: [T?]) -> [T?] {
        var out = xs
        var last: T?
        for i in out.indices { if let v = out[i] { last = v } else { out[i] = last } }
        var next: T?
        for i in stride(from: out.count - 1, through: 0, by: -1) {
            if let v = out[i] { next = v } else { out[i] = next }
        }
        return out
    }

    /// Value at quantile `q` (0…1) of a pre-sorted array (nearest-rank). 0 if empty.
    private static func percentile(_ sorted: [Double], _ q: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let idx = Int((q * Double(sorted.count - 1)).rounded())
        return sorted[min(max(idx, 0), sorted.count - 1)]
    }
}
